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

      # How this agent's backend can be focused. Callers branch on the capability rather than on
      # the harness name, so adding a backend never means editing the UI.
      def agent_focus_mode(agent_id)
        engine.agent_focus_mode(agent_id)
      end

      # Attaches to a session that is already running interactively. Unlike the handoff below, this
      # neither interrupts the agent nor replaces its process.
      def attach_agent_live_terminal(agent_id, rows: nil, columns: nil)
        engine.attach_agent_live_terminal(agent_id, rows: rows, columns: columns)
      end

      def detach_agent_live_terminal(agent_id)
        engine.detach_agent_live_terminal(agent_id)
      end

      # Focused PTY input bypasses dashboard PromptAgent routing. Notify the kernel at the point a
      # prompt is submitted so a completed resumable worker is visible as active immediately.
      def note_agent_interactive_prompt(agent_id)
        engine.note_agent_interactive_prompt(agent_id)
      end

      # Focus uses the same application service as transcript views, but remains a
      # process transition owned by the kernel rather than by a pane renderer.
      def begin_agent_interactive_focus(agent_id)
        engine.begin_agent_interactive_focus(agent_id)
      end

      def mark_agent_interactive_focus_started(agent_id, pid:)
        engine.mark_agent_interactive_focus_started(agent_id, pid: pid)
      end

      def end_agent_interactive_focus(agent_id)
        engine.end_agent_interactive_focus(agent_id)
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
          @snapshot_revision = 0
          @cached_snapshot = deep_freeze(
            Harness::SessionView.unavailable_snapshot(
              harness: "unknown",
              availability: "unavailable",
              message: "Connecting to the managed worker session…"
            )
          )
          start_snapshot_refresher
        end

        # Rendering must never wait on an RPC command or a large history file.
        # A background refresher owns those reads and this method returns the
        # most recent deeply frozen snapshot immediately.
        #
        # The snapshot is frozen instead of copied so a large transcript is not
        # duplicated on every frame, and `revision` only changes when the
        # content actually changed. Renderers use it to skip re-layout while a
        # user is only scrolling.
        def snapshot
          @mutex.synchronize { @cached_snapshot.merge("revision" => @snapshot_revision) }
        end

        def revision
          @mutex.synchronize { @snapshot_revision }
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

        # Cancels only the harness's current agent operation. It never closes stdin,
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
            @cached_snapshot = deep_freeze(
              Harness::SessionView.unavailable_snapshot(
                harness: "unknown",
                availability: "unavailable",
                message: "Refreshing the continued worker session…"
              )
            )
            @snapshot_revision += 1
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
              @mutex.synchronize { store_snapshot(fresh, generation) }
            rescue StandardError => e
              @mutex.synchronize do
                next unless !@closed && generation == @handle_generation

                store_snapshot(
                  Harness::SessionView.unavailable_snapshot(
                    harness: @cached_snapshot.fetch("harness", "unknown"),
                    availability: "unavailable",
                    message: "Worker transcript refresh failed: #{e.message}"
                  ),
                  generation
                )
              end
            end

            closed = @mutex.synchronize do
              @condition.wait(@mutex, SNAPSHOT_REFRESH_INTERVAL) unless @closed || @paused
              @closed
            end
            break if closed
          end
        end

        # Caller holds @mutex. The revision only advances on real content change
        # so an idle or completed worker keeps a stable, cache-friendly view.
        def store_snapshot(fresh, generation)
          return if @closed || generation != @handle_generation

          normalized = deep_freeze(fresh)
          return if normalized == @cached_snapshot

          @cached_snapshot = normalized
          @snapshot_revision += 1
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, child), copy| copy[key.to_s] = deep_freeze(child) }.freeze
          when Array
            value.map { |child| deep_freeze(child) }.freeze
          when String
            value.frozen? ? value : value.dup.freeze
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
