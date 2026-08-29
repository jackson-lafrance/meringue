# frozen_string_literal: true

require_relative "interactive_adapter"

module Meringue
  module Supervisor
    # Codex's interactive PTY, rollout attachment, and provider thread resume lifecycle.
    class CodexAdapter < InteractiveAdapter
      def harness_name
        "codex"
      end

      def capabilities
        super.merge(
          "attachment" => "rollout_and_resume",
          "recovery" => "provider_thread_resume"
        )
      end
    end
  end
end
