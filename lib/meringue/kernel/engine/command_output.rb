# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Turning command results into the lines the dashboard prints, plus the killed-record sweep
      # that reports through the same shape.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def kernel_command_output_lines(command_results)
        Array(command_results).flat_map do |result|
          next [] if command_result_output_suppressed?(result)

          status = result.fetch("status", "unknown")
          command_type = result.fetch("command_type", "command")
          if status == "accepted"
            # The result's message is an internal acceptance summary (for example,
            # "Loaded slash command help."). The detail formatter is the command's
            # actual output and must stand on its own without a type/status wrapper.
            kernel_command_output_detail_lines(command_type, result.fetch("result", nil))
          else
            # Rejections and failures carry actionable information in errors. Keep
            # that information, falling back to the result message for older or
            # unusual commands that do not populate an errors array.
            errors = Array(result.fetch("errors", [])).map(&:to_s)
            errors = [result.fetch("message", "").to_s] if errors.empty?
            errors
          end
        end.reject { |line| line.to_s.strip.empty? }
      end

      def command_result_output_suppressed?(result)
        return true if Array(result.fetch("log_entry_ids", [])).any?

        # Async SpawnWorker returns after the durable reservation, before workspace and harness
        # provisioning can emit the canonical "Spawned worker ..." lifecycle event. The accepted
        # reservation message remains in the command journal, but is deliberately not user-visible;
        # otherwise a head batch shows an intermediate "Reserved worker ..." line followed by the
        # useful spawn line. Rejections and failures never match this predicate.
        return false unless result.is_a?(Hash)
        return false unless result.fetch("command_type", nil).to_s == "SpawnWorker"
        return false unless result.fetch("status", nil).to_s == "accepted"

        worker = result.fetch("result", nil)
        worker.is_a?(Hash) &&
          worker.fetch("type", nil).to_s == "worker" &&
          worker_provisioning_in_progress?(worker) &&
          !agent_has_session_reference?(worker)
      end

      # One command result renders as one visible log entry: its summary line and any
      # continuation detail lines are joined with newlines so they share a single header
      # (and one attribution) instead of producing a separate log row per line. Commands
      # with their own outcome, or an intentionally silent async reservation, are skipped,
      # matching `kernel_command_output_lines`.
      def command_output_bodies(command_results)
        Array(command_results).filter_map do |result|
          next nil unless result.is_a?(Hash)

          lines = kernel_command_output_lines([result])
          next nil if lines.empty?

          [lines.join("\n"), result]
        end
      end

      # Grouped, and the usage column aligned, because a flat list of 47 lines is
      # complete without being navigable.
      def help_output_lines(result)
        entries = Array(result)
        return [] if entries.empty?

        width = entries.map { |item| item.fetch("usage", "").to_s.length }.max
        grouped = entries.group_by { |item| item.fetch("group", Engine::OTHER_HELP_GROUP) }
        ordered = (Engine::HELP_GROUPS.map(&:first) + [Engine::OTHER_HELP_GROUP]).select { |group| grouped.key?(group) }
        ordered.flat_map do |group|
          ["", "  #{group}"] + grouped.fetch(group).map do |item|
            "    #{item.fetch("usage", "").to_s.ljust(width)}  #{first_sentence(item.fetch("description", ""))}"
          end
        end
      end

      # One line per command here; the full description stays available in the
      # README and in each command's own error text.
      def first_sentence(description)
        text = description.to_s.strip
        (text[/\A.*?[.!?](?:\s|\z)/m] || text).strip.delete_suffix(".")
      end

      def kernel_command_output_detail_lines(command_type, result)
        case command_type
        when "SetTheme"
          theme = result.is_a?(Hash) ? result["theme"] : nil
          config_path = result.is_a?(Hash) ? result["config_path"] : nil
          ["  theme: #{theme}", config_path ? "  config: #{config_path}" : nil].compact
        when "SetHarness"
          harness = result.is_a?(Hash) ? result["active_harness"] || result["harness"] : nil
          harness ? ["  harness: #{harness}"] : []
        when "Help"
          help_output_lines(result)
        when "GetModelCatalog"
          model_catalog_output_lines(result)
        when "ListQuestions"
          questions = Array(result)
          return ["  No questions."] if questions.empty?

          lines = questions.map { |question| "  #{question.fetch("id", "?")} [#{question.fetch("status", "?")}] #{question.fetch("question", "")}" }
          open_question = questions.find { |question| question.fetch("status", nil) == "open" }
          if open_question
            lines << "  Answer with /answer #{open_question.fetch("id", "Q1")} \"<answer>\", or just reply in chat and a head will match your reply to the question."
          end
          lines
        when "Prune"
          prune_result = result || {}
          cleanup_outcomes = Array(prune_result["workspace_cleanup_outcomes"])
          retained = Array(prune_result["retention_reasons"])
          already_removed = cleanup_outcomes.count { |outcome| outcome["status"] == "already_removed" }
          [
            "  removed issues: #{Array(prune_result["removed_issue_ids"]).length}",
            "  removed agents: #{Array(prune_result["removed_agent_ids"]).length}",
            "  removed worktrees: #{cleanup_outcomes.count { |outcome| outcome["status"] == "removed" }}",
            "  removed projects: #{Array(prune_result["removed_project_ids"]).length}",
            already_removed.positive? ? "  worktrees already gone: #{already_removed}" : nil,
            "  blocked worktree cleanups: #{cleanup_outcomes.count { |outcome| !outcome.fetch("success", false) }}",
            "  retained issues: #{Array(prune_result["retained_issue_ids"]).length}",
            *retained.first(PRUNE_RETENTION_REPORT_LIMIT).map do |reason|
              "    #{reason["issue_id"]}: #{Array(reason["blockers"]).join(", ")}"
            end
          ].compact
        when "ListGoals"
          goal_output_lines(result)
        when "CreateGoal", "ModifyGoal", "StopGoal"
          goal = result.is_a?(Hash) ? result : {}
          return [] if goal.empty?

          [
            "  #{Goals::Record.summary(goal)}",
            goal["success_criteria"] ? "  criteria: #{goal["success_criteria"]}" : nil,
            Goals::Record.reviewer_judged?(goal) ? "  judged by: a reviewer session per iteration" : nil,
            present_string(goal.dig("metric", "command")) ? "  metric: #{goal.dig("metric", "command")}" : nil
          ].compact
        when "Recount"
          mappings = result.is_a?(Hash) ? result.fetch("mappings", {}) : {}
          ["  renamed IDs: #{mappings.values.sum { |mapping| mapping.length }}"]
        when "ClearState"
          ["  state: reset"]
        when "GetInfo"
          info = result.is_a?(Hash) ? result : {}
          record = info.fetch("record", {}) || {}
          deferred = info["deferred_spawn"].is_a?(Hash) ? info["deferred_spawn"] : nil
          waiting_dependents = Array(info["waiting_dependent_agent_ids"])
          [
            "  #{info.fetch("kind", "record")}: #{record["id"] || info["id"]}",
            record["status"] ? "  status: #{record["status"]}" : nil,
            record["title"] || record["name"] || record["question"] ? "  #{record["title"] || record["name"] || record["question"]}" : nil,
            deferred ? "  #{deferred_info_line(deferred)}" : nil,
            waiting_dependents.any? ? "  queued after this worker: #{waiting_dependents.join(", ")}" : nil
          ].compact
        when "ListAll", "GetState"
          state = result || {}
          [
            "  projects: #{Array(state["projects"]).length}",
            "  issues: #{Array(state["issues"]).length}",
            "  agents: #{Array(state["agents"]).length}",
            "  questions: #{Array(state["questions"]).length}"
          ]
        else
          target_id = result.is_a?(Hash) ? result["id"] : nil
          target_id ? ["  target: #{target_id}"] : []
        end
      end

      # A catalog read is reported as a status, not as a listing. The browsable
      # list is the TUI model picker (`/models`), which reads this same persisted
      # snapshot, so the log only has to say which harness answered, how fresh the
      # answer is, and how many models it holds.
      def model_catalog_output_lines(result)
        catalog = result.is_a?(Hash) ? result : {}
        models = Array(catalog["models"])
        lines = ["  harness: #{catalog.fetch("harness", "unknown")}", "  availability: #{catalog.fetch("availability", "unknown")}"]
        authentication = catalog.fetch("authentication", nil)
        authentication_status = authentication.is_a?(Hash) ? authentication.fetch("status", nil) : authentication
        lines << "  authentication: #{authentication_status}" if authentication_status
        lines << "  models: #{models.length}" unless models.empty?
        lines << "  source: #{catalog.fetch("source")}" if catalog["source"]
        lines << "  confirmed: #{catalog.fetch("fetched_at")}" if catalog["fetched_at"]
        lines << "  last refresh attempt: #{catalog.fetch("last_attempt_at")}" if catalog["last_attempt_at"]
        lines << "  note: #{catalog.fetch("note")}" if catalog["note"]
        return lines if models.empty?

        examples = models.first(MODEL_CATALOG_OUTPUT_EXAMPLE_LIMIT).map { |model| model.fetch("reference", "?") }
        lines << "  for example: #{examples.join(", ")}"
        lines << "  Run /models to pick one in the model picker, or /model <provider>/<model-id> to set it directly."
        lines
      end

      def prune_killed_records
        operation_id = "reconcile-prune-#{instance_id}-#{Thread.current.object_id}-#{(monotonic_time * 1_000_000).to_i}"
        preparation = synchronized_state do
          state = normalized_state
          plan = killed_record_prune_plan(state)
          if plan.values.all?(&:empty?)
            next nil
          end

          worker_ids = workers_removed_by_record_plan(state, plan)
          next nil if worker_ids.any? { |worker_id| worker_prune_cleanup_claimed?(find_agent(state, worker_id)) }

          now = timestamp
          worker_ids.each do |worker_id|
            worker = find_agent(state, worker_id)
            next unless worker

            metadata = worker.fetch("harness_metadata", {}) || {}
            worker["harness_metadata"] = metadata.merge(
              "prune_cleanup_claim" => prune_cleanup_claim(operation_id, now)
            )
          end
          touch_state!(state, now)
          store.save(state)
          { "plan" => plan, "worker_ids" => worker_ids, "state" => deep_copy(state), "claimed_at" => now }
        end
        return empty_killed_record_prune_result unless preparation

        workspace_cleanups = cleanup_prune_workspace_plan(preparation)
        synchronized_state do
          state = normalized_state
          current = killed_record_prune_plan(state)
          initial = preparation.fetch("plan")
          plan = current.to_h do |key, ids|
            [key, ids & initial.fetch(key)]
          end
          now = timestamp
          prune_result = remove_issue_bundles_and_agents!(
            state,
            issue_ids: plan.fetch("issue_ids"),
            project_ids: plan.fetch("project_ids"),
            extra_agent_ids: plan.fetch("agent_ids"),
            reason: "killed",
            now: now,
            remove_empty_projects: false,
            prepared_workspace_cleanups: workspace_cleanups
          )
          clear_prune_cleanup_claims!(state, operation_id)
          log_ids = prune_result.fetch("workspace_cleanup_log_entry_ids", []).dup
          log_ids.concat(append_killed_records_prune_log(state, prune_result))
          touch_state!(state, now)
          store.save(state)
          prune_result.merge("changed" => true, "log_entry_ids" => log_ids.uniq)
        end
      rescue StandardError
        release_prune_cleanup_claims(operation_id)
        raise
      end

      def killed_record_prune_plan(state)
        {
          "project_ids" => state.fetch("projects").filter_map { |record| record.fetch("id", nil) if record.fetch("status", nil) == "killed" },
          "issue_ids" => state.fetch("issues").filter_map { |record| record.fetch("id", nil) if record.fetch("status", nil) == "killed" },
          "agent_ids" => state.fetch("agents").filter_map { |record| record.fetch("id", nil) if record.fetch("status", nil) == "killed" }
        }
      end

      def workers_removed_by_record_plan(state, plan)
        issue_ids = (plan.fetch("issue_ids") + project_issue_ids(state, plan.fetch("project_ids"))).uniq
        subtree_ids = issue_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        state.fetch("agents").filter_map do |agent|
          next unless agent.fetch("type", nil) == "worker"
          next unless subtree_ids.include?(agent.fetch("issue_id", nil)) || plan.fetch("agent_ids").include?(agent.fetch("id", nil))

          agent.fetch("id", nil)
        end.compact.uniq
      end

      def empty_killed_record_prune_result
        {
          "changed" => false,
          "removed_issue_ids" => [],
          "removed_agent_ids" => [],
          "removed_standalone_agent_ids" => [],
          "removed_project_ids" => [],
          "log_entry_ids" => []
        }
      end

      # Reconciliation removes killed records with the same helper `/prune` uses, so one reconcile
      # pass is one line, shaped like a prune pass: consolidated counts that keep the filesystem
      # side effect visible without spending a line per worker, plus the same preserved-worktree
      # sentence (at `warning`) when cleanup had to keep a worktree, so a retention is never silent
      # now that no per-worker warning follows it. It stays silent when the pass removed nothing, so
      # a killed record whose worktree is still dirty never becomes tick noise.
      def append_killed_records_prune_log(state, prune_result)
        return [] if prune_removed_counts(prune_result).values.sum.zero?

        blocked = Array(prune_result.fetch("workspace_cleanup_outcomes", []))
                  .reject { |outcome| outcome.fetch("success", false) }
        message = prune_summary_message(prune_result, prefix: "Pruned killed records:")
        message = "#{message} #{blocked_worktree_retention_sentence(blocked)}" if blocked.any?
        append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: blocked.any? ? "warning" : "info",
          message: message,
          details: prune_result
        )
      end
    end
  end
end
