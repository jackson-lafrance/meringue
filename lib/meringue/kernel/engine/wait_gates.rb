# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Running a queued worker's gate command and recording what its outcome means.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # One reconcile pass over every armed, pending command gate. Both queued workers and
      # completion continuations use this pass: a gate is a persisted kernel wait predicate, not a
      # reason to spend a harness session. Commands never run while the state lock is held. The pass
      # claims due gates, releases the lock, runs them under one shared budget, then merges outcomes
      # into the current owner record. Owner-specific resolvers remain the only places that start a
      # worker, spawn a head, or cancel work.
      def check_kernel_wait_gates(trigger:)
        claim = synchronized_state do
          state = normalized_state
          now = timestamp
          changed = false
          due = []
          results = []
          state.fetch("agents").each do |agent|
            if waiting_deferred_worker?(agent)
              deferred = deferred_spawn_metadata(agent)
              gate = deferred_command_gate(deferred)
              if gate && gate_pending?(gate) && gate_armed?(gate)
                if gate_expired?(gate, now)
                  results << expire_deferred_worker_gate_in_state!(state, agent, deferred, gate, now: now, trigger: trigger)
                  changed = true
                elsif gate_due?(gate, now)
                  claimed = gate.merge("next_check_at" => gate_next_check_at(now, gate)).compact
                  agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
                    "deferred_spawn" => deferred.merge("command_gate" => claimed)
                  )
                  agent["updated_at"] = now
                  changed = true
                  due << {
                    "owner_type" => "deferred_worker",
                    "agent_id" => agent.fetch("id"),
                    "gate" => deep_copy(claimed),
                    "cwd" => deferred_gate_cwd(state, agent, claimed)
                  }
                end
              end
            end

            continuation = worker_completion_continuation(agent)
            gate = completion_continuation_gate(continuation)
            next unless pending_completion_continuation?(agent) && gate && gate_pending?(gate) && gate_armed?(gate)

            if gate_expired?(gate, now)
              results << expire_completion_continuation_gate_in_state!(state, agent, continuation, gate, now: now, trigger: trigger)
              changed = true
              next
            end
            next unless gate_due?(gate, now)

            # Moving next_check_at first is the cross-process claim. A crash may delay the next
            # check by one interval, but can never turn a condition into a hot loop or duplicate it
            # across two Meringue instances.
            claimed = gate.merge("next_check_at" => gate_next_check_at(now, gate)).compact
            agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
              "completion_continuation" => continuation.merge("command_gate" => claimed)
            )
            agent["updated_at"] = now
            changed = true
            due << {
              "owner_type" => "completion_continuation",
              "agent_id" => agent.fetch("id"),
              "gate" => deep_copy(claimed),
              "cwd" => deferred_gate_cwd(state, agent, claimed)
            }
          end
          if changed
            touch_state!(state, now)
            store.save(state)
          end
          { "due" => due, "results" => results.compact }
        end

        results = claim.fetch("results")
        deadline = monotonic_time + DEFERRED_WORKER_GATE_BUDGET_SECONDS
        claim.fetch("due").each do |entry|
          break if monotonic_time > deadline

          outcome = run_deferred_gate_command(entry)
          recorded = if entry.fetch("owner_type", "deferred_worker") == "completion_continuation"
                       record_completion_continuation_gate_outcome(entry, outcome, trigger: trigger)
                     else
                       record_deferred_gate_outcome(entry, outcome, trigger: trigger)
                     end
          results << recorded if recorded
        end
        results
      end

      def gate_expired?(gate, now)
        deadline = parse_time_or_nil(gate.fetch("expires_at", nil))
        current = parse_time_or_nil(now)
        return false unless deadline && current

        current >= deadline
      end

      def gate_due?(gate, now)
        due_at = parse_time_or_nil(gate.fetch("next_check_at", nil))
        current = parse_time_or_nil(now)
        return true unless due_at && current

        current >= due_at
      end

      def gate_next_check_at(now, gate)
        current = parse_time_or_nil(now)
        return nil unless current

        interval = gate.fetch("interval_seconds", DEFERRED_WORKER_GATE_DEFAULT_INTERVAL_SECONDS).to_i
        (current + [interval, DEFERRED_WORKER_GATE_MIN_INTERVAL_SECONDS].max).iso8601
      end

      # A queued worker's workspace is only planned until it starts, so `project_root` is the
      # default and also the fallback when a `workspace` gate has no directory yet.
      def deferred_gate_cwd(state, agent, gate)
        if gate.fetch("cwd", DEFERRED_WORKER_GATE_DEFAULT_CWD).to_s == "workspace"
          workspace = present_string(agent.fetch("workspace_path", nil))
          return workspace if workspace && Dir.exist?(workspace)
        end
        project = find_project(state, agent.fetch("project_id", nil))
        present_string(project && project.fetch("root_path", nil))
      end

      def run_deferred_gate_command(entry)
        gate = entry.fetch("gate")
        cwd = present_string(entry.fetch("cwd", nil))
        unless cwd
          return { "passed" => false, "unusable" => true, "error" => "the wait condition has no directory to run in", "checked_at" => timestamp }
        end

        metric_probe.check_gate(
          command: gate.fetch("command", nil),
          cwd: cwd,
          timeout: gate.fetch("timeout_seconds", DEFERRED_WORKER_GATE_DEFAULT_TIMEOUT_SECONDS),
          expect: gate.fetch("expect", DEFERRED_WORKER_GATE_DEFAULT_EXPECT),
          pattern: gate.fetch("pattern", nil)
        ).merge("cwd" => cwd, "checked_at" => timestamp)
      rescue StandardError => e
        { "passed" => false, "unusable" => true, "error" => sanitized_error_message(e), "cwd" => cwd, "checked_at" => timestamp }
      end

      def record_deferred_gate_outcome(entry, outcome, trigger:)
        agent_id = entry.fetch("agent_id")
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next nil unless agent && waiting_deferred_worker?(agent)

          deferred = deferred_spawn_metadata(agent)
          gate = deferred_command_gate(deferred)
          next nil unless gate && gate_pending?(gate)

          now = timestamp
          merged = merged_wait_gate_outcome(gate, outcome, now: now)
          updated = merged.fetch("gate")
          unusable = merged.fetch("unusable")
          passed = merged.fetch("passed")
          consecutive = merged.fetch("consecutive_unusable_checks")
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "deferred_spawn" => deferred.merge("command_gate" => updated)
          )
          agent["updated_at"] = now
          log_ids = []
          if unusable
            log_ids = append_log(
              state,
              source_type: "kernel",
              source_id: agent_id,
              level: "warning",
              message: "Wait condition #{deferred_gate_label(updated)} for queued worker #{agent_id} could not be evaluated: " \
                       "#{updated.fetch("last_problem", "unknown problem")} (#{consecutive}/#{DEFERRED_WORKER_GATE_UNUSABLE_LIMIT}).",
              details: {
                "agent_id" => agent_id,
                "issue_id" => agent.fetch("issue_id", nil),
                "after_command" => updated.fetch("command", nil),
                "after_command_state" => updated.fetch("state", nil),
                "consecutive_unusable_checks" => consecutive,
                "resolution" => "gate_check",
                "trigger" => trigger
              }.compact
            )
          end
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "CheckDeferredWorkerGate",
            agent_id,
            "Checked wait condition #{deferred_gate_label(updated)} for queued worker #{agent_id}: #{updated.fetch("state")}.",
            {
              "resolution" => "gate_check",
              "agent_id" => agent_id,
              "after_command" => updated.fetch("command", nil),
              "after_command_state" => updated.fetch("state", nil),
              "checks" => updated.fetch("checks", 0),
              "passed" => passed,
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end

      def expire_completion_continuation_gate_in_state!(state, agent, continuation, gate, now:, trigger:)
        agent_id = agent.fetch("id")
        expired = gate.merge("state" => DEFERRED_GATE_STATE_EXPIRED, "expired_at" => now)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          "completion_continuation" => continuation.merge("command_gate" => expired)
        )
        agent["updated_at"] = now
        message = "Wait condition #{deferred_gate_label(expired)} for worker #{agent_id}'s completion continuation did not pass within " \
                  "#{expired.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s."
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "warning",
          message: message,
          details: {
            "agent_id" => agent_id,
            "issue_id" => agent.fetch("issue_id", nil),
            "after_command" => expired.fetch("command", nil),
            "after_command_state" => DEFERRED_GATE_STATE_EXPIRED,
            "checks" => expired.fetch("checks", 0),
            "if_gate_expires" => expired.fetch("if_gate_expires", deferred_worker_default_failure_policy),
            "resolution" => "completion_continuation_gate_expired",
            "trigger" => trigger
          }.compact
        )
        accepted_result(
          nil,
          "CheckCompletionContinuationGate",
          agent_id,
          message,
          {
            "resolution" => "completion_continuation_gate_expired",
            "agent_id" => agent_id,
            "after_command" => expired.fetch("command", nil),
            "after_command_state" => DEFERRED_GATE_STATE_EXPIRED,
            "trigger" => trigger
          }.compact,
          log_ids
        )
      end

      def expire_deferred_worker_gate_in_state!(state, agent, deferred, gate, now:, trigger:)
        agent_id = agent.fetch("id")
        expired = gate.merge("state" => DEFERRED_GATE_STATE_EXPIRED, "expired_at" => now)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          "deferred_spawn" => deferred.merge("command_gate" => expired)
        )
        agent["updated_at"] = now
        message = "Wait condition #{deferred_gate_label(expired)} for queued worker #{agent_id} did not pass within " \
                  "#{expired.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s."
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "warning",
          message: message,
          details: {
            "agent_id" => agent_id,
            "issue_id" => agent.fetch("issue_id", nil),
            "after_command" => expired.fetch("command", nil),
            "after_command_state" => DEFERRED_GATE_STATE_EXPIRED,
            "checks" => expired.fetch("checks", 0),
            "if_gate_expires" => expired.fetch("if_gate_expires", deferred_worker_default_failure_policy),
            "resolution" => "gate_expired",
            "trigger" => trigger
          }.compact
        )
        accepted_result(
          nil,
          "CheckDeferredWorkerGate",
          agent_id,
          message,
          {
            "resolution" => "gate_expired",
            "agent_id" => agent_id,
            "after_command" => expired.fetch("command", nil),
            "after_command_state" => DEFERRED_GATE_STATE_EXPIRED,
            "trigger" => trigger
          }.compact,
          log_ids
        )
      end

      def record_completion_continuation_gate_outcome(entry, outcome, trigger:)
        agent_id = entry.fetch("agent_id")
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next nil unless agent && pending_completion_continuation?(agent)

          continuation = worker_completion_continuation(agent)
          gate = completion_continuation_gate(continuation)
          next nil unless gate && gate_pending?(gate)

          now = timestamp
          merged = merged_wait_gate_outcome(gate, outcome, now: now)
          updated = merged.fetch("gate")
          unusable = merged.fetch("unusable")
          passed = merged.fetch("passed")
          consecutive = merged.fetch("consecutive_unusable_checks")
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "completion_continuation" => continuation.merge("command_gate" => updated)
          )
          agent["updated_at"] = now
          log_ids = []
          if unusable
            log_ids = append_log(
              state,
              source_type: "kernel",
              source_id: agent_id,
              level: "warning",
              message: "Wait condition #{deferred_gate_label(updated)} for worker #{agent_id}'s completion continuation " \
                       "could not be evaluated: #{updated.fetch("last_problem", "unknown problem")} " \
                       "(#{consecutive}/#{DEFERRED_WORKER_GATE_UNUSABLE_LIMIT}).",
              details: {
                "agent_id" => agent_id,
                "issue_id" => agent.fetch("issue_id", nil),
                "after_command" => updated.fetch("command", nil),
                "after_command_state" => updated.fetch("state", nil),
                "consecutive_unusable_checks" => consecutive,
                "resolution" => "completion_continuation_gate_check",
                "trigger" => trigger
              }.compact
            )
          end
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "CheckCompletionContinuationGate",
            agent_id,
            "Checked wait condition #{deferred_gate_label(updated)} for worker #{agent_id}'s completion continuation: #{updated.fetch("state")}.",
            {
              "resolution" => "completion_continuation_gate_check",
              "agent_id" => agent_id,
              "after_command" => updated.fetch("command", nil),
              "after_command_state" => updated.fetch("state", nil),
              "checks" => updated.fetch("checks", 0),
              "passed" => passed,
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end

      # Owner-independent state transition for one bounded check. Keeping this in one place is what
      # makes `after_command` mean the same thing on queued workers and completion continuations;
      # owner-specific methods above only decide where to persist it and how to describe it.
      def merged_wait_gate_outcome(gate, outcome, now:)
        unusable = !!outcome.fetch("unusable", false) || !present_string(outcome.fetch("error", nil)).nil?
        passed = !!outcome.fetch("passed", false) && !unusable
        consecutive = unusable ? gate.fetch("consecutive_unusable_checks", 0).to_i + 1 : 0
        updated = gate.merge(
          "checks" => gate.fetch("checks", 0).to_i + 1,
          "last_checked_at" => now,
          "last_check" => gate_check_record(outcome),
          "consecutive_unusable_checks" => consecutive,
          "last_problem" => unusable ? gate_problem_text(outcome) : nil
        ).compact
        if passed
          updated["state"] = DEFERRED_GATE_STATE_SATISFIED
          updated["satisfied_at"] = now
        elsif consecutive >= DEFERRED_WORKER_GATE_UNUSABLE_LIMIT
          # A gate that cannot be run can never pass. Give up loudly rather than polling a broken
          # command until the total wait budget runs out hours from now.
          updated["state"] = DEFERRED_GATE_STATE_UNAVAILABLE
          updated["unavailable_at"] = now
        end
        {
          "gate" => updated,
          "unusable" => unusable,
          "passed" => passed,
          "consecutive_unusable_checks" => consecutive
        }
      end

      def gate_check_record(outcome)
        outcome.slice(
          "exit_status", "timed_out", "stdout_tail", "stderr_tail", "error", "parse_error", "passed", "cwd", "checked_at"
        ).compact
      end

      def gate_problem_text(outcome)
        return "the wait condition timed out" if outcome.fetch("timed_out", false)
        return outcome.fetch("parse_error") if present_string(outcome.fetch("parse_error", nil))
        return outcome.fetch("error") if present_string(outcome.fetch("error", nil))

        "the wait condition could not be evaluated"
      end
    end
  end
end
