# frozen_string_literal: true

require_relative "review_verdict"

module Meringue
  # Goal loops are the durable, kernel-owned controller for "keep working until this
  # measurable criterion is met". A goal is not an agent and not a new AgentTree node
  # kind: it is a record attached to exactly one issue that adds success criteria, a
  # deterministic metric, budgets, and iteration history to that issue.
  #
  # Everything in this module is pure and I/O free so the loop decisions can be unit
  # tested with plain hashes. Command execution lives in Goals::MetricProbe and state
  # mutation lives in the kernel.
  module Goals
    module Record
      ID_PATTERN = /^G(\d+)$/.freeze

      # Only metric-driven goals exist today. "research" and "best_of_n" goals are
      # deliberately deferred: without a trustworthy metric they have no stopping rule.
      KINDS = %w[metric].freeze
      DEFAULT_KIND = "metric"

      # Two judges exist.
      #
      # `metric_only` is the deterministic one: the kernel runs a command, reads a number,
      # and compares it to a target. It is the default and the right judge whenever the
      # success condition can be counted.
      #
      # `reviewer` covers the goals that have no number at all ("this onboarding reads
      # well", "the UX feels right"). Each iteration is judged by a short-lived reviewer
      # session the kernel spawns on the attempt's own branch; it returns a structured
      # verdict (approved + rationale + actionable critique) that either ends the loop or
      # becomes the next attempt's directive.
      #
      # The remaining modes combine the two ("the metric says met, is it actually met?")
      # and are still deferred: they need a second gate ordering that neither judge needs
      # on its own.
      METRIC_JUDGE_MODE = "metric_only"
      REVIEWER_JUDGE_MODE = "reviewer"
      JUDGE_MODES = [METRIC_JUDGE_MODE, REVIEWER_JUDGE_MODE].freeze
      DEFERRED_JUDGE_MODES = %w[worker_when_metric_met worker_every_iteration].freeze
      DEFAULT_JUDGE_MODE = METRIC_JUDGE_MODE

      # `fresh_attempt` spawns a new worker (and worktree) per iteration.
      # `accumulate` re-prompts the previous worker so one branch keeps growing.
      CONTINUITY_MODES = %w[fresh_attempt accumulate].freeze
      DEFAULT_CONTINUITY = "accumulate"

      COMPARATORS = %w[gte lte gt lt eq].freeze
      DEFAULT_COMPARATOR = "gte"

      PARSE_TYPES = %w[last_number first_number regex json_path exit_status].freeze
      DEFAULT_PARSE_TYPE = "last_number"

      METRIC_CWD_MODES = %w[workspace project_root].freeze
      DEFAULT_METRIC_CWD = "workspace"

      PHASES = %w[attempting measuring reviewing judging settled].freeze
      VERDICTS = %w[met partially_met not_met inconclusive].freeze

      STOP_REASONS = %w[
        goal_met max_iterations budget_exhausted no_progress oscillation
        probe_unavailable user_stopped killed
      ].freeze

      # A goal that is `queued` or `working` is driven by the reconcile tick. Every other
      # lifecycle status means the loop has settled and will not spawn again on its own.
      ACTIVE_STATUSES = %w[queued working].freeze

      DEFAULT_MAX_ITERATIONS = 5
      # Hard ceiling regardless of what a user or head asks for. The loop must never be
      # able to spawn an unbounded number of sessions.
      MAX_ITERATIONS_CEILING = 20
      DEFAULT_MAX_WALL_CLOCK_SECONDS = 4 * 60 * 60
      MAX_WALL_CLOCK_CEILING_SECONDS = 24 * 60 * 60
      DEFAULT_MAX_CONSECUTIVE_NO_PROGRESS = 2
      DEFAULT_MIN_METRIC_DELTA = 0.0
      DEFAULT_MIN_SECONDS_BETWEEN_ITERATIONS = 15
      MIN_SECONDS_BETWEEN_ITERATIONS_CEILING = 60 * 60
      DEFAULT_METRIC_TIMEOUT_SECONDS = 600
      METRIC_TIMEOUT_CEILING_SECONDS = 60 * 60
      # Guardrails run on every measured iteration, so the count is capped to keep the
      # probe phase bounded.
      MAX_GUARDRAILS = 3
      # Two consecutive broken probes mean the goal's signal itself is unusable — a metric
      # command that cannot be read, or a reviewer that will not return a verdict.
      # Continuing would burn sessions against a signal nobody can read.
      PROBE_FAILURE_LIMIT = 2
      # One reviewer turn per iteration, plus one retry when the first turn returns
      # something the kernel cannot act on. A third turn would just pay for the same
      # broken reviewer again; the iteration is settled `inconclusive` instead.
      REVIEW_ATTEMPT_LIMIT = 2
      ITERATION_HISTORY_LIMIT = 20
      OUTPUT_TAIL_LIMIT = 2_000

      module_function

      def normalize_goals!(state)
        state["goals"] = [] unless state["goals"].is_a?(Array)
        state["goals"] = state.fetch("goals").select { |goal| goal.is_a?(Hash) }
        state.fetch("goals").each { |goal| normalize!(goal) }
        state
      end

      # Durable shape enforcement. State written by an older Meringue version, or hand
      # edited state, must never make the loop crash or spawn without budgets.
      def normalize!(goal)
        goal["kind"] = KINDS.include?(goal["kind"].to_s) ? goal["kind"].to_s : DEFAULT_KIND
        goal["status"] = goal["status"].to_s.empty? ? "queued" : goal["status"].to_s
        goal["paused"] = goal["paused"] ? true : false
        goal["stop_reason"] = STOP_REASONS.include?(goal["stop_reason"].to_s) ? goal["stop_reason"].to_s : nil
        goal["continuity"] = CONTINUITY_MODES.include?(goal["continuity"].to_s) ? goal["continuity"].to_s : DEFAULT_CONTINUITY
        goal["metric"] = normalized_metric(goal["metric"])
        goal["judge"] = normalized_judge(goal["judge"])
        goal["budget"] = normalized_budget(goal["budget"])
        goal["current_iteration"] = nonnegative_integer(goal["current_iteration"])
        goal["workers_spawned"] = nonnegative_integer(goal["workers_spawned"])
        goal["consecutive_no_progress"] = nonnegative_integer(goal["consecutive_no_progress"])
        goal["consecutive_probe_failures"] = nonnegative_integer(goal["consecutive_probe_failures"])
        goal["iterations"] = normalized_iterations(goal["iterations"])
        goal["baseline_metric"] = normalized_measurement(goal["baseline_metric"])
        goal["last_metric"] = normalized_measurement(goal["last_metric"])
        goal["best_metric"] = normalized_measurement(goal["best_metric"])
        goal
      end

      def normalized_metric(metric)
        metric = {} unless metric.is_a?(Hash)
        parse = metric["parse"].is_a?(Hash) ? metric["parse"] : {}
        parse_type = PARSE_TYPES.include?(parse["type"].to_s) ? parse["type"].to_s : DEFAULT_PARSE_TYPE
        {
          "command" => metric["command"].to_s,
          "cwd" => METRIC_CWD_MODES.include?(metric["cwd"].to_s) ? metric["cwd"].to_s : DEFAULT_METRIC_CWD,
          "comparator" => COMPARATORS.include?(metric["comparator"].to_s) ? metric["comparator"].to_s : DEFAULT_COMPARATOR,
          "target" => float_or_nil(metric["target"]),
          "timeout_seconds" => bounded_number(
            metric["timeout_seconds"],
            default: DEFAULT_METRIC_TIMEOUT_SECONDS,
            min: 1,
            max: METRIC_TIMEOUT_CEILING_SECONDS
          ).to_i,
          "parse" => {
            "type" => parse_type,
            "pattern" => present_string(parse["pattern"]),
            "capture" => parse["capture"].nil? ? 1 : nonnegative_integer(parse["capture"]),
            "path" => present_string(parse["path"])
          }.compact,
          "guardrails" => normalized_guardrails(metric["guardrails"])
        }
      end

      def normalized_guardrails(guardrails)
        Array(guardrails).filter_map do |guardrail|
          command = guardrail.is_a?(Hash) ? guardrail["command"] : guardrail
          next nil unless present_string(command)

          { "command" => command.to_s, "expect" => "exit_zero" }
        end.first(MAX_GUARDRAILS)
      end

      def normalized_judge(judge)
        judge = {} unless judge.is_a?(Hash)
        mode = judge["mode"].to_s
        {
          "mode" => JUDGE_MODES.include?(mode) ? mode : DEFAULT_JUDGE_MODE,
          "requested_mode" => DEFERRED_JUDGE_MODES.include?(mode) ? mode : nil
        }.compact
      end

      # A goal whose success condition is a reviewer's judgement rather than a number.
      def reviewer_judged?(goal)
        return false unless goal.is_a?(Hash)

        goal.dig("judge", "mode").to_s == REVIEWER_JUDGE_MODE
      end

      def normalized_budget(budget)
        budget = {} unless budget.is_a?(Hash)
        max_iterations = bounded_number(
          budget["max_iterations"],
          default: DEFAULT_MAX_ITERATIONS,
          min: 1,
          max: MAX_ITERATIONS_CEILING
        ).to_i
        {
          "max_iterations" => max_iterations,
          "max_wall_clock_seconds" => bounded_number(
            budget["max_wall_clock_seconds"],
            default: DEFAULT_MAX_WALL_CLOCK_SECONDS,
            min: 1,
            max: MAX_WALL_CLOCK_CEILING_SECONDS
          ).to_i,
          "max_workers" => bounded_number(
            budget["max_workers"],
            default: default_max_workers(max_iterations),
            min: 1,
            max: default_max_workers(MAX_ITERATIONS_CEILING)
          ).to_i,
          "max_consecutive_no_progress" => bounded_number(
            budget["max_consecutive_no_progress"],
            default: DEFAULT_MAX_CONSECUTIVE_NO_PROGRESS,
            min: 1,
            max: MAX_ITERATIONS_CEILING
          ).to_i,
          "min_metric_delta" => [float_or_nil(budget["min_metric_delta"]) || DEFAULT_MIN_METRIC_DELTA, 0.0].max,
          "min_seconds_between_iterations" => bounded_number(
            budget["min_seconds_between_iterations"],
            default: DEFAULT_MIN_SECONDS_BETWEEN_ITERATIONS,
            min: 0,
            max: MIN_SECONDS_BETWEEN_ITERATIONS_CEILING
          ).to_i
        }
      end

      def default_max_workers(max_iterations)
        (max_iterations.to_i * 2) + 2
      end

      def normalized_iterations(iterations)
        Array(iterations).select { |iteration| iteration.is_a?(Hash) }.map do |iteration|
          iteration["number"] = nonnegative_integer(iteration["number"])
          iteration["phase"] = PHASES.include?(iteration["phase"].to_s) ? iteration["phase"].to_s : "attempting"
          iteration["verdict"] = VERDICTS.include?(iteration["verdict"].to_s) ? iteration["verdict"].to_s : nil
          iteration["guardrails"] = Array(iteration["guardrails"]).select { |entry| entry.is_a?(Hash) }
          iteration["evidence"] = Array(iteration["evidence"]).map(&:to_s)
          iteration["review_attempts"] = nonnegative_integer(iteration["review_attempts"]) if iteration.key?("review_attempts")
          iteration["review"] = ReviewVerdict.normalize(iteration["review"]) if iteration["review"].is_a?(Hash)
          iteration
        end.last(ITERATION_HISTORY_LIMIT)
      end

      def normalized_measurement(measurement)
        return nil unless measurement.is_a?(Hash)

        measurement
      end

      # --- derived helpers -------------------------------------------------------

      def loop_active?(goal)
        ACTIVE_STATUSES.include?(goal.fetch("status", nil).to_s)
      end

      def iterations(goal)
        Array(goal.fetch("iterations", []))
      end

      def settled_iterations(goal)
        iterations(goal).select { |iteration| iteration.fetch("phase", nil).to_s == "settled" }
      end

      def open_iteration(goal)
        iterations(goal).reverse.find { |iteration| iteration.fetch("phase", nil).to_s != "settled" }
      end

      def last_settled_iteration(goal)
        settled_iterations(goal).last
      end

      # The most recent reviewer verdict, settled or in flight. Used for the visible
      # "iteration N of M, last verdict, last critique" surfacing.
      def last_review(goal)
        iterations(goal).reverse.map { |iteration| iteration.fetch("review", nil) }.find { |review| review.is_a?(Hash) }
      end

      def review_state(goal)
        review = last_review(goal)
        return "not reviewed yet" unless review
        return "unreadable verdict" unless review.fetch("usable", false)

        review.fetch("approved", false) ? "approved" : "changes requested"
      end

      # One short line describing a reviewer verdict, for logs and list output.
      def review_line(review)
        return nil unless review.is_a?(Hash)
        return "reviewer verdict unusable: #{review.fetch("error", "no verdict")}" unless review.fetch("usable", false)
        return "approved#{review.fetch("rationale", nil) ? ": #{review.fetch("rationale")}" : ""}" if review.fetch("approved", false)

        detail = Array(review.fetch("critique", [])).first || review.fetch("rationale", nil)
        "changes requested#{detail ? ": #{detail}" : ""}"
      end

      def metric_value(measurement)
        return nil unless measurement.is_a?(Hash)

        float_or_nil(measurement["value"])
      end

      def target(goal)
        float_or_nil(goal.dig("metric", "target"))
      end

      def comparator(goal)
        goal.dig("metric", "comparator").to_s
      end

      # True when the measured value already satisfies the goal's comparator/target.
      def target_satisfied?(goal, value)
        value = float_or_nil(value)
        target_value = target(goal)
        return false if value.nil? || target_value.nil?

        case comparator(goal)
        when "gte" then value >= target_value
        when "gt" then value > target_value
        when "lte" then value <= target_value
        when "lt" then value < target_value
        when "eq" then value == target_value
        else false
        end
      end

      # Signed improvement toward the target. A `lte`/`lt` goal improves when the number
      # goes down, so raw deltas cannot be compared against the progress threshold.
      def improvement(goal, from_value, to_value)
        from_value = float_or_nil(from_value)
        to_value = float_or_nil(to_value)
        return nil if from_value.nil? || to_value.nil?

        case comparator(goal)
        when "lte", "lt" then from_value - to_value
        when "eq"
          target_value = target(goal)
          return nil if target_value.nil?

          (from_value - target_value).abs - (to_value - target_value).abs
        else to_value - from_value
        end
      end

      # 0.0 at the baseline, 1.0 once the target is reached. Used for the visible
      # progress score; the verdict itself comes from the comparator and guardrails.
      def progress_score(goal, value)
        value = float_or_nil(value)
        target_value = target(goal)
        return nil if value.nil? || target_value.nil?
        return 1.0 if target_satisfied?(goal, value)

        baseline = metric_value(goal.fetch("baseline_metric", nil))
        return 0.0 if baseline.nil?

        span = improvement(goal, baseline, target_value)
        gained = improvement(goal, baseline, value)
        return nil if span.nil? || gained.nil?
        return 0.0 if span <= 0

        [[gained / span, 0.0].max, 1.0].min.round(4)
      end

      def better_measurement(goal, current, candidate)
        candidate_value = metric_value(candidate)
        return current if candidate_value.nil?

        current_value = metric_value(current)
        return candidate if current_value.nil?

        gain = improvement(goal, current_value, candidate_value)
        gain && gain > 0 ? candidate : current
      end

      # Compact, user-facing summary used by logs, `/goal status`, and the AgentTree.
      def summary(goal)
        metric = goal.fetch("metric", {}) || {}
        last = metric_value(goal.fetch("last_metric", nil))
        parts = ["#{goal.fetch("id", "goal")} #{goal.fetch("status", "queued")}"]
        parts << "paused" if goal.fetch("paused", false)
        parts << "iteration #{goal.fetch("current_iteration", 0)}/#{goal.dig("budget", "max_iterations")}"
        if reviewer_judged?(goal)
          parts << "reviewer: #{review_state(goal)}"
        elsif metric["target"]
          parts << "metric #{format_number(last)}#{comparator_arrow(metric["comparator"])}#{format_number(metric["target"])}"
        end
        parts << "stopped: #{goal.fetch("stop_reason")}" if goal.fetch("stop_reason", nil)
        parts.join(" · ")
      end

      def comparator_arrow(comparator)
        case comparator.to_s
        when "lte", "lt" then " ↓ "
        when "eq" then " = "
        else " → "
        end
      end

      def format_number(value)
        value = float_or_nil(value)
        return "n/a" if value.nil?

        value == value.round ? value.round.to_s : format("%.2f", value)
      end

      # --- coercion --------------------------------------------------------------

      def float_or_nil(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)

        text = value.to_s.strip
        return nil if text.empty?

        Float(text)
      rescue ArgumentError, TypeError
        nil
      end

      def bounded_number(value, default:, min:, max:)
        number = float_or_nil(value)
        number = default.to_f if number.nil?
        [[number, min.to_f].max, max.to_f].min
      end

      def nonnegative_integer(value)
        [Integer(value || 0), 0].max
      rescue ArgumentError, TypeError
        0
      end

      def present_string(value)
        text = value.to_s
        text.strip.empty? ? nil : text
      end

      def truncate_output(value)
        text = value.to_s
        return text if text.length <= OUTPUT_TAIL_LIMIT

        "…#{text[-OUTPUT_TAIL_LIMIT..]}"
      end
    end
  end
end
