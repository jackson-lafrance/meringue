# frozen_string_literal: true

module Meringue
  module Harness
    # Extracts requests that stop an agent until a person responds. Harness adapters call this
    # with events they already drained, so provider event names do not enter kernel state.
    module HumanInput
      REQUEST_TYPES = %w[extension_ui_request approval_request permission_request dangerous_command].freeze
      APPROVAL_KEYS = %w[requiresApproval approvalRequired needsApproval permissionRequired].freeze
      # Pi's extension UI sub-protocol emits every `ctx.ui.*` call as an `extension_ui_request`.
      # Only the dialog methods block the turn until a person answers. `setWidget`, `setStatus`,
      # `notify`, `setTitle` and `set_editor_text` are fire-and-forget: a status-bar extension
      # calling `setWidget` once per turn must not mark every session as blocked on human input.
      EXTENSION_DIALOG_METHODS = %w[select confirm input editor].freeze

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
        return nil if source == "extension_ui_request" && !blocking_extension_ui_request?(details)

        message = details["message"] || details["question"] || details["title"] || details["command"] ||
                  (source == "dangerous_command_approval" ? "Approval is needed before this command can run." : "Human input is needed.")
        {
          "source" => source,
          "request_type" => details["requestType"] || details["request_type"] || type,
          "message" => message.to_s,
          "details" => compact(details)
        }
      end

      # A persisted marker still blocks only when the request it recorded was a dialog. Markers
      # written before fire-and-forget requests were filtered out carry the request `details`, so
      # they are reclassified here instead of pinning a session as blocked until it is prompted.
      def pending_marker?(marker)
        return false unless marker.is_a?(Hash)
        return false unless marker.fetch("state", nil).to_s == "pending"
        return true unless marker.fetch("source", nil).to_s == "extension_ui_request"

        details = marker.fetch("details", nil)
        return true unless details.is_a?(Hash)

        blocking_extension_ui_request?(details)
      end

      def blocking_extension_ui_request?(details)
        method = details["method"] || details["requestType"] || details["request_type"]
        EXTENSION_DIALOG_METHODS.include?(method.to_s)
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
