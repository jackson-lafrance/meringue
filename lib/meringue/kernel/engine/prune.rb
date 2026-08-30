# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Prune: deciding which issues, workers, and projects are settled enough to remove, and
      # cleaning the managed worktrees that go with them.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Prune takes no options. One pass removes resolved (completed/killed) and errored records
      # that are eligible for cleanup.
      def prune(command_id, command_type, payload)
        input_submission_id = present_string(value_at(payload, "_input_submission_id", "input_submission_id"))
        if input_submission_id && (receipt = completed_prune_submission(input_submission_id))
          return accepted_result(
            command_id, command_type, nil,
            "Prune submission #{input_submission_id} was already applied.",
            receipt.fetch("details", {}), [receipt.fetch("id")]
          )
        end
        unless synchronized_state { github_support_enabled?(normalized_state) }
          return rejected_result(
            command_id, command_type,
            "Prune is inactive because GitHub support is disabled; no records were removed. Enable it in Settings → Experiments to prune resolved records.",
            ["github_support_disabled"]
          )
        end
        started_at = monotonic_time
        # Forge I/O and git worktree cleanup are both unbounded from the state layer's point of
        # view. Neither may run while the shared state lock is held: reconciliation and later TUI
        # commands must remain able to read and mutate state throughout a large prune.
        lookup_context = prepare_prune_forge_lookups
        forge_finished_at = monotonic_time
        operation_id = present_string(command_id) || "prune-#{instance_id}-#{Thread.current.object_id}-#{(started_at * 1_000_000).to_i}"
        lookup_context["operation_id"] = operation_id
        preparation = synchronized_state do
          with_prune_forge_lookup_context(lookup_context) do
            prepare_prune_workspace_cleanup(operation_id)
          end
        end
        planning_finished_at = monotonic_time
        workspace_cleanups = cleanup_prune_workspace_plan(
          preparation,
          deadline: monotonic_time + [prune_workspace_cleanup_budget, 0.0].max
        )
        cleanup_finished_at = monotonic_time
        result = synchronized_state do
          with_prune_forge_lookup_context(lookup_context) do
            prune_records(
              command_id,
              command_type,
              prepared_plan: preparation.fetch("plan"),
              prepared_workspace_cleanups: workspace_cleanups,
              prune_operation_id: operation_id,
              input_submission_id: input_submission_id,
              timings: {
                "forge_lookup_seconds" => forge_finished_at - started_at,
                "planning_seconds" => planning_finished_at - forge_finished_at,
                "workspace_cleanup_seconds" => cleanup_finished_at - planning_finished_at,
                "commit_seconds" => monotonic_time - cleanup_finished_at,
                "total_seconds" => monotonic_time - started_at
              }
            )
          end
        end
        # The logical prune is now committed and its claims are clear. Retry failed physical
        # cleanup with no outer state lock, so a slow provider or Git command cannot block later
        # kernel commands. The retry reacquires the lock only to snapshot protected paths and log
        # its final outcome.
        post_prune = run_post_prune_worktree_cleanup(result.fetch("result", {}), source: "prune")
        apply_post_prune_cleanup_result(result, post_prune)
      rescue StandardError
        release_prune_cleanup_claims(operation_id)
        raise
      end

      def completed_prune_submission(input_submission_id)
        synchronized_state do
          normalized_state.fetch("logs").reverse.find do |log|
            details = log.fetch("details", {}) || {}
            details.fetch("kind", nil) == "prune_result" &&
              details.fetch("input_submission_id", nil).to_s == input_submission_id.to_s
          end
        end
      end

      def release_prune_cleanup_claims(operation_id)
        return if blank?(operation_id)

        synchronized_state do
          state = normalized_state
          clear_prune_cleanup_claims!(state, operation_id)
          touch_state!(state)
          store.save(state)
        end
      rescue StandardError
        nil
      end

      def prepare_prune_workspace_cleanup(operation_id)
        state = normalized_state
        plan = prune_removal_plan(state)
        worker_ids = prune_plan_worker_ids(state, plan)
        now = timestamp
        worker_ids.each do |worker_id|
          worker = find_agent(state, worker_id)
          next unless worker

          metadata = worker.fetch("harness_metadata", {}) || {}
          worker["harness_metadata"] = metadata.merge(
            "prune_cleanup_claim" => prune_cleanup_claim(operation_id, now)
          )
        end
        if worker_ids.any?
          touch_state!(state, now)
          store.save(state)
        end
        { "plan" => plan, "worker_ids" => worker_ids, "state" => deep_copy(state), "claimed_at" => now }
      end

      def cleanup_prune_workspace_plan(preparation, deadline: nil)
        cleanup_pruned_worker_workspaces!(
          preparation.fetch("state"),
          preparation.fetch("worker_ids"),
          preparation.fetch("claimed_at"),
          append_logs: false,
          deadline: deadline
        )
      end

      def prune_removal_plan(state)
        delivery_refreshes = refresh_worker_delivery_pull_requests!(state)
        pull_request_checks = prune_pull_request_checks(state)
        issue_decisions = issue_prune_decisions(state, pull_request_checks)
        project_decisions = project_prune_decisions(state, issue_decisions)
        removable_project_ids = project_decisions.select { |decision| decision.fetch("prunable", false) }.map { |decision| decision.fetch("project_id") }
        {
          "delivery_refreshes" => delivery_refreshes,
          "pull_request_checks" => pull_request_checks,
          "issue_decisions" => issue_decisions,
          "project_decisions" => project_decisions,
          "removable_project_ids" => removable_project_ids,
          "removable_issue_ids" => issue_prune_roots(issue_decisions, removable_project_ids)
        }
      end

      def prune_plan_worker_ids(state, plan)
        project_issue_ids = project_issue_ids(state, plan.fetch("removable_project_ids"))
        root_ids = (plan.fetch("removable_issue_ids") + project_issue_ids).uniq
        issue_ids = root_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        state.fetch("agents").filter_map do |agent|
          agent.fetch("id", nil) if agent.fetch("type", nil) == "worker" && issue_ids.include?(agent.fetch("issue_id", nil))
        end.compact.uniq
      end

      def prepare_prune_forge_lookups
        snapshot = synchronized_state { deep_copy(normalized_state) }
        context = new_prune_forge_lookup_context
        seed_trusted_prune_pull_request_statuses!(context, snapshot)
        unless github_support_enabled?(snapshot)
          context["allow_external"] = false
          context["github_support_disabled"] = true
          return context
        end
        with_prune_forge_lookup_context(context) do
          # These are the only prune phases that can consult the forge, and they share one bounded
          # budget, so they run in the order retention actually depends on:
          #   1. the status of every pull request already recorded on an issue,
          #   2. branch discovery for settled workers whose delivery pull request is still unknown,
          #   3. exploratory verification of historical candidate URLs.
          # Running step 3 first (the old order) let a handful of stale candidate URLs, or one
          # unreachable forge call, exhaust the budget before any retention-critical lookup ran, so
          # known-merged pull requests came back `unknown` and their whole subtree was retained.
          # Running all phases on the snapshot still fills one cache, so each URL/branch is looked
          # up once per pass instead of once per phase/record.
          prune_pull_request_checks(snapshot)
          warm_prune_branch_discovery!(snapshot)
          refresh_worker_delivery_pull_requests!(snapshot)
        end
        context["allow_external"] = false
        context
      end

      def new_prune_forge_lookup_context
        budget = [prune_forge_lookup_budget, 0.0].max
        started_at = monotonic_time
        {
          "status_by_url" => {},
          "urls_by_branch" => {},
          "branch_lookup_failures" => {},
          "branch_lookup_blockers_by_issue" => {},
          "trusted_status_urls" => [],
          "external_status_urls" => [],
          "external_branch_lookups" => [],
          "unavailable_status_urls" => [],
          "budget_exhausted" => false,
          "allow_external" => true,
          "budget_seconds" => budget,
          "started_at" => started_at,
          "deadline" => started_at + budget
        }
      end

      # Prune's own state is the first source of truth for a merged pull request. Seeding the
      # per-command cache from persisted merged records means a settled record is prunable even
      # when `gh` is unavailable, and leaves the whole budget for URLs whose state can still
      # change.
      def seed_trusted_prune_pull_request_statuses!(context, state)
        cache = context.fetch("status_by_url")
        state.fetch("issues").each do |issue|
          State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).each do |record|
            status = trusted_persisted_pull_request_status(record)
            next unless status

            url = status.fetch("url")
            next if cache.key?(url)

            cache[url] = status
            context.fetch("trusted_status_urls") << url
          end
        end
        context
      end

      def trusted_persisted_pull_request_status(record)
        return nil unless record.is_a?(Hash)

        url = present_string(State::Models.pull_request_record_url(record))
        return nil if blank?(url)
        return nil unless record.fetch("provider", nil).to_s == "github"
        return nil unless PRUNE_TRUSTED_PULL_REQUEST_STATES.include?(record.fetch("state", nil).to_s)

        record.reject { |key, _value| %w[availability last_refresh_error].include?(key) }
              .merge("url" => url, "lookup_source" => "state")
      end

      # The merged delivery pull request recorded for exactly this worker branch. Used to skip
      # forge work that could only re-derive what state already proves.
      def trusted_delivery_pull_request_for_branch(issue, branch)
        normalized = normalized_branch_name(branch)
        return nil if blank?(normalized) || !issue.is_a?(Hash)

        State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).find do |record|
          next false unless trusted_persisted_pull_request_status(record)

          [record.fetch("matched_branch", nil), record.fetch("head_branch", nil)].any? do |candidate|
            normalized_branch_name(candidate) == normalized
          end
        end
      end

      # Branch discovery is the only exploratory lookup that can create a retention blocker, so it
      # gets budget priority over candidate-URL verification.
      def warm_prune_branch_discovery!(state)
        worker_agents_by_issue(state).each do |issue_id, workers|
          issue = find_issue(state, issue_id)
          next unless issue

          project = find_project(state, issue.fetch("project_id", nil))
          next unless project

          workers.each { |worker| discovered_worker_candidate_pr_urls(agent: worker, project: project, issue: issue) }
        end
      end

      def worker_agents_by_issue(state)
        state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }
             .group_by { |worker| worker.fetch("issue_id", nil) }
      end

      def with_prune_forge_lookup_context(context)
        key = prune_forge_lookup_thread_key
        previous = Thread.current[key]
        Thread.current[key] = context
        yield
      ensure
        Thread.current[key] = previous
      end

      def prune_forge_lookup_context
        Thread.current[prune_forge_lookup_thread_key]
      end

      def prune_forge_lookup_thread_key
        @prune_forge_lookup_thread_key ||= "meringue-prune-forge-#{object_id}"
      end

      def prune_forge_lookup_remaining(context)
        [context.fetch("deadline", monotonic_time) - monotonic_time, 0.0].max
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # A head may propose `/recount` for itself. The head that is applying the batch is not an
      # "in flight" head for this purpose: its own commands are what asked for the renumber, and
      # Recount never renames head ids. Any other live head still blocks the pass.
      def recount(command_id, command_type, payload = {})
        state = normalized_state
        proposing_head_id = present_string(value_at(payload, "_head_id", "head_id", "HeadID", "headId"))
        active_head_ids = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "head" }
                               .map { |agent| agent.fetch("id") }
                               .reject { |head_id| head_id == proposing_head_id }
        if active_head_ids.any?
          return rejected_result(
            command_id,
            command_type,
            "AgentTree IDs were not recounted because a head result is still in flight.",
            ["active_heads", *active_head_ids]
          )
        end
        now = timestamp
        begin
          mappings = State::Recounter.recount!(state)
        rescue State::Recounter::UnrecountableStateError => e
          # Recount validates on a copy, so a refusal never touches the state file. An
          # inconsistency the user has to repair is reported with the recounter's own
          # explanation instead of surfacing as `KeyError: key not found: "P1-I1"`.
          return rejected_result(command_id, command_type, e.message, ["recount_refused"])
        end
        changed_count = mappings.values.sum(&:length)
        state.fetch("metadata")["last_recount"] = {
          "recounted_at" => now,
          "changed_id_count" => changed_count,
          "mappings" => mappings
        }
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: "Recounted AgentTree IDs; renamed #{changed_count} record#{changed_count == 1 ? "" : "s"}.",
          details: {
            "changed_id_count" => changed_count,
            "mappings" => mappings,
            "unchanged_id_types" => %w[head log conversation_message harness_session workspace]
          }
        )
        touch_state!(state, now)
        # The rename covers every section of the document, including the routing ids stored on
        # persisted chat messages and the ids embedded in their text. The default save merges the
        # on-disk chat buffer back over the in-memory one (persisted wins per message id), which
        # would silently restore pre-recount ids that now name different records, so this write owns
        # the whole snapshot. It is safe because Recount holds the state lock for the read and the
        # write. The TUI reloads the buffer when it sees the accepted result, so its own in-memory
        # copy cannot write those ids back either.
        store.save(state, preserve_log_buffer: false)

        accepted_result(
          command_id,
          command_type,
          nil,
          "Recounted AgentTree IDs; renamed #{changed_count} record#{changed_count == 1 ? "" : "s"}.",
          {
            "changed_id_count" => changed_count,
            "mappings" => mappings,
            "counters" => deep_copy(state.fetch("counters"))
          },
          log_ids
        )
      end

      # One prune pass over the whole tree. Eligibility is shared by resolved and errored
      # records: an issue subtree must be free of nonterminal issues, queued/working/blocked
      # workers, open questions, and unsettled pull requests, and a project is removed only when
      # it is terminal with every contained issue eligible. Standalone errored heads are removed
      # in the same pass. Managed worktree cleanup is attempted before worker records leave state,
      # but a cleanup failure never changes logical eligibility: the unsafe worktree is preserved
      # and its structured outcome is reported for manual/future cleanup.
      def prune_records(command_id, command_type, prepared_plan: nil,
                        prepared_workspace_cleanups: nil, prune_operation_id: nil,
                        input_submission_id: nil, timings: nil)
        state = normalized_state
        current_plan = prune_removal_plan(state)
        delivery_refreshes = current_plan.fetch("delivery_refreshes")
        pull_request_checks = current_plan.fetch("pull_request_checks")
        issue_decisions = current_plan.fetch("issue_decisions")
        project_decisions = current_plan.fetch("project_decisions")
        removable_project_ids = current_plan.fetch("removable_project_ids")
        removable_issue_ids = current_plan.fetch("removable_issue_ids")
        if prepared_plan
          # State may advance while cleanup runs. Never widen a pass after its cleanup safety set was
          # captured; newly eligible records wait for the next prune. Records that ceased to be
          # eligible are retained by intersecting with the freshly recomputed plan.
          removable_project_ids &= Array(prepared_plan.fetch("removable_project_ids", []))
          removable_issue_ids &= Array(prepared_plan.fetch("removable_issue_ids", []))
        end
        errored_head_ids = state.fetch("agents").select do |agent|
          agent.fetch("type", nil) == "head" && agent.fetch("status", nil) == "errored" &&
            !agent.fetch("prune_protected", false) && !head_applying_batch?(agent)
        end.map { |agent| agent.fetch("id") }
        now = timestamp
        prune_result = remove_issue_bundles_and_agents!(
          state,
          issue_ids: removable_issue_ids,
          project_ids: removable_project_ids,
          extra_agent_ids: errored_head_ids,
          reason: "prune",
          now: now,
          remove_empty_projects: false,
          cleanup_worker_workspaces: prepared_workspace_cleanups.nil?,
          prepared_workspace_cleanups: prepared_workspace_cleanups
        )
        checked_urls = pull_request_checks.flat_map { |check| check.fetch("statuses", []).map { |status| status.fetch("url", nil) } }.compact.uniq
        blocked_urls = issue_decisions.flat_map do |decision|
          decision.fetch("pull_request_blockers", []).map { |status| status.fetch("url", nil) }
        end.compact.uniq
        forge_lookup = prune_forge_lookup_summary
        retention = prune_retention_summary(issue_decisions, prune_result, forge_lookup)
        message = ([prune_summary_message(prune_result)] + retention.fetch("sentences")).join(" ")
        details = prune_result.merge(
          "kind" => "prune_result",
          "input_submission_id" => input_submission_id,
          "checked_pr_urls" => checked_urls,
          "blocked_pr_urls" => blocked_urls,
          "pull_request_checks" => pull_request_checks,
          "issue_decisions" => issue_decisions,
          "project_decisions" => project_decisions,
          "delivery_pull_request_refreshes" => delivery_refreshes,
          "retained_issue_ids" => retention.fetch("retained_issue_ids"),
          "retention_reasons" => retention.fetch("reasons"),
          "forge_lookup" => forge_lookup,
          "timings" => timings
        ).compact
        log_ids = prune_result.fetch("workspace_cleanup_log_entry_ids", []).dup
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: retention.fetch("level"),
          message: message,
          details: details
        ))
        clear_prune_cleanup_claims!(state, prune_operation_id)
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, nil, message, details, log_ids)
      end

      # After a prune pass commits, retry worktrees it could not remove within the bounded cleanup
      # budget. The same manager safety path still refuses dirty, locked, mismatched, or actively
      # referenced worktrees. This method runs without an outer state lock; it holds the lock only
      # for the current protected-path snapshot and the final durable outcome log.
      def run_post_prune_worktree_cleanup(prune_result, source:)
        blocked = post_prune_blocked_cleanups(prune_result)
        return nil if blocked.empty?

        started_at = monotonic_time
        deadline = started_at + [post_prune_cleanup_budget, 0.0].max
        exclude_agent_ids = blocked.filter_map { |outcome| present_string(outcome["agent_id"]) }
        protected_paths = synchronized_state do
          current_workspace_protected_paths(normalized_state, exclude_agent_ids: exclude_agent_ids)
        end
        retry_outcomes = blocked.map do |outcome|
          retry_blocked_worktree_cleanup(outcome, protected_paths: protected_paths, deadline: deadline)
        end
        # Clear dangling registrations for any git root we touched. `git worktree prune` only
        # removes administrative files for worktrees whose directories are already gone, so it is
        # safe to run unconditionally and never affects a live worktree.
        retry_outcomes.filter_map { |outcome| present_string(outcome["git_root"]) }.uniq.each do |git_root|
          workspace_manager.prune_dangling_worktrees(git_root)
        end
        synchronized_state do
          state = normalized_state
          summary = post_prune_cleanup_summary(retry_outcomes)
          log_ids = append_post_prune_cleanup_log(state, retry_outcomes, summary: summary, source: source)
          touch_state!(state)
          store.save(state)
          { "outcomes" => retry_outcomes, "log_entry_ids" => log_ids, "summary" => summary }
        end
      end

      def apply_post_prune_cleanup_result(result, post_prune)
        return result unless post_prune

        updated = deep_copy(result)
        summary = post_prune.fetch("summary")
        updated["message"] = append_post_prune_cleanup_message(updated.fetch("message", ""), summary)
        updated["result"] = updated.fetch("result", {}).merge(
          "post_prune_cleanup" => {
            "summary" => summary,
            "outcomes" => post_prune.fetch("outcomes", [])
          }
        )
        updated["log_entry_ids"] = (
          Array(updated.fetch("log_entry_ids", [])) + Array(post_prune.fetch("log_entry_ids", []))
        ).uniq
        updated
      end

      # Only genuine cleanup failures are revisited. Skipped workspaces (project root, shared
      # checkout, handed-over worktree) and successful cleanups are already settled by the pass.
      def post_prune_blocked_cleanups(prune_result)
        Array(prune_result.fetch("workspace_cleanup_outcomes", [])).select do |outcome|
          outcome.fetch("success", false) == false && outcome.fetch("status", "failed") != "skipped"
        end
      end

      def retry_blocked_worktree_cleanup(outcome, protected_paths:, deadline:)
        worktree_root = present_string(outcome["worktree_root_path"])
        branch = present_string(outcome["workspace_branch"])
        git_root = present_string(outcome["git_root"])
        agent_id = present_string(outcome["agent_id"])
        original_reason = outcome.fetch("reason", "unknown")
        base = {
          "agent_id" => agent_id,
          "issue_id" => outcome["issue_id"],
          "project_id" => outcome["project_id"],
          "original_reason" => original_reason,
          "worktree_root_path" => worktree_root,
          "workspace_branch" => branch,
          "git_root" => git_root,
          "workspace_owner_id" => outcome["workspace_owner_id"],
          "requested_worktree_provider" => outcome["requested_worktree_provider"],
          "worktree_provider" => outcome["worktree_provider"],
          "worktree_provider_identifier" => outcome["worktree_provider_identifier"],
          "worktree_provider_cwd" => outcome["worktree_provider_cwd"],
          "project_root" => outcome["project_root"],
          "post_prune_retry" => true
        }.compact

        unless worktree_root && branch && git_root
          return base.merge("status" => "failed", "reason" => "cleanup_blocked_missing_path",
                            "success" => false, "attempted" => false)
        end

        record = {
          "strategy" => "git_worktree",
          "worktree_root_path" => worktree_root,
          "workspace_branch" => branch,
          "git_root" => git_root,
          "workspace_owner_id" => outcome["workspace_owner_id"] || agent_id,
          "requested_worktree_provider" => outcome["requested_worktree_provider"],
          "worktree_provider" => outcome["worktree_provider"],
          "worktree_provider_identifier" => outcome["worktree_provider_identifier"],
          "worktree_provider_cwd" => outcome["worktree_provider_cwd"],
          "project_root" => outcome["project_root"]
        }.compact
        method = workspace_manager.method(:cleanup_pruned_worker_workspace)
        options = { protected_paths: protected_paths }
        options[:deadline] = deadline if method.parameters.any? { |(kind, name)| kind == :keyrest || name == :deadline }
        retry_outcome = begin
          method.call(record, **options)
        rescue StandardError => e
          {
            "status" => "failed",
            "reason" => "worktree_cleanup_error",
            "success" => false,
            "attempted" => false,
            "error" => sanitized_error_message(e)
          }
        end
        base.merge(retry_outcome)
      end

      def current_workspace_protected_paths(state, exclude_agent_ids: [])
        excluded = Array(exclude_agent_ids).compact
        state.fetch("agents", []).filter_map do |other|
          next unless other.fetch("type", nil) == "worker"
          next if excluded.any? { |id| Ids.same?(id, other.fetch("id", nil)) }
          next if worker_workspace_handed_over?(state, other)
          worker_worktree_root_path(other)
        end
      end

      def post_prune_cleanup_summary(outcomes)
        removed = outcomes.select { |outcome| outcome.fetch("success", false) && outcome.fetch("status", nil) == "removed" }
        already_removed = outcomes.select { |outcome| outcome.fetch("success", false) && outcome.fetch("status", nil) == "already_removed" }
        retained = outcomes.reject { |outcome| outcome.fetch("success", false) }
        {
          "removed_count" => removed.length,
          "already_removed_count" => already_removed.length,
          "retained_count" => retained.length,
          "removed_agent_ids" => removed.filter_map { |outcome| present_string(outcome["agent_id"]) },
          "retained" => retained.map do |outcome|
            {
              "agent_id" => outcome.fetch("agent_id", nil),
              "reason" => outcome.fetch("reason", "unknown"),
              "original_reason" => outcome.fetch("original_reason", nil)
            }.compact
          end,
          "level" => retained.any? ? "warning" : "info"
        }
      end

      def post_prune_cleanup_log_message(summary, source:)
        removed = summary.fetch("removed_count")
        retained = summary.fetch("retained_count")
        parts = []
        if removed.positive?
          parts << "Post-prune cleanup removed #{count_phrase(removed, "worktree")} the #{source} pass left behind"
        end
        if retained.positive?
          listed = Array(summary.fetch("retained")).first(PRUNE_RETENTION_REPORT_LIMIT).map do |item|
            "#{item.fetch("agent_id", "worker")} (#{item.fetch("reason", "unknown")})"
          end
          remainder = retained - listed.length
          listed << "and #{remainder} more" if remainder.positive?
          parts << "retained #{count_phrase(retained, "worktree")} because cleanup was not safe: #{listed.join(", ")}"
        end
        parts.empty? ? "Post-prune cleanup found nothing to revisit." : "#{parts.join("; ")}."
      end

      def append_post_prune_cleanup_log(state, outcomes, summary:, source:)
        append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: summary.fetch("level"),
          message: post_prune_cleanup_log_message(summary, source: source),
          details: {
            "kind" => "post_prune_cleanup",
            "source" => source,
            "outcomes" => outcomes,
            "summary" => summary
          }
        )
      end

      # The prune summary line already reports what the pass removed and retained. Append a
      # post-prune sentence only when the retry actually removed worktrees the pass left
      # behind, so a pass that retains everything (the dirty/locked safety refusals) reads exactly
      # as before while a pass that recovers previously-blocked worktrees advertises the recovery.
      def append_post_prune_cleanup_message(message, summary)
        removed = summary.fetch("removed_count")
        return message unless removed.positive?
        retained = summary.fetch("retained_count")
        suffix = "Post-prune cleanup removed #{count_phrase(removed, "worktree")} the pass left behind"
        if retained.positive?
          listed = Array(summary.fetch("retained")).first(PRUNE_RETENTION_REPORT_LIMIT).map do |item|
            "#{item.fetch("agent_id", "worker")} (#{item.fetch("reason", "unknown")})"
          end
          remainder = retained - listed.length
          listed << "and #{remainder} more" if remainder.positive?
          suffix += "; retained #{count_phrase(retained, "worktree")} because cleanup was not safe: #{listed.join(", ")}"
        end
        "#{message} #{suffix}."
      end

      # One prune pass is one visible line. The counts cover every record class the pass touched:
      # issues, *every* agent record removed with them (workers bundled with an issue plus
      # standalone/head records, not just the standalone ones), the managed worktrees actually
      # removed, and projects. Counting only standalone agents used to report "0 standalone agents"
      # for a pass that had just deleted five workers and their worktrees, while the worktree
      # removals printed one info line each.
      def prune_summary_message(prune_result, prefix: "Pruned")
        issues, agents, worktrees, projects = prune_count_phrases(prune_result)
        "#{prefix} #{issues}, #{agents}, #{worktrees}, and #{projects}."
      end

      def prune_count_phrases(prune_result)
        prune_removed_counts(prune_result).map { |noun, count| count_phrase(count, noun) }
      end

      def prune_removed_counts(prune_result)
        {
          "issue" => Array(prune_result.fetch("removed_issue_ids", [])).length,
          "agent" => Array(prune_result.fetch("removed_agent_ids", [])).length,
          "worktree" => removed_worktree_agent_ids(prune_result).length,
          "project" => Array(prune_result.fetch("removed_project_ids", [])).length
        }
      end

      # Only worktrees this pass actually deleted are counted. `already_removed` is a confirmation,
      # not a removal, and `skipped` workspaces (project root, dedicated directory) were never
      # Meringue-managed worktrees.
      def removed_worktree_agent_ids(prune_result)
        recorded = prune_result.fetch("removed_worktree_agent_ids", nil)
        return Array(recorded) if recorded

        Array(prune_result.fetch("workspace_cleanup_outcomes", [])).filter_map do |outcome|
          outcome.fetch("agent_id", nil) if outcome.fetch("status", nil) == "removed"
        end
      end

      # Retention must never look like a silent no-op. Nonterminal issues, queued/working/blocked
      # workers, and open questions are all visible in the AgentTree, so the summary spells out the
      # reasons the user cannot otherwise see: a pull request status Meringue could not verify, and
      # a managed worktree it refused to remove. Cleanup failures do not retain eligible records;
      # they produce a warning while the failed worktree remains available for manual cleanup.
      def prune_retention_summary(issue_decisions, prune_result, forge_lookup)
        reasons = Array(issue_decisions).reject { |decision| decision.fetch("prunable", false) }.map do |decision|
          pull_request_blockers = Array(decision.fetch("pull_request_blockers", []))
          unverified, unsettled = pull_request_blockers.partition { |status| status.fetch("state", nil).to_s == "unknown" }
          {
            "issue_id" => decision.fetch("issue_id", nil),
            "blockers" => Array(decision.fetch("blockers", [])),
            "unverified_pr_urls" => unverified.filter_map { |status| status.fetch("url", nil) }.uniq,
            "open_pr_urls" => unsettled.filter_map { |status| status.fetch("url", nil) }.uniq,
            "nonterminal_issue_ids" => Array(decision.fetch("nonterminal_issue_ids", [])),
            "blocking_worker_ids" => Array(decision.fetch("blocking_worker_ids", [])),
            "protected_agent_ids" => Array(decision.fetch("protected_agent_ids", [])),
            "open_question_ids" => Array(decision.fetch("open_question_ids", [])),
            "workspace_cleanup_blocking_agent_ids" => Array(decision.fetch("workspace_cleanup_blocking_agent_ids", [])),
            "live_successor_worker_ids" => Array(decision.fetch("live_successor_worker_ids", []))
          }
        end
        # A running successor can live on another issue, so this retention is not visible in the
        # subtree the user is looking at. Name it like the other invisible reasons.
        successor_retentions = reasons.reject { |reason| reason.fetch("live_successor_worker_ids").empty? }
        unverified_issue_ids = reasons.select { |reason| reason.fetch("unverified_pr_urls").any? }
                                     .filter_map { |reason| reason.fetch("issue_id") }
        blocked_cleanups = Array(prune_result.fetch("workspace_cleanup_outcomes", []))
                           .reject { |outcome| outcome.fetch("success", false) }
        sentences = []
        if unverified_issue_ids.any?
          sentences << "Retained #{count_phrase(unverified_issue_ids.length, "issue")} because Meringue could not " \
                       "verify their pull request status: #{id_list_phrase(unverified_issue_ids)}" \
                       "#{prune_forge_lookup_clause(forge_lookup)}."
        end
        protected_retentions = reasons.reject { |reason| reason.fetch("protected_agent_ids", []).empty? }
        unless protected_retentions.empty?
          ids = protected_retentions.flat_map { |reason| reason.fetch("protected_agent_ids", []) }.uniq
          sentences << "Retained #{count_phrase(protected_retentions.length, "issue")} because protected agents must remain: #{id_list_phrase(ids)}."
        end
        if successor_retentions.any?
          listed = successor_retentions.first(PRUNE_RETENTION_REPORT_LIMIT).map do |reason|
            "#{reason.fetch("issue_id")} (still needed by #{id_list_phrase(reason.fetch("live_successor_worker_ids"))})"
          end
          remainder = successor_retentions.length - listed.length
          listed << "and #{remainder} more" if remainder.positive?
          sentences << "Retained #{count_phrase(successor_retentions.length, "issue")} because a worker that " \
                       "continues their work is still running: #{listed.join(", ")}."
        end
        if blocked_cleanups.any?
          listed = blocked_cleanups.first(PRUNE_RETENTION_REPORT_LIMIT).map do |outcome|
            "#{outcome.fetch("agent_id", "worker")} (#{outcome.fetch("reason", "unknown_error")})"
          end
          remainder = blocked_cleanups.length - listed.length
          listed << "and #{remainder} more" if remainder.positive?
          sentences << "Preserved #{count_phrase(blocked_cleanups.length, "managed worktree")} because cleanup was not safe: " \
                       "#{listed.join(", ")}."
        end

        {
          "retained_issue_ids" => reasons.filter_map { |reason| reason.fetch("issue_id") },
          "reasons" => reasons,
          "unverified_issue_ids" => unverified_issue_ids,
          "sentences" => sentences,
          "level" => unverified_issue_ids.any? || blocked_cleanups.any? ? "warning" : "info"
        }
      end

      def prune_forge_lookup_clause(forge_lookup)
        return "" unless forge_lookup.is_a?(Hash)
        if forge_lookup.fetch("github_support_disabled", false)
          return " (GitHub support is disabled; re-enable it in Settings → Experiments to refresh pull request status)"
        end

        if forge_lookup.fetch("budget_exhausted", false)
          " (the #{format_seconds(forge_lookup.fetch("budget_seconds", prune_forge_lookup_budget))}s forge lookup " \
            "budget was exhausted)"
        else
          " (the forge lookup was unavailable)"
        end
      end

      def format_seconds(value)
        format("%g", Float(value))
      rescue ArgumentError, TypeError
        value.to_s
      end

      def count_phrase(count, noun)
        "#{count} #{noun}#{count == 1 ? "" : "s"}"
      end

      def id_list_phrase(ids)
        listed = Array(ids).first(PRUNE_RETENTION_REPORT_LIMIT)
        remainder = Array(ids).length - listed.length
        listed = listed + ["and #{remainder} more"] if remainder.positive?
        listed.join(", ")
      end

      # Observability for the bounded lookup phase: how much of the budget the pass used, how many
      # external lookups it actually made, which URLs came from state instead of the forge, and
      # which ones the forge could not answer.
      def prune_forge_lookup_summary
        context = prune_forge_lookup_context
        return nil unless context

        started_at = context.fetch("started_at", monotonic_time)
        {
          "budget_seconds" => context.fetch("budget_seconds", prune_forge_lookup_budget),
          "elapsed_seconds" => (monotonic_time - started_at).round(3),
          "remaining_seconds" => prune_forge_lookup_remaining(context).round(3),
          "budget_exhausted" => context.fetch("budget_exhausted", false),
          "github_support_disabled" => context.fetch("github_support_disabled", false),
          "status_lookup_count" => context.fetch("external_status_urls", []).length,
          "branch_lookup_count" => context.fetch("external_branch_lookups", []).length,
          "trusted_from_state_urls" => context.fetch("trusted_status_urls", []).uniq,
          "unavailable_urls" => context.fetch("unavailable_status_urls", []).uniq
        }
      end
    end
  end
end
