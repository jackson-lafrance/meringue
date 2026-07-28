# frozen_string_literal: true

require "thread"

module Meringue
  module Sessions
    # Application boundary used by a selected-worker UI. Harness processes stay
    # owned by the kernel/client; this service only exposes transcript polling,
    # kernel-routed prompts, and turn-level cancellation.
    class WorkerSessionService
      class Error < StandardError; end

      def initialize(engine:)
        @engine = engine
      end

      def open(agent_id)
        handle = engine.open_agent_session_view(agent_id)
        Session.new(engine: engine, agent_id: agent_id.to_s, handle: handle)
      rescue StandardError => e
        raise Error, "Unable to open agent #{agent_id}: #{e.message}"
      end

      private

      attr_reader :engine

      class Session
        SNAPSHOT_REFRESH_INTERVAL = 0.35

        attr_reader :agent_id

        def initialize(engine:, agent_id:, handle:)
          @engine = engine
          @agent_id = agent_id
          @handle = handle
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @closed = false
          @paused = false
          @handle_generation = 0
          @cached_snapshot = Harness::SessionView.unavailable_snapshot(
            harness: "unknown",
            availability: "unavailable",
            message: "Connecting to the managed worker session…"
          )
          start_snapshot_refresher
        end

        # Rendering must never wait on an RPC command or a large history file.
        # A background refresher owns those reads and this method returns the
        # most recent immutable-style copy immediately.
        def snapshot
          @mutex.synchronize { deep_copy(@cached_snapshot) }
        end

        def poll_events(limit: nil)
          current_handle.poll_events(limit: limit)
        end

        # mode: "auto" matches a native coding-agent editor: an active turn is
        # steered, while idle/completed history receives a normal continuation.
        def submit(prompt, mode: "auto")
          text = prompt.to_s
          return invalid_result("Prompt cannot be empty.", "prompt_required") if text.strip.empty?

          pre_prompt_snapshot = fresh_snapshot
          selected_mode = mode.to_s == "auto" ? automatic_prompt_mode(pre_prompt_snapshot) : mode.to_s
          result = @engine.apply(
            "type" => "PromptAgent",
            "payload" => { "agent_id" => agent_id, "prompt" => text, "mode" => selected_mode }
          )
          rebind_view if result.fetch("status", nil) == "accepted" && pre_prompt_snapshot.fetch("availability", nil) != "live"
          result.merge("session_prompt_mode" => selected_mode)
        rescue StandardError => e
          failed_result("Prompting agent #{agent_id} failed: #{e.message}", e)
        end

        # Cancels only Pi's current agent operation. It never closes stdin,
        # signals the process, kills the session, or changes workspace state.
        def cancel_current_turn
          @engine.cancel_agent_turn(agent_id)
        rescue StandardError => e
          failed_result("Cancelling agent #{agent_id} failed: #{e.message}", e)
        end

        def close
          handle, refresher = @mutex.synchronize do
            return false if @closed

            @closed = true
            @condition.broadcast
            [@handle, @snapshot_refresher]
          end
          handle.close
          refresher&.join(0.5)
          true
        end

        def closed?
          @mutex.synchronize { @closed }
        end

        # Terminal view does not need transcript RPC/history refreshes. Pausing
        # removes that background JSON work from the latency-sensitive PTY path;
        # resume wakes the refresher immediately when worker view returns.
        def pause
          @mutex.synchronize do
            return false if @closed

            @paused = true
          end
          true
        end

        def resume
          @mutex.synchronize do
            return false if @closed

            @paused = false
            @condition.broadcast
          end
          true
        end

        private

        def current_handle
          @mutex.synchronize do
            raise IOError, "worker session is closed" if @closed

            @handle
          end
        end

        def fresh_snapshot
          # Submission already runs off the render thread, so use a fresh state
          # here instead of a potentially stale display snapshot.
          current_handle.snapshot
        rescue StandardError
          {}
        end

        def automatic_prompt_mode(snapshot)
          snapshot.fetch("session_state", "unknown") == "streaming" ? "steer" : "normal"
        end

        def rebind_view
          replacement = @engine.open_agent_session_view(agent_id)
          previous = @mutex.synchronize do
            if @closed
              replacement.close
              return
            end

            old = @handle
            @handle = replacement
            @handle_generation += 1
            @cached_snapshot = Harness::SessionView.unavailable_snapshot(
              harness: "unknown",
              availability: "unavailable",
              message: "Refreshing the continued worker session…"
            )
            @condition.broadcast
            old
          end
          previous.close
        end

        def start_snapshot_refresher
          @snapshot_refresher = Thread.new do
            Thread.current.name = "meringue-worker-session-view" if Thread.current.respond_to?(:name=)
            refresh_snapshots
          end
        end

        def refresh_snapshots
          loop do
            # Return an explicit sentinel from the synchronize block. `break`
            # here would exit Mutex#synchronize, not this outer loop, leaving a
            # closed session in a hot nil-handle retry loop.
            current = @mutex.synchronize do
              @condition.wait(@mutex) while @paused && !@closed
              @closed ? nil : [@handle, @handle_generation]
            end
            break unless current

            handle, generation = current
            begin
              fresh = handle.snapshot
              @mutex.synchronize do
                @cached_snapshot = deep_copy(fresh) if !@closed && generation == @handle_generation
              end
            rescue StandardError => e
              @mutex.synchronize do
                if !@closed && generation == @handle_generation
                  @cached_snapshot = Harness::SessionView.unavailable_snapshot(
                    harness: @cached_snapshot.fetch("harness", "unknown"),
                    availability: "unavailable",
                    message: "Worker transcript refresh failed: #{e.message}"
                  )
                end
              end
            end

            closed = @mutex.synchronize do
              @condition.wait(@mutex, SNAPSHOT_REFRESH_INTERVAL) unless @closed || @paused
              @closed
            end
            break if closed
          end
        end

        def deep_copy(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, child), copy| copy[key.to_s] = deep_copy(child) }
          when Array
            value.map { |child| deep_copy(child) }
          when String
            value.dup
          else
            value
          end
        end

        def invalid_result(message, error)
          {
            "command_id" => nil,
            "command_type" => "PromptAgent",
            "status" => "rejected",
            "target_id" => agent_id,
            "message" => message,
            "result" => nil,
            "errors" => [error],
            "log_entry_ids" => []
          }
        end

        def failed_result(message, error)
          invalid_result(message, error.class.name).merge("status" => "failed", "errors" => [error.class.name, error.message])
        end
      end
    end
  end
end
