# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Polling a harness session and turning one poll result into a state transition.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def reconcile_candidate?(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return false if agent.fetch("type", nil) == "head" && present_string(metadata.fetch("head_result_applied_at", nil))
        return false if head_takeover_claimed_by?(agent)
        # A head belongs to the instance that spawned it. Completing another live
        # instance's head would apply its result a second time.
        return false if agent.fetch("type", nil) == "head" && owned_by_other_live_instance?(agent)
        return false if blank?(agent.fetch("harness", nil)) || agent.fetch("harness", nil) == "fake"
        return false unless agent_has_session_reference?(agent) || recoverable_untracked_head?(agent)
        return false if %w[completed killed paused].include?(agent.fetch("status", nil))
        # Pause/resume side effects are checkpointed before harness I/O. Their dedicated
        # reconciliation steps own the session until the marker is cleared.
        return false if metadata.fetch("pause_request", nil).is_a?(Hash)
        return false if metadata.fetch("resume_request", nil).is_a?(Hash)
        # The native interactive process is the sole session writer during a focus handoff. Do not
        # let the background reconciler read or resume the same JSONL file until focus returns. A
        # stale marker is recovered above; if recovery failed, keep it out of polling as well so an
        # old assistant message cannot be promoted to a completion.
        return false if interactive_handoff_marker?(agent)
        # A prompt RPC can time out while the harness is still compacting and before its response reaches us.
        # Pending-prompt delivery checks the durable receipt first; ordinary polling/resume is
        # suppressed because it could race that live request and write a duplicate continuation.
        return false if Array(metadata.fetch("pending_prompts", [])).any? { |entry|
          entry.is_a?(Hash) && entry.fetch("delivery_state", nil) == "awaiting_receipt"
        }
        # A record whose failure was already recorded as terminal is settled: `/prompt` refuses
        # to continue it and reconciliation has no repair left to try. Re-polling it would only
        # re-observe the same dead session, rewrite state, and append the same error log on
        # every pass. Recovery resumes only when a command moves the record out of `errored`.
        return false if terminal_reconcile_error_recorded?(agent)
        return false unless harness_client_available_for_agent?(agent)
        return true unless agent.fetch("status", nil) == "errored"

        resumable_worker_reconcile_candidate?(agent) || resumable_head_reconcile_candidate?(agent)
      end

      # The durable "reconciliation is done trying" marker: an errored record whose persisted
      # reconcile details already say `terminal_error`.
      def interactive_handoff_marker?(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        marker = metadata.fetch("interactive_handoff", nil)
        marker.is_a?(Hash) && INTERACTIVE_HANDOFF_STATES.include?(marker.fetch("state", nil).to_s)
      end

      def interactive_focus_active?(agent)
        # A stale phase is still an ownership barrier: startup recovery must clear it before pause,
        # prompt, supervisor recovery, or ordinary settlement can touch the same saved session.
        interactive_handoff_marker?(agent)
      end

      # Either kind of focus means a person owns this session's prompt box right now. A
      # dashboard-issued prompt would be typed into the same box they are typing into, so it is
      # refused with an explanation rather than interleaved.
      def agent_focus_ownership_active?(agent)
        interactive_focus_active?(agent) || live_focus_attached?(agent)
      end

      def live_focus_marker(agent)
        return nil unless agent.is_a?(Hash)

        marker = (agent.fetch("harness_metadata", {}) || {}).fetch("live_focus", nil)
        marker.is_a?(Hash) && marker.fetch("state", nil).to_s == "attached" ? marker : nil
      end

      # A live focus claim only holds while the instance that made it is still running. A crashed
      # dashboard must not leave a worker permanently unpromptable, and unlike a handoff there is
      # nothing to repair: the agent process is owned by its client, not by the claim.
      def live_focus_attached?(agent)
        marker = live_focus_marker(agent)
        !marker.nil? && live_focus_owner_alive?(marker)
      end

      def live_focus_owner_alive?(marker)
        interactive_focus_owner_alive?(marker)
      end

      def interactive_focus_owner_alive?(marker)
        owner_id = marker.fetch("owner_instance_id", nil)
        owner_pid = marker.fetch("owner_instance_pid", nil).to_i
        return true if present_string(owner_id) && owner_id.to_s == instance_id
        return true if owner_pid.positive? && owner_pid == instance_pid
        return false unless owner_pid.positive?

        instance_alive?(owner_pid, marker.fetch("owner_instance_started_at", nil))
      end

      def interactive_process_alive?(marker)
        pid = (marker["interactive_pid"] || marker["reclaim_interactive_pid"]).to_i
        pid.positive? && owner_process_alive?(pid)
      end

      def terminal_reconcile_error_recorded?(agent)
        return false unless agent.fetch("status", nil) == "errored"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile = {} unless reconcile.is_a?(Hash)
        metadata.fetch("reconcile_state", nil) == RECONCILE_STATE_TERMINAL_ERROR ||
          reconcile.fetch("state", nil) == RECONCILE_STATE_TERMINAL_ERROR
      end

      def harness_client_available_for_agent?(agent)
        !!harness_client_for_agent(agent)
      rescue StandardError
        false
      end

      def agent_has_session_reference?(agent)
        present_string(agent.fetch("pid", nil)) ||
          present_string(agent.fetch("harness_session_id", nil)) ||
          present_string(agent.fetch("harness_session_file", nil))
      end

      def resumable_worker_reconcile_candidate?(agent)
        agent.fetch("type", nil) == "worker" && worker_resume_attempt_count(agent) < WORKER_RECONCILE_RESUME_MAX_ATTEMPTS
      end

      def resumable_head_reconcile_candidate?(agent)
        agent.fetch("type", nil) == "head" && head_recovery_attempt_count(agent) < HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS
      end

      def recoverable_untracked_head?(agent)
        agent.fetch("type", nil) == "head" && %w[queued working blocked errored].include?(agent.fetch("status", nil))
      end

      def poll_agent_session(agent)
        client = harness_client_for_agent(agent)
        session_ref = agent_session_ref(agent)
        state_ref = client.get_state(session_ref)
        if client.respond_to?(:get_session_stats)
          session_stats = begin
            client.get_session_stats(state_ref)
          rescue StandardError
            nil
          end
          state_ref = state_ref.merge(
            "session_stats" => session_stats.is_a?(Hash) ? session_stats : { "availability" => "unavailable" }
          )
        end
        events = client.respond_to?(:read_events) ? client.read_events(state_ref) : []
        # A worker whose live session a person is currently driving keeps reporting progress, but
        # its record is not retired underneath them. The turn they just watched finish is the end
        # of *their* exchange, not the end of the worker's assignment. A newly-started interactive
        # head is similarly not settled until its provider has had time to publish initial transcript
        # state (some harnesses can spend substantially longer in this phase than others).
        settled = completed_session?(state_ref) &&
                  !live_focus_attached?(agent) &&
                  !head_startup_grace_active?(agent, state_ref)
        assistant_text = settled ? safe_last_assistant_text(client, state_ref) : nil
        # A settled session is only a completion when nothing says its turn died.
        settle_failure = if settled && agent.fetch("type", nil) == "worker"
                           settle_failure_from_evidence(
                             session_ref: state_ref,
                             events: events,
                             last_assistant_text: assistant_text,
                             client: client
                           )
                         end

        result = {
          "agent_id" => agent.fetch("id"),
          "agent_type" => agent.fetch("type", nil),
          "state" => settle_poll_state(settled: settled, settle_failure: settle_failure),
          "polled_session_ref" => session_ref,
          "session_ref" => state_ref,
          "events" => events,
          # Only a session that is still running has mid-work progress worth reporting; a settled
          # turn is about to log its real result instead.
          "progress" => settled ? [] : session_progress_items(agent, client, events),
          "last_assistant_text" => assistant_text
        }
        result["settle_failure"] = settle_failure if settle_failure
        result
      rescue StandardError => e
        if worker_harness_process_gone?(agent, e)
          # An isolated child crash still settles immediately. A dead *supervisor* is different:
          # every child lost the same pipe owner together, while their sessions/workspaces remain
          # valid. The transport lease proves that shared cause, and a durable recovery claim keeps
          # concurrent dashboards from sending the continuation twice.
          supervisor_recovery = recover_worker_after_supervisor_exit(agent, client, session_ref, e)
          return supervisor_recovery if supervisor_recovery

          return harness_process_gone_poll_result(agent, client, session_ref, e)
        end
        return resume_worker_session_from_poll_error(agent, client, session_ref, e) if worker_reconcile_resume_eligible?(agent, client)
        return recover_head_session_from_poll_error(agent, client, session_ref, e) if head_reconcile_recovery_eligible?(agent)

        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => agent.fetch("type", nil),
          "state" => "errored",
          "session_ref" => session_ref,
          "error" => error_payload(e),
          "reconcile" => reconcile_error_model(agent, e)
        }
      end

      # Healthy streaming polls are compatible state-only merges: apply all of them against one
      # freshly loaded snapshot while holding the cross-process writer lock, then publish that
      # snapshot once. Terminal/head paths retain their existing immediate checkpoints because
      # they can run follow-on commands or harness side effects after the lifecycle transition.
      def apply_poll_results(poll_results)
        indexed_results = Array(poll_results).each_with_index.to_a
        working, other = indexed_results.partition { |poll_result, _index| poll_result.fetch("state", nil) == "working" }
        applied = {}

        unless working.empty?
          synchronized_state do
            store.coalesce_saves do
              state = normalized_state
              save_required = false
              working.each do |poll_result, index|
                result = refresh_agent_session_state_in(state, poll_result)
                applied[index] = result
                save_required ||= result.fetch("changed", false)
              rescue StandardError => e
                applied[index] = poll_result.merge(
                  "changed" => false,
                  "log_entry_ids" => [],
                  "skipped" => "apply_error",
                  "error" => error_payload(e)
                )
              end
              store.save(state) if save_required
            end
          end
        end

        # Terminal paths checkpoint their lifecycle transition before running existing recovery,
        # completion-head, deferred-worker, or head-command side effects. Do not hold the batch
        # lock across those harness operations.
        other.each { |poll_result, index| applied[index] = apply_poll_result(poll_result) }
        indexed_results.map { |_poll_result, index| applied.fetch(index) }
      end

      def apply_poll_result(poll_result)
        poll_result = poll_result_with_current_agent_id(poll_result)
        case poll_result.fetch("state", nil)
        when "working"
          refresh_agent_session_state(poll_result)
        when "completed"
          if poll_result.fetch("agent_type", nil) == "head"
            complete_polled_head(poll_result)
          else
            result = mark_worker_completed(
              agent_id: poll_result.fetch("agent_id"),
              harness_events: poll_result.fetch("events", []),
              last_assistant_text: poll_result.fetch("last_assistant_text", nil),
              session_ref: poll_result.fetch("session_ref", nil)
            )
            poll_result.merge("changed" => result.fetch("status", nil) == "accepted", "completion_result" => result,
                              "log_entry_ids" => result.fetch("log_entry_ids", []))
          end
        when "settle_failed"
          apply_settle_failure_from_poll(poll_result)
        when "recovered"
          # Supervisor recovery checkpoints the new transport and its one continuation prompt before
          # returning to the poll loop. Applying it again would duplicate its log/state transition.
          poll_result
        when "errored"
          apply_reconcile_error_from_poll(poll_result)
        else
          poll_result.merge("changed" => false, "log_entry_ids" => [])
        end
      end

      def settle_poll_state(settled:, settle_failure: nil)
        return "working" unless settled
        return "settle_failed" if settle_failure

        "completed"
      end

      # A dead turn is recorded once. Re-observing it on the next 2s reconciliation pass changes
      # nothing and logs nothing.
      def apply_settle_failure_from_poll(poll_result)
        result = mark_worker_settle_failed(
          agent_id: poll_result.fetch("agent_id"),
          settle_failure: poll_result.fetch("settle_failure", {}),
          harness_events: poll_result.fetch("events", []),
          last_assistant_text: poll_result.fetch("last_assistant_text", nil),
          session_ref: poll_result.fetch("session_ref", nil)
        )
        log_entry_ids = result.fetch("log_entry_ids", [])
        poll_result.merge(
          "changed" => result.fetch("status", nil) == "accepted" && log_entry_ids.any?,
          "settle_failure_result" => result,
          "log_entry_ids" => log_entry_ids
        )
      end

      def poll_result_with_current_agent_id(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_session_agent(
            state,
            agent_id: poll_result.fetch("agent_id", nil),
            session_ref: poll_result.fetch("session_ref", nil)
          )
          agent ? poll_result.merge("agent_id" => agent.fetch("id")) : poll_result
        end
      end

      def refresh_agent_session_state(poll_result)
        synchronized_state do
          state = normalized_state
          result = refresh_agent_session_state_in(state, poll_result)
          store.save(state) if result.fetch("changed", false)
          result
        end
      end

      def refresh_agent_session_state_in(state, poll_result)
        agent = find_session_agent(
          state,
          agent_id: poll_result.fetch("agent_id", nil),
          session_ref: poll_result.fetch("polled_session_ref", poll_result.fetch("session_ref", nil))
        )
        return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
        return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed paused].include?(agent.fetch("status", nil))

        now = timestamp
        previous_agent = deep_copy(agent)
        previous_parent_statuses = worker_parent_statuses(state, agent)
        merge_session_ref_into_agent!(agent, poll_result.fetch("session_ref", {}), persist_heartbeat: false)
        # The session is streaming again, so a recorded dead-turn reason is stale.
        clear_settle_failure!(agent)
        agent["status"] = "working"
        log_ids = append_harness_event_logs(state, agent, poll_result.fetch("events", []))
        log_ids.concat(record_worker_progress!(state, agent, poll_result.fetch("progress", []), now))
        log_ids.concat(append_recovery_success_log(state, agent, poll_result))
        refresh_worker_parent_statuses!(state, agent, now) if agent.fetch("type", nil) == "worker"
        changed = agent != previous_agent || worker_parent_statuses(state, agent) != previous_parent_statuses || log_ids.any?
        return poll_result.merge("agent_id" => agent.fetch("id"), "changed" => false, "log_entry_ids" => []) unless changed

        agent["updated_at"] = now
        touch_state!(state, now)
        poll_result.merge("agent_id" => agent.fetch("id"), "changed" => true, "log_entry_ids" => log_ids)
      end

      def complete_polled_head(poll_result)
        head_result = if head_runner.respond_to?(:parse_head_result_text)
                        head_runner.parse_head_result_text(poll_result.fetch("last_assistant_text", nil).to_s)
                      else
                        Heads::ResultParser.parse(poll_result.fetch("last_assistant_text", nil).to_s)
                      end
        apply_result = @head_result_mutex.synchronize do
          apply_head_result(
            nil,
            "ApplyHeadResult",
            "head_id" => poll_result.fetch("agent_id"),
            "head_result" => head_result,
            "_cleanup_head" => false
          )
        end
        log_ids = record_polled_head_completion(poll_result, head_result, apply_result)
        cleanup_result = cleanup_polled_head_after_apply(poll_result, apply_result)
        log_ids.concat(cleanup_result.fetch("log_entry_ids", []))
        poll_result.merge(
          "changed" => apply_result.fetch("status", nil) == "accepted" || cleanup_result.fetch("changed", false),
          "head_result" => head_result,
          "apply_result" => apply_result,
          "head_cleanup" => cleanup_result.fetch("cleanup", nil),
          "log_entry_ids" => (apply_result.fetch("log_entry_ids", []) + log_ids).uniq
        )
      rescue Heads::InvalidHeadResultError => e
        repair_invalid_head_result(poll_result, e)
      rescue StandardError => e
        mark_agent_errored_from_poll(
          poll_result.merge(
            "state" => "errored",
            "error" => { "class" => e.class.name, "message" => e.message }
          )
        )
      end

      def repair_invalid_head_result(poll_result, error)
        agent = synchronized_state { find_agent(normalized_state, poll_result.fetch("agent_id")) }
        return mark_agent_errored_from_poll(invalid_head_result_poll_error(poll_result, error)) unless head_result_repair_eligible?(agent)

        session_ref = poll_result.fetch("session_ref", {})
        client = harness_client_for_agent(agent)
        repaired_ref = prompt_head_result_repair(client, session_ref, error)
        record_head_result_repair_requested(poll_result, error, repaired_ref)
      rescue StandardError => repair_error
        mark_agent_errored_from_poll(
          poll_result.merge(
            "state" => "errored",
            "error" => { "class" => repair_error.class.name, "message" => repair_error.message },
            "reconcile" => {
              "state" => RECONCILE_STATE_TERMINAL_ERROR,
              "error_class" => error.class.name,
              "error_message" => error.message,
              "repair_error_class" => repair_error.class.name,
              "repair_error_message" => repair_error.message
            }
          )
        )
      end

      def invalid_head_result_poll_error(poll_result, error)
        poll_result.merge(
          "state" => "errored",
          "error" => { "class" => error.class.name, "message" => error.message }
        )
      end

      def head_result_repair_eligible?(agent)
        return false unless agent
        return false unless agent.fetch("type", nil) == "head"
        return false if TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil))

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.fetch("head_result_repair_count", 0).to_i < HEAD_RESULT_REPAIR_MAX_ATTEMPTS
      end

      def prompt_head_result_repair(client, session_ref, error)
        mode = session_ref.fetch("is_streaming", false) ? "follow_up" : "normal"
        prompt = <<~PROMPT
          #{HEAD_RESULT_REPAIR_PROMPT}

          Validation error: #{error.message}
        PROMPT
        client.prompt_session(session_ref, prompt, mode: mode)
      end

      def record_head_result_repair_requested(poll_result, error, repaired_ref)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless head
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if TERMINAL_AGENT_STATUSES.include?(head.fetch("status", nil)) || head.fetch("status", nil) == "paused"

          now = timestamp
          metadata = head.fetch("harness_metadata", {}) || {}
          repair_count = metadata.fetch("head_result_repair_count", 0).to_i + 1
          merge_session_ref_into_agent!(head, repaired_ref)
          head["status"] = "working"
          head["updated_at"] = now
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "head_result_repair_count" => repair_count,
            "head_result_repair_requested_at" => now,
            "head_result_repair_error_class" => error.class.name,
            "head_result_repair_error_message" => error.message
          ).compact
          log_ids = append_log(
            state,
            source_type: "head",
            source_id: head.fetch("id"),
            level: "warning",
            message: "Head #{head.fetch("id")} returned invalid HeadResult JSON; requested one repair response.",
            details: {
              "repair_count" => repair_count,
              "error_class" => error.class.name,
              "error_message" => error.message
            }
          )
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("state" => "working", "changed" => true, "repaired" => true, "session_ref" => repaired_ref, "log_entry_ids" => log_ids)
        end
      end

      def record_polled_head_completion(poll_result, head_result, apply_result)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, poll_result.fetch("agent_id"))
          return [] unless head

          now = timestamp
          # Captured before the session merge, which resets `reconcile_state` to `healthy`, so a
          # repeated failure can still be recognised as already recorded.
          previously_terminal = terminal_reconcile_error_recorded?(head)
          previous_signature = reconcile_error_signature((head.fetch("harness_metadata", {}) || {}).fetch("reconcile", {}))
          merge_session_ref_into_agent!(head, poll_result.fetch("session_ref", {}))
          if head_result_apply_skipped?(apply_result)
            log_ids = append_harness_event_logs(state, head, poll_result.fetch("events", []))
            touch_state!(state, now)
            store.save(state)
            return log_ids
          end

          fully_applied = head_result_fully_applied?(apply_result)
          accepted = apply_result.fetch("status", nil) == "accepted"
          head["status"] = if !accepted
                             "errored"
                           elsif fully_applied
                             "completed"
                           else
                             "blocked"
                           end
          head["updated_at"] = now
          # A head result the kernel refused is terminal for this head: reconciliation has no
          # retry for it, so it is recorded like any other terminal reconcile failure. Otherwise
          # the record stays `healthy`, is re-polled every pass, and re-logs the same error every
          # two seconds. The head's session is closed for the same reason it is on other terminal
          # head failures: nothing will use it again. Release first, then snapshot the metadata,
          # so the release markers survive.
          reconcile = accepted ? nil : unapplied_head_result_reconcile_model(apply_result, now)
          repeated = !accepted && previously_terminal && previous_signature == reconcile_error_signature(reconcile)
          release_head_session!(head, reason: "head_result_not_applied", now: now) unless accepted
          metadata = (head.fetch("harness_metadata", {}) || {}).merge(
            "completed_at" => now,
            "head_result" => head_result,
            "head_result_applied_at" => accepted ? now : nil,
            "head_result_apply_status" => fully_applied ? apply_result.fetch("status", nil) : "partial",
            "is_streaming" => false
          ).compact
          unless accepted
            metadata = metadata.merge(
              "errored_at" => metadata.fetch("errored_at", nil) || now,
              "reconcile_state" => RECONCILE_STATE_TERMINAL_ERROR,
              "reconcile" => reconcile
            ).compact
          end
          head["harness_metadata"] = metadata
          log_ids = append_harness_event_logs(state, head, poll_result.fetch("events", []))
          if !accepted && !repeated
            log_ids.concat(append_log(
              state,
              source_type: "head",
              source_id: head.fetch("id"),
              level: "error",
              message: "Polled head #{head.fetch("id")} completed but its HeadResult was not applied.",
              details: {
                "head_result" => head_result,
                "apply_status" => apply_result.fetch("status", nil),
                "apply_message" => apply_result.fetch("message", nil)
              }.merge(reconcile || {})
            ))
          end
          touch_state!(state, now)
          store.save(state)
          log_ids
        end
      end

      def cleanup_polled_head_after_apply(poll_result, apply_result)
        unless apply_result.fetch("status", nil) == "accepted" && head_result_fully_applied?(apply_result)
          return { "changed" => false, "cleanup" => { "changed" => false, "reason" => "head_result_not_fully_applied" }, "log_entry_ids" => [] }
        end

        synchronized_state do
          state = normalized_state
          cleanup = cleanup_applied_head!(state, poll_result.fetch("agent_id"), now: timestamp)
          touch_state!(state)
          store.save(state)
          { "changed" => cleanup.fetch("changed", false), "cleanup" => cleanup, "log_entry_ids" => cleanup.fetch("log_entry_ids", []) }
        end
      end

      def apply_reconcile_error_from_poll(poll_result)
        if transient_head_reconcile_error?(poll_result)
          defer_head_reconcile_error_from_poll(poll_result)
        elsif worker_resume_failed_reconcile_error?(poll_result)
          defer_worker_reconcile_error_from_poll(poll_result)
        else
          mark_agent_errored_from_poll(poll_result)
        end
      end

      def transient_head_reconcile_error?(poll_result)
        poll_result.fetch("agent_type", nil) == "head" &&
          poll_result.dig("reconcile", "state") == RECONCILE_STATE_TRANSIENT_ERROR
      end

      def worker_resume_failed_reconcile_error?(poll_result)
        poll_result.fetch("agent_type", nil) == "worker" &&
          poll_result.dig("reconcile", "state") == RECONCILE_STATE_RESUME_FAILED
      end

      def reconcile_error_model(agent, error)
        state = agent.fetch("type", nil) == "head" ? RECONCILE_STATE_TRANSIENT_ERROR : RECONCILE_STATE_TERMINAL_ERROR
        {
          "state" => state,
          "agent_type" => agent.fetch("type", nil),
          "error_class" => error.class.name,
          "error_message" => sanitized_error_message(error)
        }
      end
    end
  end
end
