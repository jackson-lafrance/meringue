# frozen_string_literal: true

require_relative "../harness/transient_session_error"

module Meringue
  module Supervisor
    # Raised when a supervision operation must wait for an in-flight turn or for
    # another supervisor instance to relinquish a session. The kernel queues and
    # retries instead of failing the command, exactly like a harness transient
    # error, so an upgrade handoff never surfaces as a worker error.
    class TransientError < StandardError
      include Meringue::Harness::TransientSessionError
    end

    # Raised when a supervision operation cannot proceed because another live
    # supervisor instance owns the session. Distinct from TransientError so the
    # caller can decide whether to defer or fail.
    class OwnershipConflictError < StandardError
      include Meringue::Harness::TransientSessionError
    end
  end
end
