# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Kill: stopping a target's sessions outside the state lock, then removing its records.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def kill(command_id, command_type, payload)
        target_id = value_at(payload, "target_id", "TargetID", "targetId", "id")
        return rejected_result(command_id, command_type, "Target was not killed.", ["target_id is required"]) if blank?(target_id)

        # Harness process termination is unbounded: kill_session_safely waits up to the harness
        # shutdown timeout for each child process to exit. Running it while the shared state lock
        # is held makes rapid `/kill` commands serialize on the lock for N x (process exit + full
        # state read/write) and starves reconciliation and every later command. State mutation,
        # record removal, worktree cleanup, and persistence remain atomic under the state lock;
        # only the OS-level session stop moves outside it, mirroring the Prune pattern. The head
        # session is already marked released under the lock, so a concurrent reconcile will not
        # double-stop or reuse the session even if the engine dies before the stop completes.
        session_stops = []
        takeover_previous_head_id = nil
        result = synchronized_state do
          state = normalized_state
          target = find_agent(state, target_id) || find_goal(state, target_id) || find_issue(state, target_id) || find_project(state, target_id)
          break(rejected_result(command_id, command_type, "Target #{target_id} does not exist.", ["target_not_found"])) unless target

          now = timestamp
          takeover_previous_head_id = if target.fetch("type", nil) == "head"
                                        present_string(target.dig("harness_metadata", "takeover_of_head_id"))
                                      end
          killed_agent_ids = kill_target_in_state!(state, target_id.to_s, now)
          # A worker queued behind a killed agent can never settle its predecessor, so it is cancelled
          # in the same command instead of waiting forever on a record that is being removed.
          cancelled_dependents = cancel_deferred_dependents_in_state!(
            state,
            killed_agent_ids,
            now: now,
            reason: "predecessor_killed",
            trigger: "kill"
          )
          killed_agent_ids = (killed_agent_ids + cancelled_dependents.fetch("agent_ids")).uniq

          # Snapshot the session refs and harness providers needed for out-of-lock termination.
          # Deep copy so the outside-lock iteration never reads state mutated by a concurrent command.
          killed_agent_ids.each do |agent_id|
            agent = find_agent(state, agent_id)
            next unless agent
            next unless present_string(agent.fetch("harness", nil))

            session_stops << { "session_ref" => deep_copy(session_ref_from_agent(agent)), "agent" => deep_copy(agent) }
          end

          result_value = deep_copy(target)
          removal = remove_killed_target_records!(state, target_id.to_s, killed_agent_ids, now)
          result_value = result_value.merge(
            "removed_worktree_agent_ids" => removal.fetch("removed_worktree_agent_ids", []),
            "workspace_cleanup_outcomes" => removal.fetch("workspace_cleanup_outcomes", []),
            "workspace_cleanup_blocked_agent_ids" => removal.fetch("workspace_cleanup_blocked_agent_ids", [])
          )

          log_ids = cancelled_dependents.fetch("log_entry_ids").dup
          log_ids.concat(removal.fetch("workspace_cleanup_log_entry_ids", []))
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: target_id.to_s,
            level: "info",
            message: "Killed #{target_id}.",
            details: {
              "target_id" => target_id.to_s,
              "killed_agent_ids" => killed_agent_ids,
              "cancelled_deferred_agent_ids" => cancelled_dependents.fetch("agent_ids"),
              "removed_issue_ids" => removal.fetch("removed_issue_ids", []),
              "removed_agent_ids" => removal.fetch("removed_agent_ids", []),
              "removed_project_ids" => removal.fetch("removed_project_ids", []),
              "removed_worktree_agent_ids" => removal.fetch("removed_worktree_agent_ids", []),
              "workspace_cleanup_outcomes" => removal.fetch("workspace_cleanup_outcomes", []),
              "workspace_cleanup_blocked_agent_ids" => removal.fetch("workspace_cleanup_blocked_agent_ids", [])
            }.compact
          ))
          worktree_summary = kill_worktree_summary(removal)
          if present_string(worktree_summary)
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: target_id.to_s,
              level: kill_worktree_summary_level(removal),
              message: worktree_summary,
              details: {
                "target_id" => target_id.to_s,
                "removed_worktree_agent_ids" => removal.fetch("removed_worktree_agent_ids", []),
                "workspace_cleanup_outcomes" => removal.fetch("workspace_cleanup_outcomes", [])
              }.compact
            ))
          end
          touch_state!(state, now)
          store.save(state)

          accepted_result(command_id, command_type, target_id.to_s, "Killed #{target_id}.", result_value, log_ids)
        end

        if takeover_previous_head_id
          rollback_log_ids = Array(rollback_head_takeover!(takeover_previous_head_id, target_id.to_s, reason: "successor_head_killed"))
          result["log_entry_ids"] = Array(result.fetch("log_entry_ids", [])) + rollback_log_ids
        end

        # Phase 2: stop harness sessions outside the state lock. Best-effort; the state already
        # records each head session as released, so failure to terminate an OS process does not
        # corrupt lifecycle state and the reconciler reaps orphans on the next tick.
        session_stops.each do |stop|
          kill_session_safely(stop.fetch("session_ref"), agent: stop.fetch("agent"))
        end

        result
      end

      # Kill is an immediate stop-and-remove operation: lifecycle state is marked first so
      # attached sessions are stopped consistently, then the target bundle leaves active state.
      # A killed worker's managed git worktree is removed in the same pass, reusing the prune
      # cleanup path so every safety invariant (shared worktree, handed-over successor, dirty or
      # locked checkout, main-checkout protection, branch retention) is preserved. A worktree
      # another live or queued agent still needs is left in place and reported as retained.
      def remove_killed_target_records!(state, target_id, killed_agent_ids, now)
        issue_ids = []
        project_ids = []
        if find_agent(state, target_id).nil?
          if (issue = find_issue(state, target_id))
            issue_ids << issue.fetch("id")
          elsif (project = find_project(state, target_id))
            project_ids << project.fetch("id")
          end
        end

        remove_issue_bundles_and_agents!(
          state,
          issue_ids: issue_ids,
          project_ids: project_ids,
          extra_agent_ids: killed_agent_ids,
          reason: "killed",
          now: now,
          remove_empty_projects: false,
          cleanup_worker_workspaces: true
        )
      end

      # One visible line for the worktree side effect of a kill, mirroring the prune summary.
      # Removed worktrees, worktrees retained because another agent still uses them, and worktrees
      # preserved because cleanup was unsafe each get their own clause; a kill with no managed
      # worktrees writes nothing so the "Killed <id>." line stands alone.
      def kill_worktree_summary(removal)
        outcomes = Array(removal.fetch("workspace_cleanup_outcomes", []))
        return "" if outcomes.empty?

        removed = outcomes.select { |outcome| outcome.fetch("status", nil) == "removed" }
        retained = outcomes.select do |outcome|
          outcome.fetch("reason", nil) == "workspace_shared_with_retained_worker" ||
            outcome.fetch("reason", nil) == "workspace_handed_over_to_successor"
        end
        blocked = outcomes.reject { |outcome| outcome.fetch("success", false) }

        clauses = []
        if removed.any?
          clauses << "Removed #{count_phrase(removed.length, "managed worktree")}: " \
                     "#{id_list_phrase(removed.map { |outcome| outcome.fetch("agent_id", nil) }.compact)}."
        end
        if retained.any?
          descriptions = retained.first(PRUNE_RETENTION_REPORT_LIMIT).map do |outcome|
            sharing = Array(outcome.fetch("sharing_agent_ids", [])) + Array(outcome.fetch("successor_agent_id", nil))
            "#{outcome.fetch("agent_id", "worker")} (still in use by #{sharing.compact.join(", ")})"
          end
          remainder = retained.length - descriptions.length
          descriptions << "and #{remainder} more" if remainder.positive?
          clauses << "Retained #{count_phrase(retained.length, "managed worktree")} because another agent is still " \
                     "using it: #{descriptions.join(", ")}."
        end
        if blocked.any?
          listed = blocked.first(PRUNE_RETENTION_REPORT_LIMIT).map do |outcome|
            "#{outcome.fetch("agent_id", "worker")} (#{outcome.fetch("reason", "unknown_error")})"
          end
          remainder = blocked.length - listed.length
          listed << "and #{remainder} more" if remainder.positive?
          clauses << "Preserved #{count_phrase(blocked.length, "managed worktree")} because cleanup was not safe: " \
                     "#{listed.join(", ")}."
        end
        clauses.empty? ? "" : clauses.join(" ")
      end

      def kill_worktree_summary_level(removal)
        Array(removal.fetch("workspace_cleanup_outcomes", [])).any? { |outcome| !outcome.fetch("success", false) } ? "warning" : "info"
      end

      def unapplied_head_ids_for_issue_visibility(state)
        state.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "head" && !State::Models.head_result_applied?(agent) &&
            !%w[blocked errored killed].include?(agent.fetch("status", nil).to_s)
        end.map { |agent| agent.fetch("id", nil) }.compact
      end

      def head_still_routing?(head)
        return false unless head.is_a?(Hash) && head.fetch("type", nil) == "head"
        return false unless %w[queued working idle].include?(head.fetch("status", nil).to_s)

        metadata = head.fetch("harness_metadata", {}) || {}
        return false unless metadata.is_a?(Hash)
        return false if present_string(metadata.fetch("head_result_applied_at", nil))
        return false if metadata.fetch("head_takeover_state", nil).to_s == "claimed"

        true
      end

      def kill_target_in_state!(state, target_id, now)
        if (agent = find_agent(state, target_id))
          mark_agent_killed!(agent, now)
          return [agent.fetch("id")]
        end

        # Killing a goal is the destructive stop: the loop ends and the attempt session it
        # currently owns is killed with it. `StopGoal` is the variant that keeps the session.
        if (goal = find_goal(state, target_id))
          return kill_goal!(state, goal, now)
        end

        if (issue = find_issue(state, target_id))
          return kill_issue_subtree!(state, issue, now)
        end

        project = find_project(state, target_id)
        return [] unless project

        project["status"] = "killed"
        project["updated_at"] = now
        state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }
             .flat_map { |issue| kill_issue_subtree!(state, issue, now) }
             .uniq
      end

      def kill_goal!(state, goal, now)
        settle_goal_record!(goal, status: "killed", stop_reason: "killed", now: now)
        worker_id = present_string(goal.fetch("last_worker_id", nil))
        worker = worker_id && find_agent(state, worker_id)
        return [] unless worker && !TERMINAL_AGENT_STATUSES.include?(worker.fetch("status", nil))

        mark_agent_killed!(worker, now)
        [worker.fetch("id")]
      end

      # A killed issue must not leave its goal ticking, so goals settle with the subtree.
      def kill_goals_for_issues!(state, issue_ids, now)
        goals_for_issue_ids(state, issue_ids).each do |goal|
          next unless Goals::Record.loop_active?(goal)

          settle_goal_record!(goal, status: "killed", stop_reason: "killed", now: now)
        end
      end

      def kill_issue_subtree!(state, issue, now)
        issue["status"] = "killed"
        issue["updated_at"] = now
        kill_goals_for_issues!(state, [issue.fetch("id")], now)
        child_agent_ids = state.fetch("agents").select { |agent| agent.fetch("issue_id", nil) == issue.fetch("id") }.map do |agent|
          mark_agent_killed!(agent, now)
          agent.fetch("id")
        end
        child_issue_agent_ids = state.fetch("issues")
                                     .select { |candidate| candidate.fetch("parent_issue_id", nil) == issue.fetch("id") }
                                     .flat_map { |child_issue| kill_issue_subtree!(state, child_issue, now) }
        (child_agent_ids + child_issue_agent_ids).uniq
      end

      def mark_agent_killed!(agent, now)
        agent["status"] = "killed"
        agent["updated_at"] = now
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("killed_at" => now)
        return unless agent.fetch("type", nil) == "head"

        # The caller stops attached harness sessions; only mark the head session terminal here
        # so a killed head can never look like a live or resumable session.
        metadata = agent.fetch("harness_metadata", {}) || {}
        agent["harness_metadata"] = metadata.merge(
          "head_session_state" => HEAD_SESSION_STATE_RELEASED,
          "head_session_released_at" => present_string(metadata.fetch("head_session_released_at", nil)) || now,
          "head_session_release_reason" => present_string(metadata.fetch("head_session_release_reason", nil)) || "killed",
          "is_streaming" => false
        ).compact
      end
    end
  end
end
