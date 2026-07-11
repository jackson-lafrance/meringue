# frozen_string_literal: true

module Meringue
  module Kernel
    class Command
      attr_reader :type, :payload

      def initialize(type:, payload: {})
        @type = type.to_s
        @payload = payload
      end

      def to_h
        {
          "type" => type,
          "payload" => payload
        }
      end
    end
  end
end
