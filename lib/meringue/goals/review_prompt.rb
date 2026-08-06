# frozen_string_literal: true

require_relative "record"
require_relative "review_verdict"

module Meringue
  module Goals
    # Renders the prompt for one reviewer turn.
    #
    # The reviewer is a separate session from the attempt on purpose. An agent asked to
    # grade its own work approves it: the whole point of a reviewer-judged goal is that
    # something other than the author decides when the goal is met. So the reviewer gets
    # the success criteria, the branch, the guardrail results the kernel already measured,
    # and the previous rounds' critiques — and nothing that would let it write code.
    module ReviewPrompt
      # Also used by tests to recognise a reviewer session, and by a reviewer that wants to
      # double-check it is answering the right contract.
      VERDICT_MARKER = "MERINGUE_REVIEW_VERDICT"
      HISTORY_LIMIT = 3

      module_function

      def render(goal:, iteration:, retry_reason: nil)
        number = iteration.fetch("number", goal.fetch("current_iteration", 0))
        sections = []
        sections << header(goal, iteration, number)
        sections << "Success criteria (the only bar that matters):\n#{goal.fetch("success_criteria", "")}"
        sections << scope_section(goal, iteration)
        guardrails = guardrail_section(iteration)
        sections << guardrails if guardrails
        history = history_section(goal, number)
        sections << history if history
        sections << rules_section
        sections << retry_section(retry_reason) if Record.present_string(retry_reason)
        sections << contract_section
        sections.join("\n\n")
      end

      def header(goal, iteration, number)
        [
          "You are the reviewer for Meringue goal #{goal.fetch("id")} on issue #{goal.fetch("issue_id")} (#{VERDICT_MARKER}).",
          "This is a read-only review turn: do not edit, commit, push, or run anything that changes the workspace, and do not open a pull request.",
          "You are reviewing iteration #{number} of #{goal.dig("budget", "max_iterations")}."
        ].join("\n")
      end

      def scope_section(goal, iteration)
        branch = Record.present_string(iteration.fetch("attempt_branch", nil))
        lines = ["What to review: the work in this working directory#{branch ? " on branch `#{branch}`" : ""}, produced for this goal."]
        lines << "Inspect it directly: `git status`, `git log --oneline -20`, the diff this branch adds, and the files the success criteria are about. Read the actual result, not the attempt's description of it."
        lines << "Goal title: #{goal.fetch("title")}" if Record.present_string(goal.fetch("title", nil))
        lines.join("\n")
      end

      def guardrail_section(iteration)
        guardrails = Array(iteration.fetch("guardrails", []))
        return nil if guardrails.empty?

        lines = guardrails.map do |guardrail|
          "- `#{guardrail.fetch("command", "guardrail")}`: #{guardrail.fetch("passed", false) ? "passed" : "FAILED"}"
        end
        (["Guardrails Meringue already ran on this branch (you do not need to re-run them):"] + lines).join("\n")
      end

      def history_section(goal, number)
        previous = Record.settled_iterations(goal).last(HISTORY_LIMIT).reject { |iteration| iteration.fetch("number", 0).to_i == number.to_i }
        return nil if previous.empty?

        lines = previous.map do |iteration|
          "  it#{iteration.fetch("number", 0)}: #{Record.review_line(iteration.fetch("review", nil)) || "no verdict"}"
        end
        (["Earlier rounds on this goal — check whether the points you or a previous reviewer raised were actually addressed:"] + lines).join("\n")
      end

      def rules_section
        [
          "How to decide:",
          "- Approve only if the success criteria are fully met by the work as it stands. \"Almost\" is not approved.",
          "- Do not withhold approval for anything outside the success criteria, and do not invent new requirements between rounds.",
          "- If you do not approve, every critique item must be specific and actionable: name the file, the behaviour, and what \"good\" looks like. \"Make it nicer\" wastes an entire iteration.",
          "- Do not approve work you have not actually inspected, and say so in your rationale if the branch has no changes to review."
        ].join("\n")
      end

      def retry_section(reason)
        [
          "Your previous answer for this iteration could not be used: #{reason}",
          "Return the JSON object exactly as described below, with nothing after it."
        ].join(" ")
      end

      def contract_section
        <<~CONTRACT.strip
          End your turn with exactly one JSON object, in a fenced json block, with nothing after it:

          ```json
          {
            "approved": false,
            "rationale": "one or two sentences on why",
            "critique": ["specific actionable change", "another specific actionable change"]
          }
          ```

          `approved` must be true or false. When it is false, `critique` must list at least one specific change; that list is handed to the next attempt verbatim as its instructions. When it is true, `critique` may be empty. Do not add commentary after the JSON object.
        CONTRACT
      end
    end
  end
end
