# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Settling a finished worker turn, and the durable record of a user's own kernel command.

      # Settling a worker is a classification, not a rubber stamp. A turn that ended because the
      # transport or provider request died (a dropped wifi connection is the common case), or a
      # session that disappeared without ever producing a final message, settles as `errored`
      # with a human-readable reason. Only a turn that really finished settles as `completed`.
      def mark_worker_completed(agent_id:, harness_events: [], last_assistant_text: nil, session_ref: nil, settle_failure: nil)
        settle_failure ||= worker_settle_failure(
          agent_id: agent_id,
          session_ref: session_ref,
          events: harness_events,
          last_assistant_text: last_assistant_text
        )
        result = if settle_failure
                   record_worker_settle_failure(
                     agent_id: agent_id,
                     settle_failure: settle_failure,
                     harness_events: harness_events,
                     last_assistant_text: last_assistant_text,
                     session_ref: session_ref
                   )
                 else
                   record_worker_completion(
                     agent_id: agent_id,
                     harness_events: harness_events,
                     last_assistant_text: last_assistant_text,
                     session_ref: session_ref
                   )
                 end
        return result unless result.fetch("status", nil) == "accepted"

        # A session the provider refuses to replay is recovered here, before dependents are
        # resolved, so the successor exists in time to inherit the dead worker's queue instead of
        # letting `if_predecessor_fails: "cancel"` dead-end it.
        restart = recover_unreplayable_worker_session(result)
        return restart if restart

        # Completion continuations run from the same settle hook as deferred workers: the worker
        # records its final report, then the kernel can spawn a fresh head to route follow-on work.
        # Reconciliation is the recovery hook for the crash window between recording completion and
        # spawning that head.
        result = with_completion_continuation_resolution(result, trigger: "worker_completed")

        # First of the two activation hooks for queued dependents. Reconciliation is the second, so
        # a dependent cannot be lost if this process dies between A finishing and B starting.
        # A failed settle resolves dependents too: `if_predecessor_fails: "run"` starts them anyway,
        # and a dependent behind a still-recoverable dead turn keeps waiting instead of cancelling.
        with_deferred_worker_resolution(result)
      end

      # Public settle entry point for a worker whose harness turn ended without finishing. Mirrors
      # `mark_worker_completed`, including the queued-dependent hook.
      def mark_worker_settle_failed(agent_id:, settle_failure:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        result = record_worker_settle_failure(
          agent_id: agent_id,
          settle_failure: settle_failure,
          harness_events: harness_events,
          last_assistant_text: last_assistant_text,
          session_ref: session_ref
        )
        return result unless result.fetch("status", nil) == "accepted"

        restart = recover_unreplayable_worker_session(result)
        return restart if restart

        with_deferred_worker_resolution(result)
      end

      # The settle-time half of the unreplayable-session recovery. Returns the accepted result of
      # the settle when the successor was spawned (SpawnWorker already repointed the dead worker's
      # dependents at it), or nil when there is nothing to recover, so the caller falls back to the
      # normal dependent resolution.
      def recover_unreplayable_worker_session(settle_result)
        return nil unless settle_result.fetch("command_type", nil) == "MarkWorkerSettleFailed"

        agent_id = present_string(settle_result.fetch("target_id", nil))
        return nil unless agent_id

        agent = agent_record_snapshot(agent_id)
        return nil unless agent && worker_session_restart_eligible?(agent)

        restart = restart_unreplayable_worker_session(agent_id, trigger: "settle")
        return nil unless restart.is_a?(Hash) && restart.fetch("claimed", false)
        # The restart could not be spawned: fall through so dependents still get resolved (and
        # cancelled if that is their policy) rather than waiting on a worker that cannot continue.
        return nil unless restart.fetch("restarted", false)

        merge_result_log_entry_ids(settle_result, restart.fetch("log_entry_ids", []))
      end

      def merge_result_log_entry_ids(result, log_entry_ids)
        return result if Array(log_entry_ids).empty?

        result.merge("log_entry_ids" => (Array(result.fetch("log_entry_ids", [])) + Array(log_entry_ids)).uniq)
      end

      def agent_record_snapshot(agent_id)
        synchronized_state do
          agent = find_agent(normalized_state, agent_id)
          agent.is_a?(Hash) ? deep_copy(agent) : nil
        end
      end

      def record_worker_completion(agent_id:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        synchronized_state do
          state = normalized_state
          agent = find_session_agent(state, agent_id: agent_id, session_ref: session_ref)
          return rejected_result(nil, "MarkWorkerCompleted", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          unless agent.fetch("type", nil) == "worker"
            return rejected_result(nil, "MarkWorkerCompleted", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"])
          end
          if %w[completed killed].include?(agent.fetch("status", nil))
            return accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Worker #{agent.fetch("id")} is already #{agent.fetch("status")}.", agent, [])
          end
          if agent.fetch("status", nil) == "paused"
            return accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Worker #{agent.fetch("id")} is paused; completion will be observed after it resumes.", agent, [])
          end

          merge_session_ref_into_agent!(agent, session_ref) if session_ref
          now = timestamp
          agent["status"] = "completed"
          agent["updated_at"] = now
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "completed_at" => now,
            "is_streaming" => false,
            "settled_event_count" => Array(harness_events).length,
            "last_assistant_text" => present_string(last_assistant_text)
          ).compact

          issue = find_issue(state, agent.fetch("issue_id", nil))
          project = issue && find_project(state, issue.fetch("project_id", nil))
          update_issue_status_from_workers!(state, issue, now) if issue
          update_project_status_from_issues!(state, project, now) if project

          github_enabled = github_support_enabled?(state)
          candidate_pr_urls = github_enabled ? worker_pr_urls(last_assistant_text: last_assistant_text, harness_events: harness_events) : []
          if github_enabled
            State::Models.scrub_worker_pull_request_keys!(agent["harness_metadata"])
            delivery_pull_request = verified_worker_pull_request(agent: agent, project: project, candidate_urls: candidate_pr_urls)
            attach_issue_pull_requests!(issue, delivery_pull_request, candidate_pr_urls) if issue
          end

          completion_details = {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "settled_event_count" => Array(harness_events).length,
            "last_assistant_text" => present_string(last_assistant_text)
          }.compact
          completion_details["candidate_pr_urls"] = candidate_pr_urls unless candidate_pr_urls.empty?
          completion_details["delivery_pull_request"] = delivery_pull_request if delivery_pull_request

          log_ids = append_harness_event_logs(state, agent, harness_events)
          log_ids.concat(append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "info",
            message: "Worker #{agent.fetch("id")} completed.",
            details: completion_details
          ))
          touch_state!(state, now)
          store.save(state)

          accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Marked worker #{agent.fetch("id")} completed.", worker_completion_result(agent, issue), log_ids)
        end
      end

      # Records a worker whose harness turn ended without finishing. The worker becomes `errored`
      # with the failure reason on its record, in its log line, and in the UI, and its issue is
      # never rolled up to `completed` on the back of it. The harness session, worktree, branch,
      # and any queued prompt are all left intact so the worker stays recoverable.
      def record_worker_settle_failure(agent_id:, settle_failure:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        synchronized_state do
          state = normalized_state
          agent = find_session_agent(state, agent_id: agent_id, session_ref: session_ref)
          return rejected_result(nil, "MarkWorkerSettleFailed", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          unless agent.fetch("type", nil) == "worker"
            return rejected_result(nil, "MarkWorkerSettleFailed", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"])
          end
          if %w[completed killed].include?(agent.fetch("status", nil))
            return accepted_result(nil, "MarkWorkerSettleFailed", agent.fetch("id"), "Worker #{agent.fetch("id")} is already #{agent.fetch("status")}.", agent, [])
          end
          if agent.fetch("status", nil) == "paused"
            return accepted_result(nil, "MarkWorkerSettleFailed", agent.fetch("id"), "Worker #{agent.fetch("id")} is paused; settle classification is deferred until it resumes.", agent, [])
          end

          raw_failure = settle_failure.is_a?(Hash) ? stringify_keys(settle_failure) : {}
          failure = settle_failure_record(raw_failure)
          # Reconciliation keeps polling a settled session, so re-observing the same dead turn
          # must be a silent no-op instead of another error log every pass. Evidence older than
          # the last delivered prompt is stale for the same reason: the user already recovered.
          if settle_failure_already_recorded?(agent, failure) || stale_settle_failure_evidence?(agent, failure)
            return accepted_result(
              nil,
              "MarkWorkerSettleFailed",
              agent.fetch("id"),
              "Worker #{agent.fetch("id")} is already errored: #{failure.fetch("reason")}",
              agent,
              []
            )
          end

          merge_session_ref_into_agent!(agent, session_ref) if session_ref
          now = timestamp
          failure = failure.merge("detected_at" => now)
          agent["status"] = "errored"
          agent["updated_at"] = now
          metadata_updates = {
            "is_streaming" => false,
            "errored_at" => now,
            "settled_event_count" => Array(harness_events).length,
            "settle_state" => "failed",
            "settle_failure" => failure,
            "status_reason" => settle_failure_status_reason(failure),
            "error_message" => failure.fetch("reason")
          }
          # A session the provider refuses to replay is not resumable, so the record says what the
          # user can act on: the work is intact in the worktree, and continuing means a fresh
          # session there rather than another attempt at the same transcript.
          if unreplayable_session_failure?(failure)
            metadata_updates["session_recovery"] = unreplayable_session_recovery_record(agent, now)
            metadata_updates["status_reason"] = "#{settle_failure_status_reason(failure)}. #{unreplayable_session_recovery_advice(agent)}"
          end
          # Never overwrite a partial result the worker did manage to produce.
          partial_text = present_string(last_assistant_text) || present_string(raw_failure.fetch("last_assistant_text", nil))
          metadata_updates["last_assistant_text"] = partial_text if partial_text
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(metadata_updates).compact

          issue = find_issue(state, agent.fetch("issue_id", nil))
          refresh_worker_parent_statuses!(state, agent, now)

          details = {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "settled_event_count" => Array(harness_events).length,
            "settle_failure" => failure,
            "recoverable" => worker_resumable_after_settle_failure?(agent)
          }.compact
          details["session_recovery"] = metadata_updates["session_recovery"] if metadata_updates.key?("session_recovery")
          log_ids = append_harness_event_logs(state, agent, harness_events)
          log_ids.concat(append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "error",
            message: settle_failure_log_message(agent, failure),
            details: details
          ))
          touch_state!(state, now)
          store.save(state)

          accepted_result(
            nil,
            "MarkWorkerSettleFailed",
            agent.fetch("id"),
            "Marked worker #{agent.fetch("id")} errored: #{failure.fetch("reason")}",
            worker_completion_result(agent, issue),
            log_ids
          )
        end
      end

      private :record_worker_completion, :record_worker_settle_failure

      # A completed worker may carry a kernel-owned continuation that spawns a fresh head with the
      # worker's final report. Merge those nested results into the completion command so callers can
      # see which head routed the follow-on work and which log lines were written.
      def with_completion_continuation_resolution(result, trigger:)
        agent_id = present_string(result.fetch("target_id", nil))
        return result unless agent_id

        continuations = resolve_completion_continuations(trigger: trigger, only_agent_id: agent_id)
        return result if continuations.empty?

        result.merge(
          "log_entry_ids" => (
            Array(result.fetch("log_entry_ids", [])) +
              continuations.flat_map { |entry| Array(entry.fetch("log_entry_ids", [])) }
          ).uniq,
          "completion_continuation_results" => continuations
        )
      end

      private :with_completion_continuation_resolution

      # Both settle paths share the queued-dependent hook: a dependent must be resolved from the
      # settle that actually happened, whether the predecessor finished or died mid-turn.
      def with_deferred_worker_resolution(result)
        deferred = resolve_deferred_workers(trigger: "predecessor_settled")
        return result if deferred.empty?

        result.merge(
          "log_entry_ids" => (
            Array(result.fetch("log_entry_ids", [])) +
              deferred.flat_map { |entry| Array(entry.fetch("log_entry_ids", [])) }
          ).uniq,
          "deferred_worker_results" => deferred
        )
      end

      private :with_deferred_worker_resolution

      # `/config save` carries the whole Settings draft as one base64 payload, so
      # echoing it verbatim spent six lines of the log on an unreadable blob —
      # and on a first run those were the first six lines anyone saw. The command
      # that ran is the useful part; the payload is already in `details`, and the
      # settings it changed are named by the SaveConfiguration log right after it.
      OPAQUE_PAYLOAD_COMMANDS = ["/config save"].freeze

      def displayable_user_command(input)
        text = input.to_s
        prefix = OPAQUE_PAYLOAD_COMMANDS.find { |candidate| text.start_with?("#{candidate} ") }
        prefix ? "#{prefix} …" : text
      end

      def record_user_kernel_command(input:, commands: [])
        synchronized_state do
          state = normalized_state
          command_types = Array(commands).filter_map do |command|
            next unless command.respond_to?(:[])

            command["type"] || command[:type] || command["command_type"] || command[:command_type]
          end
          log_ids = append_log(
            state,
            source_type: "user",
            source_id: nil,
            level: "info",
            message: "User ran command: #{displayable_user_command(input)}",
            details: {
              "input" => input.to_s,
              "command_types" => command_types,
              "kind" => "kernel_command",
              "presentation" => "cmd"
            }
          )
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end

      def record_user_kernel_command_output(input:, command_results: [])
        bodies = command_output_bodies(command_results)
        return [] if bodies.empty?

        synchronized_state do
          state = normalized_state
          log_ids = bodies.map do |body, _result|
            append_log(
              state,
              source_type: "kernel",
              source_id: nil,
              level: "info",
              message: body,
              details: {
                "input" => input.to_s,
                "kind" => "kernel_command_output",
                "presentation" => "cmd"
              }
            )
          end
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end
    end
  end
end
