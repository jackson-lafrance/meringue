# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Operating on a worker's harness session from outside a kernel command: reading its
      # transcript, cancelling its turn, exporting and importing it, and pausing or resuming it.

      # Opens a read-only harness-neutral transcript handle for a worker or a live head.
      # The handle cannot attach, detach, signal, or kill the managed process. Heads are
      # intentionally supported only for viewing: their stateless lifecycle still owns all
      # prompting and teardown decisions.
      def open_agent_session_view(agent_id)
        agent = synchronized_state do
          candidate = find_agent(normalized_state, agent_id.to_s)
          raise ArgumentError, "Agent #{agent_id} does not exist." unless candidate
          raise ArgumentError, "Agent #{agent_id} is not a worker or head." unless %w[worker head].include?(candidate.fetch("type", nil))

          deep_copy(candidate)
        end
        client = harness_client_for_agent(agent)
        client.open_session_view(agent_session_ref(agent))
      end

      # Abort is a turn-level operation, unlike Kill. It preserves the harness
      # process/session and lets reconciliation observe the resulting settled
      # state. This is intentionally not a general process-control API.
      def cancel_agent_turn(agent_id)
        agent = synchronized_state do
          state = normalized_state
          candidate = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless candidate
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless candidate.fetch("type", nil) == "worker"
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent_id} is not currently working.", ["agent_not_working"]) unless candidate.fetch("status", nil) == "working"

          deep_copy(candidate)
        end

        client = harness_client_for_agent(agent)
        session_ref = client.abort_session(agent_session_ref(agent))

        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id"))
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent.fetch("id")} no longer exists.", ["agent_not_found"]) unless current

          now = timestamp
          merge_session_ref_into_agent!(current, session_ref)
          unless TERMINAL_AGENT_STATUSES.include?(current.fetch("status", nil))
            current["status"] = session_ref.fetch("is_streaming", false) ? "working" : "idle"
            current["updated_at"] = now
            current["harness_metadata"] = (current.fetch("harness_metadata", {}) || {}).merge(
              "turn_cancelled_at" => now,
              "is_streaming" => session_ref.fetch("is_streaming", false)
            )
            refresh_worker_parent_statuses!(state, current, now)
          end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: "warning",
            message: "Cancelled the current turn for worker #{current.fetch("id")} without terminating its agent session.",
            details: { "agent_id" => current.fetch("id"), "session_preserved" => true }
          )
          touch_state!(state, now)
          store.save(state)
          accepted_result(nil, "CancelAgentTurn", current.fetch("id"), "Cancelled the current turn for worker #{current.fetch("id")}.", current, log_ids)
        end
      rescue StandardError => e
        synchronized_state do
          error = error_payload(e)
          failed_result(nil, "CancelAgentTurn", "Could not cancel agent #{agent_id}: #{error.fetch("message")}", [error.fetch("class"), error.fetch("message")])
        end
      end

      # Export only portable worker context. The bundle writer deliberately runs outside the state
      # lock: it reads one normalized snapshot and performs file I/O without blocking commands from
      # another Meringue instance.
      def export_workers(command_id, command_type, payload)
        path = value_at(payload, "path", "Path", "bundle_path", "bundlePath")
        return rejected_result(command_id, command_type, "Workers were not exported.", ["path is required"]) if blank?(path)

        bundle = Workers::Bundle.export(
          store.load,
          worker_ids: value_at(payload, "worker_ids", "agent_ids", "agents") || []
        )
        destination = Workers::Bundle.write(path, bundle)
        accepted_result(
          command_id,
          command_type,
          nil,
          "Exported #{bundle.fetch("workers").length} worker(s) to #{destination}. Harness sessions were not included; import will start fresh sessions.",
          { "path" => destination, "bundle_id" => bundle.fetch("bundle_id"), "worker_ids" => bundle.fetch("workers").map { |worker| worker.fetch("source_worker_id") } },
          []
        )
      rescue ArgumentError => e
        rejected_result(command_id, command_type, "Workers were not exported: #{e.message}", ["worker_export_invalid"])
      rescue StandardError => e
        failed_result(command_id, command_type, "Workers were not exported: #{sanitized_error_message(e)}", [e.class.name, sanitized_error_message(e)])
      end

      # Import is intentionally a fresh SpawnWorker flow. A portable bundle has no usable harness
      # session reference, so the destination path is required and the normal workspace manager
      # chooses a local checkout/branch. Reading a bundle path happens before the state mutation;
      # callers may also pass an already parsed bundle (the CLI uses that form).
      def import_workers(command_id, command_type, payload)
        bundle = value_at(payload, "bundle", "Bundle")
        bundle = Workers::Bundle.read(value_at(payload, "path", "Path", "bundle_path", "bundlePath")) unless bundle.is_a?(Hash)
        Workers::Bundle.validate!(bundle)
        project_path = value_at(payload, "project_path", "projectPath", "destination_project_path")
        return rejected_result(command_id, command_type, "Workers were not imported.", ["project_path is required"]) if blank?(project_path)

        expanded_project_path = File.expand_path(project_path.to_s)
        return rejected_result(command_id, command_type, "Workers were not imported.", ["project_path must be an existing directory"]) unless Dir.exist?(expanded_project_path)

        # Import registers a destination project, so it has to clear the same bar as
        # AddProject: an imported worker needs an isolated mutable workspace like any
        # other. Skipping the probe created a project no worker could ever be given a
        # workspace in, and reported every worker as "spawn_failed" instead of saying so.
        capability = @version_control_backend.inspect_project(root_path: expanded_project_path)
        unless capability.is_a?(Hash) && capability["available"] == true && capability.dig("capabilities", "isolated_workspaces") == true
          diagnostics = Array(capability.is_a?(Hash) ? capability["diagnostics"] : nil).join(", ")
          reason = diagnostics.empty? ? "isolated_workspace_capability_missing" : diagnostics
          return rejected_result(
            command_id,
            command_type,
            "Workers were not imported: isolated mutable workspaces are unavailable (#{reason}).",
            ["version_control_backend_unavailable", reason]
          )
        end

        imported = []
        skipped = []
        log_ids = []
        project_id = nil
        issue_ids = {}
        synchronized_state do
          state = normalized_state
          project = import_project!(state, bundle, expanded_project_path, payload, capability: capability)
          project_id = project.fetch("id")
          bundle.fetch("workers").each do |entry|
            source_issue_id = entry.dig("issue", "source_id").to_s
            issue = issue_ids[source_issue_id] ||= import_issue!(state, project, bundle, entry)
            log_ids.concat(Array(issue.delete("_import_log_ids")))
          end
          touch_state!(state)
          store.save(state)
        end

        bundle.fetch("workers").each_with_index do |entry, index|
          source_worker_id = entry.fetch("source_worker_id")
          existing = imported_worker_for_bundle(bundle, source_worker_id)
          if existing
            skipped << { "source_worker_id" => source_worker_id, "target_worker_id" => existing.fetch("id"), "reason" => "already_imported" }
            next
          end

          issue = synchronized_state do
            state = normalized_state
            source_issue_id = entry.dig("issue", "source_id").to_s
            issue_ids[source_issue_id] || find_import_issue(state, project_id, bundle, source_issue_id)
          end
          unless issue
            skipped << { "source_worker_id" => source_worker_id, "reason" => "issue_unavailable" }
            next
          end

          settings = entry["session_settings"].is_a?(Hash) ? entry.fetch("session_settings") : {}
          spawn_payload = {
            "issue_id" => issue.fetch("id"),
            "prompt" => Workers::Bundle.retry_prompt(entry, destination_project_path: expanded_project_path),
            "title" => entry["title"],
            "model" => settings["model"],
            "thinking_level" => settings["thinking_level"],
            "_portable_import" => {
              "bundle_id" => bundle.fetch("bundle_id", "unknown"),
              "source_worker_id" => source_worker_id,
              "source_status" => entry["source_status"],
              "session_resume_available" => false,
              "session_resume_reason" => Workers::Bundle::PORTABLE_SESSION_REASON
            }
          }.compact
          # The bundle/worker key is the exactly-once identity, not the outer ImportWorkers
          # command id: two dashboards importing the same file must converge on one reservation.
          result = spawn_worker(
            "portable-import:#{bundle.fetch("bundle_id", "unknown")}:#{index + 1}",
            "SpawnWorker",
            spawn_payload
          )
          if result.fetch("status", nil) == "accepted"
            target_id = result.fetch("target_id")
            mark_imported_worker!(target_id, spawn_payload.fetch("_portable_import"), log_ids)
            imported << { "source_worker_id" => source_worker_id, "target_worker_id" => target_id, "status" => "fresh_session" }
          else
            skipped << { "source_worker_id" => source_worker_id, "reason" => "spawn_failed", "message" => result.fetch("message", "unknown error") }
          end
        end

        message = if imported.empty?
                    "No workers were imported. #{skipped.length} worker(s) were skipped."
                  else
                    "Imported #{imported.length} worker(s) into #{project_id} as fresh sessions; source harness sessions cannot be resumed directly on this computer."
                  end
        accepted_result(
          command_id,
          command_type,
          imported.first && imported.first.fetch("target_worker_id"),
          message,
          {
            "bundle_id" => bundle.fetch("bundle_id", nil),
            "project_id" => project_id,
            "imported" => imported,
            "skipped" => skipped,
            "session_resume" => { "available" => false, "reason" => Workers::Bundle::PORTABLE_SESSION_REASON }
          }.compact,
          log_ids
        )
      rescue ArgumentError => e
        rejected_result(command_id, command_type, "Workers were not imported: #{e.message}", ["worker_import_invalid"])
      rescue StandardError => e
        failed_result(command_id, command_type, "Workers were not imported: #{sanitized_error_message(e)}", [e.class.name, sanitized_error_message(e)])
      end

      # Pause is a user-directed lifecycle transition, not a kill. The pause request is checkpointed
      # before the harness call so a dashboard crash cannot make reconciliation race the abort. The
      # harness session, transcript, workspace, and branch remain attached to the worker record.
      def pause_worker(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId", "target_id", "TargetID")
        return rejected_result(command_id, command_type, "Worker was not paused.", ["agent_id is required"]) if blank?(agent_id)

        operation = synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
          return rejected_result(command_id, command_type, "Agent #{agent_id} is killed.", ["agent_killed"]) if agent.fetch("status", nil) == "killed"
          return rejected_result(command_id, command_type, "Agent #{agent_id} has no agent session.", ["missing_harness_session"]) unless agent_has_session_reference?(agent)
          return rejected_result(command_id, command_type, "Agent #{agent_id} is owned by its Agent session; return to the dashboard before pausing it.", ["interactive_focus_active"]) if agent_focus_ownership_active?(agent)

          metadata = agent.fetch("harness_metadata", {}) || {}
          if agent.fetch("status", nil) == "paused" && !metadata.fetch("pause_request", nil).is_a?(Hash)
            return accepted_result(command_id, command_type, agent.fetch("id"), "Worker #{agent.fetch("id")} is already paused.", deep_copy(agent), [])
          end

          allowed = %w[working idle supervision_lost].include?(agent.fetch("status", nil).to_s)
          unless allowed || metadata.fetch("pause_request", nil).is_a?(Hash)
            return rejected_result(
              command_id,
              command_type,
              "Worker #{agent_id} can only be paused after its session has started; it is #{agent.fetch("status", "unknown")}.",
              ["worker_not_pauseable"]
            )
          end

          request = metadata.fetch("pause_request", nil)
          if request.is_a?(Hash) && operation_owned_by_other_live_instance?(request)
            return accepted_result(command_id, command_type, agent.fetch("id"), "Pause for worker #{agent.fetch("id")} is already being delivered.", deep_copy(agent).merge("pause_queued" => true), [])
          end
          operation_id = request.is_a?(Hash) ? request.fetch("id", nil) : nil
          operation_id = present_string(value_at(payload, "_pause_request_id", "pause_request_id")) ||
                         operation_id || command_id.to_s.strip
          operation_id = "pause:#{agent.fetch("id")}:#{SecureRandom.hex(8)}" if operation_id.empty?
          request ||= {
            "id" => operation_id,
            "requested_at" => timestamp,
            "requested_status" => agent.fetch("status", nil),
            **instance_ownership_metadata
          }.compact
          metadata = metadata.merge("pause_request" => request)
          agent["harness_metadata"] = metadata
          agent["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
          deep_copy(agent)
        end
        return operation unless operation.is_a?(Hash) && operation.fetch("type", nil) == "worker"

        client = harness_client_for_agent(operation)
        session_ref = agent_session_ref(operation)
        updated_ref = session_ref
        begin
          # A supervision-lost session has no local transport to abort. Marking it paused is safe:
          # resume will attach the same durable session instead of creating a new one.
          updated_ref = client.abort_session(session_ref) unless operation.fetch("status", nil) == "supervision_lost"
        rescue StandardError => e
          # A proved child exit is already a stopped runtime; preserving the durable session and
          # marking it paused is safer than asking reconciliation to classify the intentional stop
          # as a completed or failed turn. Other abort failures leave the durable request in place
          # for the next reconciliation pass rather than silently losing the user's pause intent.
          if session_process_missing_error?(e)
            updated_ref = session_ref.merge("is_streaming" => false)
          else
            return failed_result(command_id, command_type, "Could not pause worker #{agent_id}: #{sanitized_error_message(e)}", [e.class.name, sanitized_error_message(e)])
          end
        end

        synchronized_state do
          state = normalized_state
          current = find_agent(state, operation.fetch("id"))
          return rejected_result(command_id, command_type, "Worker #{agent_id} no longer exists.", ["agent_not_found"]) unless current

          metadata = current.fetch("harness_metadata", {}) || {}
          request = metadata.fetch("pause_request", {})
          return accepted_result(command_id, command_type, current.fetch("id"), "Worker #{current.fetch("id")} is already paused.", deep_copy(current), []) unless request.fetch("id", nil).to_s == operation.dig("harness_metadata", "pause_request", "id").to_s

          merge_session_ref_into_agent!(current, updated_ref || session_ref)
          now = timestamp
          previous_status = request.fetch("requested_status", operation.fetch("status", "idle"))
          pause_count = metadata.fetch("pause_count", 0).to_i + 1
          current["status"] = "paused"
          current["updated_at"] = now
          current["harness_metadata"] = metadata.merge(
            "paused" => true,
            "pause_count" => pause_count,
            "pause" => {
              "state" => "paused",
              "requested_at" => request.fetch("requested_at", now),
              "paused_at" => now,
              "previous_status" => previous_status,
              "interrupted_turn" => previous_status == "working",
              "session_preserved" => true
            },
            "pause_request" => nil,
            "resume_request" => nil,
            "is_streaming" => false
          ).compact
          refresh_worker_parent_statuses!(state, current, now)
          message = "Paused worker #{current.fetch("id")}; its session and workspace were preserved."
          log_ids = append_log(
            state,
            source_type: "worker",
            source_id: current.fetch("id"),
            level: "info",
            message: message,
            details: {
              "agent_id" => current.fetch("id"),
              "issue_id" => current.fetch("issue_id", nil),
              "session_id" => current.fetch("harness_session_id", nil),
              "session_preserved" => true,
              "interrupted_turn" => previous_status == "working"
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          accepted_result(command_id, command_type, current.fetch("id"), message, deep_copy(current), log_ids)
        end
      rescue StandardError => e
        failed_result(command_id, command_type, "Could not pause worker #{agent_id}: #{sanitized_error_message(e)}", [e.class.name, sanitized_error_message(e)])
      end

      # Resume uses PromptAgent's exactly-once delivery bookkeeping with a durable request marker.
      # If the dashboard exits after the harness accepts the continuation but before the worker record is
      # finalized, reconciliation replays the same delivery id and PromptAgent recognizes it as
      # already delivered rather than sending a second continuation.
      def resume_worker(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId", "target_id", "TargetID")
        return rejected_result(command_id, command_type, "Worker was not resumed.", ["agent_id is required"]) if blank?(agent_id)

        prepared = synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
          return rejected_result(command_id, command_type, "Agent #{agent_id} is killed.", ["agent_killed"]) if agent.fetch("status", nil) == "killed"
          return rejected_result(command_id, command_type, "Agent #{agent_id} has no agent session.", ["missing_harness_session"]) unless agent_has_session_reference?(agent)
          return rejected_result(command_id, command_type, "Agent #{agent_id} is owned by its Agent session; return to the dashboard before resuming it.", ["interactive_focus_active"]) if agent_focus_ownership_active?(agent)

          metadata = agent.fetch("harness_metadata", {}) || {}
          request = metadata.fetch("resume_request", nil)
          if request.is_a?(Hash)
            owner = other_live_instance_pid(
              request.fetch("owner_instance_id", nil),
              request.fetch("owner_instance_pid", nil),
              request.fetch("owner_instance_started_at", nil)
            )
            if owner
              return accepted_result(command_id, command_type, agent.fetch("id"), "Resume for worker #{agent.fetch("id")} is already being delivered.", deep_copy(agent).merge("resume_queued" => true), [])
            end
          elsif !%w[paused supervision_lost].include?(agent.fetch("status", nil).to_s)
            delivered_ids = Array(metadata.fetch("prompt_command_ids", [])).map(&:to_s)
            if present_string(command_id) && delivered_ids.include?(command_id.to_s)
              return accepted_result(command_id, command_type, agent.fetch("id"), "Worker #{agent.fetch("id")} was already resumed.", deep_copy(agent), [])
            end
            return rejected_result(command_id, command_type, "Worker #{agent_id} is not paused; it is #{agent.fetch("status", "unknown")}.", ["worker_not_paused"])
          end

          # A crash after the prompt was accepted leaves a working worker with its resume marker.
          # Finalize that marker without sending another prompt.
          if agent.fetch("status", nil) == "working" && request.is_a?(Hash)
            return { "kind" => "finalize", "agent_id" => agent.fetch("id"), "request_id" => request.fetch("id") }
          end

          request_id = request.is_a?(Hash) ? request.fetch("id", nil) : nil
          request_id = present_string(value_at(payload, "_resume_request_id", "resume_request_id")) || request_id || command_id.to_s.strip
          request_id = "resume:#{agent.fetch("id")}:#{SecureRandom.hex(8)}" if request_id.empty?
          request ||= {
            "id" => request_id,
            "requested_at" => timestamp,
            "prompt" => WORKER_RESUME_PROMPT,
            **instance_ownership_metadata
          }.compact
          metadata = metadata.merge("resume_request" => request)
          agent["harness_metadata"] = metadata
          agent["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
          { "kind" => "deliver", "agent" => deep_copy(agent), "request" => request }
        end

        if prepared.fetch("kind", nil) == "finalize"
          finalize_worker_resume(prepared.fetch("agent_id"), prepared.fetch("request_id"), command_id: command_id, command_type: command_type)
          return accepted_result(command_id, command_type, prepared.fetch("agent_id"), "Resumed worker #{prepared.fetch("agent_id")}.", agent_record_snapshot(prepared.fetch("agent_id")), [])
        end

        agent = prepared.fetch("agent")
        request = prepared.fetch("request")
        prompt_payload = {
          "agent_id" => agent.fetch("id"),
          "prompt" => request.fetch("prompt", WORKER_RESUME_PROMPT),
          "mode" => "normal",
          "_resume_worker" => true,
          "_resume_request_id" => request.fetch("id")
        }
        pending_prompt_id = request.fetch("pending_prompt_id", nil)
        prompt_payload["_pending_prompt_id"] = pending_prompt_id if pending_prompt_id
        result = prompt_agent(request.fetch("id"), command_type, prompt_payload)
        if result.fetch("status", nil) == "accepted" && result.dig("result", "queued")
          record_worker_resume_pending(agent.fetch("id"), request.fetch("id"), result)
          return result.merge(
            "target_id" => agent.fetch("id"),
            "message" => "Queued resume for worker #{agent.fetch("id")}; it will continue when its session is available."
          )
        end

        if result.fetch("status", nil) == "accepted"
          finalize_worker_resume(agent.fetch("id"), request.fetch("id"), command_id: command_id, command_type: command_type)
          current = agent_record_snapshot(agent.fetch("id")) || result.fetch("result", nil)
          return result.merge(
            "target_id" => agent.fetch("id"),
            "message" => "Resumed worker #{agent.fetch("id")} using its existing session.",
            "result" => current
          )
        end

        clear_worker_resume_request(agent.fetch("id"), request.fetch("id"))
        result
      rescue StandardError => e
        failed_result(command_id, command_type, "Could not resume worker #{agent_id}: #{sanitized_error_message(e)}", [e.class.name, sanitized_error_message(e)])
      end

      def clear_worker_pause_request(agent_id, request_id)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          request = metadata.fetch("pause_request", nil)
          next unless request.is_a?(Hash) && request.fetch("id", nil).to_s == request_id.to_s

          metadata.delete("pause_request")
          agent["harness_metadata"] = metadata
          agent["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
        end
      end

      def record_worker_resume_pending(agent_id, request_id, result)
        pending_id = result.dig("result", "pending_prompt_id")
        return result unless pending_id

        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next result unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          request = metadata.fetch("resume_request", nil)
          next result unless request.is_a?(Hash) && request.fetch("id", nil).to_s == request_id.to_s

          request["pending_prompt_id"] = pending_id
          metadata["resume_request"] = request
          agent["harness_metadata"] = metadata
          agent["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
          result
        end
      end

      def clear_worker_resume_request(agent_id, request_id)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          request = metadata.fetch("resume_request", nil)
          next unless request.is_a?(Hash) && request.fetch("id", nil).to_s == request_id.to_s

          metadata.delete("resume_request")
          agent["harness_metadata"] = metadata
          agent["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
        end
      end

      def finalize_worker_resume(agent_id, request_id, command_id:, command_type:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return rejected_result(command_id, command_type, "Worker #{agent_id} no longer exists.", ["agent_not_found"]) unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          request = metadata.fetch("resume_request", nil)
          return accepted_result(command_id, command_type, agent.fetch("id"), "Worker #{agent.fetch("id")} is already resumed.", deep_copy(agent), []) unless request.is_a?(Hash) && request.fetch("id", nil).to_s == request_id.to_s

          now = timestamp
          pause = metadata.fetch("pause", {})
          pause = {} unless pause.is_a?(Hash)
          metadata = metadata.merge(
            "paused" => false,
            "pause" => pause.merge("state" => "resumed", "resumed_at" => now),
            "resume_request" => nil
          ).compact
          agent["harness_metadata"] = metadata
          agent["updated_at"] = now
          touch_state!(state)
          store.save(state)
          agent
        end
      end

      # Reconciliation owns unfinished pause/resume side effects. The markers are intentionally
      # separate from lifecycle status so a crash between state publication and harness I/O is
      # repaired without polling a session that the user asked us to stop.
      def reconcile_pending_worker_pauses
        candidates = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "worker"
            request = (agent.fetch("harness_metadata", {}) || {}).fetch("pause_request", nil)
            next unless request.is_a?(Hash)
            next if operation_owned_by_other_live_instance?(request)

            deep_copy(agent)
          end
        end
        candidates.map do |agent|
          pause_worker(nil, "PauseWorker", "agent_id" => agent.fetch("id"), "_pause_request_id" => agent.dig("harness_metadata", "pause_request", "id"))
        end
      end

      def reconcile_pending_worker_resumes
        candidates = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "worker"
            request = (agent.fetch("harness_metadata", {}) || {}).fetch("resume_request", nil)
            next unless request.is_a?(Hash)
            next if operation_owned_by_other_live_instance?(request)

            deep_copy(agent)
          end
        end
        candidates.map do |agent|
          resume_worker(nil, "ResumeWorker", "agent_id" => agent.fetch("id"), "_resume_request_id" => agent.dig("harness_metadata", "resume_request", "id"))
        end
      end
    end
  end
end
