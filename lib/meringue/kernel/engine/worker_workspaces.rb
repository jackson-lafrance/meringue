# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Where a worker's session runs: reserving and checkpointing a workspace, sharing or
      # inheriting a predecessor's worktree, and building the agent records that reference it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def build_worker_reservation(agent_id:, issue:, project:, workspace:, provider:, command_id:, prompt:, title:,
                                   requested_workspace_path:, follow_up_of_agent_id:, replace_agent_id:, now:, harness_generation:,
                                   after_agent_id: nil, completion_continuation: nil, workspace_reuse_request: nil,
                                   session_settings_override: {}, model_validation: nil,
                                   workspace_mode: WORKSPACE_MODE_ISOLATED, portable_import: nil,
                                   self_fixing_recovery: nil)
        plan = workspace.fetch("plan", nil) || workspace
        {
          "id" => agent_id,
          "type" => "worker",
          "status" => "queued",
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "after_agent_id" => present_string(after_agent_id),
          "workspace_path" => plan.fetch("workspace_path", workspace.fetch("workspace_path", nil)),
          "workspace_strategy" => plan.fetch("strategy", workspace.fetch("workspace_strategy", nil)),
          "workspace_branch" => plan.fetch("workspace_branch", workspace.fetch("workspace_branch", nil)),
          "workspace_mode" => workspace_mode,
          "effective_workspace_mode" => workspace.fetch("effective_workspace_mode", nil),
          "workspace_mode_fallback_reason" => workspace.fetch("workspace_mode_fallback_reason", nil),
          "harness" => provider,
          "pid" => nil,
          "harness_session_id" => nil,
          "harness_session_file" => nil,
          # A reservation has no effective session settings yet. Explicit spawn
          # intent is persisted below and becomes session_settings only after
          # the harness reports the launched session's effective values.
          "session_settings" => nil,
          "harness_metadata" => {
            "title" => worker_display_title(title, issue),
            "spawn_command_id" => command_id,
            "spawn_prompt" => prompt.to_s,
            "spawn_session_settings" => session_settings_override.empty? ? nil : deep_copy(session_settings_override),
            "model_validation" => model_validation,
            "requested_workspace_path" => present_string(requested_workspace_path),
            "workspace_mode" => workspace_mode,
            "follow_up_of_agent_id" => present_string(follow_up_of_agent_id),
            "replace_agent_id" => present_string(replace_agent_id),
            "completion_continuation" => completion_continuation_record(completion_continuation, now: now, spawn_command_id: command_id),
            "provisioning_state" => "allocating_workspace",
            "workspace_reuse_request" => workspace_reuse_request,
            "portable_import" => portable_import,
            "self_fixing_recovery" => self_fixing_recovery,
            "workspace_plan" => plan,
            "harness_generation" => harness_generation,
            **instance_ownership_metadata,
            "is_streaming" => false
          }.compact,
          "created_at" => now,
          "updated_at" => now
        }
      end

      # --- Shared worker workspaces -------------------------------------------------------------
      #
      # A successor that continues a predecessor's line of work on the same issue works in the
      # predecessor's own worktree and branch instead of getting a fresh worktree on a suffixed
      # branch. That is what makes "one worker investigates, the next implements" leave one branch
      # and one pull request behind, and what lets a successor see work the predecessor never
      # committed.
      #
      # Reuse is decided in two halves, on purpose:
      #
      #   claim_reused_worker_workspace   runs under the state lock, answers the questions only
      #                                   Meringue state can answer (is this really the same line
      #                                   of work, is any worker that could still write to that
      #                                   checkout alive, has that branch already been delivered),
      #                                   and *writes* the shared path onto the reservation. The
      #                                   write is the claim: a second successor spawned at the
      #                                   same moment then sees a live occupant and gets its own
      #                                   worktree.
      #   verify_reused_worker_workspace  runs outside the lock because it shells out to git, and
      #                                   answers whether the worktree is still registered, still
      #                                   on that branch, and unlocked.
      #
      # Any refusal falls back to fresh provisioning with a log line, except for a session restart,
      # which exists only to take over the dead worker's checkout and therefore fails loudly.

      # Which predecessor's workspace this spawn may continue in, and why. nil means "provision a
      # fresh worktree".
      def workspace_reuse_request(share_workspace:, reuse_agent_id:, inherit_agent_id:, follow_up_of_agent_id:,
                                  replace_agent_id:, after_agent_id:, requested_workspace_path:)
        # An explicitly requested path is the caller's own workspace choice; nothing to share.
        return nil if present_string(requested_workspace_path)
        if present_string(inherit_agent_id)
          return { "source" => WORKSPACE_REUSE_SOURCE_SESSION_RESTART, "agent_id" => present_string(inherit_agent_id) }
        end
        return nil if share_workspace == false
        if present_string(reuse_agent_id)
          return { "source" => WORKSPACE_REUSE_SOURCE_EXPLICIT, "agent_id" => present_string(reuse_agent_id) }
        end

        # The continuation default, in priority order. `after_agent_id` first because a queued
        # worker's predecessor is guaranteed settled, which is the case reuse is safest in.
        candidate = present_string(after_agent_id) || present_string(follow_up_of_agent_id) || present_string(replace_agent_id)
        return nil unless candidate

        { "source" => WORKSPACE_REUSE_SOURCE_CONTINUATION, "agent_id" => candidate }
      end

      # The reuse request for a reservation that already exists (a queued worker activating, a
      # provisioning retry, a reconciliation restart). The persisted request is the durable intent;
      # a continuation still re-reads the predecessor from the live record, because a replacement
      # can have repointed the chain since the worker was queued.
      def persisted_workspace_reuse_request(agent, share_workspace:, reuse_agent_id:, inherit_agent_id:,
                                            follow_up_of_agent_id:, replace_agent_id:, after_agent_id:,
                                            requested_workspace_path:)
        metadata = agent.fetch("harness_metadata", {}) || {}
        persisted = metadata.fetch("workspace_reuse_request", nil)
        persisted = nil unless persisted.is_a?(Hash)
        recorded_inherit = present_string(metadata.fetch("inherit_workspace_from_agent_id", nil))
        if persisted && persisted.fetch("source", nil) != WORKSPACE_REUSE_SOURCE_CONTINUATION
          return persisted
        end

        request = workspace_reuse_request(
          share_workspace: persisted ? nil : share_workspace,
          reuse_agent_id: reuse_agent_id,
          inherit_agent_id: recorded_inherit || inherit_agent_id,
          follow_up_of_agent_id: follow_up_of_agent_id,
          replace_agent_id: replace_agent_id,
          after_agent_id: after_agent_id,
          requested_workspace_path: present_string(requested_workspace_path) ||
            present_string(metadata.fetch("requested_workspace_path", nil))
        )
        # A reservation whose plan already carries a shared workspace keeps it even when no
        # relationship field survived, so a retry never abandons a checkout it already took over.
        return request if request
        return nil unless shared_workspace_plan?(metadata.fetch("workspace_plan", nil))

        {
          "source" => (persisted && persisted.fetch("source", nil)) || WORKSPACE_REUSE_SOURCE_CONTINUATION,
          "agent_id" => present_string((metadata.fetch("workspace_plan", {}) || {}).fetch("inherited_from_agent_id", nil))
        }
      end

      # Decides whether this spawn may continue in another worker's worktree, and claims it.
      def claim_reused_worker_workspace(state, request:, requester_id:, issue:, reserved_workspace: nil)
        source = request.fetch("source")
        predecessor_id = present_string(request.fetch("agent_id", nil))
        predecessor = predecessor_id ? find_agent(state, predecessor_id) : nil
        workspace = nil
        if predecessor.is_a?(Hash) && predecessor.fetch("type", nil) == "worker"
          return workspace_reuse_refusal(request, "predecessor_prune_in_progress") if worker_prune_cleanup_claimed?(predecessor)

          unless predecessor.fetch("issue_id", nil) == issue.fetch("id")
            return workspace_reuse_refusal(request, "predecessor_on_another_issue")
          end
          unless predecessor.fetch("workspace_strategy", nil) == "git_worktree"
            # Nothing to share: the predecessor is working in the project root or a caller-supplied
            # directory, and normal resolution already lands this worker in the same place.
            return workspace_reuse_refusal(request, "predecessor_workspace_is_not_a_worktree")
          end

          workspace = shared_worker_workspace(predecessor, source: source)
        elsif shared_workspace_record?(reserved_workspace)
          # The predecessor's record was pruned, but this reservation already carries its shared
          # workspace, so the work is still reachable and the takeover stands.
          workspace = reserved_workspace
        end
        return workspace_reuse_refusal(request, "predecessor_not_found") unless workspace

        branch = present_string(workspace.fetch("workspace_branch", nil))
        root = present_string(workspace_worktree_root_path(workspace))
        path = present_string(workspace.fetch("workspace_path", nil))
        return workspace_reuse_refusal(request, "predecessor_workspace_unknown") unless branch && root && path
        unless Dir.exist?(File.expand_path(path)) && Dir.exist?(File.expand_path(root))
          return workspace_reuse_refusal(request, "workspace_missing", "worktree_root_path" => root)
        end

        # The predecessor is deliberately *not* excluded here: a predecessor that is still working,
        # idle, or blocked can start streaming into that checkout again at any moment, and two live
        # sessions in one worktree is the one outcome this whole path exists to prevent.
        occupants = workspace_occupant_agent_ids(state, root, excluding: [requester_id])
        if occupants.any?
          reason = predecessor_id && occupants.any? { |id| Ids.same?(id, predecessor_id) } ? "predecessor_still_live" : "workspace_in_use"
          return workspace_reuse_refusal(request, reason, "occupant_agent_ids" => occupants, "worktree_root_path" => root)
        end
        if (merged = trusted_delivery_pull_request_for_branch(issue, branch))
          # That branch has already been delivered and merged. Pushing more work onto it would land
          # on a pull request that can never be reopened, so the next step starts from a fresh one.
          return workspace_reuse_refusal(
            request,
            "delivery_branch_already_merged",
            "workspace_branch" => branch,
            "pull_request_url" => State::Models.pull_request_record_url(merged)
          )
        end

        {
          "state" => WORKSPACE_REUSE_STATE_CLAIMED,
          "source" => source,
          "of_agent_id" => predecessor_id,
          "workspace_branch" => branch,
          "workspace_path" => path,
          "worktree_root_path" => root,
          "workspace" => workspace
        }.compact
      end

      def prune_cleanup_claim(operation_id, claimed_at)
        {
          "operation_id" => operation_id,
          "claimed_at" => claimed_at,
          "owner_pid" => instance_pid,
          "owner_host" => kernel_host_name
        }
      end

      def worker_prune_cleanup_claimed?(worker)
        metadata = worker.is_a?(Hash) ? (worker.fetch("harness_metadata", {}) || {}) : {}
        claim = metadata.fetch("prune_cleanup_claim", nil)
        return false unless claim.is_a?(Hash)
        return false if claim.fetch("operation_id", nil) == prune_forge_lookup_context&.fetch("operation_id", nil)

        owner_host = claim.fetch("owner_host", nil).to_s
        owner_pid = claim.fetch("owner_pid", 0).to_i
        return true if owner_host.empty? || owner_host != kernel_host_name

        owner_pid.positive? && owner_process_alive?(owner_pid)
      end

      def workspace_reuse_refusal(request, reason, details = {})
        {
          "state" => WORKSPACE_REUSE_STATE_REFUSED,
          "source" => request.fetch("source"),
          "of_agent_id" => present_string(request.fetch("agent_id", nil)),
          "reason" => reason
        }.merge(details).compact
      end

      # Runs the git half of the safety check for a claimed workspace, outside the state lock.
      def settle_workspace_reuse_claim(reservation)
        reuse = reservation.fetch("workspace_reuse", nil)
        return nil unless reuse.is_a?(Hash)
        return reuse unless reuse.fetch("state", nil) == WORKSPACE_REUSE_STATE_CLAIMED

        inspection = verify_reused_worker_workspace(reuse.fetch("workspace"), project: reservation.fetch("project", nil))
        return reuse.merge("state" => WORKSPACE_REUSE_STATE_REUSED, "verified" => inspection.fetch("reason", nil)) if inspection.fetch("usable", false)

        reuse.reject { |key, _value| key == "workspace" }.merge(
          "state" => WORKSPACE_REUSE_STATE_REFUSED,
          "reason" => inspection.fetch("reason", "worktree_unusable"),
          "checked_out_branch" => inspection.fetch("checked_out_branch", nil),
          "error" => inspection.fetch("error", nil)
        ).compact
      end

      def verify_reused_worker_workspace(workspace, project:)
        # A workspace manager double (or an older implementation) may not answer this question.
        # Reuse must not become unavailable because the inspection is.
        return { "usable" => true, "reason" => "inspection_unavailable" } unless workspace_manager.respond_to?(:inspect_shared_worktree)

        plan = workspace.fetch("plan", nil)
        plan = {} unless plan.is_a?(Hash)
        workspace_manager.inspect_shared_worktree(
          worktree_root: workspace_worktree_root_path(workspace),
          branch: workspace.fetch("workspace_branch", nil),
          git_root: present_string(plan["git_root"]) || (project && project.fetch("root_path", nil))
        )
      rescue StandardError => e
        { "usable" => false, "reason" => "worktree_inspection_error", "error" => sanitized_error_message(e) }
      end

      def reuse_claim_workspace(reuse)
        return nil unless reuse.is_a?(Hash) && reuse.fetch("state", nil) == WORKSPACE_REUSE_STATE_REUSED

        reuse.fetch("workspace", nil)
      end

      def session_restart_workspace_reuse_refused?(reuse)
        reuse.is_a?(Hash) &&
          reuse.fetch("state", nil) == WORKSPACE_REUSE_STATE_REFUSED &&
          reuse.fetch("source", nil) == WORKSPACE_REUSE_SOURCE_SESSION_RESTART
      end

      # Workers that could still write to a worktree. Only a terminal worker is guaranteed not to:
      # an `idle` or `blocked` worker is one prompt or one reconnect away from streaming again, and a
      # `queued` worker has already claimed its path for a spawn that is about to start.
      def workspace_occupant_agent_ids(state, worktree_root, excluding: [])
        excluded = Array(excluding).compact
        state.fetch("agents", []).filter_map do |other|
          next unless other.is_a?(Hash) && other.fetch("type", nil) == "worker"
          next if excluded.any? { |id| Ids.same?(id, other.fetch("id", nil)) }
          next if TERMINAL_AGENT_STATUSES.include?(other.fetch("status", nil).to_s)

          other_root = present_string(worker_worktree_root_path(other))
          next unless other_root && same_workspace_path?(other_root, worktree_root)

          other.fetch("id", nil)
        end.compact
      end

      # The predecessor's workspace, adopted verbatim for a successor that continues its work.
      # `created` is forced to false so no failure path can ever delete a worktree this spawn did
      # not create - the work in it is the only copy.
      def shared_worker_workspace(predecessor, source:)
        workspace_path = present_string(predecessor.fetch("workspace_path", nil))
        return nil unless workspace_path

        metadata = predecessor.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", nil)
        plan = plan.is_a?(Hash) ? deep_copy(plan) : {}
        plan = plan.merge(
          "created" => false,
          "shared" => true,
          "reuse_source" => source,
          # Kept under the original key so records written before workspace sharing existed, and
          # every ownership check that already reads it, keep working unchanged.
          "inherited_from_agent_id" => predecessor.fetch("id"),
          "workspace_path" => workspace_path,
          "strategy" => plan.fetch("strategy", predecessor.fetch("workspace_strategy", nil)),
          "workspace_branch" => predecessor.fetch("workspace_branch", plan.fetch("workspace_branch", nil))
        ).compact
        {
          "workspace_path" => workspace_path,
          "workspace_strategy" => predecessor.fetch("workspace_strategy", nil),
          "workspace_branch" => predecessor.fetch("workspace_branch", nil),
          "note" => "continues in #{predecessor.fetch("id")}'s existing workspace",
          "plan" => plan,
          "created" => false,
          "reused_from_agent_id" => predecessor.fetch("id"),
          "errors" => []
        }
      end

      def shared_workspace_plan?(plan)
        plan.is_a?(Hash) && !!present_string(plan.fetch("inherited_from_agent_id", nil))
      end

      def shared_workspace_record?(workspace)
        workspace.is_a?(Hash) && shared_workspace_plan?(workspace.fetch("plan", nil))
      end

      def workspace_worktree_root_path(workspace)
        return nil unless workspace.is_a?(Hash)

        plan = workspace.fetch("plan", nil)
        plan = {} unless plan.is_a?(Hash)
        present_string(plan["worktree_root_path"]) || present_string(plan["workspace_root_path"]) ||
          present_string(workspace.fetch("workspace_path", nil)) || present_string(plan["workspace_path"])
      end

      def same_workspace_path?(left, right)
        return false if blank?(left) || blank?(right)
        return true if same_path?(left, right)

        canonical_workspace_path(left) == canonical_workspace_path(right)
      end

      def canonical_workspace_path(path)
        expanded = File.expand_path(path.to_s)
        File.exist?(expanded) ? File.realpath(expanded) : expanded
      rescue StandardError
        File.expand_path(path.to_s)
      end

      WORKSPACE_REUSE_REASON_TEXT = {
        "predecessor_not_found" => "that worker's workspace is no longer recorded",
        "predecessor_on_another_issue" => "that worker belongs to another issue",
        "predecessor_workspace_is_not_a_worktree" => "that worker is not working in a managed git worktree",
        "predecessor_workspace_unknown" => "that worker's worktree and branch are not recorded",
        "workspace_missing" => "that worktree is no longer on disk",
        "predecessor_still_live" => "that worker is still live, and two sessions must never share one worktree",
        "workspace_in_use" => "another live worker is already working in that worktree",
        "delivery_branch_already_merged" => "that branch has already been merged",
        "worktree_missing" => "that worktree is no longer on disk",
        "outside_managed_workspace_root" => "that worktree is outside the Meringue workspace root",
        "branch_not_delivery_managed" => "that branch is not allocator-managed",
        "git_root_missing" => "the repository that worktree belongs to is gone",
        "worktree_list_failed" => "git could not list the repository's worktrees",
        "worktree_not_registered" => "git no longer registers that directory as a worktree",
        "worktree_branch_moved" => "that worktree has moved to another branch",
        "worktree_locked" => "that worktree is locked",
        "worktree_inspection_timed_out" => "git did not answer in time",
        "worktree_inspection_error" => "that worktree could not be inspected"
      }.freeze

      def workspace_reuse_reason_text(reuse)
        reason = (reuse.is_a?(Hash) ? reuse.fetch("reason", nil) : nil).to_s
        WORKSPACE_REUSE_REASON_TEXT.fetch(reason, reason.empty? ? "it is not safe to share" : reason.tr("_", " "))
      end

      # Says plainly whether this worker continued in an existing workspace or got a fresh one, so a
      # branch name is never the only evidence.
      def append_workspace_reuse_log(state, agent, reuse)
        return [] unless reuse.is_a?(Hash)
        # A session restart already reports the takeover in its own recovery log line.
        return [] if reuse.fetch("source", nil) == WORKSPACE_REUSE_SOURCE_SESSION_RESTART

        of_agent_id = present_string(reuse.fetch("of_agent_id", nil))
        subject = of_agent_id ? "worker #{of_agent_id}'s" : "an existing"
        reused = reuse.fetch("state", nil) == WORKSPACE_REUSE_STATE_REUSED
        message = if reused
                    "Worker #{agent.fetch("id")} reused #{subject} worktree at #{agent.fetch("workspace_path")} " \
                      "on branch #{agent.fetch("workspace_branch")} instead of provisioning a new one."
                  else
                    "Worker #{agent.fetch("id")} did not reuse #{of_agent_id ? subject : "the related worker's"} " \
                      "worktree (#{workspace_reuse_reason_text(reuse)}), so Meringue provisioned a fresh worktree " \
                      "on branch #{agent.fetch("workspace_branch")}."
                  end
        append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          # An explicit request that could not be honored is worth a warning; the continuation
          # default falling back to a fresh worktree is normal and only needs explaining.
          level: !reused && reuse.fetch("source", nil) == WORKSPACE_REUSE_SOURCE_EXPLICIT ? "warning" : "info",
          message: message,
          details: reuse.reject { |key, _value| key == "workspace" }.merge(
            "agent_id" => agent.fetch("id"),
            "issue_id" => agent.fetch("issue_id", nil),
            "workspace_path" => agent.fetch("workspace_path", nil),
            "workspace_branch" => agent.fetch("workspace_branch", nil)
          ).compact
        )
      end

      # What a successor is told about a workspace it did not provision. Without it, a fresh session
      # would find someone else's uncommitted changes with no explanation, and could open a second
      # pull request for a branch that already has one.
      def shared_workspace_prompt_note(prompt, reuse)
        return prompt unless reuse.is_a?(Hash) && reuse.fetch("state", nil) == WORKSPACE_REUSE_STATE_REUSED
        # The session-restart prompt already explains the takeover in more detail.
        return prompt if reuse.fetch("source", nil) == WORKSPACE_REUSE_SOURCE_SESSION_RESTART

        predecessor = present_string(reuse.fetch("of_agent_id", nil))
        owner = predecessor ? "agent #{predecessor}" : "an earlier agent"
        [
          prompt.to_s,
          "--- Shared workspace ---",
          "You are continuing in #{owner}'s existing worktree at #{reuse.fetch("workspace_path")} on branch " \
          "#{reuse.fetch("workspace_branch")}, not a fresh checkout. Work it already did, committed or not, is " \
          "still there: start with `git status` and `git log` and do not redo it.",
          "Deliver on this same branch. If it already has an open pull request, update that pull request instead " \
          "of opening a second one."
        ].join("\n\n")
      end

      # The successor's copy of the recovery record: it remembers which worker it took over and how
      # deep the restart chain is, which is what stops an endless chain of restarts.
      def successor_session_recovery(state, predecessor_id, now)
        predecessor = find_agent(state, predecessor_id)
        depth = predecessor ? worker_session_restart_chain_depth(predecessor) : 0
        {
          "state" => "restarted_session",
          "restarted_from_agent_id" => predecessor_id,
          "restarted_at" => now,
          "restart_chain_depth" => depth + 1
        }
      end

      def workspace_from_reserved_agent(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", {}) || {}
        {
          "workspace_path" => agent.fetch("workspace_path", plan.fetch("workspace_path", nil)),
          "workspace_strategy" => agent.fetch("workspace_strategy", plan.fetch("strategy", nil)),
          "workspace_branch" => agent.fetch("workspace_branch", plan.fetch("workspace_branch", nil)),
          "workspace_mode" => agent.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED),
          "effective_workspace_mode" => agent.fetch("effective_workspace_mode", plan.fetch("effective_workspace_mode", nil)),
          "workspace_mode_fallback_reason" => agent.fetch("workspace_mode_fallback_reason", plan.fetch("workspace_mode_fallback_reason", nil)),
          "plan" => plan,
          "created" => plan.fetch("created", false),
          "errors" => []
        }
      end

      def checkpoint_worker_workspace!(reservation, workspace, reuse: nil)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, reservation.fetch("agent_id"))
          raise "Worker reservation #{reservation.fetch("agent_id")} disappeared during workspace provisioning." unless agent

          now = timestamp
          agent["workspace_path"] = workspace.fetch("workspace_path")
          agent["workspace_strategy"] = workspace.fetch("workspace_strategy")
          agent["workspace_branch"] = workspace.fetch("workspace_branch", nil)
          agent["workspace_mode"] = workspace.fetch("workspace_mode", agent.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED))
          agent["effective_workspace_mode"] = workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED)
          agent["workspace_mode_fallback_reason"] = workspace.fetch("workspace_mode_fallback_reason", nil)
          agent["status"] = "queued"
          agent["updated_at"] = now
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "cwd" => workspace.fetch("workspace_path"),
            "workspace_plan" => workspace.fetch("plan", nil),
            "workspace_mode" => workspace.fetch("workspace_mode", agent.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED)),
            "effective_workspace_mode" => workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED),
            "workspace_mode_fallback_reason" => workspace.fetch("workspace_mode_fallback_reason", nil),
            # Durable so a restart, a reconciliation pass, and GetInfo all know this worker shares a
            # workspace rather than owning one.
            "workspace_reuse" => reuse.is_a?(Hash) ? reuse.reject { |key, _value| key == "workspace" }.merge("decided_at" => now) : nil,
            "provisioning_state" => "starting_harness",
            "workspace_provisioned_at" => now
          ).compact
          touch_state!(state, now)
          store.save(state)
        end
      end

      # A failed provisioning attempt must not end the worker's existence. The reservation, its
      # prompt, its issue, and its routing are all still valid; only the workspace is missing. So
      # a failure the workspace manager classified as recoverable degrades the worker instead of
      # erroring it into a dead end with no session, nothing to prompt, and nothing to replace:
      #
      #   retry  -> the worker stays `queued` in `retry_pending`. `recover_worker_reservations`
      #             (reconciliation, every 2s) provisions it again with no user action, at most
      #             PROVISIONING_ATTEMPT_LIMIT times in total.
      #   resume -> the worker becomes `blocked` in `retry_exhausted`. It keeps its record, its
      #             prompt, and its failure reason, and prompting it re-queues provisioning.
      #   none   -> today's behavior: `errored`, because another identical attempt would fail
      #             identically. Prompting it still re-queues provisioning rather than rejecting.
      #
      # The reason always stays in harness_metadata (`provisioning_errors`, `provisioning_state`,
      # `provisioning_attempts`, `workspace_plan`) so the AgentTree and GetInfo can explain it.
      def fail_worker_reservation(reservation, command_id:, command_type:, message:, errors:, workspace:, recovery: nil)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, reservation.fetch("agent_id"))
          degradation = nil
          if agent
            now = timestamp
            degradation = provisioning_degradation(agent, recovery)
            message = [message, degradation.fetch("next_step", nil)].compact.join(" ")
            agent["status"] = degradation.fetch("status")
            agent["updated_at"] = now
            agent["workspace_path"] = workspace.fetch("workspace_path", agent.fetch("workspace_path", nil))
            agent["workspace_strategy"] = workspace.fetch("workspace_strategy", agent.fetch("workspace_strategy", nil))
            agent["workspace_branch"] = workspace.fetch("workspace_branch", agent.fetch("workspace_branch", nil))
            agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
              "provisioning_state" => degradation.fetch("provisioning_state"),
              "provisioning_failed_at" => now,
              "provisioning_errors" => Array(errors),
              "provisioning_attempts" => degradation.fetch("attempts"),
              "provisioning_attempt_limit" => PROVISIONING_ATTEMPT_LIMIT,
              "provisioning_recovery" => degradation.fetch("recovery"),
              "provisioning_next_step" => degradation.fetch("next_step", nil),
              "provisioning_progress" => nil,
              "workspace_plan" => workspace.fetch("plan", nil)
            ).compact
            issue = find_issue(state, agent.fetch("issue_id", nil))
            project = issue && find_project(state, issue.fetch("project_id", nil))
            update_issue_status_from_workers!(state, issue, now) if issue
            update_project_status_from_issues!(state, project, now) if project
            diagnostic = State::Compactor.workspace_diagnostic_log(
              message,
              {
                "issue_id" => agent.fetch("issue_id", nil),
                "errors" => Array(errors),
                "provisioning_state" => degradation.fetch("provisioning_state"),
                "provisioning_attempts" => degradation.fetch("attempts"),
                "recovery_guidance" => degradation.fetch("next_step", nil),
                "workspace" => workspace
              }
            )
            append_log(
              state,
              source_type: "kernel",
              source_id: agent.fetch("id"),
              level: degradation.fetch("log_level"),
              message: diagnostic.fetch("message"),
              details: diagnostic.fetch("details")
            )
            log_workspace_cleanup_warnings(state, agent.fetch("id"), workspace)
            touch_state!(state, now)
            store.save(state)
          end
          failed_result(command_id, command_type, message, Array(errors))
        end
      end

      def provisioning_degradation(agent, recovery)
        metadata = agent.fetch("harness_metadata", {}) || {}
        attempts = metadata.fetch("provisioning_attempts", 0).to_i + 1
        case recovery.to_s
        when Workspace::Manager::RECOVERY_RETRY
          if attempts < PROVISIONING_ATTEMPT_LIMIT
            {
              "status" => "queued",
              "provisioning_state" => "retry_pending",
              "recovery" => Workspace::Manager::RECOVERY_RETRY,
              "attempts" => attempts,
              "log_level" => "warning",
              "next_step" => "Retrying automatically (attempt #{attempts + 1} of #{PROVISIONING_ATTEMPT_LIMIT})."
            }
          else
            provisioning_resumable_degradation(attempts)
          end
        when Workspace::Manager::RECOVERY_RESUME
          provisioning_resumable_degradation(attempts)
        else
          {
            "status" => "errored",
            "provisioning_state" => "failed",
            "recovery" => Workspace::Manager::RECOVERY_NONE,
            "attempts" => attempts,
            "log_level" => "error",
            "next_step" => nil
          }
        end
      end

      def provisioning_resumable_degradation(attempts)
        {
          "status" => "blocked",
          "provisioning_state" => "retry_exhausted",
          "recovery" => Workspace::Manager::RECOVERY_RESUME,
          "attempts" => attempts,
          "log_level" => "error",
          "next_step" => "Prompt this worker to retry provisioning, or kill it."
        }
      end

      # Cleanup that could not finish safely is reported, never swallowed: a leftover worktree
      # registration or a branch Meringue refused to delete is something the user has to know
      # about, and the warning names the git command that clears it.
      def log_workspace_cleanup_warnings(state, agent_id, workspace)
        cleanup = workspace.is_a?(Hash) ? (workspace["cleanup"] || workspace.dig("plan", "cleanup")) : nil
        warnings = cleanup.is_a?(Hash) ? Array(cleanup["warnings"]).compact : []
        return [] if warnings.empty?

        append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "warning",
          message: "Workspace cleanup for #{agent_id} could not finish: #{warnings.join("; ")}",
          details: { "agent_id" => agent_id, "cleanup" => cleanup }
        )
      end

      def build_head_agent(head_id:, now:, provider:, runner:, harness_generation: 0, user_message: nil, question_id: nil,
                           selected_target: nil, takeover_of_head_id: nil, follow_up_of_head_id: nil, takeover_context: nil,
                           retry_of: nil, completion_trigger: nil, input_submission_id: nil,
                           snapshot_issue_ids: [], snapshot_project_ids: [], snapshot_unapplied_head_ids: [], snapshot_counters: {},
                           worker_spawning_guidance: false)
        retry_of = nil unless retry_of.is_a?(Hash)
        takeover_context = nil unless takeover_context.is_a?(Hash)
        completion_trigger = nil unless completion_trigger.is_a?(Hash)
        {
          "id" => head_id,
          "type" => "head",
          "status" => "working",
          "project_id" => nil,
          "issue_id" => nil,
          "workspace_path" => nil,
          "workspace_strategy" => nil,
          "workspace_branch" => nil,
          "harness" => provider,
          "pid" => nil,
          "harness_session_id" => nil,
          "harness_session_file" => nil,
          "harness_metadata" => {
            "runner" => runner.class.name,
            "cwd" => cwd,
            "harness_generation" => harness_generation,
            "worker_spawning_guidance" => worker_spawning_guidance == true,
            "head_session_state" => HEAD_SESSION_STATE_PENDING,
            **instance_ownership_metadata,
            # What this head can actually see. A batch command that targets an issue outside this
            # set and outside the head's own batch is a mispredicted id, not a deliberate target,
            # and the counters let the kernel recompute exactly which ids the head would predict.
            "snapshot_issue_ids" => Array(snapshot_issue_ids),
            "snapshot_project_ids" => Array(snapshot_project_ids),
            # A follow-up head can be spawned while an earlier head is still routing. If that
            # earlier, already-visible head creates an issue before this head's result applies,
            # this head may legitimately read it from state and refine or staff it even though the
            # issue id was not in snapshot_issue_ids yet.
            "snapshot_unapplied_head_ids" => Array(snapshot_unapplied_head_ids),
            "snapshot_counters" => (snapshot_counters.is_a?(Hash) ? snapshot_counters : {}),
            # Lineage for a head that retries a failed head. `retry_of_head_id` is what makes the
            # log line, the AgentTree, and a later recovery say "this is H13's request again".
            "retry_of_head_id" => retry_of && retry_of.fetch("head_id", nil),
            "retry_case" => retry_of && retry_of.fetch("case", nil),
            "retry_strategy" => retry_of ? "respawn" : nil,
            "takeover_of_head_id" => takeover_of_head_id,
            "follow_up_of_head_id" => follow_up_of_head_id,
            "takeover_context" => takeover_context,
            "completion_trigger" => completion_trigger,
            "head_request" => {
              "user_message" => user_message,
              "input_submission_id" => input_submission_id,
              "question_id" => question_id,
              "selected_target" => selected_target,
              "takeover_of_head_id" => takeover_of_head_id,
              "follow_up_of_head_id" => follow_up_of_head_id,
              "takeover_context" => takeover_context,
              "retry_of_head_id" => retry_of && retry_of.fetch("head_id", nil)
            }.compact
          }.compact,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def build_worker_agent(agent_id:, issue:, project:, workspace:, session_ref:, now:, title: nil, harness_generation: 0,
                             follow_up_of_agent_id: nil, replaces_agent_id: nil, after_agent_id: nil)
        session_metadata = session_ref.fetch("metadata", {}) || {}
        display_title = worker_display_title(title, issue)
        {
          "id" => agent_id,
          "type" => "worker",
          "status" => "working",
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "follow_up_of_agent_id" => follow_up_of_agent_id,
          "replaces_agent_id" => replaces_agent_id,
          "after_agent_id" => present_string(after_agent_id),
          "workspace_path" => workspace.fetch("workspace_path"),
          "workspace_strategy" => workspace.fetch("workspace_strategy"),
          "workspace_branch" => workspace.fetch("workspace_branch"),
          "workspace_mode" => workspace.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED),
          "effective_workspace_mode" => workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED),
          "workspace_mode_fallback_reason" => workspace.fetch("workspace_mode_fallback_reason", nil),
          "harness" => session_ref.fetch("harness", nil),
          "pid" => session_ref.fetch("pid", nil),
          "harness_session_id" => session_ref.fetch("session_id", nil),
          "harness_session_file" => session_ref.fetch("session_file", nil),
          "session_settings" => session_ref.fetch("session_settings", nil).is_a?(Hash) ? deep_copy(session_ref.fetch("session_settings")) : nil,
          "session_stats" => session_ref.fetch("session_stats", nil).is_a?(Hash) ? deep_copy(session_ref.fetch("session_stats")) : nil,
          "harness_metadata" => session_metadata.merge(
            "title" => display_title,
            "cwd" => session_ref.fetch("cwd", workspace.fetch("workspace_path")),
            "is_streaming" => session_ref.fetch("is_streaming", false),
            "last_event_at" => session_ref.fetch("last_event_at", nil),
            # A worker is not quiet the instant it starts. Seeding the activity clock at spawn is
            # what makes the quiet marker measure this session rather than the epoch.
            WORKER_LAST_ACTIVITY_KEY => now,
            "harness_generation" => harness_generation,
            "workspace_note" => workspace.fetch("note", nil),
            "workspace_plan" => workspace.fetch("plan", nil),
            "delivery_branch" => workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED) == WORKSPACE_MODE_ISOLATED ? workspace.fetch("workspace_branch", nil) : nil,
            "workspace_mode" => workspace.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED),
            "effective_workspace_mode" => workspace.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED),
            "workspace_mode_fallback_reason" => workspace.fetch("workspace_mode_fallback_reason", nil),
            "routing_action" => spawn_routing_action(follow_up_of_agent_id, replaces_agent_id)
          ).compact,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def session_ref_from_agent(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        {
          "harness" => agent.fetch("harness", nil),
          "pid" => agent.fetch("pid", nil),
          "cwd" => metadata.fetch("cwd", agent.fetch("workspace_path", nil)),
          "session_id" => agent.fetch("harness_session_id", nil),
          "session_file" => agent.fetch("harness_session_file", nil),
          "is_streaming" => metadata.fetch("is_streaming", false),
          "last_event_at" => metadata.fetch("last_event_at", nil),
          "session_settings" => agent.fetch("session_settings", nil),
          "session_stats" => agent.fetch("session_stats", nil),
          "metadata" => metadata
        }
      end

      def apply_session_ref_to_agent!(agent, session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["session_settings"] = deep_copy(session_ref.fetch("session_settings")) if session_ref.fetch("session_settings", nil).is_a?(Hash)
        agent["session_stats"] = deep_copy(session_ref.fetch("session_stats")) if session_ref.fetch("session_stats", nil).is_a?(Hash)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          metadata.merge(
            "cwd" => session_ref.fetch("cwd", metadata.fetch("cwd", agent.fetch("workspace_path", nil))),
            "is_streaming" => session_ref.fetch("is_streaming", metadata.fetch("is_streaming", false)),
            "last_event_at" => session_ref.fetch("last_event_at", metadata.fetch("last_event_at", nil))
          ).compact
        )
      end
    end
  end
end
