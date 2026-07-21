# frozen_string_literal: true

module Meringue
  module Harness
    # River's official launcher configures and execs Pi, preserving Pi's RPC and
    # session-file contracts. Reuse the mature RPC client while keeping River a
    # distinct provider in persisted Meringue state and user-facing errors.
    class RiverClient < PiClient
      DEFAULT_COMMAND = "river-agent"

      def harness_name
        "river"
      end

      # River's currently distributed Pi emits agent_end rather than the newer
      # agent_settled event used by the standalone Pi integration.
      def wait_for_settled(session_ref, timeout: event_timeout)
        wait_for_event(session_ref, type: "agent_end", timeout: timeout)
      end

      private

      # River currently bundles a Pi release that names sessions through RPC
      # but does not expose Pi's newer --name startup option.
      def session_name_argv(_session_name)
        []
      end
    end
  end
end
