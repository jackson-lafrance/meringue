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
      CHAT_UNDO_LIMIT = 100
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
      def initialize(layout: Layout.new, input: $stdin, out: $stdout, terminal: nil, session_opener: nil, pull_request_opener: nil, workspace_controller: nil, agent_session_service: nil, log_store: nil, conversation_store: nil, keybindings: Keybindings.default, config: nil, onboarding_enabled: false, harness_configured_check: nil, harness_availability_provider: nil, harness_probe: nil, lifecycle: nil)
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
        @chat_undo_history = []
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
        # Theme previews are process-local until the normal SetTheme command is
        # accepted. Keep the original so Escape/click-away never leaks a preview.
        @theme_picker_original = nil
        @theme_picker_pending_original = nil
        # Open-question picker: transient UI that leaves `/answer <id> ` in the
        # composer so the user can type the answer before submitting it.
        @question_picker_active = false
        @question_picker_index = 0
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
        @github_access_test_result = nil
        @settings_mode = "settings"
        @settings_footer_button = "next"
        @settings_setup_auto = false
        @settings_setup_outcome = nil
        @settings_status_bar_draft = nil
        # A settings theme picker previews independently of the draft until its
        # row is accepted, so cancelling it can restore the theme active when it opened.
        @settings_picker_theme_original = nil
        @settings_status_bar_drag = nil
        @context_menu = nil
        # Status-bar composition is a separate in-memory draft. Preview changes
        # never touch the config until the single SaveConfiguration transaction
        # succeeds, so Esc and failed saves are deterministic.
        @status_bar_composer_active = false
        @status_bar_composer_draft = nil
        @status_bar_composer_saving = false
        @status_bar_composer_drag = nil
        @status_bar_composer_return_to_settings = false
        # First-run setup is a curated mode of the same transactional Settings
        # draft and full-screen pane. It is disabled for `meringue demo`, where no
        # kernel exists to save the draft or completion marker.
        @onboarding_enabled = onboarding_enabled ? true : false
        # Truthful only when at least one role harness is configured. The CLI
        # supplies a registry-backed check so the app can open setup and gate
        # chat when no backend is chosen yet; tests and demo default to "ready"
        # so existing behavior is unchanged.
        @harness_configured_check = harness_configured_check || -> { true }
        # Setup says which backends this machine can actually run, so it never
        # offers three equal choices and lets the user discover the answer later
        # from a StartError. Both are supplied by the CLI; without them setup
        # simply omits the availability notes.
        @harness_availability_provider = harness_availability_provider
        @harness_probe = harness_probe
        # Lifecycle is supplied by the CLI so update/reload can leave the TUI
        # through its normal ensure path before the process is replaced.
        @lifecycle = lifecycle
        @lifecycle_mutex = Mutex.new
        @lifecycle_update_thread = nil
        @reload_requested = false
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
        @lifecycle_mutex.synchronize { @reload_requested = false }
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
              break if @quit_requested || reload_requested?
            end
          end
        end

        reload_requested? ? :reload : 0
      rescue Interrupt
        0
      ensure
        shutdown_workspace_resources
      end

      private

      attr_reader :layout, :out, :terminal, :session_opener, :pull_request_opener, :workspace_controller, :agent_session_service, :log_store, :keybindings, :config, :lifecycle

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
        close_model_picker
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
        # Do not tear down the dashboard halfway through a source/dependency
        # update. The update thread will request the clean reload when it ends.
        return false if lifecycle_update_running?
        return true if keybinding?("quit", key)
        # An active selection or logs caret makes Ctrl-C a copy action, never a quit.
        return false if selection_active? || @logs_cursor_active

        ctrl_c_key?(key) && input_buffer.empty? && !@agent_tree_navigation_active
      end

      def handle_key(key, input_buffer, input_cursor = 0, slash_suggestion_index = nil, on_submit = nil, state = nil)
        handle_chat_key(
          key,
          input_buffer,
          input_cursor,
          slash_suggestion_index,
          on_submit,
          state || State::Models.empty_state
        )
      end

      def handle_chat_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        undo_snapshot = chat_undo_snapshot(input_buffer, input_cursor, slash_suggestion_index) if dashboard_chat_surface?
        history_index = @chat_history_index
        result = dispatch_chat_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        update_chat_undo_history(key, input_buffer, result, undo_snapshot, history_index)
      end

      def dispatch_chat_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        input_cursor = clamp_cursor(input_buffer, input_cursor)
        unless key
          continue_logs_drag_autoscroll(state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if @agent_workspace_active && !embedded_agent_workspace?
          return handle_agent_workspace_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end

        if dashboard_chat_undo_key?(key)
          return undo_chat_edit(input_buffer, input_cursor, slash_suggestion_index)
        end

        @chat_pastes.sync!(input_buffer)

        # Settings and its nested status-bar composer own the complete screen and
        # keep Esc/Ctrl-S as hard recovery keys regardless of dashboard bindings.
        if @status_bar_composer_active
          return handle_status_bar_composer_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end

        if @settings_active
          return handle_settings_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        end

        # An open context menu owns every key: it is modal like the pickers, and
        # anything it does not recognise dismisses it rather than typing into the
        # composer behind it.
        if context_menu_active?
          return handle_context_menu_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        end

        if context_menu_key?(key)
          opened = open_context_menu_for_selection(state)
          return [input_buffer, input_cursor, slash_suggestion_index] if opened
        end

        if @question_picker_active
          picker_result = handle_question_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
          return picker_result if picker_result
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
    end
  end
end

# The dashboard is one class split across these files by surface. Each one reopens
# `Meringue::TUI::App`; none of them adds a module to the ancestor chain, so method lookup,
# constants, and instance variables behave exactly as they did in one file.
require_relative "app/agent_tree"
require_relative "app/agent_tree_navigation"
require_relative "app/agent_workspace"
require_relative "app/chat_messages"
require_relative "app/composer"
require_relative "app/context_menu"
require_relative "app/input_keys"
require_relative "app/local_commands"
require_relative "app/log_sync"
require_relative "app/mouse"
require_relative "app/onboarding"
require_relative "app/pickers"
require_relative "app/presentation"
require_relative "app/prompt_submission"
require_relative "app/scrolling"
require_relative "app/settings"
require_relative "app/setup"
require_relative "app/status_bar_composer"
require_relative "app/text_selection"
require_relative "app/workspace_lifecycle"
require_relative "app/workspace_state"
