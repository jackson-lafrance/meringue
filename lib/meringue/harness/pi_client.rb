# frozen_string_literal: true

module Meringue
  module Harness
    class PiClient < Client
      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
        raise NotImplementedError, "real Pi integration is intentionally not implemented in the scaffold"
      end
    end
  end
end
