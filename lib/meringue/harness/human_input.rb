# frozen_string_literal: true

module Meringue
  module Harness
    # Extracts requests that stop an agent until a person responds. Harness adapters call this
    # with events they already drained, so provider event names do not enter kernel state.
    module HumanInput
      REQUEST_TYPES = %w[extension_ui_request approval_request permission_request dangerous_command].freeze
      APPROVAL_KEYS = %w[requiresApproval approvalRequired needsApproval permissionRequired].freeze

      module_function

      def requests(events)
        Array(events).filter_map { |event| request(event) }
      end

      def request(event)
        return nil unless event.is_a?(Hash)

        record = event["data"].is_a?(Hash) ? event["data"] : event
        type = record["type"].to_s
        source = if REQUEST_TYPES.include?(type)
                   type
                 elsif approval_flag?(record)
                   "dangerous_command_approval"
                 end
        return nil unless source

        details = record["request"].is_a?(Hash) ? record["request"] : record
        message = details["message"] || details["question"] || details["title"] || details["command"] ||
                  (source == "dangerous_command_approval" ? "Approval is needed before this command can run." : "Human input is needed.")
        {
          "source" => source,
          "request_type" => details["requestType"] || details["request_type"] || type,
          "message" => message.to_s,
          "details" => compact(details)
        }
      end

      def approval_flag?(record)
        APPROVAL_KEYS.any? { |key| record[key] == true || record[key].to_s.downcase == "true" }
      end

      def compact(value)
        value.each_with_object({}) do |(key, item), result|
          result[key] = item unless %w[content delta].include?(key.to_s)
        end
      end
    end
  end
end
