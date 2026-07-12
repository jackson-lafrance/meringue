# frozen_string_literal: true

module Meringue
  module Heads
    class PiRunner < HarnessRunner
      InvalidHeadResultError = Meringue::Heads::InvalidHeadResultError

      def initialize(harness_client:, cwd: Dir.pwd, session_name_prefix: "Meringue Head",
                     timeout: Meringue::Harness::PiClient::DEFAULT_EVENT_TIMEOUT)
        super(
          harness_client: harness_client,
          cwd: cwd,
          session_name_prefix: session_name_prefix,
          timeout: timeout
        )
      end
    end
  end
end
