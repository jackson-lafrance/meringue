# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    class App
      DEFAULT_WIDTH = 100
      DEFAULT_HEIGHT = 32
      REFRESH_INTERVAL = 0.2
      MOUSE_SCROLL_STEP = 3
      PAGE_SCROLL_STEP = 8
      CTRL_C = "\u0003"
      CTRL_D = "\u0004"
      CTRL_W = "\u0017"
      BACKSPACE_KEYS = ["\u007f", "\b"].freeze
      DELETE_KEYS = ["\e[3~"].freeze
      ENTER_KEYS = ["\r", "\n"].freeze
      SHIFT_ENTER_KEYS = ["\e[13;2u", "\e[27;2;13~", "\e[13;2~"].freeze
      TAB_KEYS = ["\t"].freeze
      LEFT_KEYS = ["\e[D", "\eOD"].freeze
      RIGHT_KEYS = ["\e[C", "\eOC"].freeze
      UP_KEYS = ["\e[A", "\eOA"].freeze
      DOWN_KEYS = ["\e[B", "\eOB"].freeze
      HOME_KEYS = ["\e[H", "\e[1~", "\eOH", "\u0001"].freeze
      END_KEYS = ["\e[F", "\e[4~", "\eOF", "\u0005"].freeze
      WORD_LEFT_KEYS = ["\eb", "\eB", "\e[1;3D", "\e[1;5D", "\e[1;9D"].freeze
      WORD_RIGHT_KEYS = ["\ef", "\eF", "\e[1;3C", "\e[1;5C", "\e[1;9C"].freeze
      WORD_BACKSPACE_KEYS = ["\e\u007f", "\e\b", CTRL_W].freeze
      WORD_DELETE_KEYS = ["\ed", "\eD", "\e[3;3~", "\e[3;5~"].freeze
      PAGE_UP_KEYS = ["\e[5~"].freeze
      PAGE_DOWN_KEYS = ["\e[6~"].freeze
      SHIFT_TAB_KEYS = ["\e[Z"].freeze
      CTRL_TAB_KEYS = ["\e[27;5;9~", "\e[9;5u"].freeze
      FOCUS_FORWARD_KEYS = CTRL_TAB_KEYS.freeze
      FOCUS_BACK_KEYS = SHIFT_TAB_KEYS.freeze
      FOCUS_ORDER = %w[chat agent_tree conversation logs].freeze
      AGENT_TREE_FORWARD_KEYS = (DOWN_KEYS + RIGHT_KEYS).freeze
      AGENT_TREE_BACK_KEYS = (UP_KEYS + LEFT_KEYS).freeze

      def initialize(layout: Layout.new, input: $stdin, out: $stdout, terminal: nil, session_opener: nil, pull_request_opener: nil, conversation_store: nil)
        @layout = layout
        @out = out
        @terminal = terminal || Terminal.new(input: input, output: out)
        @session_opener = session_opener || Harness::TerminalSessionOpener.new
        @pull_request_opener = pull_request_opener || PullRequestOpener.new
        @conversation_store = conversation_store
        @messages = []
        @next_message_id = 0
        @pending_count = 0
        @agent_tree_navigation_active = false
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = nil
        @focused_pane = "chat"
        @last_render_width = DEFAULT_WIDTH
        @last_render_height = DEFAULT_HEIGHT
        @scroll_offsets = Hash.new(0)
        @conversation_event_keys = {}
        @started_at = Time.iso8601(Time.now.utc.iso8601)
        @chat_mutex = Mutex.new
      end

      def render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        layout.render(state, width: width, height: height, color: color)
      end

      def restore_conversation!(state)
        conversation = state.fetch("conversation", {}) || {}
        messages = Array(conversation.fetch("messages", []))
        @chat_mutex.synchronize do
          @messages = messages.map { |message| normalize_persisted_message(message) }.compact
          @next_message_id = [conversation.fetch("next_message_id", 0).to_i, @messages.map { |message| message.fetch("id", 0).to_i }.max.to_i].max
        end
      end

      def remember_existing_conversation_events!(state)
        Array(state.fetch("agents", [])).each do |agent|
          if existing_head_completion_event?(agent)
            remember_conversation_event(head_completed_key(agent.fetch("id", nil)))
          elsif existing_worker_completion_event?(agent)
            remember_conversation_event(worker_completed_key(agent.fetch("id", nil)))
          end
        end
      end

      def run(state: nil, state_provider: nil, on_submit: nil)
        state_provider ||= -> { state || State::Models.empty_state }
        return render_once(compose_state(state_provider, "")) unless terminal.interactive?

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
            end
          end
        end

        0
      rescue Interrupt
        0
      end

      private

      attr_reader :layout, :out, :terminal, :session_opener, :pull_request_opener, :conversation_store

      def render_once(state)
        out.puts render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        0
      end

      def quit_key?(key, input_buffer)
        return false unless key
        return true if key == CTRL_D

        key == CTRL_C && input_buffer.empty? && !@agent_tree_navigation_active
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

        if ENTER_KEYS.include?(key)
          return [+"", 0, 0] if local_navigation_command_without_id?(input_buffer) && handle_local_navigation_command(input_buffer, state)

          completion = safe_slash_completion(input_buffer, slash_suggestion_index, state)
          return [completion, completion.chars.length, 0] if completion

          return [+"", 0, 0] if handle_local_navigation_command(input_buffer, state)

          submit_prompt(input_buffer, on_submit)
          return [+"", 0, 0]
        end

        if SHIFT_ENTER_KEYS.include?(key)
          return insert_text(input_buffer, input_cursor, "\n") + [0]
        end

        if key == CTRL_C
          return [+"", 0, 0]
        end

        if BACKSPACE_KEYS.include?(key)
          return delete_backward(input_buffer, input_cursor) + [0]
        end

        if DELETE_KEYS.include?(key)
          return delete_forward(input_buffer, input_cursor) + [0]
        end

        if WORD_BACKSPACE_KEYS.include?(key)
          return delete_backward_word(input_buffer, input_cursor) + [0]
        end

        if WORD_DELETE_KEYS.include?(key)
          return delete_forward_word(input_buffer, input_cursor) + [0]
        end

        new_cursor = cursor_after_navigation(key, input_buffer, input_cursor)
        return [input_buffer, new_cursor, slash_suggestion_index] if new_cursor != input_cursor

        return [input_buffer, input_cursor, slash_suggestion_index] unless printable_key?(key)

        @focused_pane = "chat"
        insert_text(input_buffer, input_cursor, key) + [0]
      end

      def slash_suggestion_key?(key)
        TAB_KEYS.include?(key)
      end

      def slash_suggestion_navigation_key?(key)
        TAB_KEYS.include?(key) || UP_KEYS.include?(key) || DOWN_KEYS.include?(key)
      end

      def handle_legacy_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
        handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
      end

      def handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
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


      def handle_focus_key(key, input_buffer, input_cursor, slash_suggestion_index)
        return nil if slash_suggestions_active?(input_buffer) && slash_suggestion_key?(key)
        return nil unless FOCUS_FORWARD_KEYS.include?(key) || FOCUS_BACK_KEYS.include?(key) || (!slash_suggestions_active?(input_buffer) && TAB_KEYS.include?(key))

        cycle_focus(FOCUS_BACK_KEYS.include?(key) ? -1 : 1)
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def cycle_focus(delta = 1)
        current_index = FOCUS_ORDER.index(@focused_pane) || 0
        @focused_pane = FOCUS_ORDER[(current_index + delta) % FOCUS_ORDER.length]
      end

      def handle_focused_action_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless @focused_pane == "agent_tree" && ENTER_KEYS.include?(key)

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

        if UP_KEYS.include?(key) || PAGE_UP_KEYS.include?(key)
          scroll_focused_pane(:up, steps: scroll_key_step(page: PAGE_UP_KEYS.include?(key)), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if DOWN_KEYS.include?(key) || PAGE_DOWN_KEYS.include?(key)
          scroll_focused_pane(:down, steps: scroll_key_step(page: PAGE_DOWN_KEYS.include?(key)), state: state)
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
        exit_agent_tree_navigation if @agent_tree_navigation_active && pane != "agent_tree"
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
        if key == "\e"
          exit_agent_tree_navigation("Agent tree navigation cancelled.")
          return [+"", 0, 0]
        end

        if AGENT_TREE_BACK_KEYS.include?(key)
          move_agent_tree_selection(state, -1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if AGENT_TREE_FORWARD_KEYS.include?(key)
          move_agent_tree_selection(state, 1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if pr_open_key?(key)
          open_selected_agent_pr_silently(state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if ENTER_KEYS.include?(key)
          open_selected_navigation_item(state)
          return [+"", 0, 0]
        end

        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def pr_open_key?(key)
        key == "p"
      end

      def handle_local_navigation_command(input_buffer, state)
        text = input_buffer.to_s.strip
        return handle_local_jump_command(text, state) if jump_command?(text)
        return handle_local_jumpr_command(text, state) if jumpr_command?(text)
        return handle_local_keybind_command if keybind_command?(text)

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

      def handle_local_jumpr_command(text, state)
        agent_id = text.split(/\s+/, 2)[1].to_s.strip
        if agent_id.empty?
          enter_pr_agent_navigation(state)
        else
          open_pr_by_agent_id(state, agent_id)
        end
        true
      end

      def handle_local_keybind_command
        append_jump_response(keybinding_help_text)
        true
      end

      def keybinding_help_text
        <<~TEXT.strip
          Keybindings:
          Global: Ctrl-D quits; Ctrl-C clears input or quits when input is empty; Esc cancels jump/PR navigation mode.
          Focus: click a dashboard section to focus it; Tab/Ctrl-Tab moves focus forward; Shift-Tab moves focus backward; arrows, PageUp/PageDown, and mouse wheel scroll the focused pane.
          Chat: Enter sends or applies the selected slash completion; Shift-Enter inserts a newline; arrows move the cursor; Home/Ctrl-A and End/Ctrl-E jump within a line; Alt/Ctrl-Left and Alt/Ctrl-Right move by word; Backspace/Delete edit characters; Alt/Ctrl-Backspace, Ctrl-W, and Alt/Ctrl-Delete edit words.
          Slash commands: type / for suggestions; Tab completes; Up/Down changes the selected suggestion.
          Agent tree: focus the agent tree and press Enter to enter jump mode.
          Jump mode: /jump or agent-tree Enter starts agent navigation; ↑/↓ or ←/→ selects an agent; Enter opens the selected agent session; p opens the selected agent PR when one is available; Esc cancels.
          PR navigation: /jumpr starts PR navigation; ↑/↓ or ←/→ selects an agent with a PR; Enter or p opens the selected PR; Esc cancels.
        TEXT
      end

      def jump_command?(text)
        text == "/jump" || text.start_with?("/jump ")
      end

      def jumpr_command?(text)
        text == "/jumpr" || text.start_with?("/jumpr ")
      end

      def keybind_command?(text)
        text == "/keybind"
      end

      def local_navigation_command_without_id?(input_buffer)
        text = input_buffer.to_s.strip
        text == "/jump" || text == "/jumpr"
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
        append_jump_response("Agent tree navigation active. ↑/↓ or ←/→ select agents, Enter jumps, p opens PRs, Esc cancels.")
      end

      def enter_pr_agent_navigation(state)
        ids = pr_agent_selectable_ids(state)
        if ids.empty?
          append_jump_response("No agents with attached pull requests are available yet.")
          return
        end

        @agent_tree_navigation_active = true
        @agent_tree_navigation_mode = :pull_request
        @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
        append_jump_response("Pull request navigation active. ↑/↓ or ←/→ select agents with PRs, Enter opens the PR, p also opens the PR, Esc cancels.")
      end

      def exit_agent_tree_navigation(message = nil)
        @agent_tree_navigation_active = false
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = nil
        append_jump_response(message) if message
      end

      def move_agent_tree_selection(state, delta)
        if @agent_tree_navigation_mode == :pull_request
          return move_pr_agent_selection(state, delta)
        end

        ids = agent_tree_selectable_agent_ids(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") if ids.empty?

        current_index = ids.index(@selected_agent_id) || 0
        @selected_agent_id = ids[(current_index + delta) % ids.length]
      end

      def move_pr_agent_selection(state, delta)
        ids = pr_agent_selectable_ids(state)
        return exit_agent_tree_navigation("No agents with attached pull requests are available yet.") if ids.empty?

        current_index = ids.index(@selected_agent_id) || 0
        @selected_agent_id = ids[(current_index + delta) % ids.length]
      end

      def open_selected_navigation_item(state)
        if @agent_tree_navigation_mode == :pull_request
          return open_selected_pr_agent(state)
        end

        open_selected_agent(state)
      end

      def open_selected_agent(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        open_agent_by_id(state, selected_id)
        exit_agent_tree_navigation
      end

      def open_selected_pr_agent(state)
        selected_id = normalized_selected_pr_agent_id(state)
        return exit_agent_tree_navigation("No agents with attached pull requests are available yet.") unless selected_id

        open_pr_by_agent_id(state, selected_id)
        exit_agent_tree_navigation
      end

      def open_selected_agent_pr_silently(state)
        selected_id = if @agent_tree_navigation_mode == :pull_request
                        normalized_selected_pr_agent_id(state)
                      else
                        normalized_selected_agent_id(state)
                      end
        return false unless selected_id

        opened = open_pr_by_agent_id(state, selected_id, silent_fail: true)
        exit_agent_tree_navigation if opened
        opened
      end

      def open_agent_by_id(state, agent_id)
        agent = Array(state["agents"]).find { |candidate| candidate["id"].to_s == agent_id.to_s }
        unless agent
          append_jump_response("Agent #{agent_id} does not exist.")
          return
        end

        result = session_opener.open(agent)
        append_jump_response(result.fetch("message", "Could not open agent #{agent_id}."))
      end

      def open_pr_by_agent_id(state, agent_id, silent_fail: false)
        agent = Array(state["agents"]).find { |candidate| candidate["id"].to_s == agent_id.to_s }
        unless agent
          append_jump_response("Agent #{agent_id} does not exist.") unless silent_fail
          return false
        end

        pr_url = AgentTreeNavigation.agent_pr_url(agent)
        unless pr_url
          append_jump_response("Agent #{agent_id} does not have an attached pull request yet.") unless silent_fail
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

      def append_jump_response(message)
        append_message("meringue", message)
      end

      def normalized_selected_agent_id(state)
        ids = agent_tree_selectable_agent_ids(state)
        return nil if ids.empty?

        @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
      end

      def normalized_selected_pr_agent_id(state)
        ids = pr_agent_selectable_ids(state)
        return nil if ids.empty?

        @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
      end

      def agent_tree_selectable_agent_ids(state)
        AgentTreeNavigation.selectable_agent_ids(state)
      end

      def pr_agent_selectable_ids(state)
        AgentTreeNavigation.selectable_pr_agent_ids(state)
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

        return [cursor - 1, 0].max if LEFT_KEYS.include?(key)
        return [cursor + 1, chars.length].min if RIGHT_KEYS.include?(key)
        return cursor_up(chars, cursor) if UP_KEYS.include?(key)
        return cursor_down(chars, cursor) if DOWN_KEYS.include?(key)
        return current_line_start(chars, cursor) if HOME_KEYS.include?(key)
        return current_line_end(chars, cursor) if END_KEYS.include?(key)
        return previous_word_boundary(chars, cursor) if WORD_LEFT_KEYS.include?(key)
        return next_word_start(chars, cursor) if WORD_RIGHT_KEYS.include?(key)

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
        append_message("you", text)
        assistant_message_id = append_message(
          "meringue",
          "",
          status: "queued",
          visible: false
        )
        increment_pending_count

        Thread.new do
          begin
            update_message(
              assistant_message_id,
              text: "",
              status: slash_command ? "working" : "head working",
              visible: false
            )
            result = if on_submit
                       on_submit.call(text) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     else
                       unavailable_prompt_handler_result
                     end
            final_text = conversation_text_for(result)
            update_message(assistant_message_id, text: final_text, status: nil, visible: !final_text.to_s.strip.empty?)
          rescue StandardError => e
            update_message(assistant_message_id, text: "Head loop failed: #{e.class}: #{e.message}", status: "errored", visible: true)
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
          remember_conversation_event(head_completed_key(event.fetch("head_id", nil)))
          update_message_status(message_id, "applying commands")
        when "head_result_applied"
          append_head_result_applied_summary(message_id, event)
        when "slash_command_applied"
          apply_theme_command_results(event.fetch("command_results", []) || [])
          append_user_facing_line(message_id, slash_command_text(event.fetch("command_results", []) || []), status: nil)
        when "worker_wait_started"
          remember_conversation_event(worker_completed_key(event.fetch("agent_id", nil)))
          update_message_status(message_id, "workers running")
        when "worker_completed"
          remember_conversation_event(worker_completed_key(event.fetch("agent_id", nil)))
          append_user_facing_line(message_id, worker_completed_line(event), status: "workers running")
        when "worker_wait_failed"
          forget_conversation_event(worker_completed_key(event.fetch("agent_id", nil)))
          append_user_facing_line(message_id, worker_wait_failed_line(event), status: "worker wait failed")
        end
      end

      def conversation_text_for(result)
        if result.fetch("event", nil) == "slash_command_applied"
          apply_theme_command_results(result.fetch("command_results", []) || [])
          lines = [slash_command_text(result.fetch("command_results", []) || [])]
          lines.concat(worker_summary_lines(result.fetch("worker_wait_results", []) || []))
          return lines.reject { |line| line.to_s.empty? }.join("\n")
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
        when "SetTheme"
          theme = result.is_a?(Hash) ? result["theme"] : nil
          config_path = result.is_a?(Hash) ? result["config_path"] : nil
          ["  theme: #{theme}", config_path ? "  config: #{config_path}" : nil].compact
        when "Help"
          Array(result).map { |item| "  #{item.fetch("usage", "")} — #{item.fetch("description", "")}" }
        when "ListQuestions"
          questions = Array(result)
          return ["  No questions."] if questions.empty?

          questions.map { |question| "  #{question.fetch("id", "?")} [#{question.fetch("status", "?")}] #{question.fetch("question", "")}" }
        when "Prune"
          prune_result = result || {}
          [
            "  removed issues: #{Array(prune_result["removed_issue_ids"]).length}",
            "  removed agents: #{Array(prune_result["removed_agent_ids"]).length}"
          ]
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

      def command_summary_lines(apply_result)
        command_results = (apply_result.fetch("result", {}) || {}).fetch("command_results", [])
        spawned_workers = command_results.select do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" && command_result.fetch("status", nil) == "accepted"
        end
        return [] if spawned_workers.empty?

        ["Spawned workers: #{spawned_workers.map { |worker| worker.fetch("target_id", nil) }.compact.join(", ")}"]
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
        sync_state_conversation!(state)
        if @agent_tree_navigation_active
          ids = if @agent_tree_navigation_mode == :pull_request
                  pr_agent_selectable_ids(state)
                else
                  agent_tree_selectable_agent_ids(state)
                end
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

      def sync_state_conversation!(state)
        sync_polled_head_updates!(state)
        sync_worker_completion_updates!(state)
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
          next unless existing_worker_completion_event?(agent)

          metadata = agent.fetch("harness_metadata", {}) || {}
          next unless conversation_sync_after_start?(metadata["completed_at"])

          append_message_once(
            worker_completed_key(agent.fetch("id", nil)),
            "meringue",
            worker_completed_text_from_agent(agent)
          )
        end
      end

      def existing_head_completion_event?(agent)
        return false unless agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata["head_result_applied_at"] && metadata["head_result"].is_a?(Hash)
      end

      def existing_worker_completion_event?(agent)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "completed"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata["completed_at"] || Array(metadata["reported_pr_urls"]).any?
      end

      def conversation_sync_after_start?(timestamp)
        return false if timestamp.to_s.empty?

        Time.iso8601(timestamp.to_s) >= @started_at
      rescue ArgumentError, TypeError
        false
      end

      def worker_completed_text_from_agent(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        user_facing_worker_lines(
          agent_id: agent.fetch("id", "worker"),
          pr_urls: verified_agent_pr_urls(metadata),
          last_assistant_text: metadata["last_assistant_text"]
        ).join("\n")
      end

      def verified_agent_pr_urls(metadata)
        delivery_pull_requests = [
          metadata["delivery_pull_request"],
          *Array(metadata["delivery_pull_requests"])
        ].compact
        delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }
      end

      def head_completed_key(head_id)
        "head_completed:#{head_id}"
      end

      def worker_completed_key(agent_id)
        "worker_completed:#{agent_id}"
      end

      def remember_conversation_event(key)
        return if key.to_s.empty?

        @chat_mutex.synchronize { @conversation_event_keys[key] = true }
      end

      def forget_conversation_event(key)
        return if key.to_s.empty?

        @chat_mutex.synchronize { @conversation_event_keys.delete(key) }
      end

      def append_message_once(key, role, text, status: nil)
        return if key.to_s.empty? || text.to_s.empty?

        @chat_mutex.synchronize do
          return if @conversation_event_keys[key]

          @conversation_event_keys[key] = true
          append_message_unlocked(role, text, status: status)
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
          "visible" => message.fetch("visible", nil)
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

      def append_message(role, text, status: nil, visible: nil)
        @chat_mutex.synchronize { append_message_unlocked(role, text, status: status, visible: visible) }
      end

      def append_message_unlocked(role, text, status: nil, visible: nil)
        @next_message_id += 1
        @messages << {
          "id" => @next_message_id,
          "role" => role,
          "text" => text,
          "status" => status,
          "visible" => visible
        }.compact
        persist_conversation_unlocked
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
          persist_conversation_unlocked
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
          persist_conversation_unlocked
        end
      end

      def update_message_status(id, status)
        @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          return unless message

          apply_message_status(message, status)
          persist_conversation_unlocked
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

      def persist_conversation_unlocked
        return unless conversation_store&.respond_to?(:save_conversation)

        conversation_store.save_conversation(
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
