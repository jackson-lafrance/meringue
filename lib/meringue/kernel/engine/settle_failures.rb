# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Classifying how a turn ended. A turn that died with the transport, or a session that
      # disappeared without a final message, is not a completion.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # "Not streaming any more" is the only thing a harness state call can tell us, and it is
      # true both for a finished turn and for a turn that died mid-flight. Callers must pair this
      # with `settle_failure_from_evidence` before recording a completion.
      def completed_session?(session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        return true if metadata.fetch("completed", false)

        !session_ref.fetch("is_streaming", false)
      end

      # Evidence that a settled turn ended without finishing, in order of authority:
      #   1. the harness's own turn outcome, including a persisted provider/transport stop reason
      #      that keeps a dropped connection visible after the fact
      #   2. a turn outcome a harness already attached to the session ref metadata
      #   3. session events proving the transport died, but only when the settled turn produced
      #      no final assistant message at all
      # Returns nil when there is no failure evidence, which keeps genuine completions intact.
      def settle_failure_from_evidence(session_ref: nil, events: [], last_assistant_text: nil, client: nil)
        failure = settle_failure_from_turn_outcome(turn_outcome_evidence(client, session_ref))
        return failure if failure
        return nil if present_string(last_assistant_text)

        failure = settle_failure_from_events(events)
        return failure if failure

        settle_failure_from_session_exit(session_ref)
      end

      # Interactive clients can lose their in-memory process entry before the kernel asks for state
      # (for example after a Claude PTY exits or after Meringue restarts). That state is non-streaming,
      # but it is not a completion unless the transcript supplied a final assistant response. The
      # client marks this durable absence explicitly so it cannot be mistaken for a clean turn.
      def settle_failure_from_session_exit(session_ref)
        return nil unless session_ref.is_a?(Hash)

        metadata = session_ref.fetch("metadata", {}) || {}
        metadata = stringify_keys(metadata) if metadata.is_a?(Hash)
        return nil unless metadata.is_a?(Hash)
        return nil unless truthy?(metadata.fetch("process_gone", false)) || metadata.fetch("exit_status", nil).is_a?(Hash)

        evidence = {
          "exit_status" => metadata.fetch("exit_status", nil),
          "stderr_tail" => metadata.fetch("stderr_tail", nil),
          "last_event_at" => metadata.fetch("process_exited_at", nil) || metadata.fetch("last_event_at", nil)
        }.compact
        harness_process_exit_settle_failure(nil, evidence)
      end

      def worker_settle_failure(agent_id:, session_ref:, events:, last_assistant_text:)
        settle_failure_from_evidence(
          session_ref: session_ref,
          events: events,
          last_assistant_text: last_assistant_text,
          client: session_ref ? settle_evidence_client(agent_id) : nil
        )
      end

      def settle_evidence_client(agent_id)
        agent = synchronized_state { find_agent(normalized_state, agent_id.to_s) }
        return nil unless agent

        harness_client_for_agent(agent)
      rescue StandardError
        nil
      end

      def turn_outcome_evidence(client, session_ref)
        from_client = safe_turn_outcome(client, session_ref)
        return from_client if from_client.is_a?(Hash)

        metadata = session_ref.is_a?(Hash) ? (session_ref["metadata"] || session_ref[:metadata] || {}) : {}
        outcome = metadata.is_a?(Hash) ? (metadata["turn_outcome"] || metadata[:turn_outcome]) : nil
        outcome.is_a?(Hash) ? stringify_keys(outcome) : nil
      end

      def safe_turn_outcome(client, session_ref)
        return nil unless client && session_ref
        return nil unless client.respond_to?(:turn_outcome)

        outcome = client.turn_outcome(session_ref)
        outcome.is_a?(Hash) ? stringify_keys(outcome) : nil
      rescue StandardError
        nil
      end

      def settle_failure_from_turn_outcome(outcome)
        return nil unless outcome.is_a?(Hash)
        return nil unless SETTLE_FAILURE_TURN_STATES.include?(outcome.fetch("state", nil).to_s)

        error_message = present_string(outcome.fetch("error_message", nil))
        {
          "kind" => present_string(outcome.fetch("kind", nil)) || settle_failure_kind(error_message),
          "reason" => present_string(outcome.fetch("reason", nil)) || settle_failure_reason(error_message),
          "source" => "harness_turn_outcome",
          "stop_reason" => present_string(outcome.fetch("stop_reason", nil)),
          "error_message" => error_message,
          "turn_ended_at" => present_string(outcome.fetch("turn_ended_at", nil)) ||
                             present_string(outcome.fetch("ended_at", nil)),
          "last_assistant_text" => present_string(outcome.fetch("last_assistant_text", nil))
        }.compact
      end

      # A tool call can be the last durable record even though the worker's session remains
      # available. That is incomplete work, not a failed worker: keep it idle and promptable.
      def recoverable_incomplete_turn?(failure, agent)
        return false unless failure.is_a?(Hash) && agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent_has_session_reference?(agent)

        kind = failure.fetch("kind", nil).to_s
        stop_reason = failure.fetch("stop_reason", nil).to_s
        RECOVERABLE_INCOMPLETE_TURN_KINDS.include?(kind) || %w[toolUse tool_use].include?(stop_reason)
      end

      def incomplete_turn_already_recorded?(agent, failure)
        metadata = agent.fetch("harness_metadata", {}) || {}
        existing = metadata.is_a?(Hash) ? metadata.fetch("incomplete_turn", nil) : nil
        existing.is_a?(Hash) && settle_failure_signature(existing) == settle_failure_signature(failure)
      end

      def incomplete_turn_status_reason(failure)
        "#{failure.fetch("reason")}. Its agent session remains recoverable; prompt it to continue."
      end

      def clear_incomplete_turn!(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return unless metadata.is_a?(Hash)

        incomplete = metadata.fetch("incomplete_turn", nil)
        return unless incomplete.is_a?(Hash)

        cleared = metadata.dup
        cleared.delete("incomplete_turn")
        cleared.delete("status_reason") if cleared.fetch("status_reason", nil) == incomplete_turn_status_reason(incomplete)
        agent["harness_metadata"] = cleared
      end

      def settle_failure_from_events(events)
        Array(events).each do |event|
          next unless event.is_a?(Hash)

          failure = settle_failure_from_event(stringify_keys(event))
          return failure if failure
        end

        nil
      end

      def settle_failure_from_event(event)
        event_type = event.fetch("type", "").to_s
        message = event.fetch("message", nil)
        message = message.is_a?(Hash) ? message : {}
        stop_reason = message["stopReason"] || message["stop_reason"] || event["stopReason"] || event["stop_reason"]
        error_message = present_string(
          message["errorMessage"] || message["error_message"] ||
            event["errorMessage"] || event["error_message"] || event["error"]
        )

        if SETTLE_FAILURE_EVENT_STOP_REASONS.include?(stop_reason.to_s)
          return {
            "kind" => settle_failure_kind(error_message),
            "reason" => settle_failure_reason(error_message),
            "source" => "harness_events",
            "event_type" => event_type,
            "stop_reason" => stop_reason.to_s,
            "error_message" => error_message
          }.compact
        end

        return nil unless SETTLE_FAILURE_TRANSPORT_EVENT_TYPES.include?(event_type)

        {
          "kind" => "transport_failure",
          "reason" => "its agent session ended before it produced a result",
          "source" => "harness_events",
          "event_type" => event_type,
          "error_message" => error_message
        }.compact
      end

      def settle_failure_kind(error_message)
        return SETTLE_FAILURE_UNREPLAYABLE_KIND if SETTLE_FAILURE_UNREPLAYABLE_PATTERN.match?(error_message.to_s)

        SETTLE_FAILURE_NETWORK_PATTERN.match?(error_message.to_s) ? "network_failure" : "provider_error"
      end

      def settle_failure_reason(error_message)
        detail = error_message.to_s.strip
        if SETTLE_FAILURE_UNREPLAYABLE_PATTERN.match?(detail)
          "its saved session can no longer be replayed to the model, so resuming it fails the same way every time (#{detail})"
        elsif SETTLE_FAILURE_NETWORK_PATTERN.match?(detail)
          "its model request failed mid-turn (network error: #{detail})"
        elsif detail.empty?
          "its agent turn ended without finishing"
        else
          "its agent turn ended without finishing (#{detail})"
        end
      end

      def settle_failure_record(settle_failure)
        failure = settle_failure.is_a?(Hash) ? stringify_keys(settle_failure) : {}
        reason = present_string(failure.fetch("reason", nil)) || "its agent turn ended without finishing"
        # The worker's own final text is stored once, on the record; do not duplicate it here.
        failure.reject { |key, _| key == "last_assistant_text" }.merge(
          "kind" => present_string(failure.fetch("kind", nil)) || "turn_failed",
          "reason" => truncate_for_state(reason, ERROR_MESSAGE_MAX_BYTES),
          "source" => present_string(failure.fetch("source", nil)) || "kernel"
        ).compact
      end

      def settle_failure_status_reason(failure)
        "errored without finishing: #{failure.fetch("reason")}"
      end

      def settle_failure_signature(failure)
        return nil unless failure.is_a?(Hash)

        %w[kind reason source stop_reason error_message event_type].map { |key| failure.fetch(key, nil).to_s }.join("|")
      end

      def settle_failure_already_recorded?(agent, failure)
        return false unless agent.fetch("status", nil) == "errored"

        existing = (agent.fetch("harness_metadata", {}) || {}).fetch("settle_failure", nil)
        return false unless existing.is_a?(Hash)

        settle_failure_signature(existing) == settle_failure_signature(failure)
      end

      # A prompt that landed after the turn died is the recovery. Persisted evidence of that old
      # turn must not error the worker again while it is working on the new prompt.
      def stale_settle_failure_evidence?(agent, failure)
        metadata = agent.fetch("harness_metadata", {}) || {}
        prompted_at = parse_time_or_nil(metadata.fetch("last_prompted_at", nil))
        return false unless prompted_at

        turn_ended_at = parse_time_or_nil(failure.fetch("turn_ended_at", nil))
        return turn_ended_at <= prompted_at if turn_ended_at

        # Harnesses that cannot timestamp the turn fall back to "this exact failure was already
        # recorded and then prompted past".
        previous = metadata.fetch("previous_settle_failure", nil)
        return false unless previous.is_a?(Hash) && settle_failure_signature(previous) == settle_failure_signature(failure)

        detected_at = parse_time_or_nil(previous.fetch("detected_at", nil))
        detected_at ? detected_at <= prompted_at : false
      end

      # A worker whose turn died still owns a live, resumable harness session, its worktree, and
      # its branch, so it can be prompted to continue. That is what separates this errored state
      # from a worker whose session is gone.
      def worker_resumable_after_settle_failure?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "errored"
        # The one dead turn that resuming can never repair: the provider rejected the saved
        # transcript, so sending it again is the same request. Such a worker is recovered by
        # restarting its work in a fresh session on the same worktree, never by a resume.
        return false if worker_session_unreplayable?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.fetch("settle_failure", nil).is_a?(Hash) && agent_has_session_reference?(agent)
      end

      # --- sessions the provider refuses to replay -------------------------------------------
      #
      # A worker's turn can die in a way no resume can fix: the model provider rejects the saved
      # transcript itself (an interrupted assistant turn whose `thinking` blocks it will not accept
      # back). Resuming replays exactly the same turn, so every attempt fails identically and the
      # worker - plus everything queued behind it - is dead-ended.
      #
      # The transcript belongs to the harness, so Meringue does not try to repair it. What it owns
      # is the workspace: the worktree, the branch, and the work already committed there. So the
      # recovery is a fresh session on the *same* worktree and branch, spawned as a replacement so
      # queued dependents follow the successor instead of waiting on a session that cannot start.
      def unreplayable_session_failure?(failure)
        return false unless failure.is_a?(Hash)
        return true if failure.fetch("kind", nil).to_s == SETTLE_FAILURE_UNREPLAYABLE_KIND

        SETTLE_FAILURE_UNREPLAYABLE_PATTERN.match?(failure.fetch("error_message", nil).to_s)
      end

      def worker_session_unreplayable?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        unreplayable_session_failure?(metadata.fetch("settle_failure", nil))
      end

      def worker_session_recovery(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        metadata = {} unless metadata.is_a?(Hash)
        recovery = metadata.fetch("session_recovery", {}) || {}
        recovery.is_a?(Hash) ? recovery : {}
      end

      def worker_session_restart_chain_depth(agent)
        worker_session_recovery(agent).fetch("restart_chain_depth", 0).to_i
      end

      # Everything that must be true before the kernel spends a fresh session on this recovery.
      def worker_session_restart_eligible?(agent)
        return false unless worker_session_unreplayable?(agent)
        return false if agent.fetch("status", nil) == "killed"

        recovery = worker_session_recovery(agent)
        return false if present_string(recovery.fetch("restarted_by_agent_id", nil))
        return false if recovery.fetch("restart_attempts", 0).to_i >= WORKER_SESSION_RESTART_MAX_ATTEMPTS
        return false if worker_session_restart_chain_depth(agent) >= WORKER_SESSION_RESTART_MAX_CHAIN_DEPTH
        return false if present_string(agent.fetch("replaced_by_agent_id", nil))

        workspace_path = present_string(agent.fetch("workspace_path", nil))
        !!workspace_path && Dir.exist?(File.expand_path(workspace_path))
      end

      def unreplayable_session_recovery_record(agent, now, extra = {})
        recovery = worker_session_recovery(agent)
        recovery.merge(
          "state" => "session_unreplayable",
          "detected_at" => recovery.fetch("detected_at", nil) || now,
          "recommended_action" => "restart_session_in_place",
          "workspace_path" => agent.fetch("workspace_path", nil),
          "workspace_branch" => agent.fetch("workspace_branch", nil),
          "restart_attempts" => recovery.fetch("restart_attempts", 0).to_i,
          "restart_chain_depth" => worker_session_restart_chain_depth(agent)
        ).merge(extra).compact
      end

      # What the record, the log line, and the focused pane tell the user. Deliberately concrete:
      # the branch is what they care about, because it is where the work already is.
      def unreplayable_session_recovery_advice(agent)
        branch = present_string(agent.fetch("workspace_branch", nil))
        location = branch ? "worktree and branch #{branch}" : "worktree"
        "Its #{location} still hold the work, so Meringue does not resume this session: continuing " \
          "means a fresh session on the same workspace."
      end

      def settle_failure_log_message(agent, failure)
        base = "Worker #{agent.fetch("id")} errored without finishing: #{failure.fetch("reason")}"
        return "#{base}. #{unreplayable_session_recovery_advice(agent)}" if unreplayable_session_failure?(failure)
        return "#{base}. #{harness_process_exit_recovery_advice}" if harness_process_exit_failure?(failure)

        base
      end

      def worker_session_restart_command_id(agent_id, attempt)
        "session-restart-#{agent_id}-#{attempt}"
      end

      # Reserves this worker's single in-place restart under the state lock, so two reconcile passes
      # (or two kernel instances sharing one state file) cannot both spend it.
      def claim_worker_session_restart(agent_id, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return { "claimed" => false, "reason" => "agent_not_found" } unless agent
          return { "claimed" => false, "reason" => "not_eligible" } unless worker_session_restart_eligible?(agent)

          now = timestamp
          attempt = worker_session_recovery(agent).fetch("restart_attempts", 0).to_i + 1
          metadata = agent.fetch("harness_metadata", {}) || {}
          agent["harness_metadata"] = metadata.merge(
            "session_recovery" => unreplayable_session_recovery_record(
              agent,
              now,
              "restart_attempts" => attempt,
              "restart_claimed_at" => now,
              "restart_trigger" => trigger.to_s
            )
          )
          agent["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          {
            "claimed" => true,
            "agent" => deep_copy(agent),
            "attempt" => attempt,
            "restart_command_id" => worker_session_restart_command_id(agent_id.to_s, attempt)
          }
        end
      end

      # The recovery itself: a replacement worker with a fresh session on the dead worker's own
      # worktree and branch. Spawning it as a replacement is what unblocks the queue - dependents
      # waiting on the dead worker are repointed at the successor by SpawnWorker itself.
      #
      # Must be called *outside* `synchronized_state`: it applies a SpawnWorker command.
      def restart_unreplayable_worker_session(agent_id, trigger:, instruction: nil)
        claim = claim_worker_session_restart(agent_id, trigger: trigger)
        return claim unless claim.fetch("claimed", false)

        agent = claim.fetch("agent")
        result = apply(
          "command_id" => claim.fetch("restart_command_id"),
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => agent.fetch("issue_id", nil),
            "prompt" => unreplayable_session_restart_prompt(agent, instruction: instruction),
            "title" => worker_session_restart_title(agent),
            "replace_agent_id" => agent.fetch("id"),
            "_inherit_workspace_from_agent_id" => agent.fetch("id"),
            "_session_restart_of_agent_id" => agent.fetch("id")
          }.compact
        )
        record_worker_session_restart_outcome(agent, claim, result, trigger: trigger)
      rescue StandardError => e
        # The record still has to say what happened, and the log line still has to be written under
        # the state lock, so the failure is reported through the same outcome path.
        record_worker_session_restart_outcome(
          (claim.is_a?(Hash) && claim.fetch("agent", nil)) || { "id" => agent_id.to_s },
          claim.is_a?(Hash) ? claim : {},
          {
            "command_type" => "SpawnWorker",
            "status" => "failed",
            "message" => "Restarting worker #{agent_id} failed: #{e.message}",
            "errors" => [e.class.name, e.message]
          },
          trigger: trigger
        )
      end

      def worker_session_restart_title(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        present_string(metadata.fetch("title", nil)) || "Continue #{agent.fetch("id")}"
      end

      # The successor is told three things a fresh session cannot know: the assignment, that its
      # predecessor's transcript is gone for good, and that the workspace already holds real work.
      def unreplayable_session_restart_prompt(agent, instruction: nil)
        metadata = agent.fetch("harness_metadata", {}) || {}
        original = present_string(metadata.fetch("spawn_prompt", nil))
        branch = present_string(agent.fetch("workspace_branch", nil))
        location = branch ? "The worktree at #{agent.fetch("workspace_path")} and its branch #{branch} are" : "The worktree at #{agent.fetch("workspace_path")} is"
        header = [
          "You are continuing work that agent #{agent.fetch("id")} started. Its agent session could " \
          "no longer be replayed to the model, so its transcript is unavailable and this is a fresh " \
          "session on the same workspace.",
          "#{location} unchanged, so any work it already committed or left uncommitted is still there.",
          "Start by re-establishing what is already done (for example `git status` and `git log`) " \
          "before continuing, and do not redo work that is already committed."
        ].join("\n\n")
        sections = [header]
        sections << "--- Original assignment ---\n\n#{original}" if original
        sections << "--- New instruction ---\n\n#{present_string(instruction)}" if present_string(instruction)
        sections.join("\n\n")
      end

      def record_worker_session_restart_outcome(agent, claim, result, trigger:)
        agent_id = agent.fetch("id", nil).to_s
        accepted = result.is_a?(Hash) && result.fetch("status", nil) == "accepted"
        successor_id = accepted ? present_string(result.fetch("target_id", nil)) : nil
        synchronized_state do
          state = normalized_state
          record = find_agent(state, agent_id)
          now = timestamp
          if record
            recovery = worker_session_recovery(record).merge(
              "state" => accepted ? "restarted" : "restart_failed",
              "restarted_by_agent_id" => successor_id,
              "restarted_at" => accepted ? now : nil,
              "restart_error" => accepted ? nil : result_failure_summary(result)
            ).compact
            record["harness_metadata"] = (record.fetch("harness_metadata", {}) || {}).merge("session_recovery" => recovery)
            record["updated_at"] = now
          end
          branch = present_string(agent.fetch("workspace_branch", nil))
          message = if accepted
                      "Worker #{agent_id}'s session could not be replayed, so worker #{successor_id} took over its " \
                        "workspace#{branch ? " on branch #{branch}" : ""} in a fresh session."
                    else
                      "Worker #{agent_id}'s session could not be replayed and restarting it failed: " \
                        "#{result_failure_summary(result)}. Its workspace is untouched, so the work can be continued by hand."
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: accepted ? "info" : "error",
            message: message,
            details: {
              "agent_id" => agent_id,
              "successor_agent_id" => successor_id,
              "trigger" => trigger.to_s,
              "attempt" => claim.fetch("attempt", nil),
              "workspace_path" => agent.fetch("workspace_path", nil),
              "workspace_branch" => agent.fetch("workspace_branch", nil)
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          {
            "claimed" => true,
            "restarted" => accepted,
            "agent_id" => agent_id,
            "successor_agent_id" => successor_id,
            "message" => message,
            "log_entry_ids" => log_ids,
            "result" => result
          }
        end
      end

      def result_failure_summary(result)
        return "unknown error" unless result.is_a?(Hash)

        present_string(result.fetch("message", nil)) ||
          present_string(Array(result.fetch("errors", [])).join("; ")) ||
          "unknown error"
      end

      # Once a prompt lands the worker is working again, so the dead-turn reason must not linger
      # on the record or in the UI.
      def clear_settle_failure!(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return unless metadata.is_a?(Hash)
        return unless metadata.key?("settle_failure") || metadata.key?("settle_state") || metadata.key?("status_reason")

        cleared = metadata.dup
        previous = cleared.delete("settle_failure")
        cleared.delete("settle_state")
        cleared.delete("status_reason")
        cleared.delete("error_message") if previous.is_a?(Hash) && cleared["error_message"] == previous["reason"]
        cleared["previous_settle_failure"] = previous if previous.is_a?(Hash)
        agent["harness_metadata"] = cleared
      end

      def safe_last_assistant_text(client, session_ref)
        return nil unless client.respond_to?(:last_assistant_text)

        client.last_assistant_text(session_ref)
      rescue StandardError
        nil
      end
    end
  end
end
