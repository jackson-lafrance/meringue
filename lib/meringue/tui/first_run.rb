# frozen_string_literal: true

module Meringue
  module TUI
    # What the dashboard says when there is genuinely nothing in it yet.
    #
    # The empty panes used to report the absence — "No AgentTree data yet.",
    # "No logs yet. Type a prompt below and press Enter." — without resolving it.
    # Someone who has just finished setup does not need to be told the dashboard
    # is empty; they need to know what a first message looks like, that Meringue
    # opens the issue and starts the worker for them, and that work has nowhere
    # to land until a project exists.
    #
    # This costs a returning user nothing. The moment any log, project, issue, or
    # agent exists, none of it renders.
    module FirstRun
      module_function

      HEADING = "Nothing here yet. Try one of these:"
      EXAMPLES = [
        ['"add tests for the login flow"', "a goal, in plain English"],
        ['"what does the kernel do?"', "a question — a worker investigates"],
        ["/help", "every command, grouped"],
        ["/setup", "rerun first-run setup"]
      ].freeze
      EXAMPLE_COLUMN = 34
      NO_PROJECT_FOOTER =
        "No project is registered yet. Run /project add <path>, or just describe a goal " \
        "and a head will offer to register the repository it finds."
      READY_FOOTER =
        "Meringue creates the issue and starts the worker. You only open an agent when you want to."

      AGENT_TREE_LINES = ["No agents yet.", "Describe a goal in the chat below."].freeze

      # True while no work exists, and no filter is narrowing the view to
      # something that merely looks empty.
      #
      # A registered project is deliberately not work: setup now adopts the
      # launch directory, so "one project, nothing in it" is the single most
      # common first dashboard there is, and it is exactly the one that needs
      # the card. What ends the first run is an issue or an agent — something
      # that means the user has already routed something.
      def empty_dashboard?(state, scoped: false)
        return false if scoped

        %w[issues agents].all? { |key| Array(state.fetch(key, [])).empty? }
      end

      def no_projects?(state)
        Array(state.fetch("projects", [])).empty?
      end

      def footer(state)
        no_projects?(state) ? NO_PROJECT_FOOTER : READY_FOOTER
      end

      # What the logs pane shows when it has no entries: the first-run card while
      # no work exists, and otherwise the terse note explaining why this
      # particular view is blank. The pane owns wrapping, because only it knows
      # how its own body text is broken; the copy all lives here.
      def empty_logs_lines(state, wrap:)
        scoped = !LogScope.label(state).empty?
        return logs_lines(state, wrap: wrap) if empty_dashboard?(state, scoped: scoped)

        wrap.call(empty_logs_text(state)).map { |line| [[line, Style::MUTED]] }
      end

      def empty_logs_text(state)
        label = LogScope.label(state)
        return "No logs yet. Type a prompt below and press Enter." if label.empty?

        "No logs for #{label} yet. Click another AgentTree row to move this filter, or press Esc to clear it."
      end

      def logs_lines(state, wrap:)
        lines = [[[HEADING, Style::TEXT]], [["", Style::DIM]]]
        EXAMPLES.each do |example, note|
          lines << [["  #{example.ljust(EXAMPLE_COLUMN)}", Style::ACCENT_BOLD], [note, Style::MUTED]]
        end
        lines << [["", Style::DIM]]
        wrap.call(footer(state)).each { |line| lines << [[line, Style::MUTED]] }
        lines
      end

      def agent_tree_lines
        AGENT_TREE_LINES.map { |line| [[line, Style::MUTED]] }
      end
    end
  end
end
