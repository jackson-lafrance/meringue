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
        return action("measure_baseline") if Record.metric_value(goal.fetch("baseline_metric", nil)).nil?

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
        when "judging"
          action("judge", "iteration_number" => number)
        else
          action("wait", "reason" => "unknown_phase", "iteration_number" => number)
        end
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
          return stop(
            "errored",
            "probe_unavailable",
            "Goal #{goal.fetch("id")} stopped because its metric command failed #{goal.fetch("consecutive_probe_failures")} times in a row."
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
          return stop(
            "blocked",
            "no_progress",
            "Goal #{goal.fetch("id")} stopped after #{goal.fetch("consecutive_no_progress")} iteration(s) without measurable progress."
          )
        end

        max_iterations = goal.dig("budget", "max_iterations").to_i
        if Record.settled_iterations(goal).length >= max_iterations
          return stop(
            "blocked",
            "max_iterations",
            "Goal #{goal.fetch("id")} reached its #{max_iterations} iteration budget."
          )
        end

        max_workers = goal.dig("budget", "max_workers").to_i
        if goal.fetch("workers_spawned", 0).to_i >= max_workers
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

      def start_iteration_action(goal, agents)
        number = Record.settled_iterations(goal).length + 1
        command_id = attempt_command_id(goal, number)
        previous_worker = continuation_worker(goal, agents)
        if previous_worker
          return action(
            "start_iteration",
            "mode" => "prompt",
            "number" => number,
            "command_id" => command_id,
            "worker_id" => previous_worker.fetch("id")
          )
        end

        action("start_iteration", "mode" => "spawn", "number" => number, "command_id" => command_id)
      end

      # `accumulate` continues the previous attempt's session (and therefore its branch and
      # worktree) instead of allocating a new worktree per iteration. A killed or errored
      # worker cannot be continued, so the loop falls back to a fresh spawn.
      def continuation_worker(goal, agents)
        return nil unless goal.fetch("continuity", nil).to_s == "accumulate"

        worker_id = Record.settled_iterations(goal).reverse.filter_map { |iteration| iteration.fetch("attempt_worker_id", nil) }.first
        return nil unless worker_id

        worker = find_agent(agents, worker_id)
        return nil unless worker
        return nil if %w[killed errored].include?(worker.fetch("status", nil).to_s)
        return nil unless session_reference?(worker)

        worker
      end

      # Deterministic per-iteration command id. Re-running the same iteration after a crash
      # or a duplicated tick reuses the kernel's existing exactly-once spawn dedupe instead
      # of creating a second worker.
      def attempt_command_id(goal, number)
        "#{goal.fetch("id")}-IT#{number}-ATTEMPT"
      end

      def find_agent(agents, agent_id)
        return nil unless Record.present_string(agent_id)

        Array(agents).find { |agent| agent.is_a?(Hash) && agent.fetch("id", nil).to_s == agent_id.to_s }
      end

      def terminal_agent?(agent)
        %w[completed errored killed].include?(agent.fetch("status", nil).to_s)
      end

      def session_reference?(agent)
        %w[pid harness_session_id harness_session_file].any? do |key|
          Record.present_string(agent.fetch(key, nil))
        end
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
