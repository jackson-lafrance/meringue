# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Allocating the worktree a worker launches into, reporting provisioning progress, and the
      # prompts and log lines that describe the result.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Allocation is not the final authority: another process can change Git registration or a
      # stale state record can reveal a second live owner after checkout. Revalidate immediately
      # before harness launch and, for kernel-managed workspaces, exclude the unusable candidate and
      # provision a fresh one. Explicit caller paths are never silently overridden.
      def ensure_launchable_worker_workspace(workspace, reservation:, requested_workspace_path:, task_title:,
                                             workspace_mode: WORKSPACE_MODE_ISOLATED, harness_provider: nil)
        return workspace if workspace.fetch("errors", []).any?

        unavailable = []
        failures = []
        3.times do
          validation = validate_worker_workspace_for_launch(workspace, reservation.fetch("agent_id"))
          occupants = launch_workspace_occupants(reservation.fetch("agent_id"), workspace)
          if validation.fetch("usable", false) && occupants.empty?
            if failures.any?
              reallocation = {
                "reallocated" => true,
                "reallocation_reasons" => failures,
                "unavailable_workspace_paths" => unavailable.dup
              }
              plan = workspace.fetch("plan", nil)
              workspace = workspace.merge(reallocation)
              workspace["plan"] = plan.merge(reallocation) if plan.is_a?(Hash)
            end
            return workspace
          end

          reason = occupants.empty? ? validation.fetch("reason", "workspace_unusable") : "workspace_owned_by_another_worker"
          details = occupants.empty? ? validation : { "occupant_agent_ids" => occupants }
          failures << reason
          if workspace.fetch("effective_workspace_mode", nil) == WORKSPACE_MODE_SHARED_READ_ONLY
            # A checkout can disappear or move branches between discovery and launch. Never try a
            # different shared checkout implicitly: fall back to the ordinary isolated allocator.
            workspace = resolve_worker_workspace(
              project: reservation.fetch("project"),
              issue: reservation.fetch("issue"),
              requested_workspace_path: nil,
              preview_agent_id: reservation.fetch("agent_id"),
              task_title: task_title,
              create: true,
              progress_agent_id: reservation.fetch("agent_id"),
              workspace_mode: WORKSPACE_MODE_ISOLATED,
              harness_provider: harness_provider
            ).merge(
              "workspace_mode" => workspace_mode,
              "effective_workspace_mode" => WORKSPACE_MODE_ISOLATED,
              "workspace_mode_fallback_reason" => reason,
              "note" => "Shared read-only checkout became unavailable (#{reason}); allocated an isolated workspace."
            )
            return workspace if workspace.fetch("errors", []).any?
            next
          end
          root = workspace_worktree_root_path(workspace) || workspace.fetch("workspace_path", nil)
          unavailable << root if present_string(root)
          break if present_string(requested_workspace_path)

          workspace = resolve_worker_workspace(
            project: reservation.fetch("project"),
            issue: reservation.fetch("issue"),
            requested_workspace_path: nil,
            preview_agent_id: reservation.fetch("agent_id"),
            task_title: task_title,
            create: true,
            progress_agent_id: reservation.fetch("agent_id"),
            unavailable_paths: unavailable,
            workspace_mode: WORKSPACE_MODE_ISOLATED,
            harness_provider: harness_provider
          )
          return workspace if workspace.fetch("errors", []).any?
          workspace["last_workspace_validation"] = details
        end

        workspace.merge(
          "created" => false,
          "errors" => ["worker workspace is not safe to launch: #{failures.uniq.join(", ")}"],
          "failure_kind" => "workspace_validation_failed",
          "recovery" => Meringue::Workspace::Manager::RECOVERY_RETRY,
          "reallocation_reasons" => failures,
          "unavailable_workspace_paths" => unavailable
        )
      end

      def validate_worker_workspace_for_launch(workspace, agent_id)
        return { "usable" => Dir.exist?(workspace.fetch("workspace_path", "")), "reason" => "basic_directory_check" } unless
          workspace_manager.respond_to?(:validate_worker_workspace)

        backend_id = workspace.fetch("version_control_backend", nil)
        if backend_id && @version_control_backend.respond_to?(:id) && @version_control_backend.id.to_s == backend_id.to_s
          return @version_control_backend.validate_workspace(workspace: workspace, worker_id: agent_id)
        end
        workspace_manager.validate_worker_workspace(workspace, agent_id: agent_id)
      rescue StandardError => e
        { "usable" => false, "reason" => "workspace_validation_error", "error" => sanitized_error_message(e) }
      end

      def launch_workspace_occupants(agent_id, workspace)
        return [] unless workspace.fetch("workspace_strategy", workspace.fetch("strategy", nil)) == "git_worktree"

        root = workspace_worktree_root_path(workspace)
        return [] unless present_string(root)

        synchronized_state do
          state = normalized_state
          workspace_occupant_agent_ids(state, root, excluding: [agent_id])
        end
      end

      def resolve_worker_workspace(project:, issue:, requested_workspace_path:, preview_agent_id:, task_title:, create: false,
                                   progress_agent_id: nil, unavailable_paths: [], workspace_mode: WORKSPACE_MODE_ISOLATED,
                                   harness_provider: nil)
        requested_mode = WORKSPACE_MODES.include?(workspace_mode.to_s) ? workspace_mode.to_s : WORKSPACE_MODE_ISOLATED
        fallback_reason = nil
        if requested_mode == WORKSPACE_MODE_SHARED_READ_ONLY
          provider = harness_provider || active_harness_provider(normalized_state)
          client = active_harness_client(provider: provider)
          if client.respond_to?(:read_only_workspace_supported?) && client.read_only_workspace_supported?
            shared = if workspace_manager.respond_to?(:shared_read_only_checkout)
                       workspace_manager.shared_read_only_checkout(project_root: project.fetch("root_path"))
                     else
                       { "usable" => false, "reason" => "workspace_manager_does_not_support_shared_checkouts" }
                     end
            if shared.is_a?(Hash) && ["shared_checkout", "project_root"].include?(shared.fetch("strategy", nil)) && shared.fetch("errors", []).empty?
              note = if shared.fetch("strategy") == "project_root"
                       "Project is not a Git repository; harness tools are restricted to read-only access in the project directory."
                     else
                       "Validated shared main checkout; harness tools are restricted to read-only access."
                     end
              return shared.merge(
                "workspace_strategy" => shared.fetch("strategy"),
                "workspace_mode" => requested_mode,
                "effective_workspace_mode" => WORKSPACE_MODE_SHARED_READ_ONLY,
                "plan" => shared,
                "note" => note
              )
            end
            fallback_reason = shared.is_a?(Hash) ? shared.fetch("reason", "shared_checkout_unavailable") : "shared_checkout_unavailable"
          else
            fallback_reason = "harness_does_not_enforce_read_only_workspaces"
          end
        end

        isolated = resolve_isolated_worker_workspace(
          project: project,
          issue: issue,
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: preview_agent_id,
          task_title: task_title,
          create: create,
          progress_agent_id: progress_agent_id,
          unavailable_paths: unavailable_paths
        )
        isolated.merge(
          "version_control_backend" => project.fetch("version_control_backend", nil),
          "workspace_mode" => requested_mode,
          "effective_workspace_mode" => WORKSPACE_MODE_ISOLATED,
          "workspace_mode_fallback_reason" => fallback_reason,
          "note" => fallback_reason ? "Shared read-only checkout unavailable (#{fallback_reason}); allocated an isolated workspace." : isolated.fetch("note", nil)
        )
      end

      def resolve_isolated_worker_workspace(project:, issue:, requested_workspace_path:, preview_agent_id:, task_title:, create: false,
                                             progress_agent_id: nil, unavailable_paths: [])
        capabilities = project.fetch("version_control_capabilities", {})
        unless capabilities["isolated_workspaces"] == true
          return {
            "workspace_path" => nil, "workspace_strategy" => "unavailable", "workspace_branch" => nil,
            "plan" => nil, "created" => false,
            "errors" => ["version_control_backend_unavailable"],
            "failure_kind" => "version_control_backend_unavailable",
            "note" => "This project cannot provision an isolated mutable workspace (its directory is not a usable Git repository with a base ref). Spawn a shared_read_only worker to investigate, or register a Git repository for implementation work."
          }
        end

        if present_string(requested_workspace_path)
          return {
            "workspace_path" => File.expand_path(requested_workspace_path.to_s),
            "workspace_strategy" => "unvalidated",
            "workspace_branch" => nil,
            "plan" => nil,
            "note" => "Explicit mutable workspace paths must be provisioned by a version-control backend.",
            "errors" => ["version_control_backend_required"]
          }
        end

        plan = if create
                 allocate_worker_workspace_with_progress(
                   project_root: project.fetch("root_path"),
                   project_id: project.fetch("id"),
                   issue_id: issue.fetch("id"),
                   agent_id: preview_agent_id,
                   task_title: task_title,
                   progress_agent_id: progress_agent_id,
                   unavailable_paths: unavailable_paths
                 )
               else
                 workspace_manager.plan_worker_workspace(
                   project_root: project.fetch("root_path"),
                   project_id: project.fetch("id"),
                   issue_id: issue.fetch("id"),
                   agent_id: preview_agent_id,
                   task_title: task_title
                 ).merge("errors" => [])
               end

        if plan.fetch("errors", []).any?
          return {
            "workspace_path" => File.expand_path(project.fetch("root_path")),
            "workspace_strategy" => plan.fetch("strategy", "git_worktree"),
            "workspace_branch" => plan.fetch("workspace_branch", nil),
            "plan" => plan,
            "note" => nil,
            "created" => plan.fetch("created", false),
            "errors" => plan.fetch("errors"),
            # How the manager classified the failure. The kernel turns this into the worker's
            # degraded state instead of guessing from the error text.
            "recovery" => plan.fetch("recovery", nil),
            "failure_kind" => plan.fetch("failure_kind", nil),
            "cleanup" => plan.fetch("cleanup", nil)
          }
        end

        # A reservation is a preview: it names the isolated worktree the backend will
        # create, and the workspace itself is provisioned later under that reservation.
        # Nothing is on disk yet, so `created` is false — which is not a failure, and is
        # the difference between planning a worktree and failing to provision one. Losing
        # this return is what made every SpawnWorker reservation report "Worker workspace
        # is invalid", because a preview fell through to the provisioning failure below.
        if !create && plan.fetch("strategy", nil) == "git_worktree" && present_string(plan.fetch("workspace_path", nil))
          return {
            "workspace_path" => File.expand_path(plan.fetch("workspace_path")),
            "workspace_strategy" => "git_worktree",
            "workspace_branch" => plan.fetch("workspace_branch", nil),
            "plan" => plan,
            "note" => "Version-control backend planned an isolated workspace for this worker.",
            "created" => false,
            "errors" => []
          }
        end

        if create && plan.fetch("created", false) && Dir.exist?(plan.fetch("workspace_path"))
          provider_note = if present_string(plan.fetch("worktree_provider_fallback_reason", nil))
                            "Requested #{plan.fetch("requested_worktree_provider", "external")} worktree provider was unavailable; " \
                              "used native Git (#{plan.fetch("worktree_provider_fallback_reason")})."
                          elsif plan.fetch("worktree_provider", "native_git") != "native_git"
                            "Provisioned and managed by the configured command provider with Git safety validation."
                          end
          return {
            "workspace_path" => File.expand_path(plan.fetch("workspace_path")),
            "workspace_strategy" => plan.fetch("strategy"),
            "workspace_branch" => plan.fetch("workspace_branch"),
            "plan" => plan,
            "note" => provider_note,
            "created" => true,
            "errors" => []
          }
        end

        {
          "workspace_path" => nil,
          "workspace_strategy" => plan.fetch("strategy", "git_worktree"),
          "workspace_branch" => plan.fetch("workspace_branch", nil),
          "plan" => plan,
          "note" => "Version-control backend did not provision an isolated workspace.",
          "created" => false,
          "errors" => ["isolated_workspace_not_provisioned"],
          "failure_kind" => "version_control_backend_unavailable"
        }
      end

      # Provisioning a monorepo worktree is minutes of honest work. It runs off the render thread
      # and holds no state lock, but a user watching a queued worker still deserves to know the
      # difference between "checking out 478k files" and "wedged", so a long allocation reports
      # progress into the worker record and the log instead of going silent.
      def allocate_worker_workspace_with_progress(project_root:, project_id:, issue_id:, agent_id:, task_title:, progress_agent_id:,
                                                  unavailable_paths: [])
        arguments = {
          project_root: project_root,
          project_id: project_id,
          issue_id: issue_id,
          agent_id: agent_id,
          task_title: task_title
        }
        if workspace_manager.method(:allocate_worker_workspace).parameters.any? { |(_kind, name)| name == :unavailable_paths }
          arguments[:unavailable_paths] = unavailable_paths
        end
        return workspace_manager.allocate_worker_workspace(**arguments) unless progress_agent_id
        unless workspace_manager.method(:allocate_worker_workspace).parameters.any? { |(_kind, name)| name == :progress }
          # A workspace manager double (or an older implementation) may not accept `progress`.
          # Provisioning must never fail because progress reporting is unavailable.
          return workspace_manager.allocate_worker_workspace(**arguments)
        end

        workspace_manager.allocate_worker_workspace(
          **arguments,
          progress: worker_provisioning_progress_reporter(progress_agent_id)
        )
      end

      def worker_provisioning_progress_reporter(agent_id)
        last_updated = nil
        last_logged = 0.0
        lambda do |progress|
          elapsed = progress.fetch("elapsed", 0).to_f
          next if last_updated && elapsed - last_updated < PROVISIONING_PROGRESS_UPDATE_INTERVAL_SECONDS

          last_updated = elapsed
          announce = elapsed - last_logged >= PROVISIONING_PROGRESS_INTERVAL_SECONDS
          last_logged = elapsed if announce
          record_worker_provisioning_progress(agent_id, progress, log: announce)
        end
      end

      # Progress is telemetry about the worktree checkout, not a percentage for the whole worker
      # lifecycle. Git's percentage is the only honest percentage available; before Git reports one,
      # the AgentTree uses the checkout phase and elapsed time instead of inventing a 0% baseline.
      def record_worker_provisioning_progress(agent_id, progress, log: true)
        detail = present_string(progress.fetch("detail", nil))
        elapsed = progress.fetch("elapsed", 0).to_f
        command = present_string(progress.fetch("command", nil)) || "workspace provisioning"
        phase = provisioning_progress_phase(command)
        percent = provisioning_progress_percent(detail)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next unless agent

          now = timestamp
          metadata = agent.fetch("harness_metadata", {}) || {}
          replacement_key = present_string(metadata.fetch("provisioning_progress_log_replacement_key", nil)) ||
                            "#{PROVISIONING_PROGRESS_LOG_REPLACEMENT_KIND}:#{SecureRandom.uuid}"
          agent["harness_metadata"] = metadata.merge(
            "provisioning_progress_log_replacement_key" => replacement_key,
            "provisioning_progress" => {
              "command" => command,
              "phase" => phase,
              "percent" => percent,
              "elapsed_seconds" => progress.fetch("elapsed", nil),
              "quiet_for_seconds" => progress.fetch("quiet_for", nil),
              "detail" => detail,
              "observed_at" => now
            }.compact
          )
          agent["updated_at"] = now
          if log
            append_log(
              state,
              source_type: "kernel",
              source_id: agent_id,
              level: "info",
              message: "Still provisioning worker #{agent_id}: #{command} has been running for " \
                       "#{elapsed.round}s#{detail ? " (#{detail})" : ""}.",
              details: {
                "kind" => "workspace_provisioning_progress",
                "agent_id" => agent_id,
                "phase" => phase,
                "percent" => percent,
                "elapsed_seconds" => progress.fetch("elapsed", nil),
                "detail" => detail
              }.compact,
              replacement_key: replacement_key
            )
          end
          touch_state!(state, now)
          store.save(state)
        end
      rescue StandardError
        nil
      end

      def provisioning_progress_phase(command)
        command.to_s.match?(/worktree\s+add/i) ? "checkout" : "workspace setup"
      end

      def provisioning_progress_percent(detail)
        match = detail.to_s.match(/(?:\A|\s)(\d{1,3})%(?:\s|\z)/)
        return nil unless match

        match[1].to_i.clamp(0, 100)
      end

      def cleanup_worker_workspace_safely(workspace)
        workspace_manager.release_worker_workspace(workspace, delete_branch: true)
      rescue StandardError
        false
      end

      def normalized_workspace_mode(value, errors:)
        raw = present_string(value)
        return WORKSPACE_MODE_ISOLATED unless raw

        mode = raw.downcase
        unless WORKSPACE_MODES.include?(mode)
          errors << "workspace_mode must be one of: #{WORKSPACE_MODES.join(", ")}"
          return WORKSPACE_MODE_ISOLATED
        end
        mode
      end

      def persisted_worker_workspace_mode(agent, fallback: WORKSPACE_MODE_ISOLATED)
        mode = present_string(agent.fetch("workspace_mode", nil)) ||
               present_string((agent.fetch("harness_metadata", {}) || {}).fetch("workspace_mode", nil)) || fallback
        WORKSPACE_MODES.include?(mode) ? mode : WORKSPACE_MODE_ISOLATED
      end

      def worker_system_prompt(issue, workspace_mode: WORKSPACE_MODE_ISOLATED)
        base_prompt = workspace_mode == WORKSPACE_MODE_SHARED_READ_ONLY ? READ_ONLY_WORKER_SYSTEM_PROMPT : WORKER_SYSTEM_PROMPT
        <<~PROMPT
          #{base_prompt}

          Product task title for delivery artifacts:
          #{DeliveryArtifactPolicy.human_title(issue.fetch("title"))}

          Assigned task:
          #{issue.fetch("title")}

          Task description:
          #{issue.fetch("description")}
        PROMPT
      end

      def worker_session_name(issue, worker_title: nil)
        title = human_delivery_title(worker_display_title(worker_title, issue))
        title = "Task" if title.empty?
        title[0, 96]
      end

      def human_delivery_title(value)
        DeliveryArtifactPolicy.human_title(value)
      end

      def worker_display_title(worker_title, issue)
        title = present_string(worker_title)
        title || issue.fetch("title").to_s.strip
      end

      def prompt_routing_action(mode)
        {
          "normal" => "resume_session",
          "steer" => "steer_active_session",
          "follow_up" => "queue_follow_up"
        }.fetch(mode.to_s)
      end

      # `requested_mode` is only present when the harness had to deliver the prompt in another mode;
      # the coercion is stated in the same user-visible line so a queued delivery is never silent.
      def prompt_log_message(agent, mode, requested_mode: nil, note: nil)
        base = case mode.to_s
               when "steer"
                 "Steered active worker #{agent.fetch("id")} on #{agent.fetch("issue_id")} with the user's correction."
               when "follow_up"
                 "Queued a follow-up for worker #{agent.fetch("id")} on #{agent.fetch("issue_id")}."
               else
                 "Continued worker #{agent.fetch("id")} on #{agent.fetch("issue_id")} using its existing session."
               end
        return base unless present_string(requested_mode) && requested_mode.to_s != mode.to_s

        explanation = present_string(note) ||
                      "The session could not take a #{requested_mode} prompt right now."
        "#{base} Requested #{requested_mode}, delivered #{mode}: #{explanation}"
      end

      def replaceable_worker?(agent)
        agent && agent.fetch("status", nil) != "killed" && blank?(agent.fetch("replaced_by_agent_id", nil))
      end

      def deferred_started_because(deferred)
        after_agent_id = present_string(deferred.fetch("after_agent_id", nil))
        gate = deferred_command_gate(deferred)
        reasons = []
        reasons << "#{after_agent_id} settled (#{deferred.fetch("predecessor_status", "completed")})" if after_agent_id
        reasons << deferred_gate_activation_reason(gate) if gate
        return "its predecessor settled (#{deferred.fetch("predecessor_status", "completed")})" if reasons.empty?

        reasons.join(" and ")
      end

      def spawn_routing_action(follow_up_of_agent_id, replaces_agent_id)
        return "replace_worker" if present_string(replaces_agent_id)
        return "spawn_follow_up_worker" if present_string(follow_up_of_agent_id)

        "spawn_worker"
      end

      def spawn_worker_log_message(agent, issue)
        deferred = deferred_spawn_metadata(agent)
        base = if deferred.fetch("state", nil) == DEFERRED_STATE_ACTIVATED
                 "Started queued worker #{agent.fetch("id")} on #{issue.fetch("id")} because " \
                   "#{deferred_started_because(deferred)}."
               elsif present_string(agent.fetch("replaces_agent_id", nil))
                 "Replaced worker #{agent.fetch("replaces_agent_id")} with #{agent.fetch("id")} on #{issue.fetch("id")}."
               elsif present_string(agent.fetch("follow_up_of_agent_id", nil))
                 "Spawned follow-up worker #{agent.fetch("id")} after #{agent.fetch("follow_up_of_agent_id")} on #{issue.fetch("id")}."
               else
                 "Spawned worker #{agent.fetch("id")} for #{issue.fetch("id")}."
               end
        if agent.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED) == WORKSPACE_MODE_SHARED_READ_ONLY
          fallback = present_string(agent.fetch("workspace_mode_fallback_reason", nil))
          base = if agent.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED) == WORKSPACE_MODE_SHARED_READ_ONLY
                   "#{base} Using a validated shared read-only checkout."
                 else
                   "#{base} Shared read-only checkout unavailable#{fallback ? " (#{fallback})" : ""}; using an isolated workspace."
                 end
        end
        rerouted_from = present_string((agent.fetch("harness_metadata", {}) || {}).fetch("rerouted_from_issue_id", nil))
        return base unless rerouted_from

        "#{base} Rerouted from predicted issue #{rerouted_from}."
      end
    end
  end
end
