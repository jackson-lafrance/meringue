# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Slash commands the dashboard answers itself, without going through the kernel.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def handle_local_navigation_command(input_buffer, state)
        text = input_buffer.to_s.strip
        return handle_local_jump_command(text, state) if jump_command?(text)
        return handle_local_pull_requests_command(state) if pull_requests_picker_command?(text)
        return handle_local_questions_command(state) if questions_picker_command?(text)
        return handle_local_models_command(text, state) if models_picker_command?(text)
        return handle_local_thinking_command(text, state) if thinking_picker_command?(text)
        return handle_local_theme_command(text, state) if theme_picker_command?(text)
        return handle_local_harness_command(text, state) if harness_picker_command?(text)
        return handle_local_open_session_command(text, state) if open_session_command?(text)
        return handle_local_setup_command(state) if setup_command?(text)
        return handle_local_keybind_command if keybind_command?(text)
        return handle_local_glossary_command if glossary_command?(text)
        return handle_local_config_command(text, state) if config_command?(text)
        return handle_local_reload_command if reload_command?(text)
        return handle_local_update_command if update_command?(text)
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

      def handle_local_glossary_command
        append_jump_response(Glossary.text)
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

      def handle_local_quit_command
        if lifecycle_update_running?
          append_jump_response("Cannot quit while a Meringue update is still running.")
          return true
        end

        @quit_requested = true
        true
      end

      # `/reload` is requested on the TUI thread but executed by the CLI only
      # after this app has unwound its terminal/workspace ensure block.
      def handle_local_reload_command
        unless lifecycle_available?(:reload)
          append_jump_response("Reload is unavailable because this TUI was not started by the Meringue CLI.")
          return true
        end

        if lifecycle_update_running?
          append_jump_response("Cannot reload while a Meringue update is still running.")
          return true
        end

        request_reload
        true
      end

      # Updating can involve network or dependency-manager I/O, so keep it off
      # the input/render thread. A successful update invokes the same reload
      # request as `/reload`; a failed or unsafe update leaves this process alive
      # and reports an actionable message instead.
      def handle_local_update_command
        unless lifecycle_available?(:update)
          append_jump_response("Update is unavailable because this TUI was not started by the Meringue CLI.")
          return true
        end

        if lifecycle_update_running?
          append_jump_response("A Meringue update is already running.")
          return true
        end

        update_message_id = append_jump_response("Updating Meringue…")
        @lifecycle_mutex.synchronize do
          @lifecycle_update_thread = Thread.new do
            begin
              result = lifecycle.update
              if lifecycle_update_succeeded?(result)
                update_message(update_message_id, text: "Update completed")
                request_reload
              else
                append_jump_response(result_message(result, "Meringue update failed."))
              end
            rescue StandardError => e
              append_jump_response("Meringue update failed: #{e.message}")
            end
          end
        end
        true
      end

      def lifecycle_available?(operation)
        lifecycle && lifecycle.respond_to?(operation)
      end

      def lifecycle_update_running?
        @lifecycle_mutex.synchronize { @lifecycle_update_thread&.alive? }
      end

      def lifecycle_update_succeeded?(result)
        result == true || (result.is_a?(Hash) && %w[updated reloaded success].include?(result.fetch("status", nil).to_s))
      end

      def result_message(result, fallback)
        return fallback unless result.is_a?(Hash)

        result.fetch("message", fallback).to_s
      end

      def request_reload
        @lifecycle_mutex.synchronize { @reload_requested = true }
      end

      def reload_requested?
        @lifecycle_mutex.synchronize { @reload_requested }
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
          Chat: #{keys_for("undo")} undoes the most recent edit while the input is focused; #{keys_for("submit")} sends the prompt as typed, or applies a slash suggestion once one is selected; #{keys_for("newline")} inserts a newline; #{keys_for("cursor_left")}/#{keys_for("cursor_right")} move by character; #{keys_for("cursor_up")}/#{keys_for("cursor_down")} move through hard and soft-wrapped rows, then browse sent-input history at the first/last row; #{keys_for("cursor_home")} and #{keys_for("cursor_end")} jump within a line; #{keys_for("cursor_word_left")} and #{keys_for("cursor_word_right")} move by word; #{keys_for("delete_backward")}/#{keys_for("delete_forward")} edit characters; #{keys_for("delete_word_backward")} and #{keys_for("delete_word_forward")} edit words.
          Slash commands: type / for suggestions; nothing is selected until you press #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} or #{keys_for("complete_suggestion")}; #{keys_for("complete_suggestion")} completes; #{keys_for("submit")} inserts the selected suggestion.
          Agent tree/logs: focus either pane and press #{keys_for("submit")} to enter jump mode. In the AgentTree, #{keys_for("rename_selected")} starts a quick rename for the selected project or issue by pre-filling `/project rename` or `/issue rename`; type its new name in the composer and press Enter. Right-click any row for its context menu, or press Shift-F10 to open the same menu for the selected row.
          Agent tree scrolling: focus the AgentTree, then #{keys_for("scroll_up")}/#{keys_for("scroll_down")} scroll a line, #{keys_for("scroll_page_up")}/#{keys_for("scroll_page_down")} scroll a page, #{keys_for("scroll_top")}/#{keys_for("scroll_bottom")} jump to the first/last row, and the mouse wheel scrolls while the pointer is over the pane. The pane title shows how many rows are hidden above and below (↑ above ↓ below). In jump mode #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} keep the selected item on screen automatically while paging and #{keys_for("scroll_top")}/#{keys_for("scroll_bottom")} still scroll.
          Pull-request picker: /prs opens every tracked PR that is still open, regardless of the AgentTree selection; #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} move, #{keys_for("submit")} opens the highlighted PR, and #{keys_for("cancel_navigation")} closes. #{keys_for("open_delivery_pr")} keeps its selection-aware behavior: it opens the selected issue's PR, or this picker when chat is unscoped.
          Settings pickers: bare /model or /models opens models, bare /thinking opens thinking levels, bare /theme or /themes opens themes, and bare /harness opens harnesses. They are bordered popovers; #{keys_for("cursor_left")}/#{keys_for("cursor_right")} switches role tabs where shown, #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} moves, #{keys_for("submit")} applies, #{keys_for("refresh_model_catalog")} refreshes the model catalog, and #{keys_for("cancel_navigation")} closes. /models refresh re-fetches without opening the picker. /prs opens the pull-request popover.
          Question picker: /questions opens existing open questions with local 1-based display numbers; #{keys_for("suggestion_previous")}/#{keys_for("suggestion_next")} move, #{keys_for("submit")} inserts /answer <question_id> into chat, and #{keys_for("cancel_navigation")} closes.
          Jump mode: /jump starts navigation; #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} selects an item; #{keys_for("open_agent_workspace")} opens the selected worker workspace or a selected head's saved harness session; #{keys_for("open_delivery_pr")} or Enter opens a verified delivery PR; #{keys_for("cancel_navigation")} cancels.
          Head/session debugging: select a head and press #{keys_for("open_agent_workspace")}, or use /open-session <agent_id>, to open its saved harness session externally without turning it into a chat target.
          Focused worker workspace (optional deep interaction): press #{keys_for("workspace_leader")}, then #{keys_for("workspace_switch_view")} to switch between terminal and agent view, #{keys_for("workspace_cycle_filter")} to cycle the transcript filter, #{keys_for("workspace_open_agent_session")} to open the underlying agent session externally, #{keys_for("workspace_open_editor")} for the editor, #{keys_for("workspace_open_pull_request")} for the delivery PR, or #{keys_for("workspace_close")} to quit back to the AgentTree while preserving the worker/terminal. PageUp/PageDown or the mouse wheel scrolls Meringue-rendered transcripts and is delivered directly to embedded harness applications for native history navigation. In the focused composer, type / for workspace commands (/help, /terminal, /filter, /session, /editor, /pr, /cwd, /cancel, /quit); anything else is sent to the worker. Use dashboard chat for normal head-agent orchestration.
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

      def glossary_command?(text)
        %w[/glossary /terms].include?(text)
      end

      def keybind_command?(text)
        text == "/keybind"
      end

      def pull_requests_picker_command?(text)
        text.to_s.strip.downcase == "/prs"
      end

      def questions_picker_command?(text)
        text.to_s.strip.downcase == "/questions"
      end

      def handle_local_questions_command(state)
        open_question_picker(state)
        true
      end

      def handle_local_pull_requests_command(state)
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
        %w[/theme /themes].include?(text.to_s.strip.downcase)
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

      def reload_command?(text)
        text.to_s.strip == "/reload"
      end

      def update_command?(text)
        text.to_s.strip == "/update"
      end

      def quit_command?(text)
        text == "/quit"
      end

      def local_navigation_command_without_id?(input_buffer)
        text = input_buffer.to_s.strip.downcase
        return true if ["/jump", "/prs", "/questions", "/theme", "/themes", "/setup", "/config", "/open-session"].include?(text)
        return true if models_picker_command?(text)
        return true if thinking_picker_command?(text)
        return true if theme_picker_command?(text)
        return true if harness_picker_command?(text)

        false
      end
    end
  end
end
