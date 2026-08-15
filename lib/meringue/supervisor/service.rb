# frozen_string_literal: true

require "digest"
require "time"

require_relative "errors"
require_relative "transport_adapter"
require_relative "state_store"

module Meringue
  module Supervisor
    # The persistent, harness-agnostic supervisor service.
    #
    # The supervisor owns harness transport independently of the interactive
    # dashboard/TUI process. A dashboard client attaches to the supervisor
    # rather than holding harness pipes directly, so a dashboard exit, restart,
    # or upgrade never drops workers' RPC transport: the supervisor's durable
    # ownership lease and state record survive, and a fresh supervisor process
    # (or the restarted dashboard acting through a new supervisor) resumes the
    # orphaned sessions.
    #
    # Supervision lifecycle per session:
    #
    #   active           the supervisor owns the transport and the session is
    #                    reachable through it.
    #   supervision_lost the recorded owner and harness process are both gone,
    #                    so the session's runtime is paused but the durable
    #                    session, workspace, and queued work remain valid. This
    #                    is the explicit state that distinguishes paused runtime
    #                    from active working, with a downtime metric.
    #   recovered        a supervisor has re-attached to the session. When the
    #                    original turn was still alive it keeps running without
    #                    being re-prompted; only a settled session that needs to
    #                    continue receives a continuation prompt.
    #
    # The service is harness-agnostic: it talks to a `TransportAdapter` and a
    # `StateStore`, and never references Pi, Claude Code, or any other backend
    # directly. Adding a backend means registering a new adapter.
    class Service
      attr_reader :adapter, :state_store, :owner_pid, :owner_started_at,
                  :settle_timeout, :handoff_timeout

      def initialize(adapter:, state_store: nil, owner_pid: Process.pid, owner_started_at: nil,
                     settle_timeout: 5.0, handoff_timeout: 10.0, clock: nil)
        @adapter = adapter
        @state_store = state_store || StateStore.new
        @owner_pid = Integer(owner_pid)
        @settle_timeout = Float(settle_timeout)
        @handoff_timeout = Float(handoff_timeout)
        @clock = clock
        described = described_owner(owner_pid, owner_started_at)
        @owner_started_at = (owner_started_at || described&.fetch("started_at", nil)&.iso8601)
        @mutex = Mutex.new
      end

      # Claim durable ownership of a freshly spawned or freshly attached session
      # for the supervisor process. Records the active supervision state.
      def register(session_ref, harness_pid:, note: nil)
        key = adapter.transport_key(session_ref)
        adapter.claim(session_ref, harness_pid: harness_pid, note: note || "supervisor")
        record = state_store.update(key) do |current|
          current.merge(
            "transport_key" => key,
            "session_id" => session_ref.fetch("session_id", nil) || session_ref.fetch(:session_id, nil),
            "harness" => adapter.harness_name,
            "state" => "active",
            "handoff_state" => "none",
            "owner_pid" => owner_pid,
            "owner_started_at" => owner_started_at,
            "harness_pid" => harness_pid,
            "harness_started_at" => adapter_harness_started_at(harness_pid),
            "episode_id" => current.fetch("episode_id", nil) || episode_id_for(session_ref, harness_pid),
            "lost_at" => nil,
            "recovered_at" => nil,
            "downtime_seconds" => current.fetch("downtime_seconds", 0.0).to_f,
            "prompted_on_recovery" => false,
            "registered_at" => current.fetch("registered_at", nil) || now,
            "updated_at" => now
          ).compact
        end
        record
      end

      # Harness-neutral supervision evidence for a session, merged with the
      # durable supervision record. Generalizes
      # `PiClient#session_supervision_evidence` so the kernel and TUI can ask
      # one question regardless of backend.
      def evidence(session_ref)
        adapter_evidence = adapter.evidence(session_ref)
        return nil unless adapter_evidence.is_a?(Hash)

        key = adapter.transport_key(session_ref)
        record = state_store.read(key) || {}
        adapter_evidence.merge(
          "supervision_state" => record.fetch("state", "active"),
          "downtime_seconds" => record.fetch("downtime_seconds", 0.0).to_f,
          "lost_at" => record.fetch("lost_at", nil),
          "recovered_at" => record.fetch("recovered_at", nil),
          "supervisor_owner_pid" => owner_pid
        ).compact
      end

      def supervision_state(session_ref)
        record = state_store.read(adapter.transport_key(session_ref))
        record&.fetch("state", "active") || "active"
      end

      def downtime(session_ref)
        record = state_store.read(adapter.transport_key(session_ref))
        return 0.0 unless record

        accumulated = record.fetch("downtime_seconds", 0.0).to_f
        return accumulated unless record.fetch("state", nil) == "supervision_lost"

        lost_at = parse_time(record.fetch("lost_at", nil))
        return accumulated unless lost_at

        accumulated + [now_time - lost_at, 0.0].max
      end

      # Observe a session and, when the recorded owner and harness process are
      # both gone, transition it to `supervision_lost`. Returns the updated
      # evidence Hash (with `supervisor_exited` and `supervision_state`) or nil
      # when the backend reports no shared supervisor.
      def detect_loss(session_ref)
        adapter_evidence = adapter.evidence(session_ref)
        return nil unless adapter_evidence.is_a?(Hash)

        return adapter_evidence unless adapter_evidence.fetch("supervisor_exited", false)

        key = adapter.transport_key(session_ref)
        record = state_store.update(key) do |current|
          next current if current.fetch("state", "active") == "supervision_lost"

          current.merge(
            "state" => "supervision_lost",
            "handoff_state" => "none",
            "lost_at" => now,
            "recovered_at" => nil,
            "updated_at" => now
          )
        end
        adapter_evidence.merge(
          "supervision_state" => record.fetch("state"),
          "lost_at" => record.fetch("lost_at", nil),
          "downtime_seconds" => downtime(session_ref)
        )
      end

      # Recover an orphaned session by re-attaching to its transport. When the
      # original turn is still alive (the resumed session is streaming), it is
      # left running and NOT re-prompted: the durable session kept the turn and
      # the supervisor only needs to own its pipes again. Only a settled session
      # that needs to continue receives the supplied continuation prompt.
      #
      # Returns a Hash:
      #   { "session_ref" => ..., "prompted" => bool, "supervision" => record,
      #     "recovery_id" => "...", "downtime_seconds" => float }
      def adopt(session_ref, prompt: nil)
        key = adapter.transport_key(session_ref)
        record = state_store.update(key) do |current|
          current.merge(
            "state" => "recovered",
            "handoff_state" => "adopting",
            "recovered_at" => now,
            "downtime_seconds" => close_downtime(current),
            "episode_id" => current.fetch("episode_id", nil) || episode_id_for(session_ref, nil),
            "updated_at" => now
          )
        end

        recovery_id = "#{record.fetch('episode_id')}-adopt-#{owner_pid}"
        resumed_ref = adapter.attach(session_ref)
        prompted = false
        if adapter.streaming?(resumed_ref)
          # The original turn is still alive. Preserve it; do not re-prompt.
          resumed_ref = resumed_ref
        elsif prompt
          resumed_ref = adapter.prompt(resumed_ref, prompt, mode: "normal")
          prompted = true
        end

        adapter.claim(resumed_ref, harness_pid: extract_pid(resumed_ref), note: "supervisor-adopt")
        record = state_store.update(key) do |current|
          current.merge(
            "handoff_state" => "none",
            "harness_pid" => extract_pid(resumed_ref),
            "harness_started_at" => adapter_harness_started_at(extract_pid(resumed_ref)),
            "owner_pid" => owner_pid,
            "owner_started_at" => owner_started_at,
            "prompted_on_recovery" => prompted,
            "updated_at" => now
          )
        end
        {
          "session_ref" => resumed_ref,
          "prompted" => prompted,
          "supervision" => record,
          "recovery_id" => recovery_id,
          "downtime_seconds" => record.fetch("downtime_seconds", 0.0).to_f
        }
      end

      # Gracefully hand a session off for a supervisor upgrade/restart without
      # killing an in-flight turn. An active turn is cancelled through the
      # backend's supported abort boundary and observed settled, then the
      # transport lease is released cleanly so the next owner attaches to a
      # settled session rather than a half-finished one.
      #
      # Returns the released session ref. The durable record is marked
      # `relinquished`; a fresh supervisor adopts it later through `adopt`.
      def prepare_handoff(session_ref)
        key = adapter.transport_key(session_ref)
        state_store.update(key) do |current|
          current.merge("handoff_state" => "preparing", "updated_at" => now)
        end

        ref = session_ref
        if adapter.streaming?(ref)
          ref = adapter.abort(ref)
          adapter.wait_for_settled(ref, timeout: settle_timeout)
          ref = adapter.get_state(ref)
        end

        adapter.release(ref, harness_pid: extract_pid(ref))
        state_store.update(key) do |current|
          current.merge(
            "handoff_state" => "relinquished",
            "owner_pid" => nil,
            "owner_started_at" => nil,
            "harness_pid" => extract_pid(ref),
            "updated_at" => now
          )
        end
        ref
      rescue StandardError => error
        state_store.update(key) do |current|
          current.merge("handoff_state" => "none", "updated_at" => now)
        end
        raise error
      end

      # Release ownership without handoff preparation. Used on graceful
      # supervisor shutdown when the dashboard is also stopping and there is no
      # in-flight turn to preserve, or after `kill`.
      def relinquish(session_ref)
        adapter.release(session_ref, harness_pid: extract_pid(session_ref))
        key = adapter.transport_key(session_ref)
        state_store.update(key) do |current|
          current.merge(
            "handoff_state" => "relinquished",
            "owner_pid" => nil,
            "owner_started_at" => nil,
            "updated_at" => now
          )
        end
        true
      end

      # Stop a session entirely: terminate its process, release the transport,
      # and drop the supervision record. Used when a worker is killed.
      def kill(session_ref)
        ref = adapter.kill(session_ref)
        relinquish(ref)
      ensure
        state_store.delete(adapter.transport_key(session_ref))
      end

      private

      attr_reader :clock

      def close_downtime(current)
        accumulated = current.fetch("downtime_seconds", 0.0).to_f
        lost_at = parse_time(current.fetch("lost_at", nil))
        return accumulated unless lost_at

        accumulated + [now_time - lost_at, 0.0].max
      end

      def episode_id_for(session_ref, harness_pid)
        identity = [
          session_ref.fetch("session_id", nil) || session_ref.fetch(:session_id, nil),
          harness_pid,
          owner_pid,
          owner_started_at
        ].map(&:to_s).join("|")
        "supervision-#{Digest::SHA256.hexdigest(identity)[0, 20]}"
      end

      def extract_pid(session_ref)
        session_ref.fetch("pid", nil) || session_ref.fetch(:pid, nil)
      end

      def adapter_harness_started_at(pid)
        return nil unless pid

        described = described_owner(pid, nil)
        described&.fetch("started_at", nil)&.iso8601
      end

      def described_owner(pid, started_at)
        return nil unless defined?(Meringue::Harness::ProcessIdentity)
        return nil unless pid

        Meringue::Harness::ProcessIdentity.describe(pid)
      rescue StandardError
        nil
      end

      def now
        now_time.iso8601(6)
      end

      def now_time
        return clock.call.utc if clock.respond_to?(:call)

        Time.now.utc
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil? || value.to_s.strip.empty?

        Time.parse(value.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
