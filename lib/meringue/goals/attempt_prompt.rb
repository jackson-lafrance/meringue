# frozen_string_literal: true

require_relative "evaluator"
require_relative "record"

module Meringue
  module Goals
    # Renders the prompt for one attempt iteration.
    #
    # The reflection lives here, outside the agent session, on purpose: an agent asked to
    # critique itself with no external signal restates the same plan in new words, while a
    # short "you already tried X and the metric moved 61 → 62" carries the signal that
    # actually changes behavior. Each iteration therefore gets the metric history and the
    # previous iteration's directive instead of a growing transcript.
    module AttemptPrompt
      HISTORY_LIMIT = 5

      module_function

      def render(goal:, iteration_number:, mode: "spawn")
        sections = []
        sections << header(goal, iteration_number, mode)
        sections << metric_section(goal)
        history = history_section(goal)
        sections << history if history
        directive = Record.present_string(latest_directive(goal))
        sections << "This iteration's directive:\n#{directive}" if directive
        sections << rules_section(goal)
        template = Record.present_string(goal.fetch("attempt_prompt_template", nil))
        sections << "Additional instructions for this goal:\n#{template}" if template
        sections.join("\n\n")
      end

      def header(goal, iteration_number, mode)
        lead = if mode.to_s == "prompt"
                 "Continue goal #{goal.fetch("id")} on issue #{goal.fetch("issue_id")} in this same workspace and branch."
               else
                 "Work on goal #{goal.fetch("id")} for issue #{goal.fetch("issue_id")}."
               end
        [
          lead,
          "Success criteria: #{goal.fetch("success_criteria", "")}",
          "Iteration #{iteration_number} of #{goal.dig("budget", "max_iterations")}."
        ].join("\n")
      end

      def metric_section(goal)
        metric = goal.fetch("metric", {}) || {}
        baseline = Record.metric_value(goal.fetch("baseline_metric", nil))
        last = Record.metric_value(goal.fetch("last_metric", nil))
        best = Record.metric_value(goal.fetch("best_metric", nil))
        [
          "Metric: `#{metric["command"]}` must be #{comparator_text(metric["comparator"])} #{Record.format_number(metric["target"])}.",
          "Baseline #{Record.format_number(baseline)} · latest #{Record.format_number(last)} · best #{Record.format_number(best)}.",
          guardrail_text(metric)
        ].compact.join("\n")
      end

      def guardrail_text(metric)
        guardrails = Array(metric["guardrails"])
        return nil if guardrails.empty?

        "Guardrails that must keep passing: #{guardrails.map { |guardrail| "`#{guardrail.fetch("command", "")}`" }.join(", ")}."
      end

      def history_section(goal)
        settled = Record.settled_iterations(goal).last(HISTORY_LIMIT)
        return nil if settled.empty?

        lines = settled.map do |iteration|
          value = Record.metric_value(iteration.fetch("metric", nil))
          delta = Record.float_or_nil(iteration.fetch("metric_delta", nil))
          directive = Record.present_string(iteration.fetch("next_directive", nil))
          [
            "  it#{iteration.fetch("number", 0)}:",
            "metric #{Record.format_number(value)}",
            "(#{Evaluator.signed(delta)})",
            "verdict #{iteration.fetch("verdict", "unknown")}",
            directive ? "— #{directive}" : nil
          ].compact.join(" ")
        end
        (["Already attempted (do not repeat these approaches):"] + lines).join("\n")
      end

      def latest_directive(goal)
        Record.settled_iterations(goal).reverse.filter_map { |iteration| Record.present_string(iteration.fetch("next_directive", nil)) }.first
      end

      def rules_section(goal)
        [
          "Rules Meringue enforces for this goal (violating them fails the iteration):",
          "- #{Evaluator::GUARD_RULES}",
          "- Commit your work on your assigned branch so the metric can be measured on it.",
          "- Meringue re-runs the metric after you finish and decides whether the goal is met; if it is not, you may be asked to iterate again with a new directive.",
          goal.fetch("continuity", nil).to_s == "accumulate" ? "- Stay in this workspace and branch across iterations." : nil
        ].compact.join("\n")
      end

      def comparator_text(comparator)
        case comparator.to_s
        when "lte" then "at most"
        when "lt" then "below"
        when "gt" then "above"
        when "eq" then "exactly"
        else "at least"
        end
      end
    end
  end
end
