# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # The head a finished worker can trigger, so a completion continues into more work exactly once.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def resolve_completion_continuations(trigger:, only_agent_id: nil)
        claims = claim_completion_continuations(trigger: trigger, only_agent_id: only_agent_id)
        claims.map do |claim|
          claim.fetch("result", nil) || trigger_completion_continuation_head(claim, trigger: trigger)
        end
      end

      def claim_completion_continuations(trigger:, only_agent_id: nil)
        synchronized_state do
          state = normalized_state
          now = timestamp
          claims = []
          changed = false
          state.fetch("agents").each do |agent|
            next unless agent.fetch("type", nil) == "worker"
            next if only_agent_id && !Ids.same?(agent.fetch("id", nil), only_agent_id)

            continuation = worker_completion_continuation(agent)
            next unless continuation
            next unless agent.fetch("status", nil) == "completed"

            state_value = continuation.fetch("state", nil).to_s
            existing_head = existing_completion_continuation_head(state, agent)
            if existing_head
              next if continuation_terminal_state?(state_value)

              updated = continuation.merge(
                "state" => COMPLETION_CONTINUATION_STATE_TRIGGERED,
                "head_id" => existing_head.fetch("id"),
                "recovered_existing_head_at" => now
              ).compact
              agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
              agent["updated_at"] = now
              claims << completion_continuation_decision(agent, updated, existing_head: deep_copy(existing_head))
              changed = true
              next
            end

            next unless state_value == COMPLETION_CONTINUATION_STATE_WAITING ||
                        (state_value == COMPLETION_CONTINUATION_STATE_TRIGGERING && !completion_continuation_owned_by_other_live_instance?(continuation))

            gate = completion_continuation_gate(continuation)
            if gate
              gate_state = gate.fetch("state", DEFERRED_GATE_STATE_PENDING).to_s
              if gate_state == DEFERRED_GATE_STATE_PENDING
                unless gate_armed?(gate)
                  armed = armed_deferred_gate(gate, now: now)
                  updated = continuation.merge("command_gate" => armed)
                  agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
                  agent["updated_at"] = now
                  refresh_worker_parent_statuses!(state, agent, now)
                  message = "Completion continuation for worker #{agent.fetch("id")} is queued until wait condition " \
                            "#{deferred_gate_label(armed)} passes."
                  log_ids = append_log(
                    state,
                    source_type: "kernel",
                    source_id: agent.fetch("id"),
                    level: "info",
                    message: message,
                    details: {
                      "agent_id" => agent.fetch("id"),
                      "issue_id" => agent.fetch("issue_id", nil),
                      "after_command" => armed.fetch("command", nil),
                      "after_command_state" => armed.fetch("state", nil),
                      "after_command_expires_at" => armed.fetch("expires_at", nil),
                      "resolution" => "completion_continuation_gate_armed",
                      "trigger" => trigger
                    }.compact
                  )
                  claims << {
                    "result" => accepted_result(
                      nil,
                      "QueueCompletionContinuation",
                      agent.fetch("id"),
                      message,
                      { "agent_id" => agent.fetch("id"), "continuation" => deep_copy(updated) },
                      log_ids
                    )
                  }
                  changed = true
                end
                next
              end

              if DEFERRED_GATE_UNRESOLVED_STATES.include?(gate_state) &&
                 gate.fetch("if_gate_expires", deferred_worker_default_failure_policy).to_s != "run"
                updated = continuation.merge(
                  "state" => COMPLETION_CONTINUATION_STATE_CANCELLED,
                  "cancelled_at" => now,
                  "cancel_reason" => gate_state == DEFERRED_GATE_STATE_EXPIRED ? "gate_expired" : "gate_unavailable"
                )
                agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
                agent["updated_at"] = now
                refresh_worker_parent_statuses!(state, agent, now)
                message = completion_continuation_gate_cancellation_message(agent.fetch("id"), gate)
                log_ids = append_log(
                  state,
                  source_type: "kernel",
                  source_id: agent.fetch("id"),
                  level: "warning",
                  message: message,
                  details: {
                    "agent_id" => agent.fetch("id"),
                    "issue_id" => agent.fetch("issue_id", nil),
                    "after_command" => gate.fetch("command", nil),
                    "after_command_state" => gate_state,
                    "resolution" => "completion_continuation_gate_cancelled",
                    "trigger" => trigger
                  }.compact
                )
                claims << {
                  "result" => accepted_result(
                    nil,
                    "CancelCompletionContinuation",
                    agent.fetch("id"),
                    message,
                    { "agent_id" => agent.fetch("id"), "continuation" => deep_copy(updated) },
                    log_ids
                  )
                }
                changed = true
                next
              end
            end

            updated = continuation.merge(
              "state" => COMPLETION_CONTINUATION_STATE_TRIGGERING,
              "trigger" => trigger,
              "triggered_at" => continuation.fetch("triggered_at", nil) || now,
              "trigger_attempts" => continuation.fetch("trigger_attempts", 0).to_i + 1,
              **instance_ownership_metadata
            ).compact
            agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
            agent["updated_at"] = now
            claims << completion_continuation_decision(agent, updated)
            changed = true
          end
          if changed
            touch_state!(state, now)
            store.save(state)
          end
          claims
        end
      end

      def continuation_terminal_state?(state)
        [
          COMPLETION_CONTINUATION_STATE_TRIGGERED,
          COMPLETION_CONTINUATION_STATE_APPLIED,
          COMPLETION_CONTINUATION_STATE_FAILED,
          COMPLETION_CONTINUATION_STATE_CANCELLED
        ].include?(state.to_s)
      end

      def completion_continuation_owned_by_other_live_instance?(continuation)
        !other_live_instance_pid(
          continuation.fetch("owner_instance_id", nil),
          continuation.fetch("owner_instance_pid", nil),
          continuation.fetch("owner_instance_started_at", nil)
        ).nil?
      end

      def existing_completion_continuation_head(state, worker)
        worker_id = worker.fetch("id", nil).to_s
        state.fetch("agents").find do |agent|
          next false unless agent.fetch("type", nil) == "head"

          trigger = (agent.fetch("harness_metadata", {}) || {}).fetch("completion_trigger", nil)
          trigger.is_a?(Hash) && trigger.fetch("worker_agent_id", nil).to_s == worker_id
        end
      end

      def checkpoint_completion_continuation_from_head_result!(state, head, now:)
        metadata = head.is_a?(Hash) ? (head.fetch("harness_metadata", {}) || {}) : {}
        trigger = metadata.fetch("completion_trigger", nil)
        return false unless trigger.is_a?(Hash) && trigger.fetch("kind", nil).to_s == "worker_completion"

        worker = find_agent(state, trigger.fetch("worker_agent_id", nil))
        return false unless worker && worker.fetch("type", nil) == "worker"

        continuation = worker_completion_continuation(worker)
        return false unless continuation

        updated = continuation.merge(
          "state" => COMPLETION_CONTINUATION_STATE_APPLIED,
          "head_id" => head.fetch("id"),
          "trigger" => trigger.fetch("trigger", continuation.fetch("trigger", nil)),
          "apply_head_result_status" => "accepted",
          "head_result_applied_at" => now,
          "completed_at" => now
        ).compact
        worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
        worker["updated_at"] = now
        refresh_worker_parent_statuses!(state, worker, now)
        true
      end

      def completion_continuation_decision(agent, continuation, existing_head: nil)
        {
          "agent" => deep_copy(agent),
          "continuation" => deep_copy(continuation),
          "existing_head" => existing_head
        }.compact
      end

      def trigger_completion_continuation_head(decision, trigger:)
        agent = decision.fetch("agent")
        continuation = decision.fetch("continuation")
        existing_head = decision.fetch("existing_head", nil)
        spawn_result = if existing_head
                         accepted_result(
                           nil,
                           "SpawnCompletionHead",
                           existing_head.fetch("id"),
                           "Completion head #{existing_head.fetch("id")} already exists for worker #{agent.fetch("id")}",
                           existing_head,
                           []
                         )
                       else
                         spawn_completion_head(agent, continuation, trigger: trigger)
                       end
        head_id = present_string(spawn_result.fetch("target_id", nil))
        apply_result = apply_completion_head_result(head_id) if spawn_result.fetch("status", nil) == "accepted" && head_id
        finalize_completion_continuation(agent.fetch("id"), spawn_result: spawn_result, apply_result: apply_result, trigger: trigger)
      rescue StandardError => e
        record_completion_continuation_failure(agent.fetch("id"), e, trigger: trigger)
      end

      def spawn_completion_head(agent, continuation, trigger:)
        spawn_head(
          nil,
          "SpawnHead",
          {
            "user_message" => completion_continuation_user_message(agent, continuation),
            "log_message" => "Worker #{agent.fetch("id")} completed; routing follow-on work.",
            "_log_source_type" => "kernel",
            "_log_source_id" => agent.fetch("id"),
            "_completion_trigger" => {
              "kind" => "worker_completion",
              "worker_agent_id" => agent.fetch("id"),
              "issue_id" => agent.fetch("issue_id", nil),
              "project_id" => agent.fetch("project_id", nil),
              "trigger" => trigger
            }.compact
          }
        )
      end

      def apply_completion_head_result(head_id)
        head = agent_record_snapshot(head_id)
        return nil unless head

        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", nil)
        return nil unless head_result.is_a?(Hash)
        return already_applied_head_result(nil, "ApplyHeadResult", head_id, metadata) if present_string(metadata.fetch("head_result_applied_at", nil))

        @head_result_mutex.synchronize do
          apply_head_result(nil, "ApplyHeadResult", "head_id" => head_id, "head_result" => head_result)
        end
      end

      def finalize_completion_continuation(agent_id, spawn_result:, apply_result:, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return spawn_result unless agent

          continuation = worker_completion_continuation(agent) || {}
          now = timestamp
          head_id = present_string(spawn_result.fetch("target_id", nil))
          spawn_accepted = spawn_result.fetch("status", nil) == "accepted"
          apply_status = apply_result&.fetch("status", nil)
          state_value = if !spawn_accepted
                          COMPLETION_CONTINUATION_STATE_FAILED
                        elsif apply_result && apply_status != "accepted"
                          COMPLETION_CONTINUATION_STATE_FAILED
                        elsif apply_status == "accepted"
                          COMPLETION_CONTINUATION_STATE_APPLIED
                        else
                          COMPLETION_CONTINUATION_STATE_TRIGGERED
                        end
          updated = continuation.merge(
            "state" => state_value,
            "head_id" => head_id,
            "trigger" => trigger,
            "spawn_head_status" => spawn_result.fetch("status", nil),
            "spawn_head_message" => spawn_result.fetch("message", nil),
            "apply_head_result_status" => apply_status,
            "apply_head_result_message" => apply_result&.fetch("message", nil),
            "completed_at" => now
          ).compact
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
          agent["updated_at"] = now
          refresh_worker_parent_statuses!(state, agent, now)
          level = state_value == COMPLETION_CONTINUATION_STATE_FAILED ? "error" : "info"
          message = if state_value == COMPLETION_CONTINUATION_STATE_FAILED
                      "Completion continuation for worker #{agent_id} failed#{head_id ? " after spawning #{head_id}" : ""}."
                    else
                      "Spawned head #{head_id} after worker #{agent_id} completed."
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: level,
            message: message,
            details: {
              "agent_id" => agent_id,
              "head_id" => head_id,
              "trigger" => trigger,
              "state" => state_value,
              "spawn_head_status" => spawn_result.fetch("status", nil),
              "apply_head_result_status" => apply_status
            }.compact
          )
          touch_state!(state, now)
          store.save(state)

          status = state_value == COMPLETION_CONTINUATION_STATE_FAILED ? "failed" : "accepted"
          result_payload = {
            "agent_id" => agent_id,
            "head_id" => head_id,
            "continuation" => updated,
            "spawn_head_result" => spawn_result,
            "apply_head_result" => apply_result
          }.compact
          if status == "accepted"
            accepted_result(nil, "SpawnCompletionHead", head_id, message, result_payload, (Array(spawn_result.fetch("log_entry_ids", [])) + Array(apply_result&.fetch("log_entry_ids", [])) + log_ids).uniq)
          else
            failure = failed_result(nil, "SpawnCompletionHead", message, [spawn_result.fetch("message", nil), apply_result&.fetch("message", nil)].compact)
            failure.merge("log_entry_ids" => (Array(failure.fetch("log_entry_ids", [])) + log_ids).uniq)
          end
        end
      end

      def record_completion_continuation_failure(agent_id, error, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return failed_result(nil, "SpawnCompletionHead", "Completion continuation failed: #{sanitized_error_message(error)}", [error.class.name, sanitized_error_message(error)]) unless agent

          now = timestamp
          continuation = worker_completion_continuation(agent) || {}
          updated = continuation.merge(
            "state" => COMPLETION_CONTINUATION_STATE_FAILED,
            "trigger" => trigger,
            "error_class" => error.class.name,
            "error_message" => sanitized_error_message(error),
            "failed_at" => now
          ).compact
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
          agent["updated_at"] = now
          refresh_worker_parent_statuses!(state, agent, now)
          message = "Completion continuation for worker #{agent_id} failed: #{sanitized_error_message(error)}"
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: "error",
            message: message,
            details: { "agent_id" => agent_id, "trigger" => trigger, "error" => error_payload(error) }
          )
          touch_state!(state, now)
          store.save(state)
          failure = failed_result(nil, "SpawnCompletionHead", message, [error.class.name, sanitized_error_message(error)])
          failure.merge("log_entry_ids" => (Array(failure.fetch("log_entry_ids", [])) + log_ids).uniq)
        end
      end

      def completion_continuation_user_message(agent, continuation)
        metadata = agent.fetch("harness_metadata", {}) || {}
        lines = [
          "Meringue kernel continuation: worker #{agent.fetch("id")} completed and requested follow-on head routing.",
          "Use the worker's final result as context, then return a HeadResult with any follow-on kernel commands that should run now.",
          "Do not launch a worker merely to re-check a condition, and do not ask one to poll Meringue state, sleep, or wait. Use kernel commands such as SpawnWorker, PromptAgent, after_agent_id, after_command, or questions instead.",
          "",
          "Worker:",
          "- id: #{agent.fetch("id")}",
          "- issue_id: #{agent.fetch("issue_id", nil)}",
          "- project_id: #{agent.fetch("project_id", nil)}",
          "- title: #{metadata.fetch("title", nil)}",
          "- workspace_branch: #{agent.fetch("workspace_branch", nil)}",
          "",
          "Continuation request:",
          continuation.fetch("prompt").to_s
        ]
        if continuation.fetch("include_worker_result", true)
          lines.concat([
            "",
            "Worker final result:",
            present_string(metadata.fetch("last_assistant_text", nil)) || "(no final assistant text was recorded)"
          ])
        end
        gate = completion_continuation_gate(continuation)
        lines.concat(completion_continuation_gate_context(gate)) if gate
        lines.join("\n")
      end

      def completion_continuation_gate(continuation)
        gate = continuation.is_a?(Hash) ? continuation.fetch("command_gate", nil) : nil
        gate.is_a?(Hash) ? gate : nil
      end

      def completion_continuation_gate_context(gate)
        last = gate.fetch("last_check", nil)
        last = {} unless last.is_a?(Hash)
        output = present_string([last.fetch("stdout_tail", nil), last.fetch("stderr_tail", nil)].compact.join("\n"))
        state_text = case gate.fetch("state", nil).to_s
                     when DEFERRED_GATE_STATE_EXPIRED
                       "The condition did not pass within its #{gate.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s budget; routing is running because if_gate_expires is \"run\"."
                     when DEFERRED_GATE_STATE_UNAVAILABLE
                       "The condition could not be evaluated (#{gate.fetch("last_problem", "unknown problem")}); routing is running because if_gate_expires is \"run\"."
                     else
                       "The condition passed; this is why follow-on routing is running now."
                     end
        [
          "",
          "Completion wait condition: #{deferred_gate_label(gate)}",
          "Command: #{gate.fetch("command", "(unknown)")}",
          "Checked #{gate.fetch("checks", 0).to_i} time(s); last exit status: #{last.fetch("exit_status", "unknown")}",
          state_text,
          output ? "Last output:" : "Last output: none was captured.",
          output ? truncate_gate_output(output) : nil
        ].compact
      end

      def completion_continuation_gate_cancellation_message(agent_id, gate)
        label = deferred_gate_label(gate)
        if gate.fetch("state", nil).to_s == DEFERRED_GATE_STATE_UNAVAILABLE
          return "Cancelled completion continuation for worker #{agent_id} because its wait condition #{label} " \
                 "could not be run #{DEFERRED_WORKER_GATE_UNUSABLE_LIMIT} times in a row."
        end

        "Cancelled completion continuation for worker #{agent_id} because its wait condition #{label} did not pass within " \
          "#{gate.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s."
      end
    end
  end
end
