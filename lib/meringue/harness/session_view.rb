# frozen_string_literal: true

require "thread"

module Meringue
  module Harness
    module SessionView
      AVAILABILITIES = %w[live history_follow history unavailable unsupported].freeze
      SESSION_STATES = %w[streaming idle completed errored unknown].freeze

      module_function

      def unavailable_snapshot(harness:, message:, availability: "unsupported", session_state: "unknown")
        {
          "availability" => availability,
          "session_state" => session_state,
          "harness" => harness.to_s,
          "items" => [],
          "capabilities" => {
            "live_events" => false,
            "prompt" => false,
            "steer" => false,
            "follow_up" => false,
            "abort" => false
          },
          "warning" => message.to_s
        }
      end

      # A read-only view of a managed harness transport. It deliberately exposes
      # no process, attach, detach, signal, or kill operations. Prompting and
      # cancellation must go through the kernel-owned worker session service.
      class Handle
        attr_reader :initial_cursor

        def initialize(initial_cursor: 0, snapshot_loader:, event_reader: nil, event_normalizer: nil, close_callback: nil)
          @initial_cursor = initial_cursor.to_i
          @cursor = @initial_cursor
          @snapshot_loader = snapshot_loader
          @event_reader = event_reader
          @event_normalizer = event_normalizer || ->(entry) { [entry] }
          @close_callback = close_callback
          @closed = false
          @mutex = Mutex.new
        end

        def snapshot
          ensure_open!
          value = @snapshot_loader.call
          value.merge("live_cursor" => cursor)
        end

        def poll_events(limit: nil)
          @mutex.synchronize do
            ensure_open_unlocked!
            return empty_poll unless @event_reader

            result = @event_reader.call(@cursor, limit)
            @cursor = result.fetch("cursor", @cursor).to_i
            events = Array(result.fetch("entries", [])).flat_map { |entry| Array(@event_normalizer.call(entry)) }.compact
            {
              "events" => events,
              "cursor" => @cursor,
              "latest_cursor" => result.fetch("latest_cursor", @cursor).to_i,
              "gap" => !!result.fetch("gap", false)
            }
          end
        end

        def close
          callback = @mutex.synchronize do
            return false if @closed

            @closed = true
            @close_callback
          end
          callback&.call
          true
        end

        def closed?
          @mutex.synchronize { @closed }
        end

        private

        def cursor
          @mutex.synchronize { @cursor }
        end

        def empty_poll
          { "events" => [], "cursor" => @cursor, "latest_cursor" => @cursor, "gap" => false }
        end

        def ensure_open!
          @mutex.synchronize { ensure_open_unlocked! }
        end

        def ensure_open_unlocked!
          raise IOError, "session view is closed" if @closed
        end
      end
    end
  end
end
