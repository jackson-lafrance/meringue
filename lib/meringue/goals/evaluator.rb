# frozen_string_literal: true

require_relative "record"
require_relative "review_verdict"

module Meringue
  module Goals
    # The judge step: scores one measured iteration against the goal's metric and
    # guardrails, or against a reviewer's verdict, and writes the directive the next
    # attempt receives.
    #
    # This is deliberately deterministic. The kernel-run probe is the primary progress
    # signal because a self-assessing agent has no stopping signal: it drifts optimistic,
    # prefers its own work, and never says "this is not working". A worker-backed second
    # gate ("the metric says met, is it actually met, or gamed?") is a planned follow-up;
    # the verdict/evidence/directive contract here is the contract it will fill.
    #
    # Pure: no clock, no I/O, no state mutation.
    module Evaluator
      GUARD_RULES = <<~RULES.strip
        Do not modify the metric command, its configuration, thresholds, or exclude lists, and do not delete, skip, or weaken existing tests. Meringue measures the metric itself on your branch after you finish; do not self-report it.
      RULES

      REVIEW_GUARD_RULES = <<~RULES.strip
        Do not edit the goal's success criteria or its guardrail commands, and do not delete, skip, or weaken existing tests. An independent reviewer reads your branch after you finish and decides whether the goal is met; do not self-approve, and do not claim a verdict on the reviewer's behalf.
      RULES

      module_function

      # Returns the judgement for one iteration. The caller stores it on the iteration
      # record and updates the goal's counters from `progress` and `probe_ok`.
      def evaluate(goal:, iteration:)
        return evaluate_review(goal: goal, iteration: iteration) if Record.reviewer_judged?(goal)

        evaluate_metric(goal: goal, iteration: iteration)
      end

      def evaluate_metric(goal:, iteration:)
        metric = iteration.fetch("metric", {}) || {}
        value = Record.metric_value(metric)
        guardrails = Array(iteration.fetch("guardrails", []))
        failed_guardrails = guardrails.reject { |guardrail| guardrail.fetch("passed", false) }
        reference = reference_value(goal)
        delta = Record.improvement(goal, reference, value)
        evidence = []

        unless probe_ok?(goal, metric)
          return judgement(
            verdict: "inconclusive",
            probe_ok: false,
            progress: false,
            metric_delta: delta,
            score: nil,
            evidence: probe_evidence(goal, metric),
            gaming_suspected: false,
            next_directive: probe_directive(goal, metric)
          )
        end

        evidence << "metric #{Record.format_number(value)} (target #{Record.comparator(goal)} #{Record.format_number(Record.target(goal))})"
        evidence << "metric moved #{Record.format_number(reference)} → #{Record.format_number(value)} (#{signed(delta)})" if delta
        failed_guardrails.each do |guardrail|
          evidence << "guardrail failed: #{guardrail.fetch("command", "guardrail")} (exit #{guardrail.fetch("exit_status", "?")})"
        end
        worker_status = iteration.fetch("attempt_worker_status", nil).to_s
        evidence << "attempt session ended #{worker_status}" unless %w[completed].include?(worker_status)

        target_reached = Record.target_satisfied?(goal, value)
        progressed = progress?(goal, delta)
        score = Record.progress_score(goal, value)

        if target_reached && failed_guardrails.empty?
          return judgement(
            verdict: "met",
            probe_ok: true,
            progress: true,
            metric_delta: delta,
            score: score,
            evidence: evidence,
            gaming_suspected: false,
            next_directive: nil
          )
        end

        if target_reached
          # The target was hit while a guardrail regressed. That is the classic
          # specification-gaming shape (coverage up, suite red), so it is not success.
          return judgement(
            verdict: "not_met",
            probe_ok: true,
            progress: false,
            metric_delta: delta,
            score: score,
            evidence: evidence,
            gaming_suspected: true,
            next_directive: gaming_directive(goal, failed_guardrails)
          )
        end

        verdict = progressed ? "partially_met" : "not_met"
        judgement(
          verdict: verdict,
          probe_ok: true,
          progress: progressed,
          metric_delta: delta,
          score: score,
          evidence: evidence,
          gaming_suspected: !failed_guardrails.empty?,
          next_directive: continue_directive(
            goal,
            value: value,
            reference: reference,
            delta: delta,
            progressed: progressed,
            failed_guardrails: failed_guardrails,
            iteration: iteration
          )
        )
      end

      # The reviewer-judged variant of the same contract. The reviewer's structured verdict
      # replaces the comparator; the guardrails, the evidence lines, and `next_directive`
      # work exactly as they do for a metric goal, so nothing downstream has to care which
      # judge produced the verdict.
      def evaluate_review(goal:, iteration:)
        review = ReviewVerdict.normalize(iteration.fetch("review", nil)) ||
                 ReviewVerdict.unusable("the reviewer produced no verdict for this iteration")
        guardrails = Array(iteration.fetch("guardrails", []))
        failed_guardrails = guardrails.reject { |guardrail| guardrail.fetch("passed", false) }

        unless review.fetch("usable", false)
          return judgement(
            verdict: "inconclusive",
            probe_ok: false,
            progress: false,
            metric_delta: nil,
            score: nil,
            evidence: ["reviewer verdict unusable: #{review.fetch("error", "no verdict")}"],
            gaming_suspected: false,
            next_directive: review_probe_directive(goal)
          )
        end

        evidence = [Record.review_line(review)].compact
        ReviewVerdict.critique_text(review).each { |item| evidence << "reviewer asked for: #{item}" }
        failed_guardrails.each do |guardrail|
          evidence << "guardrail failed: #{guardrail.fetch("command", "guardrail")} (exit #{guardrail.fetch("exit_status", "?")})"
        end
        worker_status = iteration.fetch("attempt_worker_status", nil).to_s
        evidence << "attempt session ended #{worker_status}" unless %w[completed].include?(worker_status)

        approved = review.fetch("approved", false)
        if approved && failed_guardrails.empty?
          return judgement(
            verdict: "met",
            probe_ok: true,
            progress: true,
            metric_delta: nil,
            score: 1.0,
            evidence: evidence,
            gaming_suspected: false,
            next_directive: nil
          )
        end

        if approved
          # Approved by the reviewer with a red guardrail. Same rule as a metric goal that
          # hits its target with a broken suite: not success.
          return judgement(
            verdict: "not_met",
            probe_ok: true,
            progress: false,
            metric_delta: nil,
            score: nil,
            evidence: evidence,
            gaming_suspected: true,
            next_directive: gaming_directive(goal, failed_guardrails)
          )
        end

        repeated = repeated_critique?(goal, review)
        judgement(
          verdict: "not_met",
          probe_ok: true,
          progress: !repeated,
          metric_delta: nil,
          score: nil,
          evidence: repeated ? evidence + ["reviewer repeated the previous critique"] : evidence,
          gaming_suspected: !failed_guardrails.empty?,
          next_directive: review_directive(
            goal,
            review: review,
            repeated: repeated,
            failed_guardrails: failed_guardrails,
            iteration: iteration
          )
        )
      end

      # "No progress" without a number: the reviewer produced the same critique it produced
      # last time, so the attempt did not move the thing the reviewer is blocking on.
      def repeated_critique?(goal, review)
        fingerprint = ReviewVerdict.critique_fingerprint(review)
        return false unless fingerprint

        previous = Record.settled_iterations(goal).reverse.filter_map { |iteration| iteration.fetch("review", nil) }.first
        ReviewVerdict.critique_fingerprint(previous) == fingerprint
      end

      def review_probe_directive(goal)
        [
          "The reviewer for this goal did not return a verdict Meringue could read, so this iteration could not be judged.",
          "Keep working toward the success criteria: #{goal.fetch("success_criteria", "")}".strip,
          REVIEW_GUARD_RULES
        ].join(" ")
      end

      def review_directive(goal, review:, repeated:, failed_guardrails:, iteration:)
        lines = ["The reviewer did not approve iteration #{iteration.fetch("number", 0)}."]
        rationale = Record.present_string(review.fetch("rationale", nil))
        lines << "Reviewer's reasoning: #{rationale.sub(/[.!?…]+\z/, "")}." if rationale
        critique = ReviewVerdict.critique_text(review)
        unless critique.empty?
          numbered = critique.each_with_index.map { |item, index| "#{index + 1}) #{item}" }.join(" ")
          lines << "Address every point before finishing: #{numbered}"
        end
        lines << "This is the same critique as the previous iteration, so repeating that approach will not pass; change how you are solving it." if repeated
        unless failed_guardrails.empty?
          commands = failed_guardrails.map { |guardrail| "`#{guardrail.fetch("command", "guardrail")}`" }.join(", ")
          lines << "Also restore #{commands}: a failing guardrail blocks the goal even if the reviewer approves."
        end
        lines << "Success criteria: #{goal.fetch("success_criteria", "")}" unless goal.fetch("success_criteria", "").to_s.strip.empty?
        lines << REVIEW_GUARD_RULES
        lines.join(" ")
      end

      # The value the current iteration is compared against: the previous measurement when
      # there is one, otherwise the baseline taken before the first attempt.
      def reference_value(goal)
        previous = Record.settled_iterations(goal).last
        previous_value = previous && Record.metric_value(previous.fetch("metric", nil))
        previous_value || Record.metric_value(goal.fetch("baseline_metric", nil))
      end

      def probe_ok?(goal, metric)
        return false if metric.fetch("timed_out", false)
        return false if Record.metric_value(metric).nil?
        # An `exit_status` metric is *about* the exit code, so a non-zero exit is a
        # measurement, not a broken probe.
        return true if goal.dig("metric", "parse", "type").to_s == "exit_status"

        metric.fetch("exit_status", nil).to_i.zero?
      end

      def progress?(goal, delta)
        return false if delta.nil?

        threshold = goal.dig("budget", "min_metric_delta").to_f
        delta > 0 && delta >= threshold
      end

      def probe_evidence(goal, metric)
        evidence = ["metric command could not be measured"]
        evidence << "metric command timed out after #{goal.dig("metric", "timeout_seconds")}s" if metric.fetch("timed_out", false)
        evidence << "metric command exited #{metric.fetch("exit_status")}" if metric.fetch("exit_status", nil)
        evidence << "metric output could not be parsed: #{metric.fetch("parse_error")}" if metric.fetch("parse_error", nil)
        evidence
      end

      def probe_directive(goal, metric)
        reason = if metric.fetch("timed_out", false)
                   "timed out"
                 elsif metric.fetch("parse_error", nil)
                   "produced output the goal could not parse"
                 else
                   "exited #{metric.fetch("exit_status", "non-zero")}"
                 end
        [
          "The goal metric command `#{goal.dig("metric", "command")}` #{reason}, so this iteration could not be scored.",
          "Make that command run cleanly in this workspace before changing anything else.",
          GUARD_RULES
        ].join(" ")
      end

      def gaming_directive(goal, failed_guardrails)
        commands = failed_guardrails.map { |guardrail| "`#{guardrail.fetch("command", "guardrail")}`" }.join(", ")
        reached = Record.reviewer_judged?(goal) ? "The reviewer approved the work" : "The metric reached its target"
        [
          "#{reached} but #{commands} failed, so the goal is not met.",
          "Fix the regression without giving up that result: #{goal.fetch("success_criteria", "meet the success criteria")}.",
          Record.reviewer_judged?(goal) ? REVIEW_GUARD_RULES : GUARD_RULES
        ].join(" ")
      end

      def continue_directive(goal, value:, reference:, delta:, progressed:, failed_guardrails:, iteration:)
        lines = []
        if progressed
          lines << "Metric moved #{Record.format_number(reference)} → #{Record.format_number(value)} (#{signed(delta)}) but has not reached #{Record.comparator(goal)} #{Record.format_number(Record.target(goal))}. Keep pushing the same direction with a new change, not a repeat of iteration #{iteration.fetch("number", 0)}."
        else
          lines << "Metric is #{Record.format_number(value)} and did not improve (#{signed(delta)}) at iteration #{iteration.fetch("number", 0)}. Change approach instead of repeating that attempt."
        end
        unless failed_guardrails.empty?
          commands = failed_guardrails.map { |guardrail| "`#{guardrail.fetch("command", "guardrail")}`" }.join(", ")
          lines << "Also restore #{commands}: a failing guardrail blocks the goal even if the metric improves."
        end
        lines << "Success criteria: #{goal.fetch("success_criteria", "")}" unless goal.fetch("success_criteria", "").to_s.strip.empty?
        lines << GUARD_RULES
        lines.join(" ")
      end

      def signed(delta)
        return "no change" if delta.nil?
        return "±0" if delta.zero?

        "#{delta.positive? ? "+" : "-"}#{Record.format_number(delta.abs)}"
      end

      def judgement(verdict:, probe_ok:, progress:, metric_delta:, score:, evidence:, gaming_suspected:, next_directive:)
        {
          "verdict" => verdict,
          "probe_ok" => probe_ok,
          "progress" => progress,
          "metric_delta" => metric_delta,
          "score" => score,
          "evidence" => Array(evidence).map(&:to_s),
          "gaming_suspected" => gaming_suspected ? true : false,
          "next_directive" => next_directive
        }
      end
    end
  end
end
