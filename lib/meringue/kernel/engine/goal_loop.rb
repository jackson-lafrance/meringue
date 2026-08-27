# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # One tick of a goal loop: baseline, attempt, measurement, review, judgement, and the budget
      # guards that stop it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # One reconcile pass over every goal this instance may drive. Each goal advances at
      # most GOAL_MAX_STEPS_PER_TICK phases, and the loop's own single-flight invariant
      # means at most one attempt session can exist per goal at any time.
      def advance_goal_loops
        steps = []
        @goal_mutex.synchronize do
          goal_ids = synchronized_state do
            normalized_state.fetch("goals").filter_map do |goal|
              next unless Goals::Record.loop_active?(goal)
              next if goal.fetch("paused", false)
              # A goal driven by another live Meringue instance is that instance's to advance.
              next if goal_owned_by_other_live_instance?(goal)

              goal.fetch("id")
            end
          end

          deadline = monotonic_time + goal_advance_budget
          goal_ids.each do |goal_id|
            # Out of pass budget: the remaining goals are advanced by the next tick, so a slow
            # metric on one goal cannot starve session reconciliation.
            break if monotonic_time > deadline

            GOAL_MAX_STEPS_PER_TICK.times do
              step = advance_goal_loop_step(goal_id)
              break unless step

              steps << step
              break unless step.fetch("continue", false)
              break if monotonic_time > deadline
            end
          end
        end
        steps
      end

      # Performs exactly one phase transition for one goal: it asks the pure decision
      # function what to do, does it, and writes the outcome back. State is written before
      # every side effect so an interrupted step resumes instead of repeating.
      def advance_goal_loop_step(goal_id)
        context = synchronized_state do
          state = normalized_state
          goal = find_goal(state, goal_id)
          return nil unless goal
          return nil unless Goals::Record.loop_active?(goal)
          return nil if goal.fetch("paused", false)
          return nil if goal_owned_by_other_live_instance?(goal)

          claimed = claim_goal!(state, goal)
          if claimed
            touch_state!(state)
            store.save(state)
          end
          {
            "goal" => deep_copy(goal),
            "agents" => state.fetch("agents").map { |agent| goal_agent_snapshot(agent) }
          }
        end
        goal = context.fetch("goal")
        action = Goals::Loop.next_action(goal: goal, agents: context.fetch("agents"), now: Time.now.utc)

        case action.fetch("action")
        when "measure_baseline" then measure_goal_baseline(goal, action)
        when "start_iteration" then start_goal_iteration(goal, action)
        when "measure" then measure_goal_iteration(goal, action)
        when "review" then review_goal_iteration(goal, action)
        when "judge" then judge_goal_iteration(goal, action)
        when "stop" then stop_goal_loop(goal, action)
        else nil
        end
      end

      # Records this instance as the goal's driver and flips a freshly created goal to
      # working. Returns true when state changed so the caller only saves when needed.
      def claim_goal!(state, goal)
        changed = false
        now = timestamp
        ownership = instance_ownership_metadata
        if goal.fetch("owner_instance_id", nil).to_s != ownership.fetch("owner_instance_id").to_s
          goal.merge!(ownership)
          changed = true
        end
        if goal.fetch("status", nil) == "queued"
          goal["status"] = "working"
          goal["started_at"] ||= now
          changed = true
        end
        goal["started_at"] ||= goal.fetch("created_at", now)
        goal["updated_at"] = now if changed
        changed
      end

      def goal_agent_snapshot(agent)
        agent.slice("id", "type", "status", "issue_id", "pid", "harness_session_id", "harness_session_file", "workspace_path", "workspace_branch")
      end

      # The baseline is measured before the first attempt so "progress" means something.
      def measure_goal_baseline(goal, _action)
        cwd = goal_metric_cwd(goal, worker_id: nil)
        measurement = run_goal_metric(goal, cwd: cwd)

        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          now = timestamp
          current["baseline_metric"] = measurement
          current["last_metric"] ||= measurement
          current["best_metric"] ||= measurement
          probe_ok = Goals::Evaluator.probe_ok?(current, measurement)
          current["consecutive_probe_failures"] = probe_ok ? 0 : current.fetch("consecutive_probe_failures", 0).to_i + 1
          current["updated_at"] = now
          message = if probe_ok
                      "Goal #{current.fetch("id")} baseline metric is #{Goals::Record.format_number(Goals::Record.metric_value(measurement))} (target #{current.dig("metric", "comparator")} #{Goals::Record.format_number(current.dig("metric", "target"))})."
                    else
                      "Goal #{current.fetch("id")} could not measure its baseline metric: #{goal_measurement_problem(measurement)}"
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: probe_ok ? "info" : "warning",
            message: message,
            details: goal_log_details(current).merge("phase" => "baseline", "measurement" => measurement)
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "measure_baseline", message, log_ids, continue: probe_ok)
        end
      end

      # Starts one attempt: checkpoint the iteration first, then issue the spawn/prompt.
      # The deterministic command id makes a repeated spawn idempotent, so a crash between
      # the checkpoint and the spawn resumes the same iteration instead of adding a worker.
      def start_goal_iteration(goal, action)
        number = action.fetch("number")
        mode = action.fetch("mode")
        command_id = action.fetch("command_id")
        checkpoint = synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          now = timestamp
          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          unless iteration
            iteration = {
              "number" => number,
              "phase" => "attempting",
              "mode" => mode,
              "attempt_command_id" => command_id,
              "attempt_worker_id" => mode == "prompt" ? action.fetch("worker_id", nil) : nil,
              "started_at" => now
            }
            current.fetch("iterations") << iteration
          end
          iteration["phase"] = "attempting"
          iteration["attempt_command_id"] ||= command_id
          current["current_iteration"] = number
          # Budget is consumed at the attempt, not at success: a spawn that keeps failing
          # must still exhaust the budget rather than retry forever.
          current["workers_spawned"] = current.fetch("workers_spawned", 0).to_i + 1 if mode == "spawn"
          current["active_worker_id"] = iteration.fetch("attempt_worker_id", nil)
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          { "goal" => deep_copy(current), "iteration_number" => number }
        end

        current_goal = checkpoint.fetch("goal")
        prompt = Goals::AttemptPrompt.render(goal: current_goal, iteration_number: number, mode: mode)
        result = if mode == "prompt"
                   apply(
                     "command_id" => command_id,
                     "type" => "PromptAgent",
                     "payload" => { "agent_id" => action.fetch("worker_id"), "prompt" => prompt, "mode" => "normal" }
                   )
                 else
                   apply(
                     "command_id" => command_id,
                     "type" => "SpawnWorker",
                     "payload" => {
                       "issue_id" => current_goal.fetch("issue_id"),
                       "prompt" => prompt,
                       "title" => "#{current_goal.fetch("id")} iteration #{number}",
                       "follow_up_of_agent_id" => goal_follow_up_agent_id(current_goal),
                       # Lineage is recorded for both modes, but only `accumulate` continues in the
                       # predecessor's checkout. `fresh_attempt` opts out of the continuation default
                       # so its iterations really are independent attempts from a clean tree.
                       "share_workspace" => (false if current_goal.fetch("continuity", nil).to_s == "fresh_attempt")
                     }.compact
                   )
                 end

        record_goal_attempt_result(current_goal.fetch("id"), number, mode, result)
      end

      def record_goal_attempt_result(goal_id, number, mode, result)
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal_id)
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          accepted = result.fetch("status", nil) == "accepted"
          if accepted
            worker_id = result.fetch("target_id", nil)
            worker = find_agent(state, worker_id)
            iteration["attempt_worker_id"] = worker_id
            iteration["attempt_branch"] = worker && worker.fetch("workspace_branch", nil)
            iteration["attempt_workspace_path"] = worker && worker.fetch("workspace_path", nil)
            current["active_worker_id"] = worker_id
            message = "Goal #{current.fetch("id")} started iteration #{number} of #{current.dig("budget", "max_iterations")} on #{worker_id}."
            level = "info"
          else
            # A failed attempt is settled immediately as inconclusive: the no-progress guard
            # then stops the goal instead of the kernel retrying a broken spawn forever.
            iteration["phase"] = "settled"
            iteration["verdict"] = "inconclusive"
            iteration["settled_at"] = now
            iteration["evidence"] = ["attempt could not be started: #{result.fetch("message", "unknown error")}"]
            iteration["next_directive"] = nil
            current["consecutive_no_progress"] = current.fetch("consecutive_no_progress", 0).to_i + 1
            current["active_worker_id"] = nil
            current["next_tick_at"] = goal_next_tick_at(current, now)
            message = "Goal #{current.fetch("id")} could not start iteration #{number}: #{result.fetch("message", "unknown error")}"
            level = "warning"
          end
          current["updated_at"] = now
          trim_goal_iterations!(current)
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: level,
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "attempt",
              "iteration" => number,
              "mode" => mode,
              "attempt_worker_id" => iteration.fetch("attempt_worker_id", nil),
              "attempt_command_id" => iteration.fetch("attempt_command_id", nil)
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          # After a started attempt the only legal next decision is "wait", so this pass stops.
          goal_step(current, "start_iteration", message, log_ids, continue: !accepted)
        end
      end

      # Measures the metric and guardrails on the attempt's own branch, outside the state
      # lock, with the probe's timeout and output caps.
      def measure_goal_iteration(goal, action)
        number = action.fetch("iteration_number")
        prepared = synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          iteration["phase"] = "measuring"
          iteration["attempt_worker_status"] = action.fetch("attempt_worker_status", iteration.fetch("attempt_worker_status", nil))
          worker = find_agent(state, iteration.fetch("attempt_worker_id", nil))
          iteration["attempt_branch"] ||= worker && worker.fetch("workspace_branch", nil)
          iteration["attempt_workspace_path"] ||= worker && worker.fetch("workspace_path", nil)
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          { "goal" => deep_copy(current), "workspace_path" => iteration.fetch("attempt_workspace_path", nil) }
        end

        current_goal = prepared.fetch("goal")
        reviewer_judged = Goals::Record.reviewer_judged?(current_goal)
        cwd = goal_metric_cwd(current_goal, workspace_path: prepared.fetch("workspace_path", nil))
        # A reviewer-judged goal has no metric command to run; its guardrails and the
        # workspace fingerprint are still measured here, so "approved but red" and "the
        # attempt produced nothing new" stay detectable without a number.
        measurement = reviewer_judged ? nil : run_goal_metric(current_goal, cwd: cwd)
        guardrails = run_goal_guardrails(current_goal, cwd: cwd)
        fingerprint = goal_workspace_fingerprint(cwd)

        synchronized_state do
          state = normalized_state
          current = find_goal(state, current_goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          iteration["metric"] = measurement if measurement
          iteration["guardrails"] = guardrails
          iteration["workspace_fingerprint"] = fingerprint
          iteration["measured_at"] = now
          iteration["phase"] = reviewer_judged ? "reviewing" : "judging"
          current["updated_at"] = now
          guardrail_text = guardrails.empty? ? "" : ", guardrails #{guardrails.count { |guardrail| guardrail.fetch("passed", false) }}/#{guardrails.length} passing"
          message = if reviewer_judged
                      "Goal #{current.fetch("id")} checked iteration #{number} before review#{guardrail_text.sub(", ", ": ")}."
                    else
                      "Goal #{current.fetch("id")} measured iteration #{number}: #{Goals::Record.format_number(Goals::Record.metric_value(measurement))}#{guardrail_text}."
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: "info",
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "measure",
              "iteration" => number,
              "measurement" => measurement,
              "guardrails" => guardrails,
              "metric_cwd" => cwd
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "measure", message, log_ids, continue: true)
        end
      end

      # The review step of a reviewer-judged goal, in two halves.
      #
      # `spawn` starts a short-lived reviewer session on the attempt's own workspace and
      # branch, using the ordinary worker-spawn path: that gives the reviewer a tracked
      # agent record, the kernel's exactly-once spawn dedupe, the AgentTree, and the kill
      # cascade for free. The kernel then does nothing until the tick observes that session
      # settle — no polling, no sleeping, no waiting on another agent's state.
      #
      # `collect` reads the settled reviewer's final message and turns it into a verdict.
      def review_goal_iteration(goal, action)
        return collect_goal_review(goal, action) if action.fetch("mode", "spawn").to_s == "collect"

        start_goal_review(goal, action)
      end

      def start_goal_review(goal, action)
        number = action.fetch("iteration_number")
        command_id = action.fetch("command_id")
        attempt = action.fetch("attempt", 1).to_i
        checkpoint = synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          iteration["review_attempts"] = attempt
          iteration["review_command_id"] = command_id
          iteration["review_worker_id"] = nil
          # A reviewer session is a session: it consumes the goal's session budget like an
          # attempt does, so a goal can never spawn more sessions than its budget allows.
          current["workers_spawned"] = current.fetch("workers_spawned", 0).to_i + 1
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          {
            "goal" => deep_copy(current),
            "iteration" => deep_copy(iteration),
            "workspace_path" => iteration.fetch("attempt_workspace_path", nil),
            "retry_reason" => attempt > 1 ? iteration.dig("review", "error") || iteration.fetch("review_error", nil) : nil
          }
        end

        current_goal = checkpoint.fetch("goal")
        cwd = goal_review_cwd(current_goal, workspace_path: checkpoint.fetch("workspace_path", nil))
        prompt = Goals::ReviewPrompt.render(
          goal: current_goal,
          iteration: checkpoint.fetch("iteration"),
          retry_reason: checkpoint.fetch("retry_reason", nil)
        )
        result = apply(
          "command_id" => command_id,
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => current_goal.fetch("issue_id"),
            "prompt" => prompt,
            "title" => "#{current_goal.fetch("id")} iteration #{number} review",
            "workspace_path" => cwd
          }.compact
        )

        record_goal_review_spawn(current_goal.fetch("id"), number, result)
      end

      def record_goal_review_spawn(goal_id, number, result)
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal_id)
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          accepted = result.fetch("status", nil) == "accepted"
          if accepted
            worker_id = result.fetch("target_id", nil)
            iteration["review_worker_id"] = worker_id
            current["active_worker_id"] = worker_id
            message = "Goal #{current.fetch("id")} started the review of iteration #{number} on #{worker_id}."
            level = "info"
          else
            # A reviewer that cannot be started is an unreadable verdict, not a retry loop:
            # the iteration settles inconclusive and the probe-failure guard decides whether
            # the goal can continue at all.
            iteration["review"] = Goals::ReviewVerdict.unusable("the reviewer session could not be started: #{result.fetch("message", "unknown error")}")
            iteration["phase"] = "judging"
            current["active_worker_id"] = nil
            message = "Goal #{current.fetch("id")} could not start the review of iteration #{number}: #{result.fetch("message", "unknown error")}"
            level = "warning"
          end
          current["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: level,
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "review",
              "iteration" => number,
              "review_worker_id" => iteration.fetch("review_worker_id", nil),
              "review_command_id" => iteration.fetch("review_command_id", nil),
              "review_attempts" => iteration.fetch("review_attempts", 1)
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          # After a started review the only legal next decision is "wait", so this pass stops.
          goal_step(current, "review", message, log_ids, continue: !accepted)
        end
      end

      def collect_goal_review(goal, action)
        number = action.fetch("iteration_number")
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          worker = find_agent(state, iteration.fetch("review_worker_id", nil))
          worker_status = action.fetch("review_worker_status", worker && worker.fetch("status", nil)).to_s
          text = worker && (worker.fetch("harness_metadata", {}) || {}).fetch("last_assistant_text", nil)
          review = if present_string(text)
                     Goals::ReviewVerdict.parse(text)
                   else
                     Goals::ReviewVerdict.unusable("the reviewer session ended #{worker_status.empty? ? "without a final message" : worker_status} with no verdict")
                   end
          review = review.merge(
            "review_worker_id" => iteration.fetch("review_worker_id", nil),
            "reviewed_at" => now,
            "attempt" => iteration.fetch("review_attempts", 1)
          ).compact

          attempts = iteration.fetch("review_attempts", 1).to_i
          retryable = !review.fetch("usable", false) && attempts < Goals::Record::REVIEW_ATTEMPT_LIMIT
          if retryable
            # One retry, with the parse failure quoted back at the reviewer. A second
            # unreadable answer is treated as a verdict-less iteration rather than paid for
            # a third time.
            iteration["review_error"] = review.fetch("error", nil)
            iteration["review_worker_id"] = nil
            iteration["review_command_id"] = nil
            iteration["phase"] = "reviewing"
            current["active_worker_id"] = nil
            message = "Goal #{current.fetch("id")} could not read the reviewer's verdict for iteration #{number} (#{review.fetch("error", "no verdict")}); asking once more."
            level = "warning"
          else
            iteration["review"] = review
            iteration["review_worker_status"] = worker_status.empty? ? "missing" : worker_status
            iteration["phase"] = "judging"
            current["active_worker_id"] = nil
            message = "Goal #{current.fetch("id")} reviewer verdict for iteration #{number}: #{Goals::Record.review_line(review)}"
            level = review.fetch("usable", false) ? "info" : "warning"
          end
          current["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: level,
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "review",
              "iteration" => number,
              "review_worker_id" => worker && worker.fetch("id", nil),
              "review_worker_status" => worker_status,
              "review_attempts" => attempts,
              "approved" => review.fetch("approved", false),
              "review_usable" => review.fetch("usable", false),
              "critique" => review.fetch("critique", [])
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "review", message, log_ids, continue: true)
        end
      end

      # The judge step. Deterministic today: it scores the measurement against the metric
      # and guardrails, or the reviewer's verdict against the success criteria, records the
      # verdict, and writes the directive the next attempt gets.
      def judge_goal_iteration(goal, action)
        number = action.fetch("iteration_number")
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          judgement = Goals::Evaluator.evaluate(goal: current, iteration: iteration)
          now = timestamp
          iteration["verdict"] = judgement.fetch("verdict")
          iteration["score"] = judgement.fetch("score")
          iteration["metric_delta"] = judgement.fetch("metric_delta")
          iteration["evidence"] = judgement.fetch("evidence")
          iteration["gaming_suspected"] = judgement.fetch("gaming_suspected")
          iteration["next_directive"] = judgement.fetch("next_directive")
          iteration["judged_by"] = current.dig("judge", "mode")
          iteration["phase"] = "settled"
          iteration["settled_at"] = now
          iteration["duration_seconds"] = goal_duration_seconds(iteration.fetch("started_at", nil), now)

          measurement = iteration.fetch("metric", nil)
          if judgement.fetch("probe_ok")
            if measurement
              current["last_metric"] = measurement
              current["best_metric"] = Goals::Record.better_measurement(current, current.fetch("best_metric", nil), measurement)
            end
            current["consecutive_probe_failures"] = 0
          else
            # An unreadable reviewer verdict is the reviewer-judged goal's broken probe: two
            # in a row stop the loop for the same reason an unreadable metric command does.
            current["consecutive_probe_failures"] = current.fetch("consecutive_probe_failures", 0).to_i + 1
          end
          current["consecutive_no_progress"] = judgement.fetch("progress") ? 0 : current.fetch("consecutive_no_progress", 0).to_i + 1
          current["active_worker_id"] = nil
          current["last_worker_id"] = iteration.fetch("attempt_worker_id", nil)
          current["next_tick_at"] = goal_next_tick_at(current, now)
          current["updated_at"] = now
          trim_goal_iterations!(current)

          message = "Goal #{current.fetch("id")} iteration #{number} verdict #{judgement.fetch("verdict")}: #{judgement.fetch("evidence").first || "no evidence"}."
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: judgement.fetch("gaming_suspected") ? "warning" : "info",
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "judge",
              "iteration" => number,
              "verdict" => judgement.fetch("verdict"),
              "score" => judgement.fetch("score"),
              "metric_delta" => judgement.fetch("metric_delta"),
              "evidence" => judgement.fetch("evidence"),
              "gaming_suspected" => judgement.fetch("gaming_suspected"),
              "next_directive" => judgement.fetch("next_directive"),
              "judge_mode" => current.dig("judge", "mode")
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "judge", message, log_ids, continue: true)
        end
      end

      # Terminal transition for a goal loop. Every stop is durable, logged with its reason,
      # and reflected on the owning issue; a guard stop also asks the user a question so a
      # stalled goal surfaces in the questions list instead of going quiet.
      def stop_goal_loop(goal, action)
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current
          return nil unless Goals::Record.loop_active?(current)

          now = timestamp
          stop_reason = action.fetch("stop_reason")
          settle_goal_record!(current, status: action.fetch("status"), stop_reason: stop_reason, now: now)
          issue = find_issue(state, current.fetch("issue_id", nil))
          if issue
            issue["status"] = stop_reason == "goal_met" ? "completed" : "blocked"
            issue["updated_at"] = now
            project = find_project(state, issue.fetch("project_id", nil))
            update_project_status_from_issues!(state, project, now) if project
          end

          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: stop_reason == "goal_met" ? "info" : "warning",
            message: action.fetch("message"),
            details: goal_log_details(current).merge("phase" => "stop", "iterations_settled" => Goals::Record.settled_iterations(current).length)
          )

          unless %w[goal_met user_stopped killed].include?(stop_reason)
            question = build_question(
              state: state,
              head_id: nil,
              question_text: goal_stop_question(current, action),
              context: "#{action.fetch("message")} #{Goals::Record.summary(current)}",
              project_id: current.fetch("project_id", nil),
              issue_id: current.fetch("issue_id", nil)
            )
            state.fetch("questions") << question
            current["question_id"] = question.fetch("id")
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: question.fetch("id"),
              level: "info",
              message: "Question #{question.fetch("id")}: #{question.fetch("question")}",
              details: { "goal_id" => current.fetch("id"), "stop_reason" => stop_reason }
            ))
          end

          touch_state!(state, now)
          store.save(state)
          goal_step(current, "stop", action.fetch("message"), log_ids, continue: false)
        end
      end

      def goal_stop_question(goal, action)
        return reviewer_goal_stop_question(goal, action) if Goals::Record.reviewer_judged?(goal)

        case goal.fetch("stop_reason", nil)
        when "no_progress"
          "Goal #{goal.fetch("id")} stopped after #{goal.fetch("consecutive_no_progress")} iteration(s) with no measurable progress (metric #{Goals::Record.format_number(Goals::Record.metric_value(goal.fetch("last_metric", nil)))} vs target #{Goals::Record.format_number(Goals::Record.target(goal))}). Change the approach, adjust the goal, or stop it?"
        when "oscillation"
          "Goal #{goal.fetch("id")} stopped because its attempts started repeating the same workspace state. Should it try a different approach, or stop?"
        when "probe_unavailable"
          "Goal #{goal.fetch("id")} stopped because its metric command `#{goal.dig("metric", "command")}` keeps failing. Fix the command, change the metric, or stop the goal?"
        when "max_iterations"
          "Goal #{goal.fetch("id")} used its #{goal.dig("budget", "max_iterations")} iteration budget and reached #{Goals::Record.format_number(Goals::Record.metric_value(goal.fetch("last_metric", nil)))} of #{Goals::Record.format_number(Goals::Record.target(goal))}. Raise the budget, accept the result, or stop?"
        else
          "#{action.fetch("message")} How should this goal continue?"
        end
      end

      # Reaching the iteration cap without approval is the ordinary end of a reviewer-judged
      # goal, so the question says what the reviewer last asked for instead of reporting a
      # failure the user cannot act on.
      def reviewer_goal_stop_question(goal, action)
        last_critique = Array(Goals::Record.last_review(goal)&.fetch("critique", [])).first
        outstanding = last_critique ? " The reviewer's last outstanding point: #{last_critique}" : ""
        case goal.fetch("stop_reason", nil)
        when "no_progress"
          "Goal #{goal.fetch("id")} stopped after #{goal.fetch("consecutive_no_progress")} iteration(s) where the reviewer repeated the same critique.#{outstanding} Change the approach, adjust the success criteria, or stop it?"
        when "oscillation"
          "Goal #{goal.fetch("id")} stopped because its attempts started repeating the same workspace state. Should it try a different approach, or stop?"
        when "probe_unavailable"
          "Goal #{goal.fetch("id")} stopped because its reviewer did not return a usable verdict twice in a row. Restart the goal, reword the success criteria, or stop it?"
        when "max_iterations"
          "Goal #{goal.fetch("id")} used its #{goal.dig("budget", "max_iterations")} iteration budget without reviewer approval.#{outstanding} Raise the budget, accept the work as it is, or stop?"
        else
          "#{action.fetch("message")} How should this goal continue?"
        end
      end

      def goal_step(goal, phase, message, log_entry_ids, continue:)
        {
          "goal_id" => goal.fetch("id"),
          "phase" => phase,
          "status" => goal.fetch("status", nil),
          "stop_reason" => goal.fetch("stop_reason", nil),
          "iteration" => goal.fetch("current_iteration", 0),
          "message" => message,
          "changed" => true,
          "continue" => continue,
          "log_entry_ids" => Array(log_entry_ids)
        }
      end

      def run_goal_metric(goal, cwd:)
        metric = goal.fetch("metric", {}) || {}
        measurement = metric_probe.measure(
          command: metric.fetch("command", nil),
          cwd: cwd,
          parse: metric.fetch("parse", {}),
          timeout: metric.fetch("timeout_seconds", Goals::Record::DEFAULT_METRIC_TIMEOUT_SECONDS)
        )
        (measurement.is_a?(Hash) ? measurement : {}).merge(
          "measured_at" => timestamp,
          "cwd" => cwd,
          "command" => metric.fetch("command", nil)
        )
      rescue StandardError => e
        { "value" => nil, "error" => sanitized_error_message(e), "exit_status" => nil, "timed_out" => false, "measured_at" => timestamp, "cwd" => cwd }
      end

      def run_goal_guardrails(goal, cwd:)
        Array(goal.dig("metric", "guardrails")).first(Goals::Record::MAX_GUARDRAILS).map do |guardrail|
          begin
            metric_probe.check_guardrail(
              command: guardrail.fetch("command", nil),
              cwd: cwd,
              timeout: goal.dig("metric", "timeout_seconds") || Goals::Record::DEFAULT_METRIC_TIMEOUT_SECONDS
            )
          rescue StandardError => e
            { "command" => guardrail.fetch("command", nil), "passed" => false, "error" => sanitized_error_message(e) }
          end
        end
      end

      def goal_workspace_fingerprint(cwd)
        metric_probe.workspace_fingerprint(cwd: cwd)
      rescue StandardError
        nil
      end

      # A reviewer reads the attempt's own worktree and branch. The workspace is adopted,
      # not allocated: the reviewer never gets a worktree of its own, so it cannot review a
      # copy of the work and its session is never charged a branch.
      def goal_review_cwd(goal, workspace_path: nil)
        path = present_string(workspace_path)
        return path if path && Dir.exist?(path)

        project_root_for_goal(goal)
      end

      # The metric runs on the attempt's own workspace by default, so it measures the branch
      # the attempt actually produced. `project_root` metrics and the pre-attempt baseline
      # fall back to the registered project root.
      def goal_metric_cwd(goal, worker_id: :unset, workspace_path: nil)
        return project_root_for_goal(goal) if goal.dig("metric", "cwd").to_s == "project_root"

        path = present_string(workspace_path)
        path ||= synchronized_state do
          state = normalized_state
          worker = find_agent(state, worker_id == :unset ? goal.fetch("active_worker_id", nil) : worker_id)
          worker && present_string(worker.fetch("workspace_path", nil))
        end
        return path if path && Dir.exist?(path)

        project_root_for_goal(goal)
      end

      def project_root_for_goal(goal)
        synchronized_state do
          state = normalized_state
          project = find_project(state, goal.fetch("project_id", nil))
          project && present_string(project.fetch("root_path", nil))
        end
      end

      def goal_follow_up_agent_id(goal)
        worker_id = Goals::Record.settled_iterations(goal).reverse.filter_map { |iteration| iteration.fetch("attempt_worker_id", nil) }.first
        return nil unless present_string(worker_id)

        synchronized_state do
          state = normalized_state
          worker = find_agent(state, worker_id)
          next nil unless worker
          next nil unless worker.fetch("issue_id", nil).to_s == goal.fetch("issue_id", nil).to_s

          worker.fetch("id")
        end
      end

      def goal_next_tick_at(goal, now)
        seconds = goal.dig("budget", "min_seconds_between_iterations").to_i
        return nil unless seconds.positive?

        (Time.parse(now.to_s) + seconds).utc.iso8601
      rescue ArgumentError, TypeError
        nil
      end

      def goal_duration_seconds(started_at, now)
        return nil if blank?(started_at)

        (Time.parse(now.to_s) - Time.parse(started_at.to_s)).round
      rescue ArgumentError, TypeError
        nil
      end

      def goal_measurement_problem(measurement)
        return "the metric command timed out" if measurement.fetch("timed_out", false)
        return measurement.fetch("error") if present_string(measurement.fetch("error", nil))
        return measurement.fetch("parse_error") if present_string(measurement.fetch("parse_error", nil))

        "the metric command exited #{measurement.fetch("exit_status", "non-zero")}"
      end

      def trim_goal_iterations!(goal)
        iterations = Goals::Record.iterations(goal)
        return if iterations.length <= Goals::Record::ITERATION_HISTORY_LIMIT

        goal["iterations"] = iterations.last(Goals::Record::ITERATION_HISTORY_LIMIT)
      end

      def settle_goal_record!(goal, status:, stop_reason:, now:)
        goal["status"] = status
        goal["stop_reason"] = stop_reason
        goal["settled_at"] = now
        goal["updated_at"] = now
        goal["last_worker_id"] = goal.fetch("active_worker_id", nil) if present_string(goal.fetch("active_worker_id", nil))
        goal["active_worker_id"] = nil
        goal
      end
    end
  end
end
