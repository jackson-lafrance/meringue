# frozen_string_literal: true

require "json"
require "thread"
require "time"

module Meringue
  module Harness
    # Bounded, non-destructive event storage for harness transports. Readers own
    # independent integer cursors, so lifecycle reconciliation cannot steal live
    # updates from a selected-agent view (or vice versa).
    class EventJournal
      DEFAULT_MAX_EVENTS = 2_000
      DEFAULT_MAX_BYTES = 2_000_000

      def initialize(max_events: DEFAULT_MAX_EVENTS, max_bytes: DEFAULT_MAX_BYTES)
        @max_events = [max_events.to_i, 1].max
        @max_bytes = [max_bytes.to_i, 1].max
        @entries = []
        @bytes = 0
        @next_sequence = 0
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def publish(event)
        payload = deep_copy(event)
        encoded_bytes = JSON.generate(payload).bytesize

        @mutex.synchronize do
          @next_sequence += 1
          @entries << {
            "sequence" => @next_sequence,
            "timestamp" => Time.now.utc.iso8601,
            "bytes" => encoded_bytes,
            "event" => payload
          }
          @bytes += encoded_bytes
          trim!
          @condition.broadcast
          @next_sequence
        end
      end

      def cursor
        @mutex.synchronize { @next_sequence }
      end

      def read(after:, limit: nil)
        @mutex.synchronize { read_unlocked(after: after, limit: limit) }
      end

      def wait(after:, timeout:, limit: nil)
        deadline = monotonic_now + timeout.to_f
        @mutex.synchronize do
          while @next_sequence <= after.to_i
            remaining = deadline - monotonic_now
            return read_unlocked(after: after, limit: limit) if remaining <= 0

            @condition.wait(@mutex, remaining)
          end
          read_unlocked(after: after, limit: limit)
        end
      end

      private

      def read_unlocked(after:, limit:)
        requested_cursor = after.to_i
        oldest_sequence = @entries.first&.fetch("sequence", nil)
        gap = oldest_sequence && requested_cursor < (oldest_sequence - 1)
        entries = @entries.drop_while { |entry| entry.fetch("sequence") <= requested_cursor }
        entries = entries.first(limit.to_i) if limit && limit.to_i.positive?
        next_cursor = entries.last&.fetch("sequence", nil) || [requested_cursor, @next_sequence].min

        {
          "entries" => entries.map { |entry| deep_copy(entry.reject { |key, _value| key == "bytes" }) },
          "cursor" => next_cursor,
          "latest_cursor" => @next_sequence,
          "gap" => !!gap
        }
      end

      def trim!
        while @entries.length > @max_events || (@bytes > @max_bytes && @entries.length > 1)
          removed = @entries.shift
          @bytes -= removed.fetch("bytes")
        end
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
