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
    #   * `validate_integrity!` audits the finished document and fails loudly, by path, on any id
    #     the rewrite left behind, instead of leaving a queued worker waiting on an id that no
    #     longer exists.
    #
    # Compaction *reuses* ids, and that is what makes "rewrite what resolves" insufficient on its
    # own. The record that was `P2-I2-W1` before a pass may be gone, and an unrelated worker can
    # hold that id afterwards (or be created into it later, since the counters are rewound), so an
    # id left behind does not merely dangle - it silently starts naming a different record. Every
    # id this pass can rename is therefore resolved exactly one of two ways:
    #
    #   * the record survived: the id is rewritten to its new spelling, in structured reference
    #     fields *and* in the human-readable text that quotes it (log messages, issue titles and
    #     descriptions, worker prompts and reports, question context, goal directives, chat rows),
    #     because that text is what the user reads and what a head or dependent worker is handed;
    #   * the record is gone: the bare spelling must stop resolving, because it is now free to be
    #     handed to someone else. In the live orchestration slots the kernel acts on it is cleared,
    #     exactly as dangling worker lineage links already were. In append-only history (log
    #     routing, chat routing) and in text it is marked `(old id)`, so the line stays readable
    #     and attributable to something historical while resolving to no record at all.
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

      # Sections that record what already happened. A reference here cannot be "repointed" the way
      # a live orchestration slot can, so a dangling one is marked rather than cleared: a log line
      # keeps its routing id (annotated) instead of becoming an unattributed line.
      HISTORY_SECTION_KEYS = %w[logs conversation].freeze

      # Values that are byte-exact evidence rather than prose or references: filesystem paths, git
      # branches, URLs, the argv a session was spawned with, raw process output, and harness
      # snapshots. An id-shaped substring inside them (`meringue/fix-P3-I9-abc`) is part of an
      # exact string that something outside Meringue owns, so these subtrees are skipped entirely
      # and nothing inside them is rewritten, marked, or audited.
      VERBATIM_KEYS = %w[
        branch command cwd harness_model_catalogs path pi_session_defaults pi_state
        stderr stderr_tail stdout url
      ].freeze
      VERBATIM_KEY_SUFFIXES = %w[
        _branch _branches _dir _file _files _path _paths _ref _root _url _urls
      ].freeze

      # The grammar of every id this pass can rename. Used by the audit to recognise a stored
      # reference no matter which key holds it, so a field stored under an unconventional key is
      # still caught by validation rather than silently stranded.
      RENAMEABLE_ID_PATTERN = /\A(?:P\d+(?:-I\d+(?:-W\d+)?)?|Q\d+|G\d+)\z/.freeze

      # The same grammar *inside* prose. Deliberately case-sensitive: Meringue always writes ids in
      # canonical upper case, so an id typed in lower case inside a quoted user request stays
      # exactly as the user wrote it instead of being edited into a reference. A word character,
      # `-`, or `/` on either side also disqualifies a match, which is what keeps a branch name
      # (`meringue/fix-P3-I9-abc`), a model id (`glm-5p2-fast`), and a composite correlation id
      # (`P1-I1-W1-PP1`, `G1-IT2-ATTEMPT`, `session-restart-P1-I1-W1-1`) intact.
      EMBEDDED_ID_PATTERN = %r{(?<![\w/-])(P\d+(?:-I\d+(?:-W\d+)?)?|Q\d+|G\d+)(?![\w/-])}

      # Appended to an id that no longer names a record. Deliberately plain, and deliberately not a
      # claim about *why*: the record may have been pruned or killed, or (in state written before
      # this behavior existed) renamed by an earlier pass that left the text behind. What is always
      # true is that the spelling is out of date and now resolves to nothing, which is the point.
      RETIRED_ID_MARKER = " (old id)"

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

        # Captured before anything moves: only a queued-worker chain that was coherent to begin
        # with is required to be coherent afterwards, so legacy or hand-edited state cannot make
        # `/recount` permanently unusable while a chain this pass would break still fails loudly.
        deferred_chains = deferred_chain_census(state, worker_map)

        rewrite_ids!(state, id_map)
        verify_primary_ids!(state, project_map, issue_map, worker_map, question_map, goal_map)
        clean_agent_relationships!(state)
        rebuild_issue_agent_ids!(state)
        reset_counters!(state)
        validate_integrity!(state, deferred_chains: deferred_chains)

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

      # One simultaneous substitution over the whole document, visiting every string exactly once.
      # Primary `id` fields are rewritten by the same pass as the references that point at them, so
      # a swap (P2 -> P1 while P4 -> P2) can never be applied twice to the same value - and neither
      # can a marker, which is what makes a second pass a no-op.
      def rewrite_ids!(state, id_map)
        walk_references!(state) do |value, _path, reference, mode|
          reference ? rewrite_reference_id(value, id_map, mode: mode) : rewrite_text(value, id_map)
        end
        state
      end

      # A structured id slot: exactly one record id, or nothing. When its record is gone the slot
      # must stop resolving, because the spelling it holds is now free to be reused.
      def rewrite_reference_id(value, id_map, mode:)
        mapped = id_map[value]
        return mapped if mapped
        return value unless RENAMEABLE_ID_PATTERN.match?(value)

        mode == :history ? "#{value}#{RETIRED_ID_MARKER}" : nil
      end

      # Human-readable text: log messages, issue titles and descriptions, worker prompts and
      # reports, question context, goal directives, chat rows. The ids quoted here are references
      # too - they are what the user reads and what a head or dependent worker is handed later - so
      # they follow their record, or are marked when there is no longer a record to follow.
      def rewrite_text(text, id_map)
        return text unless text.match?(EMBEDDED_ID_PATTERN)

        text.gsub(EMBEDDED_ID_PATTERN) do |token|
          # Already annotated by an earlier pass: neither spelling nor marker may change again.
          next token if Regexp.last_match.post_match.start_with?(RETIRED_ID_MARKER)

          id_map.fetch(token) { "#{token}#{RETIRED_ID_MARKER}" }
        end
      end

      # Shared traversal for the rewrite and for the audit, so the two can never disagree about
      # which parts of state hold live references. `reference` marks values that are a whole id
      # slot; every other string is prose and is scanned for ids embedded in it. `mode` says
      # whether a dangling slot in this subtree can be cleared (live orchestration) or must be
      # marked (append-only history). Containers are only written when the block actually returned
      # a different value, so the audit traversal never mutates state.
      def walk_references!(node, path = "", reference = false, mode = :live, visit_keys: false, &block)
        case node
        when Hash
          node.each do |key, child|
            next if history_key?(key) || verbatim_key?(key)

            # An id used as a hash *key* is invisible to the rewrite, which only visits values, so
            # the audit inspects keys as well: a future id-keyed map fails the pass loudly instead
            # of silently keeping a pre-recount spelling. The counters keyed by project/issue id
            # are rebuilt from the live tree before validation runs, and the history subtrees that
            # legitimately key by an old id are skipped above.
            block.call(key, "#{path}.#{key} (key)", true, mode) if visit_keys && RENAMEABLE_ID_PATTERN.match?(key.to_s)

            replacement = walk_references!(
              child, "#{path}.#{key}", reference_key?(key), section_mode(key, mode), visit_keys: visit_keys, &block
            )
            node[key] = replacement unless replacement.equal?(child)
          end
          node
        when Array
          cleared = false
          node.each_with_index do |child, index|
            replacement = walk_references!(child, "#{path}[#{index}]", reference, mode, visit_keys: visit_keys, &block)
            next if replacement.equal?(child)

            cleared ||= replacement.nil?
            node[index] = replacement
          end
          # A cleared reference leaves no hole behind: an id list drops the removed member rather
          # than carrying a nil the rest of the kernel would have to defend against.
          node.compact! if cleared
          node
        when String
          block.call(node, path, reference, mode)
        else
          node
        end
      end

      def history_key?(key)
        HISTORY_SUBTREE_KEYS.include?(normalized_key(key))
      end

      # Byte-exact evidence and self-referential correlation keys are skipped whole: nothing inside
      # them is rewritten, marked, or audited, because something outside Meringue's numbering owns
      # the exact string.
      def verbatim_key?(key)
        normalized = normalized_key(key)
        return true if OPAQUE_ID_KEYS.include?(normalized)
        return true if VERBATIM_KEYS.include?(normalized)

        VERBATIM_KEY_SUFFIXES.any? { |suffix| normalized.end_with?(suffix) }
      end

      # History mode is inherited by the whole subtree once entered.
      def section_mode(key, mode)
        HISTORY_SECTION_KEYS.include?(normalized_key(key)) ? :history : mode
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

      # Every id still spelled anywhere in state that names no record, as
      # `{ id => first path that spells it }`. Both shapes count: a whole reference slot, and an id
      # quoted inside prose. An id already annotated with the retired marker is resolved by
      # definition - it deliberately names nothing and can never be mistaken for a live record.
      def unresolved_references(state)
        live = live_ids(state)
        found = {}
        walk_references!(state, visit_keys: true) do |value, path, reference, _mode|
          if reference
            found[value] ||= path if RENAMEABLE_ID_PATTERN.match?(value) && !live.key?(value)
          else
            each_embedded_id(value) { |token| found[token] ||= path unless live.key?(token) }
          end
          value
        end
        found
      end

      # Ids quoted in prose, skipping any that is already followed by the retired marker.
      def each_embedded_id(text)
        return unless text.match?(EMBEDDED_ID_PATTERN)

        text.to_enum(:scan, EMBEDDED_ID_PATTERN).each do
          match = Regexp.last_match
          next if match.post_match.start_with?(RETIRED_ID_MARKER)

          yield match[1]
        end
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

      def validate_integrity!(state, deferred_chains: {})
        validate_unique_ids!(state)
        validate_tree_shape!(state)
        validate_deferred_chains!(state, deferred_chains)
        validate_resolved_ids!(state)
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

      # The catch-all, and the invariant the whole design exists for: when the pass is done, every
      # id still spelled in state - in a reference slot or in prose - names a record that exists
      # right now. Nothing is tolerated. A pre-existing dangling id is not an excuse to leave a
      # bare id behind, because compaction is free to hand that exact spelling to another record,
      # at which point the id stops dangling and starts lying; either the rewrite resolved it, or
      # the marker retired it, or this refuses the pass rather than persisting misattribution.
      def validate_resolved_ids!(state)
        broken = unresolved_references(state)
        return true if broken.empty?

        details = broken.first(5).map { |value, path| "#{value} (#{path})" }.join(", ")
        raise ArgumentError,
              "Recount would leave #{broken.length} ID#{broken.length == 1 ? "" : "s"} " \
              "in state that name no record: #{details}."
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
