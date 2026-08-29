# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # The delivery pull request an issue is judged by: discovering it, refreshing its status from
      # the forge, and deciding whether it is settled.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Refresh only already-verified delivery PRs. Candidate/reported URLs remain inert, and an
      # unavailable forge never replaces the last known open/closed/merged state. /prune still
      # performs its own authoritative checks and therefore keeps its conservative rules.
      #
      # This runs on every ~2s reconcile tick, so it must never behave like a batch job. The same
      # rule `/prune` follows applies here and matters more, because nothing asked for this work:
      # read which URLs are due under the lock, talk to the forge with the lock released, then
      # reacquire it to merge. Holding the state lock across `gh` froze every kernel command
      # (submitting a prompt, applying a HeadResult, settling a worker) for the length of the
      # whole burst.
      def refresh_stale_delivery_pull_requests
        return [] unless github_support_enabled?
        # Capped so a long backlog costs several cheap ticks instead of one long stall.
        due_urls = due_delivery_pull_request_urls.first(DELIVERY_PULL_REQUEST_REFRESH_BATCH_LIMIT)
        return [] if due_urls.empty?

        statuses = fetch_delivery_pull_request_statuses(due_urls)
        return [] if statuses.empty?

        apply_delivery_pull_request_statuses(statuses)
      end

      # Locked, cheap, and read-only: which verified delivery PR URLs are due right now.
      def due_delivery_pull_request_urls
        synchronized_state do
          now = timestamp
          normalized_state.fetch("issues").flat_map do |issue|
            State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).filter_map do |record|
              url = present_string(State::Models.pull_request_record_url(record))
              next if blank?(url) || !delivery_pull_request_refresh_due?(record, now)

              url
            end
          end.uniq
        end
      end

      # Unlocked and bounded. One shared deadline covers the whole batch, so an unreachable forge
      # costs one budget instead of one timeout per URL. URLs left over when the budget runs out are
      # simply not refreshed this tick; they stay due and are retried on a later tick.
      def fetch_delivery_pull_request_statuses(urls)
        deadline = monotonic_time + [delivery_pull_request_refresh_budget, 0.0].max
        urls.each_with_object({}) do |url, statuses|
          remaining = deadline - monotonic_time
          break statuses unless remaining.positive?

          statuses[url] = delivery_pull_request_status(url, timeout: remaining)
        end
      end

      # A raising lookup is answered as `unknown` rather than aborting the batch. The apply phase
      # already treats `unknown` as "forge unavailable, keep the last known state", and stamping
      # `last_checked_at` is what stops one permanently broken URL from occupying a batch slot on
      # every tick and starving the records behind it.
      def delivery_pull_request_status(url, timeout:)
        invoke_forge_status_lookup(url, timeout: timeout)
      rescue StandardError => e
        {
          "provider" => "github",
          "url" => url.to_s,
          "state" => "unknown",
          "error" => sanitized_error_message(e)
        }
      end

      # Locked again, and against current state rather than the snapshot the URLs came from: an
      # issue pruned or a record replaced during the forge call is simply skipped.
      def apply_delivery_pull_request_statuses(statuses)
        synchronized_state do
          state = normalized_state
          now = timestamp
          refreshes = state.fetch("issues").flat_map do |issue|
            State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).filter_map do |record|
              url = present_string(State::Models.pull_request_record_url(record))
              next if blank?(url) || !statuses.key?(url)

              status = statuses.fetch(url)
              unavailable = status.fetch("state", nil).to_s == "unknown"
              refreshed = if unavailable
                            record.merge(
                              "availability" => "unavailable",
                              "last_checked_at" => now,
                              "last_refresh_error" => present_string(status.fetch("error", nil))
                            ).compact
                          else
                            # The nil must survive `.compact` and the record merge inside
                            # `attach_pull_requests_to_issue!`; dropping the key instead left the
                            # previous failure attached to a record the forge just answered.
                            record.merge(status).merge(
                              "availability" => "available",
                              "last_checked_at" => now
                            ).compact.merge("last_refresh_error" => nil)
                          end
              State::Models.attach_pull_requests_to_issue!(issue, delivery_pull_requests: [refreshed])
              {
                "issue_id" => issue.fetch("id", nil),
                "url" => url,
                "state" => refreshed.fetch("state", "unknown"),
                "availability" => refreshed.fetch("availability"),
                "changed" => refreshed != record
              }.compact
            end
          end
          if refreshes.any? { |refresh| refresh.fetch("changed", false) }
            touch_state!(state, now)
            store.save(state)
          end
          refreshes
        end
      end

      def delivery_pull_request_refresh_due?(record, now)
        checked_at = record.is_a?(Hash) && (record["last_checked_at"] || record["verified_at"])
        return true if blank?(checked_at)

        Time.iso8601(now) - Time.iso8601(checked_at.to_s) >= delivery_pull_request_refresh_interval(record)
      rescue ArgumentError, TypeError
        true
      end

      # Records refreshed together are stamped with the same `last_checked_at`, so a fixed interval
      # makes them all fall due on the same tick forever: one synchronized burst every interval
      # instead of a trickle. A deterministic per-URL spread keeps each record on its own schedule
      # without storing extra scheduling state.
      def delivery_pull_request_refresh_interval(record)
        url = record.is_a?(Hash) ? State::Models.pull_request_record_url(record).to_s : ""
        DELIVERY_PULL_REQUEST_REFRESH_INTERVAL_SECONDS +
          (Zlib.crc32(url) % DELIVERY_PULL_REQUEST_REFRESH_SPREAD_SECONDS)
      end

      def refresh_worker_delivery_pull_requests!(state)
        return [] unless github_support_enabled?(state)

        workers_by_issue = worker_agents_by_issue(state)
        state.fetch("issues").flat_map do |issue|
          workers = workers_by_issue.fetch(issue.fetch("id", nil), [])
          project = find_project(state, issue.fetch("project_id", nil))
          next [] unless project

          candidate_urls = (
            Array(issue.fetch("candidate_pr_urls", nil)) +
            workers.flat_map { |worker| discovered_worker_candidate_pr_urls(agent: worker, project: project, issue: issue) }
          ).map(&:to_s).map(&:strip).reject(&:empty?).uniq
          next [] if candidate_urls.empty?

          matches = workers.flat_map do |worker|
            # This worker's branch already has a merged delivery pull request attached to the issue.
            # Re-verifying every historical candidate URL against it cannot change the record and
            # would spend forge budget that unknown deliveries need.
            next [] if trusted_delivery_pull_request_for_branch(issue, persisted_worker_delivery_branch(worker))

            verified_worker_pull_requests(agent: worker, project: project, candidate_urls: candidate_urls).map do |pull_request|
              [worker, pull_request]
            end
          end
          if matches.empty?
            matches = workers.filter_map do |worker|
              pull_request = merged_same_repo_candidate_pull_request(agent: worker, project: project, candidate_urls: candidate_urls)
              [worker, pull_request] if pull_request
            end
          end
          matches = matches.uniq { |_worker, pull_request| pull_request.fetch("url", nil) }
          next [] if matches.empty?

          matches.map do |matched_worker, delivery_pull_request|
            attach_issue_pull_requests!(issue, delivery_pull_request, candidate_urls)

            {
              "agent_id" => matched_worker.fetch("id", nil),
              "issue_id" => issue.fetch("id", nil),
              "url" => delivery_pull_request.fetch("url", nil),
              "matched_by" => delivery_pull_request.fetch("matched_by", nil)
            }.compact
          end
        end
      end

      def prune_pull_request_checks(state)
        workers_by_issue = worker_agents_by_issue(state)
        state.fetch("issues").filter_map do |issue|
          urls = issue_pr_urls(issue).uniq
          next if urls.empty?

          {
            "issue_id" => issue.fetch("id", nil),
            "pr_urls" => urls,
            "statuses" => urls.map { |url| pull_request_status(url) }
          }
        end
      end

      def issue_prune_decisions(state, pull_request_checks)
        checks_by_issue = pull_request_checks.to_h { |check| [check.fetch("issue_id", nil), check] }
        state.fetch("issues").map do |issue|
          subtree_ids = issue_subtree_ids(state, issue.fetch("id"))
          subtree_issues = state.fetch("issues").select { |candidate| subtree_ids.include?(candidate.fetch("id", nil)) }
          workers = state.fetch("agents").select do |agent|
            agent.fetch("type", nil) == "worker" && subtree_ids.include?(agent.fetch("issue_id", nil))
          end
          blocking_workers = workers.select { |worker| PRUNE_BLOCKING_WORKER_STATUSES.include?(worker.fetch("status", nil).to_s) }
          protected_agents = state.fetch("agents").select do |agent|
            agent.fetch("prune_protected", false) && subtree_ids.include?(agent.fetch("issue_id", nil))
          end
          cleanup_claimed_workers = workers.select { |worker| worker_prune_cleanup_claimed?(worker) }
          open_questions = state.fetch("questions").select do |question|
            question.fetch("status", nil) == "open" && subtree_ids.include?(question.fetch("issue_id", nil))
          end
          statuses = subtree_ids.flat_map { |issue_id| Array(checks_by_issue.dig(issue_id, "statuses")) }
          discovery_blockers = subtree_ids.flat_map do |issue_id|
            Array(prune_forge_lookup_context&.dig("branch_lookup_blockers_by_issue", issue_id))
          end
          pull_request_blockers = (statuses + discovery_blockers).reject do |status|
            PRUNE_SETTLED_PULL_REQUEST_STATES.include?(status.fetch("state", nil).to_s)
          end
          nonterminal_issue_ids = subtree_issues.reject do |candidate|
            PRUNE_ELIGIBLE_STATUSES.include?(candidate.fetch("status", nil).to_s)
          end.map { |candidate| candidate.fetch("id") }
          # A predecessor must outlive its queue: removing it here would leave a queued dependent
          # (possibly on another issue) with nothing to wait for. The same applies to a completed
          # worker whose completion still has a head-routing continuation to fire.
          deferred_dependents = waiting_deferred_dependents(state, workers.map { |worker| worker.fetch("id", nil) })
          # A settled predecessor also outlives a successor that has already *started*. Because a
          # follow-up now normally continues in a fresh session, the predecessor's record is the
          # only thing still naming the report and lineage behind the work in flight, and it may
          # own the checkout that successor is writing. Retaining it keeps that readable until the
          # successor settles too.
          live_successors = live_worker_successors(state, workers.map { |worker| worker.fetch("id", nil) })
          completion_continuations = workers.select { |worker| pending_completion_continuation?(worker) }
          # A live goal loop is retained work: pruning its issue would delete the loop, its
          # iteration history, and the worktrees it is still measuring.
          active_goals = goals_for_issue_ids(state, subtree_ids).select { |goal| Goals::Record.loop_active?(goal) }
          blockers = []
          blockers << "nonterminal_issues" if nonterminal_issue_ids.any?
          blockers << "unresolved_workers" if blocking_workers.any?
          blockers << "protected_agents" if protected_agents.any?
          blockers << "workspace_cleanup_in_progress" if cleanup_claimed_workers.any?
          blockers << "open_questions" if open_questions.any?
          blockers << "unsettled_pull_requests" if pull_request_blockers.any?
          blockers << "pending_deferred_dependents" if deferred_dependents.any?
          blockers << "live_successor_workers" if live_successors.any?
          blockers << "pending_completion_continuations" if completion_continuations.any?
          blockers << "active_goals" if active_goals.any?

          {
            "issue_id" => issue.fetch("id"),
            "project_id" => issue.fetch("project_id", nil),
            "parent_issue_id" => issue.fetch("parent_issue_id", nil),
            "subtree_issue_ids" => subtree_ids,
            "prunable" => blockers.empty?,
            "blockers" => blockers,
            "nonterminal_issue_ids" => nonterminal_issue_ids,
            "blocking_worker_ids" => blocking_workers.map { |worker| worker.fetch("id", nil) }.compact,
            "protected_agent_ids" => protected_agents.map { |agent| agent.fetch("id", nil) }.compact,
            "workspace_cleanup_claimed_worker_ids" => cleanup_claimed_workers.map { |worker| worker.fetch("id", nil) }.compact,
            "deferred_dependent_worker_ids" => deferred_dependents.map { |dependent| dependent.fetch("id", nil) }.compact,
            "live_successor_worker_ids" => live_successors.map { |successor| successor.fetch("id", nil) }.compact,
            "completion_continuation_worker_ids" => completion_continuations.map { |worker| worker.fetch("id", nil) }.compact,
            "open_question_ids" => open_questions.map { |question| question.fetch("id", nil) }.compact,
            "active_goal_ids" => active_goals.map { |goal| goal.fetch("id", nil) }.compact,
            "pull_request_blockers" => pull_request_blockers,
            "pr_urls" => subtree_ids.flat_map { |issue_id| Array(checks_by_issue.dig(issue_id, "pr_urls")) }.uniq
          }
        end
      end

      def project_prune_decisions(state, issue_decisions)
        decisions_by_issue = issue_decisions.to_h { |decision| [decision.fetch("issue_id"), decision] }
        state.fetch("projects").map do |project|
          issue_ids = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }.map { |issue| issue.fetch("id") }
          blocking_workers = state.fetch("agents").select do |agent|
            agent.fetch("type", nil) == "worker" &&
              agent.fetch("project_id", nil) == project.fetch("id") &&
              PRUNE_BLOCKING_WORKER_STATUSES.include?(agent.fetch("status", nil).to_s)
          end
          open_questions = state.fetch("questions").select do |question|
            question.fetch("status", nil) == "open" && question.fetch("project_id", nil) == project.fetch("id")
          end
          protected_agents = state.fetch("agents").select do |agent|
            agent.fetch("prune_protected", false) && agent.fetch("project_id", nil) == project.fetch("id")
          end
          ineligible_issue_ids = issue_ids.reject { |issue_id| decisions_by_issue.fetch(issue_id).fetch("prunable", false) }
          blockers = []
          blockers << "project_not_terminal" unless PRUNE_ELIGIBLE_STATUSES.include?(project.fetch("status", nil).to_s)
          blockers << "ineligible_issues" if ineligible_issue_ids.any?
          blockers << "unresolved_workers" if blocking_workers.any?
          blockers << "protected_agents" if protected_agents.any?
          blockers << "open_questions" if open_questions.any?

          {
            "project_id" => project.fetch("id"),
            "issue_ids" => issue_ids,
            "prunable" => blockers.empty?,
            "blockers" => blockers,
            "ineligible_issue_ids" => ineligible_issue_ids,
            "blocking_worker_ids" => blocking_workers.map { |worker| worker.fetch("id", nil) }.compact,
            "protected_agent_ids" => protected_agents.map { |agent| agent.fetch("id", nil) }.compact,
            "open_question_ids" => open_questions.map { |question| question.fetch("id", nil) }.compact
          }
        end
      end

      def issue_prune_roots(issue_decisions, removable_project_ids)
        eligible_issue_ids = issue_decisions.select { |decision| decision.fetch("prunable", false) }.map { |decision| decision.fetch("issue_id") }
        issue_decisions.filter_map do |decision|
          next unless decision.fetch("prunable", false)
          next if removable_project_ids.include?(decision.fetch("project_id", nil))
          next if eligible_issue_ids.include?(decision.fetch("parent_issue_id", nil))

          decision.fetch("issue_id")
        end
      end

      def verified_worker_pull_request(agent:, project:, candidate_urls:)
        verified_worker_pull_requests(agent: agent, project: project, candidate_urls: candidate_urls).first
      end

      def verified_worker_pull_requests(agent:, project:, candidate_urls:)
        return [] unless github_support_enabled?

        branch = worker_delivery_branch(agent)
        return [] if blank?(branch)

        project_repository = project && project_github_repository(project)
        return [] if blank?(project_repository)

        Array(candidate_urls).filter_map do |url|
          status = pull_request_status(url)
          next unless verified_worker_pull_request?(status, branch: branch, project_repository: project_repository)

          status.merge(
            "matched_by" => "workspace_branch",
            "matched_branch" => branch,
            "verified_at" => timestamp,
            "last_checked_at" => timestamp,
            "availability" => "available"
          )
        end
      end

      def verified_worker_pull_request?(status, branch:, project_repository:)
        status.fetch("provider", nil) == "github" &&
          status.fetch("base_repository", nil).to_s.downcase == project_repository.to_s.downcase &&
          !status.fetch("is_cross_repository", false) &&
          status.fetch("head_repository", nil).to_s.downcase == project_repository.to_s.downcase &&
          normalized_branch_name(status.fetch("head_branch", nil)) == normalized_branch_name(branch)
      end

      def discovered_worker_candidate_pr_urls(agent:, project:, issue: nil)
        return [] unless github_support_enabled?
        # A worker can settle without usable final output, so recover from the durable branch
        # identity rather than treating arbitrary URLs elsewhere in its session as deliveries.
        return [] unless agent.fetch("status", nil) == "completed"
        return [] unless forge_client.respond_to?(:pull_request_urls_for_branch)

        branch = normalized_branch_name(persisted_worker_delivery_branch(agent))
        return [] if blank?(branch)

        repository = project_github_repository(project)
        return [] if blank?(repository)
        # A merged delivery pull request is already recorded for this exact branch, so discovery can
        # only re-derive URLs Meringue already has. Skipping it stops a slow or unreachable forge
        # from manufacturing an `unknown` blocker for settled work, and leaves the budget for
        # branches whose delivery really is unknown.
        return [] if trusted_delivery_pull_request_for_branch(issue, branch)

        urls = pull_request_urls_for_branch(repository: repository, branch: branch)
        context = prune_forge_lookup_context
        failure = context&.dig("branch_lookup_failures", [repository.to_s, branch.to_s])
        if failure
          blocker = unavailable_prune_pull_request_status(
            "github-branch://#{repository}/#{branch}",
            failure
          )
          blockers = context.fetch("branch_lookup_blockers_by_issue")
          issue_blockers = blockers[agent.fetch("issue_id", nil)] ||= []
          issue_blockers << blocker unless issue_blockers.any? { |existing| existing.fetch("url", nil) == blocker.fetch("url") }
        end
        urls
      rescue StandardError
        []
      end

      def merged_same_repo_candidate_pull_request(agent:, project:, candidate_urls:)
        return nil unless agent.fetch("status", nil) == "completed"
        return nil unless Array(candidate_urls).compact.uniq.length == 1
        return nil if persisted_worker_delivery_branch(agent)

        project_repository = project && project_github_repository(project)
        return nil if blank?(project_repository)

        status = pull_request_status(Array(candidate_urls).first)
        return nil unless status.fetch("provider", nil) == "github"
        return nil unless status.fetch("state", nil) == "merged"
        return nil unless status.fetch("base_repository", nil).to_s.downcase == project_repository.to_s.downcase
        return nil if status.fetch("is_cross_repository", false)
        return nil unless status.fetch("head_repository", nil).to_s.downcase == project_repository.to_s.downcase

        status.merge(
          "matched_by" => "merged_same_repo_candidate_without_branch",
          "verified_at" => timestamp,
          "last_checked_at" => timestamp,
          "availability" => "available"
        )
      end

      def worker_delivery_branch(agent)
        normalized_branch_name(
          persisted_worker_delivery_branch(agent) ||
            current_workspace_branch_for_delivery(agent)
        )
      end

      def persisted_worker_delivery_branch(agent)
        return nil if agent.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED) == WORKSPACE_MODE_SHARED_READ_ONLY

        metadata = agent.fetch("harness_metadata", {}) || {}
        present_string(metadata.fetch("delivery_branch", nil)) || present_string(agent.fetch("workspace_branch", nil))
      end

      def current_workspace_branch_for_delivery(agent)
        return nil if agent.fetch("effective_workspace_mode", WORKSPACE_MODE_ISOLATED) == WORKSPACE_MODE_SHARED_READ_ONLY
        return nil if agent.fetch("workspace_strategy", nil) == "project_root"

        current_workspace_branch(agent)
      end

      def current_workspace_branch(agent)
        workspace_path = agent.fetch("workspace_path", nil)
        return nil if blank?(workspace_path) || !Dir.exist?(workspace_path.to_s)

        stdout, _stderr, status = Open3.capture3("git", "-C", workspace_path.to_s, "branch", "--show-current")
        return nil unless status.success?

        present_string(stdout)
      rescue StandardError
        nil
      end

      def normalized_branch_name(branch)
        value = present_string(branch)
        return nil unless value

        value.sub(/\Arefs\/heads\//, "").sub(/\Aorigin\//, "")
      end

      def project_github_repository(project)
        root_path = project.fetch("root_path", nil)
        return nil if blank?(root_path) || !Dir.exist?(root_path.to_s)

        stdout, _stderr, status = Open3.capture3("git", "-C", root_path.to_s, "remote", "get-url", "origin")
        return nil unless status.success?

        github_repository_from_remote(stdout)
      rescue StandardError
        nil
      end

      def github_repository_from_remote(remote)
        text = remote.to_s.strip.sub(/\.git\z/, "")
        match = text.match(%r{github\.com[:/]([^/]+/[^/]+)\z})
        match && match[1]
      end

      def pull_request_urls_for_branch(repository:, branch:)
        return [] unless github_support_enabled?

        context = prune_forge_lookup_context
        return Array(forge_client.pull_request_urls_for_branch(repository: repository, branch: branch)) unless context

        key = [repository.to_s, branch.to_s]
        cache = context.fetch("urls_by_branch")
        return cache.fetch(key) if cache.key?(key)
        unless context.fetch("allow_external", false)
          return record_prune_branch_lookup_failure(context, key, "Branch appeared after the prune lookup snapshot")
        end

        remaining = prune_forge_lookup_remaining(context)
        unless remaining.positive?
          context["budget_exhausted"] = true
          return record_prune_branch_lookup_failure(context, key, prune_budget_exhausted_error(context))
        end

        context.fetch("external_branch_lookups") << key
        cache[key] = Array(invoke_forge_branch_lookup(repository: repository, branch: branch, timeout: remaining))
      rescue StandardError => e
        context ? record_prune_branch_lookup_failure(context, key, e.message) : []
      end

      def record_prune_branch_lookup_failure(context, key, error)
        context.fetch("branch_lookup_failures")[key] = error.to_s
        context.fetch("urls_by_branch")[key] = []
      end

      def pull_request_status(url)
        context = prune_forge_lookup_context
        unless github_support_enabled?
          trusted = context&.dig("status_by_url", url.to_s)
          return trusted if trusted

          return unavailable_prune_pull_request_status(url, "GitHub support is disabled; enable it in Settings → Experiments")
        end

        return forge_client.pull_request_status(url) unless context

        key = url.to_s
        cache = context.fetch("status_by_url")
        return cache.fetch(key) if cache.key?(key)
        unless context.fetch("allow_external", false)
          return cache[key] = unavailable_prune_pull_request_status(key, "PR appeared after the prune lookup snapshot")
        end

        remaining = prune_forge_lookup_remaining(context)
        unless remaining.positive?
          context["budget_exhausted"] = true
          return cache[key] = unavailable_prune_pull_request_status(key, prune_budget_exhausted_error(context))
        end

        context.fetch("external_status_urls") << key
        status = invoke_forge_status_lookup(key, timeout: remaining)
        record_prune_status_availability(context, key, status)
        cache[key] = status
      rescue StandardError => e
        status = unavailable_prune_pull_request_status(url, e.message)
        return status unless context

        record_prune_status_availability(context, url.to_s, status)
        context.fetch("status_by_url")[url.to_s] = status
      end

      def record_prune_status_availability(context, url, status)
        return unless status.is_a?(Hash) && status.fetch("state", nil).to_s == "unknown"

        context.fetch("unavailable_status_urls") << url
      end

      def prune_budget_exhausted_error(context)
        budget = context.is_a?(Hash) ? context.fetch("budget_seconds", prune_forge_lookup_budget) : prune_forge_lookup_budget
        "Prune forge lookup budget of #{format_seconds(budget)}s was exhausted"
      end

      def invoke_forge_status_lookup(url, timeout:)
        method = forge_client.method(:pull_request_status)
        return method.call(url, timeout: timeout) if forge_method_accepts_timeout?(method)

        method.call(url)
      end

      def invoke_forge_branch_lookup(repository:, branch:, timeout:)
        method = forge_client.method(:pull_request_urls_for_branch)
        if forge_method_accepts_timeout?(method)
          return method.call(repository: repository, branch: branch, timeout: timeout)
        end

        method.call(repository: repository, branch: branch)
      end

      def forge_method_accepts_timeout?(method)
        method.parameters.any? do |kind, name|
          kind == :keyrest || (%i[key keyreq].include?(kind) && name == :timeout)
        end
      end

      def worker_spawning_guidance_enabled?
        config.worker_spawning_guidance?
      end

      def worker_spawning_guidance_for_head?(head)
        metadata = head.fetch("harness_metadata", {}) || {}
        return metadata.fetch("worker_spawning_guidance") == true if metadata.is_a?(Hash) && metadata.key?("worker_spawning_guidance")

        worker_spawning_guidance_enabled?
      end

      def worker_spawning_guidance_prompt
        config.setting("experiments.worker_spawning_guidance_prompt")
      rescue KeyError, Config::ParseError
        Meringue::Experiments::WorkerSpawningGuidance.default_text
      end

      def set_worker_selection_guidance(command_id, command_type, payload)
        unless worker_spawning_guidance_enabled?
          return rejected_result(
            command_id,
            command_type,
            "Worker model selection guidance is disabled. Enable it in Settings → Experiments.",
            ["worker_spawning_guidance_disabled"]
          )
        end

        prompt = value_at(payload, "prompt", "Prompt", "system_prompt", "systemPrompt")
        unless prompt.is_a?(String)
          return rejected_result(command_id, command_type, "Worker model selection prompt is required.", ["prompt_required"])
        end

        save_configuration(
          command_id,
          command_type,
          "base_fingerprint" => Config::Store.fingerprint(config_path),
          "changes" => { "experiments.worker_spawning_guidance_prompt" => prompt }
        )
      end

      def github_support_enabled?(state = nil)
        explicit = config.value("experiments", "github_support")
        return explicit if explicit == true || explicit == false

        # Callers that bypass CLI migration (older embedders and persisted test
        # fixtures) retain pre-experiment behavior. Normal launches always record
        # schema version 1 before an empty state file can be created.
        return true if config.value("settings", "schema_version").to_i < Config::Schema::VERSION

        source = state
        return false unless source.is_a?(Hash)

        Array(source.fetch("issues", [])).any? do |issue|
          State::Models.pull_request_records_from(issue).any?
        end
      end

      def unavailable_prune_pull_request_status(url, error)
        {
          "provider" => "unknown",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => error.to_s
        }
      end

      def attach_issue_pull_requests!(issue, delivery_pull_request, candidate_pr_urls)
        return unless issue

        State::Models.attach_pull_requests_to_issue!(
          issue,
          delivery_pull_requests: [delivery_pull_request].compact,
          candidate_urls: candidate_pr_urls,
          reported_urls: delivery_pull_request ? [delivery_pull_request.fetch("url", nil)] : []
        )
      end

      def worker_completion_result(agent, issue)
        result = deep_copy(agent)
        if issue
          result["issue"] = issue_pull_request_summary(issue)
          result["issue_id"] = issue.fetch("id", nil)
        end
        result
      end

      def issue_pull_request_summary(issue)
        {
          "id" => issue.fetch("id", nil),
          "delivery_pull_requests" => Array(issue.fetch("delivery_pull_requests", [])),
          "reported_pr_urls" => Array(issue.fetch("reported_pr_urls", [])),
          "candidate_pr_urls" => Array(issue.fetch("candidate_pr_urls", []))
        }.compact
      end

      def issue_pr_urls(issue)
        State::Models.pull_request_urls_from([
          *Array(issue.fetch("delivery_pull_requests", nil)),
          *Array(issue.fetch("reported_pr_urls", nil))
        ])
      end

    end
  end
end
