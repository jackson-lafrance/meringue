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
        attr_reader :agent_id

        def initialize(engine:, agent_id:, handle:)
          @engine = engine
          @agent_id = agent_id
          @handle = handle
          @mutex = Mutex.new
          @closed = false
        end

        def snapshot
          current_handle.snapshot
        end

        def poll_events(limit: nil)
          current_handle.poll_events(limit: limit)
        end

        # mode: "auto" matches a native coding-agent editor: an active turn is
        # steered, while idle/completed history receives a normal continuation.
        def submit(prompt, mode: "auto")
          text = prompt.to_s
          return invalid_result("Prompt cannot be empty.", "prompt_required") if text.strip.empty?

          selected_mode = mode.to_s == "auto" ? automatic_prompt_mode : mode.to_s
          result = @engine.apply(
            "type" => "PromptAgent",
            "payload" => { "agent_id" => agent_id, "prompt" => text, "mode" => selected_mode }
          )
          rebind_view if result.fetch("status", nil) == "accepted"
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
          handle = @mutex.synchronize do
            return false if @closed

            @closed = true
            @handle
          end
          handle.close
          true
        end

        def closed?
          @mutex.synchronize { @closed }
        end

        private

        def current_handle
          @mutex.synchronize do
            raise IOError, "worker session is closed" if @closed

            @handle
          end
        end

        def automatic_prompt_mode
          current_handle.snapshot.fetch("session_state", "unknown") == "streaming" ? "steer" : "normal"
        rescue StandardError
          "normal"
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
            old
          end
          previous.close
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
