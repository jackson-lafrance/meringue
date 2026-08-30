# frozen_string_literal: true

module Meringue
  module Supervisor
    # Harness-agnostic contract for the transport-ownership and handoff
    # operations a backend must expose so the persistent supervisor can own
    # harness sessions independent of the interactive dashboard process.
    #
    # Each supported harness supplies an adapter; the supervisor talks to every backend
    # through this contract alone, so adding a backend never reaches into the
    # supervisor or the kernel: a new adapter implements these methods and
    # registers it with the harness registry.
    #
    # A transport adapter wraps one harness client and its durable
    # transport-ownership record. It answers two kinds of questions:
    #
    #   * ownership: who currently holds the session's RPC pipes, and is that
    #     owner still alive? This is what distinguishes an isolated harness
    #     crash (owner alive, child gone) from a shared supervisor exit (both
    #     gone), and only the second is safe to auto-resume across workers.
    #   * control: attach, prompt, abort, kill, and read state from a session
    #     whose transport the supervisor owns or is taking over.
    #
    # Methods must be harness-neutral: they take and return session refs (Hashes
    # with the generic keys the kernel already uses) and never leak backend
    # command names, process layouts, or vendor-specific semantics into the
    # supervisor. Returning nil from `evidence` preserves the ordinary
    # isolated-process-exit behaviour for backends that cannot report a shared
    # supervisor.
    module TransportAdapter
      # Explicit backend capabilities. Values describe the transport boundary,
      # rather than claiming that every harness has Pi's RPC features.
      def capabilities
        raise NotImplementedError, "transport adapters must implement #capabilities"
      end

      # A stable, filesystem-safe key that names one session's transport across
      # Meringue processes. Two instances cooperate on the same key to claim or
      # release the durable ownership lease.
      def transport_key(_session_ref)
        raise NotImplementedError, "transport adapters must implement #transport_key"
      end

      # Claim durable ownership of a session's transport for the supervisor
      # process. Returns the persisted lease record (a Hash) or raises on
      # failure. Idempotent under the same owner.
      def claim(_session_ref, harness_pid:, note: nil)
        raise NotImplementedError, "transport adapters must implement #claim"
      end

      # Release the durable ownership lease for a session. Refuses (returns
      # false) when the recorded harness pid differs, so a stale releaser can
      # never drop a newer owner's claim.
      def release(_session_ref, harness_pid: nil)
        raise NotImplementedError, "transport adapters must implement #release"
      end

      # Best-effort read of the durable ownership record for a session. Never
      # blocks and never raises; returns {} when no record exists.
      def record_for(_session_ref)
        raise NotImplementedError, "transport adapters must implement #record_for"
      end

      # Harness-neutral evidence about the process supervising a session
      # transport. Returns a Hash shaped like:
      #
      #   { "source" => "transport_ownership",
      #     "transport_key" => "harness-session-...",
      #     "owner_pid" => 123, "owner_started_at" => "...",
      #     "owner_alive" => true,
      #     "harness_pid" => 456, "harness_started_at" => "...",
      #     "harness_alive" => true,
      #     "supervisor_exited" => false,
      #     "observed_at" => "..." }
      #
      # Return nil when the backend cannot report a shared supervisor; the
      # supervisor then treats an exit as isolated and never auto-resumes.
      def evidence(_session_ref)
        raise NotImplementedError, "transport adapters must implement #evidence"
      end

      # Resume a settled session whose transport was released or lost, returning
      # a fresh live session ref. Must never start a second writer while the
      # recorded process is still alive. Raises on failure.
      def attach(_session_ref)
        raise NotImplementedError, "transport adapters must implement #attach"
      end

      # Deliver a prompt to a session. `mode` is one of the harness-neutral
      # prompt modes ("normal", "steer", "follow_up"). Returns the updated
      # session ref. Raises a transient error when delivery must wait for an
      # in-flight turn to settle.
      def prompt(_session_ref, _prompt, mode: "normal")
        raise NotImplementedError, "transport adapters must implement #prompt"
      end

      # Cancel an in-flight turn through the backend's supported cancellation
      # boundary, without killing the session. Returns the updated session ref.
      def abort(_session_ref)
        raise NotImplementedError, "transport adapters must implement #abort"
      end

      # Terminate the session's process and release its transport. Returns the
      # final session ref.
      def kill(_session_ref)
        raise NotImplementedError, "transport adapters must implement #kill"
      end

      # Read the current state of a session. Returns a session ref.
      def get_state(_session_ref)
        raise NotImplementedError, "transport adapters must implement #get_state"
      end

      # Whether the session is currently streaming an active turn. Used by the
      # supervisor to decide whether a recovered session can keep its live turn
      # instead of being re-prompted.
      def streaming?(_session_ref)
        raise NotImplementedError, "transport adapters must implement #streaming?"
      end

      # Wait for an in-flight turn to settle, or raise a transient error when it
      # cannot settle within the supplied timeout. Used during graceful handoff
      # so an upgrade never kills an active turn.
      def wait_for_settled(_session_ref, timeout:)
        raise NotImplementedError, "transport adapters must implement #wait_for_settled"
      end

      # The harness name this adapter serves. Used only for
      # diagnostics and log attribution; the supervisor never branches on it.
      def harness_name
        raise NotImplementedError, "transport adapters must implement #harness_name"
      end
    end
  end
end
