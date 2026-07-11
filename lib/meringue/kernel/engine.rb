# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      attr_reader :store, :harness_client, :head_runner, :workspace_manager

      def initialize(store: State::Store.new, harness_client: Harness::FakeClient.new,
                     head_runner: Heads::FakeRunner.new,
                     workspace_manager: Workspace::Manager.new)
        @store = store
        @harness_client = harness_client
        @head_runner = head_runner
        @workspace_manager = workspace_manager
      end

      def list_all
        store.load
      end

      def apply(command)
        Result.new(
          command_id: nil,
          command_type: command.type,
          status: "rejected",
          message: "Kernel command application is not implemented in this scaffold.",
          errors: ["not_implemented"]
        ).to_h
      end
    end
  end
end
