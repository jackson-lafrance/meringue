# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Deciding what happens to a queued worker once its predecessor settles: activate, repoint,
      # arm its gate, or cancel it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # The one resolution path for queued dependents. It is called from the worker-settle path,
      # from the reconciliation pass, and after a prune, so no dedicated thread is needed. Bounded
      # iteration lets one call settle a whole chain (a cancelled dependent cancels its own
      # dependents) without ever looping on a record it cannot change.
      def resolve_deferred_workers(trigger:)
        results = []
        (DEFERRED_WORKER_MAX_CHAIN_DEPTH + 1).times do
          decisions = synchronized_state do
            state = normalized_state
            state.fetch("agents").filter_map do |agent|
              next unless waiting_deferred_worker?(agent)

              # Deliberately not filtered by instance ownership. Nothing is in flight for a waiting
              # record, so any instance may resolve it; the atomic waiting -> activating flip below is
              # what keeps activation exactly-once. Skipping another instance's records here would
              # instead let a dependency sit forever when that instance never reconciles again.
              deferred_worker_resolution(state, agent)
            end
          end
          break if decisions.empty?

          applied = decisions.filter_map { |decision| apply_deferred_worker_resolution(decision, trigger: trigger) }
          results.concat(applied)
          break if applied.empty?
        end
        results
      end

      # Every predicate a queued worker carries is resolved here. The agent gate decides first,
      # because a command gate behind a predecessor must not be polled until that predecessor has
      # settled; only when the agent side says "go" does the command gate get a say.
      def deferred_worker_resolution(state, agent)
        deferred = deferred_spawn_metadata(agent)
        recorded_id = deferred_worker_after_agent_id(agent)
        gate = deferred_command_gate(deferred)
        base = {
          "agent_id" => agent.fetch("id"),
          "issue_id" => agent.fetch("issue_id", nil),
          "after_agent_id" => recorded_id,
          "if_predecessor_fails" => deferred.fetch("if_predecessor_fails", deferred_worker_default_failure_policy)
        }
        decision = if recorded_id
                     deferred_predecessor_resolution(state, agent, base, recorded_id)
                   elsif gate
                     # Gate-only worker: nothing to wait for but the command.
                     base.merge("kind" => "activate", "predecessor" => nil)
                   else
                     base.merge(
                       "kind" => "cancel",
                       "reason" => "predecessor_reference_missing",
                       "message" => "Cancelled queued worker #{agent.fetch("id")} because it no longer records which agent it was waiting for."
                     )
                   end
        return decision unless gate && decision.is_a?(Hash) && decision.fetch("kind", nil) == "activate"

        deferred_gate_resolution(decision, base, gate)
      end

      # The command-gate half of the decision, reached only once the agent half says "go".
      def deferred_gate_resolution(decision, base, gate)
        case gate.fetch("state", DEFERRED_GATE_STATE_PENDING).to_s
        when DEFERRED_GATE_STATE_SATISFIED
          decision.merge("gate" => deep_copy(gate))
        when *DEFERRED_GATE_UNRESOLVED_STATES
          if gate.fetch("if_gate_expires", deferred_worker_default_failure_policy).to_s == "run"
            decision.merge("gate" => deep_copy(gate), "gate_unresolved" => true)
          else
            base.merge(
              "kind" => "cancel",
              "reason" => gate.fetch("state").to_s == DEFERRED_GATE_STATE_EXPIRED ? "gate_expired" : "gate_unavailable",
              "gate" => deep_copy(gate),
              "message" => deferred_gate_cancellation_message(base.fetch("agent_id"), gate)
            )
          end
        else
          # Still pending. Arming is what starts its wait budget and makes it due for a check;
          # after that the worker simply keeps waiting until a poll changes the gate's state.
          return base.merge("kind" => "arm_gate", "gate" => deep_copy(gate)) unless gate_armed?(gate)

          nil
        end
      end

      def deferred_predecessor_resolution(state, agent, base, recorded_id)
        predecessor = deferred_effective_predecessor(state, recorded_id)
        unless predecessor
          return base.merge(
            "kind" => "cancel",
            "reason" => "predecessor_missing",
            "message" => "Cancelled queued worker #{agent.fetch("id")} because #{recorded_id} is no longer in Meringue state."
          )
        end

        predecessor_id = predecessor.fetch("id")
        repointed = !Ids.same?(predecessor_id, recorded_id)
        status = predecessor.fetch("status", nil).to_s
        activation = base.merge(
          "kind" => "activate",
          "predecessor" => deep_copy(predecessor),
          "predecessor_status" => status,
          "repointed_from_agent_id" => repointed ? recorded_id : nil
        ).compact
        waiting = if repointed
                    base.merge(
                      "kind" => "repoint",
                      "predecessor" => deep_copy(predecessor),
                      "message" => deferred_repoint_message(agent.fetch("id"), recorded_id, predecessor_id)
                    )
                  end
        case status
        when "completed"
          activation
        when "errored"
          if base.fetch("if_predecessor_fails") == "run"
            activation
          elsif deferred_predecessor_can_still_finish?(predecessor)
            # The predecessor did not fail its work: its turn was cut short by a transport failure
            # and can still be continued, so a dropped connection must not permanently cancel the
            # work queued behind it. Keep waiting; killing the predecessor still cancels the chain.
            waiting
          elsif worker_harness_process_exited?(predecessor)
            base.merge(
              "kind" => "cancel",
              "reason" => "predecessor_harness_process_exited",
              "message" => "Cancelled queued worker #{agent.fetch("id")} because #{predecessor_id}'s agent session " \
                           "process exited before it finished. Prompting #{predecessor_id} continues its work; " \
                           "re-queue this step behind it once it is running again."
            )
          else
            base.merge(
              "kind" => "cancel",
              "reason" => "predecessor_errored",
              "message" => "Cancelled queued worker #{agent.fetch("id")} because #{predecessor_id} errored before it could start."
            )
          end
        when "killed"
          base.merge(
            "kind" => "cancel",
            "reason" => "predecessor_killed",
            "message" => "Cancelled queued worker #{agent.fetch("id")} because #{predecessor_id} was killed before it could start."
          )
        else
          waiting
        end
      end

      # Follows a replacement chain: when the predecessor was killed by a replacement, the successor
      # is the agent that inherited its work, so the dependent follows it instead of being cancelled.
      def deferred_effective_predecessor(state, after_agent_id)
        current = find_agent(state, after_agent_id)
        seen = []
        while current && current.fetch("status", nil) == "killed" && present_string(current.fetch("replaced_by_agent_id", nil))
          break if seen.include?(current.fetch("id"))

          seen << current.fetch("id")
          successor = find_agent(state, current.fetch("replaced_by_agent_id"))
          break unless successor && successor.fetch("type", nil) == "worker"

          current = successor
        end
        current
      end

      def apply_deferred_worker_resolution(decision, trigger:)
        case decision.fetch("kind")
        when "activate" then activate_deferred_worker(decision, trigger: trigger)
        when "cancel" then cancel_deferred_worker(decision, trigger: trigger)
        when "repoint" then repoint_deferred_worker(decision, trigger: trigger)
        when "arm_gate" then arm_deferred_worker_gate(decision, trigger: trigger)
        end
      end

      # Two steps on purpose: the state flip (and its log line) is committed first so a crash before
      # the harness spawn leaves a normal interrupted reservation that reconciliation resumes.
      def activate_deferred_worker(decision, trigger:)
        agent_id = decision.fetch("agent_id")
        predecessor = decision.fetch("predecessor", nil)
        gate = decision.fetch("gate", nil)
        activation = synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next nil unless agent && waiting_deferred_worker?(agent)

          deferred = deferred_spawn_metadata(agent)
          metadata = agent.fetch("harness_metadata", {}) || {}
          now = timestamp
          include_result = deferred.fetch("include_predecessor_result", true)
          prompt = deferred_handover_prompt(
            deferred.fetch("queued_prompt", metadata.fetch("spawn_prompt", "")),
            predecessor,
            include_result
          )
          prompt = deferred_gate_handover_prompt(prompt, gate, include_result)
          updated = metadata.merge(
            "spawn_prompt" => prompt,
            # Claims the record for this instance while the harness session is being started.
            "provisioning_state" => "allocating_workspace",
            "deferred_spawn" => deferred.merge(
              "state" => DEFERRED_STATE_ACTIVATING,
              "after_agent_id" => predecessor && predecessor.fetch("id"),
              "predecessor_status" => decision.fetch("predecessor_status", nil),
              "activation_trigger" => trigger,
              "activated_at" => now
            ).compact
          ).merge(instance_ownership_metadata)
          agent["after_agent_id"] = predecessor && predecessor.fetch("id")
          agent["harness_metadata"] = updated
          agent["updated_at"] = now
          unhappy = (predecessor && decision.fetch("predecessor_status", nil) != "completed") ||
                    decision.fetch("gate_unresolved", false)
          repointed_from = present_string(decision.fetch("repointed_from_agent_id", nil)) ||
                           present_string(deferred.fetch("repointed_from_agent_id", nil))
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: unhappy ? "warning" : "info",
            message: deferred_activation_message(agent_id, predecessor, decision, repointed_from: repointed_from),
            details: {
              "agent_id" => agent_id,
              "issue_id" => agent.fetch("issue_id", nil),
              "after_agent_id" => predecessor && predecessor.fetch("id"),
              "after_agent_status" => decision.fetch("predecessor_status", nil),
              "repointed_from_agent_id" => repointed_from,
              "if_predecessor_fails" => decision.fetch("if_predecessor_fails", nil),
              "include_predecessor_result" => include_result,
              "after_command" => gate && gate.fetch("command", nil),
              "after_command_state" => gate && gate.fetch("state", nil),
              "after_command_checks" => gate && gate.fetch("checks", nil),
              "trigger" => trigger
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          { "prompt" => prompt, "agent" => deep_copy(agent), "log_entry_ids" => log_ids }
        end
        return nil unless activation

        agent = activation.fetch("agent")
        metadata = agent.fetch("harness_metadata", {}) || {}
        result = apply(
          "command_id" => metadata.fetch("spawn_command_id", nil),
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => agent.fetch("issue_id"),
            "title" => metadata.fetch("title", nil),
            "prompt" => activation.fetch("prompt"),
            "workspace_path" => metadata.fetch("requested_workspace_path", nil),
            "follow_up_of_agent_id" => metadata.fetch("follow_up_of_agent_id", nil),
            "after_agent_id" => predecessor && predecessor.fetch("id"),
            "model" => metadata.dig("spawn_session_settings", "model"),
            "thinking_level" => metadata.dig("spawn_session_settings", "thinking_level"),
            "workspace_mode" => agent.fetch("workspace_mode", metadata.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED)),
            "_activate_deferred" => true,
            "_deferred_agent_id" => agent_id
          }
        )
        result.merge(
          "log_entry_ids" => (activation.fetch("log_entry_ids") + Array(result.fetch("log_entry_ids", []))).uniq,
          "deferred_activation" => {
            "agent_id" => agent_id,
            "after_agent_id" => predecessor && predecessor.fetch("id"),
            "after_agent_status" => decision.fetch("predecessor_status", nil),
            "after_command_state" => gate && gate.fetch("state", nil),
            "trigger" => trigger
          }.compact
        )
      end

      def deferred_activation_message(agent_id, predecessor, decision, repointed_from: nil)
        status = decision.fetch("predecessor_status", nil).to_s
        gate = decision.fetch("gate", nil)
        reasons = []
        if predecessor
          reasons << "#{predecessor.fetch("id")} settled (#{status.empty? ? "settled" : status})"
        end
        reasons << deferred_gate_activation_reason(gate) if gate
        base = "Starting queued worker #{agent_id} because #{reasons.empty? ? "it has nothing left to wait for" : reasons.join(" and ")}."
        base = "#{base} It was queued behind #{repointed_from}, which that worker replaced." if present_string(repointed_from)
        base = "#{base} Its predecessor did not complete, and if_predecessor_fails is \"run\"." if predecessor && status != "completed"
        base
      end

      def deferred_gate_activation_reason(gate)
        label = deferred_gate_label(gate)
        checks = gate.fetch("checks", 0).to_i
        case gate.fetch("state", nil).to_s
        when DEFERRED_GATE_STATE_EXPIRED
          "its wait condition #{label} never passed within its #{gate.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s budget and if_gate_expires is \"run\""
        when DEFERRED_GATE_STATE_UNAVAILABLE
          "its wait condition #{label} could not be run and if_gate_expires is \"run\""
        else
          "its wait condition #{label} passed#{checks.positive? ? " after #{checks} check#{checks == 1 ? "" : "s"}" : ""}"
        end
      end

      def deferred_gate_cancellation_message(agent_id, gate)
        label = deferred_gate_label(gate)
        if gate.fetch("state", nil).to_s == DEFERRED_GATE_STATE_UNAVAILABLE
          return "Cancelled queued worker #{agent_id} because its wait condition #{label} could not be run " \
                 "#{DEFERRED_WORKER_GATE_UNUSABLE_LIMIT} times in a row (#{gate.fetch("last_problem", "the command could not be evaluated")})."
        end

        "Cancelled queued worker #{agent_id} because its wait condition #{label} did not pass within " \
          "#{gate.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s."
      end

      # Arms a gate that was waiting behind a predecessor. Committed as its own tiny state step so
      # the wait budget starts from the moment the condition became relevant and survives a restart.
      def arm_deferred_worker_gate(decision, trigger:)
        agent_id = decision.fetch("agent_id")
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next nil unless agent && waiting_deferred_worker?(agent)

          deferred = deferred_spawn_metadata(agent)
          gate = deferred_command_gate(deferred)
          next nil unless gate && gate_pending?(gate) && !gate_armed?(gate)

          now = timestamp
          armed = armed_deferred_gate(gate, now: now)
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "deferred_spawn" => deferred.merge("command_gate" => armed)
          )
          agent["updated_at"] = now
          message = "Queued worker #{agent_id} is now waiting on #{deferred_gate_label(armed)}."
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: "info",
            message: message,
            details: {
              "agent_id" => agent_id,
              "issue_id" => agent.fetch("issue_id", nil),
              "after_agent_id" => deferred_worker_after_agent_id(agent),
              "after_command" => armed.fetch("command", nil),
              "after_command_expires_at" => armed.fetch("expires_at", nil),
              "resolution" => "armed_gate",
              "trigger" => trigger
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "ResolveDeferredWorker",
            agent_id,
            message,
            {
              "resolution" => "armed_gate",
              "agent_id" => agent_id,
              "after_command" => armed.fetch("command", nil),
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end

      # Cancelling removes the dependent the same way Kill does, because it never started and would
      # otherwise linger in the AgentTree as a worker nobody is waiting for. The warning log is the
      # durable record of why it never ran.
      def cancel_deferred_worker(decision, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, decision.fetch("agent_id"))
          next nil unless agent && waiting_deferred_worker?(agent)

          now = timestamp
          issue_ids = [agent.fetch("issue_id", nil)]
          log_ids = cancel_deferred_worker_in_state!(
            state,
            agent,
            reason: decision.fetch("reason"),
            message: decision.fetch("message"),
            trigger: trigger,
            now: now
          )
          cascade = cancel_deferred_dependents_in_state!(
            state,
            [agent.fetch("id")],
            now: now,
            reason: "predecessor_cancelled",
            trigger: trigger
          )
          log_ids.concat(cascade.fetch("log_entry_ids"))
          removed_agent_ids = ([agent.fetch("id")] + cascade.fetch("agent_ids")).uniq
          issue_ids.concat(cascade.fetch("issue_ids"))
          remove_issue_bundles_and_agents!(
            state,
            issue_ids: [],
            extra_agent_ids: removed_agent_ids,
            reason: "deferred_worker_cancelled",
            now: now,
            remove_empty_projects: false
          )
          issue_ids.compact.uniq.each do |issue_id|
            issue = find_issue(state, issue_id)
            next unless issue

            update_issue_status_from_workers!(state, issue, now)
            project = find_project(state, issue.fetch("project_id", nil))
            update_project_status_from_issues!(state, project, now) if project
          end
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "ResolveDeferredWorker",
            decision.fetch("agent_id"),
            decision.fetch("message"),
            {
              "resolution" => "cancelled",
              "reason" => decision.fetch("reason"),
              "agent_id" => decision.fetch("agent_id"),
              "after_agent_id" => decision.fetch("after_agent_id", nil),
              "cancelled_agent_ids" => removed_agent_ids,
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end

      def cancel_deferred_worker_in_state!(state, agent, reason:, message:, trigger:, now:)
        deferred = deferred_spawn_metadata(agent)
        mark_agent_killed!(agent, now)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          "provisioning_state" => "cancelled",
          "deferred_spawn" => deferred.merge(
            "state" => DEFERRED_STATE_CANCELLED,
            "cancel_reason" => reason,
            "cancelled_at" => now,
            "cancel_trigger" => trigger
          ).compact
        )
        append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "warning",
          message: message,
          details: {
            "agent_id" => agent.fetch("id"),
            "issue_id" => agent.fetch("issue_id", nil),
            "after_agent_id" => deferred_worker_after_agent_id(agent),
            "reason" => reason,
            "trigger" => trigger,
            "resolution" => "cancelled"
          }.compact
        )
      end

      # Transitively cancels dependents of records that are going away, bounded by the same chain
      # limit that bounds queueing.
      def cancel_deferred_dependents_in_state!(state, predecessor_ids, now:, reason:, trigger:)
        cancelled_ids = []
        issue_ids = []
        log_ids = []
        frontier = Array(predecessor_ids).compact.uniq
        (DEFERRED_WORKER_MAX_CHAIN_DEPTH + 1).times do |level|
          dependents = waiting_deferred_dependents(state, frontier)
          break if dependents.empty?

          # Past the first level the predecessor was itself a queued worker this pass cancelled, so
          # the reason reported to the user follows the chain instead of repeating the original one.
          level_reason = level.zero? ? reason : "predecessor_cancelled"
          frontier = dependents.map { |dependent| dependent.fetch("id") }
          dependents.each do |dependent|
            predecessor_id = deferred_worker_after_agent_id(dependent)
            log_ids.concat(cancel_deferred_worker_in_state!(
              state,
              dependent,
              reason: level_reason,
              message: deferred_cancellation_message(dependent.fetch("id"), predecessor_id, level_reason),
              trigger: trigger,
              now: now
            ))
            cancelled_ids << dependent.fetch("id")
            issue_ids << dependent.fetch("issue_id", nil)
          end
        end
        { "agent_ids" => cancelled_ids.uniq, "issue_ids" => issue_ids.compact.uniq, "log_entry_ids" => log_ids }
      end

      def deferred_cancellation_message(agent_id, predecessor_id, reason)
        case reason
        when "predecessor_killed"
          "Cancelled queued worker #{agent_id} because #{predecessor_id} was killed before it could start."
        when "predecessor_cancelled"
          "Cancelled queued worker #{agent_id} because #{predecessor_id} was cancelled before it could start."
        when "predecessor_errored"
          "Cancelled queued worker #{agent_id} because #{predecessor_id} errored before it could start."
        else
          "Cancelled queued worker #{agent_id} because #{predecessor_id} can no longer settle."
        end
      end

      # Moves every worker queued behind `from_agent_id` onto the agent that replaced it. Used by the
      # replacement path (atomically, in the same command) and by the resolver as a late fallback.
      def repoint_deferred_dependents_in_state!(state, from_agent_id:, to_agent:, now:, trigger:)
        dependents = waiting_deferred_dependents(state, [from_agent_id])
        log_ids = []
        dependents.each do |dependent|
          log_ids.concat(repoint_deferred_worker_in_state!(
            state,
            dependent,
            predecessor: to_agent,
            now: now,
            trigger: trigger
          ))
        end
        { "agent_ids" => dependents.map { |dependent| dependent.fetch("id") }, "log_entry_ids" => log_ids }
      end

      def repoint_deferred_worker_in_state!(state, agent, predecessor:, now:, trigger:)
        deferred = deferred_spawn_metadata(agent)
        previous_id = deferred_worker_after_agent_id(agent)
        agent["after_agent_id"] = predecessor.fetch("id")
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          "deferred_spawn" => deferred.merge(
            "after_agent_id" => predecessor.fetch("id"),
            "after_agent_issue_id" => predecessor.fetch("issue_id", nil),
            "after_agent_title" => (predecessor.fetch("harness_metadata", {}) || {}).fetch("title", nil),
            "repointed_from_agent_id" => previous_id,
            "repointed_at" => now
          ).compact
        )
        agent["updated_at"] = now
        append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "warning",
          message: deferred_repoint_message(agent.fetch("id"), previous_id, predecessor.fetch("id")),
          details: {
            "agent_id" => agent.fetch("id"),
            "issue_id" => agent.fetch("issue_id", nil),
            "after_agent_id" => predecessor.fetch("id"),
            "repointed_from_agent_id" => previous_id,
            "resolution" => "repointed",
            "trigger" => trigger
          }.compact
        )
      end

      def deferred_repoint_message(agent_id, previous_id, predecessor_id)
        "Queued worker #{agent_id} now waits for #{predecessor_id} because #{previous_id} was replaced."
      end

      def repoint_deferred_worker(decision, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, decision.fetch("agent_id"))
          next nil unless agent && waiting_deferred_worker?(agent)

          predecessor = decision.fetch("predecessor")
          now = timestamp
          previous_id = deferred_worker_after_agent_id(agent)
          log_ids = repoint_deferred_worker_in_state!(state, agent, predecessor: predecessor, now: now, trigger: trigger)
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "ResolveDeferredWorker",
            agent.fetch("id"),
            deferred_repoint_message(agent.fetch("id"), previous_id, predecessor.fetch("id")),
            {
              "resolution" => "repointed",
              "agent_id" => agent.fetch("id"),
              "after_agent_id" => predecessor.fetch("id"),
              "repointed_from_agent_id" => previous_id,
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end
    end
  end
end
