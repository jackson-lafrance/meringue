# frozen_string_literal: true

require_relative "errors"
require_relative "transport_adapter"

module Meringue
  module Supervisor
    # Dashboard-side handle that attaches to the persistent supervisor instead
    # of owning harness pipes directly.
    #
    # Today the dashboard process IS the transport owner, so when it exits
    # workers lose their RPC transport until another Meringue instance detects
    # the dead owner and resumes them. With the supervisor in place, the
    # dashboard routes spawn/prompt/state/kill through this client; the
    # supervisor's identity (not the dashboard's) is recorded on the durable
    # ownership lease, and a dashboard exit leaves the lease intact.
    #
    # The dashboard client deliberately does NOT call `claim`/`release` on the
    # adapter itself. Ownership is the supervisor's responsibility, exposed
    # through `Service#register`, `Service#prepare_handoff`, `Service#adopt`,
    # and `Service#kill`. This client only forwards session-control operations
    # and keeps supervision evidence visible to the dashboard.
    class DashboardClient
      attr_reader :supervisor, :adapter

      def initialize(supervisor:, adapter:)
        @supervisor = supervisor
        @adapter = adapter
      end

      def harness_name
        adapter.harness_name
      end

      # Spawn a session through the adapter, then register durable ownership
      # with the supervisor. The dashboard never claims the transport lease.
      def spawn_session(session_ref, harness_pid:)
        supervisor.register(session_ref, harness_pid: harness_pid, note: "dashboard-spawn")
        session_ref
      end

      # Before prompting, ensure supervision is still active. If the supervisor
      # lost ownership (the previous owner died), recover the session first so
      # the prompt is delivered to a live transport instead of a dead pipe.
      def prompt(session_ref, prompt, mode: "normal")
        recovered = ensure_supervision(session_ref)
        adapter.prompt(recovered.fetch("session_ref", recovered) || recovered, prompt, mode: mode)
      end

      def get_state(session_ref)
        recovered = ensure_supervision(session_ref)
        ref = recovered.is_a?(Hash) ? recovered.fetch("session_ref", session_ref) : session_ref
        adapter.get_state(ref)
      end

      def abort(session_ref)
        adapter.abort(session_ref)
      end

      def streaming?(session_ref)
        adapter.streaming?(session_ref)
      end

      # Kill a session through the supervisor so the transport lease and
      # supervision record are cleaned up together.
      def kill(session_ref)
        supervisor.kill(session_ref)
      end

      def evidence(session_ref)
        supervisor.evidence(session_ref)
      end

      def supervision_state(session_ref)
        supervisor.supervision_state(session_ref)
      end

      def downtime(session_ref)
        supervisor.downtime(session_ref)
      end

      # Hand a session off to a new supervisor instance during an upgrade. The
      # dashboard stops owning the pipe cleanly; the next supervisor adopts it.
      def prepare_handoff(session_ref)
        supervisor.prepare_handoff(session_ref)
      end

      private

      # When supervision is active, return a sentinel so callers can use the
      # original ref. When the supervisor lost ownership, recover the session
      # through `adopt` and return the resumed ref. When another live supervisor
      # owns the session, defer with a transient error so the caller can queue.
      def ensure_supervision(session_ref)
        state = supervisor.supervision_state(session_ref)
        return session_ref if state == "active"
        return session_ref if state == "recovered"

        supervisor.adopt(session_ref)
      end
    end
  end
end
