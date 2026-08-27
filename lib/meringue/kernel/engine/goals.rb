# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # The goal commands: creating, modifying, stopping, and reporting a goal loop.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # `CreateGoal` has two entry shapes and one outcome. `issue_id` attaches the loop to an
      # issue that already exists; `prompt` describes the outcome and the kernel mints the issue
      # itself, so a goal-driven request never has to be split into "create an issue, then attach
      # a goal to it". Both shapes end at the same record, and the minted issue is written in the
      # same save as the goal: validation runs first, so a rejected goal can never leave an
      # orphan issue behind.
      def create_goal(command_id, command_type, payload)
        issue_id = present_string(value_at(payload, "issue_id", "IssueID", "issueId"))
        prompt = present_string(value_at(payload, "prompt", "Prompt", "issue_prompt", "IssuePrompt", "issuePrompt"))
        success_criteria = present_string(value_at(payload, "success_criteria", "SuccessCriteria", "successCriteria", "criteria")) || prompt
        title = value_at(payload, "title", "Title")
        metric = goal_metric_from_payload(payload)
        budget = goal_budget_from_payload(payload)
        judge_mode = present_string(value_at(payload, "judge_mode", "judgeMode")) || value_at(payload, "judge", "Judge")&.then { |judge| judge.is_a?(Hash) ? value_at(judge, "mode", "Mode") : judge }
        continuity = present_string(value_at(payload, "continuity", "Continuity"))
        attempt_prompt_template = present_string(value_at(payload, "attempt_prompt_template", "attemptPromptTemplate"))
        paused = truthy?(value_at(payload, "paused", "Paused"))
        errors = []

        # A reviewer-judged goal is the "no number exists" case: its finish line is a
        # reviewer's verdict against the success criteria, so a metric command is not just
        # unnecessary, it would be an unmeasured field on the record. Guardrails stay.
        reviewer_judged = judge_mode.to_s == Goals::Record::REVIEWER_JUDGE_MODE
        errors << "issue_id or prompt is required" if issue_id.nil? && prompt.nil?
        errors << "success_criteria is required" if blank?(success_criteria)
        if reviewer_judged
          if present_string(metric["command"])
            errors << "a reviewer-judged goal has no metric; attach that command as a guardrail instead"
          end
        else
          errors << "metric.command is required" if blank?(metric["command"])
          errors << "metric.target must be a number" if metric["target"].nil?
        end
        if present_string(value_at(payload, "comparator", "Comparator")) && !Goals::Record::COMPARATORS.include?(value_at(payload, "comparator", "Comparator").to_s)
          errors << "comparator must be one of #{Goals::Record::COMPARATORS.join(", ")}"
        end
        if present_string(continuity) && !Goals::Record::CONTINUITY_MODES.include?(continuity)
          errors << "continuity must be one of #{Goals::Record::CONTINUITY_MODES.join(", ")}"
        end
        if present_string(judge_mode) && !Goals::Record::JUDGE_MODES.include?(judge_mode.to_s)
          errors << if Goals::Record::DEFERRED_JUDGE_MODES.include?(judge_mode.to_s)
                      "judge mode #{judge_mode} is not implemented yet; available modes are #{Goals::Record::JUDGE_MODES.join(", ")}"
                    else
                      "judge mode must be one of #{Goals::Record::JUDGE_MODES.join(", ")}"
                    end
        end
        return rejected_result(command_id, command_type, "Goal was not created.", errors) unless errors.empty?

        state = normalized_state
        if issue_id
          issue = find_issue(state, issue_id)
          return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) unless issue

          project = find_project(state, issue.fetch("project_id"))
          return rejected_result(command_id, command_type, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

          mismatch = goal_project_conflict(state, payload, issue, project)
          return rejected_result(command_id, command_type, mismatch.fetch("message"), mismatch.fetch("errors")) if mismatch

          # One loop per issue. Two loops on one issue would race for the same branch and
          # double the sessions the budgets are supposed to bound.
          existing = active_goal_for_issue(state, issue.fetch("id"))
          if existing
            return rejected_result(
              command_id,
              command_type,
              "Issue #{issue.fetch("id")} already has an active goal (#{existing.fetch("id")}).",
              ["issue_already_has_active_goal"]
            )
          end
        else
          resolution = resolve_goal_project(state, payload)
          project = resolution.fetch("project", nil)
          return rejected_result(command_id, command_type, resolution.fetch("message"), resolution.fetch("errors")) unless project
        end

        now = timestamp
        goal_id = next_goal_id!(state)
        minted = issue.nil?
        minted_log_ids = []
        if minted
          issue = mint_goal_issue!(
            state,
            project: project,
            prompt: prompt || success_criteria,
            success_criteria: success_criteria,
            issue_title: present_string(value_at(payload, "issue_title", "IssueTitle", "issueTitle")),
            originating_head_id: value_at(payload, "originating_head_id", "originatingHeadId", "_head_id"),
            goal_id: goal_id,
            metric: metric,
            reviewer_judged: reviewer_judged,
            now: now
          )
          minted_log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: issue.fetch("id"),
            level: "info",
            message: "Created issue #{issue.fetch("id")} for goal #{goal_id}: #{issue.fetch("title")}",
            details: {
              "project_id" => project.fetch("id"),
              "parent_issue_id" => nil,
              "goal_id" => goal_id,
              "created_for_goal" => true
            }
          )
        end
        goal = {
          "id" => goal_id,
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "title" => present_string(title) || issue.fetch("title", "Goal"),
          "success_criteria" => success_criteria.to_s.strip,
          "kind" => Goals::Record::DEFAULT_KIND,
          "status" => "queued",
          "stop_reason" => nil,
          "paused" => paused,
          "metric" => metric,
          "judge" => { "mode" => present_string(judge_mode) || Goals::Record::DEFAULT_JUDGE_MODE },
          "budget" => budget,
          "continuity" => continuity || Goals::Record::DEFAULT_CONTINUITY,
          "attempt_prompt_template" => attempt_prompt_template,
          "baseline_metric" => nil,
          "last_metric" => nil,
          "best_metric" => nil,
          "current_iteration" => 0,
          "workers_spawned" => 0,
          "consecutive_no_progress" => 0,
          "consecutive_probe_failures" => 0,
          "iterations" => [],
          "active_worker_id" => nil,
          "question_id" => nil,
          "next_tick_at" => nil,
          "created_at" => now,
          "updated_at" => now
        }
        Goals::Record.normalize!(goal)
        state.fetch("goals") << goal
        issue["status"] = "working" unless TERMINAL_AGENT_STATUSES.include?(issue.fetch("status", nil))
        issue["updated_at"] = now

        log_ids = minted_log_ids + append_log(
          state,
          source_type: "kernel",
          source_id: goal.fetch("id"),
          level: "info",
          message: "Created goal #{goal.fetch("id")} on #{minted ? "new issue " : ""}#{issue.fetch("id")}: #{goal.fetch("success_criteria")}",
          details: goal_log_details(goal).merge("created_issue" => minted)
        )
        touch_state!(state, now)
        store.save(state)

        message = if minted
                    "Created issue #{issue.fetch("id")} (#{issue.fetch("title")}) and goal #{goal.fetch("id")}. #{Goals::Record.summary(goal)}"
                  else
                    "Created goal #{goal.fetch("id")}. #{Goals::Record.summary(goal)}"
                  end
        accepted_result(command_id, command_type, goal.fetch("id"), message, goal, log_ids)
      end

      # The issue a prompt-form goal needs. It is a perfectly ordinary issue: same id counter,
      # same shape, prunable and recountable like any other. Only its provenance differs, which
      # is recorded in the log details rather than in a new field.
      def mint_goal_issue!(state, project:, prompt:, success_criteria:, issue_title:, originating_head_id:, goal_id:, metric:, now:, reviewer_judged: false)
        issue = {
          "id" => next_issue_id!(state, project.fetch("id")),
          "project_id" => project.fetch("id"),
          "parent_issue_id" => nil,
          "originating_head_id" => present_string(originating_head_id),
          "title" => issue_title || goal_issue_title(prompt),
          "description" => goal_issue_description(
            prompt: prompt,
            success_criteria: success_criteria,
            goal_id: goal_id,
            metric: metric,
            reviewer_judged: reviewer_judged
          ),
          "status" => "queued",
          "agent_ids" => [],
          "created_at" => now,
          "updated_at" => now
        }
        state.fetch("issues") << issue
        project["updated_at"] = now
        issue
      end

      def goal_issue_title(prompt)
        text = prompt.to_s.strip.gsub(/\s+/, " ")
        return "Goal loop" if text.empty?

        sentence = text.split(/(?<=[.!?])\s/, 2).first.to_s.strip.sub(/[.]\z/, "")
        sentence = text if sentence.empty?
        return sentence if sentence.length <= GOAL_ISSUE_TITLE_LIMIT

        truncated = sentence[0, GOAL_ISSUE_TITLE_LIMIT]
        boundary = truncated.rindex(" ")
        truncated = truncated[0, boundary] if boundary && boundary > GOAL_ISSUE_TITLE_LIMIT / 2
        "#{truncated.rstrip}…"
      end

      # The prompt is kept verbatim, because it is what the attempt workers are ultimately
      # working from, and the measurable finish line is spelled out underneath it.
      def goal_issue_description(prompt:, success_criteria:, goal_id:, metric:, reviewer_judged: false)
        lines = [prompt.to_s.strip]
        lines << ""
        lines << "Goal loop #{goal_id} drives this issue: Meringue keeps producing attempts until the criterion below is met or a budget guard stops the loop."
        lines << "Success criteria: #{success_criteria}" unless success_criteria.to_s.strip == prompt.to_s.strip
        if reviewer_judged
          # No metric line for a reviewer-judged goal: there is no number, and printing an
          # empty one would read as a metric nobody measures.
          lines << "Judged by: an independent reviewer session per iteration (never the attempt itself), against the success criteria above."
        else
          comparator = GOAL_COMPARATOR_TEXT.fetch(metric["comparator"].to_s, metric["comparator"].to_s)
          lines << "Metric (measured by the kernel, never self-reported): #{metric["command"]} #{comparator} #{Goals::Record.format_number(metric["target"])}"
        end
        guardrails = Array(metric["guardrails"]).map { |guardrail| guardrail.is_a?(Hash) ? guardrail["command"] : guardrail }.compact
        lines << "Guardrails that must keep passing: #{guardrails.join(", ")}" unless guardrails.empty?
        lines.join("\n")
      end

      # Which project a prompt-form goal's issue lands in. Explicit beats local beats sole,
      # and an ambiguous choice is rejected with the candidates rather than guessed at, because
      # an issue minted under the wrong project is invisible work in the wrong tree.
      def resolve_goal_project(state, payload)
        requested = present_string(value_at(payload, "project_id", "ProjectID", "projectId", "project", "Project"))
        if requested
          project = find_project(state, requested) || project_by_name_or_root(state, requested)
          return { "project" => project } if project

          return {
            "message" => "Project #{requested} does not exist.#{registered_project_hint(state)}",
            "errors" => ["project_not_found"]
          }
        end

        candidates = state.fetch("projects", []).reject { |project| project.fetch("status", nil) == "killed" }
        if candidates.empty?
          return {
            "message" => "No project is registered, so there is nowhere to create the goal's issue. Run /project add <path> first.",
            "errors" => ["no_registered_project"]
          }
        end

        local = project_for_directory(candidates, cwd)
        return { "project" => local } if local
        return { "project" => candidates.first } if candidates.length == 1

        {
          "message" => "Several projects are registered and this directory is not inside one of them, " \
                       "so /goal create cannot tell where the new issue belongs. Add --project <project_id> " \
                       "(or name an existing issue).#{registered_project_hint(state)}",
          "errors" => ["project_ambiguous"]
        }
      end

      # `project_id` alongside `issue_id` is redundant, so it is only worth a rejection when the
      # two disagree: that is a head or a user pointing at two different places at once.
      def goal_project_conflict(state, payload, issue, project)
        requested = present_string(value_at(payload, "project_id", "ProjectID", "projectId", "project", "Project"))
        return nil unless requested

        requested_project = find_project(state, requested) || project_by_name_or_root(state, requested)
        return nil if requested_project && requested_project.fetch("id") == project.fetch("id")

        {
          "message" => "Issue #{issue.fetch("id")} belongs to #{project.fetch("id")}, not #{requested}. " \
                       "Drop the project when you name an issue.",
          "errors" => ["project_issue_mismatch"]
        }
      end

      def project_by_name_or_root(state, value)
        needle = value.to_s.strip
        state.fetch("projects", []).find { |project| project.fetch("name", "").to_s.casecmp?(needle) } ||
          state.fetch("projects", []).find { |project| same_path?(project.fetch("root_path", ""), needle) }
      end

      # The deepest registered project root that contains `path`, so a nested checkout wins over
      # its parent instead of both matching.
      def project_for_directory(projects, path)
        expanded = File.expand_path(path.to_s)
        projects.select { |project| directory_contains?(project.fetch("root_path", nil), expanded) }
                .max_by { |project| File.expand_path(project.fetch("root_path").to_s).length }
      end

      def directory_contains?(root_path, expanded_path)
        return false if blank?(root_path)

        root = File.expand_path(root_path.to_s)
        expanded_path == root || expanded_path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def registered_project_hint(state)
        ids = state.fetch("projects", []).map { |project| project.fetch("id", nil) }.compact
        return "" if ids.empty?

        " Registered projects: #{ids.join(", ")}."
      end

      def modify_goal(command_id, command_type, payload)
        goal_id = value_at(payload, "goal_id", "GoalID", "goalId", "id")
        return rejected_result(command_id, command_type, "Goal was not modified.", ["goal_id is required"]) if blank?(goal_id)

        state = normalized_state
        goal = find_goal(state, goal_id)
        return rejected_result(command_id, command_type, "Goal #{goal_id} does not exist.", ["goal_not_found"]) unless goal
        if %w[killed].include?(goal.fetch("status", nil))
          return rejected_result(command_id, command_type, "Goal #{goal.fetch("id")} was stopped and cannot be modified.", ["goal_not_modifiable"])
        end

        requested_status = present_string(value_at(payload, "status", "Status"))
        if requested_status && !Goals::Record::ACTIVE_STATUSES.include?(requested_status)
          return rejected_result(
            command_id,
            command_type,
            "ModifyGoal can only set a goal back to #{Goals::Record::ACTIVE_STATUSES.join(" or ")}; use StopGoal or Kill to end one.",
            ["invalid_goal_status"]
          )
        end

        now = timestamp
        changed_fields = []
        if payload_has?(payload, "paused", "Paused")
          goal["paused"] = truthy?(value_at(payload, "paused", "Paused"))
          changed_fields << "paused"
        end
        if payload_has?(payload, "success_criteria", "SuccessCriteria", "successCriteria", "criteria")
          goal["success_criteria"] = value_at(payload, "success_criteria", "SuccessCriteria", "successCriteria", "criteria").to_s.strip
          changed_fields << "success_criteria"
        end
        if payload_has?(payload, "title", "Title")
          goal["title"] = present_string(value_at(payload, "title", "Title")) || goal.fetch("title")
          changed_fields << "title"
        end
        if payload_has?(payload, "attempt_prompt_template", "attemptPromptTemplate")
          goal["attempt_prompt_template"] = present_string(value_at(payload, "attempt_prompt_template", "attemptPromptTemplate"))
          changed_fields << "attempt_prompt_template"
        end
        target = Goals::Record.float_or_nil(value_at(payload, "target", "Target", "metric_target", "metricTarget"))
        if target
          goal["metric"]["target"] = target
          changed_fields << "target"
        end
        budget_updates = goal_budget_updates_from_payload(payload)
        unless budget_updates.empty?
          goal["budget"] = Goals::Record.normalized_budget(goal.fetch("budget").merge(budget_updates))
          changed_fields.concat(budget_updates.keys)
        end

        if requested_status
          # Restarting a guard-stopped goal clears the stop reason and the no-progress
          # counters, otherwise the same guard would trip again on the next tick.
          goal["status"] = requested_status
          goal["stop_reason"] = nil
          goal["settled_at"] = nil
          goal["consecutive_no_progress"] = 0
          goal["consecutive_probe_failures"] = 0
          goal["next_tick_at"] = nil
          changed_fields << "status"
        end

        Goals::Record.normalize!(goal)
        goal["updated_at"] = now
        message = "Modified goal #{goal.fetch("id")}: #{changed_fields.empty? ? "no fields changed" : changed_fields.uniq.join(", ")}. #{Goals::Record.summary(goal)}"
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: goal.fetch("id"),
          level: "info",
          message: message,
          details: goal_log_details(goal).merge("changed_fields" => changed_fields.uniq)
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, goal.fetch("id"), message, goal, log_ids)
      end

      # A user-facing stop. The loop ends for good, but the attempt session that is already
      # running is left alone: it owns a real branch and worktree, and killing it would throw
      # that work away. `Kill <goal_id>` is the destructive variant.
      def stop_goal(command_id, command_type, payload)
        goal_id = value_at(payload, "goal_id", "GoalID", "goalId", "id", "target_id")
        return rejected_result(command_id, command_type, "Goal was not stopped.", ["goal_id is required"]) if blank?(goal_id)

        state = normalized_state
        goal = find_goal(state, goal_id)
        return rejected_result(command_id, command_type, "Goal #{goal_id} does not exist.", ["goal_not_found"]) unless goal

        if Goals::Record::ACTIVE_STATUSES.include?(goal.fetch("status", nil))
          now = timestamp
          settle_goal_record!(goal, status: "killed", stop_reason: "user_stopped", now: now)
          message = "Stopped goal #{goal.fetch("id")} at the user's request. #{Goals::Record.summary(goal)}"
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: goal.fetch("id"),
            level: "info",
            message: message,
            details: goal_log_details(goal).merge("retained_agent_id" => goal.fetch("last_worker_id", nil)).compact
          )
          touch_state!(state, now)
          store.save(state)
          return accepted_result(command_id, command_type, goal.fetch("id"), message, goal, log_ids)
        end

        accepted_result(
          command_id,
          command_type,
          goal.fetch("id"),
          "Goal #{goal.fetch("id")} is already #{goal.fetch("status")}#{goal.fetch("stop_reason", nil) ? " (#{goal.fetch("stop_reason")})" : ""}.",
          goal,
          []
        )
      end

      def list_goals(command_id, command_type, payload)
        goal_id = present_string(value_at(payload, "goal_id", "GoalID", "goalId", "id", "target_id"))
        state = normalized_state
        goals = state.fetch("goals")
        if goal_id
          goal = find_goal(state, goal_id)
          return rejected_result(command_id, command_type, "Goal #{goal_id} does not exist.", ["goal_not_found"]) unless goal

          goals = [goal]
        end

        summaries = goals.map { |record| goal_status_summary(record) }
        # One log line: the per-goal lines are rendered as command output detail, like
        # ListQuestions, so a visible log entry stays one scannable line.
        message = if summaries.empty?
                    "No goal loops."
                  elsif summaries.length == 1
                    summaries.first.fetch("line")
                  else
                    "#{summaries.length} goal loops."
                  end
        accepted_result(command_id, command_type, goal_id, message, { "goals" => summaries }, [])
      end

      def goal_output_lines(result)
        summaries = Array(result.is_a?(Hash) ? result["goals"] : nil)
        return ["  No goal loops."] if summaries.empty?

        summaries.flat_map do |summary|
          lines = ["  #{summary.fetch("line", summary.fetch("id", "goal"))}"]
          next lines unless summaries.length == 1

          lines + Array(summary.fetch("iterations", [])).map do |iteration|
            detail = if present_string(iteration.fetch("review_line", nil))
                       iteration.fetch("review_line")
                     else
                       "metric #{Goals::Record.format_number(iteration.fetch("metric", nil))}"
                     end
            "    it#{iteration.fetch("number", 0)}: #{iteration.fetch("verdict", "?")} #{detail}"
          end
        end
      end

      def goal_status_summary(goal)
        reviewer_judged = Goals::Record.reviewer_judged?(goal)
        iterations = Goals::Record.settled_iterations(goal).last(5).map do |iteration|
          review = iteration.fetch("review", nil)
          {
            "number" => iteration.fetch("number", 0),
            "verdict" => iteration.fetch("verdict", nil),
            "metric" => Goals::Record.metric_value(iteration.fetch("metric", nil)),
            "metric_delta" => iteration.fetch("metric_delta", nil),
            "approved" => review.is_a?(Hash) ? review.fetch("approved", nil) : nil,
            "critique" => review.is_a?(Hash) ? Array(review.fetch("critique", [])) : nil,
            "review_line" => Goals::Record.review_line(review),
            "attempt_worker_id" => iteration.fetch("attempt_worker_id", nil),
            "review_worker_id" => iteration.fetch("review_worker_id", nil),
            "next_directive" => iteration.fetch("next_directive", nil)
          }.compact
        end
        {
          "id" => goal.fetch("id"),
          "issue_id" => goal.fetch("issue_id", nil),
          "status" => goal.fetch("status", nil),
          "stop_reason" => goal.fetch("stop_reason", nil),
          "paused" => goal.fetch("paused", false),
          "judge_mode" => goal.dig("judge", "mode"),
          "review_state" => reviewer_judged ? Goals::Record.review_state(goal) : nil,
          "last_critique" => reviewer_judged ? Array(Goals::Record.last_review(goal)&.fetch("critique", [])) : nil,
          "line" => "#{Goals::Record.summary(goal)} — #{goal.fetch("success_criteria", "")}",
          "iterations" => iterations
        }.compact
      end

      def goal_metric_from_payload(payload)
        nested = value_at(payload, "metric", "Metric")
        nested = {} unless nested.is_a?(Hash)
        parse = value_at(nested, "parse", "Parse")
        parse = {} unless parse.is_a?(Hash)
        pattern = present_string(value_at(payload, "pattern", "metric_pattern", "metricPattern")) || present_string(value_at(parse, "pattern", "Pattern"))
        parse_type = present_string(value_at(payload, "parse", "parse_type", "parseType")) || present_string(value_at(parse, "type", "Type"))
        parse_type = "regex" if parse_type.nil? && pattern

        Goals::Record.normalized_metric(
          "command" => present_string(value_at(payload, "metric_command", "metricCommand", "command")) || present_string(value_at(nested, "command", "Command")),
          "cwd" => present_string(value_at(payload, "metric_cwd", "metricCwd")) || present_string(value_at(nested, "cwd", "Cwd")),
          "comparator" => present_string(value_at(payload, "comparator", "Comparator")) || present_string(value_at(nested, "comparator", "Comparator")),
          "target" => Goals::Record.float_or_nil(value_at(payload, "target", "Target", "metric_target", "metricTarget") || value_at(nested, "target", "Target")),
          "timeout_seconds" => value_at(payload, "metric_timeout_seconds", "metricTimeoutSeconds") || value_at(nested, "timeout_seconds", "timeoutSeconds"),
          "parse" => {
            "type" => parse_type,
            "pattern" => pattern,
            "capture" => value_at(payload, "capture") || value_at(parse, "capture", "Capture"),
            "path" => present_string(value_at(payload, "json_path", "jsonPath")) || present_string(value_at(parse, "path", "Path"))
          },
          "guardrails" => Array(
            value_at(payload, "guardrails", "Guardrails") ||
            value_at(nested, "guardrails", "Guardrails") ||
            value_at(payload, "guardrail", "Guardrail")
          )
        )
      end

      def goal_budget_from_payload(payload)
        Goals::Record.normalized_budget(goal_budget_updates_from_payload(payload))
      end

      def goal_budget_updates_from_payload(payload)
        nested = value_at(payload, "budget", "Budget")
        nested = {} unless nested.is_a?(Hash)
        {
          "max_iterations" => value_at(payload, "max_iterations", "maxIterations") || value_at(nested, "max_iterations", "maxIterations"),
          "max_wall_clock_seconds" => value_at(payload, "max_wall_clock_seconds", "maxWallClockSeconds") || value_at(nested, "max_wall_clock_seconds", "maxWallClockSeconds"),
          "max_workers" => value_at(payload, "max_workers", "maxWorkers") || value_at(nested, "max_workers", "maxWorkers"),
          "max_consecutive_no_progress" => value_at(payload, "max_consecutive_no_progress", "maxConsecutiveNoProgress") || value_at(nested, "max_consecutive_no_progress", "maxConsecutiveNoProgress"),
          "min_metric_delta" => value_at(payload, "min_metric_delta", "minMetricDelta") || value_at(nested, "min_metric_delta", "minMetricDelta"),
          "min_seconds_between_iterations" => value_at(payload, "min_seconds_between_iterations", "minSecondsBetweenIterations") || value_at(nested, "min_seconds_between_iterations", "minSecondsBetweenIterations")
        }.compact
      end

      def goal_log_details(goal)
        {
          "goal_id" => goal.fetch("id"),
          "issue_id" => goal.fetch("issue_id", nil),
          "project_id" => goal.fetch("project_id", nil),
          "status" => goal.fetch("status", nil),
          "stop_reason" => goal.fetch("stop_reason", nil),
          "paused" => goal.fetch("paused", false),
          "current_iteration" => goal.fetch("current_iteration", 0),
          "max_iterations" => goal.dig("budget", "max_iterations"),
          "judge_mode" => goal.dig("judge", "mode"),
          "metric_command" => present_string(goal.dig("metric", "command")),
          "comparator" => present_string(goal.dig("metric", "command")) && goal.dig("metric", "comparator"),
          "target" => goal.dig("metric", "target"),
          "last_metric" => Goals::Record.metric_value(goal.fetch("last_metric", nil)),
          "best_metric" => Goals::Record.metric_value(goal.fetch("best_metric", nil)),
          "workers_spawned" => goal.fetch("workers_spawned", 0)
        }.compact
      end

      def find_goal(state, goal_id)
        return nil if blank?(goal_id)

        Ids.find_record(state.fetch("goals", []), goal_id)
      end

      def active_goal_for_issue(state, issue_id)
        state.fetch("goals", []).find do |goal|
          goal.fetch("issue_id", nil).to_s == issue_id.to_s && Goals::Record.loop_active?(goal)
        end
      end

      def issue_has_active_goal?(state, issue_id)
        !active_goal_for_issue(state, issue_id).nil?
      end

      def goals_for_issue_ids(state, issue_ids)
        ids = Array(issue_ids).compact.map(&:to_s)
        state.fetch("goals", []).select { |goal| ids.include?(goal.fetch("issue_id", nil).to_s) }
      end

      def next_goal_id!(state)
        state.fetch("counters")["goals"] = state.fetch("counters").fetch("goals", 0).to_i + 1
        "G#{state.fetch("counters").fetch("goals")}"
      end

      def truthy?(value)
        return false if value.nil?
        return value if [true, false].include?(value)

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end
    end
  end
end
