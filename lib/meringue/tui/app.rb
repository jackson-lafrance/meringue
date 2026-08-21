# frozen_string_literal: true

require "base64"
require "json"
require "shellwords"
require "time"
require_relative "keybindings"

module Meringue
  module TUI
    class App
      DEFAULT_WIDTH = 100
      DEFAULT_HEIGHT = 32
      REFRESH_INTERVAL = 0.2
      TERMINAL_REFRESH_INTERVAL = 0.025
      # Scroll steps defer the workspace state write; this is how often a
      # deferred write is actually flushed to the state file.
      WORKSPACE_PERSIST_INTERVAL = 1.0
      MOUSE_SCROLL_STEP = 3
      DRAG_AUTOSCROLL_STEP = 1
      PAGE_SCROLL_STEP = 8
      CHAT_INPUT_HISTORY_LIMIT = 100
      DOUBLE_CLICK_INTERVAL_SECONDS = 0.5
      # A double-click has to land on the same row, but a one column wobble
      # between the two presses is normal on a trackpad and still counts.
      DOUBLE_CLICK_COLUMN_TOLERANCE = 1
      # The leader highlight remains visible long enough to show that the next
      # key is a destination, without leaving the workspace in a pending mode.
      WORKSPACE_LEADER_TIMEOUT_SECONDS = 1.5
      # How long a copy/cut confirmation stays in the bottom hint line.
      SELECTION_STATUS_SECONDS = 3.0
      # A short single-line copy is echoed back in the hint line, which reads
      # better than "copied 1 line" after double-clicking one word.
      COPY_ECHO_LIMIT = 32
      # Selection-extending keys reuse the composer's cursor movement math.
      SELECTION_MOVEMENTS = {
        "select_left" => :left,
        "select_right" => :right,
        "select_up" => :up,
        "select_down" => :down,
        "select_home" => :home,
        "select_end" => :end,
        "select_word_left" => :word_left,
        "select_word_right" => :word_right
      }.freeze
      # Keyboard logs selection reuses the same configurable movement actions and
      # adds page granularity, which only makes sense for a scrolling pane.
      LOGS_SELECTION_MOVEMENTS = SELECTION_MOVEMENTS.merge(
        "select_page_up" => :page_up,
        "select_page_down" => :page_down
      ).freeze
      # Unmodified movement inside logs selection mode moves the caret and
      # collapses the selection, exactly like a text editor caret.
      LOGS_CURSOR_MOVEMENTS = {
        "cursor_left" => :left,
        "cursor_right" => :right,
        "cursor_up" => :up,
        "cursor_down" => :down,
        "cursor_home" => :home,
        "cursor_end" => :end,
        "cursor_word_left" => :word_left,
        "cursor_word_right" => :word_right,
        "scroll_page_up" => :page_up,
        "scroll_page_down" => :page_down
      }.freeze
      # Vertical caret movement keeps the column the user last chose.
      LOGS_STICKY_COLUMN_MOVEMENTS = %i[up down page_up page_down].freeze
      CTRL_C = "\u0003"
      # Keyboard-disambiguation modes used for Shift+Enter can encode Ctrl-C as
      # CSI-u or xterm modifyOtherKeys instead of the raw ETX byte.
      CTRL_C_KEYS = [CTRL_C, "\e[99;5u", "\e[67;5u", "\e[27;5;99~", "\e[27;5;67~"].freeze
      CTRL_D = "\u0004"
      CTRL_S = "\u0013"
      CTRL_S_KEYS = [CTRL_S, "\e[115;5u", "\e[83;5u", "\e[27;5;115~", "\e[27;5;83~"].freeze
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
      # No slash suggestion is selected until the user navigates the list, so an untouched
      # completion popup never steals Enter from the typed prompt.
      NO_SLASH_SELECTION = -1
      WORKSPACE_COMMAND_ACTIONS = %w[
        workspace_switch_view
        workspace_cycle_filter
        workspace_open_agent_session
        workspace_open_editor
        workspace_open_pull_request
        workspace_close
      ].freeze
      # One list of transcript filters, shared with persistence and commands.
      WORKSPACE_FILTERS = State::Models::AGENT_WORKSPACE_FILTERS

      # workspace_controller is a harness-neutral UI adapter. Integrations may
      # implement open_workspace, agent_snapshot, open_terminal,
      # terminal_snapshot, handle_terminal_key, and open_editor.
      # agent_session_service may open the generic live worker-session view.
      # Returning from this TUI workspace closes only that read handle and never
      # calls an abort/kill worker lifecycle operation.
      def initialize(layout: Layout.new, input: $stdin, out: $stdout, terminal: nil, session_opener: nil, pull_request_opener: nil, workspace_controller: nil, agent_session_service: nil, log_store: nil, conversation_store: nil, keybindings: Keybindings.default, config: nil, onboarding_enabled: false, harness_configured_check: nil)
        @layout = layout
        @out = out
        @terminal = terminal || Terminal.new(input: input, output: out)
        @session_opener = session_opener || Harness::TerminalSessionOpener.new
        @pull_request_opener = pull_request_opener || PullRequestOpener.new
        @workspace_controller = workspace_controller
        @agent_session_service = agent_session_service
        @log_store = log_store || conversation_store
        @keybindings = keybindings || Keybindings.default
        @config = config || Config.new({}, path: Config::DEFAULT_PATH)
        @messages = []
        @next_message_id = 0
        @pending_count = 0
        # Sent dashboard prompts are browsed at the top/bottom edge of the
        # composer. The draft is restored after moving forward past the newest
        # history entry, matching ordinary shell/editor input behavior.
        @chat_input_history = []
        @chat_history_index = nil
        @chat_history_draft = nil
        @agent_tree_navigation_active = false
        @quit_requested = false
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = nil
        # Sticky AgentTree selection that scopes the logs pane. It is separate
        # from the jump-mode cursor because projects are selectable here, and it
        # deliberately survives focus changes.
        @log_scope_id = nil
        # Open-PR picker: only meaningful for unscoped chat, where there is no one
        # PR to open. It is transient UI, so it is never persisted.
        @delivery_pr_picker_active = false
        @delivery_pr_picker_index = 0
        # Shared choice picker: models/thinking/themes/harnesses use the same
        # transient popup state as the model picker, never persist UI state, and
        # write nothing themselves; selections submit normal slash commands.
        @model_picker_active = false
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = "head"
        @model_picker_kind = "model"
        # Full-screen schema-backed Settings. The draft is purely in memory until
        # one SaveConfiguration command succeeds.
        @settings_active = false
        @settings_draft = nil
        @settings_category_index = 0
        @settings_row_index = 0
        @settings_expanded_advanced = {}
        @settings_editor = nil
        @settings_keybinding_capture = nil
        @settings_discard_confirm = false
        @settings_saving = false
        @settings_mode = "settings"
        @settings_setup_auto = false
        @settings_setup_outcome = nil
        # Status-bar composition is a separate in-memory draft. Preview changes
        # never touch the config until the single SaveConfiguration transaction
        # succeeds, so Esc and failed saves are deterministic.
        @status_bar_composer_active = false
        @status_bar_composer_draft = nil
        @status_bar_composer_saving = false
        @status_bar_composer_drag = nil
        # First-run setup is a curated mode of the same transactional Settings
        # draft and full-screen pane. It is disabled for `meringue demo`, where no
        # kernel exists to save the draft or completion marker.
        @onboarding_enabled = onboarding_enabled ? true : false
        # Truthful only when at least one role harness is configured. The CLI
        # supplies a registry-backed check so the app can open setup and gate
        # chat when no backend is chosen yet; tests and demo default to "ready"
        # so existing behavior is unchanged.
        @harness_configured_check = harness_configured_check || -> { true }
        @workspace_draft = ""
        @workspace_agent_scroll_offset = 0
        @workspace_terminal_scroll_offset = 0
        @workspace_persistence_error = nil
        # Collapsed pastes, one registry per composer surface. The buffers hold a
        # short marker; the bodies live here until the message is submitted.
        @chat_pastes = PasteRegistry.new
        @workspace_pastes = PasteRegistry.new
        @focused_pane = "chat"
        @last_worker_click = nil
        @agent_workspace_active = false
        @agent_workspace_agent_id = nil
        @agent_workspace_session = nil
        @agent_workspace_interactive = false
        @agent_workspace_open_pending = false
        @agent_workspace_open_generation = 0
        @agent_workspace_open_result = nil
        @agent_workspace_close_results = []
        @agent_workspace_return_pane = "chat"
        @agent_workspace_view = "agent"
        @agent_workspace_filter = "all"
        @agent_workspace_notice = nil
        @agent_workspace_error = nil
        @agent_workspace_pending_count = 0
        @agent_workspace_terminal_size = nil
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @force_full_redraw = false
        @agent_workspace_messages = Hash.new { |messages, agent_id| messages[agent_id] = [] }
        @agent_workspace_events = Hash.new { |events, agent_id| events[agent_id] = [] }
        @agent_workspace_events_revision = Hash.new(0)
        @agent_workspace_events_cache = {}
        @workspace_persist_dirty = false
        @workspace_persisted_at = 0.0
        @last_render_width = DEFAULT_WIDTH
        @last_render_height = DEFAULT_HEIGHT
        @scroll_offsets = Hash.new(0)
        @revealed_agent_tree_item_id = nil
        @selection_pane = nil
        @logs_selection_anchor = nil
        @logs_selection_focus = nil
        @chat_selection_anchor = nil
        @chat_selection = nil
        @logs_cursor_active = false
        @logs_cursor_column = 0
        @selection_dragging = false
        @logs_drag_autoscroll_direction = nil
        @logs_drag_pointer = nil
        # Mouse selection granularity: "character" for a plain drag, "word"
        # after a double-click, and "paragraph" after a logs triple-click. The
        # matching anchor keeps a continued drag on the same granularity.
        @selection_granularity = "character"
        @selection_anchor_word = nil
        @selection_anchor_paragraph = nil
        @last_text_click = nil
        @last_open_pull_requests_summary_click = nil
        @selection_status = nil
        @selection_status_at = nil
        @log_event_keys = {}
        @started_at = Time.iso8601(Time.now.utc.iso8601)
        @chat_mutex = Mutex.new
        @log_persist_mutex = Mutex.new
        @log_persist_condition = ConditionVariable.new
        @next_log_persist_sequence = 0
        @completed_log_persist_sequence = 0
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

      def restore_agent_workspace!(state)
        workspace = State::Models.agent_workspace_state(state)
        @agent_workspace_agent_id = workspace["selected_agent_id"]
        @agent_workspace_view = workspace.fetch("view", "agent")
        @agent_workspace_filter = workspace.fetch("filter", "all")
        # A persisted draft can still carry markers whose bodies died with the
        # previous process. They can never expand again, so they are dropped
        # rather than sent to a worker as literal "[paste #1 +3000 lines]" text.
        @workspace_draft = PasteRegistry.strip_markers(workspace.fetch("draft", ""))
        @workspace_agent_scroll_offset = workspace.fetch("agent_scroll_offset", 0).to_i
        @workspace_terminal_scroll_offset = workspace.fetch("terminal_scroll_offset", 0).to_i
        workspace
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
        maybe_open_onboarding(state_provider)
        input_buffer = +""
        input_cursor = 0
        slash_suggestion_index = NO_SLASH_SELECTION
        reset_base_state_cache
        terminal.with_screen do
          terminal.raw do
            last_frame = nil

            loop do
              width, height = terminal.dimensions
              @last_render_width = width
              @last_render_height = height
              now = monotonic_time
              # The orchestration snapshot is read-only presentation input. Keep it
              # independent from the composer and other transient state so a burst
              # of typing does not parse the whole Store snapshot per character.
              # Refreshing on the dashboard cadence still observes this process's
              # saves and atomic writes from other Store instances promptly.
              base_state = read_only_base_state(state_provider, now: now)
              current_state = compose_state(-> { base_state }, input_buffer, slash_suggestion_index, input_cursor)
              frame = render(current_state, width: width, height: height, color: color_output?)
              if @force_full_redraw
                terminal.invalidate_frame! if terminal.respond_to?(:invalidate_frame!)
                last_frame = nil
                @force_full_redraw = false
              end
              if frame != last_frame
                terminal.write_frame(frame)
                last_frame = frame
              end

              flush_deferred_agent_workspace_persistence
              key = terminal.read_key(timeout: frame_refresh_interval(current_state))
              break if quit_key?(key, input_buffer)

              input_buffer, input_cursor, slash_suggestion_index = handle_key_safely(
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
      ensure
        shutdown_workspace_resources
      end

      private

      attr_reader :layout, :out, :terminal, :session_opener, :pull_request_opener, :workspace_controller, :agent_session_service, :log_store, :keybindings, :config

      def handle_key_safely(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        handle_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
      rescue StandardError => e
        reset_failed_input_gesture
        append_jump_response("Could not handle #{input_event_name(key)}: #{e.class}: #{e.message}")
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def input_event_name(key)
        mouse_event?(key) ? "mouse input" : "input"
      end

      def reset_failed_input_gesture
        @selection_dragging = false
        @logs_drag_autoscroll_direction = nil
        @logs_drag_pointer = nil
        @logs_worker_click_candidate = nil
        @last_worker_click = nil
        @last_text_click = nil
        @last_open_pull_requests_summary_click = nil
      end

      def shutdown_workspace_resources
        # Quitting with Settings/setup open discards the in-memory draft and
        # restores any theme preview. No setup marker is written on process exit.
        close_settings(discard: true) if @settings_active
        close_status_bar_composer if @status_bar_composer_active
        persist_agent_workspace if @agent_workspace_active
        if @agent_workspace_active
          close_agent_workspace(async_interactive: false)
        else
          close_agent_workspace_session
        end
        if workspace_controller&.respond_to?(:shutdown)
          workspace_controller.shutdown
        elsif workspace_controller&.respond_to?(:close)
          workspace_controller.close
        end
      rescue StandardError
        nil
      end

      def render_once(state)
        out.puts render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        0
      end

      # Honor the NO_COLOR convention. Icons, explicit agent ids, statuses,
      # and the gutter marker keep log lines separable without any color.
      def color_output?
        ENV.fetch("NO_COLOR", "").to_s.empty?
      end

      def quit_key?(key, input_buffer)
        return false unless key
        return false if @agent_workspace_active
        return true if keybinding?("quit", key)
        # An active selection or logs caret makes Ctrl-C a copy action, never a quit.
        return false if selection_active? || @logs_cursor_active

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
        unless key
          continue_logs_drag_autoscroll(state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if @agent_workspace_active && !embedded_agent_workspace?
          return handle_agent_workspace_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end

        @chat_pastes.sync!(input_buffer)

        # Settings owns the complete screen and keeps Esc/Ctrl-S as hard recovery
        # keys regardless of configured dashboard bindings.
        if @settings_active
          return handle_settings_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end

        if @status_bar_composer_active
          return handle_status_bar_composer_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end

        if @model_picker_active
          picker_result = handle_model_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
          return picker_result if picker_result
        end

        if @delivery_pr_picker_active
          picker_result = handle_delivery_pr_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
          return picker_result if picker_result
        end

        embedded_result = handle_embedded_agent_workspace_key(
          key,
          input_buffer,
          input_cursor,
          slash_suggestion_index,
          state,
          on_submit
        )
        return embedded_result if embedded_result

        if paste_key?(key)
          reset_chat_history_navigation
          buffer, cursor = replace_chat_selection(input_buffer, input_cursor)
          return insert_pasted_text(buffer, cursor, paste_text(key)) + [NO_SLASH_SELECTION]
        end

        mouse_result = handle_mouse_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit)
        return mouse_result if mouse_result

        selection_command_result = handle_selection_command_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if selection_command_result
          reset_chat_history_navigation if selection_command_result.first != input_buffer
          return selection_command_result
        end

        if plain_text_paste_key?(key)
          reset_chat_history_navigation
          buffer, cursor = replace_chat_selection(input_buffer, input_cursor)
          return insert_pasted_text(buffer, cursor, key) + [NO_SLASH_SELECTION]
        end

        if legacy_slash_navigation && slash_suggestion_navigation_key?(key) && slash_suggestions_active?(input_buffer)
          buffer, index = handle_legacy_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
          reset_chat_history_navigation if buffer != input_buffer
          return [buffer, buffer.chars.length, index]
        end

        if keybinding?("open_delivery_pr", key)
          open_workspace_delivery_pr(state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if @agent_tree_navigation_active
          return handle_agent_tree_navigation_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        end

        if keybinding?("cancel_navigation", key) && (selection_active? || @logs_cursor_active)
          clear_selection
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        # Esc also clears a sticky AgentTree selection, so a filtered logs pane is
        # never a dead end even when jump mode is no longer active.
        if keybinding?("cancel_navigation", key) && log_scope_active?
          clear_log_scope
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        logs_selection_result = handle_logs_selection_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return logs_selection_result if logs_selection_result

        selection_movement_result = handle_selection_movement_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return selection_movement_result if selection_movement_result

        if slash_suggestion_navigation_key?(key) && slash_suggestions_active?(input_buffer)
          buffer, index = handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
          reset_chat_history_navigation if buffer != input_buffer
          return [buffer, buffer.chars.length, index]
        end

        focus_result = handle_focus_key(key, input_buffer, input_cursor, slash_suggestion_index)
        return focus_result if focus_result

        scroll_result = handle_focused_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return scroll_result if scroll_result

        focused_action_result = handle_focused_action_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return focused_action_result if focused_action_result

        if keybinding?("newline", key)
          reset_chat_history_navigation
          return insert_text(input_buffer, input_cursor, "\n") + [NO_SLASH_SELECTION]
        end

        if keybinding?("submit", key)
          clear_selection
          if local_navigation_command_without_id?(input_buffer) && handle_local_navigation_command(input_buffer, state)
            reset_chat_history_navigation
            return [+"", 0, NO_SLASH_SELECTION]
          end

          completion = safe_slash_completion(input_buffer, slash_suggestion_index, state)
          if completion
            reset_chat_history_navigation
            return [completion, completion.chars.length, NO_SLASH_SELECTION]
          end

          if handle_local_navigation_command(input_buffer, state)
            reset_chat_history_navigation
            return [+"", 0, NO_SLASH_SELECTION]
          end

          reset_chat_history_navigation
          submit_prompt(input_buffer, on_submit, state, remember_input: true)
          return [+"", 0, NO_SLASH_SELECTION]
        end

        if ctrl_c_key?(key)
          clear_selection
          reset_chat_history_navigation
          @chat_pastes.clear!
          return [+"", 0, NO_SLASH_SELECTION]
        end

        if selection_edit_key?(key) && chat_selection_range
          reset_chat_history_navigation
          return delete_chat_selection(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        if keybinding?("delete_backward", key)
          reset_chat_history_navigation
          return delete_backward(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        if keybinding?("delete_forward", key)
          reset_chat_history_navigation
          return delete_forward(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        if keybinding?("delete_word_backward", key)
          reset_chat_history_navigation
          return delete_backward_word(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        if keybinding?("delete_word_forward", key)
          reset_chat_history_navigation
          return delete_forward_word(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        new_cursor = cursor_after_navigation(key, input_buffer, input_cursor, state: state, visual_rows: true)
        if new_cursor != input_cursor
          clear_chat_selection
          return [input_buffer, new_cursor, slash_suggestion_index]
        end

        history_result = handle_chat_history_navigation(key, input_buffer, input_cursor, slash_suggestion_index)
        return history_result if history_result

        return [input_buffer, input_cursor, slash_suggestion_index] unless printable_key?(key)

        reset_chat_history_navigation
        @focused_pane = "chat"
        # Typing dismisses a logs highlight and replaces a composer selection,
        # matching normal text-input behavior.
        clear_selection unless chat_selection_range
        buffer, cursor = replace_chat_selection(input_buffer, input_cursor)
        insert_text(buffer, cursor, key) + [NO_SLASH_SELECTION]
      end

      def selection_edit_key?(key)
        keybinding?("delete_backward", key) || keybinding?("delete_forward", key)
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
        return [input_buffer, NO_SLASH_SELECTION] if records.empty?

        if keybinding?("suggestion_previous", key)
          return [input_buffer, slash_selection?(slash_suggestion_index) ? (slash_suggestion_index - 1) % records.length : records.length - 1]
        end
        if keybinding?("suggestion_next", key)
          return [input_buffer, slash_selection?(slash_suggestion_index) ? (slash_suggestion_index + 1) % records.length : 0]
        end

        selected_index = slash_selection?(slash_suggestion_index) ? slash_suggestion_index.clamp(0, records.length - 1) : 0
        [slash_completion_for(records.fetch(selected_index)), NO_SLASH_SELECTION]
      end

      def slash_selection?(slash_suggestion_index)
        slash_suggestion_index.to_i >= 0
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
        # The caret belongs to the logs pane, so moving focus away puts arrow keys
        # back to scrolling/composer duty while any highlight stays copyable.
        deactivate_logs_cursor_quietly unless @focused_pane == "logs"
      end

      def handle_focused_action_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless %w[agent_tree logs].include?(@focused_pane)

        if @focused_pane == "agent_tree" && keybinding?("rename_selected", key)
          return begin_selected_rename(state, input_buffer)
        end
        return nil unless keybinding?("submit", key)

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

        edge = scroll_edge_for(key)
        if edge
          scroll_focused_pane_to(edge, state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        nil
      end

      # Jump mode owns the arrow keys for selection, so paging and top/bottom
      # keys stay available for scrolling the pane the selection lives in.
      def handle_navigation_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless focused_scrollable?

        edge = scroll_edge_for(key)
        if edge
          scroll_focused_pane_to(edge, state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        page_up = keybinding?("scroll_page_up", key)
        return nil unless page_up || keybinding?("scroll_page_down", key)

        scroll_focused_pane(page_up ? :up : :down, steps: scroll_key_step(page: true), state: state)
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def scroll_edge_for(key)
        return :top if keybinding?("scroll_top", key)
        return :bottom if keybinding?("scroll_bottom", key)

        nil
      end

      def focused_scrollable?
        @focused_pane != "chat"
      end

      def handle_mouse_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit = nil)
        return nil unless mouse_event?(key)
        return handle_mouse_wheel_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_wheel?(key)
        return handle_mouse_right_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_right_button_press?(key)
        return handle_mouse_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit) if mouse_button_press?(key)
        return handle_mouse_drag_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_drag?(key)
        return handle_mouse_release_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_button_release?(key)

        nil
      end

      # Right-click is a direct AgentTree action rather than a context menu: an
      # issue row opens its associated delivery PR using the same opener as the
      # keyboard action. Worker rows deliberately do not duplicate that affordance;
      # their direct action is the focused workspace on double-click.
      def handle_mouse_right_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        pane = pane_at_mouse_position(key, state)
        return nil unless pane == "agent_tree"

        item_id = agent_tree_item_at_mouse_position(key, state)
        record = agent_tree_record(state, item_id)
        return [input_buffer, input_cursor, slash_suggestion_index] unless record
        return [input_buffer, input_cursor, slash_suggestion_index] unless issue_tree_record?(record) || record["type"] == "head"

        open_pr_by_agent_id(state, item_id)
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def handle_mouse_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit = nil)
        if layout.open_pull_requests_summary_hit?(
          state,
          width: render_width,
          height: render_height,
          x: mouse_x(key),
          y: mouse_y(key)
        )
          # Crossing between the summary and another mouse surface must not join
          # two unrelated presses into that surface's double-click gesture.
          @last_worker_click = nil
          @last_text_click = nil
          open_delivery_pr_picker(state) if open_pull_requests_summary_double_click?(key)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end
        @last_open_pull_requests_summary_click = nil

        if embedded_agent_workspace?
          action = layout.agent_workspace_control_at(
            state,
            width: render_width,
            height: render_height,
            x: mouse_x(key),
            y: mouse_y(key)
          )
          if action
            cancel_workspace_leader!
            run_workspace_command(action, state)
            return [input_buffer, input_cursor, slash_suggestion_index]
          end
        end

        pane = pane_at_mouse_position(key, state)
        return [input_buffer, input_cursor, slash_suggestion_index] unless pane

        @focused_pane = pane
        case pane
        when "agent_tree"
          clear_selection
          # The AgentTree keeps its own double-click tracker, so a text click
          # before and after a tree click never pair up into a word selection.
          @last_text_click = nil
          item_id = agent_tree_item_at_mouse_position(key, state)
          # The focused Agent session owns the logs pane, but the AgentTree must
          # remain a way out of it. A click on another agent closes the current
          # session before applying the ordinary tree selection/double-click action.
          if embedded_agent_workspace? && item_id && item_id.to_s != @agent_workspace_agent_id.to_s
            close_agent_workspace(preserve_terminal: true)
          end
          opened = handle_agent_tree_item_click(item_id, key, state, on_submit)
          if opened
            return [input_buffer, input_cursor, NO_SLASH_SELECTION] if embedded_agent_workspace?

            draft = @workspace_draft.to_s.dup
            return [draft, draft.chars.length, NO_SLASH_SELECTION]
          end

          [input_buffer, input_cursor, slash_suggestion_index]
        when "logs"
          @last_worker_click = nil
          if embedded_agent_workspace?
            @last_text_click = nil
            @logs_worker_click_candidate = nil
            clear_selection
            return [input_buffer, input_cursor, slash_suggestion_index]
          end

          click_count = text_click_count(pane, key)
          clicked_worker_id = logs_worker_at(key, state)
          if click_count > 1 && clicked_worker_id && @logs_worker_click_rollback&.fetch(:worker_id, nil) == clicked_worker_id
            @log_scope_id = @logs_worker_click_rollback.fetch(:previous_scope, nil)
            @selected_agent_id = @logs_worker_click_rollback.fetch(:previous_selected_agent, nil) if @agent_tree_navigation_active
            @logs_worker_click_rollback = nil
          end
          @logs_worker_click_candidate = click_count == 1 ? clicked_worker_id : nil
          begin_logs_selection(key, state, click_count: click_count)
          [input_buffer, input_cursor, slash_suggestion_index]
        else
          @last_worker_click = nil
          exit_agent_tree_navigation if @agent_tree_navigation_active
          cursor = begin_chat_selection(key, state, input_buffer, input_cursor, click_count: text_click_count(pane, key))
          [input_buffer, cursor, slash_suggestion_index]
        end
      end

      # Drag reports are clamped inside the pane the press started in, so a
      # selection can never grow into the agent tree or the composer. At a logs
      # edge, the latest pointer position remains armed between mouse reports so
      # refresh ticks keep scrolling and extending while the button stays held.
      def handle_mouse_drag_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return [input_buffer, input_cursor, slash_suggestion_index] unless @selection_dragging

        @logs_worker_click_candidate = nil if @selection_pane == "logs"
        case @selection_pane
        when "logs"
          @logs_drag_pointer = key
          @logs_drag_autoscroll_direction = layout.logs_drag_scroll_direction(
            state,
            width: render_width,
            height: render_height,
            y: mouse_y(key)
          )
          if @logs_drag_autoscroll_direction
            continue_logs_drag_autoscroll(state)
          else
            position = logs_text_position(key, state)
            extend_logs_selection(state, position) if position
          end
          [input_buffer, input_cursor, slash_suggestion_index]
        when "chat"
          cursor = composer_text_index(key, state)
          return [input_buffer, input_cursor, slash_suggestion_index] unless cursor

          [input_buffer, extend_chat_selection(input_buffer, cursor), slash_suggestion_index]
        else
          [input_buffer, input_cursor, slash_suggestion_index]
        end
      end

      def continue_logs_drag_autoscroll(state)
        return false unless @selection_dragging && @selection_pane == "logs"
        return false unless @logs_drag_autoscroll_direction && @logs_drag_pointer

        scroll_pane(
          "logs",
          @logs_drag_autoscroll_direction,
          steps: DRAG_AUTOSCROLL_STEP,
          state: state
        )
        scrolled_state = state.merge("_scroll" => scroll_snapshot)
        position = logs_text_position(@logs_drag_pointer, scrolled_state)
        extend_logs_selection(scrolled_state, position) if position
        true
      end

      # Releasing the button finishes a mouse selection. A finished logs
      # highlight goes straight to the system clipboard, so a double-click is one
      # gesture end to end; Ctrl-C still copies later, and the composer stays
      # copy-on-demand so selecting text to retype it cannot clobber a clipboard.
      def handle_mouse_release_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        completed_drag = @selection_dragging
        worker_id = @logs_worker_click_candidate
        @logs_worker_click_candidate = nil
        @selection_dragging = false
        @logs_drag_autoscroll_direction = nil
        @logs_drag_pointer = nil
        if selection_active?
          copy_selection(state, input_buffer) if completed_drag && @selection_pane == "logs"
        elsif worker_id && logs_worker_at(key, state) == worker_id
          clear_selection
          select_worker_from_logs(state, worker_id)
        else
          clear_selection
        end
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      # The wheel scrolls whatever scrollable pane the pointer is over, so the
      # AgentTree and the logs pane behave the same and neither needs focus or a
      # jump-mode exit first. Hovering something that cannot scroll falls back to
      # the focused pane, which is the older behavior.
      def handle_mouse_wheel_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if embedded_agent_workspace? && pane_at_mouse_position(key, state) == "logs"
          event = layout.agent_workspace_mouse_event(
            state,
            width: render_width,
            height: render_height,
            x: mouse_x(key),
            y: mouse_y(key),
            event: key
          )
          forward_agent_workspace_interactive_key(event, state) if event && @agent_workspace_view != "terminal"
          forward_agent_workspace_terminal_key(event, state) if event && @agent_workspace_view == "terminal"
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        # One limits lookup per wheel event keeps hover routing as cheap as the
        # previous focus-only path.
        limits = scroll_limits_for(state)
        pane = wheel_target_pane(key, state, limits)
        return nil unless pane

        scroll_pane(
          pane,
          mouse_wheel_up?(key) ? :up : :down,
          steps: MOUSE_SCROLL_STEP * mouse_wheel_count(key),
          state: state,
          max_offset: limits.fetch(pane, 0).to_i
        )
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def wheel_target_pane(key, state, limits)
        hovered = pane_at_mouse_position(key, state)
        return hovered if hovered && limits.fetch(hovered, 0).to_i.positive?

        focused_scrollable? ? @focused_pane.to_s : nil
      end

      def mouse_event?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse"
      end

      def mouse_button_press?(key)
        mouse_event?(key) &&
          key.fetch("kind", nil) == "button" && key.fetch("pressed", false) &&
          (key.fetch("button", 0).to_i & 3).zero?
      end

      def mouse_right_button_press?(key)
        mouse_event?(key) &&
          key.fetch("kind", nil) == "button" && key.fetch("pressed", false) &&
          (key.fetch("button", 0).to_i & 3) == 2
      end

      def mouse_drag?(key)
        mouse_event?(key) && key.fetch("kind", nil) == "motion"
      end

      def mouse_button_release?(key)
        mouse_event?(key) && key.fetch("kind", nil) == "button" && !key.fetch("pressed", false)
      end

      def pane_at_mouse_position(key, state)
        layout.pane_at(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def agent_tree_item_at_mouse_position(key, state)
        layout.agent_tree_item_at(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def render_width
        @last_render_width || DEFAULT_WIDTH
      end

      def render_height
        @last_render_height || DEFAULT_HEIGHT
      end

      def mouse_x(key)
        key.fetch("x", 1).to_i - 1
      end

      def mouse_y(key)
        key.fetch("y", 1).to_i - 1
      end

      def logs_text_position(key, state)
        layout.logs_text_position(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def logs_worker_at(key, state)
        layout.logs_worker_at(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def composer_text_index(key, state)
        layout.composer_text_index(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def begin_logs_selection(key, state, click_count: 1)
        position = logs_text_position(key, state)
        return clear_selection unless position

        @logs_drag_autoscroll_direction = nil
        @logs_drag_pointer = nil
        clear_chat_selection
        @selection_pane = "logs"
        @logs_cursor_active = false
        @selection_dragging = true
        clear_selection_status
        return true if triple_click?(click_count) && select_logs_paragraph(state, position)
        return true if double_click?(click_count) && select_logs_word(state, position)

        @selection_granularity = "character"
        @selection_anchor_word = nil
        @selection_anchor_paragraph = nil
        @logs_selection_anchor = position
        @logs_selection_focus = position
        @logs_cursor_column = position.fetch("column", 0).to_i
      end

      def begin_chat_selection(key, state, input_buffer, input_cursor, click_count: 1)
        index = composer_text_index(key, state)
        return input_cursor unless index

        clear_logs_selection
        @selection_dragging = true
        clear_selection_status
        word = double_click?(click_count) ? Selection.word_range(input_buffer, index) : nil
        if word
          @selection_granularity = "word"
          @selection_anchor_word = { "start" => word.begin, "end" => word.end }
          @selection_anchor_paragraph = nil
          update_chat_selection(word.begin, word.end)
          return word.end
        end

        @selection_granularity = "character"
        @selection_anchor_word = nil
        @selection_anchor_paragraph = nil
        update_chat_selection(index, index)
        index
      end

      def double_click?(click_count)
        click_count.to_i == 2
      end

      def triple_click?(click_count)
        click_count.to_i == 3
      end

      # Click counting is position- and time-bounded, so a slow next click, or a
      # click on another row, starts a fresh single-click selection. Logs count
      # through three for paragraph selection; the composer deliberately keeps
      # its existing single/double cycle.
      def text_click_count(pane, key)
        now = monotonic_time
        click = { pane: pane.to_s, x: mouse_x(key), y: mouse_y(key), at: now, count: 1 }
        previous = @last_text_click
        if previous && previous.fetch(:count, 1).to_i < text_click_limit(pane) && consecutive_text_click?(previous, click)
          click[:count] = previous.fetch(:count, 1).to_i + 1
        end
        @last_text_click = click
        click.fetch(:count)
      end

      def text_click_limit(pane)
        pane.to_s == "logs" ? 3 : 2
      end

      def consecutive_text_click?(previous, click)
        return false unless previous.fetch(:pane, nil) == click.fetch(:pane)
        return false unless previous.fetch(:y, nil) == click.fetch(:y)
        return false unless (previous.fetch(:x, 0) - click.fetch(:x)).abs <= DOUBLE_CLICK_COLUMN_TOLERANCE

        click.fetch(:at) - previous.fetch(:at, 0.0) <= DOUBLE_CLICK_INTERVAL_SECONDS
      end

      # Word selection uses the same wrapped content coordinates the drag
      # highlight uses, so it lands on the right text on soft-wrapped rows and on
      # scrolled-back content.
      def select_logs_word(state, position)
        line_index = position.fetch("line", 0).to_i
        word = logs_word_range(state, line_index, position.fetch("column", 0).to_i)
        return false unless word

        @selection_granularity = "word"
        @selection_anchor_word = { "line" => line_index, "start" => word.begin, "end" => word.end }
        @selection_anchor_paragraph = nil
        @logs_selection_anchor = Selection.point(line_index, word.begin)
        @logs_selection_focus = Selection.point(line_index, word.end)
        @logs_cursor_column = word.end
        true
      end

      # Triple-clicking selects the complete displayed paragraph under the
      # pointer, including all of its soft-wrapped rows but not an adjacent log
      # entry or paragraph. It uses the same content coordinates as every other
      # logs selection, so the highlight remains stable across rerenders.
      def select_logs_paragraph(state, position)
        lines = logs_selection_lines(state)
        paragraph = logs_paragraph_range(state, position.fetch("line", 0).to_i)
        return false unless paragraph

        start_line = paragraph.fetch("start_line").to_i
        end_line = paragraph.fetch("end_line").to_i
        return false unless start_line.between?(0, lines.length - 1) && end_line.between?(start_line, lines.length - 1)

        @selection_granularity = "paragraph"
        @selection_anchor_word = nil
        @selection_anchor_paragraph = paragraph
        @logs_selection_anchor = Selection.point(start_line, 0)
        @logs_selection_focus = Selection.point(end_line, lines.fetch(end_line).length)
        @logs_cursor_column = lines.fetch(end_line).length
        true
      end

      def logs_paragraph_range(state, line_index)
        return nil unless layout.respond_to?(:logs_text_paragraph_range)

        layout.logs_text_paragraph_range(
          state,
          width: render_width,
          height: render_height,
          line_index: line_index
        )
      end

      def logs_word_range(state, line_index, column)
        lines = logs_selection_lines(state)
        return nil unless line_index.between?(0, lines.length - 1)

        Selection.word_range(lines.fetch(line_index), column)
      end

      # A plain drag moves the focus point; double- and triple-click drags grow
      # the selection by whole words and whole displayed paragraphs, respectively.
      def extend_logs_selection(state, position)
        if @selection_granularity == "paragraph" && @selection_anchor_paragraph
          return extend_logs_paragraph_selection(state, position)
        end

        anchor_word = @selection_anchor_word
        unless @selection_granularity == "word" && anchor_word
          @logs_selection_focus = position
          return position
        end

        word = logs_word_range(state, position.fetch("line", 0).to_i, position.fetch("column", 0).to_i)
        word_start = Selection.point(position.fetch("line", 0).to_i, word ? word.begin : position.fetch("column", 0).to_i)
        word_end = Selection.point(position.fetch("line", 0).to_i, word ? word.end : position.fetch("column", 0).to_i)
        anchor_start = Selection.point(anchor_word.fetch("line", 0).to_i, anchor_word.fetch("start", 0).to_i)
        anchor_end = Selection.point(anchor_word.fetch("line", 0).to_i, anchor_word.fetch("end", 0).to_i)
        @logs_selection_anchor = [anchor_start, word_start].min_by { |point| selection_point_order(point) }
        @logs_selection_focus = [anchor_end, word_end].max_by { |point| selection_point_order(point) }
      end

      def extend_logs_paragraph_selection(state, position)
        lines = logs_selection_lines(state)
        target = logs_paragraph_range(state, position.fetch("line", 0).to_i)
        return position if lines.empty? || target.nil?

        first_line = [@selection_anchor_paragraph.fetch("start_line").to_i, target.fetch("start_line").to_i].min
        last_line = [@selection_anchor_paragraph.fetch("end_line").to_i, target.fetch("end_line").to_i].max
        @logs_selection_anchor = Selection.point(first_line, 0)
        @logs_selection_focus = Selection.point(last_line, lines.fetch(last_line).length)
      end

      def selection_point_order(point)
        [point.fetch("line", 0).to_i, point.fetch("column", 0).to_i]
      end

      def extend_chat_selection(input_buffer, cursor)
        anchor_word = @selection_anchor_word
        unless @selection_granularity == "word" && anchor_word
          update_chat_selection(@chat_selection_anchor || cursor, cursor)
          return cursor
        end

        word = Selection.word_range(input_buffer, cursor)
        start_index = [anchor_word.fetch("start", 0).to_i, word ? word.begin : cursor].min
        finish_index = [anchor_word.fetch("end", 0).to_i, word ? word.end : cursor].max
        update_chat_selection(start_index, finish_index)
        finish_index
      end

      def update_chat_selection(anchor, cursor)
        @selection_pane = "chat"
        @chat_selection_anchor = anchor.to_i
        start_index, finish_index = [anchor.to_i, cursor.to_i].minmax
        @chat_selection = finish_index > start_index ? { "start" => start_index, "end" => finish_index } : nil
      end

      def chat_selection_range
        @chat_selection
      end

      def logs_selection
        Selection.normalize("logs", @logs_selection_anchor, @logs_selection_focus)
      end

      def selection_active?
        case @selection_pane
        when "logs" then !Selection.empty?(logs_selection)
        when "chat" then !chat_selection_range.nil?
        else false
        end
      end

      def clear_selection
        clear_logs_selection
        clear_chat_selection
        @selection_pane = nil
        @selection_dragging = false
        @logs_drag_autoscroll_direction = nil
        @logs_drag_pointer = nil
        nil
      end

      def clear_logs_selection
        @logs_selection_anchor = nil
        @logs_selection_focus = nil
        @logs_cursor_active = false
        @logs_cursor_column = 0
        if @selection_pane == "logs"
          @logs_drag_autoscroll_direction = nil
          @logs_drag_pointer = nil
          reset_mouse_selection_granularity
          @selection_pane = nil
        end
        nil
      end

      def reset_mouse_selection_granularity
        @selection_granularity = "character"
        @selection_anchor_word = nil
        @selection_anchor_paragraph = nil
      end

      # Keyboard-driven logs selection.
      #
      # Selection mode is pane-scoped: it only reacts while the logs pane is
      # focused, it never touches the AgentTree or the composer, and it leaves
      # jump mode, slash suggestions, and typing in charge of their own keys.
      def handle_logs_selection_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless @focused_pane == "logs"

        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        if keybinding?("logs_selection_mode", key)
          toggle_logs_cursor(state)
          return unchanged
        end

        extend_movement = LOGS_SELECTION_MOVEMENTS.keys.find { |action| keybinding?(action, key) }
        if extend_movement
          move_logs_cursor(LOGS_SELECTION_MOVEMENTS.fetch(extend_movement), state, extend: true)
          return unchanged
        end

        return nil unless @logs_cursor_active

        movement = LOGS_CURSOR_MOVEMENTS.keys.find { |action| keybinding?(action, key) }
        return nil unless movement

        move_logs_cursor(LOGS_CURSOR_MOVEMENTS.fetch(movement), state, extend: false)
        unchanged
      end

      def toggle_logs_cursor(state)
        return deactivate_logs_cursor if @logs_cursor_active

        activate_logs_cursor(state)
      end

      def activate_logs_cursor(state)
        lines = logs_selection_lines(state)
        if lines.empty?
          set_selection_status("no log text to select")
          return false
        end

        clear_chat_selection
        @selection_pane = "logs"
        @logs_cursor_active = true
        @logs_selection_focus ||= default_logs_cursor(state, lines)
        @logs_selection_anchor ||= @logs_selection_focus
        @logs_cursor_column = @logs_selection_focus.fetch("column", 0).to_i
        reveal_logs_line(state, @logs_selection_focus.fetch("line", 0).to_i)
        set_selection_status("logs selection on")
        true
      end

      def deactivate_logs_cursor
        clear_logs_selection
        set_selection_status("logs selection off")
        false
      end

      def deactivate_logs_cursor_quietly
        return unless @logs_cursor_active

        @logs_cursor_active = false
        @logs_cursor_column = 0
      end

      # Caret and anchor are stored in logs content coordinates, so a selection
      # keeps covering the same text while the pane scrolls.
      def move_logs_cursor(movement, state, extend:)
        lines = logs_selection_lines(state)
        return false if lines.empty?
        return false unless @logs_cursor_active || activate_logs_cursor(state)

        current = @logs_selection_focus || default_logs_cursor(state, lines)
        line = current.fetch("line", 0).to_i.clamp(0, lines.length - 1)
        column = current.fetch("column", 0).to_i.clamp(0, lines.fetch(line).length)
        anchor = extend ? (@logs_selection_anchor || Selection.point(line, column)) : nil
        line, column = next_logs_cursor(movement, lines, line, column, logs_page_step(state))

        clear_chat_selection
        @selection_pane = "logs"
        @logs_selection_focus = Selection.point(line, column)
        @logs_selection_anchor = anchor || @logs_selection_focus
        @logs_cursor_column = column unless LOGS_STICKY_COLUMN_MOVEMENTS.include?(movement)
        reveal_logs_line(state, line)
        clear_selection_status
        true
      end

      def next_logs_cursor(movement, lines, line, column, page)
        last_line = lines.length - 1
        length = lines.fetch(line).length
        desired_column = [@logs_cursor_column.to_i, column].max

        case movement
        when :left
          return [line, column - 1] if column.positive?
          return [line - 1, lines.fetch(line - 1).length] if line.positive?
        when :right
          return [line, column + 1] if column < length
          return [line + 1, 0] if line < last_line
        when :up then return logs_cursor_on_line(lines, line - 1, desired_column)
        when :down then return logs_cursor_on_line(lines, line + 1, desired_column)
        when :home then return [line, 0]
        when :end then return [line, length]
        when :word_left
          return [line - 1, lines.fetch(line - 1).length] if column.zero? && line.positive?
          return [line, previous_word_boundary(lines.fetch(line).chars, column)]
        when :word_right
          return [line + 1, 0] if column >= length && line < last_line
          return [line, next_word_start(lines.fetch(line).chars, column)]
        when :page_up then return logs_cursor_on_line(lines, line - page, desired_column)
        when :page_down then return logs_cursor_on_line(lines, line + page, desired_column)
        end

        [line, column]
      end

      def logs_cursor_on_line(lines, line, desired_column)
        target = line.clamp(0, lines.length - 1)
        [target, [desired_column, lines.fetch(target).length].min]
      end

      def logs_page_step(state)
        window = layout.logs_visible_window(state, width: render_width, height: render_height) || {}
        [window.fetch("capacity", 1).to_i, 1].max
      end

      # A fresh caret starts on the newest visible line with text, so the first
      # keystroke lands on real log content instead of trailing blank wrap rows.
      def default_logs_cursor(state, lines)
        window = layout.logs_visible_window(state, width: render_width, height: render_height) || {}
        last_line = (window.fetch("finish_index", lines.length).to_i - 1).clamp(0, lines.length - 1)
        first_line = window.fetch("start_index", 0).to_i.clamp(0, last_line)
        line = last_line.downto(first_line).find { |candidate| !lines.fetch(candidate).strip.empty? } || last_line
        Selection.point(line, 0)
      end

      def logs_selection_lines(state)
        layout.logs_text_lines(state, width: render_width, height: render_height)
      end

      def reveal_logs_line(state, line_index)
        offset = layout.logs_scroll_offset_for_line(
          state,
          width: render_width,
          height: render_height,
          line_index: line_index
        )
        @scroll_offsets["logs"] = offset.to_i unless offset.nil?
      end

      def logs_cursor_line_text(state)
        return "" unless @logs_cursor_active && @logs_selection_focus

        layout.logs_line_copy_text(
          state,
          width: render_width,
          height: render_height,
          line_index: @logs_selection_focus.fetch("line", 0).to_i
        )
      end

      def clear_chat_selection
        @chat_selection_anchor = nil
        @chat_selection = nil
        reset_mouse_selection_granularity if @selection_pane == "chat"
        @selection_pane = nil if @selection_pane == "chat"
        nil
      end

      def set_selection_status(message)
        @selection_status = message.to_s
        @selection_status_at = monotonic_time
      end

      def clear_selection_status
        @selection_status = nil
        @selection_status_at = nil
      end

      def selection_status_text
        return nil unless @selection_status && @selection_status_at
        return nil if monotonic_time - @selection_status_at > SELECTION_STATUS_SECONDS

        @selection_status
      end

      def selection_snapshot
        snapshot = { "active" => selection_active?, "pane" => @selection_pane }
        status = selection_status_text
        snapshot["status"] = status if status
        snapshot = snapshot.merge(logs_selection || {})
        if @logs_cursor_active && @logs_selection_focus
          snapshot["pane"] = "logs"
          snapshot["mode"] = "logs_cursor"
          snapshot["cursor"] = @logs_selection_focus
        end
        snapshot
      end

      def logs_cursor_selection?
        @logs_cursor_active && @selection_pane == "logs"
      end

      def handle_selection_command_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if keybinding?("copy_selection", key) && (selection_active? || logs_cursor_selection?)
          copy_selection(state, input_buffer)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("cut_selection", key) && chat_selection_range
          copy_selection(state, input_buffer)
          return delete_chat_selection(input_buffer, input_cursor) + [NO_SLASH_SELECTION]
        end

        if keybinding?("paste_clipboard", key)
          text = Clipboard.paste
          if text.to_s.empty?
            set_selection_status("clipboard is empty")
            return [input_buffer, input_cursor, slash_suggestion_index]
          end

          buffer, cursor = replace_chat_selection(input_buffer, input_cursor)
          return insert_pasted_text(buffer, cursor, text) + [NO_SLASH_SELECTION]
        end

        nil
      end

      def copy_selection(state, input_buffer)
        text = selection_text(state, input_buffer)
        return if text.to_s.empty?

        transport = Clipboard.copy(text, output: clipboard_output)
        set_selection_status(transport ? copy_status_text(text) : "clipboard unavailable")
      end

      def copy_status_text(text)
        line_count = text.count("\n") + 1
        return "copied #{line_count} lines" unless line_count == 1

        stripped = text.strip
        return "copied 1 line" if stripped.empty? || stripped.length > COPY_ECHO_LIMIT

        %(copied "#{stripped}")
      end

      def selection_text(state, input_buffer)
        case @selection_pane
        when "logs"
          selection = logs_selection
          # An unextended caret copies its whole line, so keyboard users never
          # have to select a full line by hand to grab one log entry. Test the
          # geometry rather than the extracted text: a real selection may cover
          # only a non-copyable gutter and should then copy nothing.
          return logs_cursor_line_text(state) if Selection.empty?(selection)

          layout.logs_selection_text(state, width: render_width, height: render_height, selection: selection)
        when "chat"
          range = chat_selection_range
          return "" unless range

          # Copy hands over what the user pasted, not the marker standing in for
          # it, so the composer placeholder never leaks into another app.
          @chat_pastes.expand(input_buffer.to_s.chars[range.fetch("start")...range.fetch("end")].to_a.join)
        else
          ""
        end
      end

      def clipboard_output
        terminal.respond_to?(:output) ? terminal.output : out
      end

      def delete_chat_selection(input_buffer, input_cursor)
        range = chat_selection_range
        return [input_buffer, clamp_cursor(input_buffer, input_cursor)] unless range

        buffer, cursor = delete_range(input_buffer, (range.fetch("start")...range.fetch("end")))
        clear_chat_selection
        [buffer, cursor]
      end

      def replace_chat_selection(input_buffer, input_cursor)
        return [input_buffer, clamp_cursor(input_buffer, input_cursor)] unless chat_selection_range

        delete_chat_selection(input_buffer, input_cursor)
      end

      def handle_selection_movement_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        movement = SELECTION_MOVEMENTS.keys.find { |action| keybinding?(action, key) }
        return nil unless movement

        cursor = selection_movement_cursor(SELECTION_MOVEMENTS.fetch(movement), input_buffer, input_cursor, state: state)
        anchor = @selection_pane == "chat" && @chat_selection_anchor ? @chat_selection_anchor : clamp_cursor(input_buffer, input_cursor)
        clear_logs_selection
        update_chat_selection(anchor, cursor)
        @focused_pane = "chat"
        [input_buffer, cursor, slash_suggestion_index]
      end

      def selection_movement_cursor(movement, input_buffer, input_cursor, state: nil)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)

        moved = case movement
                when :left then [cursor - 1, 0].max
                when :right then [cursor + 1, chars.length].min
                when :up then composer_vertical_cursor(state, input_buffer, cursor, :up)
                when :down then composer_vertical_cursor(state, input_buffer, cursor, :down)
                when :home then current_line_start(chars, cursor)
                when :end then current_line_end(chars, cursor)
                when :word_left then previous_word_boundary(chars, cursor)
                when :word_right then next_word_start(chars, cursor)
                else cursor
                end

        # Extending a selection stops at a marker's edges for the same reason
        # moving the caret does: half a marker is not a thing the user can act on.
        paste_registry.snap_cursor(input_buffer, cursor, moved)
      end

      # A single left click selects the clicked AgentTree row and scopes the logs
      # pane to it. Clicking the already-selected row, or empty space inside the
      # tree, is the explicit deselect gesture. A double-click is node-specific:
      # issues open their delivery PR, workers open their focused workspace, and
      # retryable heads submit an explicit retry command.
      def handle_agent_tree_item_click(item_id, key, state, on_submit = nil)
        if item_id.to_s.empty?
          @last_worker_click = nil
          deselect_agent_tree_item
          return false
        end

        record = agent_tree_record(state, item_id)
        return false unless record

        action = agent_tree_double_click_action(record, item_id, key, state)
        double_click = action.fetch(:double_click)
        @last_worker_click = nil unless action.fetch(:track_click)
        if !double_click && @log_scope_id.to_s == item_id.to_s
          deselect_agent_tree_item
          return false
        end

        select_agent_tree_item(state, item_id)
        case action.fetch(:kind)
        when :pull_request
          double_click && open_pr_by_agent_id(state, item_id)
        when :workspace
          double_click && open_agent_workspace_by_id(state, item_id)
        when :retry
          double_click && submit_head_retry_from_tree(item_id, on_submit, state)
        else
          false
        end
      end

      def agent_tree_double_click_action(record, item_id, key, state)
        if issue_tree_record?(record)
          { kind: :pull_request, track_click: true, double_click: worker_double_click?(item_id, key) }
        elsif record["type"].to_s == "worker"
          workspace_openable = worker_workspace_available?(record)
          {
            kind: :workspace,
            track_click: workspace_openable,
            double_click: workspace_openable && worker_double_click?(item_id, key)
          }
        elsif record["type"].to_s == "head" && State::Models.head_retry_target?(record)
          { kind: :retry, track_click: true, double_click: worker_double_click?(item_id, key) }
        else
          { kind: :none, track_click: false, double_click: false }
        end
      end

      def agent_tree_record(state, item_id)
        return nil if item_id.to_s.empty?

        Array(state.fetch("issues", [])).find { |record| record.is_a?(Hash) && record["id"].to_s == item_id.to_s } ||
          Array(state.fetch("agents", [])).find { |record| record.is_a?(Hash) && record["id"].to_s == item_id.to_s }
      end

      def worker_workspace_available?(worker)
        Workspace::PathResolver.path_for(worker)
      rescue StandardError
        nil
      end

      def issue_tree_record?(record)
        AgentTreeNavigation.issue_record?(record)
      end

      def submit_head_retry_from_tree(item_id, on_submit, state)
        @workspace_draft = ""
        unless on_submit
          append_jump_response("Retry #{item_id} with /retry #{item_id}.")
          return true
        end

        submit_prompt("/retry #{item_id}", on_submit, state)
        true
      end

      def select_agent_tree_item(state, item_id)
        if agent_tree_selectable_agent_ids(state).include?(item_id)
          @agent_tree_navigation_active = true
          @agent_tree_navigation_mode = :agent
          @selected_agent_id = item_id
          remember_workspace_agent(state, item_id)
        elsif LogScope.selectable?(state, item_id)
          # Projects are valid log-filter targets but not jump targets, so
          # selecting one leaves jump mode instead of moving its cursor.
          @agent_tree_navigation_active = false
          @agent_tree_navigation_mode = :agent
          @selected_agent_id = nil
        else
          return false
        end

        set_log_scope(item_id)
        true
      end

      def deselect_agent_tree_item
        clear_log_scope
        exit_agent_tree_navigation if @agent_tree_navigation_active
        false
      end

      # A worker-authored logs cell is a direct filter gesture, not a pane or
      # keyboard-mode transition. Keep logs focus and its viewport; if jump mode
      # was already active, move its cursor to the same worker without toggling
      # the mode. A stale/removed worker is deliberately inert.
      def select_worker_from_logs(state, worker_id)
        worker = Array(state.fetch("agents", [])).find do |record|
          record.is_a?(Hash) && record.fetch("type", nil).to_s == "worker" && record.fetch("id", nil).to_s == worker_id.to_s
        end
        return false unless worker

        @logs_worker_click_rollback = {
          worker_id: worker.fetch("id").to_s,
          previous_scope: @log_scope_id,
          previous_selected_agent: @selected_agent_id
        }
        @log_scope_id = worker.fetch("id").to_s
        if @agent_tree_navigation_active
          @selected_agent_id = @log_scope_id
          remember_workspace_agent(state, @log_scope_id)
        end
        @revealed_agent_tree_item_id = nil
        true
      end

      # The logs filter follows the selection, so retargeting it also resets the
      # logs viewport to the newest matching entry and drops a caret/highlight
      # that pointed at lines the filter no longer renders.
      def set_log_scope(item_id)
        id = item_id.to_s
        return false if id.empty?

        @log_scope_id = id
        @scroll_offsets["logs"] = 0
        clear_logs_selection
        true
      end

      def clear_log_scope
        return false unless log_scope_active?

        @log_scope_id = nil
        @scroll_offsets["logs"] = 0
        clear_logs_selection
        true
      end

      def log_scope_active?
        !@log_scope_id.to_s.empty?
      end

      # Compatibility for extensions that invoked the old worker-only helper.
      def select_agent_tree_worker(state, worker_id)
        select_agent_tree_item(state, worker_id)
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

      # The open-PR count is not an AgentTree node and must never enter jump mode
      # or change the sticky log/chat selection. It therefore keeps an isolated
      # click tracker rather than borrowing the node-specific one above.
      def open_pull_requests_summary_double_click?(key)
        now = monotonic_time
        click = { x: key.fetch("x", nil).to_i, y: key.fetch("y", nil).to_i, at: now }
        previous = @last_open_pull_requests_summary_click
        @last_open_pull_requests_summary_click = click
        return false unless previous
        return false unless previous.fetch(:y) == click.fetch(:y)
        return false unless (previous.fetch(:x) - click.fetch(:x)).abs <= DOUBLE_CLICK_COLUMN_TOLERANCE

        if now - previous.fetch(:at, 0.0) <= DOUBLE_CLICK_INTERVAL_SECONDS
          @last_open_pull_requests_summary_click = nil
          true
        else
          false
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def cancel_workspace_leader!
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @agent_workspace_notice = nil
      end

      def expire_workspace_leader!
        return unless @workspace_leader_pending
        return unless @workspace_leader_started_at
        return if monotonic_time - @workspace_leader_started_at < WORKSPACE_LEADER_TIMEOUT_SECONDS

        cancel_workspace_leader!
      end

      def reset_base_state_cache
        @cached_base_state = nil
        @cached_base_state_at = nil
      end

      def read_only_base_state(state_provider, now: monotonic_time)
        if @cached_base_state && @cached_base_state_at && (now - @cached_base_state_at) < REFRESH_INTERVAL
          return @cached_base_state
        end

        @cached_base_state = state_provider.call || State::Models.empty_state
        @cached_base_state_at = now
        @cached_base_state
      end

      def mouse_wheel_up?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "wheel_up"
      end

      def mouse_wheel_down?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "wheel_down"
      end

      def mouse_wheel?(key)
        mouse_wheel_up?(key) || mouse_wheel_down?(key)
      end

      def scroll_focused_pane(direction, steps:, state:)
        scroll_pane(@focused_pane.to_s, direction, steps: steps, state: state)
      end

      def scroll_pane(pane, direction, steps:, state:, max_offset: nil)
        pane = pane.to_s
        delta = scroll_delta_for(pane, direction, steps)
        max_offset ||= scroll_max_for(pane, state)
        @scroll_offsets[pane] = (@scroll_offsets[pane].to_i + delta).clamp(0, max_offset)
      end

      def scroll_focused_pane_to(edge, state:)
        pane = @focused_pane.to_s
        max_offset = scroll_max_for(pane, state)
        # The AgentTree counts rows from the first line down; tail panes count
        # back from the newest line, so "top" is the opposite end there.
        top_offset, bottom_offset = pane == "agent_tree" ? [0, max_offset] : [max_offset, 0]
        @scroll_offsets[pane] = edge == :top ? top_offset : bottom_offset
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

      def scroll_limits_for(state)
        layout.scroll_limits(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT
        )
      end

      def scroll_max_for(pane, state)
        scroll_limits_for(state).fetch(pane.to_s, 0).to_i
      end

      def clamp_scroll_offsets!(state)
        scroll_limits_for(state).each do |pane, max_offset|
          @scroll_offsets[pane] = @scroll_offsets[pane].to_i.clamp(0, max_offset.to_i)
        end
      end

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
          next if action == "workspace_open_pull_request" && !github_support_enabled?

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
          unless github_support_enabled?(state)
            @agent_workspace_notice = nil
            @agent_workspace_error = github_support_disabled_message
            return :handled
          end
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
        records = WorkspaceCommands.command_suggestion_records(input_buffer)
        return records if github_support_enabled?

        records.reject do |record|
          record.fetch("action", nil) == "workspace_open_pull_request" || record.fetch("completion", nil) == "/pr"
        end
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
          help_lines = help_lines.reject { |line| line.start_with?("/pr ") } unless github_support_enabled?(state)
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
      # harness-agnostic so a non-Pi backend reads correctly.
      def workspace_leader_commands
        WORKSPACE_COMMAND_ACTIONS.filter_map do |action|
          next if action == "workspace_open_pull_request" && !github_support_enabled?
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

      # Page keys stay available to the shell in terminal view; the wheel is
      # never forwarded to a shell, so it scrolls either view.
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

      def handle_agent_tree_navigation_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if keybinding?("cancel_navigation", key)
          # Esc cancels the innermost thing first: a text selection or logs caret,
          # then the AgentTree selection (with its logs filter) and jump mode.
          if selection_active? || @logs_cursor_active
            clear_selection
            return [input_buffer, input_cursor, slash_suggestion_index]
          end

          clear_log_scope
          exit_agent_tree_navigation("Agent tree navigation cancelled.")
          return [+"", 0, NO_SLASH_SELECTION]
        end

        scroll_result = handle_navigation_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return scroll_result if scroll_result

        if keybinding?("agent_select_previous", key)
          move_agent_tree_selection(state, -1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("agent_select_next", key)
          move_agent_tree_selection(state, 1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("rename_selected", key)
          return begin_selected_rename(state, input_buffer)
        end

        if agent_session_open_key?(key)
          opened = open_selected_agent(state)
          return [input_buffer, input_cursor, NO_SLASH_SELECTION] if opened && embedded_agent_workspace?

          draft = opened ? @workspace_draft.to_s.dup : ""
          return [draft, draft.chars.length, NO_SLASH_SELECTION]
        end

        if ENTER_KEYS.include?(key)
          open_selected_agent_pr(state)
          return [+"", 0, NO_SLASH_SELECTION]
        end

        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def agent_session_open_key?(key)
        keybinding?("open_agent_workspace", key)
      end

      # Quick rename reuses the normal composer and kernel command path. This keeps
      # the edit cancellable with Ctrl-C/Esc and means projects and issues get the
      # same validation and durable log entry as slash commands. The draft is the
      # namespaced command for the selected row kind (`/project rename` for a project,
      # `/issue rename` for an issue or the issue that owns the selected worker), so what
      # lands in the composer is exactly what the user could have typed themselves.
      def begin_selected_rename(state, input_buffer = "")
        kind, target_id = rename_target(state)
        unless target_id
          set_selection_status("Select a project or issue to rename")
          return [input_buffer, input_buffer.to_s.chars.length, NO_SLASH_SELECTION]
        end

        exit_agent_tree_navigation if @agent_tree_navigation_active
        draft = "/#{kind} rename #{target_id} "
        set_selection_status("Type a new name and press Enter")
        [draft, draft.chars.length, NO_SLASH_SELECTION]
      end

      # Returns ["project" | "issue", id] for the selected row, or nil when nothing
      # renameable is selected.
      def rename_target(state)
        candidate_ids = [@selected_agent_id, @log_scope_id].compact
        candidate_ids.each do |candidate_id|
          issue = Array(state.fetch("issues", [])).find { |record| record["id"].to_s == candidate_id.to_s }
          return ["issue", issue.fetch("id")] if issue

          project = Array(state.fetch("projects", [])).find { |record| record["id"].to_s == candidate_id.to_s }
          return ["project", project.fetch("id")] if project

          agent = Array(state.fetch("agents", [])).find { |record| record["id"].to_s == candidate_id.to_s }
          return ["issue", agent.fetch("issue_id")] if agent && agent["issue_id"]
        end
        nil
      end

      def handle_local_navigation_command(input_buffer, state)
        text = input_buffer.to_s.strip
        return handle_local_jump_command(text, state) if jump_command?(text)
        return handle_local_pull_requests_command(state) if pull_requests_picker_command?(text)
        return handle_local_models_command(text, state) if models_picker_command?(text)
        return handle_local_thinking_command(text, state) if thinking_picker_command?(text)
        return handle_local_theme_command(text, state) if theme_picker_command?(text)
        return handle_local_harness_command(text, state) if harness_picker_command?(text)
        return handle_local_open_session_command(text, state) if open_session_command?(text)
        return handle_local_setup_command(state) if setup_command?(text)
        return handle_local_keybind_command if keybind_command?(text)
        return handle_local_config_command(text, state) if config_command?(text)
        return handle_local_status_bar_command(state) if status_bar_command?(text)
        return handle_local_quit_command if quit_command?(text)

        false
      end

      def handle_local_jump_command(text, state)
        agent_id = text.split(/\s+/, 2)[1].to_s.strip
        if agent_id.empty?
          enter_agent_tree_navigation(state)
        else
          open_agent_workspace_by_id(state, agent_id)
        end
        true
      end

      def handle_local_keybind_command
        append_jump_response(keybinding_help_text)
        true
      end

      def handle_local_config_command(text, state)
        if text.to_s.strip == "/config --text"
          append_jump_response(configuration_help_text)
        else
          open_settings(state)
        end
        true
      end

      def handle_local_status_bar_command(state)
        open_status_bar_composer(state)
        true
      end

      def handle_local_quit_command
        @quit_requested = true
        true
      end

      def keybinding_help_text
        <<~TEXT.strip
          Keybindings (from [tui.keybindings], with defaults for omitted actions):
          Global: /quit or #{keys_for("quit")} quits; #{keys_for("clear_or_quit")} clears input or quits when input is empty; #{keys_for("cancel_navigation")} cancels a selection first, then the AgentTree log/chat target and jump mode.
          Focus: click a dashboard section to focus it; double-clicking the `N open PR` / `N open PRs` summary opens the global pull-request picker, double-clicking an issue opens its delivery PR (or shows a transient no-PR notice), double-clicking a worker with a workspace opens its focused workspace, and double-clicking a retryable head submits /retry for a fresh head. Unavailable rows stay quiet. #{keys_for("focus_next")} moves focus forward; #{keys_for("focus_previous")} moves focus backward; #{keys_for("scroll_up")}/#{keys_for("scroll_down")}, #{keys_for("scroll_page_up")}/#{keys_for("scroll_page_down")}, and #{keys_for("scroll_top")}/#{keys_for("scroll_bottom")} scroll the focused pane; the mouse wheel scrolls whichever pane the pointer is over.
          AgentTree selection and chat target: single-click a project, issue, head, or worker row to select it and filter the logs pane to that node (a worker shows its own logs, an issue adds all of its workers and child issues, a project adds its whole subtree). Right-click an issue to open its associated delivery PR; workers do not duplicate that affordance, and an issue without one shows a transient notice. An issue also targets subsequent natural-language chat to that issue; a worker selection resolves chat to its owning issue. A fresh head still routes every message using that explicit target context. Head rows and projects remain log-only filters; retry a failed/blocked head explicitly with /retry H<n> or by double-clicking its "retry me" row. Use /open-session <agent_id> to open an underlying harness session for debugging, including a head session. The selection stays highlighted, is scrolled back into view when it changes, and keeps filtering while you work in the logs or chat pane; #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} in jump mode retarget it. Double-click an issue to open its PR, or double-click a worker with an assigned workspace to open that worker's focused workspace. Click the highlighted row again, click empty space in the AgentTree, or press #{keys_for("cancel_navigation")} to clear it. Heads without an owning issue, projects, and workers without workspaces remain log-only filters for these mouse actions.
          Logs mouse target: click a worker id, worker title, or nonblank worker-authored body text to select that worker and filter its logs without changing logs focus or scroll position; removed workers and surrounding chrome are inert. Drag, double-click, and triple-click remain text-selection gestures and take precedence.
          Selection: drag with the mouse in the logs pane or the composer to select text; holding a logs drag against or beyond the top/bottom text edge scrolls and extends it automatically; double-click selects a word, and triple-click selects a complete logs paragraph; #{keys_for("copy_selection")} copies the selection to the system clipboard; #{keys_for("cancel_navigation")} clears it.
          Logs selection (keyboard): focus the logs pane, then #{keys_for("logs_selection_mode")} toggles the selection cursor or any Shift+movement starts it. #{keys_for("cursor_left")}/#{keys_for("cursor_right")}/#{keys_for("cursor_up")}/#{keys_for("cursor_down")} move the cursor, #{keys_for("cursor_word_left")}/#{keys_for("cursor_word_right")} move by word, #{keys_for("cursor_home")}/#{keys_for("cursor_end")} jump to the line edges, and #{keys_for("scroll_page_up")}/#{keys_for("scroll_page_down")} move by page. #{keys_for("select_left")}/#{keys_for("select_right")}/#{keys_for("select_up")}/#{keys_for("select_down")}, #{keys_for("select_home")}/#{keys_for("select_end")}, #{keys_for("select_word_left")}/#{keys_for("select_word_right")}, and #{keys_for("select_page_up")}/#{keys_for("select_page_down")} extend the selection. #{keys_for("copy_selection")} copies the selection (or the cursor line when nothing is extended); #{keys_for("cancel_navigation")} exits.
          Composer selection: #{keys_for("select_left")}/#{keys_for("select_right")}/#{keys_for("select_up")}/#{keys_for("select_down")} extend by character or line; #{keys_for("select_home")}/#{keys_for("select_end")} extend to the line edges; #{keys_for("select_word_left")}/#{keys_for("select_word_right")} extend by word; #{keys_for("cut_selection")} cuts; #{keys_for("paste_clipboard")} pastes; typing or Backspace/Delete replaces the selection.
          Chat: #{keys_for("submit")} sends the prompt as typed, or applies a slash suggestion once one is selected; #{keys_for("newline")} inserts a newline; #{keys_for("cursor_left")}/#{keys_for("cursor_right")} move by character; #{keys_for("cursor_up")}/#{keys_for("cursor_down")} move through hard and soft-wrapped rows, then browse sent-input history at the first/last row; #{keys_for("cursor_home")} and #{keys_for("cursor_end")} jump within a line; #{keys_for("cursor_word_left")} and #{keys_for("cursor_word_right")} move by word; #{keys_for("delete_backward")}/#{keys_for("delete_forward")} edit characters; #{keys_for("delete_word_backward")} and #{keys_for("delete_word_forward")} edit words.
          Slash commands: type / for suggestions; nothing is selected until you press #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} or #{keys_for("complete_suggestion")}; #{keys_for("complete_suggestion")} completes; #{keys_for("submit")} inserts the selected suggestion.
          Agent tree/logs: focus either pane and press #{keys_for("submit")} to enter jump mode. In the AgentTree, #{keys_for("rename_selected")} starts a quick rename for the selected project or issue by pre-filling `/project rename` or `/issue rename`; type its new name in the composer and press Enter.
          Agent tree scrolling: focus the AgentTree, then #{keys_for("scroll_up")}/#{keys_for("scroll_down")} scroll a line, #{keys_for("scroll_page_up")}/#{keys_for("scroll_page_down")} scroll a page, #{keys_for("scroll_top")}/#{keys_for("scroll_bottom")} jump to the first/last row, and the mouse wheel scrolls while the pointer is over the pane. The pane title shows how many rows are hidden above and below (↑ above ↓ below). In jump mode #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} keep the selected item on screen automatically while paging and #{keys_for("scroll_top")}/#{keys_for("scroll_bottom")} still scroll.
          Pull-request picker: /prs opens every tracked PR that is still open, regardless of the AgentTree selection; #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} move, #{keys_for("submit")} opens the highlighted PR, and #{keys_for("cancel_navigation")} closes. #{keys_for("open_delivery_pr")} keeps its selection-aware behavior: it opens the selected issue's PR, or this picker when chat is unscoped.
          Settings pickers: bare /model or /models opens models, bare /thinking opens thinking levels, bare /theme opens themes, and bare /harness opens harnesses. They are bordered popovers; #{keys_for("cursor_left")}/#{keys_for("cursor_right")} switches role tabs where shown, #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} moves, #{keys_for("submit")} applies, #{keys_for("refresh_model_catalog")} refreshes the model catalog, and #{keys_for("cancel_navigation")} closes. /models refresh re-fetches without opening the picker. /prs opens the pull-request popover.
          Status-bar composer: /status-bar opens the live bottom, agent-information, and focused-worker layout editor; Tab/Shift-Tab changes bars, Up/Down selects, Left/Right reorders, Home/End moves to an edge, R resets, Enter/Ctrl-S saves, Esc cancels, and mouse drag reorders items.
          Jump mode: /jump starts navigation; #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} selects an item; #{keys_for("open_agent_workspace")} opens the selected worker workspace or a selected head's saved harness session; #{keys_for("open_delivery_pr")} or Enter opens a verified delivery PR; #{keys_for("cancel_navigation")} cancels.
          Head/session debugging: select a head and press #{keys_for("open_agent_workspace")}, or use /open-session <agent_id>, to open its saved harness session externally without turning it into a chat target.
          Focused worker workspace (optional deep interaction): press #{keys_for("workspace_leader")}, then #{keys_for("workspace_switch_view")} to switch between terminal and agent view, #{keys_for("workspace_cycle_filter")} to cycle the transcript filter, #{keys_for("workspace_open_agent_session")} to open the underlying agent session externally, #{keys_for("workspace_open_editor")} for the editor, #{keys_for("workspace_open_pull_request")} for the delivery PR, or #{keys_for("workspace_close")} to quit back to the AgentTree while preserving the worker/terminal. PageUp/PageDown or the mouse wheel scrolls the transcript. In the focused composer, type / for workspace commands (/help, /terminal, /filter, /session, /editor, /pr, /cwd, /cancel, /quit); anything else is sent to the worker. Use dashboard chat for normal head-agent orchestration.
        TEXT
      end

      # `/config` is deliberately a read-only local command. It reports the
      # supported effective settings rather than dumping arbitrary TOML, which
      # keeps the overview useful and avoids accidentally echoing secrets.
      def configuration_help_text
        registry = Harness::Registry.new(config: config)
        # A harness that exposes no model or reasoning defaults simply has none to report, which is
        # different from having them and failing to read them.
        session_defaults = begin
          registry.session_defaults
        rescue StandardError
          {}
        end
        head_model = session_defaults.dig("roles", "head", "model") || "mixed by role"
        worker_model = session_defaults.dig("roles", "worker", "model") || "mixed by role"
        head_thinking = session_defaults.dig("roles", "head", "thinking_level")
        worker_thinking = session_defaults.dig("roles", "worker", "thinking_level")
        provider = ENV["MERINGUE_HARNESS"] || config.value("harness", "provider")
        head_provider = ENV["MERINGUE_HEAD_HARNESS"] || config.value("harness", "head_provider") || provider || "not set"
        worker_provider = ENV["MERINGUE_WORKER_HARNESS"] || config.value("harness", "worker_provider") || provider || "not set"
        colorscheme = config.value("tui", "colorscheme") || config.value("tui", "color_scheme") || TUI::Style::DEFAULT_COLORSCHEME
        shell = config.value("workspace", "shell_command") || ENV["MERINGUE_SHELL"] || ENV["SHELL"] || "/bin/sh"
        editor = config.value("workspace", "editor_command") || ENV["MERINGUE_EDITOR"] || ENV["VISUAL"] || ENV["EDITOR"] || "code"
        editor_args = config.value("workspace", "editor_args") || ["."]
        worker_blacklist = CommandBlacklist.from_config(config).patterns

        lines = [
          "Configuration (read-only)",
          "  file: #{config.path} (#{config.loaded? ? "loaded" : "not found; built-in defaults"})",
          "  harness: #{provider}",
          "  head harness: #{head_provider}",
          "  worker harness: #{worker_provider}",
          "  TUI colorscheme: #{colorscheme}",
          "  head model: #{head_model}",
          "  worker model: #{worker_model}",
          "  head reasoning: #{head_thinking}",
          "  worker reasoning: #{worker_thinking}",
          "  conflict policy (predecessor failure): #{config.conflict_predecessor_failure}",
          "  worker command blacklist: #{worker_blacklist.empty? ? "(disabled)" : format_config_value(worker_blacklist)}",
          "  workspace shell: #{format_config_value(shell)}",
          "  workspace editor: #{format_config_value(editor)}",
          "  workspace editor args: #{format_config_value(editor_args)}",
          "",
          "Keybindings (action: configured keys; omitted actions use defaults):"
        ]
        lines.concat(Keybindings.actions.map do |action|
          "  #{Keybindings.label_for(action)} [#{action}]: #{format_config_value(keybindings.names_for(action))}"
        end)
        lines.join("\n")
      end

      def format_config_value(value)
        case value
        when Array
          value.empty? ? "(unbound)" : value.join(", ")
        when Hash
          value.empty? ? "{}" : value.inspect
        else
          value.to_s
        end
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

      def pull_requests_picker_command?(text)
        text.to_s.strip.downcase == "/prs"
      end

      def handle_local_pull_requests_command(state)
        unless github_support_enabled?(state)
          append_jump_response(github_support_disabled_message)
          return true
        end

        open_delivery_pr_picker(state)
        true
      end

      def open_session_command?(text)
        text == "/open-session" || text.start_with?("/open-session ")
      end

      # `/models` and its bare singular alias `/model` are local TUI commands
      # that open the model picker. A singular command with any argument keeps
      # its existing setting behavior. `/models refresh` stays a kernel command
      # (GetModelCatalog), so a forced re-fetch is still journaled and logged
      # like any other kernel command instead of being a hidden UI side effect.
      def models_picker_command?(text)
        tokens = text.to_s.strip.split(/\s+/)
        arguments = tokens.drop(1).map { |token| token.to_s.downcase }
        command = tokens.first.to_s.downcase.delete_prefix("/")
        role_only_model_command = command == "model" && arguments.length == 1 && %w[head worker].include?(arguments.first)
        command = Input::SlashCommandParser.expand_bare_singular_alias(command, arguments.join(" ")) unless role_only_model_command
        return false unless command == "models" || role_only_model_command
        return false if arguments.any? { |token| Input::SlashCommandParser::MODEL_CATALOG_REFRESH_WORDS.include?(token) }
        return false if arguments.length > 1

        # `/models head` and `/models worker` select the initial tab; any other
        # single argument keeps the existing harness-scoping behavior.
        true
      end

      def thinking_picker_command?(text)
        tokens = text.to_s.strip.split(/\s+/)
        return false unless tokens.first.to_s.downcase == "/thinking"

        arguments = tokens.drop(1).map { |token| token.to_s.downcase }
        arguments.empty? || (arguments.length == 1 && %w[head worker].include?(arguments.first))
      end

      def theme_picker_command?(text)
        text.to_s.strip.downcase == "/theme"
      end

      def harness_picker_command?(text)
        tokens = text.to_s.strip.split(/\s+/)
        return false unless tokens.first.to_s.downcase == "/harness"

        arguments = tokens.drop(1).map { |token| token.to_s.downcase }
        arguments.empty? || (arguments.length == 1 && %w[head worker].include?(arguments.first))
      end

      def handle_local_models_command(text, state)
        arguments = text.to_s.strip.split(/\s+/).drop(1)
        role = arguments.first if %w[head worker].include?(arguments.first.to_s.downcase)
        harness = role ? nil : arguments.first
        open_model_picker(state, harness: harness, role: role)
        true
      end

      def handle_local_thinking_command(text, state)
        role = text.to_s.strip.split(/\s+/)[1]
        open_thinking_picker(state, role: role)
        true
      end

      def handle_local_theme_command(_text, state)
        open_theme_picker(state)
        true
      end

      def handle_local_harness_command(text, state)
        role = text.to_s.strip.split(/\s+/)[1]
        open_harness_picker(state, role: role)
        true
      end

      def handle_local_open_session_command(text, state)
        agent_id = text.split(/\s+/, 2)[1].to_s.strip
        if agent_id.empty?
          append_jump_response("Usage: /open-session <agent_id>")
          return true
        end

        agent = Array(state.fetch("agents", [])).find { |record| record.is_a?(Hash) && record.fetch("id", nil).to_s == agent_id }
        unless agent
          append_jump_response("Agent #{agent_id} does not exist.")
          return true
        end

        result = external_agent_session_result(agent)
        status = result.fetch("status", "failed").to_s
        message = result.fetch("message", nil).to_s.strip
        append_jump_response(message.empty? && status == "opened" ? "Opened agent session for #{agent.fetch("id")}." : message)
        true
      end

      # One detached-session boundary serves `/open-session`, the head-row
      # shortcut, and the focused worker command. It never attaches to or takes
      # ownership of the kernel-managed harness process.
      def external_agent_session_result(agent)
        unless session_opener&.respond_to?(:open)
          return {
            "status" => "rejected",
            "message" => "Opening an external agent session is not configured."
          }
        end

        result = session_opener.open(agent)
        return result if result.is_a?(Hash)

        {
          "status" => "failed",
          "message" => "Could not open the external agent session for #{agent.fetch("id", "unknown")}."
        }
      rescue StandardError => e
        {
          "status" => "failed",
          "message" => "Could not open the external agent session for #{agent.fetch("id", "unknown")}: #{e.message}"
        }
      end

      def config_command?(text)
        ["/config", "/config --text"].include?(text.to_s.strip)
      end

      def status_bar_command?(text)
        ["/status-bar", "/statusbar", "/layout"].include?(text.to_s.strip.downcase)
      end

      def quit_command?(text)
        text == "/quit"
      end

      def local_navigation_command_without_id?(input_buffer)
        text = input_buffer.to_s.strip.downcase
        return true if ["/jump", "/prs", "/setup", "/config", "/status-bar", "/statusbar", "/layout", "/open-session"].include?(text)
        return true if models_picker_command?(text)
        return true if thinking_picker_command?(text)
        return true if theme_picker_command?(text)
        return true if harness_picker_command?(text)

        false
      end

      def enter_agent_tree_navigation(state)
        ids = agent_tree_selectable_agent_ids(state)
        if ids.empty?
          append_jump_response("No agents are available to jump into yet.")
          return
        end

        deactivate_logs_cursor_quietly
        @agent_tree_navigation_active = true
        @agent_tree_navigation_mode = :agent
        # Start on the sticky selection when it is a jump target, so entering jump
        # mode never argues with what the logs pane is already filtered by.
        # Entering jump mode by itself does not retarget the filter; moving the
        # cursor does.
        @selected_agent_id = [@log_scope_id, @selected_agent_id].find { |id| ids.include?(id) } || ids.first
        append_jump_response("Agent tree navigation active. #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} selects issues and agents, filters their logs, and targets dashboard chat through a fresh head when an issue can be resolved (kernel events are skipped). Enter opens PRs, #{keys_for("open_agent_workspace")} opens a worker workspace or selected head session, and #{keys_for("cancel_navigation")} clears the selection.")
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
        # Moving the cursor is an explicit selection action, so the logs filter
        # follows it and the highlighted row always matches the filter.
        set_log_scope(@selected_agent_id)
        remember_workspace_agent(state, @selected_agent_id)
      end

      def open_selected_agent(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        selected_agent = Meringue::Ids.find_record(Array(state.fetch("agents", [])), selected_id)
        if selected_agent&.fetch("type", nil) == "head"
          open_head_session_for_debugging(selected_agent)
          return false
        end

        remember_workspace_agent(state, selected_id)
        open_agent_workspace_by_id(state, selected_id)
      end

      # Heads never gain a focused workspace or become chat targets. `a` is only
      # a debugging affordance over the persisted harness history. Expected
      # unavailability is transient dashboard feedback, not a durable log line.
      def open_head_session_for_debugging(head)
        result = external_agent_session_result(head)
        status = result.fetch("status", "failed").to_s
        message = result.fetch("message", nil).to_s.strip
        message = "Opened agent session for #{head.fetch("id")}." if status == "opened" && message.empty?
        message = "Agent session for #{head.fetch("id")} is unavailable." if message.empty?
        set_selection_status(message)
        status == "opened"
      end

      def open_selected_agent_pr(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        open_pr_by_agent_id(state, selected_id)
        exit_agent_tree_navigation
      end

      def open_agent_workspace_by_id(state, item_id)
        return_pane = @focused_pane
        agent = agent_workspace_agent_for_item(state, item_id)
        unless agent
          # Unavailable is an expected state for pending heads and issues that do
          # not have a worker yet. Keep it out of durable/visible logs; an
          # explicit keyboard or /jump attempt gets a short-lived hint instead.
          set_selection_status("#{item_id} has no focused workspace yet")
          return false
        end

        if @agent_workspace_active && @agent_workspace_agent_id.to_s != agent.fetch("id").to_s
          close_agent_workspace
        elsif @agent_workspace_active
          return true
        end

        # Whether this worker's backend has a session to embed is the backend's answer, not a
        # harness name the UI keeps a list of.
        focus_mode = agent_workspace_focus_mode(agent)
        native_focus = focus_mode != "none" && workspace_controller&.respond_to?(:open_workspace)
        restored_view = if native_focus
                          "agent"
                        elsif @agent_workspace_agent_id.to_s == agent.fetch("id").to_s
                          @agent_workspace_view
                        else
                          "agent"
                        end
        # The logs caret belongs to the dashboard logs pane, so opening the
        # focused workspace disarms it instead of leaving Ctrl-C bound to copy.
        deactivate_logs_cursor_quietly
        # The open-PR and model pickers are dashboard chrome, so they must not
        # survive into the focused workspace and reappear on return.
        close_delivery_pr_picker
        close_model_picker
        @agent_workspace_active = true
        @agent_workspace_interactive = false
        @force_full_redraw = true
        @agent_workspace_agent_id = agent.fetch("id")
        @agent_workspace_return_pane = return_pane
        @agent_workspace_view = restored_view
        @agent_workspace_terminal_size = nil
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @agent_workspace_notice = nil
        @agent_workspace_error = nil
        @agent_workspace_open_generation += 1
        open_generation = @agent_workspace_open_generation
        @chat_mutex.synchronize do
          event_key = agent.fetch("id").to_s
          @agent_workspace_events[event_key] = []
          # A reopened view has a fresh journal cursor and will replay the managed
          # session's retained events. Invalidate the old frozen presentation too;
          # otherwise a worker with no new events can briefly render fragments from
          # the previous focus session instead of the fresh replay.
          @agent_workspace_events_revision[event_key] += 1
          @agent_workspace_events_cache.delete(event_key)
        end
        @selected_agent_id = agent.fetch("id")
        @agent_tree_navigation_active = !native_focus
        @focused_pane = native_focus ? "logs" : "agent_tree"
        if workspace_controller&.respond_to?(:open_workspace)
          rows, columns = agent_workspace_terminal_dimensions(state, embedded: native_focus)
          workspace_result = begin
            if workspace_controller.respond_to?(:open_workspace_async) && focus_mode != "none"
              @agent_workspace_open_pending = true
              @chat_mutex.synchronize { @agent_workspace_open_result = nil }
              workspace_controller.open_workspace_async(
                agent: agent,
                state: state,
                rows: rows,
                columns: columns
              ) do |result|
                @chat_mutex.synchronize do
                  @agent_workspace_open_result = [open_generation, agent.fetch("id").to_s, result]
                end
              end
            else
              workspace_controller.open_workspace(
                agent: agent,
                state: state,
                rows: rows,
                columns: columns
              )
            end
          rescue ArgumentError
            workspace_controller.open_workspace(agent: agent, state: state)
          end
          apply_workspace_controller_result(workspace_result)
          if %w[failed rejected errored].include?(workspace_result.fetch("status", nil).to_s)
            @agent_workspace_open_pending = false
            # The focused pane is about to disappear, so keep its actionable failure visible on the
            # restored dashboard instead of stranding it in @agent_workspace_error.
            message = workspace_result.fetch("message", "Could not open focused workspace.").to_s
            set_selection_status(message)
            @agent_workspace_active = false
            @focused_pane = @agent_workspace_return_pane
            @agent_tree_navigation_active = false
            @force_full_redraw = true
            return false
          end
          if workspace_result.fetch("status", nil).to_s == "pending"
            @agent_workspace_notice = workspace_result.fetch("message", "Preparing focused workspace…")
            persist_agent_workspace
            return true
          end
          @agent_workspace_open_pending = false
          @agent_workspace_interactive = workspace_result.fetch("interactive", false)
          unless @agent_workspace_interactive
            @focused_pane = "agent_tree"
            @agent_tree_navigation_active = true
          end
        end
        open_agent_workspace_session(agent) unless @agent_workspace_interactive
        if @agent_workspace_view == "terminal"
          @agent_workspace_session.pause if !@agent_workspace_interactive && @agent_workspace_session&.respond_to?(:pause)
          prepare_workspace_terminal(state)
        end
        persist_agent_workspace
        true
      rescue StandardError => e
        close_agent_workspace_session
        @agent_workspace_active = false
        @focused_pane = @agent_workspace_return_pane
        @agent_tree_navigation_active = false
        append_jump_response("Could not open focused workspace for #{item_id}: #{e.message}")
        false
      end

      def open_agent_workspace_session(agent)
        close_agent_workspace_session
        return unless agent_session_service&.respond_to?(:open)

        @agent_workspace_session = agent_session_service.open(agent.fetch("id"))
      rescue StandardError => e
        @agent_workspace_session = nil
        @agent_workspace_error = "Could not open the live worker session: #{e.message}"
      end

      def close_agent_workspace_session
        session = @agent_workspace_session
        @agent_workspace_session = nil
        session.close if session&.respond_to?(:close)
      rescue StandardError
        nil
      end

      def close_agent_workspace(preserve_terminal: false, async_interactive: true)
        was_embedded = embedded_agent_workspace?
        return_pane = @agent_workspace_return_pane.to_s
        return_pane = "chat" unless FOCUS_ORDER.include?(return_pane)
        if @agent_workspace_open_pending && workspace_controller&.respond_to?(:cancel_workspace_open)
          workspace_controller.cancel_workspace_open(agent: @agent_workspace_agent_id)
        end
        @agent_workspace_open_pending = false
        @agent_workspace_open_generation += 1
        @chat_mutex.synchronize { @agent_workspace_open_result = nil }
        close_agent_workspace_session
        if @agent_workspace_interactive && workspace_controller&.respond_to?(:close_workspace)
          close_interactive_agent_workspace(@agent_workspace_agent_id, asynchronous: async_interactive)
        elsif !preserve_terminal && workspace_controller&.respond_to?(:close_terminal)
          workspace_controller.close_terminal(agent: @agent_workspace_agent_id)
        end
        @agent_workspace_interactive = false
        @agent_workspace_open_pending = false
        @agent_workspace_active = false
        @agent_workspace_view = "agent"
        @force_full_redraw = true
        @agent_workspace_terminal_size = nil
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @agent_workspace_notice = nil
        @agent_workspace_error = nil
        @focused_pane = was_embedded ? return_pane : "agent_tree"
        @agent_tree_navigation_active = !was_embedded && !@agent_workspace_agent_id.to_s.empty?
        @selected_agent_id = @agent_workspace_agent_id if @agent_tree_navigation_active
        persist_agent_workspace
      end

      def close_interactive_agent_workspace(agent_id, asynchronous: true)
        if asynchronous && workspace_controller.respond_to?(:close_workspace_async)
          result = workspace_controller.close_workspace_async(agent: agent_id) do |completion|
            @chat_mutex.synchronize { @agent_workspace_close_results << completion }
          end
          @chat_mutex.synchronize { @agent_workspace_close_results << result } unless result.fetch("status", nil).to_s == "pending"
        else
          apply_workspace_controller_result(workspace_controller.close_workspace(agent: agent_id))
        end
      end

      # `item_id` can come from a typed `/jump <id>`, so it is matched case-insensitively against
      # canonical Meringue ids. Everything downstream uses the resolved record's canonical id.
      def agent_workspace_agent_for_item(state, item_id)
        agents = Array(state.fetch("agents", []))
        direct = Meringue::Ids.find_record(
          agents.select { |agent| agent.fetch("type", nil) == "worker" },
          item_id
        )
        return direct if direct

        issue = Meringue::Ids.find_record(Array(state.fetch("issues", [])), item_id)
        return nil unless issue

        agents.select { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil).to_s == issue.fetch("id").to_s }
              .reject { |agent| agent.fetch("status", nil) == "killed" }
              .max_by { |agent| AgentTreeNavigation.sort_key(agent.fetch("id", "")) }
      end

      def agent_workspace_agent(state)
        Array(state.fetch("agents", [])).find do |agent|
          agent.fetch("id", nil).to_s == @agent_workspace_agent_id.to_s
        end
      end

      # Ctrl-B has two honest meanings. With one node in view it opens that node's
      # delivery PR. Unscoped, there is no single PR to mean, so it opens the picker
      # over every PR that is still open instead of guessing.
      def open_workspace_delivery_pr(state)
        unless github_support_enabled?(state)
          set_selection_status(github_support_disabled_message)
          return false
        end

        return open_delivery_pr_for_id(state, @agent_workspace_agent_id) if @agent_workspace_active
        return open_delivery_pr_for_id(state, normalized_selected_agent_id(state)) if @agent_tree_navigation_active

        scoped_id = DeliveryPullRequest.scoped_id(state)
        return open_delivery_pr_for_id(state, scoped_id) unless scoped_id.empty?

        open_delivery_pr_picker(state)
      end

      def open_delivery_pr_for_id(state, agent_id)
        unless github_support_enabled?(state)
          append_jump_response(github_support_disabled_message)
          return false
        end
        if agent_id.to_s.empty?
          append_jump_response("Select a worker before opening its delivery pull request.")
          return false
        end

        presentation = DeliveryPullRequest.for_id(state, agent_id)
        unless DeliveryPullRequest.openable?(presentation)
          append_jump_response("Delivery PR for #{agent_id} is unavailable: #{presentation.fetch("message")}")
          return false
        end

        result = pull_request_opener.open(presentation.fetch("url"))
        opened = result.fetch("status", nil) == "opened" || !%w[failed rejected].include?(result.fetch("status", nil).to_s)
        append_jump_response(result.fetch("message", "Could not open delivery pull request for #{agent_id}.")) unless opened
        opened
      rescue StandardError => e
        append_jump_response("Could not open delivery pull request for #{agent_id}: #{e.message}")
        false
      end

      def delivery_pr_picker_snapshot
        return nil unless @delivery_pr_picker_active

        { "active" => true, "index" => @delivery_pr_picker_index }
      end

      # --- status-bar composer ---------------------------------------------

      def open_status_bar_composer(_state)
        @status_bar_composer_draft = StatusBarComposer::Draft.new(config)
        @status_bar_composer_active = true
        @status_bar_composer_saving = false
        @status_bar_composer_drag = nil
        close_delivery_pr_picker
        close_model_picker
        @force_full_redraw = true
        true
      rescue StandardError => e
        append_jump_response("Could not open Status bar composer: #{e.message}")
        false
      end

      def close_status_bar_composer
        @status_bar_composer_active = false
        @status_bar_composer_draft = nil
        @status_bar_composer_saving = false
        @status_bar_composer_drag = nil
        @force_full_redraw = true
        true
      end

      def status_bar_composer_snapshot
        return nil unless @status_bar_composer_active && @status_bar_composer_draft

        @status_bar_composer_draft.saving_snapshot(saving: @status_bar_composer_saving)
      end

      def handle_status_bar_composer_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        return unchanged unless @status_bar_composer_draft

        if mouse_event?(key)
          return unchanged if @status_bar_composer_saving

          return handle_status_bar_composer_mouse(key, unchanged, on_submit, state)
        end
        return unchanged if @status_bar_composer_saving

        if hard_escape_key?(key)
          close_status_bar_composer
        elsif hard_save_key?(key) || ENTER_KEYS.include?(key)
          save_status_bar_composer(on_submit, state)
        elsif TAB_KEYS.include?(key) || FOCUS_FORWARD_KEYS.include?(key)
          @status_bar_composer_draft.cycle_bar(1)
        elsif SHIFT_TAB_KEYS.include?(key) || FOCUS_BACK_KEYS.include?(key)
          @status_bar_composer_draft.cycle_bar(-1)
        elsif UP_KEYS.include?(key)
          @status_bar_composer_draft.select_item(@status_bar_composer_draft.item_index - 1)
        elsif DOWN_KEYS.include?(key)
          @status_bar_composer_draft.select_item(@status_bar_composer_draft.item_index + 1)
        elsif LEFT_KEYS.include?(key)
          @status_bar_composer_draft.move_selected(-1)
        elsif RIGHT_KEYS.include?(key) || key == " "
          @status_bar_composer_draft.move_selected(1)
        elsif HOME_KEYS.include?(key)
          @status_bar_composer_draft.move_item(@status_bar_composer_draft.item_index, 0)
        elsif END_KEYS.include?(key)
          @status_bar_composer_draft.move_item(@status_bar_composer_draft.item_index, @status_bar_composer_draft.items.length - 1)
        elsif key.to_s.downcase == "r"
          @status_bar_composer_draft.reset!
        end
        unchanged
      rescue StandardError => e
        @status_bar_composer_draft.apply_save_failure("Status bar input failed: #{e.message}")
        unchanged
      end

      def handle_status_bar_composer_mouse(key, unchanged, on_submit, state)
        if mouse_wheel_up?(key) || mouse_wheel_down?(key)
          hit = layout.status_bar_composer_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
          if hit.is_a?(Array) && hit.first == :item
            @status_bar_composer_draft.select_item(@status_bar_composer_draft.item_index + (mouse_wheel_up?(key) ? -1 : 1))
          elsif hit.is_a?(Array) && hit.first == :bar
            @status_bar_composer_draft.select_bar(@status_bar_composer_draft.bar_index + (mouse_wheel_up?(key) ? -1 : 1))
          end
          return unchanged
        end

        if mouse_button_press?(key)
          hit = layout.status_bar_composer_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
          case hit
          when :save then save_status_bar_composer(on_submit, state)
          when :cancel then close_status_bar_composer
          when :reset then @status_bar_composer_draft.reset!
          when Array
            kind, index = hit
            if kind == :bar
              @status_bar_composer_draft.select_bar(index)
              @status_bar_composer_drag = nil
            elsif kind == :item
              @status_bar_composer_draft.select_item(index)
              @status_bar_composer_drag = { bar: @status_bar_composer_draft.bar, index: index }
            end
          end
          return unchanged
        end

        if mouse_drag?(key) && @status_bar_composer_drag
          hit = layout.status_bar_composer_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
          if hit.is_a?(Array) && hit.first == :item
            @status_bar_composer_draft.move_item(@status_bar_composer_drag.fetch(:index), hit.fetch(1))
            @status_bar_composer_drag[:index] = hit.fetch(1)
          end
          return unchanged
        end

        if mouse_button_release?(key)
          @status_bar_composer_drag = nil
          return unchanged
        end

        unchanged
      end

      def save_status_bar_composer(on_submit, state)
        return false if @status_bar_composer_saving
        unless @status_bar_composer_draft.validate
          return false
        end

        changes = @status_bar_composer_draft.changes
        if changes.empty?
          close_status_bar_composer
          return true
        end

        unless on_submit
          @status_bar_composer_draft.apply_save_failure("Configuration save is unavailable in this TUI session.")
          return false
        end

        payload = {
          "base_fingerprint" => @status_bar_composer_draft.baseline_fingerprint,
          "changes" => changes
        }
        encoded = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
        @status_bar_composer_saving = true
        @status_bar_composer_draft.clear_save_failure
        submit_prompt("/config save #{encoded}", on_submit, state)
        true
      end

      # --- full-screen settings --------------------------------------------

      def github_support_enabled?(state = nil)
        explicit = config.value("experiments", "github_support")
        return explicit if explicit == true || explicit == false
        return true if config.value("settings", "schema_version").to_i < Config::Schema::VERSION
        return false unless state.is_a?(Hash)

        Array(state.fetch("issues", [])).any? { |issue| State::Models.pull_request_records_from(issue).any? }
      end

      def github_support_disabled_message
        "Enable GitHub support in Settings → Experiments to use pull request commands."
      end

      def open_settings(_state, mode: "settings", setup_origin: "manual")
        @settings_draft = Settings::Draft.new(config)
        @settings_active = true
        @settings_mode = mode.to_s == "setup" ? "setup" : "settings"
        @settings_setup_auto = @settings_mode == "setup" && setup_origin.to_s == "auto"
        @settings_setup_outcome = nil
        @settings_category_index = 0
        @settings_row_index = 0
        @settings_expanded_advanced = {}
        @settings_editor = nil
        @settings_picker = nil
        @settings_keybinding_capture = nil
        @settings_footer_focus = false
        @settings_discard_confirm = false
        @settings_saving = false
        close_delivery_pr_picker
        close_model_picker
        @force_full_redraw = true
        true
      rescue StandardError => e
        append_jump_response("Could not open #{@settings_mode == "setup" ? "Setup" : "Settings"}: #{e.message}")
        false
      end

      def close_settings(discard: false)
        @settings_draft&.restore_theme if discard
        @settings_active = false
        @settings_draft = nil
        @settings_category_index = 0
        @settings_row_index = 0
        @settings_expanded_advanced = {}
        @settings_editor = nil
        @settings_picker = nil
        @settings_keybinding_capture = nil
        @settings_footer_focus = false
        @settings_discard_confirm = false
        @settings_saving = false
        @settings_setup_auto = false
        @settings_setup_outcome = nil
        @settings_mode = "settings"
        @force_full_redraw = true
        true
      end

      def setup_mode?
        @settings_mode == "setup"
      end

      def setup_animation_phase
        return 0 unless setup_mode? && @settings_draft
        return 0 unless @settings_draft.value("appearance.animations") == true

        (monotonic_time * 3).floor % 4
      rescue StandardError
        0
      end

      def settings_categories
        return [] unless @settings_draft

        setup_mode? ? Settings::SetupFlow.steps : @settings_draft.categories
      end

      def settings_category
        categories = settings_categories
        categories[@settings_category_index.to_i.clamp(0, [categories.length - 1, 0].max)].to_s
      end

      def settings_rows
        return [] unless @settings_draft
        return setup_rows if setup_mode?

        expanded = @settings_expanded_advanced.fetch(settings_category, false)
        definitions = @settings_draft.definitions_for(settings_category, include_advanced: expanded)
        rows = definitions.map { |definition| @settings_draft.row(definition) }
        hidden = @settings_draft.definitions_for(settings_category, include_advanced: true).count(&:advanced)
        if !expanded && hidden.positive?
          rows << synthetic_settings_row(
            "_show_advanced",
            "Show advanced settings (#{hidden})",
            "Reveal #{hidden} advanced setting#{hidden == 1 ? "" : "s"} in #{settings_category}. Other categories keep their own advanced settings hidden.",
            "#{hidden} hidden"
          )
        end
        rows
      end

      def setup_rows
        case settings_category
        when "Welcome"
          [synthetic_settings_row(
            "_setup_begin",
            "Begin Setup",
            "Start choosing your setup defaults.",
            "Enter"
          )]
        else
          Settings::SetupFlow.setting_ids(settings_category).filter_map do |id|
            definition = @settings_draft.definitions.find { |candidate| candidate.id == id }
            @settings_draft.row(definition) if definition
          end
        end
      end

      def synthetic_settings_row(id, label, description, display_value, dirty: false, source: "setup")
        {
          "id" => id,
          "label" => label,
          "description" => description,
          "type" => "action",
          "editor" => "action",
          "display_value" => display_value,
          "default_value" => display_value,
          "source" => source,
          "dirty" => dirty,
          "read_only" => false,
          "apply_mode" => "none"
        }
      end

      def settings_category_counts
        settings_categories.to_h do |category|
          if setup_mode?
            rows = setup_rows
            count = category == settings_category ? rows.length : 0
            [category, { "visible" => count, "total" => count, "hidden_advanced" => 0 }]
          else
            definitions = @settings_draft.definitions_for(category, include_advanced: true)
            advanced = definitions.count(&:advanced)
            hidden = @settings_expanded_advanced.fetch(category, false) ? 0 : advanced
            visible = definitions.length - hidden
            [category, { "visible" => visible, "total" => definitions.length, "hidden_advanced" => hidden }]
          end
        end
      end

      def settings_picker_snapshot
        return nil unless @settings_picker

        @settings_picker.merge(
          "row" => @settings_picker.fetch("row", {}).merge(
            "error" => (@settings_draft ? @settings_draft.errors[@settings_picker.fetch("id")] : nil)
          ).compact
        ).compact
      end

      def settings_snapshot
        return nil unless @settings_active && @settings_draft

        rows = settings_rows
        @settings_row_index = @settings_row_index.to_i.clamp(0, [rows.length - 1, 0].max)
        counts = settings_category_counts
        current_counts = counts.fetch(settings_category, {})
        editor = if @settings_editor
                   row = @settings_editor.fetch("row", {}).merge(
                     "error" => @settings_draft.errors[@settings_editor.fetch("id")]
                   ).compact
                   @settings_editor.merge("row" => row)
                 end
        capture = if @settings_keybinding_capture
                    @settings_keybinding_capture.merge("row" => @settings_keybinding_capture.fetch("row", {}).merge(
                      "error" => @settings_keybinding_capture.fetch("error", nil)
                    ).compact)
                  end
        {
          "active" => true,
          "mode" => @settings_mode,
          "categories" => settings_categories,
          "category" => settings_category,
          "category_index" => @settings_category_index,
          "category_counts" => counts,
          "visible_setting_count" => current_counts.fetch("visible", rows.length),
          "hidden_advanced_count" => current_counts.fetch("hidden_advanced", 0),
          "rows" => rows,
          "row_index" => @settings_row_index,
          "dirty" => @settings_draft.dirty?,
          "saving" => @settings_saving,
          "advanced" => @settings_expanded_advanced.fetch(settings_category, false),
          "editor" => editor,
          "keybinding_capture" => capture,
          "picker" => settings_picker_snapshot,
          "footer_focus" => @settings_footer_focus,
          "setup_last_step" => setup_mode? && @settings_category_index.to_i == settings_categories.length - 1,
          "discard_confirm" => @settings_discard_confirm.is_a?(String),
          "confirmation" => (@settings_discard_confirm if @settings_discard_confirm.is_a?(String)),
          "setup_auto" => @settings_setup_auto,
          "setup_step" => setup_mode? ? @settings_category_index + 1 : nil,
          "setup_step_count" => setup_mode? ? settings_categories.length : nil,
          "setup_animations" => setup_mode? ? @settings_draft.value("appearance.animations") == true : nil,
          "setup_animation_phase" => setup_mode? ? setup_animation_phase : nil,
          "error_count" => @settings_draft.errors.length,
          "global_error" => @settings_draft.global_error,
          "width" => render_width,
          "height" => render_height
        }.compact
      end

      def handle_settings_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        if render_width < Settings::MIN_WIDTH || render_height < Settings::MIN_HEIGHT
          close_settings(discard: true) if hard_escape_key?(key)
          return unchanged
        end
        if @settings_keybinding_capture
          return handle_settings_keybinding_capture_key(key, unchanged)
        end
        if @settings_picker
          return handle_settings_picker_key(key, unchanged, on_submit, state)
        end
        return handle_settings_mouse(key, unchanged, on_submit, state) if mouse_event?(key)

        if @settings_discard_confirm.is_a?(String)
          if ENTER_KEYS.include?(key)
            if @settings_discard_confirm == "skip"
              @settings_discard_confirm = false
              save_settings(on_submit, state, onboarding_outcome: "skipped")
            else
              close_settings(discard: true)
            end
          elsif hard_escape_key?(key)
            @settings_discard_confirm = false
          end
          return unchanged
        end

        if @settings_editor
          return handle_settings_editor_key(key, unchanged, on_submit, state)
        end

        rows = settings_rows
        if hard_save_key?(key)
          setup_mode? ? setup_next_or_finish(on_submit, state) : save_settings(on_submit, state)
        elsif hard_escape_key?(key)
          request_settings_cancel
        elsif setup_mode? && (BACKSPACE_KEYS.include?(key) || DELETE_KEYS.include?(key))
          move_settings_category(-1)
        elsif TAB_KEYS.include?(key) || FOCUS_FORWARD_KEYS.include?(key)
          move_settings_category(1)
        elsif SHIFT_TAB_KEYS.include?(key)
          move_settings_category(-1)
        elsif UP_KEYS.include?(key) || keybinding?("suggestion_previous", key)
          move_settings_row(-1)
        elsif DOWN_KEYS.include?(key) || keybinding?("suggestion_next", key)
          move_settings_row(1)
        elsif PAGE_UP_KEYS.include?(key)
          move_settings_row(-settings_page_size)
        elsif PAGE_DOWN_KEYS.include?(key)
          move_settings_row(settings_page_size)
        elsif HOME_KEYS.include?(key)
          @settings_row_index = 0
          @settings_footer_focus = false
        elsif END_KEYS.include?(key)
          @settings_row_index = [rows.length - 1, 0].max
          @settings_footer_focus = false
        elsif LEFT_KEYS.include?(key)
          cycle_or_move_settings(-1, state)
        elsif RIGHT_KEYS.include?(key)
          cycle_or_move_settings(1, state)
        elsif key == " "
          activate_settings_row(state, toggle_only: true, on_submit: on_submit) unless setup_mode?
        elsif ENTER_KEYS.include?(key)
          if setup_mode? && @settings_footer_focus
            setup_next_or_finish(on_submit, state)
          else
            activate_settings_row(state, on_submit: on_submit)
          end
        elsif key.to_s.downcase == "a" && !setup_mode?
          category = settings_category
          if @settings_draft.definitions_for(category, include_advanced: true).any?(&:advanced)
            @settings_expanded_advanced[category] = !@settings_expanded_advanced.fetch(category, false)
            @settings_row_index = 0
          end
        end
        unchanged
      rescue StandardError => e
        @settings_draft&.apply_save_failure("Settings input failed: #{e.message}")
        unchanged
      end

      def handle_settings_keybinding_capture_key(key, unchanged)
        capture = @settings_keybinding_capture
        if mouse_event?(key)
          capture["error"] = "Mouse input cannot be bound here; press a keyboard key, Esc, or Backspace."
          return unchanged
        end
        if key == "\e"
          @settings_keybinding_capture = nil
          return unchanged
        end
        if BACKSPACE_KEYS.include?(key) || DELETE_KEYS.include?(key)
          id = capture.fetch("id")
          @settings_draft.set(id, [])
          @settings_keybinding_capture = nil unless @settings_draft.errors.key?(id)
          capture["error"] = @settings_draft.errors[id] if @settings_keybinding_capture
          return unchanged
        end

        name = Keybindings.capture_name(key)
        unless name
          capture["error"] = "That input cannot be used as a keybinding; press one key at a time."
          return unchanged
        end

        id = capture.fetch("id")
        @settings_draft.set(id, [name])
        if @settings_draft.errors.key?(id)
          capture["error"] = @settings_draft.errors[id]
        else
          @settings_keybinding_capture = nil
        end
        unchanged
      end

      def handle_settings_editor_key(key, unchanged, on_submit, state)
        editor = @settings_editor
        if hard_escape_key?(key)
          @settings_editor = nil
          return unchanged
        end
        if hard_save_key?(key)
          if apply_settings_editor
            @settings_editor = nil
            setup_mode? ? setup_next_or_finish(on_submit, state) : save_settings(on_submit, state)
          end
          return unchanged
        end
        if ENTER_KEYS.include?(key)
          @settings_editor = nil if apply_settings_editor
          return unchanged
        end
        if paste_key?(key)
          insert_settings_editor_text(paste_text(key))
          return unchanged
        end
        if keybinding?("delete_backward", key)
          chars = editor.fetch("buffer").chars
          cursor = editor.fetch("cursor").to_i
          if cursor.positive?
            chars.delete_at(cursor - 1)
            editor["buffer"] = chars.join
            editor["cursor"] = cursor - 1
          end
          return unchanged
        end
        if LEFT_KEYS.include?(key)
          editor["cursor"] = [editor.fetch("cursor").to_i - 1, 0].max
          return unchanged
        end
        if RIGHT_KEYS.include?(key)
          editor["cursor"] = [editor.fetch("cursor").to_i + 1, editor.fetch("buffer").chars.length].min
          return unchanged
        end
        if printable_key?(key)
          insert_settings_editor_text(key)
          return unchanged
        end
        unchanged
      end

      def insert_settings_editor_text(text)
        editor = @settings_editor
        chars = editor.fetch("buffer").chars
        cursor = editor.fetch("cursor").to_i.clamp(0, chars.length)
        insertion = text.to_s.chars
        chars.insert(cursor, *insertion)
        editor["buffer"] = chars.join
        editor["cursor"] = cursor + insertion.length
      end

      def apply_settings_editor
        id = @settings_editor.fetch("id")
        applied = @settings_draft.parse_editor(id, @settings_editor.fetch("buffer"))
        @settings_draft.preview_theme if id == "appearance.theme" && applied
        !applied.nil?
      end

      def handle_settings_mouse(key, unchanged, on_submit, state)
        if mouse_wheel_up?(key) || mouse_wheel_down?(key)
          hit = layout.settings_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
          move_settings_row(mouse_wheel_up?(key) ? -3 : 3) unless hit == :inert
          return unchanged
        end
        return unchanged unless mouse_button_press?(key) && key.fetch("button", 0).to_i.zero?

        hit = layout.settings_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        case hit
        when :save, :next
          setup_mode? ? setup_next_or_finish(on_submit, state) : save_settings(on_submit, state)
        when :back
          setup_mode? ? move_settings_category(-1) : request_settings_cancel
        when :cancel
          request_settings_cancel
        when Array
          kind, index = hit
          if kind == :picker
            option = Array(@settings_picker&.fetch("options", []))[index.to_i]
            if option
              id = @settings_picker.fetch("id")
              value = option.is_a?(Hash) ? option.fetch("reference") : option
              @settings_draft.set(id, value)
              @settings_draft.preview_theme if id == "appearance.theme"
              @settings_picker = nil
            end
          elsif kind == :category
            @settings_category_index = index.to_i.clamp(0, [settings_categories.length - 1, 0].max)
            @settings_row_index = 0
          elsif %i[row toggle].include?(kind)
            @settings_row_index = index.to_i.clamp(0, [settings_rows.length - 1, 0].max)
            @settings_footer_focus = false
            activate_settings_row(state, toggle_only: kind == :toggle, on_submit: on_submit)
          end
        end
        unchanged
      end

      def hard_escape_key?(key)
        key == "\e" || keybinding?("cancel_navigation", key)
      end

      def hard_save_key?(key)
        CTRL_S_KEYS.include?(key)
      end

      def move_settings_category(delta)
        count = settings_categories.length
        return if count.zero?

        @settings_category_index = if setup_mode?
                                     (@settings_category_index.to_i + delta.to_i).clamp(0, count - 1)
                                   else
                                     (@settings_category_index.to_i + delta.to_i) % count
                                   end
        @settings_row_index = 0
        @settings_footer_focus = false
      end

      def move_settings_row(delta)
        count = settings_rows.length
        return if count.zero?

        if setup_mode?
          if delta.to_i.positive?
            if @settings_footer_focus
              return
            elsif @settings_row_index.to_i >= count - 1
              @settings_footer_focus = true
            else
              @settings_row_index += 1
            end
          elsif delta.to_i.negative?
            if @settings_footer_focus
              @settings_footer_focus = false
              @settings_row_index = [count - 1, 0].max
            else
              @settings_row_index = [@settings_row_index.to_i - 1, 0].max
            end
          end
          return
        end

        @settings_row_index = (@settings_row_index.to_i + delta.to_i) % count
      end

      def settings_page_size
        [render_height - 8, 1].max
      end

      def selected_settings_row
        rows = settings_rows
        rows[@settings_row_index.to_i.clamp(0, [rows.length - 1, 0].max)]
      end

      def cycle_or_move_settings(delta, state)
        return if setup_mode? && @settings_footer_focus

        row = selected_settings_row
        return move_settings_row(delta) if setup_mode? && !row

        if setup_mode?
          if row.fetch("editor", nil) == "checkbox"
            @settings_draft.set(row.fetch("id"), delta.to_i.positive?)
          else
            # In Setup, horizontal movement never changes pages. It either changes
            # a focused boolean toggle or moves focus to another control.
            move_settings_row(delta)
          end
          return
        end

        return move_settings_category(delta) unless row
        if %w[selector enum].include?(row.fetch("editor", nil))
          @settings_draft.cycle(row.fetch("id"), delta)
          @settings_draft.preview_theme if row.fetch("id") == "appearance.theme"
        elsif row.fetch("editor", nil) == "model"
          cycle_settings_model(row, delta, state)
        else
          move_settings_category(delta)
        end
      end

      # The model list a settings row should offer belongs to the harness that row is about, so a
      # user editing the worker model is never shown another backend's catalog.
      def settings_model_harness
        Harness::Registry.new(config: config).worker_provider
      rescue StandardError
        nil
      end

      def cycle_settings_model(row, delta, state)
        options = ModelPicker.entries(state, harness: settings_model_harness, query: "").map { |entry| entry.fetch("reference") }
        current = @settings_draft.value(row.fetch("id")).to_s
        options.unshift(current) unless options.include?(current)
        return if options.empty?

        index = options.index(current) || 0
        @settings_draft.set(row.fetch("id"), options[(index + delta.to_i) % options.length])
      end

      def activate_settings_row(state, toggle_only: false, on_submit: nil)
        row = selected_settings_row
        return false unless row

        id = row.fetch("id")
        if id == "_show_advanced"
          @settings_expanded_advanced[settings_category] = true
          @settings_row_index = 0
          return true
        end
        if id == "setup.run_again"
          close_settings(discard: true)
          return handle_local_setup_command(state)
        end
        if id == "_setup_begin"
          move_settings_category(1)
          return true
        end
        return false if row.fetch("read_only", false)

        case row.fetch("editor", nil)
        when "checkbox"
          @settings_draft.toggle(id)
        when "keybinding"
          return false if toggle_only
          open_settings_keybinding_capture(row)
        when "selector", "model"
          return false if toggle_only
          setup_mode? ? open_settings_picker(row, state) : (row.fetch("editor") == "model" ? open_settings_editor(row) : @settings_draft.cycle(id, 1))
          @settings_draft.preview_theme if id == "appearance.theme" && !@settings_picker
        else
          return false if toggle_only
          open_settings_editor(row)
        end
        true
      end

      def focus_setup_setting(id)
        step = Settings::SetupFlow.step_for_setting(id)
        return false unless step

        @settings_category_index = settings_categories.index(step) || 0
        @settings_row_index = settings_rows.index { |row| row.fetch("id", nil) == id.to_s } || 0
        true
      end

      def open_settings_picker(row, state)
        id = row.fetch("id")
        options = if row.fetch("editor") == "model"
                    ModelPicker.entries(state, harness: "pi", query: "").map do |entry|
                      { "reference" => entry.fetch("reference"), "name" => entry.fetch("name", entry.fetch("reference")) }
                    end
                  else
                    Array(row.fetch("options", [])).map(&:to_s)
                  end
        current = @settings_draft.value(id).to_s
        unless options.any? { |option| option.is_a?(Hash) ? option.fetch("reference") == current : option == current }
          options.unshift(row.fetch("editor") == "model" ? { "reference" => current, "name" => current } : current)
        end
        @settings_picker = {
          "id" => id,
          "row" => row,
          "options" => options,
          "index" => [options.index { |option| option.is_a?(Hash) ? option.fetch("reference") == current : option == current } || 0, 0].max
        }
        true
      end

      def handle_settings_picker_key(key, unchanged, _on_submit, _state)
        if mouse_event?(key)
          return handle_settings_mouse(key, unchanged, _on_submit, _state)
        end
        options = Array(@settings_picker.fetch("options", []))
        if UP_KEYS.include?(key)
          @settings_picker["index"] = (@settings_picker.fetch("index", 0).to_i - 1) % [options.length, 1].max
        elsif DOWN_KEYS.include?(key)
          @settings_picker["index"] = (@settings_picker.fetch("index", 0).to_i + 1) % [options.length, 1].max
        elsif ENTER_KEYS.include?(key)
          option = options[@settings_picker.fetch("index", 0).to_i]
          if option
            id = @settings_picker.fetch("id")
            value = option.is_a?(Hash) ? option.fetch("reference") : option
            @settings_draft.set(id, value)
            @settings_draft.preview_theme if id == "appearance.theme"
            @settings_picker = nil
          end
        elsif hard_escape_key?(key) || BACKSPACE_KEYS.include?(key) || DELETE_KEYS.include?(key)
          @settings_picker = nil
        end
        unchanged
      end

      def open_settings_keybinding_capture(row)
        @settings_draft.errors.delete(row.fetch("id"))
        @settings_keybinding_capture = {
          "id" => row.fetch("id"),
          "row" => row,
          "error" => nil
        }
      end

      def open_settings_editor(row)
        id = row.fetch("id")
        text = @settings_draft.editor_text(id)
        @settings_editor = {
          "id" => id,
          "row" => row,
          "buffer" => text,
          "cursor" => text.chars.length
        }
      end

      def request_settings_cancel
        if setup_mode?
          if @settings_setup_auto
            @settings_discard_confirm = "skip"
          elsif @settings_draft&.dirty?
            @settings_discard_confirm = "discard"
          else
            close_settings(discard: true)
          end
          return true
        end

        return close_settings(discard: true) unless @settings_draft&.dirty?

        @settings_discard_confirm = "discard"
        true
      end

      def setup_next_or_finish(on_submit, state)
        if setup_mode? && @settings_category_index.to_i >= settings_categories.length - 1
          save_settings(on_submit, state, onboarding_outcome: "completed")
        else
          move_settings_category(1)
        end
      end

      def save_settings(on_submit, state, onboarding_outcome: nil)
        return false if @settings_saving
        unless @settings_draft.validate
          first_id = @settings_draft.errors.keys.first
          focus_settings_id(first_id) if first_id
          return false
        end

        changes = @settings_draft.changes
        unless onboarding_outcome.to_s.empty?
          explicit_experiments = Settings::SetupFlow.experiment_defaults(@settings_draft, explicit_only: true)
          changes = onboarding_outcome == "skipped" ? explicit_experiments : changes.merge(explicit_experiments)
        end
        if changes.empty? && onboarding_outcome.to_s.empty?
          close_settings(discard: false)
          return true
        end

        payload = {
          "base_fingerprint" => @settings_draft.baseline_fingerprint,
          "changes" => changes
        }
        payload["onboarding_outcome"] = onboarding_outcome unless onboarding_outcome.to_s.empty?
        encoded = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
        @settings_saving = true
        @settings_setup_outcome = onboarding_outcome
        @settings_draft.clear_save_failure
        submit_prompt("/config save #{encoded}", on_submit, state)
        true
      end

      def focus_settings_id(id)
        return focus_setup_setting(id) if setup_mode?

        definition = @settings_draft.definitions.find { |candidate| candidate.id == id.to_s }
        return unless definition

        if definition.advanced
          @settings_expanded_advanced[definition.category] = true
        end
        @settings_category_index = settings_categories.index(definition.category) || 0
        @settings_row_index = settings_rows.index { |row| row.fetch("id", nil) == definition.id } || 0
      end

      # --- first-run setup --------------------------------------------------

      def frame_refresh_interval(_state)
        if @agent_workspace_active && (@agent_workspace_interactive || @agent_workspace_view == "terminal")
          return TERMINAL_REFRESH_INTERVAL
        end

        REFRESH_INTERVAL
      end

      # Auto-open decision, made once per launch. It never opens when the config
      # already carries the marker, when there is no kernel behind the UI, or when
      # the terminal is too small to draw the popup at all.
      def maybe_open_onboarding(state_provider)
        return false unless onboarding_autostart?

        state = state_provider.call || State::Models.empty_state
        open_settings(state, mode: "setup", setup_origin: "auto")
      end

      def onboarding_autostart?
        return false unless @onboarding_enabled
        # No harness means the app cannot route work yet, so force setup open
        # even when a prior onboarding marker exists. Setup is the only path
        # that persists a harness through the kernel.
        return true unless harness_configured?
        return false if Onboarding.completed?(config)

        width, height = terminal.dimensions
        Onboarding.fits?(width: width, height: height)
      end

      def harness_configured?
        @harness_configured_check.call ? true : false
      end

      # Compatibility seam for tests/extensions that opened the old controller
      # directly. Setup now opens the curated transactional Settings mode.
      def open_onboarding(state)
        open_settings(state, mode: "setup", setup_origin: "manual")
      end

      def setup_command?(text)
        text.to_s.strip.downcase == "/setup"
      end

      # Bare `/setup` is local UI. `/setup complete|skip` remain compatibility
      # kernel commands for scripts, while the interactive flow saves its marker
      # together with the reviewed draft in one SaveConfiguration transaction.
      def handle_local_setup_command(state)
        unless @onboarding_enabled
          append_jump_response(Onboarding.unavailable_message)
          return true
        end

        unless onboarding_fits?
          append_jump_response(Onboarding.collapsed_message)
          return true
        end

        open_settings(state, mode: "setup", setup_origin: "manual")
        true
      end

      def onboarding_fits?
        Onboarding.fits?(width: render_width, height: render_height)
      end

      def model_picker_snapshot
        return nil unless @model_picker_active

        {
          "active" => true,
          "index" => @model_picker_index,
          "query" => @model_picker_query.to_s,
          "harness" => @model_picker_harness,
          "role" => @model_picker_role,
          "kind" => @model_picker_kind
        }.compact
      end

      # Model and choice pickers always open, even when their source cannot give
      # us a catalog/list: an explicit explanation inside the popup is the useful
      # answer, and a chat line or blank popup is not. The model path reads the
      # kernel-cached snapshot, so opening it never starts a harness process.
      def open_model_picker(state, harness: nil, role: nil)
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = harness.to_s.strip.empty? ? nil : harness.to_s.strip
        @model_picker_role = %w[head worker].include?(role.to_s.downcase) ? role.to_s.downcase : "head"
        @model_picker_kind = "model"
        close_delivery_pr_picker
        true
      end

      def open_thinking_picker(state, role: nil)
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = %w[head worker].include?(role.to_s.downcase) ? role.to_s.downcase : "head"
        @model_picker_kind = "thinking"
        close_delivery_pr_picker
        true
      end

      def open_theme_picker(state)
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = "head"
        @model_picker_kind = "theme"
        close_delivery_pr_picker
        true
      end

      def open_harness_picker(state, role: nil)
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = %w[head worker].include?(role.to_s.downcase) ? role.to_s.downcase : "head"
        @model_picker_kind = "harness"
        close_delivery_pr_picker
        true
      end

      def close_model_picker
        @model_picker_active = false
        @model_picker_query = +""
        @model_picker_index = 0
        @model_picker_harness = nil
        @model_picker_role = "head"
        @model_picker_kind = "model"
      end

      def model_picker_entries(state)
        case @model_picker_kind
        when "thinking"
          ModelPicker.thinking_entries(state, role: @model_picker_role, query: @model_picker_query)
        when "theme"
          Style.colorschemes.filter_map.with_index do |theme, index|
            next unless @model_picker_query.to_s.empty? || theme.downcase.include?(@model_picker_query.to_s.downcase)

            {
              "reference" => theme,
              "name" => theme,
              "current" => theme == Style.current_colorscheme,
              "description" => theme == Style.current_colorscheme ? "current theme" : "future dashboard theme",
              "index" => index
            }
          end
        when "harness"
          query = @model_picker_query.to_s.downcase
          Harness::Registry.provider_choices.filter_map.with_index do |choice, index|
            provider = choice.fetch("provider")
            label = choice.fetch("label")
            next unless query.empty? || provider.downcase.include?(query) || label.downcase.include?(query)

            {
              "reference" => provider,
              "name" => label,
              "description" => choice.fetch("description", "future #{(@model_picker_role || "head")} harness"),
              "index" => index
            }
          end
        else
          ModelPicker.entries(
            state,
            harness: @model_picker_harness,
            query: @model_picker_query,
            role: @model_picker_role
          )
        end
      end

      # A modal list that owns typing while it is up: printable keys filter it,
      # arrows move, Enter applies the model, Ctrl-R re-fetches the catalog, and
      # Esc closes. Unlike the open-PR picker it does not close on any other key,
      # because typing here is the search box rather than the composer.
      def handle_model_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        entries = model_picker_entries(state)
        return handle_model_picker_mouse(key, unchanged, on_submit, state, entries) if mouse_event?(key)

        if keybinding?("cursor_left", key)
          switch_model_picker_role(-1)
          return unchanged
        end
        if keybinding?("cursor_right", key)
          switch_model_picker_role(1)
          return unchanged
        end
        if keybinding?("suggestion_previous", key)
          move_model_picker(-1, entries.length)
          return unchanged
        end
        if keybinding?("suggestion_next", key)
          move_model_picker(1, entries.length)
          return unchanged
        end
        if keybinding?("refresh_model_catalog", key)
          if @model_picker_kind == "model" || @model_picker_kind == "thinking"
            refresh_model_catalog(on_submit, state)
          end
          return unchanged
        end
        if keybinding?("submit", key)
          apply_model_picker_entry(selected_model_picker_entry(entries), on_submit, state)
          return unchanged
        end
        if keybinding?("cancel_navigation", key)
          close_model_picker
          return unchanged
        end
        if keybinding?("delete_word_backward", key)
          @model_picker_query = +""
          @model_picker_index = 0
          return unchanged
        end
        if keybinding?("delete_backward", key)
          @model_picker_query = @model_picker_query.to_s.chars[0...-1].join
          @model_picker_index = 0
          return unchanged
        end
        if printable_key?(key)
          @model_picker_query = "#{@model_picker_query}#{key}"
          @model_picker_index = 0
          return unchanged
        end

        close_model_picker
        nil
      end

      def handle_model_picker_mouse(key, unchanged, on_submit, state, entries)
        return unchanged unless mouse_button_press?(key) || mouse_wheel?(key)

        hit = layout.model_picker_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        if mouse_wheel?(key)
          return nil if hit == :outside

          move_model_picker(mouse_wheel_up?(key) ? -1 : 1, entries.length)
          return unchanged
        end

        if hit.is_a?(Integer)
          apply_model_picker_entry(entries[hit], on_submit, state)
        elsif hit == :outside
          close_model_picker
        end
        unchanged
      end

      def move_model_picker(step, count)
        return if count <= 0

        @model_picker_index = (@model_picker_index.to_i + step) % count
      end

      def switch_model_picker_role(step)
        roles = %w[head worker]
        index = roles.index(@model_picker_role) || 0
        @model_picker_role = roles[(index + step.to_i) % roles.length]
        @model_picker_index = 0
        @model_picker_query = +""
      end

      def selected_model_picker_entry(entries)
        return nil if entries.empty?

        entries[@model_picker_index.to_i.clamp(0, entries.length - 1)]
      end

      # Selecting a row is exactly `/model <provider/model>`: the same parser, the
      # same `SetDefaultSessionModel` validation, the same journaling, and the same
      # log line. The picker never writes session defaults itself.
      def apply_model_picker_entry(entry, on_submit, state)
        unless entry
          # Expected unavailability (no catalog, or a query that matched nothing)
          # is already rendered inside the popup. Do not duplicate it in chat.
          return false
        end

        kind = @model_picker_kind
        role = @model_picker_role
        close_model_picker
        command = case kind
                  when "thinking"
                    "/thinking #{role} #{entry.fetch("level")}"
                  when "theme"
                    "/theme #{entry.fetch("reference")}"
                  when "harness"
                    "/harness #{role} #{entry.fetch("reference")}"
                  else
                    "/model #{role} #{entry.fetch("reference")}"
                  end
        submit_prompt(command, on_submit, state)
        true
      end

      # Refreshing is the kernel's job: the picker submits `/models refresh`, the
      # kernel re-asks the harness and persists the snapshot, and the next frame
      # renders the new list. The picker stays open while that happens.
      def refresh_model_catalog(on_submit, state)
        command = ["/models", @model_picker_harness, "refresh"].compact.join(" ")
        submit_prompt(command, on_submit, state)
        true
      end

      def open_delivery_pr_picker(state)
        unless github_support_enabled?(state)
          append_jump_response(github_support_disabled_message)
          return false
        end

        entries = OpenPullRequests.entries(state)
        # Keep the empty explanation in the same bordered popup as a populated
        # picker. Previously `/prs`/Ctrl-B appended this expected state to chat,
        # which made the picker contract depend on whether a PR happened to be
        # available at that instant.
        @delivery_pr_picker_active = true
        @delivery_pr_picker_index = @delivery_pr_picker_index.to_i.clamp(0, [entries.length - 1, 0].max)
        return true if entries.empty?

        true
      end

      def close_delivery_pr_picker
        @delivery_pr_picker_active = false
      end

      # A small modal list: it owns the arrow keys, Enter, Esc, and clicks while it
      # is up. Any other key closes it and is then handled normally, so the picker
      # can never trap the composer.
      def handle_delivery_pr_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        entries = OpenPullRequests.entries(state)
        return handle_delivery_pr_picker_mouse(key, unchanged, state, entries) if mouse_event?(key)

        if keybinding?("suggestion_previous", key)
          move_delivery_pr_picker(-1, entries.length)
          return unchanged
        end
        if keybinding?("suggestion_next", key)
          move_delivery_pr_picker(1, entries.length)
          return unchanged
        end
        if keybinding?("submit", key)
          open_delivery_pr_entry(selected_delivery_pr_entry(entries))
          close_delivery_pr_picker
          return unchanged
        end
        if keybinding?("cancel_navigation", key) || keybinding?("open_delivery_pr", key)
          close_delivery_pr_picker
          return unchanged
        end

        close_delivery_pr_picker
        nil
      end

      def handle_delivery_pr_picker_mouse(key, unchanged, state, entries)
        return unchanged unless mouse_button_press?(key) || mouse_wheel?(key)

        hit = layout.delivery_pr_picker_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        if mouse_wheel?(key)
          return nil if hit == :outside

          move_delivery_pr_picker(mouse_wheel_up?(key) ? -1 : 1, entries.length)
          return unchanged
        end

        # Click-away dismisses; a click on a row opens it.
        if hit.is_a?(Integer)
          open_delivery_pr_entry(entries[hit])
          close_delivery_pr_picker
        elsif hit == :outside
          close_delivery_pr_picker
        end
        unchanged
      end

      def move_delivery_pr_picker(step, count)
        return if count <= 0

        @delivery_pr_picker_index = (@delivery_pr_picker_index.to_i + step) % count
      end

      # The list is rebuilt from state every frame, so a PR that merged (and left
      # the list) must not leave the highlight pointing past the end.
      def selected_delivery_pr_entry(entries)
        return nil if entries.empty?

        entries[@delivery_pr_picker_index.to_i.clamp(0, entries.length - 1)]
      end

      def open_delivery_pr_entry(entry)
        return false unless entry
        return false unless github_support_enabled?

        result = pull_request_opener.open(entry.fetch("url"))
        return true if open_succeeded?(result)

        append_jump_response(result.fetch("message", "Could not open pull request ##{entry.fetch("number", "?")}."))
        false
      rescue StandardError => e
        append_jump_response("Could not open pull request ##{entry.fetch("number", "?")}: #{e.message}")
        false
      end

      def open_pr_by_agent_id(state, agent_id, silent_fail: false)
        unless github_support_enabled?(state)
          append_jump_response(github_support_disabled_message) unless silent_fail
          return false
        end

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
        # Opening a PR is a transient UI action: only failures are worth a log entry.
        return true if open_succeeded?(result)

        append_jump_response(result.fetch("message", "Could not open pull request for #{agent_id}.")) unless silent_fail
        false
      rescue StandardError => e
        append_jump_response("Could not open pull request for #{agent_id}: #{e.message}") unless silent_fail
        false
      end

      def open_succeeded?(result)
        status = result.is_a?(Hash) ? result.fetch("status", nil).to_s : ""
        !%w[failed rejected].include?(status)
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

      # The registry that owns collapsed pastes for whichever composer is taking
      # keys. The focused workspace and the dashboard each number and clear their
      # own pastes, so neither can expand a marker the other still shows.
      def paste_registry
        @agent_workspace_active ? @workspace_pastes : @chat_pastes
      end

      # The single funnel for every paste entry point: bracketed paste, the
      # plain-text fallback used by terminals without it, and the clipboard
      # keybinding. Anything large is parked in the registry and only its marker
      # reaches the buffer, so no later frame ever wraps the pasted body.
      def insert_pasted_text(input_buffer, input_cursor, text)
        registry = paste_registry
        registry.sync!(input_buffer)
        normalized = normalize_input_text(text)
        insert_text(input_buffer, input_cursor, registry.collapse(normalized))
      end

      def normalize_input_text(text)
        text.to_s.gsub("\r\n", "\n").tr("\r", "\n")
      end

      def insert_text(input_buffer, input_cursor, text)
        normalized = normalize_input_text(text)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        chars.insert(cursor, *normalized.chars)
        [chars.join, cursor + normalized.length]
      end

      # Deletions run through one range so a paste marker is always removed whole:
      # half a marker would be text that no longer expands to anything.
      def delete_range(input_buffer, range)
        range = paste_registry.expand_range(input_buffer, range)
        return [input_buffer, range.first] if range.first >= range.last

        chars = input_buffer.chars
        chars.slice!(range.first...range.last)
        [chars.join, range.first]
      end

      def delete_backward(input_buffer, input_cursor)
        cursor = clamp_cursor(input_buffer, input_cursor)
        return [input_buffer, cursor] if cursor.zero?

        delete_range(input_buffer, ((cursor - 1)...cursor))
      end

      def delete_forward(input_buffer, input_cursor)
        cursor = clamp_cursor(input_buffer, input_cursor)
        return [input_buffer, cursor] if cursor >= input_buffer.to_s.length

        delete_range(input_buffer, (cursor...(cursor + 1)))
      end

      def delete_backward_word(input_buffer, input_cursor)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        start_index = previous_word_boundary(chars, cursor)
        return [input_buffer, cursor] if start_index == cursor

        delete_range(input_buffer, (start_index...cursor))
      end

      def delete_forward_word(input_buffer, input_cursor)
        chars = input_buffer.chars
        cursor = clamp_cursor(input_buffer, input_cursor)
        finish_index = next_word_boundary(chars, cursor)
        return [input_buffer, cursor] if finish_index == cursor

        buffer, _cursor = delete_range(input_buffer, (cursor...finish_index))
        [buffer, cursor]
      end

      def cursor_after_navigation(key, input_buffer, input_cursor, state: nil, visual_rows: false)
        cursor = clamp_cursor(input_buffer, input_cursor)
        chars = input_buffer.chars

        moved = if keybinding?("cursor_left", key) then [cursor - 1, 0].max
                elsif keybinding?("cursor_right", key) then [cursor + 1, chars.length].min
                elsif keybinding?("cursor_up", key)
                  visual_rows ? composer_vertical_cursor(state, input_buffer, cursor, :up) : cursor_up(chars, cursor)
                elsif keybinding?("cursor_down", key)
                  visual_rows ? composer_vertical_cursor(state, input_buffer, cursor, :down) : cursor_down(chars, cursor)
                elsif keybinding?("cursor_home", key) then current_line_start(chars, cursor)
                elsif keybinding?("cursor_end", key) then current_line_end(chars, cursor)
                elsif keybinding?("cursor_word_left", key) then previous_word_boundary(chars, cursor)
                elsif keybinding?("cursor_word_right", key) then next_word_start(chars, cursor)
                else cursor
                end

        # A paste marker is one unit: a step that would land inside it continues
        # to its far edge instead of parking the caret in the middle of a token.
        paste_registry.snap_cursor(input_buffer, cursor, moved)
      end

      def composer_vertical_cursor(state, input_buffer, input_cursor, direction)
        return direction == :up ? cursor_up(input_buffer.chars, input_cursor) : cursor_down(input_buffer.chars, input_cursor) unless state

        layout.composer_vertical_cursor(
          state,
          width: render_width,
          height: render_height,
          input_buffer: input_buffer,
          input_cursor: input_cursor,
          direction: direction
        )
      end

      def handle_chat_history_navigation(key, input_buffer, input_cursor, slash_suggestion_index)
        return nil unless @focused_pane == "chat"

        direction = if keybinding?("cursor_up", key)
                      :up
                    elsif keybinding?("cursor_down", key)
                      :down
                    end
        return nil unless direction
        return nil if @chat_input_history.empty?
        return nil if direction == :down && @chat_history_index.nil?

        if direction == :up
          if @chat_history_index.nil?
            @chat_history_draft = @chat_pastes.expand(input_buffer)
            @chat_history_index = @chat_input_history.length - 1
          elsif @chat_history_index.positive?
            @chat_history_index -= 1
          end
          text = @chat_input_history.fetch(@chat_history_index)
        elsif @chat_history_index < @chat_input_history.length - 1
          @chat_history_index += 1
          text = @chat_input_history.fetch(@chat_history_index)
        else
          text = @chat_history_draft.to_s
          reset_chat_history_navigation
        end

        @chat_pastes.clear!
        buffer = @chat_pastes.collapse(text)
        clear_chat_selection
        [buffer, buffer.length, slash_suggestion_index]
      end

      def remember_chat_input(text)
        value = text.to_s
        return if value.empty?

        @chat_input_history << value
        @chat_input_history.shift while @chat_input_history.length > CHAT_INPUT_HISTORY_LIMIT
        reset_chat_history_navigation
      end

      def reset_chat_history_navigation
        @chat_history_index = nil
        @chat_history_draft = nil
      end

      def clamp_cursor(input_buffer, input_cursor)
        # String#length is already the character count; `chars` here would
        # allocate one string per character on every keystroke.
        input_cursor.to_i.clamp(0, input_buffer.to_s.length)
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
        # Nothing is highlighted until the user navigates the list, so Enter submits the prompt
        # exactly as typed instead of applying the first suggestion.
        return nil unless slash_selection?(slash_suggestion_index)

        records = slash_suggestion_records(input_buffer, state)
        return nil if records.empty?

        record = records.fetch(slash_suggestion_index.clamp(0, records.length - 1))
        stripped = input_buffer.to_s.strip.gsub(/\s+/, " ")
        completion = slash_completion_for(record).strip
        appends_space = record.fetch("append_space", record.fetch("requires_arguments", false))

        # A suggestion that differs only by case is still worth applying: it recases a typed id to
        # its canonical form (/kill h83 -> /kill H83). Only an identical no-op is skipped.
        return nil if stripped == completion && !appends_space
        unless argument_suggestion_record?(record)
          return nil unless completion.downcase.start_with?(stripped.downcase) || stripped == "/"
        end

        slash_completion_for(record)
      end

      # Argument suggestions (ids for /kill, /prompt, /jump, and friends) are selected from a
      # list, so the highlighted entry should always be inserted into the input buffer even when
      # the typed query only matches the middle of the id.
      def argument_suggestion_record?(record)
        record.fetch("kind", "command") != "command"
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

      def submit_prompt(input_buffer, on_submit, state, remember_input: false)
        # Collapsed pastes are re-expanded here and nowhere else: the composer,
        # the wrapper, and the slash completer only ever saw the markers, while
        # the kernel receives the message the user actually pasted.
        text = @chat_pastes.expand(input_buffer).strip
        @chat_pastes.clear!
        return if text.empty?

        remember_chat_input(text) if remember_input
        slash_command = text.start_with?("/")
        # Without a harness the kernel cannot spawn a head, so a plain prompt
        # would fail mid-routing. Slash commands (notably /setup and /config)
        # still work so the user can pick a backend and continue.
        unless slash_command
          unless harness_configured?
            append_jump_response("No agent harness is configured. Run /setup to choose one before sending prompts.")
            return
          end
        end
        # Slash commands are explicit clutch-path instructions and never carry
        # dashboard routing context. LogScope.chat_target already normalizes an
        # absent, cleared, or unbound selection to nil, so both branches produce
        # the same "Hash or nil" shape the handler call expects.
        selected_target = slash_command ? nil : LogScope.chat_target(state)
        assistant_message_id = nil
        unless slash_command
          # This placeholder is presentation-only. Persisting it here can wait behind a kernel
          # state write and block the input thread before the background head even starts.
          assistant_message_id = append_message(
            "meringue",
            "",
            status: "queued",
            visible: false,
            persist: false
          )
        end
        submission = if on_submit&.respond_to?(:enqueue_submission)
                       on_submit.enqueue_submission(text, selected_target: selected_target)
                     end
        increment_pending_count

        Thread.new do
          begin
            update_message(
              assistant_message_id,
              text: "",
              status: "head working",
              visible: false,
              persist: false
            ) if assistant_message_id
            result = if submission && on_submit.respond_to?(:deliver_submission)
                       on_submit.deliver_submission(submission) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     elsif on_submit
                       submit_to_prompt_handler(on_submit, text, selected_target) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     else
                       unavailable_prompt_handler_result
                     end
            if slash_command
              apply_slash_command_results(result.fetch("command_results", []) || []) if result.fetch("event", nil) == "slash_command_applied"
            else
              final_text = result_logged_to_kernel?(result) ? "" : log_text_for(result)
              visible = !final_text.to_s.strip.empty?
              update_message(assistant_message_id, text: final_text, status: nil, visible: visible, persist: visible)
            end
          rescue StandardError => e
            if slash_command && text.start_with?("/config save ") && @status_bar_composer_active && @status_bar_composer_draft
              @status_bar_composer_saving = false
              @status_bar_composer_draft.apply_save_failure("Configuration save failed: #{e.class}: #{e.message}")
            elsif slash_command && text.start_with?("/config save ") && @settings_active && @settings_draft
              @settings_saving = false
              @settings_draft.apply_save_failure("Configuration save failed: #{e.class}: #{e.message}")
            elsif assistant_message_id
              update_message(assistant_message_id, text: "Head loop failed: #{e.class}: #{e.message}", status: "errored", visible: true)
            end
          ensure
            decrement_pending_count
          end
        end
      end

      # Selected dashboard chat still goes through the normal head callback. The
      # target is a keyword so it cannot be confused with user text or turn into
      # a direct PromptAgent shortcut.
      def submit_to_prompt_handler(on_submit, text, selected_target, &on_event)
        return on_submit.call(text, &on_event) if blank_selected_target?(selected_target)
        return on_submit.call(text, &on_event) unless handler_accepts_selected_target?(on_submit)

        on_submit.call(text, selected_target: selected_target, &on_event)
      end

      # nil, "", and {} all mean "nothing is selected". Normalizing here keeps a
      # stale or partially cleared value from turning a normal prompt into a
      # keyword call carrying no routing information.
      def blank_selected_target?(selected_target)
        return true if selected_target.nil?
        return selected_target.empty? if selected_target.respond_to?(:empty?)

        false
      end

      # Older embedders pass a one-argument prompt handler. Routing context is
      # additive, so degrade to an unscoped prompt instead of failing the whole
      # message with an ArgumentError only when a target happens to be selected.
      def handler_accepts_selected_target?(on_submit)
        parameters = handler_parameters(on_submit)
        return true unless parameters

        parameters.any? do |kind, name|
          kind == :keyrest || (%i[key keyreq].include?(kind) && name == :selected_target)
        end
      end

      def handler_parameters(on_submit)
        return on_submit.parameters if on_submit.respond_to?(:parameters)
        return on_submit.method(:call).parameters if on_submit.respond_to?(:call)

        nil
      rescue StandardError
        nil
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
          update_message_status(message_id, "applying commands", persist: false)
        when "head_result_applied"
          # A head may propose user commands such as /clear or /theme. Their local side effects
          # must match the typed slash path.
          apply_slash_command_results(event.fetch("command_results", []) || [])
          update_message_status(message_id, worker_wait_status(event), persist: false)
        when "slash_command_applied"
          apply_slash_command_results(event.fetch("command_results", []) || [])
        when "worker_wait_started"
          update_message_status(message_id, "workers running", persist: false)
        when "worker_completed"
          update_message_status(message_id, nil, persist: false)
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
        reload_recounted_presentation_state! if recount_accepted?(command_results)
        apply_theme_command_results(command_results)
        apply_configuration_command_results(command_results)
      end

      def apply_configuration_command_results(command_results)
        result = Array(command_results).reverse.find { |candidate| candidate.fetch("command_type", nil) == "SaveConfiguration" }
        return unless result

        if result.fetch("status", nil) == "accepted"
          outcome = result.dig("result", "onboarding_outcome") || @settings_setup_outcome
          setup_was_active = @settings_active && setup_mode?
          composer_was_active = @status_bar_composer_active
          @config = config.reload_file
          @keybindings = Keybindings.from_config(@config.section("tui", "keybindings"))
          close_settings(discard: outcome == "skipped") if @settings_active
          close_status_bar_composer if composer_was_active
          if setup_was_active && outcome
            append_jump_response(outcome == "skipped" ? Onboarding.skip_card : Onboarding.completion_card(@config))
          end
        elsif @status_bar_composer_active && @status_bar_composer_draft
          @status_bar_composer_saving = false
          details = result.fetch("result", {}) || {}
          @status_bar_composer_draft.apply_save_failure(
            result.fetch("message", "Configuration was not saved."),
            details.fetch("field_errors", {})
          )
        elsif @settings_active && @settings_draft
          @settings_saving = false
          details = result.fetch("result", {}) || {}
          @settings_draft.apply_save_failure(
            result.fetch("message", "Configuration was not saved."),
            details.fetch("field_errors", {})
          )
        end
      rescue StandardError => e
        if @status_bar_composer_active && @status_bar_composer_draft
          @status_bar_composer_saving = false
          @status_bar_composer_draft.apply_save_failure("Configuration result could not be applied: #{e.message}")
        elsif @settings_active && @settings_draft
          @settings_saving = false
          @settings_draft.apply_save_failure("Configuration result could not be applied: #{e.message}")
        end
      end

      def clear_state_accepted?(command_results)
        Array(command_results).any? do |result|
          result.fetch("command_type", nil) == "ClearState" && result.fetch("status", nil) == "accepted"
        end
      end

      def recount_accepted?(command_results)
        Array(command_results).any? do |result|
          result.fetch("command_type", nil) == "Recount" && result.fetch("status", nil) == "accepted"
        end
      end

      # A recount renames records, and the kernel rewrote the ids embedded in persisted chat
      # history and in the focused-workspace selection to match. This in-memory state is written
      # back on the next append, so it has to be re-read: otherwise the stale buffer would
      # reintroduce pre-recount ids that now name different records.
      def reload_recounted_presentation_state!
        return unless log_store&.respond_to?(:load)

        state = log_store.load
        restore_logs!(state)
        restore_agent_workspace!(state)
      rescue StandardError
        nil
      end

      def clear_logs!
        snapshot = @chat_mutex.synchronize do
          @messages = []
          @next_message_id = 0
          @log_event_keys = {}
          log_buffer_snapshot_unlocked
        end
        persist_log_snapshot(snapshot)
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
        response = head_result.fetch("response", "").to_s.strip
        questions = Array(head_result.fetch("questions", []))
        question_lines = question_user_lines(questions, question_ids: question_ids)

        [response.empty? ? nil : response, *question_lines].compact
      end

      def question_user_lines(questions, question_ids: [])
        questions.each_with_index.filter_map do |question, index|
          question_text = question.fetch("question", "").to_s.strip
          next if question_text.empty?

          question_id = question_ids[index].to_s
          label = question_id.empty? ? "Question" : "Question #{question_id}"
          context = question.fetch("context", "").to_s.strip
          [
            "#{label}: #{question_text}",
            context.empty? ? nil : "Context: #{context}",
            question_answer_hint(question_id)
          ].compact.join("\n")
        end
      end

      # Answering is a real routing action: the kernel records the answer and spawns a head that
      # continues the work. Tell the user both ways to answer so the question is not a dead end.
      def question_answer_hint(question_id)
        return "Reply here to answer, or run /answer <question_id> \"<answer>\"." if question_id.to_s.empty?

        "Reply here to answer, or run /answer #{question_id} \"<answer>\"."
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
        lines = Array(pr_urls).compact.map { |url| "PR  #{url}" }
        output = AgentOutput.normalize(last_assistant_text, source_id: agent_id, pr_urls: pr_urls)
        lines << output unless output.empty?
        lines
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

      def compose_state(state_provider, input_buffer, slash_suggestion_index = NO_SLASH_SELECTION, input_cursor = nil)
        @workspace_draft = input_buffer.to_s if @agent_workspace_active && !embedded_agent_workspace?
        state = state_provider.call || State::Models.empty_state
        sync_state_logs!(state)
        complete_pending_workspace_closes
        if @agent_tree_navigation_active
          ids = agent_tree_selectable_agent_ids(state)
          @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
          @agent_tree_navigation_active = false if ids.empty?
        end
        reconcile_workspace_selection!(state)
        reconcile_log_scope!(state)
        composed_state = state.merge(
          "_chat" => chat_snapshot(input_buffer, slash_suggestion_index, input_cursor),
          Settings::STATE_KEY => settings_snapshot,
          StatusBarComposer::STATE_KEY => status_bar_composer_snapshot,
          "_status_bar_layout" => StatusBarLayout.from_config(config),
          "_capabilities" => { "github_support" => github_support_enabled?(state) },
          "_agent_tree_navigation" => agent_tree_navigation_snapshot,
          LogScope::STATE_KEY => LogScope.snapshot(state, @log_scope_id),
          "_agent_workspace" => agent_workspace_snapshot(state, input_buffer, input_cursor, slash_suggestion_index),
          "_scroll" => scroll_snapshot,
          "_selection" => selection_snapshot
        )
        clamp_scroll_offsets!(composed_state)
        # Reveal reads the offsets it is about to adjust, so it runs against the
        # clamped snapshot instead of the pre-clamp one.
        reveal_selected_agent_tree_item!(composed_state.merge("_scroll" => scroll_snapshot))
        composed_state.merge("_scroll" => scroll_snapshot)
      end

      # A newly selected AgentTree item scrolls into view by the minimum amount,
      # the same way the logs caret reveals its line. Reveal only runs when the
      # selection actually changed, so scrolling by hand is never yanked back.
      def reveal_selected_agent_tree_item!(state)
        selected_id = revealable_agent_tree_item_id
        if selected_id.to_s.empty?
          @revealed_agent_tree_item_id = nil
          return
        end
        return if @revealed_agent_tree_item_id.to_s == selected_id.to_s

        @revealed_agent_tree_item_id = selected_id
        reveal_agent_tree_item(state, selected_id)
      end

      # Whichever row is rendered as selected: the jump-mode cursor while it is
      # active, otherwise the sticky selection that scopes the logs pane. The
      # sticky row outlives jump mode, so it still deserves to be revealed.
      def revealable_agent_tree_item_id
        return @selected_agent_id if @agent_tree_navigation_active && !@selected_agent_id.to_s.empty?

        @log_scope_id
      end

      def reveal_agent_tree_item(state, item_id)
        range = layout.agent_tree_item_line_range(state, width: render_width, height: render_height, item_id: item_id)
        return unless range

        offset = layout.agent_tree_scroll_offset_for_line(
          state,
          width: render_width,
          height: render_height,
          line_index: range.first,
          last_line_index: range.last
        )
        @scroll_offsets["agent_tree"] = offset.to_i unless offset.nil?
      end

      def complete_pending_workspace_closes
        results = @chat_mutex.synchronize do
          pending = @agent_workspace_close_results
          @agent_workspace_close_results = []
          pending
        end
        failed = results.reverse.find do |result|
          %w[failed rejected errored].include?(result.fetch("status", nil).to_s)
        end
        return unless failed

        set_selection_status(failed.fetch("message", "Could not restore dashboard session ownership."))
      end

      def complete_pending_workspace_open(state)
        pending = @chat_mutex.synchronize do
          result = @agent_workspace_open_result
          @agent_workspace_open_result = nil
          result
        end
        return unless pending

        open_generation, agent_id, result = pending
        return unless @agent_workspace_open_pending && open_generation == @agent_workspace_open_generation && agent_id == @agent_workspace_agent_id.to_s

        @agent_workspace_open_pending = false
        apply_workspace_controller_result(result)
        if %w[failed rejected errored cancelled].include?(result.fetch("status", nil).to_s)
          message = result.fetch("message", "Could not open focused workspace.").to_s
          set_selection_status(message)
          @agent_workspace_active = false
          @agent_workspace_interactive = false
          @focused_pane = @agent_workspace_return_pane
          @agent_tree_navigation_active = false
          @force_full_redraw = true
          persist_agent_workspace
          return
        end

        agent = agent_workspace_agent(state)
        unless agent
          @agent_workspace_active = false
          @focused_pane = @agent_workspace_return_pane
          @agent_tree_navigation_active = false
          @force_full_redraw = true
          persist_agent_workspace
          return
        end
        @agent_workspace_interactive = result.fetch("interactive", false)
        if @agent_workspace_interactive
          @focused_pane = "logs"
          @agent_tree_navigation_active = false
          @agent_workspace_terminal_size = nil
        else
          @focused_pane = "agent_tree"
          @agent_tree_navigation_active = true
        end
        open_agent_workspace_session(agent) unless @agent_workspace_interactive
        if @agent_workspace_view == "terminal"
          @agent_workspace_session.pause if !@agent_workspace_interactive && @agent_workspace_session&.respond_to?(:pause)
          prepare_workspace_terminal(state)
        end
        persist_agent_workspace
      end

      def agent_workspace_snapshot(state, input_buffer, input_cursor, slash_suggestion_index = NO_SLASH_SELECTION)
        expire_workspace_leader!
        complete_pending_workspace_open(state)
        snapshot = @chat_mutex.synchronize do
          {
            "active" => @agent_workspace_active,
            "agent_id" => @agent_workspace_agent_id,
            "interactive" => @agent_workspace_interactive,
            "embedded" => embedded_agent_workspace?,
            "opening" => @agent_workspace_open_pending,
            "view" => @agent_workspace_view,
            "filter" => @agent_workspace_filter,
            "input_buffer" => input_buffer,
            "input_cursor" => clamp_cursor(input_buffer, input_cursor || input_buffer.to_s.length),
            "pending_count" => @agent_workspace_pending_count,
            "leader_hint" => workspace_leader_help,
            "leader_label" => workspace_leader_label,
            "leader_commands" => workspace_leader_commands,
            "leader_pending" => @workspace_leader_pending,
            "slash_suggestion_index" => slash_suggestion_index.to_i,
            "slash_suggestions" => workspace_command_suggestion_records(input_buffer),
            "scroll_offset" => @agent_workspace_view == "terminal" ? @workspace_terminal_scroll_offset.to_i : @workspace_agent_scroll_offset.to_i,
            "messages" => @agent_workspace_messages[@agent_workspace_agent_id.to_s].map(&:dup),
            "notice" => @agent_workspace_notice,
            "error" => @agent_workspace_error,
            "persistence_error" => @workspace_persistence_error
          }.compact
        end
        if @agent_workspace_active
          terminal_view = @agent_workspace_view == "terminal"
          live = terminal_view ? terminal_workspace_snapshot(state) : live_agent_workspace_snapshot(state)
          snapshot[terminal_view ? "terminal" : "agent_session"] = live
          revision = workspace_content_revision(snapshot, live)
          snapshot["content_revision"] = revision if revision
        end
        snapshot
      end

      # Cheap signature of everything the focused workspace renders. Panes reuse
      # composed lines while it is unchanged, so scrolling never repeats a full
      # transcript or terminal re-layout.
      def workspace_content_revision(snapshot, live)
        return nil unless live.is_a?(Hash)

        revision = live.fetch("revision", nil)
        return nil if revision.nil?

        [
          revision,
          live.fetch("error", nil).to_s,
          live.fetch("notice", nil).to_s,
          live.fetch("warning", nil).to_s,
          live.fetch("availability", nil).to_s,
          live.fetch("session_state", nil).to_s,
          live.fetch("status", nil).to_s,
          @chat_mutex.synchronize { @agent_workspace_events_revision[@agent_workspace_agent_id.to_s] },
          Array(snapshot.fetch("messages", [])).length,
          snapshot.fetch("notice", nil).to_s,
          snapshot.fetch("error", nil).to_s,
          snapshot.fetch("persistence_error", nil).to_s
        ]
      end

      def persisted_agent_workspace_snapshot
        {
          "selected_agent_id" => @agent_workspace_agent_id,
          "view" => @agent_workspace_view,
          "filter" => @agent_workspace_filter,
          "draft" => @workspace_draft.to_s,
          "agent_scroll_offset" => @workspace_agent_scroll_offset.to_i,
          "terminal_scroll_offset" => @workspace_terminal_scroll_offset.to_i
        }
      end

      def remember_workspace_agent(state, agent_id)
        worker = Array(state.fetch("agents", [])).find do |agent|
          agent.is_a?(Hash) && agent["type"].to_s == "worker" && agent["id"].to_s == agent_id.to_s
        end
        return false unless worker
        return true if @agent_workspace_agent_id.to_s == worker.fetch("id").to_s

        @agent_workspace_agent_id = worker.fetch("id")
        @agent_workspace_view = "agent"
        @agent_workspace_filter = "all"
        @workspace_agent_scroll_offset = 0
        @workspace_terminal_scroll_offset = 0
        @workspace_draft = ""
        # AgentTree movement is a transient filtering gesture. Remember the worker
        # immediately in memory, but do not make the click wait for Store to load,
        # lock, and rewrite the complete orchestration snapshot.
        persist_agent_workspace(deferred: true)
        true
      end

      def reconcile_workspace_selection!(state)
        return if @agent_workspace_agent_id.to_s.empty?
        current = Array(state.fetch("agents", [])).find do |agent|
          agent.is_a?(Hash) && agent["type"] == "worker" && agent["id"].to_s == @agent_workspace_agent_id.to_s
        end
        if current
          status = current.fetch("status", nil).to_s
          return unless %w[completed killed].include?(status)
          # A completed Pi worker is already terminal when native focus begins. Keep its pending
          # or active PTY alive; treating that pre-existing status as a new settle cancels the
          # handoff on the next frame and immediately resumes the dashboard session.
          return if status == "completed" && embedded_agent_workspace?
        end

        was_embedded = embedded_agent_workspace?
        if @agent_workspace_open_pending && workspace_controller&.respond_to?(:cancel_workspace_open)
          workspace_controller.cancel_workspace_open(agent: @agent_workspace_agent_id)
        elsif @agent_workspace_interactive && workspace_controller&.respond_to?(:close_workspace)
          close_interactive_agent_workspace(@agent_workspace_agent_id)
        else
          close_agent_workspace_session
        end
        @chat_mutex.synchronize { @agent_workspace_open_result = nil }
        @agent_workspace_open_pending = false
        @agent_workspace_open_generation += 1
        @force_full_redraw = true if @agent_workspace_active
        @agent_workspace_interactive = false
        @agent_workspace_active = false
        @focused_pane = @agent_workspace_return_pane if was_embedded
        @agent_tree_navigation_active = false if was_embedded
        @agent_workspace_agent_id = nil
        @agent_workspace_view = "agent"
        @agent_workspace_filter = "all"
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @workspace_draft = ""
        persist_agent_workspace(deferred: true)
      end

      # Saving rewrites the whole state file, so high-frequency presentation
      # changes only mark the workspace dirty. The run loop flushes on a slow,
      # bounded cadence, while opening/closing a workspace and shutdown still
      # persist immediately.
      def persist_agent_workspace(deferred: false)
        return unless log_store&.respond_to?(:save_agent_workspace)

        if deferred
          # Start the bounded flush window with the first dirty change. Without
          # this, a process whose last write was long ago flushes immediately on
          # the next loop and merely moves the blocking rewrite one frame later.
          @workspace_persisted_at = monotonic_time unless @workspace_persist_dirty
          @workspace_persist_dirty = true
          return nil
        end

        @workspace_persist_dirty = false
        @workspace_persisted_at = monotonic_time
        persisted = log_store.save_agent_workspace(persisted_agent_workspace_snapshot)
        @workspace_persistence_error = nil
        persisted
      rescue StandardError => e
        @workspace_persistence_error = "Workspace selection could not be saved: #{e.message}"
        nil
      end

      def flush_deferred_agent_workspace_persistence
        return unless @workspace_persist_dirty
        return if monotonic_time - @workspace_persisted_at < WORKSPACE_PERSIST_INTERVAL

        persist_agent_workspace
      end

      def live_agent_workspace_snapshot(state)
        agent = agent_workspace_agent(state)
        return { "error" => "Selected worker is no longer available." } unless agent

        result = if @agent_workspace_interactive && workspace_controller&.respond_to?(:agent_snapshot)
                   resize_agent_workspace_interactive(agent, state)
                   rows, columns = agent_workspace_terminal_dimensions(state)
                   workspace_controller.agent_snapshot(agent: agent, state: state, rows: rows, columns: columns)
                 elsif @agent_workspace_session&.respond_to?(:snapshot)
                   snapshot = @agent_workspace_session.snapshot
                   polled = @agent_workspace_session.respond_to?(:poll_events) ? @agent_workspace_session.poll_events(limit: 200) : {}
                   reduce_agent_workspace_events(agent.fetch("id"), Array(polled["events"]))
                   snapshot.merge(
                     "events" => frozen_agent_workspace_events(agent.fetch("id")),
                     "event_gap" => !!polled["gap"],
                     "warning" => polled["gap"] ? "Some transient live events expired; the transcript was refreshed from the managed session." : snapshot["warning"]
                   ).compact
                 elsif workspace_controller&.respond_to?(:agent_snapshot)
                   workspace_controller.agent_snapshot(agent: agent, state: state)
                 elsif workspace_controller&.respond_to?(:snapshot)
                   workspace_controller.snapshot(agent: agent, state: state, view: "agent")
                 else
                   {}
                 end
        result.is_a?(Hash) ? stringify_workspace_snapshot(result) : {}
      rescue StandardError => e
        { "error" => "Could not read worker session: #{e.message}" }
      end

      # Renders from one frozen copy per change instead of duplicating every
      # retained event on every frame.
      def frozen_agent_workspace_events(agent_id)
        key = agent_id.to_s
        @chat_mutex.synchronize do
          revision = @agent_workspace_events_revision[key]
          cached = @agent_workspace_events_cache[key]
          return cached.fetch("events") if cached && cached.fetch("revision") == revision

          events = @agent_workspace_events[key].map { |event| deep_freeze_workspace_value(event) }.freeze
          @agent_workspace_events_cache[key] = { "revision" => revision, "events" => events }
          events
        end
      end

      def deep_freeze_workspace_value(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), copy| copy[key.to_s] = deep_freeze_workspace_value(child) }.freeze
        when Array
          value.map { |child| deep_freeze_workspace_value(child) }.freeze
        when String
          value.frozen? ? value : value.dup.freeze
        else
          value
        end
      end

      def reduce_agent_workspace_events(agent_id, events)
        return if events.empty?

        @chat_mutex.synchronize do
          @agent_workspace_events_revision[agent_id.to_s] += 1
          retained = @agent_workspace_events[agent_id.to_s]
          events.each do |event|
            next unless event.is_a?(Hash)

            identity = [event["kind"], event["id"] || event["tool_call_id"]]
            replace_at = identity.last && retained.index do |candidate|
              [candidate["kind"], candidate["id"] || candidate["tool_call_id"]] == identity
            end
            if replace_at
              retained[replace_at] = event
            else
              retained << event
            end
          end
          retained.shift(retained.length - 300) if retained.length > 300
        end
      end

      def terminal_workspace_snapshot(state)
        agent = agent_workspace_agent(state)
        return { "error" => "Selected worker is no longer available.", "lines" => [] } unless agent
        return { "error" => "The worktree terminal is unavailable.", "lines" => [] } unless workspace_controller

        resize_agent_workspace_terminal(agent, state)
        result = if workspace_controller.respond_to?(:terminal_snapshot)
                   workspace_controller.terminal_snapshot(agent: agent, state: state)
                 elsif workspace_controller.respond_to?(:snapshot)
                   workspace_controller.snapshot(agent: agent, state: state, view: "terminal")
                 else
                   { "error" => "The worktree terminal is unavailable.", "lines" => [] }
                 end
        result.is_a?(Hash) ? stringify_workspace_snapshot(result) : { "lines" => Array(result).map(&:to_s) }
      rescue StandardError => e
        { "error" => "Could not read terminal: #{e.message}", "lines" => [] }
      end

      # Frozen values already come from a normalized, string-keyed snapshot, so
      # they are shared instead of rebuilt. That keeps a long transcript off the
      # per-frame path while scrolling.
      def stringify_workspace_snapshot(value)
        return value if value.frozen? && (value.is_a?(Hash) || value.is_a?(Array))

        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[key.to_s] = stringify_workspace_snapshot(child) }
        when Array
          value.map { |child| stringify_workspace_snapshot(child) }
        else
          value
        end
      end

      # A pruned, killed, or renumbered node stops filtering instead of hiding
      # every log line.
      def reconcile_log_scope!(state)
        return unless log_scope_active?
        return if LogScope.selectable?(state, @log_scope_id)

        clear_log_scope
      end

      def agent_tree_navigation_snapshot
        focused_agent_id = embedded_agent_workspace? ? @agent_workspace_agent_id : nil
        selected_agent_id = focused_agent_id || (@agent_tree_navigation_active ? @selected_agent_id : nil)
        {
          "active" => @agent_tree_navigation_active,
          "mode" => @agent_tree_navigation_active ? @agent_tree_navigation_mode.to_s : nil,
          "selected_agent_id" => selected_agent_id
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

        parsed = Timestamps.parse(timestamp)
        return false unless parsed

        parsed >= @started_at
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

        message_id = nil
        snapshot = @chat_mutex.synchronize do
          next if @log_event_keys[key]

          @log_event_keys[key] = true
          message_id = append_message_unlocked(role, text, status: status, source_id: source_id)
          log_buffer_snapshot_unlocked
        end
        persist_log_snapshot(snapshot)
        message_id
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

      def chat_snapshot(input_buffer, slash_suggestion_index = NO_SLASH_SELECTION, input_cursor = nil)
        @chat_mutex.synchronize do
          {
            "messages" => @messages.map(&:dup),
            "input_buffer" => input_buffer,
            "input_cursor" => clamp_cursor(input_buffer, input_cursor || input_buffer.to_s.length),
            "slash_suggestion_index" => slash_suggestion_index,
            "selection" => @chat_selection,
            "pending_count" => @pending_count,
            "delivery_pr_picker" => delivery_pr_picker_snapshot,
            "model_picker" => model_picker_snapshot
          }
        end
      end

      def append_message(role, text, status: nil, visible: nil, source_id: nil, persist: true)
        message_id = nil
        snapshot = @chat_mutex.synchronize do
          message_id = append_message_unlocked(role, text, status: status, visible: visible, source_id: source_id)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
        message_id
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
        @next_message_id
      end

      def update_message(id, text:, status: nil, visible: nil, persist: true)
        snapshot = @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          next unless message

          message["text"] = text
          if status
            message["status"] = status
          else
            message.delete("status")
          end
          apply_message_visibility(message, visible)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
      end

      def append_to_message(id, line, status: nil, visible: nil, persist: true)
        snapshot = @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          next unless message

          existing = message.fetch("text", "").to_s
          addition = line.to_s
          unless duplicate_trailing_line?(existing, addition)
            message["text"] = [existing, addition].reject { |part| part.to_s.empty? }.join("\n")
          end
          apply_message_status(message, status)
          apply_message_visibility(message, visible)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
      end

      def update_message_status(id, status, persist: true)
        snapshot = @chat_mutex.synchronize do
          message = @messages.find { |candidate| candidate.fetch("id") == id }
          next unless message

          apply_message_status(message, status)
          log_buffer_snapshot_unlocked if persist
        end
        persist_log_snapshot(snapshot)
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

      def log_buffer_snapshot_unlocked
        @next_log_persist_sequence += 1
        {
          sequence: @next_log_persist_sequence,
          messages: @messages.map(&:dup),
          next_message_id: @next_message_id
        }
      end

      # State persistence can wait behind a kernel write. Keep that I/O outside the chat mutex so
      # rendering, typing, and quitting stay available while another thread owns the state lock.
      # Sequence numbers preserve mutation order when several prompt threads finish together.
      def persist_log_snapshot(snapshot)
        return unless snapshot

        sequence = snapshot.fetch(:sequence)
        @log_persist_mutex.synchronize do
          @log_persist_condition.wait(@log_persist_mutex) until sequence == @completed_log_persist_sequence + 1
          begin
            log_store.save_log_buffer(
              messages: snapshot.fetch(:messages),
              next_message_id: snapshot.fetch(:next_message_id)
            ) if log_store&.respond_to?(:save_log_buffer)
          rescue StandardError
            nil
          ensure
            @completed_log_persist_sequence = sequence
            @log_persist_condition.broadcast
          end
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
