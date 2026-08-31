# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # The reconciliation pass itself: its ordered steps, its per-step error isolation, and the
      # cross-instance ownership checks every step consults.

      def reconcile_sessions(command_id: nil, command_type: "ReconcileSessions")
        @session_reconcile_mutex.synchronize do
          reconcile_sessions_once(command_id: command_id, command_type: command_type)
        end
      end

      def reconcile_sessions_once(command_id:, command_type:)
        # Each step is isolated: a single unhealthy record must not turn a routine
        # reconciliation pass into a user-visible "Failed ReconcileSessions" error.
        normalized_state_changed = reconcile_step("normalize_state", false) { persist_normalized_state_if_changed }
        # Early, and before anything asks a project for a workspace: a project whose
        # record predates the isolation contract has to regain its evidence before the
        # workers it owns are provisioned in this same pass.
        version_control_backfills = reconcile_step("backfill_project_version_control", []) { backfill_project_version_control }
        recovered_worker_results = reconcile_step("recover_worker_reservations", []) { recover_worker_reservations }
        pause_results = reconcile_step("finish_worker_pauses", []) { reconcile_pending_worker_pauses }
        resume_results = reconcile_step("finish_worker_resumes", []) { reconcile_pending_worker_resumes }
        interactive_focus_results = reconcile_step("recover_interactive_focus", []) { reconcile_stale_interactive_focuses }
        interactive_focus_results.concat(
          reconcile_step("observe_interactive_focus", []) { reconcile_active_interactive_focuses }
        )
        pending_prompt_results = reconcile_step("deliver_pending_prompts", []) { deliver_pending_agent_prompts }
        recovered_results = reconcile_step("recover_head_results", []) { recover_unapplied_head_results }
        prune_result = reconcile_step("prune_killed_records", { "changed" => false, "log_entry_ids" => [] }) { prune_killed_records }
        delivery_pr_refreshes = reconcile_step("refresh_delivery_pull_requests", []) { refresh_stale_delivery_pull_requests }
        model_catalog_refresh = reconcile_step("refresh_model_catalog", { "changed" => false }) { refresh_active_model_catalog }
        agents = synchronized_state do
          normalized_state.fetch("agents").select { |agent| reconcile_candidate?(agent) }.map { |agent| deep_copy(agent) }
        end

        poll_results = agents.map { |agent| poll_agent_session(agent) }
        applied_results = apply_poll_results(poll_results)
        self_fixing_worker_results = reconcile_step("self_fixing_workers", []) { reconcile_self_fixing_workers }
        # Completion-triggered heads are resolved after polls so a worker that completed during
        # this pass can route follow-on commands immediately. A continuation carrying an external
        # gate is only armed here; it remains durable state on the completed worker until the shared
        # wait-gate pass below says the condition is satisfied.
        completion_continuation_results = reconcile_step("resolve_completion_continuations", []) { resolve_completion_continuations(trigger: "reconcile") }
        # Command gates are evaluated before dependents are resolved, so a wait condition that
        # passes in this pass starts its worker (or completion head) in the same pass. The commands
        # run outside the state lock under their own wall-clock budget; nothing here blocks on a
        # user command for longer than one gate's own timeout.
        gate_check_results = reconcile_step("check_kernel_wait_gates", []) { check_kernel_wait_gates(trigger: "reconcile") }
        completion_continuation_results.concat(
          reconcile_step("resolve_completion_continuations_after_wait_gates", []) do
            resolve_completion_continuations(trigger: "reconcile_after_wait_gate")
          end
        )
        # Second activation hook for queued dependents. It runs after the polls so a predecessor
        # that settled in this same pass is honoured immediately, and it is the hook that recovers
        # a dependency whose predecessor settled, errored, or disappeared while Meringue was down.
        deferred_worker_results = reconcile_step("resolve_deferred_workers", []) { resolve_deferred_workers(trigger: "reconcile") }
        # Goal loops run after the poll results are applied so this pass already sees the attempt
        # worker that just settled, instead of waiting a full tick to notice it. They also run after
        # deferred activation, so a goal whose attempt was queued behind another agent observes the
        # activated worker rather than a record that is still waiting.
        goal_steps = reconcile_step("advance_goal_loops", []) { advance_goal_loops }
        # Last, so a worker whose output arrived in this same pass is never called quiet for the
        # silence that preceded it.
        quiet_worker_results = reconcile_step("warn_quiet_workers", []) { warn_quiet_workers }
        changed_count = applied_results.count { |result| result.fetch("changed", false) }
        changed_count += self_fixing_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += completion_continuation_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += gate_check_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += deferred_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += recovered_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += interactive_focus_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += pause_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += resume_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += pending_prompt_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += recovered_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += version_control_backfills.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += 1 if normalized_state_changed
        changed_count += 1 if prune_result.fetch("changed", false)
        changed_count += delivery_pr_refreshes.count { |refresh| refresh.fetch("changed", false) }
        changed_count += 1 if model_catalog_refresh.fetch("changed", false)
        changed_count += goal_steps.count { |step| step.fetch("changed", false) }
        changed_count += quiet_worker_results.length
        accepted_result(
          command_id,
          command_type,
          nil,
          "Reconciled #{agents.length} agent session(s).",
          {
            "checked_count" => agents.length,
            "changed_count" => changed_count,
            "pruned_issue_ids" => prune_result.fetch("removed_issue_ids", []),
            "pruned_agent_ids" => prune_result.fetch("removed_agent_ids", []),
            "pruned_project_ids" => prune_result.fetch("removed_project_ids", []),
            "version_control_backfills" => version_control_backfills,
            "recovered_worker_results" => recovered_worker_results,
            "interactive_focus_results" => interactive_focus_results,
            "pause_results" => pause_results,
            "resume_results" => resume_results,
            "pending_prompt_results" => pending_prompt_results,
            "recovered_head_results" => recovered_results,
            "delivery_pull_request_refreshes" => delivery_pr_refreshes,
            "model_catalog_refresh" => model_catalog_refresh,
            "completion_continuation_results" => completion_continuation_results,
            "deferred_worker_gate_results" => gate_check_results,
            "deferred_worker_results" => deferred_worker_results,
            "goal_loop_steps" => goal_steps,
            "poll_results" => applied_results,
            "self_fixing_worker_results" => self_fixing_worker_results,
            "quiet_worker_results" => quiet_worker_results
          },
          (version_control_backfills.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + recovered_worker_results.flat_map { |result| result.fetch("log_entry_ids", []) } + interactive_focus_results.flat_map { |result| result.fetch("log_entry_ids", []) } + pause_results.flat_map { |result| result.fetch("log_entry_ids", []) } + resume_results.flat_map { |result| result.fetch("log_entry_ids", []) } + pending_prompt_results.flat_map { |result| result.fetch("log_entry_ids", []) } + recovered_results.flat_map { |result| result.fetch("log_entry_ids", []) } + prune_result.fetch("log_entry_ids", []) + applied_results.flat_map { |result| result.fetch("log_entry_ids", []) } + completion_continuation_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + gate_check_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + deferred_worker_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + self_fixing_worker_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + goal_steps.flat_map { |step| step.fetch("log_entry_ids", []) } + quiet_worker_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) }).uniq
        )
      rescue StandardError => e
        error = error_payload(e)
        failed_result(command_id, command_type, "Session reconciliation failed: #{error.fetch("message")}", [error.fetch("class"), error.fetch("message")])
      end

      private :reconcile_sessions_once

      # Self-fixing is deliberately a reconciliation concern rather than a worker completion hook:
      # it sees both terminal errors and blocked resume failures, and it also runs after a poll batch
      # has been durably applied. Claiming the source under the state lock makes concurrent
      # dashboards converge on one recovery; the marker on the child prevents recovery recursion.
      def reconcile_self_fixing_workers
        return [] unless config.experiment_enabled?("self_fixing_workers")

        candidates = synchronized_state do
          state = normalized_state
          agents = state.fetch("agents")
          agents.filter_map do |worker|
            next unless Experiments::SelfFixingWorkers.claimable?(worker)
            next if agents.any? { |child| Experiments::SelfFixingWorkers.child?(child, worker.fetch("id")) }

            deep_copy(worker)
          end
        end

        candidates.filter_map do |candidate|
          claim = claim_self_fixing_worker(candidate.fetch("id"))
          next unless claim.fetch("claimed", false)

          source = claim.fetch("worker")
          attempt = claim.fetch("attempt")
          recovery_id = claim.fetch("command_id")
          marker = { "source_worker_id" => source.fetch("id"), "attempt" => attempt }
          continuation_payload = {
            "issue_id" => source.fetch("issue_id"),
            "title" => Experiments::SelfFixingWorkers.title(source),
            "prompt" => Experiments::SelfFixingWorkers.continuation_prompt(source),
            "follow_up_of_agent_id" => source.fetch("id"),
            "_self_fixing_recovery" => marker.merge("lane" => "continuation")
          }
          continuation = @worker_spawn_mutex.synchronize { spawn_worker(recovery_id, "SpawnWorker", continuation_payload) }
          continuation = record_self_fixing_outcome(source.fetch("id"), continuation, attempt, recovery_id)
          results = [continuation.merge("self_fixing_lane" => "continuation", "self_fixing_source_worker_id" => source.fetch("id"), "self_fixing_attempt" => attempt)]

          if Experiments::SelfFixingWorkers.repair_lane?(source)
            repair_id = "self-fix:#{source.fetch("id")}:#{attempt}:repair"
            repair = Experiments::SelfFixingWorkers.classification(source)
            repair_payload = {
              "issue_id" => repair.fetch("repair_issue_id"),
              "title" => "Repair recovery platform defect",
              "prompt" => Experiments::SelfFixingWorkers.repair_prompt(source),
              "share_workspace" => false,
              "_self_fixing_recovery" => marker.merge("lane" => "repair")
            }
            repair_result = @worker_spawn_mutex.synchronize { spawn_worker(repair_id, "SpawnWorker", repair_payload) }
            record_self_fixing_lane_outcome(source.fetch("id"), "repair", repair_result, attempt, repair_id)
            results << repair_result.merge("self_fixing_lane" => "repair", "self_fixing_source_worker_id" => source.fetch("id"), "self_fixing_attempt" => attempt)
          end
          results
        rescue StandardError => e
          failure = failed_result(
            recovery_id,
            "SpawnWorker",
            "Self-fixing recovery was not started: #{sanitized_error_message(e)}",
            [e.class.name, sanitized_error_message(e)]
          )
          record_self_fixing_outcome(candidate.fetch("id"), failure, claim && claim.fetch("attempt", 1), recovery_id)
          [failure.merge("self_fixing_lane" => "continuation", "self_fixing_source_worker_id" => candidate.fetch("id"))]
        end.flatten
      end

      def claim_self_fixing_worker(worker_id)
        synchronized_state do
          state = normalized_state
          worker = find_agent(state, worker_id)
          return { "claimed" => false, "reason" => "worker_not_found" } unless worker
          return { "claimed" => false, "reason" => "not_eligible" } unless Experiments::SelfFixingWorkers.claimable?(worker)
          return { "claimed" => false, "reason" => "recovery_already_present" } if state.fetch("agents").any? { |child| Experiments::SelfFixingWorkers.child?(child, worker_id) }

          now = timestamp
          attempt = Experiments::SelfFixingWorkers.attempts(worker) + 1
          command_id = "self-fix:#{worker_id}:#{attempt}"
          metadata = worker.fetch("harness_metadata", {}) || {}
          recovery = Experiments::SelfFixingWorkers.recovery_record(worker).merge(
            "state" => "spawning",
            "attempts" => attempt,
            "claimed_at" => now,
            "command_id" => command_id
          )
          worker["harness_metadata"] = metadata.merge("self_fixing_recovery" => recovery)
          worker["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          { "claimed" => true, "worker" => deep_copy(worker), "attempt" => attempt, "command_id" => command_id }
        end
      end

      def record_self_fixing_lane_outcome(source_worker_id, lane, result, attempt, command_id)
        synchronized_state do
          state = normalized_state
          source = find_agent(state, source_worker_id)
          return result unless source
          metadata = source.fetch("harness_metadata", {}) || {}
          recovery = Experiments::SelfFixingWorkers.recovery_record(source)
          lanes = recovery.fetch("lanes", {})
          lanes = {} unless lanes.is_a?(Hash)
          lanes[lane] = {
            "state" => result.fetch("status", nil) == "accepted" ? "spawned" : "failed",
            "attempts" => attempt.to_i, "command_id" => command_id,
            "recovery_worker_id" => result.fetch("target_id", nil), "completed_at" => timestamp
          }.compact
          recovery["lanes"] = lanes
          source["harness_metadata"] = metadata.merge("self_fixing_recovery" => recovery)
          source["updated_at"] = timestamp
          touch_state!(state, source.fetch("updated_at"))
          store.save(state)
          result
        end
      end

      def record_self_fixing_outcome(source_worker_id, result, attempt, command_id)
        synchronized_state do
          state = normalized_state
          source = find_agent(state, source_worker_id)
          return result unless source

          now = timestamp
          metadata = source.fetch("harness_metadata", {}) || {}
          previous = Experiments::SelfFixingWorkers.recovery_record(source)
          accepted = result.fetch("status", nil) == "accepted"
          recovery = previous.merge(
            "state" => accepted ? "spawned" : "failed",
            "attempts" => attempt.to_i,
            "command_id" => command_id,
            "recovery_worker_id" => result.fetch("target_id", nil),
            "completed_at" => now
          ).compact
          source["harness_metadata"] = metadata.merge("self_fixing_recovery" => recovery)
          source["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "worker",
            source_id: source_worker_id,
            level: accepted ? "warning" : "error",
            message: accepted ? "Started one bounded self-fixing recovery for worker #{source_worker_id}." : "Self-fixing recovery for worker #{source_worker_id} was not started.",
            details: recovery.merge("result_status" => result.fetch("status", nil)).compact
          )
          touch_state!(state, now)
          store.save(state)
          result.merge("log_entry_ids" => (Array(result.fetch("log_entry_ids", [])) + log_ids).uniq)
        end
      end

      private

      # Isolates one reconciliation step. A step that raises records a warning and
      # falls back, instead of aborting the whole pass with an error log.
      def reconcile_step(name, fallback)
        yield
      rescue StandardError => e
        synchronized_state do
          state = normalized_state
          append_log(
            state,
            source_type: "kernel",
            source_id: nil,
            level: "warning",
            message: "Skipped session reconciliation step #{name}: #{sanitized_error_message(e)}",
            details: { "step" => name, "error" => error_payload(e) }
          )
          touch_state!(state)
          store.save(state)
        end
        fallback
      end

      # True when another *live* Meringue instance owns this record. Recovery is
      # for records whose owner is gone; stealing in-flight work from a live
      # instance is what applies one logical command twice.
      def owned_by_other_live_instance?(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        !other_live_instance_pid(
          metadata.fetch("owner_instance_id", nil),
          metadata.fetch("owner_instance_pid", nil),
          metadata.fetch("owner_instance_started_at", nil)
        ).nil?
      end

      # Same question for a goal record. Goals are not agents: their driver ownership lives at
      # the top level of the record, not in harness metadata.
      def goal_owned_by_other_live_instance?(goal)
        !other_live_instance_pid(
          goal.fetch("owner_instance_id", nil),
          goal.fetch("owner_instance_pid", nil),
          goal.fetch("owner_instance_started_at", nil)
        ).nil?
      end

      # Returns the pid of the other live owner, or nil when the record is
      # unowned, owned by this engine, or owned by a process that is gone.
      def other_live_instance_pid(owner_instance_id, owner_instance_pid, owner_started_at = nil)
        return nil if blank?(owner_instance_id) && blank?(owner_instance_pid)
        return nil if present_string(owner_instance_id) && owner_instance_id.to_s == instance_id
        return nil if blank?(owner_instance_id) && owner_instance_pid.to_i == instance_pid

        pid = blank?(owner_instance_pid) ? instance_pid : owner_instance_pid.to_i
        instance_alive?(pid, owner_started_at) ? pid : nil
      end

      # A recorded pid can be reused by an unrelated process, which would make a
      # crashed owner look alive and block recovery forever. The recorded start
      # time settles it when available.
      def instance_alive?(pid, started_at)
        return false unless Harness::ProcessIdentity.alive?(pid)
        return true if blank?(started_at)

        Harness::ProcessIdentity.matches?(pid, started_at: started_at)
      end

      def instance_started_at
        return @instance_started_at if defined?(@instance_started_at)

        described = Harness::ProcessIdentity.describe(instance_pid)
        started_at = described && described.fetch("started_at", nil)
        @instance_started_at = started_at && started_at.iso8601
      end

      def instance_ownership_metadata
        {
          "owner_instance_pid" => instance_pid,
          "owner_instance_id" => instance_id,
          "owner_instance_started_at" => instance_started_at
        }.compact
      end

      def operation_owned_by_other_live_instance?(operation)
        return false unless operation.is_a?(Hash)

        !other_live_instance_pid(
          operation.fetch("owner_instance_id", nil),
          operation.fetch("owner_instance_pid", nil),
          operation.fetch("owner_instance_started_at", nil)
        ).nil?
      end

      def session_process_missing_error?(error)
        return true if Harness.session_process_gone_error?(error)

        error.class.name.to_s.end_with?("ProcessNotFoundError", "ProcessExitedError")
      rescue StandardError
        false
      end
    end
  end
end
