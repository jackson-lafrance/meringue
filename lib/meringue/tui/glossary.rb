# frozen_string_literal: true

module Meringue
  module TUI
    # The words Meringue uses everywhere and defined nowhere.
    #
    # Setup asks someone to "choose how heads think" and the AgentTree labels a
    # row `after W3`; the log pane distinguishes a head from a worker by glyph.
    # All of it assumes a vocabulary that only existed in the README and in
    # AGENTS.md, neither of which is open while someone is looking at the screen
    # that used the word.
    module Glossary
      module_function

      TERMS = [
        ["project", "A board over one directory. Issues and workers hang off it, so work has nowhere to go until one exists. One directory can hold several."],
        ["issue", "One unit of work on a project. Meringue usually creates these for you from what you type."],
        ["head", "A short-lived agent that reads your message plus light project context and decides what should happen. It routes; it does not implement."],
        ["worker", "The agent that does the work, in its own git worktree and branch. It is what opens a pull request."],
        ["harness", "The coding-agent CLI Meringue drives — Claude Code, Codex CLI, or Pi. Meringue orchestrates; the harness does the thinking."],
        ["workspace", "A worker's own checkout. Opening one (`a`, or double-click) attaches to that agent's live session without stopping it."],
        ["goal loop", "Repeated attempts at one issue until a metric you name reaches a target, or a budget stops it. See /goal."],
        ["question", "A head asking before it routes something it cannot do safely. Answer with /answer, or just reply in chat."],
        ["quiet", "A working agent that has produced no output for a while. Not the same as stuck: a long tool call looks identical from outside."]
      ].freeze

      LABEL_COLUMN = TERMS.map { |term, _| term.length }.max + 2

      def text
        lines = ["Meringue vocabulary:", ""]
        TERMS.each { |term, meaning| lines << "  #{term.ljust(LABEL_COLUMN)}#{meaning}" }
        lines << ""
        lines << "  A message you type spawns a head. The head opens or reuses an issue and starts a worker on it."
        lines.join("\n")
      end
    end
  end
end
