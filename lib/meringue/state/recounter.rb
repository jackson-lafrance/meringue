# frozen_string_literal: true

require "json"

module Meringue
  module State
    # Renumbers user-facing AgentTree records while preserving their relationships.
    # Opaque runtime identifiers (harness sessions, PIDs, workspaces, branches) and
    # append-only log/message IDs intentionally remain unchanged.
    #
    # Referential integrity is the whole job. A rename is only correct if *every* place that
    # stores a renamed id is rewritten in the same pass, so the traversal is deliberately
    # inverted: it walks the entire state document and rewrites every reference-shaped field it
    # finds, instead of maintaining a per-record allow list that silently rots whenever a new
    # id-bearing field is added. Two guards keep that honest:
    #
    #   * the pass runs on a copy and is swapped in only after validation passes, so a broken
    #     rename can never be persisted, and
    #   * `validate_integrity!` compares the references that resolved before the pass against the
    #     references that resolve after it. Anything the rewrite missed fails loudly, by path,
    #     instead of leaving a queued worker waiting on an id that no longer exists.
    module Recounter
      # Correlation identifiers that are only ever compared against copies of themselves. They
      # are never resolved back to an AgentTree record, so they are preserved verbatim even when
      # they embed a renamed id (`<agent id>-PP1` pending prompts, `<goal id>-IT2-ATTEMPT`
      # attempt commands, `session-restart-<agent id>-1`). Rewriting one copy and not another
      # would break exactly-once dedupe, which is strictly worse than a stale-looking key.
      OPAQUE_ID_KEYS = %w[
        command_id event_id harness_session_id log_entry_ids message_id next_message_id
        pid session_id tool_call_id
      ].freeze

      # Subtrees that record a *previous* rename. They are history: their old ids intentionally
      # no longer resolve, and rewriting the new-id side of an old mapping would falsify the only
      # record a reader has for translating pre-recount log text. The walker stops at them for
      # both rewriting and auditing.
      HISTORY_SUBTREE_KEYS = %w[last_recount mappings].freeze

      # The grammar of every id this pass can rename. Used by the audit to recognise a stored
      # reference no matter which key holds it, so a field stored under an unconventional key is
      # still caught by validation rather than silently stranded.
      RENAMEABLE_ID_PATTERN = /\A(?:P\d+(?:-I\d+(?:-W\d+)?)?|Q\d+|G\d+)\z/.freeze

      module_function

      def recount!(state)
        # Recount is all-or-nothing: mutate a copy, validate it, and only then swap it in. A
        # failure therefore leaves the caller's state (and the file it came from) untouched.
        working = deep_copy(state)
        mappings = apply_recount!(working)
        state.replace(working)
        mappings
      end

      def apply_recount!(state)
        project_map = sequential_map(state.fetch("projects"), /^P(\d+)$/) { |number, _record| "P#{number}" }
        issue_map = issue_id_map(state, project_map)
        worker_map = worker_id_map(state, issue_map)
        question_map = sequential_map(state.fetch("questions"), /^Q(\d+)$/) { |number, _record| "Q#{number}" }
        goal_map = sequential_map(goal_records(state), Meringue::Goals::Record::ID_PATTERN) { |number, _record| "G#{number}" }
        id_map = project_map.merge(issue_map).merge(worker_map).merge(question_map).merge(goal_map)

        # Captured before anything moves: references that were *already* dangling (a log entry
        # about a pruned worker, a lineage link to a removed session) cannot be repaired by a
        # renumber, so they are the only unresolved references validation is allowed to tolerate.
        # The deferred census is the same idea for queued-worker chains: only a chain this pass
        # breaks is a failure.
        preexisting_dangling = unresolved_references(state)
        deferred_chains = deferred_chain_census(state, worker_map)

        rewrite_references!(state, id_map)
        verify_primary_ids!(state, project_map, issue_map, worker_map, question_map, goal_map)
        clean_agent_relationships!(state)
        rebuild_issue_agent_ids!(state)
        reset_counters!(state)
        validate_integrity!(state, preexisting_dangling: preexisting_dangling, deferred_chains: deferred_chains)

        {
          "project_ids" => changed_entries(project_map),
          "issue_ids" => changed_entries(issue_map),
          "worker_ids" => changed_entries(worker_map),
          "question_ids" => changed_entries(question_map),
          "goal_ids" => changed_entries(goal_map)
        }
      end

      # State is JSON by definition, and a JSON round trip is what the rest of the state layer
      # uses, so the working copy cannot share any mutable node with the caller's snapshot.
      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def goal_records(state)
        Array(state["goals"]).select { |goal| goal.is_a?(Hash) }
      end

      def sequential_map(records, pattern)
        sorted_records(records, pattern).each_with_index.to_h do |record, index|
          [record.fetch("id"), yield(index + 1, record)]
        end
      end

      def issue_id_map(state, project_map)
        state.fetch("projects").flat_map do |project|
          old_project_id = project.fetch("id")
          new_project_id = project_map.fetch(old_project_id)
          issues = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == old_project_id }
          sorted_records(issues, /^#{Regexp.escape(old_project_id)}-I(\d+)$/).each_with_index.map do |issue, index|
            [issue.fetch("id"), "#{new_project_id}-I#{index + 1}"]
          end
        end.to_h
      end

      def worker_id_map(state, issue_map)
        state.fetch("issues").flat_map do |issue|
          old_issue_id = issue.fetch("id")
          new_issue_id = issue_map.fetch(old_issue_id)
          workers = state.fetch("agents").select do |agent|
            agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == old_issue_id
          end
          sorted_records(workers, /^#{Regexp.escape(old_issue_id)}-W(\d+)$/).each_with_index.map do |worker, index|
            [worker.fetch("id"), "#{new_issue_id}-W#{index + 1}"]
          end
        end.to_h
      end

      def sorted_records(records, pattern)
        Array(records).each_with_index.sort_by do |(record, index)|
          id = record.fetch("id", "").to_s
          match = id.match(pattern)
          raise ArgumentError, "Cannot recount malformed AgentTree ID #{id.inspect}." unless match

          [match[1].to_i, index]
        end.map(&:first)
      end

      # One simultaneous substitution over the whole document. Primary `id` fields are rewritten
      # by the same pass as the references that point at them, so a swap (P2 -> P1 while P4 -> P2)
      # can never be applied twice to the same value.
      def rewrite_references!(state, id_map)
        walk_references!(state) do |value, _path, reference|
          reference ? id_map.fetch(value, value) : value
        end
        state
      end

      # Shared traversal for the rewrite and for the audit, so the two can never disagree about
      # which parts of state hold live references. `reference` marks values the rewrite is allowed
      # to rename; the audit inspects every string it sees regardless, which is what makes it a
      # backstop for a field stored under an unexpected key. Containers are only written when the
      # block actually returned a different value, so the audit traversal never mutates state.
      def walk_references!(node, path = "", reference = false, &block)
        case node
        when Hash
          node.each do |key, child|
            next if history_key?(key)

            replacement = walk_references!(child, "#{path}.#{key}", reference_key?(key), &block)
            node[key] = replacement unless replacement.equal?(child)
          end
          node
        when Array
          node.each_with_index do |child, index|
            replacement = walk_references!(child, "#{path}[#{index}]", reference, &block)
            node[index] = replacement unless replacement.equal?(child)
          end
          node
        when String
          block.call(node, path, reference)
        else
          node
        end
      end

      def history_key?(key)
        HISTORY_SUBTREE_KEYS.include?(normalized_key(key))
      end

      def reference_key?(key)
        normalized = normalized_key(key)
        return false if OPAQUE_ID_KEYS.include?(normalized)

        normalized == "id" || normalized.end_with?("_id", "_ids")
      end

      def normalized_key(key)
        key.to_s
           .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
           .tr("-", "_")
           .downcase
      end

      # Every id in the tree that a reference can legitimately resolve to.
      def live_ids(state)
        ids = []
        ids.concat(state.fetch("projects").map { |project| project.fetch("id", nil) })
        ids.concat(state.fetch("issues").map { |issue| issue.fetch("id", nil) })
        ids.concat(state.fetch("agents").map { |agent| agent.fetch("id", nil) })
        ids.concat(state.fetch("questions").map { |question| question.fetch("id", nil) })
        ids.concat(goal_records(state).map { |goal| goal.fetch("id", nil) })
        ids.compact.to_h { |id| [id, true] }
      end

      # Stored ids that resolve to nothing, as `{ id => first path that stores it }`.
      def unresolved_references(state)
        live = live_ids(state)
        found = {}
        walk_references!(state) do |value, path, _reference|
          found[value] ||= path if RENAMEABLE_ID_PATTERN.match?(value) && !live.key?(value)
          value
        end
        found
      end

      def verify_primary_ids!(state, project_map, issue_map, worker_map, question_map, goal_map)
        assert_primary_ids!(state.fetch("projects"), project_map, "Project")
        assert_primary_ids!(state.fetch("issues"), issue_map, "Issue")
        assert_primary_ids!(state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }, worker_map, "Worker")
        assert_primary_ids!(state.fetch("questions"), question_map, "Question")
        assert_primary_ids!(goal_records(state), goal_map, "Goal")
      end

      def assert_primary_ids!(records, id_map, label)
        expected = id_map.values.sort
        actual = records.map { |record| record.fetch("id", nil) }.compact.sort
        return true if expected == actual

        raise ArgumentError, "Recount did not renumber every #{label.downcase} record: expected #{expected.inspect}, got #{actual.inspect}."
      end

      def clean_agent_relationships!(state)
        worker_ids = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }.map { |agent| agent.fetch("id") }
        state.fetch("agents").each do |agent|
          next unless agent.fetch("type", nil) == "worker"

          %w[follow_up_of_agent_id replaces_agent_id replaced_by_agent_id].each do |key|
            next unless agent.key?(key)

            related_id = agent[key]
            agent[key] = nil unless worker_ids.include?(related_id) && related_id != agent.fetch("id")
          end
          if agent.key?("follow_up_agent_ids")
            agent["follow_up_agent_ids"] = Array(agent["follow_up_agent_ids"]).select do |related_id|
              worker_ids.include?(related_id) && related_id != agent.fetch("id")
            end.uniq
          end
        end
      end

      def rebuild_issue_agent_ids!(state)
        workers_by_issue = state.fetch("agents")
                                .select { |agent| agent.fetch("type", nil) == "worker" }
                                .group_by { |agent| agent.fetch("issue_id", nil) }
        state.fetch("issues").each do |issue|
          workers = workers_by_issue.fetch(issue.fetch("id"), [])
          issue["agent_ids"] = workers.sort_by { |worker| worker_number(worker.fetch("id")) }.map { |worker| worker.fetch("id") }
          issue["last_agent_id"] = nil if issue.key?("last_agent_id") && !issue.fetch("agent_ids").include?(issue["last_agent_id"])
        end
      end

      def worker_number(worker_id)
        worker_id.to_s[/\-W(\d+)\z/, 1].to_i
      end

      def reset_counters!(state)
        counters = state.fetch("counters")
        counters["projects"] = state.fetch("projects").length
        counters["questions"] = state.fetch("questions").length
        counters["goals"] = goal_records(state).length
        counters["issues_by_project"] = state.fetch("projects").to_h do |project|
          project_id = project.fetch("id")
          [project_id, state.fetch("issues").count { |issue| issue.fetch("project_id", nil) == project_id }]
        end
        counters["workers_by_issue"] = state.fetch("issues").to_h do |issue|
          issue_id = issue.fetch("id")
          [issue_id, state.fetch("agents").count { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id }]
        end
      end

      def validate_integrity!(state, preexisting_dangling: {}, deferred_chains: {})
        validate_unique_ids!(state)
        validate_tree_shape!(state)
        validate_deferred_chains!(state, deferred_chains)
        validate_no_new_dangling_references!(state, preexisting_dangling)
        true
      end

      def validate_unique_ids!(state)
        {
          "goal" => goal_records(state).map { |goal| goal.fetch("id") },
          "project" => state.fetch("projects").map { |project| project.fetch("id") },
          "issue" => state.fetch("issues").map { |issue| issue.fetch("id") },
          "worker" => state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }.map { |agent| agent.fetch("id") },
          "question" => state.fetch("questions").map { |question| question.fetch("id") }
        }.each do |label, ids|
          raise ArgumentError, "Recount produced duplicate #{label} IDs." unless ids.uniq.length == ids.length
        end
        true
      end

      def validate_tree_shape!(state)
        project_ids = state.fetch("projects").map { |project| project.fetch("id") }
        state.fetch("issues").each do |issue|
          raise ArgumentError, "Issue #{issue.fetch("id")} has no project after recount." unless project_ids.include?(issue.fetch("project_id", nil))

          parent_id = issue.fetch("parent_issue_id", nil)
          next unless parent_id

          parent = state.fetch("issues").find { |candidate| candidate.fetch("id", nil) == parent_id }
          unless parent && parent.fetch("project_id", nil) == issue.fetch("project_id", nil)
            raise ArgumentError, "Issue #{issue.fetch("id")} has an invalid parent after recount."
          end
        end
        state.fetch("agents").each do |agent|
          next unless agent.fetch("type", nil) == "worker"

          issue = state.fetch("issues").find { |candidate| candidate.fetch("id", nil) == agent.fetch("issue_id", nil) }
          unless issue && issue.fetch("project_id", nil) == agent.fetch("project_id", nil)
            raise ArgumentError, "Worker #{agent.fetch("id")} has an invalid issue after recount."
          end
        end
        goal_records(state).each do |goal|
          issue = state.fetch("issues").find { |candidate| candidate.fetch("id", nil) == goal.fetch("issue_id", nil) }
          unless issue && issue.fetch("project_id", nil) == goal.fetch("project_id", nil)
            raise ArgumentError, "Goal #{goal.fetch("id")} has an invalid issue after recount."
          end
        end
        true
      end

      # A queued worker keeps its dependency in two places: the flat `after_agent_id` the kernel
      # schedules on, and the `harness_metadata.deferred_spawn` block that explains and re-points
      # it. If a rename updated one copy and not the other the dependent would either wait
      # forever or be cancelled, so the two must agree and must still describe the same
      # predecessor record.
      def validate_deferred_chains!(state, expected_chains = {})
        agents_by_id = state.fetch("agents").to_h { |agent| [agent.fetch("id", nil), agent] }
        each_deferred_worker(state) do |agent, deferred|
          expected = expected_chains.fetch(agent.fetch("id", nil), {})
          flat_after = present_reference(agent.fetch("after_agent_id", nil))
          deferred_after = present_reference(deferred.fetch("after_agent_id", nil))
          if expected.fetch("agreed", false) && flat_after != deferred_after
            raise ArgumentError,
                  "Worker #{agent.fetch("id")} disagrees about the worker it is queued behind after recount " \
                  "(after_agent_id #{flat_after.inspect}, deferred_spawn.after_agent_id #{deferred_after.inspect})."
          end

          predecessor = agents_by_id[deferred_after || flat_after]
          next unless predecessor && expected.fetch("issue_matched", false)

          deferred_issue = present_reference(deferred.fetch("after_agent_issue_id", nil))
          next if deferred_issue == present_reference(predecessor.fetch("issue_id", nil))

          raise ArgumentError,
                "Worker #{agent.fetch("id")} records the wrong issue for its predecessor " \
                "#{predecessor.fetch("id")} after recount (#{deferred_issue.inspect})."
        end
        true
      end

      # Pre-pass snapshot of every queued-worker chain, keyed by the id the dependent will have
      # after the rename. Only a chain that was coherent before the pass is required to be
      # coherent after it, so hand-edited or legacy state cannot make `/recount` permanently
      # unusable while a chain this pass would break still fails loudly.
      def deferred_chain_census(state, worker_map)
        agents_by_id = state.fetch("agents").to_h { |agent| [agent.fetch("id", nil), agent] }
        census = {}
        each_deferred_worker(state) do |agent, deferred|
          flat_after = present_reference(agent.fetch("after_agent_id", nil))
          deferred_after = present_reference(deferred.fetch("after_agent_id", nil))
          predecessor = agents_by_id[deferred_after || flat_after]
          deferred_issue = present_reference(deferred.fetch("after_agent_issue_id", nil))
          new_id = worker_map.fetch(agent.fetch("id", nil), agent.fetch("id", nil))
          census[new_id] = {
            "agreed" => flat_after == deferred_after,
            "issue_matched" => !predecessor.nil? && !deferred_issue.nil? &&
              deferred_issue == present_reference(predecessor.fetch("issue_id", nil))
          }
        end
        census
      end

      def each_deferred_worker(state)
        state.fetch("agents").each do |agent|
          next unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"

          metadata = agent.fetch("harness_metadata", nil)
          deferred = metadata.is_a?(Hash) ? metadata.fetch("deferred_spawn", nil) : nil
          next unless deferred.is_a?(Hash)

          yield(agent, deferred)
        end
      end

      # The catch-all. Every stored id that resolved before the pass must still resolve after it,
      # whatever record or nesting level holds it. References that were already dangling are the
      # only tolerated unresolved values, because a renumber cannot resurrect a removed record.
      def validate_no_new_dangling_references!(state, preexisting_dangling)
        broken = unresolved_references(state).reject { |value, _path| preexisting_dangling.key?(value) }
        return true if broken.empty?

        details = broken.first(5).map { |value, path| "#{value} (#{path})" }.join(", ")
        raise ArgumentError,
              "Recount would strand #{broken.length} reference#{broken.length == 1 ? "" : "s"} " \
              "pointing at an ID that no longer exists: #{details}."
      end

      def present_reference(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def changed_entries(mapping)
        mapping.reject { |old_id, new_id| old_id == new_id }
      end
    end
  end
end
