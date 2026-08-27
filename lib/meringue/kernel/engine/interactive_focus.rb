# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Handing a worker's live terminal to the dashboard and taking it back: attaching, focusing,
      # and recovering a focus whose owner disappeared.

      # A dashboard crash can leave any durable focus phase behind. Claim it before process I/O,
      # reclaim a surviving native writer through the harness identity check, and return dashboard
      # ownership before ordinary polling. That ordering preserves the continuation obligation and
      # prevents the aborted pre-focus assistant checkpoint from being promoted to a completion.
      def reconcile_stale_interactive_focuses
        candidates = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "worker"
            next unless interactive_handoff_marker?(agent)

            marker = agent.dig("harness_metadata", "interactive_handoff")
            next if interactive_focus_owner_alive?(marker)

            deep_copy(agent)
          end
        end

        candidates.filter_map do |candidate|
          agent = claim_stale_interactive_focus_recovery(candidate.fetch("id"))
          next unless agent

          marker = agent.dig("harness_metadata", "interactive_handoff") || {}
          interactive_pid = (marker["interactive_pid"] || marker["reclaim_interactive_pid"]).to_i
          if interactive_pid.positive? && interactive_process_alive?(marker)
            harness_client_for_agent(agent).reclaim_interactive_session(
              agent_session_ref(agent),
              pid: interactive_pid
            )
          end
          end_agent_interactive_focus(agent.fetch("id"))
        rescue StandardError => e
          mark_stale_interactive_focus_recovery_failed(candidate.fetch("id"), e)
        end
      end

      def claim_stale_interactive_focus_recovery(agent_id)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id.to_s)
          next unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          marker = metadata.fetch("interactive_handoff", nil)
          next unless marker.is_a?(Hash) && INTERACTIVE_HANDOFF_STATES.include?(marker.fetch("state", nil).to_s)
          next if interactive_focus_owner_alive?(marker)

          now = timestamp
          original_state = marker.fetch("recovery_from_state", nil) || marker.fetch("state", nil)
          marker = stale_interactive_focus_recovery_marker(marker, original_state)
          agent["harness_metadata"] = metadata.merge(
            "interactive_handoff" => marker.merge(instance_ownership_metadata).merge(
              "state" => "reclaiming",
              "recovery_from_state" => original_state,
              "recovery_started_at" => now
            )
          )
          agent["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          deep_copy(agent)
        end
      end

      def stale_interactive_focus_recovery_marker(marker, original_state)
        return marker unless original_state.to_s == "preparing"
        return marker unless marker.fetch("managed_turn_was_streaming", false)
        return marker if marker.fetch("handoff", nil).is_a?(Hash)

        marker.merge(
          "handoff" => {
            "continuation_required" => true,
            "prompt" => WORKER_RESUME_PROMPT.strip,
            "recovery" => "dashboard_restart_during_focus_preparation"
          }
        )
      end

      def mark_stale_interactive_focus_recovery_failed(agent_id, exception)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id.to_s)
          if agent
            metadata = agent.fetch("harness_metadata", {}) || {}
            marker = metadata.fetch("interactive_handoff", {}) || {}
            now = timestamp
            agent["harness_metadata"] = metadata.merge(
              "interactive_handoff" => marker.merge(
                "state" => "reclaim_failed",
                "recovery_failed_at" => now,
                "recovery_error" => exception.message
              )
            )
            agent["updated_at"] = now
            touch_state!(state, now)
            store.save(state)
          end
        end
        error = error_payload(exception)
        failed_result(
          nil,
          "RecoverInteractiveFocus",
          "Could not recover focused session ownership for worker #{agent_id}: #{error.fetch("message")}",
          [error.fetch("class"), error.fetch("message")]
        )
      end

      # How this agent's backend can be focused, so callers stay harness-agnostic:
      #
      #   "live_terminal" - the session already runs in an interactive process Meringue owns, and
      #                     focusing it is a pure attach.
      #   "handoff"       - the backend must settle and release its managed transport first.
      #   "none"          - the backend has no focusable session.
      def agent_focus_mode(agent_id)
        agent = synchronized_state { find_agent(normalized_state, agent_id.to_s) }
        return "none" unless agent

        client = begin
          harness_client_for_agent(agent)
        rescue StandardError
          nil
        end
        return "none" unless client
        return "live_terminal" if client.respond_to?(:live_terminal_supported?) && client.live_terminal_supported?
        return "handoff" if client.respond_to?(:interactive_session_supported?) && client.interactive_session_supported?

        "none"
      end

      # Attaches a viewer to the session's own running interactive process.
      #
      # Nothing about the session changes: no turn is aborted, no transport is quiesced, and no
      # process is started in place of another. That is the entire difference from the handoff path
      # below, and it is why leaving focus costs nothing and can never strand a worker.
      #
      # A durable marker still records that a human owns the prompt box, because dashboard-issued
      # prompts must not be typed into a box someone is already typing into.
      def attach_agent_live_terminal(agent_id, rows: nil, columns: nil)
        agent = synchronized_state do
          state = normalized_state
          candidate = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "AttachLiveTerminal", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless candidate
          return rejected_result(nil, "AttachLiveTerminal", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless candidate.fetch("type", nil) == "worker"
          if interactive_focus_active?(candidate)
            return rejected_result(nil, "AttachLiveTerminal", "Worker #{agent_id} is already in a focus transition.", ["interactive_focus_active"])
          end

          marker = live_focus_marker(candidate)
          if marker && live_focus_owner_alive?(marker)
            return rejected_result(nil, "AttachLiveTerminal", "Worker #{agent_id} is already focused by a live session.", ["live_focus_active"])
          end

          deep_copy(candidate)
        end
        return agent if kernel_command_result?(agent)

        client = harness_client_for_agent(agent)
        unless client.respond_to?(:live_terminal_supported?) && client.live_terminal_supported?
          return rejected_result(nil, "AttachLiveTerminal", "This agent's backend does not provide a live session to attach to.", ["live_terminal_unsupported"])
        end

        terminal = client.live_terminal(agent_session_ref(agent))
        terminal.resize(rows: rows, columns: columns) if rows && columns

        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id"))
          return rejected_result(nil, "AttachLiveTerminal", "Agent #{agent.fetch("id")} disappeared while attaching.", ["agent_not_found"]) unless current

          now = timestamp
          metadata = current.fetch("harness_metadata", {}) || {}
          current["harness_metadata"] = metadata.merge(
            "live_focus" => instance_ownership_metadata.merge(
              "state" => "attached",
              "attached_at" => now,
              "pid" => terminal.respond_to?(:pid) ? terminal.pid : nil
            ).compact
          )
          current["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: "info",
            message: "Focused worker #{current.fetch("id")}'s live agent session without interrupting it.",
            details: { "agent_id" => current.fetch("id"), "routing_action" => "live_focus_attach" }
          )
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "AttachLiveTerminal",
            current.fetch("id"),
            "Attached to the live agent session for #{current.fetch("id")}.",
            { "terminal" => terminal },
            log_ids
          )
        end
      rescue StandardError => e
        error = error_payload(e)
        failed_result(
          nil,
          "AttachLiveTerminal",
          "Could not attach to the live agent session for #{agent_id}: #{error.fetch("message")}",
          [error.fetch("class"), error.fetch("message")]
        )
      end

      # Releases the viewer's claim. The session keeps running exactly as it was, so this can never
      # fail in a way that leaves a worker without a supervisor.
      def detach_agent_live_terminal(agent_id)
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent_id.to_s)
          return { "status" => "accepted", "message" => "No live agent session was focused." } unless current

          metadata = current.fetch("harness_metadata", {}) || {}
          marker = metadata.fetch("live_focus", nil)
          return accepted_result(nil, "DetachLiveTerminal", current.fetch("id"), "No live agent session was focused.", nil, []) unless marker.is_a?(Hash)

          now = timestamp
          metadata = metadata.dup
          metadata.delete("live_focus")
          current["harness_metadata"] = metadata.merge(
            "last_live_focus" => marker.merge("state" => "detached", "detached_at" => now)
          )
          current["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: "info",
            message: "Returned worker #{current.fetch("id")} to the dashboard; its agent session kept running throughout.",
            details: { "agent_id" => current.fetch("id"), "routing_action" => "live_focus_detach" }
          )
          touch_state!(state, now)
          store.save(state)
          accepted_result(nil, "DetachLiveTerminal", current.fetch("id"), "Returned #{current.fetch("id")} to the dashboard.", nil, log_ids)
        end
      end

      # A focused Agent session writes directly to its provider PTY, so it does not pass through the
      # dashboard PromptAgent command. Enter is the durable boundary at which the kernel can expose a
      # completed worker as active; reconciliation later confirms whether the submitted turn is still
      # streaming or has already completed.
      def note_agent_interactive_prompt(agent_id)
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "FocusPrompt", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless current
          return rejected_result(nil, "FocusPrompt", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless current.fetch("type", nil) == "worker"
          return accepted_result(nil, "FocusPrompt", current.fetch("id"), "Worker #{current.fetch("id")} is already #{current.fetch("status")}.", deep_copy(current), []) unless current.fetch("status", nil) == "completed"
          return rejected_result(nil, "FocusPrompt", "Worker #{agent_id} has no resumable agent session.", ["missing_harness_session"]) unless agent_has_session_reference?(current)

          now = timestamp
          current["status"] = "working"
          current["updated_at"] = now
          current["harness_metadata"] = (current.fetch("harness_metadata", {}) || {}).merge(
            "is_streaming" => true,
            "focused_prompt_at" => now
          ).compact
          refresh_worker_parent_statuses!(state, current, now)
          touch_state!(state, now)
          store.save(state)
          accepted_result(nil, "FocusPrompt", current.fetch("id"), "Worker #{current.fetch("id")} is working on its focused prompt.", deep_copy(current), [])
        end
      end

      # The Agent session is a kernel-owned transport transition, not a TUI-side attach. The managed
      # RPC writer is quiesced before the workspace controller launches the interactive PTY, and a
      # durable marker makes reconciliation stand down while that PTY owns the session file.
      def begin_agent_interactive_focus(agent_id)
        reclaim_pid = nil
        reclaim_started_at = nil
        reclaim_completed = false
        client = nil
        agent = synchronized_state do
          state = normalized_state
          candidate = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "BeginInteractiveFocus", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless candidate
          return rejected_result(nil, "BeginInteractiveFocus", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless candidate.fetch("type", nil) == "worker"

          metadata = (candidate.fetch("harness_metadata", {}) || {}).dup
          # This marker belongs to one focused turn; do not let a prior focus return preserve
          # `working` if this focus session is only being viewed.
          metadata.delete("focused_prompt_at")
          existing = metadata.fetch("interactive_handoff", nil)
          if existing.is_a?(Hash) && INTERACTIVE_HANDOFF_STATES.include?(existing.fetch("state", nil).to_s)
            retrying_reclaim = existing.fetch("state", nil).to_s == "reclaim_failed"
            if interactive_focus_owner_alive?(existing) && !retrying_reclaim
              return rejected_result(nil, "BeginInteractiveFocus", "Worker #{agent_id} already has an interactive focus transition in progress.", ["interactive_focus_active"])
            end

            if interactive_process_alive?(existing)
              reclaim_pid = (existing["interactive_pid"] || existing["reclaim_interactive_pid"]).to_i
              reclaim_started_at = existing["interactive_started_at"] || existing["reclaim_interactive_started_at"]
            else
              # The previous owner died without leaving a live interactive process. Discard only the
              # stale lifecycle marker and recover the same durable session.
              metadata = metadata.dup
              metadata.delete("interactive_handoff")
              candidate["harness_metadata"] = metadata
            end
          end

          client = harness_client_for_agent(candidate)
          unless client.respond_to?(:interactive_session_supported?) && client.interactive_session_supported?
            return rejected_result(nil, "BeginInteractiveFocus", "The selected harness does not provide an Agent session.", ["interactive_session_unsupported"])
          end

          now = timestamp
          candidate["harness_metadata"] = metadata.merge(
            "interactive_handoff" => instance_ownership_metadata.merge(
              "state" => "preparing",
              "started_at" => now,
              "managed_turn_was_streaming" => !!metadata.fetch("is_streaming", false),
              "context" => interactive_focus_context(state, candidate),
              "reclaim_interactive_pid" => reclaim_pid,
              "reclaim_interactive_started_at" => reclaim_started_at
            ).compact
          )
          candidate["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          deep_copy(candidate)
        end
        return agent if kernel_command_result?(agent)

        client = harness_client_for_agent(agent)
        if reclaim_pid
          client.reclaim_interactive_session(agent_session_ref(agent), pid: reclaim_pid)
          reclaim_completed = true
        end
        prepared = client.prepare_interactive_session(agent_session_ref(agent))
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id"))
          return rejected_result(nil, "BeginInteractiveFocus", "Agent #{agent.fetch("id")} disappeared during interactive handoff.", ["agent_not_found"]) unless current

          now = timestamp
          handoff = prepared.fetch("handoff", {}) || {}
          prepared_ref = prepared.fetch("session_ref", {})
          merge_session_ref_into_agent!(current, prepared_ref) unless prepared_ref.empty?
          marker = (current.fetch("harness_metadata", {}) || {}).fetch("interactive_handoff", {}) || {}
          current["pid"] = nil
          current["harness_metadata"] = (current.fetch("harness_metadata", {}) || {}).merge(
            "is_streaming" => false,
            "interactive_handoff" => marker.merge(
              "state" => "interactive_pending",
              "session_ref" => prepared.fetch("session_ref", {}),
              "handoff" => handoff
            )
          )
          current["updated_at"] = now
          # Native focus itself makes this successful ownership transition visible. Keep the
          # durable handoff state and command result, but do not add a routine lifecycle log row.
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "BeginInteractiveFocus",
            current.fetch("id"),
            "Prepared worker #{current.fetch("id")} for an Agent session.",
            {
              "interactive_argv" => prepared.fetch("interactive_argv"),
              "interactive_executable" => prepared.fetch("interactive_executable", nil),
              "interactive_env" => prepared.fetch("interactive_env", nil),
              "interactive_shutdown_input" => prepared.fetch("interactive_shutdown_input", nil),
              "handoff" => handoff,
              "session_ref" => prepared.fetch("session_ref")
            },
            []
          )
        end
      rescue StandardError => e
        recovered_ref = nil
        recovery_error = nil
        # Preparation may already have quiesced the RPC writer. If no orphaned native
        # process is still being reclaimed, restore dashboard ownership before clearing the marker.
        # This makes launch/preparation failure a settled, resumable worker rather than a stale
        # `working` record with no supervisor.
        unless reclaim_pid && !reclaim_completed
          begin
            client ||= harness_client_for_agent(agent) if agent.is_a?(Hash)
            recovered_ref = client.resume_dashboard_session(agent_session_ref(agent)) if client && agent.is_a?(Hash)
          rescue StandardError => recovery_exception
            recovery_error = recovery_exception
          end
        end

        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent_id.to_s)
          if current
            metadata = current.fetch("harness_metadata", {}) || {}
            marker = metadata.fetch("interactive_handoff", {}) || {}
            if reclaim_pid && !reclaim_completed && marker.is_a?(Hash)
              current["harness_metadata"] = metadata.merge(
                "interactive_handoff" => marker.merge("state" => "reclaim_failed", "reclaim_error" => e.message)
              )
            else
              merge_session_ref_into_agent!(current, recovered_ref) if recovered_ref.is_a?(Hash)
              metadata = current.fetch("harness_metadata", {}) || {}
              metadata.delete("interactive_handoff")
              current["harness_metadata"] = metadata.merge(
                "last_interactive_handoff" => marker.merge(
                  "state" => "failed",
                  "outcome" => "prepare_failed",
                  "failed_at" => timestamp,
                  "error" => e.message,
                  "recovery_error" => recovery_error&.message
                ).compact
              )
              unless TERMINAL_AGENT_STATUSES.include?(current.fetch("status", nil))
                current["status"] = if recovered_ref.is_a?(Hash)
                                      recovered_ref.fetch("is_streaming", false) ? "working" : "idle"
                                    else
                                      "blocked"
                                    end
                refresh_worker_parent_statuses!(state, current, timestamp)
              end
            end
            current["updated_at"] = timestamp
            touch_state!(state)
            store.save(state)
          end
          error = error_payload(e)
          errors = [error.fetch("class"), error.fetch("message")]
          errors << "dashboard_recovery_failed: #{recovery_error.message}" if recovery_error
          failed_result(nil, "BeginInteractiveFocus", "Could not prepare worker #{agent_id} for interactive focus: #{error.fetch("message")}", errors)
        end
      end

      def mark_agent_interactive_focus_started(agent_id, pid:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "MarkInteractiveFocusStarted", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          marker = metadata.fetch("interactive_handoff", {}) || {}
          return rejected_result(nil, "MarkInteractiveFocusStarted", "Agent #{agent_id} is not awaiting interactive focus.", ["interactive_focus_not_pending"]) unless marker.fetch("state", nil) == "interactive_pending"

          now = timestamp
          process = Harness::ProcessIdentity.describe(pid)
          marker = marker.merge(
            "state" => "interactive",
            "interactive_pid" => pid,
            "interactive_started_at" => process&.fetch("started_at", nil)&.iso8601 || now
          )
          marker.delete("reclaim_interactive_pid")
          agent["harness_metadata"] = metadata.merge(
            "is_streaming" => true,
            "interactive_handoff" => marker
          )
          agent["status"] = "working" unless TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil))
          agent["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          accepted_result(nil, "MarkInteractiveFocusStarted", agent.fetch("id"), "Native interactive focus is active for worker #{agent.fetch("id")}.", agent, [])
        end
      end

      # Called only after the interactive PTY has exited. Reattaching before that point would create
      # two writers against one session transcript and is explicitly rejected by the lifecycle seam.
      def end_agent_interactive_focus(agent_id)
        handoff_marker = nil
        agent = synchronized_state do
          state = normalized_state
          candidate = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "EndInteractiveFocus", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless candidate

          marker = (candidate.fetch("harness_metadata", {}) || {}).fetch("interactive_handoff", {}) || {}
          unless INTERACTIVE_RETURN_STATES.include?(marker.fetch("state", nil).to_s)
            return accepted_result(nil, "EndInteractiveFocus", candidate.fetch("id"), "Worker #{candidate.fetch("id")} has no active interactive focus.", candidate, [])
          end
          if marker.fetch("state", nil).to_s == "resuming" && interactive_focus_owner_alive?(marker)
            return rejected_result(nil, "EndInteractiveFocus", "Worker #{candidate.fetch("id")} is already returning focus to a live dashboard.", ["interactive_focus_resume_active"])
          end

          handoff_marker = deep_copy(marker)
          now = timestamp
          candidate["harness_metadata"] = (candidate.fetch("harness_metadata", {}) || {}).merge(
            "interactive_handoff" => marker.merge(instance_ownership_metadata).merge(
              "state" => "resuming",
              "resume_started_at" => now
            )
          )
          candidate["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          deep_copy(candidate)
        end
        return agent if kernel_command_result?(agent)

        client = harness_client_for_agent(agent)
        resumed = client.resume_dashboard_session(agent_session_ref(agent), handoff: handoff_marker)
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id"))
          return rejected_result(nil, "EndInteractiveFocus", "Agent #{agent.fetch("id")} disappeared while resuming dashboard operation.", ["agent_not_found"]) unless current

          now = timestamp
          merge_session_ref_into_agent!(current, resumed)
          metadata = current.fetch("harness_metadata", {}) || {}
          metadata.delete("interactive_handoff")
          recovery_from_state = handoff_marker.fetch("recovery_from_state", nil) || handoff_marker.fetch("state", nil)
          handoff_outcome = if recovery_from_state.to_s == "interactive_pending"
                              "launch_not_started"
                            elsif resumed.dig("metadata", "interactive_dashboard_continuation") == "started"
                              "dashboard_continuation_started"
                            else
                              "interactive_closed"
                            end
          current["harness_metadata"] = metadata.merge(
            "is_streaming" => resumed.fetch("is_streaming", false),
            "last_interactive_handoff" => handoff_marker.merge(
              "state" => "ended",
              "outcome" => handoff_outcome,
              "ended_at" => now
            )
          ).compact
          focused_prompt_at = parse_time_or_nil(metadata.fetch("focused_prompt_at", nil))
          focus_started_at = parse_time_or_nil(handoff_marker.fetch("started_at", nil))
          focused_prompt_submitted = focused_prompt_at && (!focus_started_at || focused_prompt_at >= focus_started_at)
          unless TERMINAL_AGENT_STATUSES.include?(current.fetch("status", nil))
            current["status"] = if resumed.fetch("is_streaming", false) || focused_prompt_submitted
                                  "working"
                                else
                                  "idle"
                                end
            refresh_worker_parent_statuses!(state, current, now)
          end
          current["updated_at"] = now
          # Returning to the dashboard is already visible when native focus closes. Persist the
          # resumed owner without adding another routine lifecycle row to the user-visible log.
          touch_state!(state, now)
          store.save(state)
          accepted_result(nil, "EndInteractiveFocus", current.fetch("id"), "Resumed worker #{current.fetch("id")} in the dashboard.", current, [])
        end
      rescue StandardError => e
        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent_id.to_s)
          if current
            metadata = current.fetch("harness_metadata", {}) || {}
            marker = metadata.fetch("interactive_handoff", {}) || {}
            current["harness_metadata"] = metadata.merge("interactive_handoff" => marker.merge("state" => "resume_failed", "resume_error" => e.message))
            current["updated_at"] = timestamp
            touch_state!(state)
            store.save(state)
          end
          error = error_payload(e)
          failed_result(nil, "EndInteractiveFocus", "Could not resume dashboard operation for worker #{agent_id}: #{error.fetch("message")}", [error.fetch("class"), error.fetch("message")])
        end
      end
    end
  end
end
