# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Recovering a session whose process or supervisor is gone: resuming a worker, restarting a
      # head, and deferring or settling the error when recovery is spent.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def worker_reconcile_resume_eligible?(agent, client)
        agent.fetch("type", nil) == "worker" &&
          client.respond_to?(:attach_session) &&
          agent_has_session_reference?(agent) &&
          # A session the provider already refused to replay is not retried: the resume would send
          # the same rejected transcript. It is recovered by a fresh session instead.
          !worker_session_unreplayable?(agent) &&
          worker_resume_attempt_count(agent) < WORKER_RECONCILE_RESUME_MAX_ATTEMPTS
      end

      # --- a harness process that is gone -------------------------------------------------------
      #
      # A `ProcessExitedError`-class failure is not a transport blip: the process that owned the
      # session left, so no later RPC can be answered. Reconciliation used to discover this only by
      # *trying to resume* the session, and then spent its whole resume budget on `prompt` RPCs that
      # could only time out - which is why a real incident reported
      # `RpcTimeoutError: Timed out waiting for a harness response to "prompt"` for a worker whose
      # actual failure was `ProcessExitedError`. The exit is now recorded on the first pass that
      # observes it, named for what it is.
      def worker_harness_process_gone?(agent, error)
        agent.fetch("type", nil) == "worker" && Harness.session_process_gone_error?(error)
      end

      # Recover only the shared-supervisor failure mode. A lone harness crash while its Meringue owner is
      # alive still follows the normal process-exit settle path, so an arbitrary harness failure can
      # never turn into an automatic prompt. Transport ownership is the causal proof: both the
      # recorded child and the Meringue process that owned its pipes are gone.
      def recover_worker_after_supervisor_exit(agent, client, session_ref, original_error)
        supervision = safe_session_supervision_evidence(client, session_ref)
        return nil unless supervision&.fetch("supervisor_exited", false)
        return nil unless supervisor_exit_recovery_eligible?(agent, client)

        claim = claim_worker_supervisor_recovery(agent, session_ref, supervision)
        unless claim.fetch("claimed", false)
          return nil if claim.fetch("reason", nil) == "attempts_exhausted"

          # Another live Meringue instance already owns the durable claim, or this poll used a stale
          # pid after that instance recovered it. Leave the worker untouched; the claimant is the
          # only process allowed to attach or prompt.
          return supervisor_recovery_deferred_poll_result(agent, session_ref, claim)
        end

        resumed_ref = nil
        prompted = false
        begin
          resumed_ref = client.attach_session(session_ref)
          unless resumed_ref.fetch("is_streaming", false)
            resumed_ref = client.prompt_session(
              resumed_ref,
              supervisor_recovery_prompt(claim.fetch("recovery_id")),
              mode: "normal"
            )
            prompted = true
          end
          completion = complete_worker_supervisor_recovery(
            agent,
            resumed_ref,
            claim: claim,
            supervision: supervision,
            prompted: prompted
          )
          safely_kill_recovery_session(client, resumed_ref) if completion.fetch("recovery_session_cleanup_required", false)
          completion
        rescue StandardError => recovery_error
          # attach_session may already have created a replacement RPC child. A failed attempt never
          # leaves that untracked child writing the same session file.
          safely_kill_recovery_session(client, resumed_ref) if resumed_ref
          failed_recovery = record_worker_supervisor_recovery_failure(
            agent,
            claim: claim,
            supervision: supervision,
            error: recovery_error
          )
          # The final failed attempt falls through to ordinary process-exit settlement in this same
          # poll. Keep that poll's session metadata at least as new as the just-saved claim, or its
          # stale snapshot would overwrite attempt N with attempt N-1 while merging the settle.
          if failed_recovery
            session_ref["metadata"] = (session_ref.fetch("metadata", {}) || {}).merge(
              "supervisor_recovery" => failed_recovery
            )
          end
          return nil if claim.fetch("attempt") >= WORKER_SUPERVISOR_RECOVERY_MAX_ATTEMPTS

          supervisor_recovery_failed_poll_result(
            agent,
            session_ref,
            original_error,
            recovery_error,
            claim,
            supervision
          )
        end
      end

      def safe_session_supervision_evidence(client, session_ref)
        return nil unless client.respond_to?(:session_supervision_evidence)

        evidence = client.session_supervision_evidence(session_ref)
        evidence.is_a?(Hash) ? stringify_keys(evidence) : nil
      rescue StandardError
        nil
      end

      def supervisor_exit_recovery_eligible?(agent, client)
        return false unless agent.fetch("type", nil) == "worker"
        return false if %w[completed killed].include?(agent.fetch("status", nil))
        return false unless client.respond_to?(:attach_session) && client.respond_to?(:prompt_session)
        return false unless agent_has_session_reference?(agent)
        return false if worker_session_unreplayable?(agent)
        return false if interactive_focus_active?(agent)

        true
      end

      # One recovery episode is one dead transport owner. When the replacement Meringue process
      # itself later exits, the transport lease names that newer owner and therefore creates a new
      # episode rather than replaying an old claim.
      def supervisor_recovery_episode_id(agent, session_ref, supervision)
        identity = [
          agent.fetch("id", nil),
          session_ref.fetch("session_id", nil),
          supervision.fetch("owner_pid", nil),
          supervision.fetch("owner_started_at", nil),
          supervision.fetch("harness_pid", nil),
          supervision.fetch("harness_started_at", nil)
        ].map(&:to_s).join("|")
        "supervisor-#{Digest::SHA256.hexdigest(identity)[0, 20]}"
      end

      # The claim is persisted before process or prompt I/O. It is the single-flight boundary for
      # two dashboards reconciling one state file, and its deterministic attempt id is included in
      # the continuation prompt for diagnostics.
      def claim_worker_supervisor_recovery(agent, session_ref, supervision)
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id", nil))
          return { "claimed" => false, "reason" => "agent_not_found" } unless current
          return { "claimed" => false, "reason" => "terminal_status" } if %w[completed killed].include?(current.fetch("status", nil))

          # A prompt or another recovery may have replaced the process after this poll took its
          # snapshot. Never let stale exit evidence take that newer transport over.
          persisted_pid = current.fetch("pid", nil).to_s
          polled_pid = agent.fetch("pid", nil).to_s
          if !persisted_pid.empty? && !polled_pid.empty? && persisted_pid != polled_pid
            return { "claimed" => false, "reason" => "stale_poll" }
          end

          episode_id = supervisor_recovery_episode_id(current, session_ref, supervision)
          metadata = current.fetch("harness_metadata", {}) || {}
          previous = metadata.fetch("supervisor_recovery", {}) || {}
          previous = {} unless previous.is_a?(Hash)
          previous = {} unless previous.fetch("episode_id", nil).to_s == episode_id

          if previous.fetch("state", nil) == "claimed"
            owner = other_live_instance_pid(
              previous.fetch("owner_instance_id", nil),
              previous.fetch("owner_instance_pid", nil),
              previous.fetch("owner_instance_started_at", nil)
            )
            return { "claimed" => false, "reason" => "claimed_by_live_instance", "owner_pid" => owner } if owner
          end
          return { "claimed" => false, "reason" => "already_recovered" } if previous.fetch("state", nil) == "resumed"

          attempt = previous.fetch("attempt_count", 0).to_i + 1
          if attempt > WORKER_SUPERVISOR_RECOVERY_MAX_ATTEMPTS
            return { "claimed" => false, "reason" => "attempts_exhausted" }
          end

          now = timestamp
          recovery_id = "#{episode_id}-attempt-#{attempt}"
          recovery = previous.merge(
            "state" => "claimed",
            "episode_id" => episode_id,
            "recovery_id" => recovery_id,
            "attempt_count" => attempt,
            "claimed_at" => now,
            "previous_pid" => current.fetch("pid", nil),
            "supervision" => bounded_supervision_evidence(supervision),
            **instance_ownership_metadata
          ).compact
          current["harness_metadata"] = metadata.merge("supervisor_recovery" => recovery)
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          {
            "claimed" => true,
            "attempt" => attempt,
            "episode_id" => episode_id,
            "recovery_id" => recovery_id
          }
        end
      end

      def bounded_supervision_evidence(supervision)
        return {} unless supervision.is_a?(Hash)

        supervision.slice(
          "source", "transport_key", "owner_pid", "owner_started_at", "owner_alive",
          "harness_pid", "harness_started_at", "harness_alive", "supervisor_exited", "observed_at"
        )
      end

      def supervisor_recovery_prompt(recovery_id)
        "#{WORKER_RESUME_PROMPT.rstrip}\n\n#{SUPERVISOR_RECOVERY_PROMPT_ID_LABEL}: #{recovery_id}"
      end

      def complete_worker_supervisor_recovery(agent, resumed_ref, claim:, supervision:, prompted:)
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id", nil))
          unless current
            return supervisor_recovery_deferred_poll_result(agent, resumed_ref, "reason" => "agent_not_found").merge(
              "recovery_session_cleanup_required" => true
            )
          end

          metadata = current.fetch("harness_metadata", {}) || {}
          recovery = metadata.fetch("supervisor_recovery", {}) || {}
          claim_current = recovery.is_a?(Hash) && recovery.fetch("recovery_id", nil).to_s == claim.fetch("recovery_id")
          if !claim_current || %w[completed killed].include?(current.fetch("status", nil)) || interactive_focus_active?(current)
            reason = if !claim_current
                       "claim_replaced"
                     elsif interactive_focus_active?(current)
                       "interactive_focus_active"
                     else
                       "terminal_status"
                     end
            return supervisor_recovery_deferred_poll_result(agent, resumed_ref, "reason" => reason).merge(
              "recovery_session_cleanup_required" => true
            )
          end

          now = timestamp
          merge_session_ref_into_agent!(current, resumed_ref)
          metadata = current.fetch("harness_metadata", {}) || {}
          recovery = recovery.merge(
            "state" => "resumed",
            "resumed_at" => now,
            "new_pid" => resumed_ref.fetch("pid", nil),
            "prompt_delivered" => !!prompted,
            "owner_instance_id" => instance_id,
            "owner_instance_pid" => instance_pid,
            "owner_instance_started_at" => instance_started_at
          ).compact
          metadata = metadata.merge("supervisor_recovery" => recovery)
          if prompted
            metadata = metadata.merge(
              "prompt_count" => metadata.fetch("prompt_count", 0).to_i + 1,
              "last_prompt_mode" => "normal",
              "last_prompted_at" => now,
              "routing_action" => "resume_session"
            )
          end
          current["harness_metadata"] = metadata
          clear_settle_failure!(current)
          current["status"] = "working"
          current["updated_at"] = now
          refresh_worker_parent_statuses!(state, current, now)
          log_ids = append_log(
            state,
            source_type: "worker",
            source_id: current.fetch("id"),
            level: "warning",
            message: "Automatically resumed worker #{current.fetch("id")} after its supervising Meringue process exited; " \
                     "its existing session and workspace were preserved.",
            details: {
              "recovery_id" => claim.fetch("recovery_id"),
              "attempt" => claim.fetch("attempt"),
              "prompt_delivered" => !!prompted,
              "workspace_path" => current.fetch("workspace_path", nil),
              "workspace_branch" => current.fetch("workspace_branch", nil),
              "supervision" => bounded_supervision_evidence(supervision)
            }.compact
          )
          log_ids.concat(append_session_model_substitution_log(state, current))
          touch_state!(state, now)
          store.save(state)
          {
            "agent_id" => current.fetch("id"),
            "agent_type" => "worker",
            "state" => "recovered",
            "session_ref" => resumed_ref,
            "supervisor_recovered" => true,
            "changed" => true,
            "recovery_id" => claim.fetch("recovery_id"),
            "log_entry_ids" => log_ids
          }
        end
      end

      def record_worker_supervisor_recovery_failure(agent, claim:, supervision:, error:)
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id", nil))
          next nil unless current

          metadata = current.fetch("harness_metadata", {}) || {}
          recovery = metadata.fetch("supervisor_recovery", {}) || {}
          next nil unless recovery.is_a?(Hash) && recovery.fetch("recovery_id", nil).to_s == claim.fetch("recovery_id")

          now = timestamp
          failed_recovery = recovery.merge(
            "state" => "failed",
            "failed_at" => now,
            "error_class" => error.class.name,
            "error_message" => sanitized_error_message(error),
            "supervision" => bounded_supervision_evidence(supervision)
          )
          current["harness_metadata"] = metadata.merge("supervisor_recovery" => failed_recovery)
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          deep_copy(failed_recovery)
        end
      end

      def supervisor_recovery_failed_poll_result(agent, session_ref, original_error, recovery_error, claim, supervision)
        attempt = claim.fetch("attempt")
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "worker",
          "state" => "errored",
          "session_ref" => session_ref,
          "error" => error_payload(recovery_error),
          "reconcile" => {
            "state" => RECONCILE_STATE_RESUME_FAILED,
            "kind" => "supervisor_exit_recovery",
            "resume_attempt_count" => attempt,
            "resume_attempts_remaining" => [WORKER_SUPERVISOR_RECOVERY_MAX_ATTEMPTS - attempt, 0].max,
            "resume_attempted_at" => timestamp,
            "recovery_id" => claim.fetch("recovery_id"),
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error),
            "error_class" => recovery_error.class.name,
            "error_message" => sanitized_error_message(recovery_error),
            "supervision" => bounded_supervision_evidence(supervision)
          }
        }
      end

      def supervisor_recovery_deferred_poll_result(agent, session_ref, claim)
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "worker",
          "state" => "unchanged",
          "session_ref" => session_ref,
          "changed" => false,
          "supervisor_recovery_deferred" => true,
          "recovery_claim" => claim,
          "log_entry_ids" => []
        }
      end

      def harness_process_gone_poll_result(agent, client, session_ref, error)
        # Recorded evidence underneath, fresh evidence on top: a client that can still describe the
        # exit wins, and one that cannot (a restart, a session this process never owned) falls back
        # to what the record already says instead of re-wording the same failure.
        evidence = recorded_process_exit_evidence(agent).merge(safe_session_exit_evidence(client, session_ref) || {})
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "worker",
          "state" => "settle_failed",
          "session_ref" => session_ref,
          # The harness journalled its own `process_exit` event before its pipes closed. Draining it
          # here is what finally puts that event in the log: the happy path never reached
          # `read_events`, because `get_state` raises first for a session whose process is gone.
          "events" => safe_read_events(client, session_ref),
          "last_assistant_text" => nil,
          "settle_failure" => harness_process_exit_settle_failure(error, evidence)
        }
      end

      def harness_process_exit_settle_failure(error, evidence)
        exit_status = evidence.fetch("exit_status", nil)
        exit_status = nil unless exit_status.is_a?(Hash)
        stderr_tail = present_string(evidence.fetch("stderr_tail", nil))
        {
          "kind" => SETTLE_FAILURE_PROCESS_EXIT_KIND,
          "reason" => harness_process_exit_reason(exit_status),
          "source" => "harness_process_exit",
          "error_class" => error&.class&.name,
          "error_message" => error && sanitized_error_message(error),
          "exit_status" => exit_status,
          "stderr_tail" => stderr_tail && truncate_for_state(stderr_tail, PROCESS_EXIT_STDERR_MAX_BYTES),
          "process_exited_at" => present_string(evidence.fetch("last_event_at", nil))
        }.compact
      end

      # Derived only from the exit status, which does not move for the life of the record: the reason
      # is part of the settle-failure signature that makes this log once instead of once per pass.
      def harness_process_exit_reason(exit_status)
        base = "its agent session process exited before it produced a result"
        detail = if exit_status.nil?
                   nil
                 elsif present_string(exit_status.fetch("termsig", nil))
                   "terminated by signal #{exit_status.fetch("termsig")}"
                 elsif !exit_status.fetch("exit_code", nil).nil?
                   "exit code #{exit_status.fetch("exit_code")}"
                 end
        detail ? "#{base} (#{detail})" : base
      end

      def harness_process_exit_failure?(failure)
        failure.is_a?(Hash) && failure.fetch("kind", nil).to_s == SETTLE_FAILURE_PROCESS_EXIT_KIND
      end

      def worker_harness_process_exited?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.is_a?(Hash) && harness_process_exit_failure?(metadata.fetch("settle_failure", nil))
      end

      def harness_process_exit_recovery_advice
        "Its session history and workspace are intact, so prompting this worker continues it in a new agent process."
      end

      # Evidence the record already carries. A Meringue restart loses the process object that knew
      # the exit status, and without this the same failure would be re-worded and therefore re-logged
      # as if it were new.
      def recorded_process_exit_evidence(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        failure = metadata.is_a?(Hash) ? metadata.fetch("settle_failure", nil) : nil
        return {} unless harness_process_exit_failure?(failure)

        {
          "exit_status" => failure.fetch("exit_status", nil),
          "stderr_tail" => failure.fetch("stderr_tail", nil),
          "last_event_at" => failure.fetch("process_exited_at", nil)
        }.compact
      end

      def safe_session_exit_evidence(client, session_ref)
        return nil unless client.respond_to?(:session_exit_evidence)

        evidence = client.session_exit_evidence(session_ref)
        evidence.is_a?(Hash) ? stringify_keys(evidence) : nil
      rescue StandardError
        nil
      end

      def safe_read_events(client, session_ref)
        return [] unless client.respond_to?(:read_events)

        Array(client.read_events(session_ref))
      rescue StandardError
        []
      end

      def resume_worker_session_from_poll_error(agent, client, session_ref, original_error)
        attempt = worker_resume_attempt_count(agent) + 1
        resumed_ref = nil
        resumed_ref = client.attach_session(session_ref)
        resumed_ref = prompt_resumed_worker_session(client, resumed_ref)
        {
          "agent_id" => agent.fetch("id"),
          "agent_type" => "worker",
          "state" => "working",
          "session_ref" => resumed_ref,
          "events" => client.respond_to?(:read_events) ? client.read_events(resumed_ref) : [],
          "last_assistant_text" => nil,
          "resumed" => true,
          "reconcile" => {
            "state" => RECONCILE_STATE_RESUMING,
            "resume_attempt_count" => attempt,
            "resume_attempted_at" => timestamp,
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error)
          }
        }
      rescue StandardError => resume_error
        # The attach may well have started a replacement harness process before the prompt failed.
        # Leaving it running is what let three failed resume attempts leave three untracked agent
        # processes writing to the same session file long after the worker had been settled.
        safely_kill_recovery_session(client, resumed_ref) if resumed_ref
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "worker",
          "state" => "errored",
          "session_ref" => session_ref,
          "error" => error_payload(resume_error),
          "reconcile" => worker_resume_failed_reconcile_model(agent, original_error, resume_error, attempt)
        }
      end

      def prompt_resumed_worker_session(client, session_ref)
        return session_ref unless client.respond_to?(:prompt_session)
        return session_ref if session_ref.fetch("is_streaming", false)

        client.prompt_session(session_ref, WORKER_RESUME_PROMPT, mode: "normal")
      end

      def worker_resume_failed_reconcile_model(agent, original_error, resume_error, attempt)
        {
          "state" => RECONCILE_STATE_RESUME_FAILED,
          "resume_attempt_count" => attempt,
          "resume_attempts_remaining" => [WORKER_RECONCILE_RESUME_MAX_ATTEMPTS - attempt, 0].max,
          "resume_attempted_at" => timestamp,
          "original_error_class" => original_error.class.name,
          "original_error_message" => sanitized_error_message(original_error),
          "error_class" => resume_error.class.name,
          "error_message" => sanitized_error_message(resume_error)
        }
      end

      def worker_resume_attempt_count(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile.fetch("resume_attempt_count", reconcile.fetch("error_count", 0)).to_i
      end

      def head_reconcile_recovery_eligible?(agent)
        return false unless agent.fetch("type", nil) == "head"
        return false if %w[completed killed].include?(agent.fetch("status", nil))
        return false if head_recovery_attempt_count(agent) >= HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS

        metadata = agent.fetch("harness_metadata", {}) || {}
        reconcile = metadata.fetch("reconcile", {}) || {}
        first_error_at = reconcile.fetch("first_error_at", nil)
        return true if agent.fetch("status", nil) == "errored" && present_string(first_error_at)
        return false unless present_string(first_error_at)

        !head_reconcile_grace_active?(first_error_at, timestamp)
      end

      def head_recovery_attempt_count(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile.fetch("head_recovery_attempt_count", metadata.fetch("head_recovery_attempt_count", 0)).to_i
      end

      def recover_head_session_from_poll_error(agent, client, session_ref, original_error)
        attempt = head_recovery_attempt_count(agent) + 1
        request = head_recovery_request(agent)
        resumed_ref = nil
        attach_error = nil

        if agent_has_session_reference?(agent) && client.respond_to?(:attach_session)
          begin
            resumed_ref = client.attach_session(session_ref)
            resumed_ref = prompt_recovered_head_session(client, resumed_ref)
            return recovered_head_poll_result(
              agent,
              client,
              resumed_ref,
              original_error,
              attempt: attempt,
              mode: "resumed"
            )
          rescue StandardError => e
            attach_error = e
            safely_kill_recovery_session(client, resumed_ref) if resumed_ref
          end
        end

        raise attach_error || RuntimeError.new("persisted head request is unavailable") if request.nil?

        restarted_ref = restart_head_session(agent, request)
        recovered_head_poll_result(
          agent,
          client_for_restarted_head(agent),
          restarted_ref,
          original_error,
          attempt: attempt,
          mode: "restarted",
          attach_error: attach_error
        )
      rescue StandardError => recovery_error
        previous_reconcile = (agent.fetch("harness_metadata", {}) || {}).fetch("reconcile", {}) || {}
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "head",
          "state" => "errored",
          "session_ref" => session_ref,
          "error" => error_payload(recovery_error),
          "reconcile" => previous_reconcile.merge(
            "state" => RECONCILE_STATE_TRANSIENT_ERROR,
            "head_recovery_attempt_count" => attempt || head_recovery_attempt_count(agent) + 1,
            "head_recovery_attempted_at" => timestamp,
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error),
            "recovery_error_class" => recovery_error.class.name,
            "recovery_error_message" => sanitized_error_message(recovery_error)
          ).compact
        }
      end

      def prompt_recovered_head_session(client, session_ref)
        return session_ref if session_ref.fetch("is_streaming", false)

        client.prompt_session(session_ref, HEAD_RESUME_PROMPT, mode: "normal")
      end

      def restart_head_session(agent, request)
        runner = active_head_runner(provider: agent.fetch("harness", nil))
        unless runner.respond_to?(:spawn_head_session)
          raise RuntimeError, "head runner cannot restart a persisted session"
        end

        snapshot = synchronized_state { deep_copy(normalized_state) }
        context = Heads::Context.new(
          head_id: agent.fetch("id"),
          user_message: request.fetch("user_message"),
          snapshot: snapshot,
          question_id: request.fetch("question_id", nil),
          selected_target: request.fetch("selected_target", nil),
          takeover_context: request.fetch("takeover_context", nil),
          cwd: cwd,
          state_path: store.path,
          github_support: github_support_enabled?(snapshot),
          worker_spawning_guidance: worker_spawning_guidance_for_head?(agent),
          worker_spawning_guidance_prompt: worker_spawning_guidance_prompt
        )
        runner.spawn_head_session(
          user_message: request.fetch("user_message"),
          snapshot: context.snapshot,
          question_id: request.fetch("question_id", nil),
          context: context
        )
      end

      def head_recovery_request(agent)
        head_request_from_metadata(agent) || synchronized_state { head_request_from_logs(normalized_state, agent) }
      end

      # Same lookup for callers that already hold the state lock (head retry planning).
      def head_request_in_state(state, agent)
        head_request_from_metadata(agent) || head_request_from_logs(state, agent)
      end

      def head_request_from_metadata(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        request = metadata.fetch("head_request", {}) || {}
        request = {} unless request.is_a?(Hash)
        user_message = present_string(request.fetch("user_message", nil))
        return nil unless user_message

        {
          "user_message" => user_message,
          "question_id" => present_string(request.fetch("question_id", nil)),
          "selected_target" => request.fetch("selected_target", nil),
          "takeover_of_head_id" => present_string(request.fetch("takeover_of_head_id", nil)),
          "follow_up_of_head_id" => present_string(request.fetch("follow_up_of_head_id", nil)),
          "takeover_context" => request.fetch("takeover_context", nil)
        }.compact
      end

      # Older head records (and records written before `head_request` existed) still have the
      # user's own prompt in the log the kernel wrote when it spawned them.
      def head_request_from_logs(state, agent)
        log = state.fetch("logs", []).reverse.find do |entry|
          entry.fetch("source_type", nil) == "user" && entry.dig("details", "head_id").to_s == agent.fetch("id").to_s
        end
        message = log && present_string(log.fetch("message", nil))
        return nil unless message

        {
          "user_message" => message,
          "question_id" => present_string(log.dig("details", "question_id")),
          "selected_target" => log.dig("details", "selected_target")
        }.compact
      end

      def recovered_head_poll_result(agent, client, session_ref, original_error, attempt:, mode:, attach_error: nil)
        metadata = session_ref.fetch("metadata", {}) || {}
        request = head_recovery_request(agent)
        session_ref = session_ref.merge(
          "metadata" => metadata.merge(
            "head_request" => request,
            "head_recovery_attempt_count" => attempt,
            "head_recovery_mode" => mode,
            "head_recovered_at" => timestamp
          ).compact
        )
        completed = completed_session?(session_ref)
        original_identity = session_ref_identity(agent_session_ref(agent))
        result = {
          "agent_id" => agent.fetch("id"),
          "agent_type" => "head",
          "state" => completed ? "completed" : "working",
          "session_ref" => session_ref,
          "events" => client.respond_to?(:read_events) ? client.read_events(session_ref) : [],
          "last_assistant_text" => completed ? safe_last_assistant_text(client, session_ref) : nil,
          "reconcile" => {
            "state" => RECONCILE_STATE_RESUMING,
            "head_recovery_attempt_count" => attempt,
            "head_recovery_attempted_at" => timestamp,
            "head_recovery_mode" => mode,
            "original_pid" => original_identity.fetch("pid", nil),
            "original_session_id" => original_identity.fetch("session_id", nil),
            "original_session_file" => original_identity.fetch("session_file", nil),
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error),
            "attach_error_class" => attach_error&.class&.name,
            "attach_error_message" => attach_error && sanitized_error_message(attach_error)
          }.compact
        }
        result[mode == "resumed" ? "resumed" : "restarted"] = true
        result
      end

      def session_ref_identity(session_ref)
        {
          "pid" => session_ref.fetch("pid", nil),
          "session_id" => session_ref.fetch("session_id", nil),
          "session_file" => session_ref.fetch("session_file", nil)
        }.compact
      end

      def client_for_restarted_head(agent)
        runner = active_head_runner(provider: agent.fetch("harness", nil))
        return runner.harness_client if runner.respond_to?(:harness_client)

        harness_client_for_agent(agent)
      end

      def safely_kill_recovery_session(client, session_ref)
        client.kill_session(session_ref) if client.respond_to?(:kill_session)
      rescue StandardError
        nil
      end

      def defer_head_reconcile_error_from_poll(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))
          return mark_agent_errored_from_poll(poll_result) unless agent.fetch("type", nil) == "head"

          now = timestamp
          metadata = agent.fetch("harness_metadata", {}) || {}
          previous_reconcile = metadata.fetch("reconcile", {}) || {}
          first_error_at = previous_reconcile.fetch("first_error_at", nil) || existing_error_reference_at(agent) || now
          error_count = previous_reconcile.fetch("error_count", 0).to_i + 1
          warning_logged_at = previous_reconcile.fetch("warning_logged_at", nil)

          reconcile = poll_result.fetch("reconcile", {}).merge(
            "state" => RECONCILE_STATE_TRANSIENT_ERROR,
            "first_error_at" => first_error_at,
            "last_error_at" => now,
            "error_count" => error_count,
            "grace_seconds" => HEAD_RECONCILE_ERROR_GRACE_SECONDS,
            "warning_delay_seconds" => HEAD_RECONCILE_WARNING_DELAY_SECONDS,
            "warning_logged_at" => warning_logged_at
          ).compact

          return mark_agent_errored_from_poll(poll_result.merge("reconcile" => reconcile)) unless head_reconcile_grace_active?(first_error_at, now)

          log_ids = []
          if warning_logged_at.nil? && head_reconcile_warning_due?(agent, first_error_at, now)
            reconcile["warning_logged_at"] = now
            log_ids = append_log(
              state,
              source_type: "head",
              source_id: agent.fetch("id"),
              level: "warning",
              message: "Head #{agent.fetch("id")} had a transient agent session reconciliation error; keeping it working during the startup grace window.",
              details: reconcile
            )
          end

          agent["status"] = "working"
          agent["updated_at"] = now
          agent["harness_metadata"] = metadata.merge(
            "reconcile_state" => RECONCILE_STATE_TRANSIENT_ERROR,
            "reconcile" => reconcile
          ).compact

          touch_state!(state, now)
          store.save(state)
          poll_result.merge("state" => "working", "changed" => true, "deferred" => true, "reconcile" => reconcile, "log_entry_ids" => log_ids)
        end
      end

      def defer_worker_reconcile_error_from_poll(poll_result)
        return mark_agent_errored_from_poll(poll_result) if poll_result.dig("reconcile", "resume_attempt_count").to_i >= WORKER_RECONCILE_RESUME_MAX_ATTEMPTS

        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))
          return mark_agent_errored_from_poll(poll_result) unless agent.fetch("type", nil) == "worker"

          now = timestamp
          metadata = agent.fetch("harness_metadata", {}) || {}
          reconcile = poll_result.fetch("reconcile", {}).merge("state" => RECONCILE_STATE_RESUME_FAILED).compact
          attempt = reconcile.fetch("resume_attempt_count", 0).to_i
          warning_logged_attempt = metadata.fetch("resume_warning_logged_attempt", nil)
          if agent.fetch("status", nil) == "blocked" && !warning_logged_attempt.nil? && warning_logged_attempt.to_i == attempt
            return poll_result.merge("changed" => false, "blocked" => true, "reconcile" => metadata.fetch("reconcile", reconcile), "log_entry_ids" => [])
          end
          should_log_warning = warning_logged_attempt.to_i != attempt
          reconcile["warning_logged_attempt"] = attempt if should_log_warning
          agent["status"] = "blocked"
          agent["updated_at"] = now
          agent["harness_metadata"] = metadata.merge(
            "is_streaming" => false,
            "resume_warning_logged_attempt" => attempt,
            "reconcile_state" => RECONCILE_STATE_RESUME_FAILED,
            "reconcile" => reconcile
          ).compact
          refresh_worker_parent_statuses!(state, agent, now)
          log_ids = if should_log_warning
                       append_log(
                         state,
                         source_type: "worker",
                         source_id: agent.fetch("id"),
                         level: "warning",
                         message: "Worker #{agent.fetch("id")} could not resume its agent session; will retry reconciliation.",
                         details: reconcile
                       )
                     else
                       []
                     end
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => true, "blocked" => true, "reconcile" => reconcile, "log_entry_ids" => log_ids)
        end
      end

      def mark_agent_errored_from_poll(poll_result)
        takeover_previous_head_id = nil
        result = synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))

          takeover_previous_head_id = present_string(agent.dig("harness_metadata", "takeover_of_head_id")) if agent.fetch("type", nil) == "head"
          now = timestamp
          reconcile = terminal_reconcile_error_model(poll_result, now)
          # Recording the same terminal failure twice is not a state change: it would bump
          # `updated_at`, rewrite the state file, and append a duplicate error log on every
          # reconciliation pass. A genuinely different failure still transitions and logs.
          if repeated_terminal_reconcile_error?(agent, reconcile)
            return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "already_errored")
          end

          agent["status"] = "errored"
          agent["updated_at"] = now
          # AGENTS.md: the kernel closes a head's harness session when the head errors. Without
          # this a terminally failed head keeps an orphaned harness process alive forever.
          session_release = if agent.fetch("type", nil) == "head"
                              release_head_session!(agent, reason: "head_reconcile_error", now: now)
                            end
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "is_streaming" => false,
            "error_class" => poll_result.dig("error", "class"),
            "error_message" => poll_result.dig("error", "message"),
            "errored_at" => now,
            "reconcile_state" => RECONCILE_STATE_TERMINAL_ERROR,
            "reconcile" => reconcile
          ).compact

          if agent.fetch("type", nil) == "worker"
            issue = find_issue(state, agent.fetch("issue_id", nil))
            project = issue && find_project(state, issue.fetch("project_id", nil))
            update_issue_status_from_workers!(state, issue, now) if issue
            update_project_status_from_issues!(state, project, now) if project
          end

          details = if session_release && session_release.fetch("changed", false)
                      reconcile.merge("head_session_released" => true)
                    else
                      reconcile
                    end
          log_ids = append_log(
            state,
            source_type: agent.fetch("type", nil) == "head" ? "head" : "worker",
            source_id: agent.fetch("id"),
            level: "error",
            message: "#{agent.fetch("type", "Agent").capitalize} #{agent.fetch("id")} errored while reconciling its agent session.",
            details: details
          )
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => true, "log_entry_ids" => log_ids)
        end
        if takeover_previous_head_id
          rollback_head_takeover!(takeover_previous_head_id, poll_result.fetch("agent_id"), reason: "successor_head_errored")
        end
        result
      end

      # Same record, same terminal failure: nothing new to persist or tell the user about.
      # `last_error_at` moves every pass, so identity is the failure itself, not its timestamp.
      def repeated_terminal_reconcile_error?(agent, reconcile)
        return false unless terminal_reconcile_error_recorded?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        reconcile_error_signature(metadata.fetch("reconcile", {})) == reconcile_error_signature(reconcile)
      end

      def reconcile_error_signature(reconcile)
        reconcile = {} unless reconcile.is_a?(Hash)
        {
          "state" => reconcile.fetch("state", nil).to_s,
          "error_class" => reconcile.fetch("error_class", nil).to_s,
          "error_message" => reconcile.fetch("error_message", nil).to_s
        }
      end

      def terminal_reconcile_error_model(poll_result, now)
        reconcile = poll_result.fetch("reconcile", {}) || {}
        reconcile.merge(
          "state" => RECONCILE_STATE_TERMINAL_ERROR,
          "last_error_at" => now,
          "error_class" => reconcile.fetch("error_class", poll_result.dig("error", "class")),
          "error_message" => reconcile.fetch("error_message", poll_result.dig("error", "message"))
        ).compact
      end

      # An already-errored head must not earn a fresh startup grace window (and be flipped back
      # to `working`) just because reconciliation noticed it again. Judge the window from when
      # the record actually failed instead of from now.
      def existing_error_reference_at(agent)
        return nil unless agent.fetch("status", nil) == "errored"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        present_string(metadata.fetch("errored_at", nil)) || present_string(agent.fetch("updated_at", nil))
      end

      def head_reconcile_grace_active?(first_error_at, now)
        (Time.iso8601(now) - Time.iso8601(first_error_at.to_s)) < HEAD_RECONCILE_ERROR_GRACE_SECONDS
      rescue ArgumentError, TypeError
        false
      end

      # The window between a head record being saved and its harness session being recorded. It is
      # bounded so a record left `pending` by an instance that died mid-spawn becomes recoverable
      # again rather than being excused forever.
      def session_spawn_grace_active?(started_at, now)
        (Time.iso8601(now) - Time.iso8601(started_at.to_s)) < HEAD_SESSION_SPAWN_GRACE_SECONDS
      rescue ArgumentError, TypeError
        false
      end

      # An interactive provider can have a live PTY before its transcript reader has observed the
      # first turn. In that narrow startup window, an empty/unknown conversation is not a completed
      # head result. Keep the head working while its owned process is alive; once the window expires,
      # the normal invalid-result repair and genuine failure paths remain authoritative.
      def head_startup_grace_active?(agent, session_ref)
        return false unless agent.fetch("type", nil) == "head"
        return false unless session_ref.is_a?(Hash)

        metadata = session_ref.fetch("metadata", {}) || {}
        metadata = stringify_keys(metadata) if metadata.is_a?(Hash)
        return false unless metadata.is_a?(Hash)
        return false unless metadata.fetch("session_state", nil).to_s == "unknown"
        return false if truthy?(metadata.fetch("process_gone", false))

        pid = session_ref.fetch("pid", nil).to_i
        return false unless pid.positive? && owner_process_alive?(pid)

        started_at = metadata.fetch("head_session_started_at", nil) ||
                     metadata.fetch("started_at", nil) ||
                     agent.fetch("created_at", nil)
        started_at && head_reconcile_grace_active?(started_at, timestamp)
      end

      def head_reconcile_warning_due?(agent, first_error_at, now)
        started_at = agent.fetch("created_at", nil) || first_error_at
        reference_time = [parse_time_or_nil(started_at), parse_time_or_nil(first_error_at)].compact.min
        return true unless reference_time

        (Time.iso8601(now) - reference_time) >= HEAD_RECONCILE_WARNING_DELAY_SECONDS
      rescue ArgumentError, TypeError
        true
      end

      def parse_time_or_nil(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def worker_parent_statuses(state, agent)
        return nil unless agent.fetch("type", nil) == "worker"

        issue = find_issue(state, agent.fetch("issue_id", nil))
        project = issue && find_project(state, issue.fetch("project_id", nil))
        [issue&.fetch("status", nil), project&.fetch("status", nil)]
      end

      def refresh_worker_parent_statuses!(state, agent, now)
        issue = find_issue(state, agent.fetch("issue_id", nil))
        project = issue && find_project(state, issue.fetch("project_id", nil))
        update_issue_status_from_workers!(state, issue, now) if issue
        update_project_status_from_issues!(state, project, now) if project
      end

      def append_recovery_success_log(state, agent, poll_result)
        return [] unless poll_result.fetch("resumed", false) || poll_result.fetch("restarted", false)

        if agent.fetch("type", nil) == "head"
          restarted = poll_result.fetch("restarted", false)
          append_log(
            state,
            source_type: "head",
            source_id: agent.fetch("id"),
            level: restarted ? "warning" : "info",
            message: restarted ?
              "Restarted agent session for head #{agent.fetch("id")} because its persisted session could not be safely resumed." :
              "Resumed agent session for head #{agent.fetch("id")} and requested its HeadResult.",
            details: poll_result.fetch("reconcile", {})
          )
        else
          append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "info",
            message: "Resumed agent session for worker #{agent.fetch("id")} and prompted it to continue.",
            details: poll_result.fetch("reconcile", {})
          )
        end
      end
    end
  end
end
