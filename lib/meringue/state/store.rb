# frozen_string_literal: true

require "fileutils"
require "json"
require "thread"
require "time"

require_relative "compactor"

module Meringue
  module State
    class Store
      DEFAULT_PATH = File.expand_path("~/.meringue/state.json")

      def self.default_path
        File.expand_path(ENV.fetch("MERINGUE_STATE_PATH", DEFAULT_PATH))
      end

      attr_reader :path

      def initialize(path: self.class.default_path)
        @path = File.expand_path(path)
        @mutex = Mutex.new
      end

      # Saves publish a complete snapshot with an atomic rename, so readers can
      # safely observe either the previous or next snapshot without waiting for
      # serialization and disk I/O to finish. Keeping TUI reads off the writer
      # mutex is important because worker provisioning checkpoints state several
      # times while a completed head result is being applied.
      def load
        load_unlocked
      end

      def compact!
        @mutex.synchronize do
          return false unless File.exist?(path)

          state = JSON.parse(File.read(path))
          previous_log_count = Array(state["logs"]).length
          Models.ensure_state_shape!(state)
          changed = state.fetch("logs").length != previous_log_count
          changed = Compactor.compact!(state) || changed
          save_unlocked(state, preserve_log_buffer: false) if changed
          changed
        end
      end

      def save(state, preserve_log_buffer: true, preserve_conversation: nil)
        preserve_log_buffer = preserve_conversation unless preserve_conversation.nil?
        @mutex.synchronize do
          save_unlocked(state, preserve_log_buffer: preserve_log_buffer)
        end
      end

      def save_log_buffer(messages:, next_message_id: nil)
        @mutex.synchronize do
          state = load_unlocked
          state["conversation"] = {
            "messages" => Array(messages).map { |message| deep_copy(message) },
            "next_message_id" => next_message_id ? next_message_id.to_i : 0
          }
          state["conversation"]["next_message_id"] = Models.max_log_message_id(state) if state["conversation"]["next_message_id"].zero?
          state.fetch("metadata")["updated_at"] = Time.now.utc.iso8601
          save_unlocked(state, preserve_log_buffer: false)
        end
      end
      alias save_conversation save_log_buffer

      private

      def load_unlocked
        return Models.empty_state unless File.exist?(path)

        read_state_unlocked
      end

      def read_state_unlocked
        state = JSON.parse(File.read(path))
        # Normalize first so legacy oversized histories are pruned before the
        # deep string compactor visits entries that will not be retained.
        Models.ensure_state_shape!(state)
        Compactor.compact!(state)
        state
      end

      def save_unlocked(state, preserve_log_buffer: true)
        FileUtils.mkdir_p(File.dirname(path))
        temp_path = "#{path}.tmp.#{$$}"
        Models.ensure_state_shape!(state)
        Compactor.compact!(state)
        merge_persisted_log_buffer!(state) if preserve_log_buffer

        File.write(temp_path, JSON.pretty_generate(state) + "\n")
        File.rename(temp_path, path)
        state
      ensure
        File.delete(temp_path) if temp_path && File.exist?(temp_path)
      end

      def merge_persisted_log_buffer!(state)
        return unless File.exist?(path)

        persisted = JSON.parse(File.read(path))
        Models.ensure_state_shape!(persisted)
        state["conversation"] = merge_log_buffer(
          state.fetch("conversation", {}),
          persisted.fetch("conversation", {})
        )
      rescue JSON::ParserError
        nil
      end

      def merge_log_buffer(incoming, persisted)
        incoming_messages = Array(incoming["messages"])
        persisted_messages = Array(persisted["messages"])
        messages_by_id = {}
        incoming_messages.each { |message| messages_by_id[message_id(message)] = message if message_id(message) }
        persisted_messages.each { |message| messages_by_id[message_id(message)] = message if message_id(message) }
        merged_messages = messages_by_id.values.sort_by { |message| message_id(message).to_i }
        {
          "messages" => merged_messages,
          "next_message_id" => [
            integer_value(incoming["next_message_id"]),
            integer_value(persisted["next_message_id"]),
            merged_messages.filter_map { |message| message_id(message)&.to_i }.max.to_i
          ].max
        }
      end

      def message_id(message)
        return nil unless message.is_a?(Hash)

        message["id"] || message[:id]
      end

      def integer_value(value)
        value ? value.to_i : 0
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
