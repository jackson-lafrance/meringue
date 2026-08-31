# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # SpawnWorker: validating the request, reserving the record, and provisioning it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def spawn_worker(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        prompt = value_at(payload, "prompt", "Prompt")
        worker_title = value_at(payload, "title", "Title", "worker_title", "workerTitle")
        requested_model = value_at(payload, "model", "Model")
        requested_thinking_level = value_at(payload, "thinking_level", "thinkingLevel", "ThinkingLevel")
        session_settings_override = {}
        follow_up_of_agent_id = value_at(payload, "follow_up_of_agent_id", "followUpOfAgentID", "followUpOfAgentId")
        replace_agent_id = value_at(payload, "replace_agent_id", "replaceAgentID", "replaceAgentId")
        after_agent_id = value_at(payload, *DEFERRED_WORKER_AFTER_KEYS)
        failure_policy = normalized_deferred_failure_policy(payload)
        include_predecessor_result = deferred_handover_requested?(payload)
        gate_plan = deferred_gate_plan(payload)
        command_gate = gate_plan.fetch("gate", nil)
        # Set by the kernel when it starts a worker it had queued behind another agent. It is the
        # only way past the deferral branch, so a queued worker cannot start itself twice.
        activating_deferred = !!value_at(payload, "_activate_deferred", "activate_deferred")
        deferred_agent_id = present_string(value_at(payload, "_deferred_agent_id", "deferred_agent_id"))
        # Set by the kernel when it re-runs provisioning for a reservation that already exists.
        # Naming the record directly is what lets a worker be recovered or retried even when its
        # original spawn carried no command id, instead of silently spawning a second worker.
        reservation_agent_id = present_string(value_at(payload, "_reservation_agent_id", "reservation_agent_id"))
        # Executor-only marker. Public SpawnWorker calls stop after the durable reservation; a
        # bounded provisioning thread re-enters with this marker to perform external I/O.
        provisioning_reserved = !!value_at(payload, "_provision_reserved", "provision_reserved")
        requested_workspace_path = value_at(payload, "workspace_path", "WorkspacePath", "workspacePath")
        requested_workspace_mode = value_at(payload, "workspace_mode", "workspaceMode", "WorkspaceMode")
        # Set by the kernel when it corrected a head's predicted issue id; kept on the worker and
        # in its spawn log so a corrected route is visible instead of silent.
        rerouted_from_issue_id = present_string(value_at(payload, "_rerouted_from_issue_id", "rerouted_from_issue_id"))
        portable_import = value_at(payload, "_portable_import", "portable_import")
        portable_import = portable_import.is_a?(Hash) ? deep_copy(portable_import) : nil
        self_fixing_recovery = value_at(payload, "_self_fixing_recovery", "self_fixing_recovery")
        self_fixing_recovery = self_fixing_recovery.is_a?(Hash) ? deep_copy(self_fixing_recovery) : nil
        # Set by the kernel when it restarts a worker whose session can no longer be replayed. The
        # successor takes over the dead worker's existing worktree and branch instead of allocating
        # a new one, because that is where the unfinished work already lives.
        inherit_workspace_agent_id = present_string(value_at(payload, "_inherit_workspace_from_agent_id", "inherit_workspace_from_agent_id"))
        session_restart_of_agent_id = present_string(value_at(payload, "_session_restart_of_agent_id", "session_restart_of_agent_id"))
        # Head-facing workspace sharing: name the predecessor whose worktree/branch this worker
        # should continue in, or turn the continuation default off for a step that must be isolated.
        reuse_workspace_agent_id = present_string(value_at(payload, *WORKSPACE_REUSE_AGENT_KEYS))
        errors = []
        workspace_mode = normalized_workspace_mode(requested_workspace_mode, errors: errors)
        if requested_model
          reason = Meringue::Harness::ModelReference.rejection_reason(requested_model)
          if reason
            errors << "invalid model: #{reason}"
          else
            session_settings_override["model"] = Meringue::Harness::ModelReference.normalize(requested_model)
          end
        end
        if requested_thinking_level
          level = requested_thinking_level.to_s.strip.downcase
          if Meringue::Harness::ModelCatalog::THINKING_LEVELS.include?(level)
            session_settings_override["thinking_level"] = level
          else
            errors << "thinking_level must be one of: #{Meringue::Harness::ModelCatalog::THINKING_LEVELS.join(", ")}"
          end
        end
        share_workspace = normalized_share_workspace(payload, errors: errors)
        completion_continuation = normalized_completion_continuation(payload, errors: errors)

        errors << "issue_id is required" if blank?(issue_id)
        errors << "prompt is required" if blank?(prompt)
        if workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY && present_string(requested_workspace_path)
          errors << "workspace_path cannot be combined with shared_read_only workspace_mode"
        end
        if workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY && (share_workspace == true || reuse_workspace_agent_id)
          errors << "shared_read_only workspace_mode cannot reuse a worker-owned workspace"
        end
        if workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY &&
           (command_gate || completion_continuation_gate(completion_continuation))
          errors << "shared_read_only workspace_mode cannot be combined with an after_command gate"
        end
        if share_workspace == false && reuse_workspace_agent_id
          errors << "share_workspace_conflicts_with_reuse_workspace_of_agent_id"
        end
        if reuse_workspace_agent_id && present_string(requested_workspace_path)
          errors << "workspace_path_conflicts_with_reuse_workspace_of_agent_id"
        end
        if share_workspace && !reuse_workspace_agent_id &&
           [follow_up_of_agent_id, replace_agent_id, after_agent_id].none? { |value| present_string(value) }
          errors << "share_workspace_requires_a_related_worker"
        end
        if present_string(follow_up_of_agent_id) && present_string(replace_agent_id)
          errors << "follow_up_of_agent_id and replace_agent_id are mutually exclusive"
        end
        if present_string(after_agent_id) && present_string(replace_agent_id)
          # A replacement takes over now: the kernel spawns the successor and then kills the worker
          # it replaces. Deferring that would leave the replaced worker running indefinitely.
          errors << "deferred_after_agent_conflicts_with_replace"
        end
        if command_gate && present_string(replace_agent_id)
          errors << "after_command_conflicts_with_replace"
        end
        errors.concat(gate_plan.fetch("errors", []))
        errors << "invalid_if_predecessor_fails" if failure_policy.nil?
        return synchronized_state { rejected_result(command_id, command_type, "Worker was not spawned.", errors) } unless errors.empty?

        reservation = synchronized_state do
          state = normalized_state
          issue = find_issue(state, issue_id)
          return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) unless issue

          project = find_project(state, issue.fetch("project_id"))
          return rejected_result(command_id, command_type, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

          # An activation names the queued record directly: its reservation was written by an earlier
          # command, so resolving it only through spawn_command_id would risk provisioning a second
          # worker for the same queued record.
          existing = worker_for_spawn_command(state, command_id)
          existing ||= find_agent(state, deferred_agent_id) if activating_deferred && deferred_agent_id
          existing ||= reserved_worker_for_retry(state, reservation_agent_id, issue)
          if existing && agent_has_session_reference?(existing)
            return accepted_result(command_id, command_type, existing.fetch("id"), "Worker #{existing.fetch("id")} was already spawned.", existing, [])
          end
          # A reservation being provisioned by another live instance must not be
          # provisioned again here: that races on the same worktree branch and
          # leaves two harness sessions in one workspace.
          if @async_worker_provisioning && existing && worker_provisioning_in_progress?(existing) &&
             !provisioning_reserved && !activating_deferred
            # The reservation is the exactly-once effect of SpawnWorker. Replays acknowledge it
            # whether this engine or another live engine currently owns the expensive phase.
            return accepted_result(
              command_id,
              command_type,
              existing.fetch("id"),
              "Worker #{existing.fetch("id")} was already reserved and is being provisioned.",
              deep_copy(existing),
              []
            )
          end
          if existing && worker_provisioning_in_progress?(existing) && owned_by_other_live_instance?(existing)
            return rejected_result(
              command_id,
              command_type,
              "Worker #{existing.fetch("id")} is already being spawned by another Meringue instance.",
              ["worker_spawn_in_progress"]
            )
          end
          # This command already queued its worker behind another agent. Report the queued record
          # instead of starting a second session for the same logical command.
          if existing && waiting_deferred_worker?(existing) && !activating_deferred
            return accepted_result(
              command_id,
              command_type,
              existing.fetch("id"),
              deferred_queue_message(existing),
              deep_copy(existing),
              []
            )
          end

          unless existing
            related_agent_id = present_string(replace_agent_id) || present_string(follow_up_of_agent_id)
            related_agent = find_agent(state, related_agent_id) if related_agent_id
            if related_agent_id && (!related_agent || related_agent.fetch("type", nil) != "worker")
              return rejected_result(
                command_id,
                command_type,
                "Related worker #{related_agent_id} does not exist. #{RELATED_AGENT_REFERENCE_HINT}",
                ["related_agent_not_found"]
              )
            end
            if related_agent && related_agent.fetch("issue_id", nil) != issue.fetch("id")
              return rejected_result(
                command_id,
                command_type,
                "Related worker #{related_agent_id} belongs to another issue. #{RELATED_AGENT_REFERENCE_HINT}",
                ["related_agent_issue_mismatch"]
              )
            end
            if present_string(replace_agent_id) && !replaceable_worker?(related_agent)
              return rejected_result(command_id, command_type, "Worker #{related_agent_id} has already been killed or replaced.", ["agent_not_replaceable"])
            end
            if reuse_workspace_agent_id
              # A bad reference is a head contract error, not a safety refusal: it is rejected the
              # same way a bad lineage reference is, instead of silently provisioning fresh.
              reuse_target = find_agent(state, reuse_workspace_agent_id)
              if !reuse_target || reuse_target.fetch("type", nil) != "worker"
                return rejected_result(
                  command_id,
                  command_type,
                  "Worker #{reuse_workspace_agent_id} does not exist, so its workspace cannot be reused. #{RELATED_AGENT_REFERENCE_HINT}",
                  ["reuse_workspace_agent_not_found"]
                )
              end
              if reuse_target.fetch("issue_id", nil) != issue.fetch("id")
                return rejected_result(
                  command_id,
                  command_type,
                  "Worker #{reuse_workspace_agent_id} belongs to another issue, so its workspace cannot be reused. #{RELATED_AGENT_REFERENCE_HINT}",
                  ["reuse_workspace_agent_issue_mismatch"]
                )
              end
            end

            if (present_string(after_agent_id) || command_gate) && !activating_deferred
              decision = if present_string(after_agent_id)
                           deferred_spawn_decision(state, after_agent_id: after_agent_id, failure_policy: failure_policy)
                         else
                           # A gate-only worker has no predecessor to validate; it is still one
                           # queued link, so it carries the same chain depth as a one-step chain.
                           { "kind" => "defer", "predecessor" => nil, "chain_depth" => 1 }
                         end
              # A command gate keeps the worker queued even when its predecessor has already
              # settled: there is still a condition left to satisfy, and reusing the queued path
              # means the gate is polled and handed over by exactly one mechanism.
              decision = decision.merge("kind" => "defer") if command_gate && decision.fetch("kind") == "start_now"
              case decision.fetch("kind")
              when "reject"
                return rejected_result(command_id, command_type, decision.fetch("message"), decision.fetch("errors"))
              when "defer"
                return queue_deferred_worker(
                  state,
                  command_id: command_id,
                  command_type: command_type,
                  issue: issue,
                  project: project,
                  prompt: prompt,
                  title: worker_title,
                  requested_workspace_path: requested_workspace_path,
                  follow_up_of_agent_id: present_string(follow_up_of_agent_id),
                  predecessor: decision.fetch("predecessor"),
                  chain_depth: decision.fetch("chain_depth"),
                  failure_policy: failure_policy,
                  include_predecessor_result: include_predecessor_result,
                  completion_continuation: completion_continuation,
                  session_settings_override: session_settings_override,
                  workspace_mode: workspace_mode,
                  command_gate: command_gate,
                  rerouted_from_issue_id: rerouted_from_issue_id,
                  # The workspace decision is deliberately not made here: a queued worker is
                  # provisioned when it activates, and whether its predecessor's worktree is free
                  # can only be answered then. The *intent* is persisted so activation, a
                  # provisioning retry, and a restart all resolve it the same way.
                  self_fixing_recovery: self_fixing_recovery,
                  workspace_reuse_request: workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY ? nil : workspace_reuse_request(
                    share_workspace: share_workspace,
                    reuse_agent_id: reuse_workspace_agent_id,
                    inherit_agent_id: nil,
                    follow_up_of_agent_id: follow_up_of_agent_id,
                    replace_agent_id: nil,
                    after_agent_id: decision.fetch("predecessor", nil)&.fetch("id", nil),
                    requested_workspace_path: requested_workspace_path
                  )
                )
              else
                # Nothing left to wait for: the predecessor already settled, so start now and still
                # hand its final report to this worker.
                after_agent_id = decision.fetch("predecessor").fetch("id")
                prompt = deferred_handover_prompt(prompt, decision.fetch("predecessor"), include_predecessor_result)
              end
            end
          end

          active_provider = active_harness_provider(state)
          now = timestamp
          if existing
            agent_id = existing.fetch("id")
            workspace = workspace_from_reserved_agent(existing)
            active_provider = existing.fetch("harness", active_provider)
            # This is a fresh provisioning attempt for a reservation whose last attempt failed, so
            # the record says "allocating" again instead of still showing the previous failure.
            mark_worker_provisioning_attempt!(existing, now)
            existing_metadata = existing.fetch("harness_metadata", {}) || {}
            session_settings_override = existing_metadata.fetch("spawn_session_settings", session_settings_override)
            follow_up_of_agent_id = existing_metadata.fetch("follow_up_of_agent_id", follow_up_of_agent_id)
            replace_agent_id = existing_metadata.fetch("replace_agent_id", replace_agent_id)
            completion_continuation ||= worker_completion_continuation(existing)
            after_agent_id = present_string(existing.fetch("after_agent_id", nil)) ||
                             present_string(deferred_spawn_metadata(existing).fetch("after_agent_id", nil)) ||
                             present_string(after_agent_id)
            # A queued worker's workspace is decided when it activates, and a retry re-decides it,
            # because "is the predecessor's worktree free" is only answerable now. The persisted
            # request is what makes activation, a retry, and a restart resolve it the same way.
            workspace_mode = persisted_worker_workspace_mode(existing, fallback: workspace_mode)
            reuse_request = workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY ? nil : persisted_workspace_reuse_request(
              existing,
              share_workspace: share_workspace,
              reuse_agent_id: reuse_workspace_agent_id,
              inherit_agent_id: inherit_workspace_agent_id,
              follow_up_of_agent_id: follow_up_of_agent_id,
              replace_agent_id: replace_agent_id,
              after_agent_id: after_agent_id,
              requested_workspace_path: requested_workspace_path
            )
            workspace_reuse = reuse_request && claim_reused_worker_workspace(
              state,
              request: reuse_request,
              requester_id: agent_id,
              issue: issue,
              reserved_workspace: workspace
            )
            if workspace_reuse && workspace_reuse.fetch("state") == WORKSPACE_REUSE_STATE_CLAIMED
              workspace = workspace_reuse.fetch("workspace")
              existing["workspace_path"] = workspace.fetch("workspace_path")
              existing["workspace_strategy"] = workspace.fetch("workspace_strategy")
              existing["workspace_branch"] = workspace.fetch("workspace_branch", nil)
              existing["harness_metadata"] = (existing.fetch("harness_metadata", {}) || {}).merge(
                "workspace_plan" => workspace.fetch("plan", nil)
              ).compact
            end
          else
            agent_id = next_worker_id!(state, issue.fetch("id"))
            reuse_request = workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY ? nil : workspace_reuse_request(
              share_workspace: share_workspace,
              reuse_agent_id: reuse_workspace_agent_id,
              inherit_agent_id: inherit_workspace_agent_id,
              follow_up_of_agent_id: follow_up_of_agent_id,
              replace_agent_id: replace_agent_id,
              after_agent_id: after_agent_id,
              requested_workspace_path: requested_workspace_path
            )
            workspace_reuse = reuse_request && claim_reused_worker_workspace(
              state,
              request: reuse_request,
              requester_id: agent_id,
              issue: issue
            )
            # A session restart exists only to take over the dead worker's checkout, so it fails
            # loudly instead of silently starting fresh somewhere else and abandoning that work.
            if session_restart_workspace_reuse_refused?(workspace_reuse)
              return rejected_result(
                command_id,
                command_type,
                "Worker cannot take over #{reuse_request.fetch("agent_id")}'s workspace: " \
                "#{workspace_reuse_reason_text(workspace_reuse)}.",
                ["inherited_workspace_unavailable"]
              )
            end

            claimed_workspace = workspace_reuse && workspace_reuse.fetch("state") == WORKSPACE_REUSE_STATE_CLAIMED ?
                                  workspace_reuse.fetch("workspace") : nil
            workspace = claimed_workspace || resolve_worker_workspace(
              project: project,
              issue: issue,
              requested_workspace_path: requested_workspace_path,
              preview_agent_id: agent_id,
              task_title: worker_display_title(worker_title, issue),
              create: false,
              workspace_mode: workspace_mode,
              harness_provider: active_provider
            )
            return rejected_result(command_id, command_type, "Worker workspace is invalid.", workspace.fetch("errors")) unless workspace.fetch("errors").empty?

            agent = build_worker_reservation(
              agent_id: agent_id,
              issue: issue,
              project: project,
              workspace: workspace,
              provider: active_provider,
              command_id: command_id,
              prompt: prompt,
              title: worker_title,
              requested_workspace_path: requested_workspace_path,
              follow_up_of_agent_id: follow_up_of_agent_id,
              replace_agent_id: replace_agent_id,
              after_agent_id: present_string(after_agent_id),
              completion_continuation: completion_continuation,
              session_settings_override: session_settings_override,
              workspace_reuse_request: reuse_request,
              workspace_mode: workspace_mode,
              portable_import: portable_import,
              self_fixing_recovery: self_fixing_recovery,
              now: now,
              harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i
            )
            if inherit_workspace_agent_id || session_restart_of_agent_id
              # Persisted on the reservation so a provisioning retry inherits the same workspace and
              # keeps counting the restart chain instead of starting the recovery over.
              agent["harness_metadata"] = agent.fetch("harness_metadata").merge(
                "inherit_workspace_from_agent_id" => inherit_workspace_agent_id,
                "session_recovery" => session_restart_of_agent_id ? successor_session_recovery(state, session_restart_of_agent_id, now) : nil
              ).compact
            end
            state.fetch("agents") << agent
            issue.fetch("agent_ids") << agent_id unless issue.fetch("agent_ids").include?(agent_id)
            issue["status"] = "working"
            issue["updated_at"] = now
            project["status"] = "working"
            project["updated_at"] = now
            # The reservation is deliberately silent: the queued worker is already visible in the
            # AgentTree, and the "Spawned worker ..." log emitted once the harness session exists
            # carries the same routing details plus the *actual* workspace path/branch (a plan can
            # still be uniquified or adopted before creation). Provisioning that fails is reported
            # by fail_worker_reservation as an error log, so nothing goes unreported.
            # harness_metadata.provisioning_state remains the structured telemetry for this phase.
          end
          if @async_worker_provisioning && !provisioning_reserved
            queued_agent = find_agent(state, agent_id)
            queued_metadata = queued_agent.fetch("harness_metadata", {}) || {}
            queued_agent["status"] = "queued"
            queued_agent["updated_at"] = now
            queued_agent["harness_metadata"] = queued_metadata.merge(
              "provisioning_state" => "provisioning_queued",
              "provisioning_queued_at" => now,
              "provisioning_next_step" => "Waiting for an available worker-provisioning slot."
            )
          end
          touch_state!(state, now)
          store.save(state)

          {
            "agent_id" => agent_id,
            "issue" => deep_copy(issue),
            "project" => deep_copy(project),
            "workspace" => workspace,
            "now" => now,
            "harness" => active_provider,
            "harness_generation" => state.fetch("metadata").fetch("harness_generation", 0).to_i,
            "follow_up_of_agent_id" => present_string(follow_up_of_agent_id),
            "replace_agent_id" => present_string(replace_agent_id),
            "after_agent_id" => present_string(after_agent_id),
            "workspace_reuse" => workspace_reuse,
            "session_restart_of_agent_id" => session_restart_of_agent_id,
            "session_settings_override" => session_settings_override,
            "workspace_mode" => workspace_mode,
            "prompt" => prompt.to_s
          }
        end
        prompt = reservation.fetch("prompt", prompt)

        if @async_worker_provisioning && !provisioning_reserved
          schedule_worker_provisioning(reservation.fetch("agent_id"))
          reserved_agent = agent_record_snapshot(reservation.fetch("agent_id"))
          message = "Reserved worker #{reservation.fetch("agent_id")}; workspace and harness provisioning will continue in the background."
          return accepted_result(
            command_id,
            command_type,
            reservation.fetch("agent_id"),
            message,
            reserved_agent,
            []
          )
        end

        # A claimed workspace is already provisioned by definition: it is the predecessor's existing
        # worktree, so it is adopted as-is and never re-created, re-branched, or cleaned up. The git
        # half of the safety check runs here, outside the state lock, because it shells out.
        workspace_reuse = settle_workspace_reuse_claim(reservation)
        workspace = reuse_claim_workspace(workspace_reuse)
        if workspace.nil? && session_restart_workspace_reuse_refused?(workspace_reuse)
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Worker #{reservation.fetch("agent_id")} could not take over " \
                     "#{workspace_reuse.fetch("of_agent_id", "its predecessor")}'s workspace: " \
                     "#{workspace_reuse_reason_text(workspace_reuse)}.",
            errors: ["inherited_workspace_unavailable", workspace_reuse.fetch("reason", "workspace_reuse_refused")],
            workspace: reservation.fetch("workspace", {})
          )
        end
        workspace ||= resolve_worker_workspace(
          project: reservation.fetch("project"),
          issue: reservation.fetch("issue"),
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: reservation.fetch("agent_id"),
          task_title: worker_display_title(worker_title, reservation.fetch("issue")),
          create: true,
          progress_agent_id: reservation.fetch("agent_id"),
          workspace_mode: reservation.fetch("workspace_mode", workspace_mode),
          harness_provider: reservation.fetch("harness")
        )
        unless workspace_reuse.is_a?(Hash) && workspace_reuse.fetch("state", nil) == WORKSPACE_REUSE_STATE_REUSED
          workspace = ensure_launchable_worker_workspace(
            workspace,
            reservation: reservation,
            requested_workspace_path: requested_workspace_path,
            task_title: worker_display_title(worker_title, reservation.fetch("issue")),
            workspace_mode: reservation.fetch("workspace_mode", workspace_mode),
            harness_provider: reservation.fetch("harness")
          )
        end
        reservation["workspace_reuse"] = workspace_reuse
        if workspace.fetch("errors", []).any?
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Worker workspace provisioning failed: #{workspace.fetch("errors").join("; ")}",
            errors: workspace.fetch("errors"),
            workspace: workspace,
            recovery: workspace.fetch("recovery", nil)
          )
        end
        reservation["workspace"] = workspace
        checkpoint_worker_workspace!(reservation, workspace, reuse: workspace_reuse)
        # PromptAgent may have added an instruction while allocation was running. Read the durable
        # first-turn prompt after the workspace checkpoint so same-batch routing is not lost merely
        # because the harness startup moved to a background executor.
        latest_reservation = agent_record_snapshot(reservation.fetch("agent_id"))
        prompt = latest_reservation.dig("harness_metadata", "spawn_prompt") if latest_reservation
        prompt = shared_workspace_prompt_note(prompt, workspace_reuse)

        session_ref = nil
        begin
          spawn_options = {
            kind: "worker",
            cwd: workspace.fetch("workspace_path"),
            prompt: prompt.to_s,
            system_prompt: worker_system_prompt(
              reservation.fetch("issue"),
              workspace_mode: workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED)
            ),
            session_name: worker_session_name(reservation.fetch("issue"), worker_title: worker_title),
            workspace_mode: workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED)
          }
          override = reservation.fetch("session_settings_override", {})
          spawn_options[:session_settings] = override unless override.empty?
          session_ref = active_harness_client(provider: reservation.fetch("harness")).spawn_session(**spawn_options)
        rescue StandardError => e
          cleanup_worker_workspace_safely(workspace)
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Could not start an agent session for worker #{reservation.fetch("agent_id")}: #{e.message}",
            errors: [e.class.name, e.message],
            workspace: workspace
          )
        end

        synchronized_state do
          state = normalized_state
          issue = find_issue(state, reservation.fetch("issue").fetch("id"))
          project = issue && find_project(state, issue.fetch("project_id"))
          reserved_agent = find_agent(state, reservation.fetch("agent_id"))
          unless issue && project && reserved_agent
            kill_session_safely(session_ref)
            cleanup_worker_workspace_safely(workspace)
            return failed_result(
              command_id,
              command_type,
              "Worker #{reservation.fetch("agent_id")} could not be recorded because its reservation, issue, or project no longer exists.",
              ["reservation_issue_or_project_not_found"]
            )
          end

          follow_up_of_id = reservation.fetch("follow_up_of_agent_id", nil)
          replaces_id = reservation.fetch("replace_agent_id", nil)
          related_agent_id = replaces_id || follow_up_of_id
          related_agent = find_agent(state, related_agent_id) if related_agent_id
          relation_invalid = related_agent_id && (!related_agent || related_agent.fetch("issue_id", nil) != issue.fetch("id"))
          replacement_invalid = replaces_id && !replaceable_worker?(related_agent)
          if relation_invalid || replacement_invalid
            kill_session_safely(session_ref)
            cleanup_worker_workspace_safely(reservation.fetch("workspace"))
            return fail_worker_reservation(
              reservation,
              command_id: command_id,
              command_type: command_type,
              message: "Worker #{reservation.fetch("agent_id")} could not be related because the prior worker is no longer available on this issue.",
              errors: ["related_agent_unavailable"],
              workspace: reservation.fetch("workspace")
            )
          end

          after_agent_value = present_string(reservation.fetch("after_agent_id", nil)) ||
                              present_string(reserved_agent.fetch("after_agent_id", nil))
          agent = build_worker_agent(
            agent_id: reservation.fetch("agent_id"),
            issue: issue,
            project: project,
            workspace: workspace,
            session_ref: session_ref,
            now: reserved_agent.fetch("created_at", reservation.fetch("now")),
            title: worker_title,
            harness_generation: reservation.fetch("harness_generation"),
            follow_up_of_agent_id: follow_up_of_id,
            replaces_agent_id: replaces_id,
            after_agent_id: after_agent_value
          )
          now = timestamp
          agent["harness_metadata"] = (reserved_agent.fetch("harness_metadata", {}) || {}).merge(agent.fetch("harness_metadata", {})).merge(
            "provisioning_state" => "ready",
            "provisioning_progress" => nil,
            "provisioned_at" => now,
            "spawn_command_id" => command_id,
            "rerouted_from_issue_id" => rerouted_from_issue_id,
            "deferred_spawn" => activated_deferred_spawn_metadata(reserved_agent, now)
          ).compact
          state.fetch("agents")[state.fetch("agents").index(reserved_agent)] = agent
          issue.fetch("agent_ids") << reservation.fetch("agent_id") unless issue.fetch("agent_ids").include?(reservation.fetch("agent_id"))
          if related_agent && follow_up_of_id
            related_agent["follow_up_agent_ids"] = (Array(related_agent["follow_up_agent_ids"]) + [agent.fetch("id")]).uniq
            related_agent["updated_at"] = now
          end
          repointed_dependents = { "agent_ids" => [], "log_entry_ids" => [] }
          if related_agent && replaces_id
            mark_agent_killed!(related_agent, now)
            related_agent["replaced_by_agent_id"] = agent.fetch("id")
            # The successor inherits the replaced worker's queue in the same command. Waiting for
            # reconciliation would race the pass that removes the replaced record.
            repointed_dependents = repoint_deferred_dependents_in_state!(
              state,
              from_agent_id: replaces_id,
              to_agent: agent,
              now: now,
              trigger: "replacement"
            )
            kill_session_safely(session_ref_from_agent(related_agent), agent: related_agent) if present_string(related_agent.fetch("harness", nil))
          end
          issue["status"] = "working"
          issue["last_agent_id"] = agent.fetch("id")
          issue["last_routing_action"] = spawn_routing_action(follow_up_of_id, replaces_id)
          issue["last_routed_at"] = now
          issue["updated_at"] = now
          project["status"] = "working"
          project["updated_at"] = now

          log_message = spawn_worker_log_message(agent, issue)
          log_ids = repointed_dependents.fetch("log_entry_ids").dup
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: reservation.fetch("agent_id"),
            level: "info",
            message: log_message,
            details: {
              "issue_id" => issue.fetch("id"),
              "project_id" => project.fetch("id"),
              "agent_id" => agent.fetch("id"),
              "routing_action" => spawn_routing_action(follow_up_of_id, replaces_id),
              "follow_up_of_agent_id" => follow_up_of_id,
              "replaces_agent_id" => replaces_id,
              "after_agent_id" => after_agent_value,
              "workspace_path" => agent.fetch("workspace_path"),
              "workspace_strategy" => agent.fetch("workspace_strategy"),
              "workspace_branch" => agent.fetch("workspace_branch"),
              "workspace_mode" => agent.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED),
              "effective_workspace_mode" => agent.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED),
              "workspace_mode_fallback_reason" => agent.fetch("workspace_mode_fallback_reason", nil),
              "requested_worktree_provider" => workspace.dig("plan", "requested_worktree_provider"),
              "worktree_provider" => workspace.dig("plan", "worktree_provider"),
              "worktree_provider_fallback_reason" => workspace.dig("plan", "worktree_provider_fallback_reason"),
              "title" => agent.fetch("harness_metadata", {}).fetch("title", nil),
              "rerouted_from_issue_id" => rerouted_from_issue_id,
              "workspace_reuse" => workspace_reuse,
              "session_settings" => agent.fetch("session_settings", nil),
              "repointed_deferred_agent_ids" => repointed_dependents.fetch("agent_ids").empty? ? nil : repointed_dependents.fetch("agent_ids")
            }.compact
          ))
          log_ids.concat(append_session_model_substitution_log(state, agent))
          # Whether a worker got its own worktree or continued in someone else's is exactly the kind
          # of thing a user should never have to infer from a branch name.
          log_ids.concat(append_workspace_reuse_log(state, agent, workspace_reuse))
          touch_state!(state, now)
          store.save(state)

          accepted_result(command_id, command_type, reservation.fetch("agent_id"), log_message, agent, log_ids)
        end
      rescue StandardError => e
        kill_session_safely(session_ref) if session_ref
        cleanup_worker_workspace_safely(reservation.fetch("workspace")) if defined?(reservation) && reservation && reservation["workspace"]
        if defined?(reservation) && reservation
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Worker #{reservation.fetch("agent_id")} failed during provisioning: #{e.message}",
            errors: [e.class.name, e.message],
            workspace: reservation.fetch("workspace", {})
          )
        end
        raise e
      end

      def worker_provisioning_in_progress?(agent)
        state = (agent.fetch("harness_metadata", {}) || {}).fetch("provisioning_state", nil)
        %w[provisioning_queued allocating_workspace starting_harness].include?(state.to_s)
      end

      # What GetInfo says about a worker that is being provisioned, is waiting for a retry, or
      # gave up: what happened, how many attempts it has had, and what the user can do next.
      def worker_provisioning_info(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        state = metadata.fetch("provisioning_state", nil).to_s
        return nil if state.empty? || state == "ready"

        errors = Array(metadata.fetch("provisioning_errors", []))
        resumable = worker_awaiting_provisioning_retry?(agent)
        {
          "state" => state,
          "attempts" => metadata.fetch("provisioning_attempts", nil),
          "attempt_limit" => PROVISIONING_ATTEMPT_LIMIT,
          "failed_at" => metadata.fetch("provisioning_failed_at", nil),
          "errors" => errors.empty? ? nil : errors,
          "progress" => metadata.fetch("provisioning_progress", nil),
          "workspace_branch" => agent.fetch("workspace_branch", nil),
          "resumable" => resumable,
          "next_step" => provisioning_next_step(state, metadata, agent, resumable)
        }.compact
      end

      def provisioning_next_step(state, metadata, agent, resumable)
        recorded = present_string(metadata.fetch("provisioning_next_step", nil))
        case state
        when "provisioning_queued" then recorded || "Waiting for an available worker-provisioning slot."
        when "allocating_workspace" then recorded || "Provisioning this worker's workspace; it starts once the checkout finishes."
        when "retry_pending" then recorded || "Meringue is retrying provisioning automatically."
        else
          return recorded unless resumable

          "Prompt #{agent.fetch("id")} to retry workspace provisioning, or kill it."
        end
      end

      def mark_worker_provisioning_attempt!(agent, now)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return unless PROVISIONING_RESUMABLE_STATES.include?(metadata.fetch("provisioning_state", nil).to_s)

        agent["status"] = "queued"
        agent["updated_at"] = now
        agent["harness_metadata"] = metadata.merge(
          "provisioning_state" => "allocating_workspace",
          "provisioning_attempt_started_at" => now
        )
      end

      # A worker whose workspace never got provisioned: the reservation, prompt, and issue are all
      # intact, there is no session to prompt, and provisioning can simply be run again.
      def worker_awaiting_provisioning_retry?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false if agent.fetch("status", nil) == "killed"
        return false if agent_has_session_reference?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        return false unless PROVISIONING_RESUMABLE_STATES.include?(metadata.fetch("provisioning_state", nil).to_s)

        !blank?(metadata.fetch("spawn_prompt", nil))
      end

      # Re-queues a worker whose provisioning failed, with the user's latest instruction as its
      # spawn prompt. Reconciliation owns the actual retry (`recover_worker_reservations`), so
      # this never runs a multi-minute checkout inside a kernel command.
      def requeue_worker_provisioning(state, command_id, command_type, agent, prompt)
        now = timestamp
        metadata = agent.fetch("harness_metadata", {}) || {}
        agent["status"] = "queued"
        agent["updated_at"] = now
        agent["harness_metadata"] = metadata.merge(
          "spawn_prompt" => prompt.to_s,
          "provisioning_state" => "retry_pending",
          # An explicit ask resets the automatic budget: the user decided this is worth retrying.
          "provisioning_attempts" => 0,
          "provisioning_retry_requested_at" => now,
          "provisioning_next_step" => nil,
          **instance_ownership_metadata
        ).compact
        refresh_worker_parent_statuses!(state, agent, now)
        agent_id = agent.fetch("id")
        message = "Retrying workspace provisioning for worker #{agent_id}; it starts as soon as its workspace is ready."
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "info",
          message: message,
          details: {
            "agent_id" => agent_id,
            "issue_id" => agent.fetch("issue_id", nil),
            "previous_provisioning_errors" => Array(metadata.fetch("provisioning_errors", []))
          }.compact
        )
        touch_state!(state, now)
        store.save(state)
        accepted_result(command_id, command_type, agent_id, message, deep_copy(agent), log_ids)
      end

      # Only an unstarted reservation on the named issue may be re-provisioned through
      # `_reservation_agent_id`; anything else would let a payload point provisioning at a
      # worker that is already running.
      def reserved_worker_for_retry(state, agent_id, issue)
        return nil unless agent_id

        agent = find_agent(state, agent_id)
        return nil unless agent && agent.fetch("type", nil) == "worker"
        return nil unless agent.fetch("issue_id", nil) == issue.fetch("id")
        return nil if agent_has_session_reference?(agent)

        agent
      end

      def worker_for_spawn_command(state, command_id)
        return nil if blank?(command_id)

        state.fetch("agents").find do |agent|
          agent.fetch("type", nil) == "worker" &&
            (agent.fetch("harness_metadata", {}) || {}).fetch("spawn_command_id", nil).to_s == command_id.to_s
        end
      end

      # --- Completion-triggered head continuations ----------------------------------------------
      #
      # A worker can carry a small continuation record telling the kernel to spawn a fresh head once
      # that worker completes. The continuation lives on the worker record, is claimed before the
      # head is spawned, and is also resolved from reconciliation so it survives restarts without a
      # sleeping worker session.
      # `share_workspace`: true asks for the continuation default explicitly, false opts a
      # continuation step out of it, and nil leaves the default in place.
      def normalized_share_workspace(payload, errors:)
        raw = value_at(payload, *SHARE_WORKSPACE_KEYS)
        return nil if raw.nil? || blank?(raw)
        return raw if [true, false].include?(raw)

        value = raw.to_s.strip.downcase
        return true if %w[true yes on 1].include?(value)
        return false if %w[false no off 0].include?(value)

        errors << "invalid_share_workspace"
        nil
      end

      def normalized_completion_continuation(payload, errors:)
        raw = value_at(payload, *COMPLETION_CONTINUATION_KEYS)
        return nil if raw.nil? || raw == false

        record = case raw
                 when String
                   { "prompt" => raw }
                 when Hash
                   raw.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
                 else
                   errors << "completion_continuation must be a string prompt or object"
                   return nil
                 end
        prompt = present_string(value_at(record, *COMPLETION_CONTINUATION_PROMPT_KEYS))
        unless prompt
          errors << "completion_continuation.prompt is required"
          return nil
        end

        include_result = value_at(record, "include_worker_result", "IncludeWorkerResult", "includeWorkerResult")
        gate_plan = deferred_gate_plan(record)
        errors.concat(gate_plan.fetch("errors", []))
        {
          "prompt" => prompt,
          "include_worker_result" => include_result.nil? ? true : truthy?(include_result),
          # The same persisted, bounded predicate used by queued workers can hold the continuation
          # itself. It is stored disarmed and only begins consuming its wait budget after the worker
          # completes, so worker runtime never counts against an external review/deploy deadline.
          "command_gate" => gate_plan.fetch("gate", nil)
        }.compact
      end

      def completion_continuation_record(continuation, now:, spawn_command_id: nil)
        return nil unless continuation.is_a?(Hash)

        {
          "state" => COMPLETION_CONTINUATION_STATE_WAITING,
          "prompt" => continuation.fetch("prompt"),
          "include_worker_result" => continuation.fetch("include_worker_result", true),
          "command_gate" => continuation.fetch("command_gate", nil),
          "created_at" => now,
          "spawn_command_id" => present_string(spawn_command_id)
        }.compact
      end

      def worker_completion_continuation(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        continuation = metadata.fetch("completion_continuation", nil)
        continuation.is_a?(Hash) ? continuation : nil
      end

      def pending_completion_continuation?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "completed"

        state = worker_completion_continuation(agent)&.fetch("state", nil).to_s
        [COMPLETION_CONTINUATION_STATE_WAITING, COMPLETION_CONTINUATION_STATE_TRIGGERING].include?(state)
      end
    end
  end
end
