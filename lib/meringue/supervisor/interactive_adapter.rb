# frozen_string_literal: true

require_relative "transport_adapter"

module Meringue
  module Supervisor
    # Adapter for interactive CLI transports. Claude Code and Codex both keep
    # one PTY per session, but neither exposes Pi's RPC protocol. Their common
    # boundary is the durable transcript plus the client's provider-specific
    # resume argv; all process and prompt semantics remain in the client.
    class InteractiveAdapter
      include TransportAdapter

      HANDOFF_POLL_INTERVAL = 0.1

      attr_reader :client, :transport_ownership

      def initialize(client:, transport_ownership: nil)
        @client = client
        @transport_ownership = transport_ownership || Harness::TransportOwnership.new
      end

      def harness_name
        client.harness_name.to_s
      end

      def capabilities
        {
          "session_start" => true,
          "session_lookup" => true,
          "health_status" => true,
          "attachment" => "transcript_and_resume",
          "recovery" => "provider_session_resume",
          "stop" => true,
          "concurrent_sessions" => true,
          "live_turn_survives_owner_loss" => false
        }
      end

      def transport_key(session_ref)
        "#{harness_name}-#{session_id(session_ref)}"
      end

      def claim(session_ref, harness_pid:, note: nil)
        transport_ownership.claim(transport_key(session_ref), pid: harness_pid,
                                  session_id: session_id(session_ref), note: note)
        record_for(session_ref)
      end

      def release(session_ref, harness_pid: nil)
        transport_ownership.release(transport_key(session_ref), pid: harness_pid)
      end

      def record_for(session_ref)
        transport_ownership.record_for(transport_key(session_ref))
      end

      # A PTY cannot be adopted by a different Ruby process. Reopen the
      # provider's durable session through its resume mechanism; this creates
      # exactly one replacement writer in the new supervisor process.
      def attach(session_ref)
        return client.resume_session(session_ref) if client.respond_to?(:resume_session)

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
        value = session_ref.is_a?(Hash) ? (session_ref["is_streaming"] || session_ref[:is_streaming]) : nil
        return !!value unless value.nil?

        get_state(session_ref).fetch("is_streaming", false)
      rescue StandardError
        false
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
          raise Harness::TransientSessionError, "#{harness_name} session did not settle before handoff timeout" if monotonic_time >= deadline

          sleep HANDOFF_POLL_INTERVAL
        end
      end

      # Unlike Pi's RPC-specific evidence, this is derived only from the shared
      # ownership lease and process identity. It works for every independent
      # interactive CLI and detects stale/reused PIDs safely.
      def evidence(session_ref)
        record = record_for(session_ref)
        return nil if record.empty?

        owner_pid = record["owner_pid"]
        harness_pid = record["pid"] || session_ref["pid"] || session_ref[:pid]
        owner = Harness::ProcessIdentity.describe(owner_pid)
        harness = Harness::ProcessIdentity.describe(harness_pid)
        owner_alive = owner && Harness::ProcessIdentity.matches?(owner_pid, started_at: record["owner_started_at"])
        harness_alive = harness && Harness::ProcessIdentity.matches?(harness_pid,
                                                                       command: client.command,
                                                                       started_at: record["harness_started_at"])
        {
          "source" => "transport_ownership",
          "transport_key" => transport_key(session_ref),
          "owner_pid" => owner_pid,
          "owner_started_at" => record["owner_started_at"],
          "owner_alive" => !!owner_alive,
          "harness_pid" => harness_pid,
          "harness_started_at" => record["harness_started_at"],
          "harness_alive" => !!harness_alive,
          "supervisor_exited" => !owner_alive && !harness_alive,
          "observed_at" => Time.now.utc.iso8601(6)
        }.compact
      rescue StandardError
        nil
      end

      private

      def session_id(ref)
        ref.fetch("session_id", nil) || ref.fetch(:session_id, nil)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
