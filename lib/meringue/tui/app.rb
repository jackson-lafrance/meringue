# frozen_string_literal: true

require "time"
require_relative "keybindings"

module Meringue
  module TUI
    class App
      DEFAULT_WIDTH = 100
      DEFAULT_HEIGHT = 32
      REFRESH_INTERVAL = 0.2
      MOUSE_SCROLL_STEP = 3
      PAGE_SCROLL_STEP = 8
      DOUBLE_CLICK_INTERVAL_SECONDS = 0.5
      CTRL_C = "\u0003"
      # Keyboard-disambiguation modes used for Shift+Enter can encode Ctrl-C as
      # CSI-u or xterm modifyOtherKeys instead of the raw ETX byte.
      CTRL_C_KEYS = [CTRL_C, "\e[99;5u", "\e[67;5u", "\e[27;5;99~", "\e[27;5;67~"].freeze
      CTRL_D = "\u0004"
      CTRL_W = "\u0017"
      BACKSPACE_KEYS = ["\u007f", "\b"].freeze
      DELETE_KEYS = ["\e[3~"].freeze
      ENTER_KEYS = ["\r", "\n"].freeze
      SHIFT_ENTER_KEYS = ["\e[13;2u", "\e[10;2u", "\e[27;2;13~", "\e[27;2;10~", "\e[13;2~", "\e[10;2~"].freeze
      TAB_KEYS = ["\t"].freeze
      LEFT_KEYS = ["\e[D", "\eOD"].freeze
      RIGHT_KEYS = ["\e[C", "\eOC"].freeze
      UP_KEYS = ["\e[A", "\eOA"].freeze
      DOWN_KEYS = ["\e[B", "\eOB"].freeze
      HOME_KEYS = ["\e[H", "\e[1~", "\eOH", "\u0001"].freeze
      END_KEYS = ["\e[F", "\e[4~", "\eOF", "\u0005"].freeze
      WORD_LEFT_KEYS = ["\eb", "\eB", "\e[1;3D", "\e[1;5D", "\e[1;9D"].freeze
      WORD_RIGHT_KEYS = ["\ef", "\eF", "\e[1;3C", "\e[1;5C", "\e[1;9C"].freeze
      # Alt/Option-Backspace is reported as ESC+Backspace by some terminals,
      # and as CSI-u / modifyOtherKeys once keyboard disambiguation is enabled.
      WORD_BACKSPACE_KEYS = ["\e\u007f", "\e\b", "\e[127;3u", "\e[8;3u", "\e[27;3;127~", "\e[27;3;8~", CTRL_W].freeze
      WORD_DELETE_KEYS = ["\ed", "\eD", "\e[3;3~", "\e[3;5~"].freeze
      PAGE_UP_KEYS = ["\e[5~"].freeze
      PAGE_DOWN_KEYS = ["\e[6~"].freeze
      SHIFT_TAB_KEYS = ["\e[Z"].freeze
      CTRL_TAB_KEYS = ["\e[27;5;9~", "\e[9;5u"].freeze
      FOCUS_FORWARD_KEYS = CTRL_TAB_KEYS.freeze
      FOCUS_BACK_KEYS = SHIFT_TAB_KEYS.freeze
      FOCUS_ORDER = %w[chat agent_tree logs].freeze
      AGENT_TREE_FORWARD_KEYS = (DOWN_KEYS + RIGHT_KEYS).freeze
      AGENT_TREE_BACK_KEYS = (UP_KEYS + LEFT_KEYS).freeze

      def initialize(layout: Layout.new, input: $stdin, out: $stdout, terminal: nil, session_opener: nil, pull_request_opener: nil, log_store: nil, conversation_store: nil, keybindings: Keybindings.default)
        @layout = layout
        @out = out
        @terminal = terminal || Terminal.new(input: input, output: out)
        @session_opener = session_opener || Harness::TerminalSessionOpener.new
        @pull_request_opener = pull_request_opener || PullRequestOpener.new
        @log_store = log_store || conversation_store
        @keybindings = keybindings || Keybindings.default
        @messages = []
        @next_message_id = 0
        @pending_count = 0
        @agent_tree_navigation_active = false
        @quit_requested = false
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = nil
        @focused_pane = "chat"
        @last_worker_click = nil
        @last_render_width = DEFAULT_WIDTH
        @last_render_height = DEFAULT_HEIGHT
        @scroll_offsets = Hash.new(0)
        @log_event_keys = {}
        @started_at = Time.iso8601(Time.now.utc.iso8601)
        @chat_mutex = Mutex.new
      end

      def render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        layout.render(state, width: width, height: height, color: color)
      end

      def restore_logs!(state)
        legacy_log_buffer = state.fetch("conversation", {}) || {}
        messages = Array(legacy_log_buffer.fetch("messages", []))
        @chat_mutex.synchronize do
          @messages = messages.map { |message| normalize_persisted_message(message) }.compact
          @next_message_id = [legacy_log_buffer.fetch("next_message_id", 0).to_i, @messages.map { |message| message.fetch("id", 0).to_i }.max.to_i].max
        end
      end

      def remember_existing_log_events!(state)
        Array(state.fetch("agents", [])).each do |agent|
          if existing_head_completion_event?(agent)
            remember_log_event(head_completed_key(agent.fetch("id", nil)))
          elsif existing_worker_completion_event?(agent)
            remember_log_event(worker_completed_key(agent.fetch("id", nil)))
          end
        end
      end

      def run(state: nil, state_provider: nil, on_submit: nil)
        state_provider ||= -> { state || State::Models.empty_state }
        return render_once(compose_state(state_provider, "")) unless terminal.interactive?

        @quit_requested = false
        input_buffer = +""
        input_cursor = 0
        slash_suggestion_index = 0
        terminal.with_screen do
          terminal.raw do
            last_frame = nil

            loop do
              width, height = terminal.dimensions
              @last_render_width = width
              @last_render_height = height
              current_state = compose_state(state_provider, input_buffer, slash_suggestion_index, input_cursor)
              frame = render(current_state, width: width, height: height, color: true)
              if frame != last_frame
                terminal.write_frame(frame)
                last_frame = frame
              end

              key = terminal.read_key(timeout: REFRESH_INTERVAL)
              break if quit_key?(key, input_buffer)

              input_buffer, input_cursor, slash_suggestion_index = handle_key(
                key,
                input_buffer,
                input_cursor,
                slash_suggestion_index,
                on_submit,
                current_state
              )
              break if @quit_requested
            end
          end
        end

        0
      rescue Interrupt
        0
      end

      private

      attr_reader :layout, :out, :terminal, :session_opener, :pull_request_opener, :log_store, :keybindings

      def render_once(state)
        out.puts render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        0
      end

      def quit_key?(key, input_buffer)
        return false unless key
        return true if keybinding?("quit", key)

        ctrl_c_key?(key) && input_buffer.empty? && !@agent_tree_navigation_active
      end

      def handle_key(key, input_buffer, input_cursor_or_slash_index = 0, slash_index_or_on_submit = nil, on_submit_or_state = nil, state_arg = nil)
        old_signature = !slash_index_or_on_submit.is_a?(Integer)
        if old_signature
          slash_suggestion_index = input_cursor_or_slash_index.to_i
          on_submit = slash_index_or_on_submit
          state = on_submit_or_state || State::Models.empty_state
          buffer, _cursor, index = handle_chat_key(
            key,
            input_buffer,
            input_buffer.chars.length,
            slash_suggestion_index,
            on_submit,
            state,
            legacy_slash_navigation: true
          )
          return [buffer, index]
        end

        handle_chat_key(
          key,
          input_buffer,
          input_cursor_or_slash_index,
          slash_index_or_on_submit,
          on_submit_or_state,
          state_arg || State::Models.empty_state
        )
      end

      def handle_chat_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state, legacy_slash_navigation: false)
        input_cursor = clamp_cursor(input_buffer, input_cursor)
        return [input_buffer, input_cursor, slash_suggestion_index] unless key

        if paste_key?(key)
          return insert_text(input_buffer, input_cursor, paste_text(key)) + [0]
        end

        mouse_focus_result = handle_mouse_focus_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return mouse_focus_result if mouse_focus_result

        if plain_text_paste_key?(key)
          return insert_text(input_buffer, input_cursor, key) + [0]
        end

        if legacy_slash_navigation && slash_suggestion_navigation_key?(key) && slash_suggestions_active?(input_buffer)
          buffer, index = handle_legacy_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
          return [buffer, buffer.chars.length, index]
        end

        if @agent_tree_navigation_active
          return handle_agent_tree_navigation_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        end

        if slash_suggestion_navigation_key?(key) && slash_suggestions_active?(input_buffer)
          buffer, index = handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
          return [buffer, buffer.chars.length, index]
        end

        focus_result = handle_focus_key(key, input_buffer, input_cursor, slash_suggestion_index)
        return focus_result if focus_result

        scroll_result = handle_focused_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return scroll_result if scroll_result

        focused_action_result = handle_focused_action_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return focused_action_result if focused_action_result

        if keybinding?("newline", key)
          return insert_text(input_buffer, input_cursor, "\n") + [0]
        end

        if keybinding?("submit", key)
          return [+"", 0, 0] if local_navigation_command_without_id?(input_buffer) && handle_local_navigation_command(input_buffer, state)

          completion = safe_slash_completion(input_buffer, slash_suggestion_index, state)
          return [completion, completion.chars.length, 0] if completion

          return [+"", 0, 0] if handle_local_navigation_command(input_buffer, state)

          submit_prompt(input_buffer, on_submit)
          return [+"", 0, 0]
        end

        if ctrl_c_key?(key)
          return [+"", 0, 0]
        end

        if keybinding?("delete_backward", key)
          return delete_backward(input_buffer, input_cursor) + [0]
        end

        if keybinding?("delete_forward", key)
          return delete_forward(input_buffer, input_cursor) + [0]
        end

        if keybinding?("delete_word_backward", key)
          return delete_backward_word(input_buffer, input_cursor) + [0]
        end

        if keybinding?("delete_word_forward", key)
          return delete_forward_word(input_buffer, input_cursor) + [0]
        end

        new_cursor = cursor_after_navigation(key, input_buffer, input_cursor)
        return [input_buffer, new_cursor, slash_suggestion_index] if new_cursor != input_cursor

        return [input_buffer, input_cursor, slash_suggestion_index] unless printable_key?(key)

        @focused_pane = "chat"
        insert_text(input_buffer, input_cursor, key) + [0]
      end

      def keybinding?(action, key)
        keybindings.match?(action, key)
      end

      def ctrl_c_key?(key)
        keybinding?("clear_or_quit", key)
      end

      def slash_suggestion_key?(key)
        keybinding?("complete_suggestion", key)
      end

      def slash_suggestion_navigation_key?(key)
        keybinding?("complete_suggestion", key) || keybinding?("suggestion_previous", key) || keybinding?("suggestion_next", key)
      end

      def handle_legacy_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
        handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
      end

      def handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
        records = slash_suggestion_records(input_buffer, state)
        return [input_buffer, 0] if records.empty?

        if keybinding?("suggestion_previous", key)
          return [input_buffer, (slash_suggestion_index - 1) % records.length]
        end
        if keybinding?("suggestion_next", key)
          return [input_buffer, (slash_suggestion_index + 1) % records.length]
        end

        [slash_completion_for(records.fetch(slash_suggestion_index.clamp(0, records.length - 1))), 0]
      end


      def handle_focus_key(key, input_buffer, input_cursor, slash_suggestion_index)
        return nil if slash_suggestions_active?(input_buffer) && slash_suggestion_key?(key)

        if keybinding?("focus_previous", key)
          cycle_focus(-1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("focus_next", key)
          cycle_focus(1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        nil
      end

      def cycle_focus(delta = 1)
        current_index = FOCUS_ORDER.index(@focused_pane) || 0
        @focused_pane = FOCUS_ORDER[(current_index + delta) % FOCUS_ORDER.length]
      end

      def handle_focused_action_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless %w[agent_tree logs].include?(@focused_pane) && keybinding?("submit", key)

        enter_agent_tree_navigation(state)
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def handle_focused_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless focused_scrollable?

        if mouse_wheel_up?(key)
          scroll_focused_pane(:up, steps: MOUSE_SCROLL_STEP * mouse_wheel_count(key), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if mouse_wheel_down?(key)
          scroll_focused_pane(:down, steps: MOUSE_SCROLL_STEP * mouse_wheel_count(key), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("scroll_up", key) || keybinding?("scroll_page_up", key)
          scroll_focused_pane(:up, steps: scroll_key_step(page: keybinding?("scroll_page_up", key)), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("scroll_down", key) || keybinding?("scroll_page_down", key)
          scroll_focused_pane(:down, steps: scroll_key_step(page: keybinding?("scroll_page_down", key)), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        nil
      end

      def focused_scrollable?
        @focused_pane != "chat"
      end

      def handle_mouse_focus_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless mouse_button_press?(key)

        pane = pane_at_mouse_position(key, state)
        return [input_buffer, input_cursor, slash_suggestion_index] unless pane

        @focused_pane = pane
        if pane == "agent_tree"
          worker_id = worker_at_mouse_position(key, state)
          handle_agent_tree_worker_click(worker_id, key, state) if worker_id
        else
          @last_worker_click = nil
          exit_agent_tree_navigation if @agent_tree_navigation_active && !%w[agent_tree logs].include?(pane)
        end
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def mouse_button_press?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" &&
          key.fetch("kind", nil) == "button" && key.fetch("pressed", false) &&
          (key.fetch("button", 0).to_i & 3).zero?
      end

      def pane_at_mouse_position(key, state)
        layout.pane_at(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT,
          x: key.fetch("x", 1).to_i - 1,
          y: key.fetch("y", 1).to_i - 1
        )
      end

      def worker_at_mouse_position(key, state)
        layout.agent_tree_worker_at(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT,
          x: key.fetch("x", 1).to_i - 1,
          y: key.fetch("y", 1).to_i - 1
        )
      end

      def handle_agent_tree_worker_click(worker_id, key, state)
        double_click = worker_double_click?(worker_id, key)
        select_agent_tree_worker(state, worker_id)
        open_pr_by_agent_id(state, worker_id) if double_click
      end

      def select_agent_tree_worker(state, worker_id)
        return false unless agent_tree_selectable_agent_ids(state).include?(worker_id)

        @agent_tree_navigation_active = true
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = worker_id
        true
      end

      def worker_double_click?(worker_id, key)
        now = monotonic_time
        click = {
          agent_id: worker_id,
          x: key.fetch("x", nil).to_i,
          y: key.fetch("y", nil).to_i,
          at: now
        }
        previous = @last_worker_click
        @last_worker_click = click
        return false unless previous
        return false unless previous.fetch(:agent_id, nil) == worker_id
        return false unless previous.fetch(:x, nil) == click.fetch(:x) && previous.fetch(:y, nil) == click.fetch(:y)

        if now - previous.fetch(:at, 0.0) <= DOUBLE_CLICK_INTERVAL_SECONDS
          @last_worker_click = nil
          true
        else
          false
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def mouse_wheel_up?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "wheel_up"
      end

      def mouse_wheel_down?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "wheel_down"
      end

      def scroll_focused_pane(direction, steps:, state:)
        pane = @focused_pane.to_s
        delta = scroll_delta_for(pane, direction, steps)
        max_offset = scroll_max_for(pane, state)
        @scroll_offsets[pane] = (@scroll_offsets[pane].to_i + delta).clamp(0, max_offset)
      end

      def scroll_delta_for(pane, direction, step)
        if pane == "agent_tree"
          direction == :down ? step : -step
        else
          direction == :up ? step : -step
        end
      end

      def scroll_key_step(page: false)
        page ? PAGE_SCROLL_STEP : 1
      end

      def mouse_wheel_count(key)
        [key.fetch("count", 1).to_i, 1].max
      end

      def scroll_max_for(pane, state)
        layout.scroll_limits(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT
        ).fetch(pane.to_s, 0).to_i
      end

      def clamp_scroll_offsets!(state)
        layout.scroll_limits(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT
        ).each do |pane, max_offset|
          @scroll_offsets[pane] = @scroll_offsets[pane].to_i.clamp(0, max_offset.to_i)
        end
      end

      def handle_agent_tree_navigation_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if keybinding?("cancel_navigation", key)
          exit_agent_tree_navigation("Agent tree navigation cancelled.")
          return [+"", 0, 0]
        end

        if keybinding?("agent_select_previous", key)
          move_agent_tree_selection(state, -1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("agent_select_next", key)
          move_agent_tree_selection(state, 1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if agent_session_open_key?(key)
          open_selected_agent(state)
          return [+"", 0, 0]
        end

        if ENTER_KEYS.include?(key)
          open_selected_agent_pr(state)
          return [+"", 0, 0]
        end

        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def agent_session_open_key?(key)
        key == "a"
      end

      def handle_local_navigation_command(input_buffer, state)
        text = input_buffer.to_s.strip
        return handle_local_jump_command(text, state) if jump_command?(text)
        return handle_local_keybind_command if keybind_command?(text)
        return handle_local_quit_command if quit_command?(text)

        false
      end

      def handle_local_jump_command(text, state)
        agent_id = text.split(/\s+/, 2)[1].to_s.strip
        if agent_id.empty?
          enter_agent_tree_navigation(state)
        else
          open_agent_by_id(state, agent_id)
        end
        true
      end

      def handle_local_keybind_command
        append_jump_response(keybinding_help_text)
        true
      end

      def handle_local_quit_command
        @quit_requested = true
        true
      end

      def keybinding_help_text
        <<~TEXT.strip
          Keybindings (from [tui.keybindings], with defaults for omitted actions):
          Global: /quit or #{keys_for("quit")} quits; #{keys_for("clear_or_quit")} clears input or quits when input is empty; #{keys_for("cancel_navigation")} cancels jump mode.
          Focus: click a dashboard section to focus it; clicking an issue or worker in the agent tree selects it, and double-clicking opens its PR when available. #{keys_for("focus_next")} moves focus forward; #{keys_for("focus_previous")} moves focus backward; #{keys_for("scroll_up")}/#{keys_for("scroll_down")}, #{keys_for("scroll_page_up")}/#{keys_for("scroll_page_down")}, and mouse wheel scroll the focused pane.
          Chat: #{keys_for("submit")} sends or applies the selected slash completion; #{keys_for("newline")} inserts a newline; #{keys_for("cursor_left")}/#{keys_for("cursor_right")}/#{keys_for("cursor_up")}/#{keys_for("cursor_down")} move the cursor; #{keys_for("cursor_home")} and #{keys_for("cursor_end")} jump within a line; #{keys_for("cursor_word_left")} and #{keys_for("cursor_word_right")} move by word; #{keys_for("delete_backward")}/#{keys_for("delete_forward")} edit characters; #{keys_for("delete_word_backward")} and #{keys_for("delete_word_forward")} edit words.
          Slash commands: type / for suggestions; #{keys_for("complete_suggestion")} completes; #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} changes the selected suggestion.
          Agent tree/logs: focus either pane and press #{keys_for("submit")} to enter jump mode.
          Jump mode: /jump starts agent navigation; #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} selects an agent; Enter opens the selected agent PR when one is available; a opens the selected agent session; #{keys_for("cancel_navigation")} cancels.
        TEXT
      end

      def keys_for(action)
        names = keybindings.names_for(action)
        names.empty? ? "(unbound)" : names.join("/")
      end

      def jump_command?(text)
        text == "/jump" || text.start_with?("/jump ")
      end

      def keybind_command?(text)
        text == "/keybind"
      end

      def quit_command?(text)
        text == "/quit"
      end

      def local_navigation_command_without_id?(input_buffer)
        input_buffer.to_s.strip == "/jump"
      end

      def enter_agent_tree_navigation(state)
        ids = agent_tree_selectable_agent_ids(state)
        if ids.empty?
          append_jump_response("No agents are available to jump into yet.")
          return
        end

        @agent_tree_navigation_active = true
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
        append_jump_response("Agent tree navigation active. #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} selects issues and agents (kernel events are skipped), Enter opens PRs, a opens agent sessions, #{keys_for("cancel_navigation")} cancels.")
      end

      def exit_agent_tree_navigation(message = nil)
        @agent_tree_navigation_active = false
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = nil
        append_jump_response(message) if message
      end

      def move_agent_tree_selection(state, delta)
        ids = agent_tree_selectable_agent_ids(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") if ids.empty?

        current_index = ids.index(@selected_agent_id) || 0
        @selected_agent_id = ids[(current_index + delta) % ids.length]
      end

      def open_selected_agent(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        open_agent_by_id(state, selected_id)
        exit_agent_tree_navigation
      end

      def open_selected_agent_pr(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        open_pr_by_agent_id(state, selected_id)
        exit_agent_tree_navigation
      end

      def open_agent_by_id(state, agent_id)
        agent = Array(state["agents"]).find { |candidate| candidate["id"].to_s == agent_id.to_s }
        unless agent
          append_jump_response("Agent #{agent_id} does not exist or is not a session-backed record.")
          return
        end

        result = session_opener.open(agent)
        append_jump_response(result.fetch("message", "Could not open agent #{agent_id}."))
      end

      def open_pr_by_agent_id(state, agent_id, silent_fail: false)
        record = pr_record_for_id(state, agent_id)
        unless record
          append_jump_response("Agent tree item #{agent_id} does not exist.") unless silent_fail
          return false
        end

        pr_url = AgentTreeNavigation.agent_pr_url(record)
        unless pr_url
          append_jump_response("Agent tree item #{agent_id} does not have an attached pull request yet.") unless silent_fail
          return false
        end

        result = pull_request_opener.open(pr_url)
        opened = result.fetch("status", nil) == "opened" || !%w[failed rejected].include?(result.fetch("status", nil).to_s)
        append_jump_response(result.fetch("message", "Could not open pull request for #{agent_id}.")) if opened || !silent_fail
        opened
      rescue StandardError => e
        append_jump_response("Could not open pull request for #{agent_id}: #{e.message}") unless silent_fail
        false
      end

      def pr_record_for_id(state, id)
        issue = Array(state["issues"]).find { |candidate| candidate["id"].to_s == id.to_s }
        return issue if issue

        agent = Array(state["agents"]).find { |candidate| candidate["id"].to_s == id.to_s }
        return nil unless agent
        return agent unless agent.fetch("type", nil) == "worker"

        worker_issue = Array(state["issues"]).find { |candidate| candidate["id"].to_s == agent.fetch("issue_id", nil).to_s }
        AgentTreeNavigation.agent_pr_url(worker_issue || {}) ? worker_issue : agent
      end

      def append_jump_response(message)
        append_message("meringue", message)
      end

      def normalized_selected_agent_id(state)
        ids = agent_tree_selectable_agent_ids(state)
        return nil if ids.empty?

        @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
      end

      def agent_tree_selectable_agent_ids(state)
        AgentTreeNavigation.selectable_agent_ids(state)
      end

      def paste_key?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "paste"
      end

      def paste_text(key)
        key.fetch("text", "").to_s.tr("\r", "\n")
      end

      def plain_text_paste_key?(key)
        key.is_a?(String) && key.length > 1 && !key.start_with?("\e")
      end

      def insert_text(input_buffer, input_cursor, text)
        normalized = text.to_s.gsub("\r\n", "\n").tr("\r", "\n")
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        chars.insert(cursor, *normalized.chars)
        [chars.join, cursor + normalized.length]
      end

      def delete_backward(input_buffer, input_cursor)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        return [input_buffer, cursor] if cursor.zero?

        chars.delete_at(cursor - 1)
        [chars.join, cursor - 1]
      end

      def delete_forward(input_buffer, input_cursor)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        return [input_buffer, cursor] if cursor >= chars.length

        chars.delete_at(cursor)
        [chars.join, cursor]
      end

      def delete_backward_word(input_buffer, input_cursor)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        start_index = previous_word_boundary(chars, cursor)
        return [input_buffer, cursor] if start_index == cursor

        chars.slice!(start_index...cursor)
        [chars.join, start_index]
      end

      def delete_forward_word(input_buffer, input_cursor)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        finish_index = next_word_boundary(chars, cursor)
        return [input_buffer, cursor] if finish_index == cursor

        chars.slice!(cursor...finish_index)
        [chars.join, cursor]
      end

      def cursor_after_navigation(key, input_buffer, input_cursor)
        cursor = clamp_cursor(input_buffer, input_cursor)
        chars = input_buffer.chars

        return [cursor - 1, 0].max if keybinding?("cursor_left", key)
        return [cursor + 1, chars.length].min if keybinding?("cursor_right", key)
        return cursor_up(chars, cursor) if keybinding?("cursor_up", key)
        return cursor_down(chars, cursor) if keybinding?("cursor_down", key)
        return current_line_start(chars, cursor) if keybinding?("cursor_home", key)
        return current_line_end(chars, cursor) if keybinding?("cursor_end", key)
        return previous_word_boundary(chars, cursor) if keybinding?("cursor_word_left", key)
        return next_word_start(chars, cursor) if keybinding?("cursor_word_right", key)

        cursor
      end

      def clamp_cursor(input_buffer, input_cursor)
        input_cursor.to_i.clamp(0, input_buffer.chars.length)
      end

      def current_line_start(chars, cursor)
        index = cursor
        index -= 1 while index.positive? && chars[index - 1] != "\n"
        index
      end

      def current_line_end(chars, cursor)
        index = cursor
        index += 1 while index < chars.length && chars[index] != "\n"
        index
      end

      def cursor_up(chars, cursor)
        line_start = current_line_start(chars, cursor)
        return cursor if line_start.zero?

        column = cursor - line_start
        previous_line_end = line_start - 1
        previous_line_start = current_line_start(chars, previous_line_end)
        previous_line_start + [column, previous_line_end - previous_line_start].min
      end

      def cursor_down(chars, cursor)
        line_end = current_line_end(chars, cursor)
        return cursor if line_end >= chars.length

        column = cursor - current_line_start(chars, cursor)
        next_line_start = line_end + 1
        next_line_end = current_line_end(chars, next_line_start)
        next_line_start + [column, next_line_end - next_line_start].min
      end

      def previous_word_boundary(chars, cursor)
        index = cursor
        index -= 1 while index.positive? && word_separator?(chars[index - 1])
        index -= 1 while index.positive? && !word_separator?(chars[index - 1])
        index
      end

      def next_word_boundary(chars, cursor)
        index = cursor
        index += 1 while index < chars.length && word_separator?(chars[index])
        index += 1 while index < chars.length && !word_separator?(chars[index])
        index
      end

      def next_word_start(chars, cursor)
        index = cursor
        index += 1 while index < chars.length && !word_separator?(chars[index])
        index += 1 while index < chars.length && word_separator?(chars[index])
        index
      end

      def word_separator?(character)
        character.to_s.match?(/\s/)
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
        key.is_a?(String) && key.bytes.all? { |byte| byte >= 32 && byte != 127 }
      end

      def submit_prompt(input_buffer, on_submit)
        text = input_buffer.to_s.strip
        return if text.empty?

        slash_command = text.start_with?("/")
        assistant_message_id = nil
        unless slash_command
          assistant_message_id = append_message(
            "meringue",
            "",
            status: "queued",
            visible: false
          )
        end
        increment_pending_count

        Thread.new do
          begin
            update_message(
              assistant_message_id,
              text: "",
              status: "head working",
              visible: false
            ) if assistant_message_id
            result = if on_submit
                       on_submit.call(text) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     else
                       unavailable_prompt_handler_result
                     end
            if slash_command
              apply_slash_command_results(result.fetch("command_results", []) || []) if result.fetch("event", nil) == "slash_command_applied"
            else
              final_text = result_logged_to_kernel?(result) ? "" : log_text_for(result)
              update_message(assistant_message_id, text: final_text, status: nil, visible: !final_text.to_s.strip.empty?)
            end
          rescue StandardError => e
            if assistant_message_id
              update_message(assistant_message_id, text: "Head loop failed: #{e.class}: #{e.message}", status: "errored", visible: true)
            end
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
          remember_log_event(head_completed_key(event.fetch("head_id", nil)))
          update_message_status(message_id, "applying commands")
        when "head_result_applied"
          update_message_status(message_id, worker_wait_status(event))
        when "slash_command_applied"
          apply_slash_command_results(event.fetch("command_results", []) || [])
        when "worker_wait_started"
          update_message_status(message_id, "workers running")
        when "worker_completed"
          update_message_status(message_id, nil)
        when "worker_wait_failed"
          append_user_facing_line(message_id, worker_wait_failed_line(event), status: "worker wait failed")
        end
      end

      def result_logged_to_kernel?(result)
        kernel_results = [
          result.fetch("spawn_head_result", nil),
          result.fetch("apply_head_result", nil),
          *Array(result.fetch("worker_wait_results", [])).map { |worker| worker.fetch("completion_result", nil) }
        ].compact
        kernel_results.any? { |kernel_result| Array(kernel_result.fetch("log_entry_ids", [])).any? }
      end

      def log_text_for(result)
        if result.fetch("event", nil) == "slash_command_applied"
          apply_theme_command_results(result.fetch("command_results", []) || [])
          return ""
        end

        spawn_result = result.fetch("spawn_head_result", {}) || {}
        apply_result = result.fetch("apply_head_result", {}) || {}
        head = spawn_result.fetch("result", {}) || {}
        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", {}) || {}

        lines = []
        if head_result.any?
          lines.concat(head_result_user_lines(head_result, question_ids: question_ids_from_apply_result(apply_result)))
        else
          lines.concat(failure_result_lines(spawn_result, apply_result, fallback: result.fetch("summary", nil)))
        end

        lines.concat(worker_summary_lines(result.fetch("worker_wait_results", []) || []))
        lines.concat(failure_result_lines(spawn_result, apply_result)) if lines.empty?
        lines.reject { |line| line.to_s.empty? }.join("\n")
      end

      def apply_slash_command_results(command_results)
        clear_logs! if clear_state_accepted?(command_results)
        apply_theme_command_results(command_results)
      end

      def clear_state_accepted?(command_results)
        Array(command_results).any? do |result|
          result.fetch("command_type", nil) == "ClearState" && result.fetch("status", nil) == "accepted"
        end
      end

      def clear_logs!
        @chat_mutex.synchronize do
          @messages = []
          @next_message_id = 0
          @log_event_keys = {}
          persist_logs_unlocked
        end
      end

      def apply_theme_command_results(command_results)
        Array(command_results).each do |result|
          next unless result.fetch("command_type", nil) == "SetTheme"
          next unless result.fetch("status", nil) == "accepted"

          theme = (result.fetch("result", {}) || {})["theme"]
          Style.configure!(theme) if theme
        end
      rescue StandardError
        nil
      end

      def append_head_result_applied_summary(message_id, event)
        lines = head_result_user_lines(
          event.fetch("head_result", {}) || {},
          question_ids: question_ids_from_apply_result(event.fetch("apply_result", {}) || {})
        )
        status = worker_wait_status(event)
        if lines.empty?
          update_message_status(message_id, status)
        else
          append_user_facing_line(message_id, lines.join("\n"), status: status)
        end
      end

      def head_result_user_lines(head_result, question_ids: [])
        commands = Array(head_result.fetch("commands", []))
        questions = Array(head_result.fetch("questions", []))
        question_lines = question_user_lines(questions, question_ids: question_ids)
        return question_lines unless question_lines.empty?

        summary = head_result.fetch("summary", "").to_s.strip
        return [summary] if commands.empty? && !summary.empty?

        []
      end

      def question_user_lines(questions, question_ids: [])
        questions.each_with_index.filter_map do |question, index|
          question_text = question.fetch("question", "").to_s.strip
          next if question_text.empty?

          question_id = question_ids[index].to_s
          label = question_id.empty? ? "Question" : "Question #{question_id}"
          context = question.fetch("context", "").to_s.strip
          ["#{label}: #{question_text}", context.empty? ? nil : "Context: #{context}"].compact.join("\n")
        end
      end

      def worker_summary_lines(worker_wait_results)
        worker_wait_results.filter_map do |worker|
          next unless worker.fetch("status", nil) == "settled"

          worker_completed_line(worker)
        end
      end

      def worker_completed_line(event)
        user_facing_worker_lines(
          agent_id: event.fetch("agent_id", "worker"),
          pr_urls: Array(event.fetch("pr_urls", [])).compact,
          last_assistant_text: event.fetch("last_assistant_text", nil)
        ).join("\n")
      end

      def worker_wait_failed_line(event)
        agent_id = event.fetch("agent_id", "worker")
        error = event.fetch("error", {}) || {}
        message = error.fetch("message", "worker result could not be read").to_s.strip
        "Could not read #{agent_id}'s result#{message.empty? ? "." : ": #{message}"}"
      end

      def user_facing_worker_lines(agent_id:, pr_urls:, last_assistant_text:)
        lines = []
        unless pr_urls.empty?
          label = pr_urls.length == 1 ? "Pull request" : "Pull requests"
          lines << "#{label} from #{agent_id}:"
          lines.concat(pr_urls.map { |url| "PR: #{url}" })
        end

        output = user_facing_agent_output(last_assistant_text, pr_urls: pr_urls)
        unless output.empty?
          lines << ["#{agent_id} output:", output].join("\n")
        end

        lines
      end

      def user_facing_agent_output(text, pr_urls: [])
        output = text.to_s.strip
        return "" if output.empty?

        Array(pr_urls).compact.each do |url|
          output = output.gsub(url.to_s, "").strip
        end
        output.gsub(/\n{3,}/, "\n\n").strip
      end

      def append_user_facing_line(message_id, line, status: nil)
        return if line.to_s.strip.empty?

        append_to_message(message_id, line, status: status, visible: true)
      end

      def question_ids_from_apply_result(apply_result)
        result = apply_result.fetch("result", {}) || {}
        Array(result.fetch("question_ids", []))
      end

      def failure_result_lines(spawn_result, apply_result, fallback: nil)
        failed_result = [apply_result, spawn_result].compact.find do |result|
          status = result.fetch("status", nil)
          !status.to_s.empty? && status != "accepted"
        end
        message = failed_result&.fetch("message", nil).to_s.strip
        errors = Array(failed_result&.fetch("errors", [])).map(&:to_s).reject(&:empty?)
        lines = []
        lines << message unless message.empty?
        lines.concat(errors.map { |error| "- #{error}" })
        lines << fallback.to_s.strip if lines.empty? && !fallback.to_s.strip.empty?
        lines
      end

      def worker_wait_status(event)
        command_results = (event.fetch("apply_result", {}).fetch("result", {}) || {}).fetch("command_results", [])
        has_workers = command_results.any? do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" && command_result.fetch("status", nil) == "accepted"
        end

        has_workers ? "workers running" : nil
      end

      def compose_state(state_provider, input_buffer, slash_suggestion_index = 0, input_cursor = nil)
        state = state_provider.call || State::Models.empty_state
        sync_state_logs!(state)
        if @agent_tree_navigation_active
          ids = agent_tree_selectable_agent_ids(state)
          @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
          @agent_tree_navigation_active = false if ids.empty?
        end
        composed_state = state.merge(
          "_chat" => chat_snapshot(input_buffer, slash_suggestion_index, input_cursor),
          "_agent_tree_navigation" => agent_tree_navigation_snapshot,
          "_scroll" => scroll_snapshot
        )
        clamp_scroll_offsets!(composed_state)
        composed_state.merge("_scroll" => scroll_snapshot)
      end

      def agent_tree_navigation_snapshot
        {
          "active" => @agent_tree_navigation_active,
          "mode" => @agent_tree_navigation_active ? @agent_tree_navigation_mode.to_s : nil,
          "selected_agent_id" => @agent_tree_navigation_active ? @selected_agent_id : nil
        }
      end

      def scroll_snapshot
        {
          "active_pane" => @focused_pane,
          "offsets" => @scroll_offsets.to_h
        }
      end

      def sync_state_logs!(_state)
        # Durable kernel logs are the visible event stream. Conversation messages
        # are kept only for transient in-flight status and legacy persisted rows,
        # so do not synthesize second copies of completed head/worker events here.
      end

      def sync_polled_head_updates!(state)
        Array(state.fetch("agents", [])).each do |agent|
          next unless agent.fetch("type", nil) == "head"

          metadata = agent.fetch("harness_metadata", {}) || {}
          head_result = metadata["head_result"]
          next unless metadata["head_result_applied_at"] && head_result.is_a?(Hash)

          append_message_once(
            head_completed_key(agent.fetch("id", nil)),
            "meringue",
            head_result_user_lines(head_result).join("\n")
          )
        end
      end

      def sync_worker_completion_updates!(state)
        Array(state.fetch("agents", [])).each do |agent|
          issue = Array(state.fetch("issues", [])).find { |candidate| candidate.fetch("id", nil) == agent.fetch("issue_id", nil) }
          next unless existing_worker_completion_event?(agent, issue)

          metadata = agent.fetch("harness_metadata", {}) || {}
          next unless log_sync_after_start?(metadata["completed_at"])

          append_message_once(
            worker_completed_key(agent.fetch("id", nil)),
            "agent",
            worker_completed_text_from_agent(agent, issue),
            source_id: agent.fetch("id", nil)
          )
        end
      end

      def existing_head_completion_event?(agent)
        return false unless agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata["head_result_applied_at"] && metadata["head_result"].is_a?(Hash)
      end

      def existing_worker_completion_event?(agent, issue = nil)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "completed"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata["completed_at"] || Array(metadata["reported_pr_urls"]).any? || AgentTreeNavigation.agent_pr_url(issue || {})
      end

      def log_sync_after_start?(timestamp)
        return false if timestamp.to_s.empty?

        Time.iso8601(timestamp.to_s) >= @started_at
      rescue ArgumentError, TypeError
        false
      end

      def worker_completed_text_from_agent(agent, issue = nil)
        metadata = agent.fetch("harness_metadata", {}) || {}
        user_facing_worker_lines(
          agent_id: agent.fetch("id", "worker"),
          pr_urls: verified_agent_pr_urls(metadata, issue),
          last_assistant_text: metadata["last_assistant_text"]
        ).join("\n")
      end

      def verified_agent_pr_urls(metadata, issue = nil)
        delivery_pull_requests = [
          issue&.fetch("delivery_pull_request", nil),
          *Array(issue&.fetch("delivery_pull_requests", nil)),
          metadata["delivery_pull_request"],
          *Array(metadata["delivery_pull_requests"])
        ].compact
        delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }.uniq
      end

      def head_completed_key(head_id)
        "head_completed:#{head_id}"
      end

      def worker_completed_key(agent_id)
        "worker_completed:#{agent_id}"
      end

      def remember_log_event(key)
        return if key.to_s.empty?

        @chat_mutex.synchronize { @log_event_keys[key] = true }
      end

      def forget_log_event(key)
        return if key.to_s.empty?

        @chat_mutex.synchronize { @log_event_keys.delete(key) }
      end

      def append_message_once(key, role, text, status: nil, source_id: nil)
        return if key.to_s.empty? || text.to_s.empty?

        @chat_mutex.synchronize do
          return if @log_event_keys[key]

          @log_event_keys[key] = true
          append_message_unlocked(role, text, status: status, source_id: source_id)
        end
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

      def chat_snapshot(input_buffer, slash_suggestion_index = 0, input_cursor = nil)
        @chat_mutex.synchronize do
          {
            "messages" => @messages.map(&:dup),
            "input_buffer" => input_buffer,
            "input_cursor" => clamp_cursor(input_buffer, input_cursor || input_buffer.chars.length),
            "slash_suggestion_index" => slash_suggestion_index,
            "pending_count" => @pending_count
          }
        end
      end

      def append_message(role, text, status: nil, visible: nil, source_id: nil)
        @chat_mutex.synchronize { append_message_unlocked(role, text, status: status, visible: visible, source_id: source_id) }
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
        persist_logs_unlocked
        @next_message_id
      end

      def update_message(id, text:, status: nil, visible: nil)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          message["text"] = text
          if status
            message["status"] = status
          else
            message.delete("status")
          end
          apply_message_visibility(message, visible)
          persist_logs_unlocked
        end
      end

      def append_to_message(id, line, status: nil, visible: nil)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          existing = message.fetch("text", "").to_s
          addition = line.to_s
          unless duplicate_trailing_line?(existing, addition)
            message["text"] = [existing, addition].reject { |part| part.to_s.empty? }.join("\n")
          end
          apply_message_status(message, status)
          apply_message_visibility(message, visible)
          persist_logs_unlocked
        end
      end

      def update_message_status(id, status)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          apply_message_status(message, status)
          persist_logs_unlocked
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

      def apply_message_visibility(message, visible)
        return if visible.nil?

        if visible
          message.delete("visible")
        else
          message["visible"] = false
        end
      end

      def persist_logs_unlocked
        return unless log_store&.respond_to?(:save_log_buffer)

        log_store.save_log_buffer(
          messages: @messages,
          next_message_id: @next_message_id
        )
      rescue StandardError
        nil
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
