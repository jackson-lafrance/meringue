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
      NEWLINE_KEYS = ["\e\r", "\e\n", "\e[13;2u", "\e[27;2;13~", "\e[13;2~"].freeze
      TAB_KEYS = ["\t"].freeze
      UP_KEYS = ["\e[A"].freeze
      DOWN_KEYS = ["\e[B"].freeze

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
        slash_suggestion_index = 0
        terminal.with_screen do
          terminal.raw do
            last_frame = nil

            loop do
              width, height = terminal.dimensions
              current_state = compose_state(state_provider, input_buffer, slash_suggestion_index)
              frame = render(current_state, width: width, height: height, color: true)
              if frame != last_frame
                terminal.write_frame(frame)
                last_frame = frame
              end

              key = terminal.read_key(timeout: REFRESH_INTERVAL)
              break if quit_key?(key, input_buffer)

              input_buffer, slash_suggestion_index = handle_key(key, input_buffer, slash_suggestion_index, on_submit, current_state)
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

      def handle_key(key, input_buffer, slash_suggestion_index, on_submit, state = State::Models.empty_state)
        return [input_buffer, slash_suggestion_index] unless key

        if slash_suggestion_key?(key) && slash_suggestions_active?(input_buffer)
          return handle_slash_suggestion_key(key, input_buffer, slash_suggestion_index, state)
        end

        if ENTER_KEYS.include?(key)
          completion = safe_slash_completion(input_buffer, slash_suggestion_index, state)
          return [completion, 0] if completion

          submit_prompt(input_buffer, on_submit)
          return [+"", 0]
        end

        if NEWLINE_KEYS.include?(key)
          return [input_buffer + "\n", 0]
        end

        if BACKSPACE_KEYS.include?(key)
          return [input_buffer[0...-1], 0]
        end
        return [input_buffer, slash_suggestion_index] unless printable_key?(key)

        [input_buffer + key, 0]
      end

      def slash_suggestion_key?(key)
        TAB_KEYS.include?(key) || UP_KEYS.include?(key) || DOWN_KEYS.include?(key)
      end

      def handle_slash_suggestion_key(key, input_buffer, slash_suggestion_index, state)
        records = slash_suggestion_records(input_buffer, state)
        return [input_buffer, 0] if records.empty?

        if UP_KEYS.include?(key)
          return [input_buffer, (slash_suggestion_index - 1) % records.length]
        end
        if DOWN_KEYS.include?(key)
          return [input_buffer, (slash_suggestion_index + 1) % records.length]
        end

        [slash_completion_for(records.fetch(slash_suggestion_index.clamp(0, records.length - 1))), 0]
      end

      def safe_slash_completion(input_buffer, slash_suggestion_index, state)
        return nil unless slash_suggestions_active?(input_buffer)

        records = slash_suggestion_records(input_buffer, state)
        return nil if records.empty?

        record = records.fetch(slash_suggestion_index.clamp(0, records.length - 1))
        stripped = input_buffer.to_s.strip.gsub(/\s+/, " ")
        completion = slash_completion_for(record).strip
        appends_space = record.fetch("append_space", record.fetch("requires_arguments", false))

        return nil if stripped.casecmp?(completion) && !appends_space
        return nil unless completion.downcase.start_with?(stripped.downcase) || stripped == "/"

        slash_completion_for(record)
      end

      def slash_suggestions_active?(input_buffer)
        input_buffer.to_s.strip.start_with?("/")
      end

      def slash_suggestion_records(input_buffer, state)
        return [] unless slash_suggestions_active?(input_buffer)

        Input::SlashCommandParser.command_suggestion_records(input_buffer, limit: nil, state: state)
      end

      def slash_completion_for(record)
        completion = record.fetch("completion")
        record.fetch("append_space", record.fetch("requires_arguments", false)) ? "#{completion} " : completion
      end

      def printable_key?(key)
        key.bytes.all? { |byte| byte >= 32 && byte != 127 }
      end

      def submit_prompt(input_buffer, on_submit)
        text = input_buffer.to_s.strip
        return if text.empty?

        slash_command = text.start_with?("/")
        append_message("you", text)
        assistant_message_id = append_message(
          "meringue",
          slash_command ? "Queued slash command…" : head_activity_text(text, phase: :queued),
          status: "queued"
        )
        increment_pending_count

        Thread.new do
          begin
            update_message(
              assistant_message_id,
              text: slash_command ? "Applying slash command…" : head_activity_text(text, phase: :working),
              status: slash_command ? "working" : "head working"
            )
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

      def head_activity_text(text, phase:)
        prompt = text.to_s.strip
        options = if phase == :queued
                    [
                      "Handing this to a fresh head agent…",
                      "Starting a head to read the prompt and current state…",
                      "Queueing a head to plan the next kernel-safe step…"
                    ]
                  else
                    [
                      "A head is reading the prompt against current Meringue state…",
                      "A head is deciding whether to ask, route, or spawn work…",
                      "A head is shaping this into validated kernel commands…",
                      "A head is keeping the request moving without blocking chat…"
                    ]
                  end
        options[stable_activity_index(prompt, phase, options.length)]
      end

      def stable_activity_index(prompt, phase, length)
        "#{phase}:#{prompt}".bytes.sum % length
      end

      def update_message_from_event(message_id, event)
        case event.fetch("event", nil)
        when "head_completed"
          update_message(message_id, text: head_completed_text(event), status: "applying commands")
        when "head_result_applied"
          append_head_result_applied_summary(message_id, event)
        when "slash_command_applied"
          append_to_message(message_id, slash_command_text(event.fetch("command_results", []) || []), status: nil)
        when "worker_wait_started"
          append_to_message(message_id, "Waiting for #{event.fetch("agent_id", "worker")}…", status: "workers running")
        when "worker_completed"
          append_to_message(message_id, worker_completed_line(event), status: "workers running")
        when "worker_wait_failed"
          append_to_message(message_id, "#{event.fetch("agent_id", "worker")} wait failed.", status: "worker wait failed")
        end
      end

      def conversation_text_for(result)
        return slash_command_text(result.fetch("command_results", []) || []) if result.fetch("event", nil) == "slash_command_applied"

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

      def slash_command_text(command_results)
        return "Slash command did not produce a kernel result." if command_results.empty?

        command_results.flat_map { |result| slash_result_lines(result) }.reject { |line| line.to_s.empty? }.join("\n")
      end

      def slash_result_lines(result)
        status = result.fetch("status", "unknown")
        command_type = result.fetch("command_type", "command")
        lines = ["#{command_type}: #{status} — #{result.fetch("message", "")}".strip]
        if status == "accepted"
          lines.concat(slash_result_detail_lines(command_type, result.fetch("result", nil)))
        else
          errors = result.fetch("errors", []) || []
          lines.concat(errors.map { |error| "  - #{error}" })
        end
        lines
      end

      def slash_result_detail_lines(command_type, result)
        case command_type
        when "Help"
          Array(result).map { |item| "  #{item.fetch("usage", "")} — #{item.fetch("description", "")}" }
        when "ListQuestions"
          questions = Array(result)
          return ["  No questions."] if questions.empty?

          questions.map { |question| "  #{question.fetch("id", "?")} [#{question.fetch("status", "?")}] #{question.fetch("question", "")}" }
        when "ListAll", "GetState"
          state = result || {}
          [
            "  projects: #{Array(state["projects"]).length}",
            "  issues: #{Array(state["issues"]).length}",
            "  agents: #{Array(state["agents"]).length}",
            "  questions: #{Array(state["questions"]).length}"
          ]
        else
          target_id = result.is_a?(Hash) ? result["id"] : nil
          target_id ? ["  target: #{target_id}"] : []
        end
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

        lines = ["Completed workers: #{completed_workers.map { |worker| worker.fetch("agent_id", nil) }.compact.join(", ")}"]
        pr_lines = completed_workers.flat_map do |worker|
          Array(worker.fetch("pr_urls", [])).map do |url|
            "#{worker.fetch("agent_id", "worker")} PR: #{url}"
          end
        end
        lines.concat(pr_lines)
      end

      def worker_completed_line(event)
        pr_urls = Array(event.fetch("pr_urls", [])).compact
        return "#{event.fetch("agent_id", "worker")} completed." if pr_urls.empty?

        "#{event.fetch("agent_id", "worker")} completed and reported PR#{pr_urls.length == 1 ? "" : "s"}: #{pr_urls.join(", ")}"
      end

      def worker_wait_status(event)
        command_results = (event.fetch("apply_result", {}).fetch("result", {}) || {}).fetch("command_results", [])
        has_workers = command_results.any? do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" && command_result.fetch("status", nil) == "accepted"
        end

        has_workers ? "workers running" : nil
      end

      def compose_state(state_provider, input_buffer, slash_suggestion_index = 0)
        state = state_provider.call || State::Models.empty_state
        state.merge("_chat" => chat_snapshot(input_buffer, slash_suggestion_index))
      end

      def chat_snapshot(input_buffer, slash_suggestion_index = 0)
        @chat_mutex.synchronize do
          {
            "messages" => @messages.map(&:dup),
            "input_buffer" => input_buffer,
            "slash_suggestion_index" => slash_suggestion_index,
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

          existing = message.fetch("text", "").to_s
          addition = line.to_s
          unless duplicate_trailing_line?(existing, addition)
            message["text"] = [existing, addition].reject { |part| part.to_s.empty? }.join("\n")
          end
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

      def increment_pending_count
        @chat_mutex.synchronize { @pending_count += 1 }
      end

      def decrement_pending_count
        @chat_mutex.synchronize { @pending_count -= 1 if @pending_count.positive? }
      end
    end
  end
end
