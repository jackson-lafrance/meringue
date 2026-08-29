# frozen_string_literal: true

require_relative "transport_adapter"

module Meringue
  module Supervisor
    # Transport adapter for the Pi backend.
    #
    # Pi RPC sessions are long-lived child processes whose stdin/stdout pipes are
    # owned by one Meringue process. `Meringue::Harness::TransportOwnership`
    # already keeps a durable cross-process lease naming that owner, and
    # `PiClient#session_supervision_evidence` already classifies an isolated Pi
    # crash apart from a shared supervisor exit. This adapter exposes those
    # existing capabilities through the harness-neutral `TransportAdapter`
    # contract so the supervisor never depends on Pi semantics directly.
    #
    # Claude Code and Codex use different interactive transports and have their
    # own adapters; the supervisor never assumes that they are Pi RPC sessions.
    class PiAdapter
      include TransportAdapter

      attr_reader :client, :transport_ownership

      def initialize(client:, transport_ownership: nil)
        @client = client
        # The adapter must share the same durable lease store the Pi client uses,
        # so the supervisor and the harness client agree on one owner per session.
        # PiClient keeps its transport ownership private, so the caller (the
        # harness registry or the supervisor factory) passes the shared instance
        # explicitly rather than the adapter reaching into the client.
        @transport_ownership = transport_ownership || Harness::TransportOwnership.new
      end

      def harness_name
        "pi"
      end

      def capabilities
        {
          "session_start" => true,
          "session_lookup" => true,
          "health_status" => true,
          "attachment" => "rpc_and_session_file",
          "recovery" => "rpc_reconnect",
          "stop" => true,
          "concurrent_sessions" => true,
          "live_turn_survives_owner_loss" => true
        }
      end

      def transport_key(session_ref)
        session_id = session_ref.fetch("session_id", nil) || session_ref.fetch(:session_id, nil)
        "pi-#{session_id}"
      end

      def claim(session_ref, harness_pid:, note: nil)
        transport_ownership.claim(
          transport_key(session_ref),
          pid: harness_pid,
          session_id: session_ref.fetch("session_id", nil) || session_ref.fetch(:session_id, nil),
          note: note
        )
        record_for(session_ref)
      end

      def release(session_ref, harness_pid: nil)
        transport_ownership.release(transport_key(session_ref), pid: harness_pid)
      end

      def record_for(session_ref)
        transport_ownership.record_for(transport_key(session_ref))
      end

      def evidence(session_ref)
        return nil unless client.respond_to?(:session_supervision_evidence)

        client.session_supervision_evidence(session_ref)
      end

      def attach(session_ref)
        client.attach_session(session_ref)
      end

      def prompt(session_ref, prompt, mode: "normal")
        client.prompt_session(session_ref, prompt, mode: mode)
      end

      def abort(session_ref)
        client.abort_session(session_ref)
      end

      def kill(session_ref)
        client.kill_session(session_ref)
      end

      def get_state(session_ref)
        client.get_state(session_ref)
      end

      def streaming?(session_ref)
        ref = session_ref
        ref = ref.is_a?(Hash) ? ref.fetch("is_streaming", nil) : nil
        return !!ref unless ref.nil?

        # A session ref without an explicit flag may still be live; ask the
        # backend rather than guessing, but never raise into the supervisor.
        begin
          client.get_state(session_ref).fetch("is_streaming", false)
        rescue StandardError
          false
        end
      end

      def wait_for_settled(session_ref, timeout:)
        return [session_ref] unless streaming?(session_ref)

        if client.respond_to?(:wait_for_settled)
          client.wait_for_settled(session_ref, timeout: timeout)
          return [get_state(session_ref)]
        end

        deadline = monotonic_time + Float(timeout)
        loop do
          return [get_state(session_ref)] unless streaming?(session_ref)
          raise TransientSessionError, "Pi session did not settle before handoff timeout" if monotonic_time >= deadline

          sleep HANDOFF_POLL_INTERVAL
        end
      end

      HANDOFF_POLL_INTERVAL = 0.1

      private

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
