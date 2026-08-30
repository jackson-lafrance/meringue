# frozen_string_literal: true

require_relative "interactive_adapter"

module Meringue
  module Supervisor
    # Claude Code's interactive PTY, transcript attachment, and --resume lifecycle.
    class ClaudeAdapter < InteractiveAdapter
      def harness_name
        "claude"
      end
    end
  end
end
