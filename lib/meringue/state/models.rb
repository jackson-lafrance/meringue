# frozen_string_literal: true

require "time"

module Meringue
  module State
    module Models
      SCHEMA_VERSION = 1

      LIFECYCLE_STATUSES = %w[queued working idle blocked completed errored killed].freeze
      QUESTION_STATUSES = %w[open answered dismissed].freeze
      LOG_LEVELS = %w[info warning error].freeze
      LOG_SOURCE_TYPES = %w[user kernel head worker harness system].freeze

      module_function

      def empty_state(now: Time.now.utc.iso8601)
        ensure_state_shape!({}, now: now)
      end

      def ensure_state_shape!(state, now: Time.now.utc.iso8601)
        state["schema_version"] ||= SCHEMA_VERSION
        state["projects"] ||= []
        state["issues"] ||= []
        state["agents"] ||= []
        state["questions"] ||= []
        state["logs"] ||= []
        state["conversation"] ||= {}
        state["conversation"]["messages"] ||= []
        state["conversation"]["next_message_id"] ||= max_conversation_message_id(state)
        state["counters"] ||= {}
        state["counters"]["projects"] ||= max_numeric_suffix(state.fetch("projects"), /^P(\d+)$/)
        state["counters"]["heads"] ||= max_numeric_suffix(state.fetch("agents").select { |agent| agent["type"] == "head" }, /^H(\d+)$/)
        state["counters"]["questions"] ||= max_numeric_suffix(state.fetch("questions"), /^Q(\d+)$/)
        state["counters"]["logs"] ||= max_numeric_suffix(state.fetch("logs"), /^L(\d+)$/)
        state["counters"]["issues_by_project"] ||= {}
        state["counters"]["workers_by_issue"] ||= {}
        state["metadata"] ||= {}
        state["metadata"]["created_at"] ||= now
        state["metadata"]["updated_at"] ||= state["metadata"].fetch("created_at")
        state
      end

      def max_conversation_message_id(state)
        Array(state.dig("conversation", "messages")).filter_map do |message|
          next unless message.is_a?(Hash)

          id = message["id"] || message[:id]
          id && id.to_i
        end.max || 0
      end

      def max_numeric_suffix(records, pattern)
        Array(records).filter_map do |record|
          next unless record.is_a?(Hash)

          match = record.fetch("id", "").to_s.match(pattern)
          match && match[1].to_i
        end.max || 0
      end
    end
  end
end
