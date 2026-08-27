# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Removing issue subtrees, their workers, and their workspaces from state, and repairing the
      # references that pointed at them.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def remove_issue_bundles_and_agents!(state, issue_ids:, extra_agent_ids:, reason:, now:, remove_empty_projects: true,
                                           project_ids: [], cleanup_worker_workspaces: false,
                                           prepared_workspace_cleanups: nil)
        requested_project_ids = Array(project_ids).compact.uniq
        requested_issue_ids = Array(issue_ids).compact.uniq
        initial_project_issue_ids = project_issue_ids(state, requested_project_ids)
        initial_root_issue_ids = (requested_issue_ids + initial_project_issue_ids).uniq
        initial_issue_ids = initial_root_issue_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        initial_worker_ids = state.fetch("agents").filter_map do |agent|
          next unless agent.fetch("type", nil) == "worker"
          next unless initial_issue_ids.include?(agent.fetch("issue_id", nil)) || Array(extra_agent_ids).include?(agent.fetch("id", nil))

          agent.fetch("id", nil)
        end.compact.uniq

        workspace_cleanups = if prepared_workspace_cleanups
                               apply_prepared_workspace_cleanups!(state, initial_worker_ids, prepared_workspace_cleanups)
                             elsif cleanup_worker_workspaces
                               cleanup_pruned_worker_workspaces!(state, initial_worker_ids, now)
                             else
                               []
                             end
        # A failed cleanup blocks only the physical deletion attempt, never the logical removal
        # of an otherwise eligible terminal record. Keep these associations in the result so the
        # warning and structured outcome remain actionable, while preserving every safety check in
        # Workspace::Manager (including branch/path ownership validation).
        cleanup_blocked_worker_ids = workspace_cleanups.reject { |outcome| outcome.fetch("success", false) }
                                                     .map { |outcome| outcome.fetch("agent_id") }
        cleanup_blocked_workers = state.fetch("agents").select do |agent|
          cleanup_blocked_worker_ids.include?(agent.fetch("id", nil))
        end
        cleanup_blocked_project_ids = requested_project_ids.select do |project_id|
          cleanup_blocked_workers.any? { |worker| worker.fetch("project_id", nil) == project_id }
        end
        cleanup_blocked_issue_ids = requested_issue_ids.select do |issue_id|
          subtree_ids = issue_subtree_ids(state, issue_id)
          cleanup_blocked_workers.any? { |worker| subtree_ids.include?(worker.fetch("issue_id", nil)) }
        end

        # Cleanup is best-effort and conservative. Eligibility was established above from
        # lifecycle/retention blockers, so do not subtract cleanup failures from either set.
        effective_project_ids = requested_project_ids
        effective_issue_ids = requested_issue_ids
        root_issue_ids = (effective_issue_ids + project_issue_ids(state, effective_project_ids)).uniq
        issue_ids_to_remove = root_issue_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        issues_to_remove = state.fetch("issues").select { |issue| issue_ids_to_remove.include?(issue.fetch("id", nil)) }
        affected_project_ids = (issues_to_remove.map { |issue| issue.fetch("project_id", nil) } + effective_project_ids).compact.uniq
        empty_project_ids = if remove_empty_projects
                              affected_project_ids.select do |project_id|
                                state.fetch("issues").none? do |issue|
                                  issue.fetch("project_id", nil) == project_id && !issue_ids_to_remove.include?(issue.fetch("id", nil))
                                end
                              end
                            else
                              []
                            end
        removed_project_ids = (effective_project_ids + empty_project_ids).uniq
        # The agent record owns workspace routing. A stale id in issue.agent_ids must never make
        # pruning one issue remove a worker (and worktree) whose issue_id points at another issue.
        issue_owned_agent_ids = state.fetch("agents").select do |agent|
          issue_ids_to_remove.include?(agent.fetch("issue_id", nil))
        end.map { |agent| agent.fetch("id", nil) }
        originating_head_ids = issues_to_remove.map { |issue| issue.fetch("originating_head_id", nil) }.compact
        related_head_ids = pruned_related_head_agent_ids(state, issue_ids_to_remove, removed_project_ids)
        bundled_agent_ids = (issue_owned_agent_ids + originating_head_ids + related_head_ids).compact.uniq
        effective_extra_agent_ids = Array(extra_agent_ids).compact.uniq
        agent_ids_to_remove = (bundled_agent_ids + effective_extra_agent_ids).compact.uniq
        standalone_agent_ids = effective_extra_agent_ids - bundled_agent_ids

        released_head_ids = release_head_sessions_for_removed_agents!(state, agent_ids_to_remove, now)
        # A goal cannot outlive the issue it controls, or it would keep driving a record that
        # no longer exists.
        removed_goal_ids = goals_for_issue_ids(state, issue_ids_to_remove).map { |goal| goal.fetch("id", nil) }.compact
        state["goals"] = state.fetch("goals", []).reject { |goal| removed_goal_ids.include?(goal.fetch("id", nil)) }
        state["issues"] = state.fetch("issues").reject { |issue| issue_ids_to_remove.include?(issue.fetch("id", nil)) }
        # Remember that these ids existed. A command already in flight (a head result being
        # applied while a prune lands) can then be told its target was removed instead of being
        # accused of inventing an id that was real when it was read.
        record_removed_records!(state, "issue", issue_ids_to_remove, reason, now)
        record_removed_records!(state, "agent", agent_ids_to_remove, reason, now)
        state["agents"] = state.fetch("agents").reject { |agent| agent_ids_to_remove.include?(agent.fetch("id", nil)) }
        state["projects"] = state.fetch("projects").reject { |project| removed_project_ids.include?(project.fetch("id", nil)) }
        state.fetch("issues").each do |issue|
          issue["agent_ids"] = Array(issue.fetch("agent_ids", [])) - agent_ids_to_remove if issue.key?("agent_ids")
          # Killing a worker removes its record, so routing pointers must not keep naming it.
          # A misrouted worker that was killed used to leave `last_agent_id` dangling on the
          # issue it never belonged to.
          clear_dangling_issue_routing_pointer!(issue, agent_ids_to_remove, now)
        end
        updated_project_ids = refresh_projects_after_prune!(state, affected_project_ids - removed_project_ids, now)

        {
          "reason" => reason,
          "root_issue_ids" => root_issue_ids,
          "removed_issue_ids" => issue_ids_to_remove,
          "removed_agent_ids" => agent_ids_to_remove,
          "removed_goal_ids" => removed_goal_ids,
          "removed_standalone_agent_ids" => standalone_agent_ids,
          "removed_project_ids" => removed_project_ids,
          "updated_project_ids" => updated_project_ids,
          "released_head_session_agent_ids" => released_head_ids,
          "workspace_cleanup_outcomes" => workspace_cleanups,
          "removed_worktree_agent_ids" => workspace_cleanups.filter_map do |outcome|
            outcome.fetch("agent_id", nil) if outcome.fetch("status", nil) == "removed"
          end,
          "workspace_cleanup_blocked_agent_ids" => cleanup_blocked_worker_ids,
          "workspace_cleanup_blocked_issue_ids" => cleanup_blocked_issue_ids,
          "workspace_cleanup_blocked_project_ids" => cleanup_blocked_project_ids,
          "workspace_cleanup_log_entry_ids" => workspace_cleanups.flat_map { |outcome| Array(outcome.fetch("log_entry_ids", [])) }.uniq
        }
      end

      def project_issue_ids(state, project_ids)
        state.fetch("issues").select do |issue|
          Array(project_ids).include?(issue.fetch("project_id", nil))
        end.map { |issue| issue.fetch("id") }
      end

      def apply_prepared_workspace_cleanups!(state, worker_ids, prepared)
        allowed_ids = Array(worker_ids).compact
        Array(prepared).filter_map do |raw_outcome|
          outcome = deep_copy(raw_outcome)
          agent_id = outcome.fetch("agent_id", nil)
          next unless allowed_ids.include?(agent_id)

          worker = find_agent(state, agent_id)
          next unless worker && worker.fetch("type", nil) == "worker"

          metadata = worker.fetch("harness_metadata", {}) || {}
          worker["harness_metadata"] = metadata.merge("workspace_cleanup" => outcome.reject { |key, _value| key == "log_entry_ids" })
          outcome.merge("log_entry_ids" => append_workspace_cleanup_log(state, worker, outcome))
        end
      end

      def clear_prune_cleanup_claims!(state, operation_id)
        return if blank?(operation_id)

        state.fetch("agents").each do |agent|
          metadata = agent.fetch("harness_metadata", {}) || {}
          claim = metadata.fetch("prune_cleanup_claim", nil)
          next unless claim.is_a?(Hash) && claim.fetch("operation_id", nil) == operation_id

          metadata = metadata.dup
          metadata.delete("prune_cleanup_claim")
          agent["harness_metadata"] = metadata
        end
      end

      def cleanup_pruned_worker_workspaces!(state, worker_ids, now, append_logs: true, deadline: nil)
        pruned_ids = Array(worker_ids).compact
        Array(worker_ids).filter_map do |agent_id|
          worker = find_agent(state, agent_id)
          if deadline && monotonic_time >= deadline
            # The prune pass ran out of budget before it could attempt this worktree. Carry the
            # persisted workspace identity so the post-commit cleanup can retry it without
            # needing the worker record, which is about to be removed.
            base = blocked_worktree_path_base(worker) || { "agent_id" => agent_id }
            next base.merge(
              "status" => "failed",
              "reason" => "prune_cleanup_budget_exhausted",
              "success" => false,
              "attempted" => false,
              "checked_at" => now,
              "log_entry_ids" => []
            )
          end
          next unless worker && worker.fetch("type", nil) == "worker"

          # A worker whose worktree was taken over by a successor no longer owns it, so pruning it
          # removes only its record. Without this, the shared checkout could be deleted from under
          # the successor or produce a misleading cleanup warning for the predecessor.
          if worker_workspace_handed_over?(state, worker)
            outcome = handed_over_workspace_cleanup_outcome(worker, now)
            worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome)
            next outcome.merge("log_entry_ids" => [])
          end
          # Several workers can legitimately share one worktree. The record may go as soon as this
          # worker no longer needs it; the *worktree* may only go once nobody does. A retained
          # sharer therefore skips cleanup successfully instead of failing it, because failing would
          # retain this record - and warn about it - on every pass forever.
          retained_sharers = retained_workspace_sharer_ids(state, worker, pruned_ids)
          if retained_sharers.any?
            outcome = shared_workspace_cleanup_outcome(worker, retained_sharers, now)
            worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome)
            next outcome.merge("log_entry_ids" => [])
          end

          protected_paths = state.fetch("agents").filter_map do |other|
            next unless other.fetch("type", nil) == "worker" && other.fetch("id", nil) != agent_id
            # The successor is listed separately, so a handed-over predecessor must not protect a
            # path it no longer owns: that would leak the worktree when the issue is pruned.
            next if worker_workspace_handed_over?(state, other)
            # A worker this same pass is removing cannot own the path either. Protecting it would
            # deadlock a shared worktree whose every sharer is being pruned: each sharer would
            # refuse on account of the others and the worktree would never be removed.
            next if pruned_ids.any? { |pruned_id| Ids.same?(pruned_id, other.fetch("id", nil)) }

            worker_worktree_root_path(other)
          end
          cleanup_options = { protected_paths: protected_paths }
          method = workspace_manager.method(:cleanup_pruned_worker_workspace)
          cleanup_options[:deadline] = deadline if method.parameters.any? { |kind, name| kind == :keyrest || name == :deadline }
          outcome = method.call(
            worker_workspace_cleanup_record(state, worker),
            **cleanup_options
          ).merge(
            "agent_id" => agent_id,
            "issue_id" => worker.fetch("issue_id", nil),
            "project_id" => worker.fetch("project_id", nil),
            "checked_at" => now
          )
          worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome)
          log_ids = append_logs ? append_workspace_cleanup_log(state, worker, outcome) : []
          outcome.merge("log_entry_ids" => log_ids)
        rescue StandardError => e
          outcome = {
            "agent_id" => agent_id,
            "issue_id" => worker && worker.fetch("issue_id", nil),
            "project_id" => worker && worker.fetch("project_id", nil),
            "status" => "failed",
            "reason" => "workspace_cleanup_error",
            "success" => false,
            "attempted" => false,
            "error" => sanitized_error_message(e),
            "checked_at" => now
          }.compact
          worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome) if worker
          log_ids = worker && append_logs ? append_workspace_cleanup_log(state, worker, outcome) : []
          outcome.merge("log_entry_ids" => log_ids)
        end
      end

      def worker_workspace_handed_over?(state, worker)
        successor_id = present_string(worker.fetch("replaced_by_agent_id", nil)) ||
                       present_string(worker_session_recovery(worker).fetch("restarted_by_agent_id", nil))
        return false unless successor_id

        successor = find_agent(state, successor_id)
        return false unless successor.is_a?(Hash) && successor.fetch("type", nil) == "worker"

        root = worker_worktree_root_path(worker)
        !!present_string(root) && worker_worktree_root_path(successor) == root
      end

      # Workers that still need this worker's worktree once this pass is done: any worker sharing the
      # same worktree root that the pass is not removing.
      def retained_workspace_sharer_ids(state, worker, pruned_ids)
        root = present_string(worker_worktree_root_path(worker))
        return [] unless root
        return [] unless worker.fetch("workspace_strategy", nil) == "git_worktree"

        excluded = Array(pruned_ids) + [worker.fetch("id", nil)]
        state.fetch("agents", []).filter_map do |other|
          next unless other.is_a?(Hash) && other.fetch("type", nil) == "worker"
          next if excluded.any? { |id| Ids.same?(id, other.fetch("id", nil)) }
          next unless same_workspace_path?(present_string(worker_worktree_root_path(other)), root)

          other.fetch("id", nil)
        end.compact
      end

      def shared_workspace_cleanup_outcome(worker, sharing_agent_ids, now)
        {
          "agent_id" => worker.fetch("id", nil),
          "issue_id" => worker.fetch("issue_id", nil),
          "project_id" => worker.fetch("project_id", nil),
          "status" => "skipped",
          "reason" => "workspace_shared_with_retained_worker",
          "success" => true,
          "attempted" => false,
          "worktree_root_path" => worker_worktree_root_path(worker),
          "workspace_branch" => worker.fetch("workspace_branch", nil),
          "sharing_agent_ids" => sharing_agent_ids,
          "checked_at" => now
        }.compact
      end

      def handed_over_workspace_cleanup_outcome(worker, now)
        {
          "agent_id" => worker.fetch("id", nil),
          "issue_id" => worker.fetch("issue_id", nil),
          "project_id" => worker.fetch("project_id", nil),
          "status" => "skipped",
          "reason" => "workspace_handed_over_to_successor",
          "success" => true,
          "attempted" => false,
          "worktree_root_path" => worker_worktree_root_path(worker),
          "workspace_branch" => worker.fetch("workspace_branch", nil),
          "successor_agent_id" => present_string(worker.fetch("replaced_by_agent_id", nil)) ||
            present_string(worker_session_recovery(worker).fetch("restarted_by_agent_id", nil)),
          "checked_at" => now
        }.compact
      end

      def worker_workspace_cleanup_record(state, worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", nil)
        project = find_project(state, worker.fetch("project_id", nil))
        {
          "workspace_strategy" => worker.fetch("workspace_strategy", nil),
          "workspace_path" => worker.fetch("workspace_path", nil),
          "workspace_branch" => worker.fetch("workspace_branch", nil),
          "project_root" => project && project.fetch("root_path", nil),
          "plan" => plan.is_a?(Hash) ? plan : nil
        }.compact
      end

      def worker_worktree_root_path(worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", {})
        plan = {} unless plan.is_a?(Hash)
        plan["worktree_root_path"] || plan["workspace_root_path"] || worker.fetch("workspace_path", nil) || plan["workspace_path"]
      end

      # The persisted workspace plan is wrapped as `{"workspace" => inner}` by the manager's
      # allocation result. Unwrap it so path/branch/git_root can be read directly, while still
      # tolerating a bare inner plan (tests and older records may store either shape).
      def workspace_plan_record(worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", nil)
        return {} unless plan.is_a?(Hash)
        inner = plan.fetch("workspace", nil)
        inner.is_a?(Hash) ? inner : plan
      end

      # The prune pass runs out of budget before it can attempt some worktrees. Carry the
      # persisted workspace identity on the `prune_cleanup_budget_exhausted` outcome so the
      # post-commit cleanup can retry it without the worker record, which the pass is
      # about to remove.
      def blocked_worktree_path_base(worker)
        return nil unless worker.is_a?(Hash) && worker.fetch("type", nil) == "worker"
        inner = workspace_plan_record(worker)
        worktree_root = present_string(inner["worktree_root_path"] || inner["workspace_root_path"] ||
                                        worker.fetch("workspace_path", nil) || inner["workspace_path"])
        branch = present_string(inner["workspace_branch"] || worker.fetch("workspace_branch", nil))
        git_root = present_string(inner["git_root"] || inner["project_root"] || worker.fetch("project_root", nil))
        return nil unless worktree_root && branch && git_root
        {
          "agent_id" => worker.fetch("id", nil),
          "issue_id" => worker.fetch("issue_id", nil),
          "project_id" => worker.fetch("project_id", nil),
          "worktree_root_path" => worktree_root,
          "workspace_branch" => branch,
          "git_root" => git_root,
          "workspace_owner_id" => inner["workspace_owner_id"],
          "requested_worktree_provider" => inner["requested_worktree_provider"],
          "worktree_provider" => inner["worktree_provider"],
          "worktree_provider_identifier" => inner["worktree_provider_identifier"],
          "worktree_provider_cwd" => inner["worktree_provider_cwd"],
          "project_root" => inner["project_root"]
        }.compact
      end

      # Only cleanups the user may have to act on get their own line. A successful removal (or a
      # confirmation that the worktree was already gone, or a workspace that was never a managed
      # worktree) is counted by the pass summary instead, so one prune of five workers is one log
      # line rather than six. The per-worker outcome is not lost: it is written to the worker's
      # `harness_metadata.workspace_cleanup` and returned in the pass's `workspace_cleanup_outcomes`,
      # which the prune log details and the command result both carry.
      def append_workspace_cleanup_log(state, worker, outcome)
        return [] if outcome.fetch("success", false)
        return [] if outcome.fetch("status", "failed") == "skipped"

        message = "Pruned worker #{worker.fetch("id")} but its managed worktree could not be removed; " \
                  "preserving it for safety: #{outcome.fetch("reason", "unknown_error")}."
        append_log(
          state,
          source_type: "kernel",
          source_id: worker.fetch("id"),
          level: "warning",
          message: message,
          details: outcome.merge(
            "agent_id" => worker.fetch("id"),
            "issue_id" => worker.fetch("issue_id", nil),
            "project_id" => worker.fetch("project_id", nil)
          ).compact
        )
      end

      def clear_dangling_issue_routing_pointer!(issue, removed_agent_ids, now)
        return unless removed_agent_ids.include?(issue.fetch("last_agent_id", nil))

        issue["last_agent_id"] = Array(issue.fetch("agent_ids", [])).last
        issue["last_routing_action"] = nil if issue["last_agent_id"].nil?
        issue["updated_at"] = now
      end

      # A head's harness session only lives as long as its head record. Whenever a head
      # leaves active state its session is stopped and marked terminal; worker session
      # handling is intentionally untouched here.
      def release_head_sessions_for_removed_agents!(state, agent_ids, now)
        Array(agent_ids).filter_map do |agent_id|
          agent = find_agent(state, agent_id)
          next unless agent && agent.fetch("type", nil) == "head"

          release_head_session!(agent, reason: "head_record_removed", now: now).fetch("changed", false) ? agent_id : nil
        end
      end

      def pruned_related_head_agent_ids(state, issue_ids_to_remove, removed_project_ids)
        state.fetch("agents").select { |agent| agent.fetch("type", nil) == "head" }
             .reject { |agent| head_applying_batch?(agent) }
             .select { |agent| head_related_to_pruned_work?(state, agent, issue_ids_to_remove, removed_project_ids) }
             .map { |agent| agent.fetch("id", nil) }
      end

      # A head that is mid-batch owns the commands still being journaled. Pruning it from inside
      # its own `Prune` command would drop the journal and abort the rest of the batch.
      def head_applying_batch?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.is_a?(Hash) && metadata.fetch("head_result_apply_state", nil) == "applying"
      end

      def head_related_to_pruned_work?(state, head, issue_ids_to_remove, removed_project_ids)
        return true if issue_ids_to_remove.include?(head.fetch("issue_id", nil))
        return true if removed_project_ids.include?(head.fetch("project_id", nil))

        related = head_result_related_ids(state, head)
        (related.fetch("issue_ids") & issue_ids_to_remove).any? ||
          (related.fetch("project_ids") & removed_project_ids).any?
      end

      def head_result_related_ids(state, head)
        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", nil)
        commands = head_result.is_a?(Hash) ? Array(value_at(head_result, "commands") || []) : []
        journal_issue_ids = head_batch_created_issues(Array(metadata.fetch("head_result_command_journal", []))).filter_map { |entry| entry.fetch("issue_id", nil) }
        commands.each_with_object({ "issue_ids" => journal_issue_ids.dup, "project_ids" => [] }) do |command, ids|
          next unless command.is_a?(Hash)

          payload = value_at(command, "payload")
          payload = {} unless payload.is_a?(Hash)
          collect_head_command_related_ids!(state, ids, payload)
        end.transform_values { |values| values.compact.uniq }
      end

      def collect_head_command_related_ids!(state, ids, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        target_id = value_at(payload, "target_id", "TargetID", "targetId", "id")

        ids.fetch("issue_ids") << issue_id if present_string(issue_id) && !batch_issue_reference_value?(issue_id)
        ids.fetch("project_ids") << project_id if present_string(project_id)
        collect_related_ids_for_agent_target!(state, ids, agent_id)
        collect_related_ids_for_target!(state, ids, target_id)
      end

      def collect_related_ids_for_agent_target!(state, ids, agent_id)
        agent = present_string(agent_id) && find_agent(state, agent_id)
        return unless agent

        ids.fetch("issue_ids") << agent.fetch("issue_id", nil)
        ids.fetch("project_ids") << agent.fetch("project_id", nil)
      end

      def collect_related_ids_for_target!(state, ids, target_id)
        target = present_string(target_id)
        return unless target

        if (issue = find_issue(state, target))
          ids.fetch("issue_ids") << issue.fetch("id", nil)
          ids.fetch("project_ids") << issue.fetch("project_id", nil)
        elsif (project = find_project(state, target))
          ids.fetch("project_ids") << project.fetch("id", nil)
        elsif (agent = find_agent(state, target))
          ids.fetch("issue_ids") << agent.fetch("issue_id", nil)
          ids.fetch("project_ids") << agent.fetch("project_id", nil)
        end
      end

      def refresh_projects_after_prune!(state, project_ids, now)
        Array(project_ids).filter_map do |project_id|
          project = find_project(state, project_id)
          next unless project

          update_project_status_from_issues!(state, project, now)
          project.fetch("id")
        end
      end
    end
  end
end
