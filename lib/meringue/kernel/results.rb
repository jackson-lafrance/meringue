# frozen_string_literal: true

module Meringue
  module Kernel
    class Result
      STATUSES = %w[accepted rejected failed].freeze

      attr_reader :command_id, :command_type, :status, :target_id, :message,
                  :result, :errors, :log_entry_ids

      def initialize(command_id:, command_type:, status:, target_id: nil, message: nil,
                     result: nil, errors: [], log_entry_ids: [])
        @command_id = command_id
        @command_type = command_type
        @status = status.to_s
        @target_id = target_id
        @message = message
        @result = result
        @errors = errors
        @log_entry_ids = log_entry_ids
      end

      def to_h
        {
          "command_id" => command_id,
          "command_type" => command_type,
          "status" => status,
          "target_id" => target_id,
          "message" => message,
          "result" => result,
          "errors" => errors,
          "log_entry_ids" => log_entry_ids
        }
      end
    end
  end
end
