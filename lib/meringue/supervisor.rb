# frozen_string_literal: true

require_relative "supervisor/errors"
require_relative "supervisor/transport_adapter"
require_relative "supervisor/state_store"
require_relative "supervisor/pi_adapter"
require_relative "supervisor/service"
require_relative "supervisor/dashboard_client"

module Meringue
  # Persistent, harness-agnostic supervisor that owns harness transport
  # independent of the interactive dashboard process.
  #
  # See {Meringue::Supervisor::Service} for the durable ownership, handoff,
  # `supervision_lost` lifecycle, downtime accounting, and recovery contract.
  # See {Meringue::Supervisor::TransportAdapter} for the backend contract each
  # harness implements to plug into the supervisor without touching the kernel or TUI.
  module Supervisor
    # Registered transport adapters by harness name. Adding a backend means
    # registering an adapter class here; the supervisor and kernel never branch
    # on the harness name. Kept mutable so backends can be registered at load
    # time (and in tests) without reworking the supervisor.
    ADAPTERS = {
      "pi" => PiAdapter
    }

    class << self
      # Resolve a transport adapter for a harness client. Returns nil when no
      # adapter is registered for the client's harness, so callers can fall back
      # to ordinary dashboard-owned transport until that backend is integrated.
      def adapter_for(harness_name, client:, transport_ownership: nil)
        adapter_class = ADAPTERS[harness_name.to_s]
        return nil unless adapter_class

        adapter_class.new(client: client, transport_ownership: transport_ownership)
      end

      def register_adapter(harness_name, adapter_class)
        ADAPTERS[harness_name.to_s] = adapter_class
      end
    end
  end
end
