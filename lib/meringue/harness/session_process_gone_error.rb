# frozen_string_literal: true

module Meringue
  module Harness
    # Marker for harness errors that mean "the process behind this session is gone, and the session
    # has produced no completed response". It is the opposite of `TransientSessionError`: nothing
    # about the condition is momentary, so replaying a prompt into it can only fail again.
    #
    # This distinction exists because Meringue used to treat the two the same. A worker whose
    # long-lived harness process exited mid-tool-call was re-attached and re-prompted three times; each `prompt` RPC
    # timed out, and the failure the user finally read named the downstream `RpcTimeoutError`
    # instead of the process exit that actually happened. A client that can prove the process is
    # gone raises an error carrying this marker so the kernel settles the worker honestly instead.
    #
    # Harness clients opt in by including this module in the specific error classes they raise.
    # A harness whose sessions are one process *per turn* (the exit is its normal lifecycle) must
    # not mark its exit errors: this marker means "the session's transport can never answer again".
    module SessionProcessGoneError
      def session_process_gone?
        true
      end
    end

    module_function

    def session_process_gone_error?(error)
      return true if error.is_a?(SessionProcessGoneError)

      error.respond_to?(:session_process_gone?) && error.session_process_gone?
    end
  end
end
