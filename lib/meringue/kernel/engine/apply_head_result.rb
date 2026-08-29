# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Applying a head's batch of proposed commands, and the guards that decide which of them a
      # head is allowed to run at all.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def apply_head_result(command_id, command_type, payload)
        head_id = value_at(payload, "head_id", "HeadID", "headId")
        head_result = value_at(payload, "head_result", "HeadResult", "result")
        errors = validate_head_result_shape(head_result)
        errors << "head_id is required" if blank?(head_id)
        return synchronized_state { rejected_result(command_id, command_type, "Head result was not applied.", errors) } unless errors.empty?

        cleanup_head = value_at(payload, "_cleanup_head", "cleanup_head")
        cleanup_head = true if cleanup_head.nil?
        recovering = !!value_at(payload, "_recover", "recover")
        log_ids = []

        initialization = synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return rejected_result(command_id, command_type, "Head #{head_id} does not exist.", ["head_not_found"]) unless head
          return rejected_result(command_id, command_type, "Agent #{head_id} is not a head.", ["agent_is_not_head"]) unless head.fetch("type", nil) == "head"

          if head_result_apply_lease_held_elsewhere?(head)
            return accepted_result(
              command_id,
              command_type,
              head_id.to_s,
              "Head result for #{head_id} is already being applied by another kernel instance.",
              { "head_id" => head_id.to_s, "skipped" => "head_result_apply_in_progress" },
              []
            )
          end

          now = timestamp
          metadata = head.fetch("harness_metadata", {}) || {}
          already_initialized = present_string(metadata.fetch("head_result_initialized_at", nil))
          # Exactly-once: a finished batch is never re-applied, no matter which
          # loop (prompt loop, session poll, or recovery) delivers it again.
          if present_string(metadata.fetch("head_result_applied_at", nil))
            return already_applied_head_result(command_id, command_type, head_id.to_s, metadata)
          end

          if head_takeover_claimed_by?(head)
            return defer_head_result_for_takeover(command_id, command_type, state, head, head_result)
          end

          stored_result = metadata.fetch("head_result", nil)
          fingerprint = head_result_fingerprint(head_result)
          stored_fingerprint = present_string(metadata.fetch("head_result_fingerprint", nil))
          duplicate_variant = already_initialized && stored_result.is_a?(Hash) &&
                              stored_fingerprint && stored_fingerprint != fingerprint
          if duplicate_variant
            # The first recorded result stays authoritative so a re-read or
            # re-parse of the head's output cannot append a second batch of
            # questions, issues, or workers.
            head_result = deep_copy(stored_result)
            fingerprint = stored_fingerprint
          end

          head["status"] = "working"
          head["updated_at"] = now
          metadata = metadata.merge(
            "title" => head_result.fetch("title"),
            "summary" => head_result.fetch("summary"),
            "response" => present_string(head_result.fetch("response", nil)),
            "head_result" => head_result,
            "head_result_fingerprint" => fingerprint,
            "head_result_apply_state" => "applying",
            "head_result_initialized_at" => metadata.fetch("head_result_initialized_at", nil) || now
          ).merge(head_result_apply_lease(now))
          instance_ownership_metadata.each { |key, value| metadata[key] ||= value }
          if duplicate_variant
            metadata["head_result_duplicate_count"] = metadata.fetch("head_result_duplicate_count", 0).to_i + 1
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: head_id.to_s,
              level: "warning",
              message: "Ignored a duplicate result for head #{head_id}; its first result is still being applied.",
              details: { "head_id" => head_id.to_s, "duplicate_count" => metadata.fetch("head_result_duplicate_count") }
            ))
          end
          metadata["head_result_command_journal"] = initialize_head_command_journal(
            state: state,
            head_id: head_id.to_s,
            head_result: head_result,
            existing: metadata.fetch("head_result_command_journal", []),
            recovering: recovering
          )
          unless already_initialized
            metadata["head_result_question_ids"] = ensure_head_questions!(state, head_id.to_s, head_result.fetch("questions"), log_ids)
            log_ids.concat(append_head_response_log(state, head_id, head_result))
          end
          head["harness_metadata"] = metadata
          touch_state!(state, now)
          store.save(state)
          {
            "question_ids" => Array(metadata.fetch("head_result_question_ids", [])),
            "journal" => deep_copy(metadata.fetch("head_result_command_journal")),
            "head" => deep_copy(head)
          }
        end
        return initialization if kernel_command_result?(initialization)

        takeover_previous_head_id = present_string(initialization.dig("head", "harness_metadata", "takeover_of_head_id"))
        if takeover_previous_head_id
          takeover_release = complete_head_takeover!(takeover_previous_head_id, head_id.to_s)
          log_ids.concat(takeover_release.fetch("log_entry_ids", []))
        end

        command_results = []
        interrupted = false
        claimed_by = nil
        state_cleared = false
        skipped_after_clear = 0
        head_snapshot = initialization.fetch("head", nil)
        head_result.fetch("commands").each_with_index do |proposed_command, index|
          command = command_with_default_id(proposed_command, head_id: head_id.to_s, index: index)
          if state_cleared
            skipped_after_clear += 1
            next
          end

          journal_entry = current_head_journal_entry(head_id.to_s, index)
          if journal_entry && terminal_command_status?(journal_entry.fetch("status", nil))
            command_results << command_result_from_journal(journal_entry)
            next
          end

          # Another live instance already claimed this command. Re-running it here
          # is what produced duplicate workers and duplicate spawn logs.
          if (owner = head_command_claim_owner(journal_entry))
            claimed_by = owner
            break
          end

          # The head record can disappear mid-batch when it is killed, cleaned up, or finished
          # by another kernel instance. Stop instead of raising so reconciliation keeps working.
          unless mark_head_command_started!(head_id.to_s, index)
            interrupted = true
            break
          end

          # Resolve intra-batch issue references (and catch mispredicted issue ids) before the
          # command can attach work to an issue this head never created. Then apply the
          # head-command permission/destructive guardrails to the resolved command.
          resolution = resolve_head_batch_issue_reference(
            command: command,
            head_id: head_id.to_s,
            index: index,
            commands: head_result.fetch("commands")
          )
          # The journal establishes the author of this command before the kernel applies it.
          # Keep that provenance active while validation, remapping, and application emit their
          # logs; `source_type: kernel` still says who applied the command, while details retain
          # which head proposed it.
          result = with_head_command_log_attribution(head_id.to_s) do
            if (rejection = resolution.fetch("rejection", nil))
              synchronized_state do
                rejected_result(
                  value_at(command, "command_id", "id"),
                  canonical_command_type(value_at(command, "type", "command_type")),
                  with_dropped_intent(rejection.fetch("message"), command),
                  rejection.fetch("errors")
                )
              end
            elsif (skip = resolution.fetch("skip", nil))
              synchronized_state do
                skipped_result(
                  value_at(command, "command_id", "id"),
                  canonical_command_type(value_at(command, "type", "command_type")),
                  skip.fetch("target_id", nil),
                  with_dropped_intent(skip.fetch("message"), command),
                  skip.fetch("errors"),
                  level: skip.fetch("level", "info"),
                  details: skip.fetch("details", {})
                )
              end
            else
              resolved_command = resolution.fetch("command")
              # Resolution above established what was true while the command was being prepared.
              # Refresh it again at the submission boundary: kill/prune may have committed between
              # that lookup and this command's actual dispatch. The second pass also rebinds a
              # prediction against the state that is about to receive the command.
              fresh_resolution = fresh_head_command_target_refresh(
                command: resolved_command,
                head_id: head_id.to_s
              )
              if (fresh_skip = fresh_resolution.fetch("skip", nil))
                skipped_result(
                  value_at(resolved_command, "command_id", "id"),
                  canonical_command_type(value_at(resolved_command, "type", "command_type")),
                  fresh_skip.fetch("target_id", nil),
                  with_dropped_intent(fresh_skip.fetch("message"), resolved_command),
                  fresh_skip.fetch("errors"),
                  level: fresh_skip.fetch("level", "info"),
                  details: fresh_skip.fetch("details", {})
                )
              else
                guard_result = head_command_guard_result(resolved_command, head: head_snapshot)
                unless guard_result
                  log_ids.concat(log_head_batch_issue_remap(head_id.to_s, resolution))
                end
                applied = guard_result || apply(resolved_command)
                # The fresh check cannot make the check-and-use operation atomic with commands
                # that perform external work. If removal wins that final race, use the durable
                # removal ledger to preserve the request as an explicit skip rather than surfacing
                # a generic not-found rejection (or, worse, provisioning onto a dead issue).
                command_result_after_target_removal(
                  applied,
                  command: resolved_command,
                  head_id: head_id.to_s
                )
              end
            end
          end
          command_results << result
          # Persist a request-linked PR as soon as this command establishes an issue route. A later
          # SpawnWorker may spend minutes provisioning a workspace, and neither that wait nor a
          # worker's eventual completion should delay the issue association.
          associate_head_request_pull_requests!(head_snapshot, result)
          # ClearState removes the journal along with everything else, so it is the last command
          # the kernel can honestly journal. Report the batch as applied instead of treating the
          # deliberate wipe as an interrupted batch.
          if result.fetch("command_type", nil) == "ClearState" && result.fetch("status", nil) == "accepted"
            state_cleared = true
            next
          end

          unless checkpoint_head_command_result!(head_id.to_s, index, result)
            interrupted = true
            break
          end
        end

        if state_cleared
          return cleared_state_head_result(
            command_id,
            command_type,
            head_id.to_s,
            head_result: head_result,
            head_snapshot: head_snapshot,
            command_results: command_results,
            skipped_after_clear: skipped_after_clear
          )
        end

        if claimed_by
          return synchronized_state do
            rejected_result(
              command_id,
              command_type,
              "Head #{head_id}'s result is already being applied by Meringue instance #{claimed_by}.",
              ["head_result_claimed_by_another_instance"]
            )
          end
        end

        auto_retry_plan = nil
        final_result = synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          unless head
            return interrupted_head_result(command_id, command_type, state, head_id.to_s, command_results, log_ids)
          end

          accepted_count = command_results.count { |result| result.fetch("status", nil) == "accepted" }
          # A command whose target was removed under the head is not a rejection the head or the
          # user can fix, so it is counted (and reported) separately and never makes the batch
          # look partially applied.
          skipped_count = command_results.count { |result| head_command_result_skipped?(result) }
          rejected_count = command_results.count { |result| result.fetch("status", nil) == "rejected" } - skipped_count
          failed_count = command_results.count { |result| result.fetch("status", nil) == "failed" }
          unapplied_count = rejected_count + failed_count
          question_ids = initialization.fetch("question_ids")
          if interrupted
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: head_id.to_s,
              level: "warning",
              message: "Stopped applying head #{head_id}'s remaining commands because its command journal is no longer tracked.",
              details: { "head_id" => head_id.to_s, "applied_command_count" => command_results.length }
            ))
          end
          # The prompt was logged before the stateless head knew where it belonged. Complete its
          # routing metadata only from commands that actually landed, so AgentTree issue/worker
          # filters keep the originating user line without treating rejected intent as a route.
          attribute_user_prompt_routes!(state, head_id.to_s, command_results)
          # Same visible output as the typed slash path: the kernel's own command output reaches
          # the user, so a head summary never has to restate "Pruned N issues, ...".
          log_ids.concat(append_head_command_output_logs(state, head_id.to_s, command_results))
          summary_log_ids = if skipped_count.positive?
                              append_log(
                                state,
                                source_type: "kernel",
                                source_id: head_id.to_s,
                                level: head_batch_summary_level(rejected_count: rejected_count, failed_count: failed_count),
                                message: head_batch_summary_message(
                                  head_id: head_id.to_s,
                                  accepted_count: accepted_count,
                                  rejected_count: rejected_count,
                                  failed_count: failed_count,
                                  skipped_count: skipped_count
                                ),
                                details: State::Compactor.head_command_diagnostic_details(
                                  "head_id" => head_id.to_s,
                                  "question_ids" => question_ids,
                                  "skipped_command_count" => skipped_count,
                                  "command_results" => command_results
                                )
                              )
                            else
                              []
                            end
          # A direct response handles the message without orchestration. Only a truly empty or
          # wholly failed result is unrouted and needs the retry warning.
          direct_response = present_string(head_result.fetch("response", nil))
          unrouted_log_ids = if accepted_count.zero? && question_ids.empty? && !direct_response
                               append_unrouted_user_message_log(state, head_id.to_s, command_results)
                             else
                               []
                             end
          now = timestamp
          metadata = head.fetch("harness_metadata", {}) || {}
          metadata["head_result_apply_state"] = unapplied_count.positive? ? "partially_applied" : "applied"
          metadata["head_result_apply_status"] = unapplied_count.positive? ? "partial" : "accepted"
          metadata["head_result_applied_at"] = now
          metadata["head_result_skipped_command_count"] = skipped_count if skipped_count.positive?
          auto_retry_requested = skipped_count.positive? && !metadata.fetch("automatic_target_removal_retry_at", nil) &&
                                 head_retry_count(head).zero?
          if auto_retry_requested
            # Checkpoint the recovery before any harness call. The replacement is intentionally
            # limited to one automatic attempt: if the replacement sees another removal, it stays
            # visible as an unrouted/manual-retry case instead of looping forever.
            metadata["automatic_target_removal_retry_at"] = now
            metadata["automatic_target_removal_retry_state"] = "pending"
          end
          head["harness_metadata"] = metadata
          head["status"] = (unapplied_count.positive? || auto_retry_requested) ? "blocked" : "completed"
          head["updated_at"] = now
          # A completion head and the worker continuation that spawned it are checkpointed in the
          # same state transaction. If the process dies after this save but before the synchronous
          # caller finalizes its result, reconciliation sees `applied` instead of spawning a second
          # head after the first head record has already been cleaned up.
          checkpoint_completion_continuation_from_head_result!(state, head, now: now)

          log_ids.concat(command_results.flat_map { |result| result.fetch("log_entry_ids", []) })
          log_ids.concat(summary_log_ids)
          log_ids.concat(unrouted_log_ids)
          cleanup = if cleanup_head && unapplied_count.zero? && !auto_retry_requested
                      cleanup_applied_head!(state, head_id.to_s, now: now)
                    elsif cleanup_head
                      { "changed" => false, "reason" => auto_retry_requested ? "automatic_retry_pending" : "partially_applied" }
                    else
                      { "changed" => false, "reason" => "deferred" }
                    end
          log_ids.concat(cleanup.fetch("log_entry_ids", []))
          if auto_retry_requested
            auto_retry_plan = head_retry_plan(state, head_id.to_s)
            auto_retry_plan = nil unless auto_retry_plan.fetch("eligible")
          end
          touch_state!(state, now)
          store.save(state)

          accepted_result(
            command_id,
            command_type,
            head_id.to_s,
            "Applied head result for #{head_id}.",
            {
              "head_id" => head_id.to_s,
              "title" => head_result.fetch("title"),
              "summary" => head_result.fetch("summary"),
              "response" => direct_response,
              "question_ids" => question_ids,
              "command_results" => command_results,
              "head_cleanup" => cleanup
            },
            log_ids.uniq
          )
        end

        if auto_retry_plan
          retry_result = automatic_target_removal_retry(auto_retry_plan)
          final_result["result"] = (final_result.fetch("result", {}) || {}).merge(
            "automatic_retry" => retry_result
          )
          final_result["log_entry_ids"] = Array(final_result.fetch("log_entry_ids", [])) + Array(retry_result.fetch("log_entry_ids", []))
        end
        final_result
      end

      # Automatic recovery deliberately shares the manual retry machinery: the same immutable plan
      # and respawn path build the replacement prompt, carry the command journal, and atomically
      # remove the predecessor. Only the trigger and the one-attempt guard differ.
      def automatic_target_removal_retry(plan)
        result = respawn_head_retry(nil, "AutomaticHeadRetry", plan)
        return result unless result.fetch("status", nil) == "accepted"

        result.merge(
          "automatic" => true,
          "message" => "Automatically retried unrouted work as head #{result.fetch("target_id", nil)}."
        )
      rescue StandardError => e
        failed_result(nil, "AutomaticHeadRetry", "Automatic head retry was not started: #{sanitized_error_message(e)}", [e.class.name, sanitized_error_message(e)])
      end

      # Re-check only the already-resolved target at submission. The full batch resolver is not
      # repeated here because a later alias pass could reinterpret an earlier command.
      def fresh_head_command_target_refresh(command:, head_id:)
        type = canonical_command_type(value_at(command, "type", "command_type"))
        payload = value_at(command, "payload")
        payload = {} unless payload.is_a?(Hash)
        if BATCH_REMOVABLE_TARGET_COMMANDS.include?(type)
          return resolve_batch_removed_target(payload: payload, command_type: type, head_id: head_id) || { "command" => command }
        end
        return { "command" => command } unless BATCH_ISSUE_GUARDED_COMMANDS.include?(type)

        issue_id = present_string(value_at(payload, "issue_id", "IssueID", "issueId"))
        return { "command" => command } unless issue_id
        synchronized_state do
          state = normalized_state
          next({ "command" => command }) if find_issue(state, issue_id)
          ledger = removed_under_head_result(state, head_id, "issue", issue_id)
          next({ "command" => command }) unless ledger && ledger.fetch("after_spawn")
          removal = ledger.fetch("removal")
          { "skip" => { "target_id" => issue_id,
                         "level" => type == "SpawnWorker" ? "warning" : "info",
                         "message" => removed_batch_issue_target_message(command_type: type, head_id: head_id, issue_id: issue_id, removal: removal),
                         "errors" => [REMOVED_BATCH_ISSUE_TARGET_ERROR],
                         "details" => { "head_id" => head_id.to_s, "issue_id" => issue_id,
                                        "reason" => REMOVED_BATCH_ISSUE_TARGET_ERROR,
                                        "issue_removal" => removal,
                                        "visibility_evidence" => "fresh_submission_check" } } }
        end
      end

      # External provisioning leaves a final check/use gap. If removal wins it, convert only an
      # exact not-found failure backed by the durable ledger; unrelated failures remain retryable.
      def command_result_after_target_removal(result, command:, head_id:)
        return result unless result.is_a?(Hash) && result.fetch("status", nil) != "accepted"
        missing = %w[issue_not_found target_issue_not_found agent_not_found target_not_found reservation_issue_or_project_not_found]
        return result unless Array(result.fetch("errors", [])).any? { |error| missing.include?(error.to_s) }
        type = canonical_command_type(value_at(command, "type", "command_type"))
        payload = value_at(command, "payload")
        payload = {} unless payload.is_a?(Hash)
        requested = if type == "PromptAgent"
                      present_string(value_at(payload, "agent_id", "AgentID", "agentId"))
                    elsif type == "Kill"
                      present_string(value_at(payload, "target_id", "TargetID", "targetId", "id"))
                    else
                      present_string(value_at(payload, "issue_id", "IssueID", "issueId"))
                    end
        return result unless requested
        removal = synchronized_state do
          state = normalized_state
          next nil if find_issue(state, requested) || find_agent(state, requested) || find_project(state, requested)
          %w[issue agent].filter_map do |kind|
            ledger = removed_under_head_result(state, head_id, kind, requested)
            ledger && ledger.fetch("after_spawn") ? ledger.fetch("removal") : nil
          end.first
        end
        return result unless removal
        kind = removal.fetch("kind", type == "PromptAgent" ? "agent" : "issue").to_s
        error = kind == "agent" ? REMOVED_BATCH_AGENT_TARGET_ERROR : REMOVED_BATCH_ISSUE_TARGET_ERROR
        skipped_result(value_at(command, "command_id", "id") || result.fetch("command_id", nil), type, requested,
                      with_dropped_intent(removed_batch_record_target_message(command_type: type, head_id: head_id,
                                                                              record_id: requested, kind: kind,
                                                                              removal: removal), command),
                      [error], level: type == "Kill" ? "info" : "warning",
                      details: { "head_id" => head_id.to_s, "target_id" => requested, "reason" => error,
                                 "removed_record" => removal, "original_errors" => result.fetch("errors", []) })
      end

      # Stable identity for one head result, so a re-delivered or re-parsed copy of
      # the same decision can be recognized instead of applied again.
      def head_result_fingerprint(head_result)
        Digest::SHA256.hexdigest(
          JSON.generate(
            "title" => head_result.fetch("title", nil).to_s,
            "summary" => head_result.fetch("summary", nil).to_s,
            "response" => head_result.fetch("response", nil).to_s,
            "commands" => Array(head_result.fetch("commands", [])),
            "questions" => Array(head_result.fetch("questions", []))
          )
        )
      end

      def already_applied_head_result(command_id, command_type, head_id, metadata)
        journal = Array(metadata.fetch("head_result_command_journal", []))
        accepted_result(
          command_id,
          command_type,
          head_id,
          "Head result for #{head_id} was already applied.",
          {
            "head_id" => head_id,
            "title" => metadata.fetch("title", nil),
            "summary" => metadata.fetch("summary", nil),
            "response" => metadata.fetch("response", nil),
            "question_ids" => Array(metadata.fetch("head_result_question_ids", [])),
            "command_results" => journal.map { |entry| command_result_from_journal(entry) },
            "duplicate_apply" => true
          },
          []
        )
      end

      # The head record can be killed or cleaned up while its batch is running.
      # Commands that already ran still count as applied work, so this reports what
      # happened as a warning rather than a command failure.
      def interrupted_head_result(command_id, command_type, state, head_id, command_results, log_ids)
        # Commands that landed before another instance removed the head still routed the request.
        # Preserve that routing attribution even though this batch cannot reach its ordinary
        # finalizer. Command authorship was attached when each log entry was created, and
        # request-linked PRs were checkpointed beside each accepted routing command.
        attribute_user_prompt_routes!(state, head_id, command_results)
        log_ids.concat(command_results.flat_map { |result| result.fetch("log_entry_ids", []) })
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: head_id,
          level: "warning",
          message: "Head #{head_id} was no longer tracked when its result finished applying; #{command_results.length} command(s) were applied.",
          details: { "head_id" => head_id, "applied_command_count" => command_results.length }
        ))
        touch_state!(state)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          head_id,
          "Applied head result for #{head_id} after the head was cleaned up.",
          {
            "head_id" => head_id,
            "command_results" => command_results,
            "head_missing" => true
          },
          log_ids.uniq
        )
      end

      # Answering an open question is not bookkeeping. The answer is the input a head said it
      # needed, so the kernel records the answer, closes the question, and then spawns a fresh
      # head carrying the answer plus the original question context (question text, context,
      # project/issue scope, originating head, and the user message that triggered the question)
      # so the work the question blocked actually gets routed instead of silently stopping at
      # "Answered question Q<n>."
      def answer_question_and_route(command_id, command_type, payload)
        outcome = synchronized_state { record_question_answer(command_id, command_type, payload) }
        result = outcome.fetch("result")
        return result unless result.fetch("status", nil) == "accepted"
        return result unless outcome.fetch("recorded", false)
        return result unless answer_routing_enabled?(payload)

        question = outcome.fetch("question")
        routing = route_answered_question(question)
        accepted_result(
          command_id,
          command_type,
          question.fetch("id"),
          answer_routing_message(question, routing),
          question.merge("routing" => answer_routing_summary(routing)),
          (Array(result.fetch("log_entry_ids", [])) + answer_routing_log_entry_ids(routing)).uniq
        )
      end

      # A head that proposes AnswerQuestion returns its own routing commands in the same batch,
      # so the kernel must not spawn a second head for that answer. It also must not re-enter the
      # head-result apply path while that batch still holds the apply lease.
      def answer_routing_enabled?(payload)
        return false if present_string(value_at(payload, "_head_id", "head_id", "HeadID"))
        return false if @head_result_mutex.owned?

        flag = value_at(payload, "route_answer", "spawn_head", "route")
        return true if flag.nil?

        flag != false && flag.to_s.strip.downcase != "false"
      end

      def route_answered_question(question)
        spawn_result = spawn_head(
          nil,
          "SpawnHead",
          "user_message" => answer_routing_prompt(question),
          "question_id" => question.fetch("id"),
          "log_message" => "Answered #{question.fetch("id")}: #{question.fetch("answer")}"
        )
        routing = { "spawn_head_result" => spawn_result }
        return routing unless spawn_result.fetch("status", nil) == "accepted"

        head_id = present_string(spawn_result.fetch("target_id", nil))
        routing["head_id"] = head_id if head_id
        head_result = (spawn_result.dig("result", "harness_metadata") || {})["head_result"]
        # Asynchronous head runners hand the result to reconciliation instead, which applies it
        # through the same ApplyHeadResult path once the session settles.
        return routing unless head_id && head_result.is_a?(Hash)

        routing["apply_head_result"] = @head_result_mutex.synchronize do
          apply_head_result(nil, "ApplyHeadResult", "head_id" => head_id, "head_result" => head_result)
        end
        routing
      rescue StandardError => e
        { "error" => error_payload(e) }
      end

      def answer_routing_prompt(question)
        question_id = question.fetch("id")
        lines = [
          "The user answered open Meringue question #{question_id}. This is the missing input for the work that question blocked, not a brand-new goal.",
          "",
          "Question (#{question_id}): #{question.fetch("question")}"
        ]
        context = present_string(question.fetch("context", nil))
        lines << "Question context: #{context}" if context
        original_message = present_string(question.fetch("original_user_message", nil))
        lines << "Original user message that led to the question: #{original_message}" if original_message
        asking_head = present_string(question.fetch("head_id", nil))
        lines << "Question was asked by head: #{asking_head}" if asking_head
        project_id = present_string(question.fetch("project_id", nil))
        issue_id = present_string(question.fetch("issue_id", nil))
        scope = [project_id ? "project #{project_id}" : nil, issue_id ? "issue #{issue_id}" : nil].compact
        lines << "Question scope: #{scope.join(", ")}" unless scope.empty?
        lines << "User answer: #{question.fetch("answer")}"
        lines << ""
        lines << "The question is already recorded as answered, so do not ask it again and do not propose AnswerQuestion for it."
        lines << "Route the work this answer unblocks: reuse the question's issue when it still represents the durable goal, and continue it in a fresh worker queued behind the settled worker it follows (after_agent_id plus follow_up_of_agent_id) so it inherits that worktree, branch, and final report. Prompt an existing worker instead only when it is mid-turn and needs steering, or stopped mid-flight and must be resumed."
        lines << "Ask a new clarifying question only if the answer still leaves the routing genuinely ambiguous."
        lines.join("\n")
      end

      def answer_routing_message(question, routing)
        question_id = question.fetch("id")
        if routing.key?("error")
          return "Answered question #{question_id}, but routing the answer failed: #{routing.dig("error", "message")}"
        end

        head_id = routing.fetch("head_id", nil)
        return "Answered question #{question_id}, but no head could be spawned to act on the answer." unless head_id

        "Answered question #{question_id} and spawned head #{head_id} to act on the answer."
      end

      def answer_routing_summary(routing)
        {
          "head_id" => routing.fetch("head_id", nil),
          "spawn_head_status" => routing.dig("spawn_head_result", "status"),
          "apply_head_result_status" => routing.dig("apply_head_result", "status"),
          # Nested results so callers can see (and wait on) the work the answer actually started.
          "command_results" => routing.dig("apply_head_result", "result", "command_results"),
          "error" => routing.fetch("error", nil)
        }.compact
      end

      def answer_routing_log_entry_ids(routing)
        [routing.fetch("spawn_head_result", nil), routing.fetch("apply_head_result", nil)].compact.flat_map do |result|
          Array(result.fetch("log_entry_ids", []))
        end
      end

      # A head-proposed `ClearState` deliberately removes the head record, its journal, and the
      # visible logs. The batch therefore ends here: the wipe is reported as applied work, the
      # head's harness session is released, and the kernel's own command output is re-logged into
      # the fresh state so the user still sees "Cleared Meringue state."
      def cleared_state_head_result(command_id, command_type, head_id, head_result:, head_snapshot:,
                                    command_results:, skipped_after_clear: 0)
        release_head_session!(head_snapshot, reason: "head_result_cleared_state") if head_snapshot.is_a?(Hash)

        synchronized_state do
          state = normalized_state
          log_ids = append_head_command_output_logs(state, head_id, command_results)
          if skipped_after_clear.positive?
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: head_id,
              level: "warning",
              message: "Skipped #{skipped_after_clear} command(s) after head #{head_id}'s ClearState reset Meringue state.",
              details: { "head_id" => head_id, "skipped_command_count" => skipped_after_clear }
            ))
          end
          touch_state!(state)
          store.save(state)

          accepted_result(
            command_id,
            command_type,
            head_id,
            "Applied head result for #{head_id}; ClearState reset Meringue state.",
            {
              "head_id" => head_id,
              "title" => head_result.fetch("title", nil),
              "summary" => head_result.fetch("summary", nil),
              "response" => head_result.fetch("response", nil),
              "question_ids" => [],
              "command_results" => command_results,
              "state_cleared" => true,
              "skipped_command_count" => skipped_after_clear
            },
            log_ids.uniq
          )
        end
      end

      # Pull request links in a user's request are routing metadata: when the head assigns that
      # request to an issue, the issue should expose the linked PR immediately rather than waiting
      # for a worker to finish and mention it again. We intentionally store the links as
      # unverified delivery records. The normal refresh path can enrich their lifecycle state, and
      # the worker-completion path can merge branch/repository verification into the same URL.
      def associate_head_request_pull_requests!(head, command_result)
        return [] unless github_support_enabled?
        return [] unless head.is_a?(Hash)
        return [] unless command_result.is_a?(Hash) && command_result.fetch("status", nil) == "accepted"
        return [] unless PULL_REQUEST_ASSOCIATING_COMMANDS.include?(command_result.fetch("command_type", nil).to_s)

        metadata = head.fetch("harness_metadata", {}) || {}
        # Completion continuations contain worker output, not a new user request. Associating a URL
        # from one here would bypass the existing branch/repository verification performed when the
        # worker settles.
        return [] if metadata.is_a?(Hash) && metadata.fetch("completion_trigger", nil).is_a?(Hash)

        urls = extract_linked_pull_request_urls(head_record_user_message(head))
        return [] if urls.empty?

        synchronized_state do
          state = normalized_state
          issue_id = routed_issue_id(state, command_result)
          issue = issue_id && find_issue(state, issue_id)
          next [] unless issue

          existing_urls = State::Models.pull_request_records_from(issue).filter_map do |record|
            canonical_pull_request_url(State::Models.pull_request_record_url(record))
          end
          records = urls.reject { |url| existing_urls.include?(canonical_pull_request_url(url)) }.map do |url|
            {
              "url" => url,
              "matched_by" => "user_request",
              "associated_at" => timestamp
            }
          end
          next [] if records.empty?

          now = timestamp
          State::Models.attach_pull_requests_to_issue!(
            issue,
            delivery_pull_requests: records,
            reported_urls: urls
          )
          issue["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          [{
            "issue_id" => issue.fetch("id"),
            "pull_request_urls" => records.map { |record| record.fetch("url") }
          }]
        end
      end

      def routed_issue_id(state, command_result)
        target_id = present_string(command_result.fetch("target_id", nil))
        return nil unless target_id

        if (issue = find_issue(state, target_id))
          issue.fetch("id")
        elsif (agent = find_agent(state, target_id))
          present_string(agent.fetch("issue_id", nil))
        elsif (goal = find_goal(state, target_id))
          present_string(goal.fetch("issue_id", nil))
        end
      end

      # A user prompt exists before its head chooses a route, so its initial log can carry only the
      # head id (unless the dashboard selection supplied a target up front). Once the batch lands,
      # add the accepted AgentTree destinations to that same originating line. Arrays are required:
      # one head may staff several workers, and every selected worker must retain the prompt.
      #
      # This deliberately ignores rejected/failed commands and non-AgentTree targets. A worker
      # contributes both itself and its durable issue, which keeps the prompt in either filter.
      def attribute_user_prompt_routes!(state, head_id, command_results)
        issue_ids = []
        agent_ids = []
        Array(command_results).each do |result|
          next unless result.is_a?(Hash) && result.fetch("status", nil) == "accepted"

          target_id = present_string(result.fetch("target_id", nil))
          next unless target_id

          if (agent = find_agent(state, target_id)) && agent.fetch("type", nil).to_s == "worker"
            agent_ids << agent.fetch("id").to_s
            issue_id = present_string(agent.fetch("issue_id", nil))
            issue_ids << issue_id if issue_id
          elsif (issue = find_issue(state, target_id))
            issue_ids << issue.fetch("id").to_s
          end
        end
        issue_ids.uniq!
        agent_ids.uniq!
        return false if issue_ids.empty? && agent_ids.empty?

        prompt_log = state.fetch("logs", []).reverse.find do |entry|
          next false unless entry.is_a?(Hash) && entry.fetch("source_type", nil).to_s == "user"

          details = entry.fetch("details", nil)
          details.is_a?(Hash) && details.fetch("head_id", nil).to_s == head_id.to_s
        end
        return false unless prompt_log

        details = prompt_log.fetch("details")
        details["routed_issue_ids"] = (Array(details["routed_issue_ids"]) + issue_ids).map(&:to_s).uniq unless issue_ids.empty?
        details["routed_agent_ids"] = (Array(details["routed_agent_ids"]) + agent_ids).map(&:to_s).uniq unless agent_ids.empty?
        true
      end

      # Head-proposed commands must reach the user the way typed slash command output does. This
      # is the head-side twin of `record_user_kernel_command_output`, and it uses the same
      # formatter: a command that already logged its own outcome (Prune, Recount, Kill,
      # SpawnWorker, and every rejection) is not repeated, while read-only commands are surfaced
      # here instead of staying buried inside the ApplyHeadResult envelope.
      def append_head_command_output_logs(state, head_id, command_results)
        command_output_bodies(command_results).map do |body, result|
          append_log(
            state,
            source_type: "kernel",
            source_id: head_id.to_s,
            level: result.fetch("status", nil) == "accepted" ? "info" : "warning",
            message: body,
            details: {
              "head_id" => head_id.to_s,
              "command_type" => result.fetch("command_type", nil),
              "kind" => "kernel_command_output",
              "presentation" => "cmd"
            }.merge(head_command_author_details(head_id)).compact
          )
        end
      end

      # Guardrails for head-proposed commands. Returns nil when the command may run, or a rejected
      # KernelCommandResult that is journaled and logged exactly like any other rejection.
      #
      # Policy:
      # - Ordinary housekeeping (Prune, Recount, DismissQuestion, killing one worker/issue, and
      #   every read-only command) runs on a clear user request, with no extra ceremony.
      # - Irreversible commands (ClearState, killing a whole project) additionally require the
      #   head to mark the command user-confirmed AND require the user's own message to be an
      #   unambiguous instruction. A vague prompt can therefore never wipe state or a project.
      # - Kernel-internal commands are never proposable.
      def head_command_guard_result(command, head:)
        return nil unless command.is_a?(Hash)

        command_type = canonical_command_type(value_at(command, "type", "command_type").to_s)
        command_id = value_at(command, "command_id", "id")
        payload = value_at(command, "payload")
        payload = {} unless payload.is_a?(Hash)
        head = {} unless head.is_a?(Hash)
        head_id = head.fetch("id", nil).to_s

        if HEAD_BLOCKED_COMMANDS.include?(command_type)
          return synchronized_state do
            rejected_result(
              command_id,
              command_type,
              "Head #{head_id} may not propose #{command_type}.",
              [HEAD_UNPROPOSABLE_COMMAND_REASON, "proposable commands: #{HEAD_PROPOSABLE_COMMANDS.join(", ")}"]
            )
          end
        end
        # Unknown command types continue through normal kernel dispatch and keep the established
        # `unknown_command` validation error. The explicit block above is only for known
        # kernel/parser internals; user-facing commands are enumerated for the head contract.

        guard = case command_type
                when "ClearState" then clear_state_head_guard(head, payload)
                when "Kill" then kill_head_guard(head, payload)
                when "PromptAgent" then prompt_agent_head_guard(head, payload)
                when "SpawnHead" then head_takeover_command_guard(head, payload)
                when "SpawnWorker" then worker_selection_guidance_spawn_guard(head, payload)
                when "GetSessionDefaults" then worker_selection_guidance_defaults_guard(head)
                end
        return nil unless guard

        synchronized_state do
          rejected_result(command_id, command_type, guard.fetch("message"), guard.fetch("errors"))
        end
      end

      def worker_selection_guidance_defaults_guard(head)
        return nil unless worker_spawning_guidance_for_head?(head)

        {
          "message" => "Future worker model and thinking defaults are unavailable while guidance-based selection is enabled.",
          "errors" => ["worker_selection_guidance_hides_defaults"]
        }
      end

      def worker_selection_guidance_spawn_guard(head, payload)
        return nil unless worker_spawning_guidance_for_head?(head)

        missing = []
        missing << "model" if blank?(value_at(payload, "model", "Model"))
        missing << "thinking_level" if blank?(value_at(payload, "thinking_level", "thinkingLevel", "ThinkingLevel"))
        return nil if missing.empty?

        {
          "message" => "Worker was not spawned because guidance-based selection requires an explicit model and thinking_level.",
          "errors" => [
            "worker_selection_guidance_requires_explicit_settings",
            "missing: #{missing.join(", ")}"
          ]
        }
      end

      def clear_state_head_guard(head, payload)
        confirmed = head_command_user_confirmed?(payload)
        user_message = head_record_user_message(head)
        explicit = HEAD_CLEAR_STATE_INSTRUCTION_PATTERN.match?(user_message)
        return nil if confirmed && explicit

        errors = []
        errors << "clear_state_requires_user_confirmation" unless confirmed
        errors << "clear_state_requires_explicit_user_instruction" unless explicit
        errors << "ask the user a confirmation question, then propose ClearState with \"confirmed_by_user\": true only when they explicitly ask to clear/reset/wipe Meringue state"
        {
          "message" => "ClearState was refused because the user did not unambiguously ask to reset Meringue state.",
          "errors" => errors
        }
      end

      def kill_head_guard(head, payload)
        target_id = present_string(value_at(payload, "target_id", "TargetID", "targetId", "id"))
        return nil unless target_id

        head_id = head.fetch("id", nil).to_s
        if target_id == head_id
          return {
            "message" => "Head #{head_id} may not kill itself while its own commands are being applied.",
            "errors" => ["head_cannot_kill_itself"]
          }
        end

        project = synchronized_state { find_project(normalized_state, target_id) }
        return nil unless project

        confirmed = head_command_user_confirmed?(payload)
        user_message = head_record_user_message(head)
        explicit = HEAD_KILL_INSTRUCTION_PATTERN.match?(user_message) && head_message_names_project?(user_message, project)
        return nil if confirmed && explicit

        errors = []
        errors << "project_kill_requires_user_confirmation" unless confirmed
        errors << "project_kill_requires_explicit_user_instruction" unless explicit
        errors << "ask the user a confirmation question, then propose Kill with \"confirmed_by_user\": true only when they explicitly name project #{project.fetch("id", target_id)} and ask to kill it"
        {
          "message" => "Kill was refused for project #{project.fetch("id", target_id)} because the user did not unambiguously ask to kill the whole project.",
          "errors" => errors
        }
      end

      # Prompting a head is a user recovery action, not something a head may trigger. A head may
      # explicitly hand its own still-routing result to one direct follow-up head, however; the
      # SpawnHead path claims that self predecessor before any replacement session runs.
      def prompt_agent_head_guard(head, payload)
        target_id = present_string(value_at(payload, "agent_id", "AgentID", "agentId"))
        return nil unless target_id

        target = synchronized_state { find_agent(normalized_state, target_id) }
        return nil unless target && target.fetch("type", nil) == "head"

        {
          "message" => "Head #{head.fetch("id", nil)} may not prompt head #{target.fetch("id")}; only the user can take over a head.",
          "errors" => ["head_cannot_prompt_head"]
        }
      end

      def head_takeover_command_guard(head, payload)
        takeover_id = present_string(value_at(payload, "_takeover_of_head_id", "takeover_of_head_id", "takeover_head_id", "takeoverHeadId"))
        follow_up_id = present_string(value_at(payload, "_follow_up_of_head_id", "follow_up_of_head_id", "follow_up_of_head", "follow_up_head_id", "followUpOfHeadID", "followUpOfHeadId", "followUpOfHead"))
        return nil if follow_up_id && Ids.same?(follow_up_id, head.fetch("id", nil))
        return nil unless takeover_id || follow_up_id

        target_id = takeover_id || follow_up_id
        {
          "message" => "Head #{head.fetch("id", nil)} may not take over head #{target_id}; only a direct self follow-up may consume its predecessor.",
          "errors" => ["head_cannot_prompt_head"]
        }
      end

      def head_command_user_confirmed?(payload)
        HEAD_CONFIRMATION_PAYLOAD_KEYS.any? do |key|
          value = value_at(payload, key)
          value == true || value.to_s.strip.downcase == "true"
        end
      end

      # The user's own words are the authoritative evidence for a destructive command. A head
      # cannot manufacture them: the kernel reads the message it recorded when it spawned the head.
      def head_for_input_submission(state, submission_id)
        state.fetch("agents").find do |agent|
          next false unless agent.fetch("type", nil) == "head"

          request = (agent.fetch("harness_metadata", {}) || {}).fetch("head_request", {}) || {}
          request.fetch("input_submission_id", nil).to_s == submission_id.to_s
        end
      end

      def head_record_user_message(head)
        metadata = head.is_a?(Hash) ? (head.fetch("harness_metadata", {}) || {}) : {}
        request = metadata.is_a?(Hash) ? (metadata.fetch("head_request", {}) || {}) : {}
        request.is_a?(Hash) ? request.fetch("user_message", "").to_s : ""
      end

      def head_message_names_project?(user_message, project)
        message = user_message.to_s.downcase
        project_id = project.fetch("id", "").to_s.downcase
        name = project.fetch("name", "").to_s.downcase
        return true if !project_id.empty? && message.match?(/\b#{Regexp.escape(project_id)}\b/)
        return true if name.length >= 3 && message.include?(name)

        false
      end
    end
  end
end
