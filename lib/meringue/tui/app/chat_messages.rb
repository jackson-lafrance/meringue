# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The visible chat buffer: appending, updating, and persisting its messages.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def append_message_once(key, role, text, status: nil, source_id: nil)
        return if key.to_s.empty? || text.to_s.empty?

        message_id = nil
        snapshot = @chat_mutex.synchronize do
          next if @log_event_keys[key]

          @log_event_keys[key] = true
          message_id = append_message_unlocked(role, text, status: status, source_id: source_id)
          log_buffer_snapshot_unlocked
        end
        persist_log_snapshot(snapshot)
        message_id
      end

      def normalize_persisted_message(message)
        return nil unless message.is_a?(Hash)

        id = message.fetch("id", nil)
        return nil unless id

        id = id.to_i
        return nil unless id.positive?

        {
          "id" => id,
          "role" => message.fetch("role", "meringue").to_s,
          "text" => message.fetch("text", "").to_s,
          "status" => message.fetch("status", nil),
          "visible" => message.fetch("visible", nil),
          "timestamp" => message.fetch("timestamp", nil),
          "source_id" => message.fetch("source_id", nil)
        }.compact
      end

      def chat_snapshot(input_buffer, slash_suggestion_index = NO_SLASH_SELECTION, input_cursor = nil)
        @chat_mutex.synchronize do
          {
            "messages" => @messages.map(&:dup),
            "input_buffer" => input_buffer,
            "input_cursor" => clamp_cursor(input_buffer, input_cursor || input_buffer.to_s.length),
            "slash_suggestion_index" => slash_suggestion_index,
            "selection" => @chat_selection,
            "pending_count" => @pending_count,
            "delivery_pr_picker" => delivery_pr_picker_snapshot,
            "model_picker" => model_picker_snapshot,
            "question_picker" => question_picker_snapshot
          }
        end
      end

      def append_message(role, text, status: nil, visible: nil, source_id: nil, persist: true)
        message_id = nil
        snapshot = @chat_mutex.synchronize do
          message_id = append_message_unlocked(role, text, status: status, visible: visible, source_id: source_id)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
        message_id
      end

      def append_message_unlocked(role, text, status: nil, visible: nil, source_id: nil)
        @next_message_id += 1
        @messages << {
          "id" => @next_message_id,
          "role" => role,
          "text" => text,
          "status" => status,
          "visible" => visible,
          "timestamp" => Time.now.utc.iso8601,
          "source_id" => source_id
        }.compact
        @next_message_id
      end

      def update_message(id, text:, status: nil, visible: nil, persist: true)
        snapshot = @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          next unless message

          message["text"] = text
          if status
            message["status"] = status
          else
            message.delete("status")
          end
          apply_message_visibility(message, visible)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
      end

      def append_to_message(id, line, status: nil, visible: nil, persist: true)
        snapshot = @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          next unless message

          existing = message.fetch("text", "").to_s
          addition = line.to_s
          unless duplicate_trailing_line?(existing, addition)
            message["text"] = [existing, addition].reject { |part| part.to_s.empty? }.join("\n")
          end
          apply_message_status(message, status)
          apply_message_visibility(message, visible)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
      end

      def update_message_status(id, status, persist: true)
        snapshot = @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          next unless message

          apply_message_status(message, status)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
      end

      def duplicate_trailing_line?(existing, addition)
        return true if addition.empty?
        return false if existing.empty?

        existing == addition || existing.end_with?("\n#{addition}")
      end

      def apply_message_status(message, status)
        if status
          message["status"] = status
        else
          message.delete("status")
        end
      end

      def apply_message_visibility(message, visible)
        return if visible.nil?

        if visible
          message.delete("visible")
        else
          message["visible"] = false
        end
      end

      def log_buffer_snapshot_unlocked
        @next_log_persist_sequence += 1
        {
          sequence: @next_log_persist_sequence,
          messages: @messages.map(&:dup),
          next_message_id: @next_message_id
        }
      end

      # State persistence can wait behind a kernel write. Keep that I/O outside the chat mutex so
      # rendering, typing, and quitting stay available while another thread owns the state lock.
      # Sequence numbers preserve mutation order when several prompt threads finish together.
      def persist_log_snapshot(snapshot)
        return unless snapshot

        sequence = snapshot.fetch(:sequence)
        @log_persist_mutex.synchronize do
          @log_persist_condition.wait(@log_persist_mutex) until sequence == @completed_log_persist_sequence + 1
          begin
            log_store.save_log_buffer(
              messages: snapshot.fetch(:messages),
              next_message_id: snapshot.fetch(:next_message_id)
            ) if log_store&.respond_to?(:save_log_buffer)
          rescue StandardError
            nil
          ensure
            @completed_log_persist_sequence = sequence
            @log_persist_condition.broadcast
          end
        end
      end

      def increment_pending_count
        @chat_mutex.synchronize { @pending_count += 1 }
      end

      def decrement_pending_count
        @chat_mutex.synchronize { @pending_count -= 1 if @pending_count.positive? }
      end
    end
  end
end
