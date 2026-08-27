# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Binding the symbolic targets in a head's batch - predicted ids, `@command` references, the
      # issue a command means - to records that actually exist.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # A head returns its whole batch at once, so a `SpawnWorker` that targets an issue the same
      # batch creates cannot know the real issue id yet. Heads used to predict that id, which
      # silently attached the worker to whatever issue happened to own the predicted id: when two
      # head batches interleaved, the second head's worker landed under the first head's issue.
      #
      # The kernel now resolves the pointer itself. A head may reference the issue-creating command
      # in the same batch (`issue_from_command`, or an `issue_id` like "@H1-C1"/"@index:0"), and a
      # still-predicted id is verified against the issues the head could actually see plus the
      # issues its own batch created. "Could see" includes the spawn snapshot and issues created by
      # heads that were already visible and still unapplied when this head spawned, because a
      # refinement head may read the updated state file after that earlier head lands. An
      # unverifiable prediction is remapped to this batch's issue when that is unambiguous, and
      # rejected otherwise, so work never routes onto another head's issue. Pre-existing issue ids
      # keep working unchanged.
      def resolve_head_batch_issue_reference(command:, head_id:, index:, commands: [])
        return { "command" => command } unless command.is_a?(Hash)

        command_type = canonical_command_type(value_at(command, "type", "command_type"))
        payload = value_at(command, "payload")
        return { "command" => command } unless payload.is_a?(Hash)

        if BATCH_REMOVABLE_TARGET_COMMANDS.include?(command_type)
          removed_resolution = resolve_batch_removed_target(payload: payload, command_type: command_type, head_id: head_id)
          return removed_resolution if removed_resolution
        end

        plan = head_batch_plan(head_id: head_id, commands: commands, index: index)
        prompt_resolution = nil
        if BATCH_PROJECT_REFERENCE_COMMANDS.include?(command_type)
          project_resolution = resolve_batch_project_target(command: command, payload: payload, command_type: command_type, plan: plan)
          return project_resolution if project_resolution
        end
        if command_type == "SpawnWorker"
          # "start this worker after the worker my own batch spawns" cannot predict the worker id, so
          # it points at the SpawnWorker command instead. Resolve that before applying the command.
          after_resolution = resolve_batch_after_agent_target(command: command, payload: payload, plan: plan, index: index)
          if after_resolution
            return after_resolution if after_resolution.fetch("rejection", nil)

            command = after_resolution.fetch("command")
            payload = value_at(command, "payload")
          end

          # Same problem for the lineage fields: "this worker follows up on the worker my own batch
          # spawns" cannot predict the worker id either, so it points at the SpawnWorker command.
          lineage_resolution = resolve_batch_lineage_agent_target(command: command, payload: payload, plan: plan, index: index)
          if lineage_resolution
            return lineage_resolution if lineage_resolution.fetch("rejection", nil)

            command = lineage_resolution.fetch("command")
            payload = value_at(command, "payload")
          end
        elsif command_type == "PromptAgent"
          # A prompt can follow a SpawnWorker in the same batch. Resolve its symbolic reference
          # before the prompt is dispatched, and redirect a stale replaced-worker id when another
          # head completed the replacement while this head was still routing.
          agent_resolution = resolve_batch_prompt_agent_target(command: command, payload: payload, plan: plan, index: index)
          if agent_resolution
            return agent_resolution if agent_resolution.fetch("rejection", nil)

            prompt_resolution = agent_resolution
            command = agent_resolution.fetch("command")
            payload = value_at(command, "payload")
          end
        end
        unless BATCH_ISSUE_REFERENCE_COMMANDS.include?(command_type)
          return { "command" => command }.tap do |resolution|
            resolution["remap"] = prompt_resolution.fetch("remap") if prompt_resolution&.fetch("remap", nil)
            resolution["resolved_reference"] = prompt_resolution.fetch("resolved_reference") if prompt_resolution&.fetch("resolved_reference", nil)
          end
        end

        reference = head_batch_issue_reference(payload)
        if reference
          return resolve_symbolic_batch_issue_reference(
            command: command,
            payload: payload,
            command_type: command_type,
            reference: reference,
            created: plan.fetch("created"),
            index: index
          )
        end

        return { "command" => command } unless BATCH_ISSUE_GUARDED_COMMANDS.include?(command_type)

        # The batch plan, journal, and head snapshot all hold canonical ids, so compare a
        # head-predicted id in canonical form. Nothing else about the command is rewritten here.
        requested = Ids.canonical(present_string(value_at(payload, "issue_id", "IssueID", "issueId")))
        return { "command" => command } if requested.nil?

        resolve_batch_issue_target(
          command: command,
          payload: payload,
          command_type: command_type,
          requested: requested,
          head_id: head_id,
          plan: plan
        )
      end

      # Resolve a PromptAgent target against a worker this batch spawned, or against a replacement
      # that another head installed after this head captured its snapshot. A stale worker with no
      # replacement remains a normal kernel rejection; guessing a different issue would be worse.
      def resolve_batch_prompt_agent_target(command:, payload:, plan:, index:)
        reference = head_batch_prompt_agent_reference(payload)
        if reference
          described = describe_batch_issue_reference(reference)
          entry = find_batch_issue_reference_entry(reference, plan.fetch("spawned_workers"))
          unless entry
            return {
              "rejection" => {
                "message" => "PromptAgent references #{described}, but this head result has no matching SpawnWorker command.",
                "errors" => ["batch_agent_reference_not_found"]
              }
            }
          end
          if entry.fetch("index", -1).to_i >= index
            return {
              "rejection" => {
                "message" => "PromptAgent references #{described}, which is not applied before it. List the SpawnWorker command first.",
                "errors" => ["batch_agent_reference_out_of_order"]
              }
            }
          end

          agent_id = entry.fetch("agent_id", nil)
          unless agent_id
            return {
              "rejection" => {
                "message" => "PromptAgent references #{described}, but that command did not spawn a worker (#{entry.fetch("status", "pending")}).",
                "errors" => ["batch_agent_reference_unresolved"]
              }
            }
          end

          return {
            "command" => command_with_agent_id(command, payload, agent_id),
            "resolved_reference" => { "reference" => described, "agent_id" => agent_id, "command_type" => "PromptAgent" }
          }
        end

        requested = Ids.canonical(present_string(value_at(payload, "agent_id", "AgentID", "agentId")))
        return { "command" => command } unless requested

        replacement = synchronized_state do
          state = normalized_state
          target = find_agent(state, requested)
          replacement_id = target && present_string(target.fetch("replaced_by_agent_id", nil))
          successor = replacement_id && find_agent(state, replacement_id)
          next nil unless successor && successor.fetch("type", nil) == "worker"
          next nil unless target.fetch("type", nil) == "worker"
          next nil unless successor.fetch("issue_id", nil) == target.fetch("issue_id", nil)

          successor.fetch("id")
        end
        return { "command" => command } unless replacement

        {
          "command" => command_with_agent_id(command, payload, replacement, rerouted_from: requested),
          "remap" => {
            "command_type" => "PromptAgent",
            "requested_agent_id" => requested,
            "agent_id" => replacement,
            "reason" => "replaced_worker_target"
          }
        }
      end

      def head_batch_prompt_agent_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *BATCH_PROMPT_AGENT_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        return nil unless batch_issue_reference_value?(agent_id)

        parse_batch_issue_reference(agent_id)
      end

      def command_with_agent_id(command, payload, agent_id, rerouted_from: nil)
        cleaned = payload.reject do |key, _value|
          name = key.to_s
          BATCH_PROMPT_AGENT_REFERENCE_KEYS.include?(name) || %w[agent_id AgentID agentId].include?(name)
        end
        resolved = { "agent_id" => agent_id, "_rerouted_from_agent_id" => present_string(rerouted_from) }.compact
        command.merge("payload" => cleaned.merge(resolved))
      end

      # Resolution order for a literal `issue_id` inside a head batch. Every step is a fact about
      # the batch or about what the head could see, never a guess about what it meant:
      #
      #   1. the id is one this head would have predicted for an issue its own batch created
      #      (recomputed from the head's snapshot counters) -> bind to the real created issue,
      #   2. the id is literally one of this batch's created issues -> keep it,
      #   3. the batch left an issue it created with no worker of its own while this command points
      #      somewhere else -> the batch is internally inconsistent, so bind to that orphan issue
      #      (single, same project) or reject rather than silently pile work onto another issue,
      #   4. the id was visible in the head's spawn snapshot -> deliberate pre-existing target,
      #   5. the id was visible in that snapshot but the issue has since been removed (a prune or
      #      kill landed while this head was routing) -> skip the command as a no-op; the head
      #      read a real id and there is nothing left to apply it to,
      #   6. anything else -> reject loudly.
      def resolve_batch_issue_target(command:, payload:, command_type:, requested:, head_id:, plan:)
        aliases = plan.fetch("issue_aliases")
        if plan.fetch("ambiguous_issue_aliases").include?(requested)
          return {
            "rejection" => {
              "message" => "#{command_type} targets predicted issue #{requested}, which matches more than one issue created by this head result. " \
                           "Use issue_from_command to name the CreateIssue command it belongs to.",
              "errors" => ["ambiguous_batch_issue_prediction"]
            }
          }
        end

        if (aliased = aliases[requested])
          return { "command" => command } if aliased == requested

          return batch_issue_remap(command, payload, command_type, requested, aliased, "predicted_issue_id_shifted")
        end

        created_ids = plan.fetch("created_issue_ids")
        orphans = plan.fetch("orphan_created_issue_ids")
        return { "command" => command } if created_ids.include?(requested)

        # Only worker routing is subject to the batch-consistency rule. Modifying some other issue
        # in the same batch is a normal operation and never claims a created issue.
        if command_type == "SpawnWorker" && !orphans.empty? && !batch_target_declared_deliberate?(payload)
          candidates = orphans.select { |issue_id| same_project_issue_ids?(issue_id, requested) }
          if candidates.length == 1
            return batch_issue_remap(command, payload, command_type, requested, candidates.first, "batch_created_issue_left_without_worker")
          end

          return {
            "rejection" => {
              "message" => "SpawnWorker targets issue #{requested}, but this head result created #{orphans.join(", ")} without giving #{orphans.length == 1 ? "it" : "them"} a worker. " \
                           "Use issue_from_command to bind each worker to the issue it belongs to, or mark a deliberate existing-issue worker with follow_up_of_agent_id or existing_issue.",
              "errors" => ["ambiguous_batch_issue_target"]
            }
          }
        end

        visibility = head_issue_visibility(head_id: head_id, issue_id: requested)
        return { "command" => command } if visibility.fetch("visible")

        # The target was real when the head read state and was removed under it. Blaming the head
        # for "predicting" the id here is what dropped part of a head's intent behind a warning the
        # user could not act on, so this is a no-op skip with an accurate line instead.
        if visibility.fetch("removed_after_spawn")
          return {
            "skip" => {
              "target_id" => requested,
              "level" => command_type == "SpawnWorker" ? "warning" : "info",
              "message" => removed_batch_issue_target_message(
                command_type: command_type,
                head_id: head_id,
                issue_id: requested,
                removal: visibility.fetch("removal", nil)
              ),
              "errors" => [REMOVED_BATCH_ISSUE_TARGET_ERROR],
              "details" => {
                "head_id" => head_id.to_s,
                "issue_id" => requested,
                "reason" => REMOVED_BATCH_ISSUE_TARGET_ERROR,
                "issue_removal" => visibility.fetch("removal", nil),
                "visibility_evidence" => visibility.fetch("evidence", nil)
              }.compact
            }
          }
        end

        {
          "rejection" => {
            "message" => unseen_batch_issue_target_message(command_type, requested, head_id, visibility),
            "errors" => ["issue_id_not_created_by_this_head_result"]
          }
        }
      end

      # Several very different situations reach the final rejection, and only some of them are a head
      # mistake, so they must never share a sentence:
      #   - the id exists but belongs to work created after this head was spawned, or it never
      #     existed at all -> the head predicted an id, which is the documented mistake,
      #   - the id was removed before this head was even spawned (a stale id copied from an old log,
      #     say) -> still not a legitimate target, but say what happened to it,
      #   - the head record is gone, or it predates snapshot tracking, so the kernel has no
      #     evidence either way -> say that plainly instead of asserting a prediction.
      def unseen_batch_issue_target_message(command_type, requested, head_id, visibility)
        removal = visibility.fetch("removal", nil)
        if visibility.fetch("evidence", nil) == "no_snapshot_recorded"
          "#{command_type} targets issue #{requested}, which no longer exists, and Meringue has no spawn snapshot for this head to tell whether it was removed after routing began. " \
            "Nothing was applied."
        elsif removal
          "#{command_type} targets issue #{requested}, which was removed #{issue_removal_phrase(removal)}, before head #{head_id} was spawned, so it was never in this head's view of state. " \
            "Nothing was applied."
        else
          "#{command_type} targets issue #{requested}, which this head result did not create and the head could not have seen. " \
            "Reference the issue-creating command with issue_from_command instead of predicting an issue id."
        end
      end

      def removed_batch_issue_target_message(command_type:, head_id:, issue_id:, removal:)
        tail = if command_type == "SpawnWorker"
                 "so no worker was started on it. Re-request the work if it is still wanted."
               else
                 "so there was nothing left to update. No state was changed."
               end
        "issue #{issue_id} was removed #{issue_removal_phrase(removal)} after head #{head_id} was spawned with it in view, #{tail}"
      end

      def issue_removal_phrase(removal)
        reason = removal.is_a?(Hash) ? present_string(removal.fetch("reason", nil)) : nil
        removed_at = removal.is_a?(Hash) ? present_string(removal.fetch("removed_at", nil)) : nil
        phrase = case reason
                 when "prune" then "by a prune"
                 when "killed" then "by a kill"
                 when nil then "(pruned or killed)"
                 else "by #{reason.tr("_", " ")}"
                 end
        removed_at ? "#{phrase} at #{removed_at}" : phrase
      end

      # `PromptAgent` and `Kill` name a whole record, and the prune that removed 21 agents in one
      # pass can land between a head reading state and its result being applied. Telling the user
      # "Agent P3-I9-W2 does not exist" and blocking the head for that is the same failure as the
      # issue case: the head read a real id, the record was removed under it, and there is nothing
      # left to do. A target that was already gone when the head was spawned still falls through to
      # normal validation, because that head really did name something it could not see.
      def resolve_batch_removed_target(payload:, command_type:, head_id:)
        requested = if command_type == "PromptAgent"
                      present_string(value_at(payload, "agent_id", "AgentID", "agentId"))
                    else
                      present_string(value_at(payload, "target_id", "TargetID", "targetId"))
                    end
        return nil unless requested
        return nil if requested.start_with?(BATCH_REFERENCE_PREFIX)

        synchronized_state do
          state = normalized_state
          next nil if find_agent(state, requested) || find_issue(state, requested) || find_project(state, requested)

          ledger = %w[agent issue].filter_map { |kind| removed_under_head_result(state, head_id, kind, requested) }.first
          next nil unless ledger && ledger.fetch("after_spawn")

          removal = ledger.fetch("removal")
          kind = removal.fetch("kind", "issue").to_s
          error = kind == "agent" ? REMOVED_BATCH_AGENT_TARGET_ERROR : REMOVED_BATCH_ISSUE_TARGET_ERROR
          {
            "skip" => {
              "target_id" => requested,
              "level" => command_type == "Kill" ? "info" : "warning",
              "message" => removed_batch_record_target_message(
                command_type: command_type,
                head_id: head_id,
                record_id: requested,
                kind: kind,
                removal: removal
              ),
              "errors" => [error],
              "details" => {
                "head_id" => head_id.to_s,
                "target_id" => requested,
                "reason" => error,
                "removed_record" => removal
              }.compact
            }
          }
        end
      end

      def removed_batch_record_target_message(command_type:, head_id:, record_id:, kind:, removal:)
        noun = kind == "agent" ? "agent" : "issue"
        tail = if command_type == "Kill"
                 "so there was nothing left to kill."
               else
                 "so the prompt was not delivered. Re-send it if the work is still wanted."
               end
        "#{noun} #{record_id} was removed #{issue_removal_phrase(removal)} after head #{head_id} was spawned, #{tail}"
      end

      def batch_issue_remap(command, payload, command_type, requested, issue_id, reason)
        {
          "command" => command_with_issue_id(command, payload, issue_id, rerouted_from: requested),
          "remap" => {
            "command_type" => command_type,
            "requested_issue_id" => requested,
            "issue_id" => issue_id,
            "reason" => reason
          }
        }
      end

      # A head states that a worker belongs to an already existing issue's session lineage by
      # setting follow_up_of_agent_id, replace_agent_id, or after_agent_id. That is an explicit
      # target, so the batch-consistency check leaves it alone. Intra-batch references are already
      # resolved to real agent ids before this runs, so "@research" never reaches it.
      def batch_target_declared_deliberate?(payload)
        present_string(value_at(payload, "follow_up_of_agent_id", "followUpOfAgentID", "followUpOfAgentId")) ||
          present_string(value_at(payload, "replace_agent_id", "replaceAgentID", "replaceAgentId")) ||
          present_string(value_at(payload, *DEFERRED_WORKER_AFTER_KEYS)) ||
          !!value_at(payload, "existing_issue", "ExistingIssue", "existingIssue")
      end

      def same_project_issue_ids?(left, right)
        project_id_from_issue_id(left) == project_id_from_issue_id(right)
      end

      def project_id_from_issue_id(issue_id)
        issue_id.to_s[/\A(P\d+)-I\d+/, 1]
      end

      def resolve_batch_project_target(command:, payload:, command_type:, plan:)
        reference = head_batch_project_reference(payload)
        added = plan.fetch("added_projects")
        if reference
          described = describe_batch_issue_reference(reference)
          entry = find_batch_issue_reference_entry(reference, added)
          unless entry && entry.fetch("project_id", nil)
            return {
              "rejection" => {
                "message" => "#{command_type} references #{described}, but this head result has no applied AddProject command there.",
                "errors" => ["batch_project_reference_unresolved"]
              }
            }
          end

          return { "command" => command_with_project_id(command, payload, entry.fetch("project_id")) }
        end

        requested = Ids.canonical(present_string(value_at(payload, "project_id", "ProjectID", "projectId")))
        return nil unless requested

        aliased = plan.fetch("project_aliases")[requested]
        return nil if aliased.nil? || aliased == requested

        {
          "command" => command_with_project_id(command, payload, aliased, rerouted_from: requested),
          "remap" => {
            "command_type" => command_type,
            "requested_project_id" => requested,
            "project_id" => aliased,
            "reason" => "predicted_project_id_shifted"
          }
        }
      end

      # Everything the kernel knows about the batch being applied: what it has created so far, which
      # ids the head would have predicted for those creations, and which created issues the batch
      # never gives a worker of their own.
      def head_batch_plan(head_id:, commands:, index:)
        journal = current_head_command_journal(head_id)
        snapshot = head_batch_snapshot(head_id)
        created = head_batch_created_issues(journal)
        added_projects = head_batch_added_projects(journal)
        aliases = head_batch_predicted_aliases(
          commands: commands,
          journal: journal,
          snapshot: snapshot,
          index: index
        )
        created_issue_ids = created.filter_map { |entry| entry.fetch("issue_id", nil) }
        {
          "created" => created,
          "created_issue_ids" => created_issue_ids,
          "added_projects" => added_projects,
          "spawned_workers" => head_batch_spawned_workers(journal),
          "issue_aliases" => aliases.fetch("issues"),
          "ambiguous_issue_aliases" => aliases.fetch("ambiguous_issues"),
          "project_aliases" => aliases.fetch("projects"),
          "orphan_created_issue_ids" => orphan_created_issue_ids(
            commands: commands,
            created: created,
            aliases: aliases.fetch("issues")
          )
        }
      end

      def head_batch_snapshot(head_id)
        synchronized_state do
          head = find_agent(normalized_state, head_id)
          metadata = head ? (head.fetch("harness_metadata", {}) || {}) : {}
          issue_ids = metadata.fetch("snapshot_issue_ids", nil)
          counters = metadata.fetch("snapshot_counters", nil)
          {
            "issue_ids" => issue_ids.is_a?(Array) ? issue_ids.map(&:to_s) : nil,
            "project_ids" => Array(metadata.fetch("snapshot_project_ids", [])).map(&:to_s),
            "counters" => counters.is_a?(Hash) ? counters : {}
          }
        end
      end

      # Recomputes the ids the head would have predicted for its own creations, following the same
      # rule the head contract documents (`counters` or the max existing number, plus one per
      # creation in the batch). Those predictions become aliases for the ids the kernel actually
      # minted, so a batch stays correctly bound even when another head consumed the ids first.
      def head_batch_predicted_aliases(commands:, journal:, snapshot:, index:)
        issues = {}
        ambiguous_issues = []
        projects = {}
        return { "issues" => issues, "ambiguous_issues" => ambiguous_issues, "projects" => projects } unless snapshot.fetch("issue_ids")

        journal_by_index = {}
        Array(journal).each_with_index do |entry, position|
          next unless entry.is_a?(Hash)

          journal_by_index[entry.fetch("index", position).to_i] = entry
        end

        snapshot_issue_ids = snapshot.fetch("issue_ids")
        snapshot_counters = snapshot.fetch("counters")
        issue_counters = snapshot_counters.fetch("issues_by_project", {}) || {}
        project_counter = snapshot_counters.fetch("projects", nil)
        project_counter = snapshot.fetch("project_ids").length if project_counter.nil?
        snapshot_max_issue = snapshot_max_issue_numbers(snapshot_issue_ids)
        added_projects = 0
        created_per_project = Hash.new(0)

        Array(commands).each_with_index do |proposed, position|
          break if position >= index

          entry = journal_by_index[position]
          next unless entry && entry.fetch("status", nil) == "accepted"

          target_id = present_string(entry.fetch("target_id", nil))
          next unless target_id

          command_type = canonical_command_type(value_at(proposed, "type", "command_type"))
          payload = value_at(proposed, "payload")
          payload = {} unless payload.is_a?(Hash)

          case command_type
          when "AddProject"
            added_projects += 1
            predicted = "P#{project_counter.to_i + added_projects}"
            register_batch_alias!(projects, [], predicted, target_id, snapshot.fetch("project_ids"))
          when "CreateIssue"
            requested_project = present_string(value_at(payload, "project_id", "ProjectID", "projectId"))
            resolved_project = projects.fetch(requested_project, requested_project)
            next unless resolved_project

            created_per_project[resolved_project] += 1
            offset = created_per_project[resolved_project]
            counter_base = issue_counters.fetch(resolved_project, nil)
            max_base = snapshot_max_issue.fetch(resolved_project, 0)
            bases = [counter_base, max_base].compact.map(&:to_i).uniq
            bases = [max_base] if bases.empty?
            prefixes = [resolved_project, requested_project].compact.uniq
            prefixes.each do |prefix|
              bases.each do |base|
                register_batch_alias!(issues, ambiguous_issues, "#{prefix}-I#{base + offset}", target_id, snapshot_issue_ids)
              end
            end
          end
        end

        { "issues" => issues, "ambiguous_issues" => ambiguous_issues, "projects" => projects }
      end

      # An alias is only recorded when the head could not already see something with that id, so a
      # prediction never shadows a real pre-existing target. Two creations claiming the same
      # prediction make it ambiguous, and ambiguous predictions are rejected instead of guessed.
      def register_batch_alias!(table, ambiguous, predicted_id, real_id, visible_ids)
        return if blank?(predicted_id)
        return if Array(visible_ids).include?(predicted_id)
        return if ambiguous.include?(predicted_id)

        existing = table[predicted_id]
        if existing && existing != real_id
          table.delete(predicted_id)
          ambiguous << predicted_id
          return
        end

        table[predicted_id] = real_id
      end

      def snapshot_max_issue_numbers(snapshot_issue_ids)
        Array(snapshot_issue_ids).each_with_object({}) do |issue_id, maxima|
          match = issue_id.to_s.match(/\A(P\d+)-I(\d+)\z/)
          next unless match

          project_id = match[1]
          number = match[2].to_i
          maxima[project_id] = number if number > maxima.fetch(project_id, 0)
        end
      end

      # Issues this batch created that no SpawnWorker in the batch claims. Claims are read from the
      # head's declared payloads (explicit reference, predicted id, or the real created id), never
      # from state that earlier commands already mutated, so every command in a large fan-out batch
      # sees the same answer.
      def orphan_created_issue_ids(commands:, created:, aliases:)
        created_ids = created.filter_map { |entry| entry.fetch("issue_id", nil) }
        return [] if created_ids.empty?

        created_by_index = created.to_h { |entry| [entry.fetch("index", -1).to_i, entry.fetch("issue_id", nil)] }
        created_by_command_id = created.to_h { |entry| [entry.fetch("command_id", nil).to_s, entry.fetch("issue_id", nil)] }
        claimed = []
        Array(commands).each_with_index do |proposed, position|
          next unless proposed.is_a?(Hash)
          next unless canonical_command_type(value_at(proposed, "type", "command_type")) == "SpawnWorker"

          payload = value_at(proposed, "payload")
          payload = {} unless payload.is_a?(Hash)
          reference = head_batch_issue_reference(payload)
          if reference
            claimed << if reference.fetch("kind") == "index"
                         created_by_index[reference.fetch("index").to_i]
                       else
                         created_by_command_id[reference.fetch("command_id").to_s]
                       end
            next
          end

          requested = present_string(value_at(payload, "issue_id", "IssueID", "issueId"))
          next unless requested

          claimed << (aliases[requested] || (created_ids.include?(requested) ? requested : nil))
        end

        created_ids.uniq - claimed.compact.uniq
      end

      def resolve_symbolic_batch_issue_reference(command:, payload:, command_type:, reference:, created:, index:)
        described = describe_batch_issue_reference(reference)
        entry = find_batch_issue_reference_entry(reference, created)
        if entry.nil?
          return {
            "rejection" => {
              "message" => "#{command_type} references #{described}, but this head result has no matching CreateIssue command.",
              "errors" => ["batch_issue_reference_not_found"]
            }
          }
        end
        if entry.fetch("index", -1).to_i >= index
          return {
            "rejection" => {
              "message" => "#{command_type} references #{described}, which is not applied before it. List the CreateIssue command first.",
              "errors" => ["batch_issue_reference_out_of_order"]
            }
          }
        end

        issue_id = entry.fetch("issue_id", nil)
        unless issue_id
          return {
            "rejection" => {
              "message" => "#{command_type} references #{described}, but that command did not create an issue (#{entry.fetch("status", "pending")}).",
              "errors" => ["batch_issue_reference_unresolved"]
            }
          }
        end

        {
          "command" => command_with_issue_id(command, payload, issue_id),
          "resolved_reference" => { "reference" => described, "issue_id" => issue_id, "command_type" => command_type }
        }
      end

      def find_batch_issue_reference_entry(reference, entries)
        if reference.fetch("kind") == "index"
          entries.find { |entry| entry.fetch("index", nil).to_i == reference.fetch("index").to_i }
        else
          wanted = reference.fetch("command_id").to_s
          entries.find { |entry| entry.fetch("command_id", nil).to_s == wanted }
        end
      end

      def head_batch_created_issues(journal)
        Array(journal).each_with_index.filter_map do |entry, position|
          next unless entry.is_a?(Hash)
          next unless canonical_command_type(entry.fetch("command_type", nil)) == "CreateIssue"

          {
            "index" => entry.fetch("index", position).to_i,
            "command_id" => entry.fetch("command_id", nil).to_s,
            "status" => entry.fetch("status", nil),
            "issue_id" => entry.fetch("status", nil) == "accepted" ? present_string(entry.fetch("target_id", nil)) : nil
          }
        end
      end

      # Resolves `follow_up_of_command` / `replace_agent_from_command` (and the equivalent
      # `"@<command_id>"` value written straight into the lineage field) against the workers this
      # batch already spawned, the same way `after_from_command` is resolved.
      def resolve_batch_lineage_agent_target(command:, payload:, plan:, index:)
        resolved_payload = payload
        changed = false
        BATCH_AGENT_REFERENCE_FIELDS.each do |definition|
          reference = head_batch_agent_reference(resolved_payload, definition)
          next unless reference

          resolution = resolve_symbolic_batch_agent_reference(
            payload: resolved_payload,
            definition: definition,
            reference: reference,
            spawned: plan.fetch("spawned_workers"),
            index: index
          )
          return resolution if resolution.fetch("rejection", nil)

          resolved_payload = resolution.fetch("payload")
          changed = true
        end
        return nil unless changed

        { "command" => command.merge("payload" => resolved_payload) }
      end

      def head_batch_agent_reference(payload, definition)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *definition.fetch("reference_keys"))
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        agent_id = value_at(payload, *definition.fetch("aliases"))
        return nil unless batch_issue_reference_value?(agent_id)

        parse_batch_issue_reference(agent_id)
      end

      def resolve_symbolic_batch_agent_reference(payload:, definition:, reference:, spawned:, index:)
        field = definition.fetch("field")
        described = describe_batch_issue_reference(reference)
        entry = find_batch_issue_reference_entry(reference, spawned)
        if entry.nil?
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described} for #{field}, but this head result has no matching SpawnWorker command.",
              "errors" => ["batch_agent_reference_not_found"]
            }
          }
        end
        if entry.fetch("index", -1).to_i >= index
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described} for #{field}, which is not applied before it. List the predecessor SpawnWorker command first.",
              "errors" => ["batch_agent_reference_out_of_order"]
            }
          }
        end

        agent_id = entry.fetch("agent_id", nil)
        unless agent_id
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described} for #{field}, but that command did not spawn a worker (#{entry.fetch("status", "pending")}).",
              "errors" => ["batch_agent_reference_unresolved"]
            }
          }
        end

        { "payload" => payload_with_related_agent_id(payload, definition, agent_id) }
      end

      def payload_with_related_agent_id(payload, definition, agent_id)
        dropped = definition.fetch("reference_keys") + definition.fetch("aliases")
        payload.reject { |key, _value| dropped.include?(key.to_s) }.merge(definition.fetch("field") => agent_id)
      end

      def head_batch_added_projects(journal)
        Array(journal).each_with_index.filter_map do |entry, position|
          next unless entry.is_a?(Hash)
          next unless canonical_command_type(entry.fetch("command_type", nil)) == "AddProject"

          {
            "index" => entry.fetch("index", position).to_i,
            "command_id" => entry.fetch("command_id", nil).to_s,
            "status" => entry.fetch("status", nil),
            "project_id" => entry.fetch("status", nil) == "accepted" ? present_string(entry.fetch("target_id", nil)) : nil
          }
        end
      end

      # Resolves `after_from_command` / `after_agent_id: "@<command_id>"` against the workers this
      # batch has already spawned. Same ordering and failure rules as issue_from_command.
      def resolve_batch_after_agent_target(command:, payload:, plan:, index:)
        reference = head_batch_after_agent_reference(payload)
        return nil unless reference

        described = describe_batch_issue_reference(reference)
        entry = find_batch_issue_reference_entry(reference, plan.fetch("spawned_workers"))
        if entry.nil?
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described}, but this head result has no matching SpawnWorker command.",
              "errors" => ["after_agent_reference_not_found"]
            }
          }
        end
        if entry.fetch("index", -1).to_i >= index
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described}, which is not applied before it. List the worker it waits for first.",
              "errors" => ["after_agent_reference_out_of_order"]
            }
          }
        end

        agent_id = entry.fetch("agent_id", nil)
        unless agent_id
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described}, but that command did not spawn a worker (#{entry.fetch("status", "pending")}).",
              "errors" => ["after_agent_reference_unresolved"]
            }
          }
        end

        {
          "command" => command_with_after_agent_id(command, payload, agent_id),
          "resolved_reference" => { "reference" => described, "after_agent_id" => agent_id, "command_type" => "SpawnWorker" }
        }
      end

      def head_batch_after_agent_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *DEFERRED_WORKER_AFTER_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        value = value_at(payload, *DEFERRED_WORKER_AFTER_KEYS)
        return nil unless batch_issue_reference_value?(value)

        parse_batch_issue_reference(value)
      end

      def command_with_after_agent_id(command, payload, agent_id)
        updated_payload = payload.dup
        DEFERRED_WORKER_AFTER_REFERENCE_KEYS.each { |key| updated_payload.delete(key) }
        DEFERRED_WORKER_AFTER_KEYS.each { |key| updated_payload.delete(key) }
        updated_payload["after_agent_id"] = agent_id
        command.merge("payload" => updated_payload)
      end

      # Workers this batch has spawned so far, so a later command can wait for one of them.
      def head_batch_spawned_workers(journal)
        Array(journal).each_with_index.filter_map do |entry, position|
          next unless entry.is_a?(Hash)
          next unless canonical_command_type(entry.fetch("command_type", nil)) == "SpawnWorker"

          {
            "index" => entry.fetch("index", position).to_i,
            "command_id" => entry.fetch("command_id", nil).to_s,
            "status" => entry.fetch("status", nil),
            "agent_id" => entry.fetch("status", nil) == "accepted" ? present_string(entry.fetch("target_id", nil)) : nil
          }
        end
      end

      def head_batch_project_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *BATCH_PROJECT_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        return nil unless batch_issue_reference_value?(project_id)

        parse_batch_issue_reference(project_id)
      end

      def command_with_project_id(command, payload, project_id, rerouted_from: nil)
        cleaned = payload.reject do |key, _value|
          name = key.to_s
          BATCH_PROJECT_REFERENCE_KEYS.include?(name) || %w[project_id ProjectID projectId].include?(name)
        end
        resolved = { "project_id" => project_id, "_rerouted_from_project_id" => present_string(rerouted_from) }.compact
        command.merge("payload" => cleaned.merge(resolved))
      end

      def head_batch_issue_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *BATCH_ISSUE_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        return nil unless batch_issue_reference_value?(issue_id)

        parse_batch_issue_reference(issue_id)
      end

      def batch_issue_reference_value?(value)
        value.is_a?(String) && value.strip.start_with?(BATCH_REFERENCE_PREFIX)
      end

      def parse_batch_issue_reference(value)
        return { "kind" => "index", "index" => value.to_i } if value.is_a?(Integer)

        if value.is_a?(Hash)
          command_id = present_string(value_at(value, "command_id", "commandId", "command"))
          return { "kind" => "command_id", "command_id" => command_id } if command_id

          index = value_at(value, "index", "command_index", "commandIndex")
          return { "kind" => "index", "index" => index.to_i } unless index.nil?

          return nil
        end

        text = value.to_s.strip.delete_prefix(BATCH_REFERENCE_PREFIX).strip
        return nil if text.empty?

        if (match = text.match(/\A(?:command|command_id|commandId)\s*[:=]\s*(.+)\z/))
          return { "kind" => "command_id", "command_id" => match[1].strip }
        end
        if (match = text.match(/\A(?:index|command_index|commandIndex)\s*[:=]\s*(\d+)\z/))
          return { "kind" => "index", "index" => match[1].to_i }
        end
        return { "kind" => "index", "index" => text.to_i } if text.match?(/\A\d+\z/)

        { "kind" => "command_id", "command_id" => text }
      end

      def describe_batch_issue_reference(reference)
        if reference.fetch("kind") == "index"
          "command index #{reference.fetch("index")} in this head result"
        else
          "command #{reference.fetch("command_id")} in this head result"
        end
      end

      def command_with_issue_id(command, payload, issue_id, rerouted_from: nil)
        cleaned = payload.reject do |key, _value|
          name = key.to_s
          BATCH_ISSUE_REFERENCE_KEYS.include?(name) || %w[issue_id IssueID issueId].include?(name)
        end
        resolved = { "issue_id" => issue_id, "_rerouted_from_issue_id" => present_string(rerouted_from) }.compact
        command.merge("payload" => cleaned.merge(resolved))
      end

      # Only remap a predicted id inside the project the head was already routing to. A predicted
      # id that resolves to another project is a routing mistake the kernel should not paper over.
      def batch_issue_remap_compatible?(requested_issue_id:, candidate_issue_id:)
        synchronized_state do
          state = normalized_state
          requested = find_issue(state, requested_issue_id)
          next true unless requested

          candidate = find_issue(state, candidate_issue_id)
          next false unless candidate

          requested.fetch("project_id", nil) == candidate.fetch("project_id", nil)
        end
      end

      # What this head could see, answered from the head's own spawn snapshot rather than from live
      # state. Live state answers a different question: an issue can be pruned or killed while a
      # head is still routing, and treating "it is not in state now" as "the head could not have
      # seen it" turned every prune-during-routing race into a bogus "you predicted this id"
      # rejection that silently dropped part of the head's intent.
      #
      # Returns:
      #   "visible"             - the issue exists now and this head was entitled to target it,
      #   "removed_after_spawn" - the head saw it at spawn and it has since been removed,
      #   "removal"             - the ledger record of that removal when the kernel has one,
      #   "evidence"            - which fact decided it, for the log details.
      def head_issue_visibility(head_id:, issue_id:)
        synchronized_state do
          state = normalized_state
          issue = find_issue(state, issue_id)
          head = find_agent(state, head_id)
          metadata = head.is_a?(Hash) ? (head.fetch("harness_metadata", {}) || {}) : {}
          snapshot_issue_ids = metadata.fetch("snapshot_issue_ids", nil)
          in_snapshot = if snapshot_issue_ids.is_a?(Array)
                          Array(snapshot_issue_ids).map { |id| Ids.canonical(id.to_s) }.include?(Ids.canonical(issue_id.to_s))
                        end

          if issue
            next issue_visibility(true, "created_by_this_head") if issue.fetch("originating_head_id", nil).to_s == head_id.to_s
            # A head record that is already gone cannot be held to a snapshot nobody kept.
            next issue_visibility(true, "head_record_missing") unless head
            next issue_visibility(true, "spawn_snapshot") if in_snapshot

            # A refinement head can legitimately route to an issue created by a head that was
            # already visible and still applying when this head spawned.
            originating_head_id = present_string(issue.fetch("originating_head_id", nil))
            snapshot_unapplied_head_ids = metadata.fetch("snapshot_unapplied_head_ids", nil)
            if originating_head_id && snapshot_unapplied_head_ids.is_a?(Array)
              if snapshot_unapplied_head_ids.map(&:to_s).include?(originating_head_id)
                next issue_visibility(true, "visible_unapplied_head")
              end
            end
            next issue_visibility(false, "not_in_spawn_snapshot") unless in_snapshot.nil?

            # Heads recorded before snapshot ids were tracked fall back to creation order.
            issue_created = parse_time_or_nil(issue.fetch("created_at", nil))
            head_created = parse_time_or_nil(head.fetch("created_at", nil))
            next issue_visibility(true, "creation_time_unknown") unless issue_created && head_created

            next issue_visibility(issue_created <= head_created, "creation_order")
          end

          # The issue is not in state. Whether that is a removed target or an invented id is the
          # whole distinction, so decide it from recorded facts: the head's snapshot first, then
          # the kernel's own record of what it removed.
          ledger = removed_under_head_result(state, head_id, "issue", issue_id)
          removal = ledger && ledger.fetch("removal")
          next issue_visibility(false, "spawn_snapshot", removed_after_spawn: true, removal: removal) if in_snapshot
          next issue_visibility(false, "not_in_spawn_snapshot", removal: removal) unless in_snapshot.nil?
          next issue_visibility(false, "no_snapshot_recorded") unless ledger

          next issue_visibility(false, "removed_issue_ledger", removed_after_spawn: ledger.fetch("after_spawn"), removal: removal)
        end
      end

      def issue_visibility(visible, evidence, removed_after_spawn: false, removal: nil)
        {
          "visible" => !!visible,
          "removed_after_spawn" => !visible && removed_after_spawn,
          "removal" => removal,
          "evidence" => evidence
        }
      end

      # The kernel's own record of issues it removed. Prune and kill both funnel through
      # `remove_issue_bundles_and_agents!`, so this ledger is the durable answer to "did this id
      # ever exist" once the issue record itself is gone.
      def removed_issue_record(state, issue_id)
        removed_record(state, "issue", issue_id)
      end

      def removed_agent_record(state, agent_id)
        removed_record(state, "agent", agent_id)
      end

      def removed_record(state, kind, record_id)
        canonical = Ids.canonical(record_id.to_s)
        key = REMOVED_RECORD_LEDGER_KEYS.fetch(kind)
        Array(state.fetch("metadata", {}).fetch(key, nil)).reverse.find do |entry|
          entry.is_a?(Hash) && Ids.canonical(entry.fetch("id", entry.fetch("issue_id", nil)).to_s) == canonical
        end
      end

      def record_removed_records!(state, kind, record_ids, reason, now)
        ids = Array(record_ids).compact.map(&:to_s).uniq
        return if ids.empty?

        key = REMOVED_RECORD_LEDGER_KEYS.fetch(kind)
        metadata = (state["metadata"] ||= {})
        ledger = metadata[key]
        ledger = [] unless ledger.is_a?(Array)
        ledger += ids.map do |record_id|
          { "id" => record_id, "kind" => kind, "reason" => reason.to_s, "removed_at" => now }
        end
        metadata[key] = ledger.last(REMOVED_RECORD_LEDGER_LIMIT)
      end

      # Was this record removed after the head was spawned? That is the difference between "the
      # world changed under an in-flight result" and "this head named something it never saw".
      def removed_under_head_result(state, head_id, kind, record_id)
        removal = removed_record(state, kind, record_id)
        return nil unless removal

        head = find_agent(state, head_id)
        head_created = head.is_a?(Hash) ? parse_time_or_nil(head.fetch("created_at", nil)) : nil
        removed_at = parse_time_or_nil(removal.fetch("removed_at", nil))
        after_spawn = head_created.nil? || removed_at.nil? || removed_at >= head_created
        { "removal" => removal, "after_spawn" => after_spawn }
      end

      def head_batch_remap_message(remap)
        if remap.key?("project_id")
          "Routed #{remap.fetch("command_type")} to project #{remap.fetch("project_id")} added by this head result instead of predicted project #{remap.fetch("requested_project_id")}."
        elsif remap.key?("agent_id")
          "Routed #{remap.fetch("command_type")} to replacement worker #{remap.fetch("agent_id")} instead of stale worker #{remap.fetch("requested_agent_id")}."
        elsif remap.fetch("reason", nil) == "batch_created_issue_left_without_worker"
          "Routed #{remap.fetch("command_type")} to issue #{remap.fetch("issue_id")} created by this head result, which would otherwise have had no worker, instead of #{remap.fetch("requested_issue_id")}."
        else
          "Routed #{remap.fetch("command_type")} to issue #{remap.fetch("issue_id")} created by this head result instead of predicted issue #{remap.fetch("requested_issue_id")}."
        end
      end

      def log_head_batch_issue_remap(head_id, resolution)
        remap = resolution.fetch("remap", nil)
        return [] unless remap

        synchronized_state do
          state = normalized_state
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: head_id,
            level: "warning",
            message: head_batch_remap_message(remap),
            details: remap.merge("head_id" => head_id)
          )
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end
    end
  end
end
