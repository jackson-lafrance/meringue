# frozen_string_literal: true

module Meringue
  module TUI
    class App
      DEFAULT_WIDTH = 100
      DEFAULT_HEIGHT = 32
      REFRESH_INTERVAL = 0.2
      QUIT_KEYS = ["\u0003", "\u0004"].freeze
      BACKSPACE_KEYS = ["\u007f", "\b"].freeze
      ENTER_KEYS = ["\r", "\n"].freeze

      def initialize(layout: Layout.new, input: $stdin, out: $stdout, terminal: nil)
        @layout = layout
        @out = out
        @terminal = terminal || Terminal.new(input: input, output: out)
        @messages = []
        @next_message_id = 0
        @pending_count = 0
        @chat_mutex = Mutex.new
      end

      def render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        layout.render(state, width: width, height: height, color: color)
      end

      def run(state: nil, state_provider: nil, on_submit: nil)
        state_provider ||= -> { state || State::Models.empty_state }
        return render_once(compose_state(state_provider, "")) unless terminal.interactive?

        input_buffer = +""
        terminal.with_screen do
          terminal.raw do
            last_frame = nil

            loop do
              width, height = terminal.dimensions
              frame = render(compose_state(state_provider, input_buffer), width: width, height: height, color: true)
              if frame != last_frame
                terminal.write_frame(frame)
                last_frame = frame
              end

              key = terminal.read_key(timeout: REFRESH_INTERVAL)
              break if quit_key?(key, input_buffer)

              input_buffer = handle_key(key, input_buffer, on_submit)
            end
          end
        end

        0
      rescue Interrupt
        0
      end

      private

      attr_reader :layout, :out, :terminal

      def render_once(state)
        out.puts render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        0
      end

      def quit_key?(key, input_buffer)
        return false unless key
        return true if QUIT_KEYS.include?(key)

        key == "\e" && input_buffer.empty?
      end

      def handle_key(key, input_buffer, on_submit)
        return input_buffer unless key

        if ENTER_KEYS.include?(key)
          submit_prompt(input_buffer, on_submit)
          return +""
        end

        return input_buffer[0...-1] if BACKSPACE_KEYS.include?(key)
        return input_buffer unless printable_key?(key)

        input_buffer + key
      end

      def printable_key?(key)
        key.bytes.all? { |byte| byte >= 32 && byte != 127 }
      end

      def submit_prompt(input_buffer, on_submit)
        text = input_buffer.to_s.strip
        return if text.empty?

        append_message("you", text)
        assistant_message_id = append_message("meringue", "Queued for the head agent loop…", status: "queued")
        increment_pending_count

        Thread.new do
          begin
            update_message(assistant_message_id, text: "Running head agent loop…", status: "working")
            result = if on_submit
                       on_submit.call(text) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     else
                       unavailable_prompt_handler_result
                     end
            update_message(assistant_message_id, text: conversation_text_for(result), status: nil)
          rescue StandardError => e
            update_message(assistant_message_id, text: "Head loop failed: #{e.class}: #{e.message}", status: "errored")
          ensure
            decrement_pending_count
          end
        end
      end

      def unavailable_prompt_handler_result
        {
          "summary" => "Prompt handling is not enabled for this TUI session.",
          "spawn_head_result" => { "status" => "rejected", "message" => "No prompt handler configured." }
        }
      end

      def update_message_from_event(message_id, event)
        case event.fetch("event", nil)
        when "head_completed"
          update_message(message_id, text: head_completed_text(event), status: "applying commands")
        when "head_result_applied"
          append_head_result_applied_summary(message_id, event)
        when "worker_wait_started"
          append_to_message(message_id, "Waiting for #{event.fetch("agent_id", "worker")}…", status: "workers running")
        when "worker_completed"
          append_to_message(message_id, "#{event.fetch("agent_id", "worker")} completed.", status: "workers running")
        when "worker_wait_failed"
          append_to_message(message_id, "#{event.fetch("agent_id", "worker")} wait failed.", status: "worker wait failed")
        end
      end

      def conversation_text_for(result)
        spawn_result = result.fetch("spawn_head_result", {}) || {}
        apply_result = result.fetch("apply_head_result", {}) || {}
        head = spawn_result.fetch("result", {}) || {}
        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", {}) || {}

        lines = []
        if head_result.any?
          lines << format_head_result(spawn_result.fetch("target_id", "head"), head_result)
        else
          lines << result.fetch("summary", spawn_result.fetch("message", "Head loop completed."))
        end

        lines.concat(command_summary_lines(apply_result))
        lines.concat(worker_summary_lines(result.fetch("worker_wait_results", []) || []))
        lines.reject { |line| line.to_s.empty? }.join("\n")
      end

      def head_completed_text(event)
        format_head_result(event.fetch("head_id", "head"), event.fetch("head_result", {}) || {})
      end

      def append_head_result_applied_summary(message_id, event)
        lines = command_summary_lines(event.fetch("apply_result", {}) || {})
        status = worker_wait_status(event)
        if lines.empty?
          update_message_status(message_id, status)
        else
          append_to_message(message_id, lines.join("\n"), status: status)
        end
      end

      def format_head_result(head_id, head_result)
        [
          "#{head_id}: #{head_result.fetch("title", "Head completed")}".strip,
          head_result.fetch("summary", "")
        ].reject { |line| line.to_s.empty? }.join("\n")
      end

      def command_summary_lines(apply_result)
        command_results = (apply_result.fetch("result", {}) || {}).fetch("command_results", [])
        spawned_workers = command_results.select do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" && command_result.fetch("status", nil) == "accepted"
        end
        return [] if spawned_workers.empty?

        ["Spawned workers: #{spawned_workers.map { |worker| worker.fetch("target_id", nil) }.compact.join(", ")}"]
      end

      def worker_summary_lines(worker_wait_results)
        completed_workers = worker_wait_results.select { |worker| worker.fetch("status", nil) == "settled" }
        return [] if completed_workers.empty?

        ["Completed workers: #{completed_workers.map { |worker| worker.fetch("agent_id", nil) }.compact.join(", ")}"]
      end

      def worker_wait_status(event)
        command_results = (event.fetch("apply_result", {}).fetch("result", {}) || {}).fetch("command_results", [])
        has_workers = command_results.any? do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" && command_result.fetch("status", nil) == "accepted"
        end

        has_workers ? "workers running" : nil
      end

      def compose_state(state_provider, input_buffer)
        state = state_provider.call || State::Models.empty_state
        state.merge("_chat" => chat_snapshot(input_buffer))
      end

      def chat_snapshot(input_buffer)
        @chat_mutex.synchronize do
          {
            "messages" => @messages.map(&:dup),
            "input_buffer" => input_buffer,
            "pending_count" => @pending_count
          }
        end
      end

      def append_message(role, text, status: nil)
        @chat_mutex.synchronize do
          @next_message_id += 1
          @messages << {
            "id" => @next_message_id,
            "role" => role,
            "text" => text,
            "status" => status
          }.compact
          @next_message_id
        end
      end

      def update_message(id, text:, status: nil)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          message["text"] = text
          if status
            message["status"] = status
          else
            message.delete("status")
          end
        end
      end

      def append_to_message(id, line, status: nil)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          message["text"] = [message.fetch("text", ""), line].reject { |part| part.to_s.empty? }.join("\n")
          apply_message_status(message, status)
        end
      end

      def update_message_status(id, status)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          apply_message_status(message, status)
        end
      end

      def apply_message_status(message, status)
        if status
          message["status"] = status
        else
          message.delete("status")
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
