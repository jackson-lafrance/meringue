# frozen_string_literal: true

module Meringue
  module Harness
    # Marker for harness errors that are expected to succeed on a later attempt, such as a session
    # that is momentarily owned by another Meringue instance mid-turn. The kernel queues the work
    # and retries during reconciliation instead of failing the command with a user-facing error.
    #
    # Harness clients opt in by including this module in the specific error classes they raise.
    module TransientSessionError
      def transient?
        true
      end
    end

    module_function

    def transient_session_error?(error)
      return true if error.is_a?(TransientSessionError)

      error.respond_to?(:transient?) && error.transient?
    end
  end
end
