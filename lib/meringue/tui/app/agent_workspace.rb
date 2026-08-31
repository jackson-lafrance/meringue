# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The focused workspace overlay: its key handling, its slash commands, its terminal and\ninteractive views, and the prompts sent from it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Native focus is an embedded logs-pane surface. Mouse/focus gestures stay
      # dashboard-owned; ordinary bytes go to the PTY only while that pane has
      # focus, leaving the external composer and AgentTree fully operational.
      def handle_embedded_agent_workspace_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit)
        return nil unless embedded_agent_workspace?

        if mouse_event?(key)
          return handle_mouse_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit)
        end

        command, remainder = consume_workspace_command(key)
        if command
          run_workspace_command(command, state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end
        return [input_buffer, input_cursor, slash_suggestion_index] if remainder.nil?

        focus_result = handle_focus_key(remainder, input_buffer, input_cursor, slash_suggestion_index)
        return focus_result if focus_result
        return nil unless @focused_pane == "logs"

        if @agent_workspace_open_pending
          @agent_workspace_notice = "Focused session is still preparing. Chat and AgentTree controls remain available."
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        # PageUp/PageDown and every other non-leader key belong to the embedded
        # application. In particular, do not page through Meringue's captured
        # screen rows: that changes pixels without changing the harness's own
        # history position.
        if @agent_workspace_view == "terminal"
          forward_agent_workspace_terminal_key(remainder, state)
        else
          forward_agent_workspace_interactive_key(remainder, state)
        end
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def embedded_agent_workspace?
        @agent_workspace_active && (@agent_workspace_interactive || @agent_workspace_open_pending)
      end

      def handle_agent_workspace_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        command, remainder = consume_workspace_command(key)
        if command
          outcome = run_workspace_command(command, state)
          return [+"", 0, NO_SLASH_SELECTION] if outcome == :closed
          return [input_buffer, input_cursor, slash_suggestion_index] if remainder.empty?

          return handle_agent_workspace_key(remainder, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end
        return [input_buffer, input_cursor, slash_suggestion_index] if remainder.nil?

        key = remainder
        if @agent_workspace_interactive && @agent_workspace_view != "terminal"
          forward_agent_workspace_interactive_key(key, state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        @workspace_pastes.sync!(input_buffer)
        if workspace_scroll_key?(key)
          scroll_agent_workspace(key, state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if @agent_workspace_view == "terminal"
          forward_agent_workspace_terminal_key(key, state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if paste_key?(key)
          return insert_pasted_text(input_buffer, input_cursor, paste_text(key)) + [NO_SLASH_SELECTION]
        end
        if plain_text_paste_key?(key)
          return insert_pasted_text(input_buffer, input_cursor, key) + [NO_SLASH_SELECTION]
        end
        if keybinding?("newline", key)
          return insert_text(input_buffer, input_cursor, "\n") + [NO_SLASH_SELECTION]
        end
        if workspace_slash_navigation_key?(key, input_buffer)
          buffer, index = handle_workspace_slash_navigation(key, input_buffer, slash_suggestion_index)
          return [buffer, buffer.chars.length, index]
        end
        if keybinding?("submit", key)
          if WorkspaceCommands.slash_prompt?(input_buffer)
            completion = workspace_slash_completion(input_buffer, slash_suggestion_index)
            return [completion, completion.chars.length, NO_SLASH_SELECTION] if completion

            run_workspace_slash_command(input_buffer, state)
            return [+"", 0, NO_SLASH_SELECTION]
          end

          submit_agent_workspace_prompt(input_buffer, on_submit)
          return [+"", 0, NO_SLASH_SELECTION]
        end
        if ctrl_c_key?(key)
          @workspace_pastes.clear!
          return [+"", 0, NO_SLASH_SELECTION]
        end
        if keybinding?("delete_backward", key)
          return delete_backward(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end
        if keybinding?("delete_forward", key)
          return delete_forward(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end
        if keybinding?("delete_word_backward", key)
          return delete_backward_word(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end
        if keybinding?("delete_word_forward", key)
          return delete_forward_word(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        new_cursor = cursor_after_navigation(key, input_buffer, input_cursor)
        return [input_buffer, new_cursor, slash_suggestion_index] if new_cursor != input_cursor
        return [input_buffer, input_cursor, slash_suggestion_index] unless printable_key?(key)

        insert_text(input_buffer, input_cursor, key) + [NO_SLASH_SELECTION]
      end

      # Returns [action, remainder]. A nil remainder means a leader was consumed
      # and the next key is awaited; otherwise an unrecognized suffix is passed
      # back to the active worker/terminal view rather than silently discarded.
      def consume_workspace_command(key)
        if @workspace_leader_pending
          pending = @workspace_leader_pending
          cancel_workspace_leader!
          return [nil, nil] if pending && ctrl_c_key?(key)

          action, remainder = workspace_action_prefix(key)
          if action
            @agent_workspace_notice = nil
            return [action, remainder]
          end

          @agent_workspace_notice = "Unknown workspace command. #{workspace_leader_help}"
          return [nil, key]
        end

        remainder = keybindings.consume_prefix("workspace_leader", key)
        return [nil, key] unless remainder

        @workspace_leader_pending = true
        @workspace_leader_started_at = monotonic_time
        @agent_workspace_notice = workspace_leader_help
        return [nil, nil] if remainder.empty?

        consume_workspace_command(remainder)
      end

      def workspace_action_prefix(key)
        WORKSPACE_COMMAND_ACTIONS.each do |action|
          remainder = keybindings.consume_prefix(action, key)
          return [action, remainder] if remainder
        end
        [nil, key]
      end

      def run_workspace_command(action, state)
        case action
        when "workspace_switch_view"
          switch_agent_workspace_view(state)
        when "workspace_cycle_filter"
          cycle_agent_workspace_filter
        when "workspace_open_agent_session"
          open_agent_workspace_harness_session(state)
        when "workspace_open_editor"
          open_agent_workspace_editor(state)
        when "workspace_open_pull_request"
          if open_workspace_delivery_pr(state)
            @agent_workspace_notice = "Opened the verified delivery pull request."
            @agent_workspace_error = nil
          else
            @agent_workspace_error = "No verified delivery pull request is available yet."
          end
        when "workspace_close"
          close_agent_workspace(preserve_terminal: true)
          return :closed
        end
        :handled
      end

      def cycle_agent_workspace_filter
        index = WORKSPACE_FILTERS.index(@agent_workspace_filter) || 0
        set_agent_workspace_filter(WORKSPACE_FILTERS[(index + 1) % WORKSPACE_FILTERS.length])
      end

      def set_agent_workspace_filter(filter)
        @agent_workspace_filter = filter
        @workspace_agent_scroll_offset = 0
        @agent_workspace_notice = "Transcript filter: #{@agent_workspace_filter}."
        @agent_workspace_error = nil
        persist_agent_workspace
      end

      # Slash commands are the discoverable twin of the leader keys: they run the
      # same workspace actions plus a couple of session-scoped operations, and
      # anything that is not a slash command stays a direct worker follow-up.
      def workspace_slash_navigation_key?(key, input_buffer)
        WorkspaceCommands.slash_prompt?(input_buffer) && slash_suggestion_navigation_key?(key)
      end

      def handle_workspace_slash_navigation(key, input_buffer, slash_suggestion_index)
        records = workspace_command_suggestion_records(input_buffer)
        return [input_buffer, NO_SLASH_SELECTION] if records.empty?

        if keybinding?("suggestion_previous", key)
          return [input_buffer, slash_selection?(slash_suggestion_index) ? (slash_suggestion_index - 1) % records.length : records.length - 1]
        end
        if keybinding?("suggestion_next", key)
          return [input_buffer, slash_selection?(slash_suggestion_index) ? (slash_suggestion_index + 1) % records.length : 0]
        end

        selected = slash_selection?(slash_suggestion_index) ? slash_suggestion_index.clamp(0, records.length - 1) : 0
        [slash_completion_for(records.fetch(selected)), NO_SLASH_SELECTION]
      end

      # Enter applies a highlighted suggestion instead of running a partial
      # command, matching the dashboard's completion behavior.
      def workspace_slash_completion(input_buffer, slash_suggestion_index)
        return nil unless slash_selection?(slash_suggestion_index)

        records = workspace_command_suggestion_records(input_buffer)
        return nil if records.empty?

        completion = slash_completion_for(records.fetch(slash_suggestion_index.clamp(0, records.length - 1)))
        completion == input_buffer.to_s ? nil : completion
      end

      def workspace_command_suggestion_records(input_buffer)
        WorkspaceCommands.command_suggestion_records(input_buffer)
      end

      def run_workspace_slash_command(input_buffer, state)
        resolution = WorkspaceCommands.resolve(input_buffer)
        if (error = resolution.fetch("error", nil))
          @agent_workspace_error = error
          @agent_workspace_notice = nil
          return :rejected
        end

        action = resolution.fetch("action")
        arguments = resolution.fetch("arguments", [])
        case action
        when "workspace_help"
          @agent_workspace_error = nil
          help_lines = WorkspaceCommands.help_lines
          @agent_workspace_notice = "Workspace commands: #{help_lines.join(" · ")}"
        when "workspace_filter"
          arguments.empty? ? cycle_agent_workspace_filter : set_agent_workspace_filter(arguments.first)
        when "workspace_cwd"
          show_agent_workspace_directory(state)
        when "workspace_cancel_turn"
          cancel_agent_workspace_turn
        else
          return run_workspace_command(action, state)
        end
        :handled
      end

      def show_agent_workspace_directory(state)
        agent = agent_workspace_agent(state)
        return @agent_workspace_error = "Selected agent is no longer available." unless agent

        resolution = Workspace::PathResolver.resolve(agent)
        path = resolution.fetch("path", nil)
        if path
          @agent_workspace_error = nil
          @agent_workspace_notice = ["Workspace directory: #{path}", resolution.fetch("message", nil)].compact.join(" ")
        else
          @agent_workspace_notice = nil
          @agent_workspace_error = resolution.fetch("message", "This worker has no usable workspace directory.")
        end
      end

      # Turn-level cancellation only. It never kills the worker, its session, or
      # its workspace; the kernel owns that lifecycle.
      def cancel_agent_workspace_turn
        unless @agent_workspace_session&.respond_to?(:cancel_current_turn)
          @agent_workspace_error = "Cancelling a turn is not available for this worker session."
          return
        end

        result = @agent_workspace_session.cancel_current_turn
        status = result.is_a?(Hash) ? result.fetch("status", nil).to_s : ""
        if %w[failed rejected errored].include?(status)
          @agent_workspace_notice = nil
          @agent_workspace_error = result.fetch("message", "Could not cancel the current turn.")
        else
          @agent_workspace_error = nil
          @agent_workspace_notice = result.is_a?(Hash) ? result.fetch("message", "Cancelled the worker's current turn.") : "Cancelled the worker's current turn."
        end
      rescue StandardError => e
        @agent_workspace_notice = nil
        @agent_workspace_error = "Could not cancel the current turn: #{e.message}"
      end

      # One leader line describes the whole focused workspace. Labels come from
      # the active keybindings so custom bindings stay accurate, and they stay
      # harness-agnostic so every backend reads correctly.
      def workspace_leader_commands
        WORKSPACE_COMMAND_ACTIONS.filter_map do |action|
          key = keybindings.display_name_for(action)
          next unless key

          { "action" => action, "key" => key, "label" => Keybindings.workspace_command_label(action) }
        end
      end

      def workspace_leader_help
        commands = workspace_leader_commands.map { |command| "#{command.fetch("key")} #{command.fetch("label")}" }
        "#{workspace_leader_label}: #{commands.join(", ")}"
      end

      def workspace_leader_label
        keybindings.display_name_for("workspace_leader") || "workspace leader"
      end

      # Page keys scroll Meringue's transcript view and stay available to the
      # shell in terminal view. Embedded harness sessions are routed before this
      # helper and receive both page keys and wheel events directly.
      def workspace_scroll_key?(key)
        mouse_wheel_up?(key) || mouse_wheel_down?(key) ||
          (@agent_workspace_view == "agent" && (keybinding?("scroll_page_up", key) || keybinding?("scroll_page_down", key)))
      end

      # Offsets are clamped to what the pane can actually scroll. Without the
      # clamp, wheeling past the top kept incrementing a dead offset and the
      # next several scrolls down did nothing, which reads as choppy scrolling.
      def scroll_agent_workspace(key, state = nil)
        step = if mouse_wheel_up?(key) || mouse_wheel_down?(key)
                 MOUSE_SCROLL_STEP * mouse_wheel_count(key)
               else
                 PAGE_SCROLL_STEP
               end
        direction = mouse_wheel_up?(key) || keybinding?("scroll_page_up", key) ? :up : :down
        variable = @agent_workspace_view == "terminal" ? :@workspace_terminal_scroll_offset : :@workspace_agent_scroll_offset
        current = instance_variable_get(variable).to_i
        target = direction == :up ? current + step : current - step
        instance_variable_set(variable, target.clamp(0, agent_workspace_scroll_max(state)))
        persist_agent_workspace(deferred: true)
      end

      def agent_workspace_scroll_max(state)
        return Float::INFINITY unless state && layout.respond_to?(:agent_workspace_scroll_max)

        layout.agent_workspace_scroll_max(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT
        )
      rescue StandardError
        Float::INFINITY
      end

      def switch_agent_workspace_view(state)
        @agent_workspace_view = @agent_workspace_view == "agent" ? "terminal" : "agent"
        @agent_workspace_notice = nil
        @agent_workspace_error = nil
        if @agent_workspace_view == "terminal"
          @agent_workspace_session.pause if !@agent_workspace_interactive && @agent_workspace_session&.respond_to?(:pause)
          prepare_workspace_terminal(state)
        else
          @agent_workspace_session.resume if !@agent_workspace_interactive && @agent_workspace_session&.respond_to?(:resume)
        end
        persist_agent_workspace
      end

      def prepare_workspace_terminal(state)
        agent = agent_workspace_agent(state)
        unless agent
          @agent_workspace_error = "Selected agent is no longer available."
          return
        end
        unless workspace_controller&.respond_to?(:open_terminal)
          @agent_workspace_error = "This harness does not provide an in-dashboard terminal."
          return
        end

        rows, columns = agent_workspace_terminal_dimensions(state)
        result = workspace_controller.open_terminal(agent: agent, state: state, rows: rows, columns: columns)
        unless %w[failed rejected errored].include?(result.fetch("status", nil).to_s)
          @agent_workspace_terminal_size = [rows, columns]
          @workspace_terminal_scroll_offset = 0 if result.fetch("started", false)
        end
        apply_workspace_controller_result(result)
      rescue ArgumentError
        # Compatibility for external controllers written before size-aware workspaces.
        apply_workspace_controller_result(workspace_controller.open_terminal(agent: agent, state: state))
      rescue StandardError => e
        @agent_workspace_error = "Could not open terminal: #{e.message}"
      end

      def agent_workspace_terminal_dimensions(state = nil, embedded: embedded_agent_workspace?)
        if embedded && state && layout.respond_to?(:embedded_agent_workspace_dimensions)
          dimensions = layout.embedded_agent_workspace_dimensions(
            state,
            width: @last_render_width || DEFAULT_WIDTH,
            height: @last_render_height || DEFAULT_HEIGHT
          )
          return [dimensions.fetch("rows"), dimensions.fetch("columns")]
        end

        rows = [(@last_render_height || DEFAULT_HEIGHT) - 3, 1].max
        columns = [(@last_render_width || DEFAULT_WIDTH) - 6, 1].max
        [rows, columns]
      end

      # Backends answer for themselves whether a worker can be focused in place, and how. A
      # controller without the capability keeps the previous behaviour of no embedded session.
      def agent_workspace_focus_mode(agent)
        return "none" unless workspace_controller.respond_to?(:open_workspace)
        # A controller that predates the capability question can only ever have handed off, so
        # that is what it is treated as rather than losing the embedded view entirely.
        return "handoff" unless workspace_controller.respond_to?(:focus_mode)

        workspace_controller.focus_mode(agent: agent).to_s
      rescue StandardError
        "none"
      end

      def resize_agent_workspace_terminal(agent, state)
        return unless workspace_controller&.respond_to?(:resize_terminal)

        rows, columns = agent_workspace_terminal_dimensions(state)
        return if @agent_workspace_terminal_size == [rows, columns]

        result = workspace_controller.resize_terminal(agent: agent, rows: rows, columns: columns)
        @agent_workspace_terminal_size = [rows, columns] unless %w[failed rejected errored].include?(result.fetch("status", nil).to_s)
      end

      def resize_agent_workspace_interactive(agent, state)
        return unless workspace_controller&.respond_to?(:resize_agent)

        rows, columns = agent_workspace_terminal_dimensions(state)
        return if @agent_workspace_terminal_size == [rows, columns]

        result = workspace_controller.resize_agent(agent: agent, rows: rows, columns: columns)
        @agent_workspace_terminal_size = [rows, columns] unless %w[failed rejected errored].include?(result.fetch("status", nil).to_s)
      rescue StandardError => e
        @agent_workspace_error = "Could not resize focused session: #{e.message}"
      end

      def forward_agent_workspace_terminal_key(key, state)
        unless workspace_controller&.respond_to?(:handle_terminal_key)
          @agent_workspace_error = "This harness does not provide an in-dashboard terminal."
          return
        end

        agent = agent_workspace_agent(state)
        return @agent_workspace_error = "Selected agent is no longer available." unless agent

        result = workspace_controller.handle_terminal_key(key: key, agent: agent, state: state)
        apply_workspace_controller_result(result)
      rescue StandardError => e
        @agent_workspace_error = "Terminal input failed: #{e.message}"
      end

      def forward_agent_workspace_interactive_key(key, state)
        unless workspace_controller&.respond_to?(:handle_agent_key)
          @agent_workspace_error = "Agent session is unavailable."
          return
        end

        agent = agent_workspace_agent(state)
        return @agent_workspace_error = "Selected agent is no longer available." unless agent

        result = workspace_controller.handle_agent_key(key: key, agent: agent, state: state)
        apply_workspace_controller_result(result)
      rescue StandardError => e
        @agent_workspace_error = "Agent session input failed: #{e.message}"
      end

      # Reuses the established detached terminal launcher. It validates the
      # saved harness session and starts an external UI without attaching to,
      # replacing, signaling, or taking ownership of Meringue's RPC process.
      def open_agent_workspace_harness_session(state)
        if @agent_workspace_interactive
          @agent_workspace_notice = "The Agent session is already open in this workspace."
          return
        end

        agent = agent_workspace_agent(state)
        return @agent_workspace_error = "Selected agent is no longer available." unless agent

        harness = agent.fetch("harness", nil).to_s
        if harness.empty?
          return @agent_workspace_error = "The selected worker has no recorded agent session to open."
        end
        result = external_agent_session_result(agent)
        apply_workspace_controller_result(result)
      end

      def open_agent_workspace_editor(state)
        agent = agent_workspace_agent(state)
        return @agent_workspace_error = "Selected agent is no longer available." unless agent
        unless workspace_controller&.respond_to?(:open_editor)
          @agent_workspace_error = "No editor command is configured for this workspace."
          return
        end

        apply_workspace_controller_result(workspace_controller.open_editor(agent: agent, state: state))
      rescue StandardError => e
        @agent_workspace_error = "Could not open editor: #{e.message}"
      end

      def apply_workspace_controller_result(result)
        return unless result.is_a?(Hash)

        status = result.fetch("status", result.fetch(:status, nil)).to_s
        message = result.fetch("message", result.fetch(:message, nil)).to_s.strip
        if %w[failed rejected errored].include?(status)
          @agent_workspace_error = message.empty? ? "Workspace action failed." : message
          @agent_workspace_notice = nil
        elsif !message.empty?
          @agent_workspace_notice = message
          @agent_workspace_error = nil
        end
      end

      def submit_agent_workspace_prompt(input_buffer, on_submit)
        # The composer only ever held markers for anything large; the worker gets
        # the full bodies back here, at the one moment the cost is unavoidable.
        text = @workspace_pastes.expand(input_buffer).strip
        @workspace_pastes.clear!
        return if text.empty?

        agent_id = @agent_workspace_agent_id.to_s
        append_agent_workspace_message(agent_id, "you", text)
        @chat_mutex.synchronize { @agent_workspace_pending_count += 1 }
        Thread.new do
          begin
            result, command_result = if @agent_workspace_session&.respond_to?(:submit)
                                       direct_result = @agent_workspace_session.submit(text, mode: "auto")
                                       [direct_result, direct_result]
                                     else
                                       raise "Prompt handling is not enabled for this TUI session." unless on_submit

                                       routed_result = on_submit.call(Shellwords.join(["/prompt", agent_id, text]))
                                       prompt_result = Array(routed_result.fetch("command_results", [])).find { |entry| entry.fetch("command_type", nil) == "PromptAgent" }
                                       [routed_result, prompt_result]
                                     end
            unless command_result&.fetch("status", nil) == "accepted"
              message = command_result&.fetch("message", nil) || result.fetch("summary", "Agent prompt was rejected.")
              append_agent_workspace_message(agent_id, "system", message)
              @chat_mutex.synchronize { @agent_workspace_error = message.to_s }
            end
          rescue StandardError => e
            message = "Could not prompt #{agent_id}: #{e.message}"
            append_agent_workspace_message(agent_id, "system", message)
            @chat_mutex.synchronize { @agent_workspace_error = message }
          ensure
            @chat_mutex.synchronize do
              @agent_workspace_pending_count -= 1 if @agent_workspace_pending_count.positive?
            end
          end
        end
      end

      def append_agent_workspace_message(agent_id, role, text)
        @chat_mutex.synchronize do
          @agent_workspace_messages[agent_id.to_s] << {
            "role" => role,
            "text" => text.to_s,
            "timestamp" => Time.now.utc.iso8601
          }
        end
      end
    end
  end
end
