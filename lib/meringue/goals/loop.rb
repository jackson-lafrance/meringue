# frozen_string_literal: true

require "time"

require_relative "record"

module Meringue
  module Goals
    # The goal loop as a pure decision function.
    #
    # `next_action` answers exactly one question: given this durable goal record and the
    # current agent records, what is the single next thing the kernel should do? All
    # termination rules, budget accounting, and the single-flight invariant live here so
    # they can be tested with plain hashes and cannot drift from the kernel's behavior.
    #
    # The kernel performs the returned action, writes the outcome back to state, and calls
    # this again. Nothing here reads the clock, the filesystem, or a harness.
    module Loop
      module_function

      # Returns one of:
      #   { "action" => "none",           "reason" => ... }
      #   { "action" => "wait",           "reason" => ... }
      #   { "action" => "measure_baseline" }
      #   { "action" => "start_iteration","mode" => "spawn"|"prompt", "number" => n,
      #     "command_id" => ..., "worker_id" => (prompt only) }
      #   { "action" => "measure",        "iteration_number" => n }
      #   { "action" => "review",         "mode" => "spawn"|"collect", "iteration_number" => n,
      #     "command_id" => (spawn only), "attempt" => n, "review_worker_status" => (collect only) }
      #   { "action" => "judge",          "iteration_number" => n }
      #   { "action" => "stop",           "status" => ..., "stop_reason" => ..., "message" => ... }
      def next_action(goal:, agents: [], now: Time.now.utc)
        now = parse_time(now)
        return action("none", "reason" => "goal_not_active") unless Record.loop_active?(goal)
        return action("none", "reason" => "paused") if goal.fetch("paused", false)

        open_iteration = Record.open_iteration(goal)
        return open_iteration_action(goal, open_iteration, agents) if open_iteration

        stop = stop_action(goal, now)
        return stop if stop
        # A reviewer-judged goal has no number to baseline against: its "before" is the
        # success criteria the reviewer reads, not a measurement.
        if !Record.reviewer_judged?(goal) && Record.metric_value(goal.fetch("baseline_metric", nil)).nil?
          return action("measure_baseline")
        end

        rate_limit = rate_limit_action(goal, now)
        return rate_limit if rate_limit

        start_iteration_action(goal, agents)
      end

      # An in-flight attempt is the anti-fan-out invariant: while the attempt worker is
      # not terminal the loop can only wait, so one goal can never have two live workers.
      def open_iteration_action(goal, iteration, agents)
        number = iteration.fetch("number", goal.fetch("current_iteration", 0))
        case iteration.fetch("phase", nil).to_s
        when "attempting"
          worker_id = Record.present_string(iteration.fetch("attempt_worker_id", nil))
          # The phase is checkpointed before the spawn is issued, so an interrupted spawn
          # leaves an attempting iteration with no worker. Re-issuing it with the stored
          # deterministic command id resumes that iteration instead of duplicating it.
          unless worker_id
            return action(
              "start_iteration",
              "mode" => "spawn",
              "number" => number,
              "command_id" => iteration.fetch("attempt_command_id", nil) || attempt_command_id(goal, number),
              "resumed" => true
            )
          end

          worker = find_agent(agents, worker_id)
          return action("wait", "reason" => "attempt_in_flight", "iteration_number" => number) if worker && !terminal_agent?(worker)

          action(
            "measure",
            "iteration_number" => number,
            "attempt_worker_status" => worker ? worker.fetch("status", nil) : "missing"
          )
        when "measuring"
          action("measure", "iteration_number" => number)
        when "reviewing"
          review_action(goal, iteration, number, agents)
        when "judging"
          action("judge", "iteration_number" => number)
        else
          action("wait", "reason" => "unknown_phase", "iteration_number" => number)
        end
      end

      # A reviewer turn is sequenced exactly like an attempt: the kernel spawns it, and
      # while it is not terminal the loop can only wait. Nothing polls or sleeps; the next
      # reconcile tick observes the settled session and collects its verdict.
      def review_action(goal, iteration, number, agents)
        worker_id = Record.present_string(iteration.fetch("review_worker_id", nil))
        unless worker_id
          attempt = iteration.fetch("review_attempts", 0).to_i + 1
          return action(
            "review",
            "mode" => "spawn",
            "iteration_number" => number,
            "attempt" => attempt,
            "command_id" => Record.present_string(iteration.fetch("review_command_id", nil)) || review_command_id(goal, number, attempt)
          )
        end

        worker = find_agent(agents, worker_id)
        return action("wait", "reason" => "review_in_flight", "iteration_number" => number) if worker && !terminal_agent?(worker)

        action(
          "review",
          "mode" => "collect",
          "iteration_number" => number,
          "attempt" => iteration.fetch("review_attempts", 1).to_i,
          "review_worker_id" => worker_id,
          "review_worker_status" => worker ? worker.fetch("status", nil) : "missing"
        )
      end

      # Termination rules, in priority order. Success first, then the guards that mean
      # "stop spawning", then the budget ceilings.
      def stop_action(goal, now)
        last = Record.last_settled_iteration(goal)
        if last && last.fetch("verdict", nil).to_s == "met"
          return stop(
            "completed",
            "goal_met",
            "Goal #{goal.fetch("id")} met its success criteria at iteration #{last.fetch("number", 0)}."
          )
        end

        if goal.fetch("consecutive_probe_failures", 0).to_i >= Record::PROBE_FAILURE_LIMIT
          judge = if Record.reviewer_judged?(goal)
                    "reviewer returned an unusable verdict"
                  else
                    "metric command failed"
                  end
          return stop(
            "errored",
            "probe_unavailable",
            "Goal #{goal.fetch("id")} stopped because its #{judge} #{goal.fetch("consecutive_probe_failures")} times in a row."
          )
        end

        if (repeated = repeated_fingerprint(goal))
          return stop(
            "blocked",
            "oscillation",
            "Goal #{goal.fetch("id")} stopped because iteration #{repeated} reproduced an earlier workspace state."
          )
        end

        allowed_no_progress = goal.dig("budget", "max_consecutive_no_progress").to_i
        if allowed_no_progress.positive? && goal.fetch("consecutive_no_progress", 0).to_i >= allowed_no_progress
          # Without a metric, "no progress" means the reviewer asked for the same thing
          # again: the attempt is not moving the critique, so more iterations of the same
          # exchange will not either.
          detail = if Record.reviewer_judged?(goal)
                     "with the same reviewer critique"
                   else
                     "without measurable progress"
                   end
          return stop(
            "blocked",
            "no_progress",
            "Goal #{goal.fetch("id")} stopped after #{goal.fetch("consecutive_no_progress")} iteration(s) #{detail}."
          )
        end

        max_iterations = goal.dig("budget", "max_iterations").to_i
        if Record.settled_iterations(goal).length >= max_iterations
          # The expected end of a reviewer-judged goal that never got approved. It is a
          # reported outcome, not an error: the work and every critique are still on the
          # record, and raising the budget restarts the loop.
          suffix = Record.reviewer_judged?(goal) ? " without reviewer approval" : ""
          return stop(
            "blocked",
            "max_iterations",
            "Goal #{goal.fetch("id")} reached its #{max_iterations} iteration budget#{suffix}."
          )
        end

        # An iteration is atomic: an attempt that cannot be judged is a session spent for nothing.
        # So the budget must have room for the whole iteration before one starts — two sessions
        # for a reviewer-judged goal, one otherwise — rather than being checked per session and
        # overshooting on the review.
        max_workers = goal.dig("budget", "max_workers").to_i
        iteration_cost = Record.reviewer_judged?(goal) ? 2 : 1
        if goal.fetch("workers_spawned", 0).to_i + iteration_cost > max_workers
          return stop(
            "blocked",
            "budget_exhausted",
            "Goal #{goal.fetch("id")} reached its #{max_workers} agent-session budget."
          )
        end

        elapsed = elapsed_seconds(goal, now)
        max_wall_clock = goal.dig("budget", "max_wall_clock_seconds").to_i
        if elapsed && elapsed >= max_wall_clock
          return stop(
            "blocked",
            "budget_exhausted",
            "Goal #{goal.fetch("id")} reached its #{max_wall_clock}s wall-clock budget."
          )
        end

        nil
      end

      # A workspace state the goal already produced means the attempts are going in
      # circles; measuring it again cannot teach the loop anything new.
      def repeated_fingerprint(goal)
        seen = {}
        baseline_fingerprint = goal.dig("baseline_metric", "workspace_fingerprint")
        seen[baseline_fingerprint.to_s] = 0 if Record.present_string(baseline_fingerprint)

        Record.settled_iterations(goal).each do |iteration|
          fingerprint = Record.present_string(iteration.fetch("workspace_fingerprint", nil))
          next unless fingerprint

          number = iteration.fetch("number", 0)
          return number if seen.key?(fingerprint)

          seen[fingerprint] = number
        end
        nil
      end

      def rate_limit_action(goal, now)
        next_tick_at = parse_time(goal.fetch("next_tick_at", nil))
        return nil unless next_tick_at
        return nil if now >= next_tick_at

        action("wait", "reason" => "rate_limited", "next_tick_at" => goal.fetch("next_tick_at"))
      end

      # Every iteration is a new session. `accumulate` keeps the predecessor's worktree and
      # branch so progress and the metric are cumulative; `fresh_attempt` starts from a clean
      # tree. Neither re-prompts the previous attempt: the reflection an iteration needs is the
      # metric history and directive that AttemptPrompt renders, not a replayed transcript.
      def start_iteration_action(goal, _agents = nil)
        number = Record.settled_iterations(goal).length + 1
        action("start_iteration", "mode" => "spawn", "number" => number, "command_id" => attempt_command_id(goal, number))
      end

      # Deterministic per-iteration command id. Re-running the same iteration after a crash
      # or a duplicated tick reuses the kernel's existing exactly-once spawn dedupe instead
      # of creating a second worker.
      def attempt_command_id(goal, number)
        "#{goal.fetch("id")}-IT#{number}-ATTEMPT"
      end

      # Deterministic per-review command id. The retry after an unreadable verdict gets its
      # own id on purpose: reusing the first one would hit the kernel's exactly-once spawn
      # dedupe and hand back the same broken reviewer session.
      def review_command_id(goal, number, attempt = 1)
        suffix = attempt.to_i > 1 ? "-RETRY#{attempt.to_i}" : ""
        "#{goal.fetch("id")}-IT#{number}-REVIEW#{suffix}"
      end

      def find_agent(agents, agent_id)
        return nil unless Record.present_string(agent_id)

        Array(agents).find { |agent| agent.is_a?(Hash) && agent.fetch("id", nil).to_s == agent_id.to_s }
      end

      def terminal_agent?(agent)
        %w[completed errored killed].include?(agent.fetch("status", nil).to_s)
      end

      def elapsed_seconds(goal, now)
        started_at = parse_time(goal.fetch("started_at", nil) || goal.fetch("created_at", nil))
        return nil unless started_at

        now - started_at
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil?

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def action(name, extra = {})
        { "action" => name }.merge(extra)
      end

      def stop(status, stop_reason, message)
        action("stop", "status" => status, "stop_reason" => stop_reason, "message" => message)
      end
    end
  end
end
