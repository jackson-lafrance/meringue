# frozen_string_literal: true

module Meringue
  module TUI
    class Keybindings
      DEFAULT_BINDINGS = {
        "quit" => ["ctrl-d"],
        "clear_or_quit" => ["ctrl-c"],
        "cancel_navigation" => ["escape"],
        "open_delivery_pr" => ["ctrl-b"],
        "refresh_model_catalog" => ["ctrl-r"],
        "focus_next" => ["tab", "ctrl-tab"],
        "focus_previous" => ["shift-tab"],
        "scroll_up" => ["up"],
        "scroll_down" => ["down"],
        "scroll_page_up" => ["page-up"],
        "scroll_page_down" => ["page-down"],
        "scroll_top" => ["home"],
        "scroll_bottom" => ["end"],
        "submit" => ["enter"],
        "rename_selected" => ["r"],
        "newline" => ["shift-enter"],
        "complete_suggestion" => ["tab"],
        "suggestion_previous" => ["up"],
        "suggestion_next" => ["down"],
        "cursor_left" => ["left"],
        "cursor_right" => ["right"],
        "cursor_up" => ["up"],
        "cursor_down" => ["down"],
        "cursor_home" => ["home", "ctrl-a"],
        "cursor_end" => ["end", "ctrl-e"],
        "cursor_word_left" => ["alt-left", "ctrl-left"],
        "cursor_word_right" => ["alt-right", "ctrl-right"],
        "delete_backward" => ["backspace"],
        "delete_forward" => ["delete"],
        "delete_word_backward" => ["alt-backspace", "ctrl-backspace", "ctrl-w"],
        "delete_word_forward" => ["alt-delete", "ctrl-delete"],
        "copy_selection" => ["ctrl-c", "alt-c"],
        "cut_selection" => ["ctrl-x"],
        "paste_clipboard" => ["ctrl-v"],
        "select_left" => ["shift-left"],
        "select_right" => ["shift-right"],
        "select_up" => ["shift-up"],
        "select_down" => ["shift-down"],
        "select_home" => ["shift-home"],
        "select_end" => ["shift-end"],
        "select_word_left" => ["shift-alt-left", "shift-ctrl-left"],
        "select_word_right" => ["shift-alt-right", "shift-ctrl-right"],
        "select_page_up" => ["shift-page-up"],
        "select_page_down" => ["shift-page-down"],
        "logs_selection_mode" => ["alt-v"],
        "agent_select_previous" => ["up", "left"],
        "agent_select_next" => ["down", "right"],
        "open_agent_workspace" => ["a"],
        "workspace_leader" => ["ctrl-space"],
        "workspace_switch_view" => ["t"],
        "workspace_cycle_filter" => ["f"],
        "workspace_open_agent_session" => ["a"],
        "workspace_open_editor" => ["b"],
        "workspace_open_pull_request" => ["p"],
        "workspace_close" => ["q"]
      }.freeze

      # Older config files bound the harness-specific action name. Keep them
      # working by folding the legacy name onto the harness-agnostic action.
      ACTION_ALIASES = {
        "workspace_open_pi_session" => "workspace_open_agent_session",
        "workspace_open_harness_session" => "workspace_open_agent_session",
        "workspace_open_session" => "workspace_open_agent_session"
      }.freeze

      # Short, harness-agnostic labels for the focused-workspace leader line.
      WORKSPACE_COMMAND_LABELS = {
        "workspace_switch_view" => "terminal/agent",
        "workspace_cycle_filter" => "filter",
        "workspace_open_agent_session" => "agent session",
        "workspace_open_editor" => "editor",
        "workspace_open_pull_request" => "PR",
        "workspace_close" => "quit"
      }.freeze

      ACTION_LABELS = {
        "quit" => "Quit",
        "clear_or_quit" => "Clear input / quit empty prompt",
        "cancel_navigation" => "Cancel dashboard navigation",
        "open_delivery_pr" => "Open the selected worker's delivery PR, or pick from the open PRs",
        "refresh_model_catalog" => "In the model picker: re-fetch the harness model catalog",
        "focus_next" => "Focus next pane",
        "focus_previous" => "Focus previous pane",
        "scroll_up" => "Scroll up",
        "scroll_down" => "Scroll down",
        "scroll_page_up" => "Page up",
        "scroll_page_down" => "Page down",
        "scroll_top" => "Scroll focused pane to the top",
        "scroll_bottom" => "Scroll focused pane to the bottom",
        "submit" => "Submit / open selected item",
        "rename_selected" => "Rename the selected project or issue",
        "newline" => "Insert newline",
        "complete_suggestion" => "Complete slash suggestion",
        "suggestion_previous" => "Previous slash suggestion",
        "suggestion_next" => "Next slash suggestion",
        "cursor_left" => "Cursor left",
        "cursor_right" => "Cursor right",
        "cursor_up" => "Cursor up",
        "cursor_down" => "Cursor down",
        "cursor_home" => "Line start",
        "cursor_end" => "Line end",
        "cursor_word_left" => "Previous word",
        "cursor_word_right" => "Next word",
        "delete_backward" => "Delete backward",
        "delete_forward" => "Delete forward",
        "delete_word_backward" => "Delete previous word",
        "delete_word_forward" => "Delete next word",
        "copy_selection" => "Copy selection",
        "cut_selection" => "Cut selection",
        "paste_clipboard" => "Paste clipboard",
        "select_left" => "Extend selection left",
        "select_right" => "Extend selection right",
        "select_up" => "Extend selection up",
        "select_down" => "Extend selection down",
        "select_home" => "Extend selection to line start",
        "select_end" => "Extend selection to line end",
        "select_word_left" => "Extend selection by word left",
        "select_word_right" => "Extend selection by word right",
        "select_page_up" => "Extend selection up one page",
        "select_page_down" => "Extend selection down one page",
        "logs_selection_mode" => "Toggle logs selection cursor",
        "agent_select_previous" => "Select previous agent",
        "agent_select_next" => "Select next agent",
        "open_agent_workspace" => "Open optional focused worker workspace",
        "workspace_leader" => "Focused workspace command leader",
        "workspace_switch_view" => "After workspace leader: switch between terminal and agent view",
        "workspace_cycle_filter" => "After workspace leader: cycle transcript filter",
        "workspace_open_agent_session" => "After workspace leader: open the underlying agent session externally",
        "workspace_open_editor" => "After workspace leader: open configured editor",
        "workspace_open_pull_request" => "After workspace leader: open delivery pull request",
        "workspace_close" => "After workspace leader: quit back to the AgentTree"
      }.freeze

      KEY_ALIASES = {
        "escape" => ["\e"],
        "esc" => ["\e"],
        "ctrl-c" => ["\u0003", "\e[99;5u", "\e[67;5u", "\e[27;5;99~", "\e[27;5;67~"],
        "ctrl-d" => ["\u0004"],
        "ctrl-w" => ["\u0017"],
        "ctrl-b" => ["\u0002", "\e[98;5u", "\e[66;5u", "\e[27;5;98~", "\e[27;5;66~"],
        "ctrl-r" => ["\u0012", "\e[114;5u", "\e[82;5u", "\e[27;5;114~", "\e[27;5;82~"],
        "ctrl-e" => ["\u0005", "\e[101;5u", "\e[69;5u", "\e[27;5;101~", "\e[27;5;69~"],
        "ctrl-t" => ["\u0014", "\e[116;5u", "\e[84;5u", "\e[27;5;116~", "\e[27;5;84~"],
        "ctrl-space" => ["\u0000", "\e[32;5u", "\e[27;5;32~"],
        "ctrl-x" => ["\u0018", "\e[120;5u", "\e[27;5;120~"],
        "ctrl-v" => ["\u0016", "\e[118;5u", "\e[27;5;118~"],
        "alt-c" => ["\ec", "\e[99;3u", "\e[27;3;99~"],
        "alt-v" => ["\ev", "\e[118;3u", "\e[27;3;118~"],
        "enter" => ["\r", "\n"],
        "return" => ["\r", "\n"],
        "shift-enter" => ["\e[13;2u", "\e[10;2u", "\e[27;2;13~", "\e[27;2;10~", "\e[13;2~", "\e[10;2~"],
        "tab" => ["\t"],
        "shift-tab" => ["\e[Z"],
        "ctrl-tab" => ["\e[27;5;9~", "\e[9;5u"],
        "backspace" => ["\u007f", "\b"],
        "delete" => ["\e[3~"],
        "left" => ["\e[D", "\eOD"],
        "right" => ["\e[C", "\eOC"],
        "up" => ["\e[A", "\eOA"],
        "down" => ["\e[B", "\eOB"],
        "home" => ["\e[H", "\e[1~", "\eOH"],
        "end" => ["\e[F", "\e[4~", "\eOF"],
        "page-up" => ["\e[5~"],
        "page-down" => ["\e[6~"],
        "alt-left" => ["\eb", "\eB", "\e[1;3D", "\e[1;9D"],
        "ctrl-left" => ["\e[1;5D"],
        "alt-right" => ["\ef", "\eF", "\e[1;3C", "\e[1;9C"],
        "ctrl-right" => ["\e[1;5C"],
        "alt-backspace" => ["\e\u007f", "\e\b", "\e[127;3u", "\e[8;3u", "\e[27;3;127~", "\e[27;3;8~"],
        "ctrl-backspace" => ["\e[127;3u", "\e[8;3u", "\e[27;3;127~", "\e[27;3;8~"],
        "alt-delete" => ["\ed", "\eD", "\e[3;3~"],
        "ctrl-delete" => ["\e[3;5~"],
        "shift-left" => ["\e[1;2D", "\e[2D"],
        "shift-right" => ["\e[1;2C", "\e[2C"],
        "shift-up" => ["\e[1;2A", "\e[2A"],
        "shift-down" => ["\e[1;2B", "\e[2B"],
        "shift-home" => ["\e[1;2H", "\e[2H", "\e[1;2~"],
        "shift-end" => ["\e[1;2F", "\e[2F", "\e[4;2~"],
        "shift-alt-left" => ["\e[1;4D", "\e[1;10D"],
        "shift-alt-right" => ["\e[1;4C", "\e[1;10C"],
        "shift-ctrl-left" => ["\e[1;6D"],
        "shift-ctrl-right" => ["\e[1;6C"],
        "shift-page-up" => ["\e[5;2~"],
        "shift-page-down" => ["\e[6;2~"],
        "space" => [" "]
      }.freeze

      def self.default
        new(DEFAULT_BINDINGS)
      end

      def self.from_config(config_section)
        names = DEFAULT_BINDINGS.transform_values(&:dup)
        return new(names) unless config_section.is_a?(Hash)

        config_section.each do |action, configured_names|
          action_name = canonical_action(action)
          next unless DEFAULT_BINDINGS.key?(action_name)

          key_names = normalize_configured_names(configured_names)
          next unless key_names

          valid_key_names = valid_names(key_names)
          names[action_name] = valid_key_names if key_names.empty? || valid_key_names.any?
        end

        new(names)
      end

      def self.actions
        DEFAULT_BINDINGS.keys
      end

      def self.label_for(action)
        ACTION_LABELS.fetch(canonical_action(action), canonical_action(action).tr("_", " "))
      end

      def self.canonical_action(action)
        normalized = action.to_s.strip.downcase.tr("- ", "__").gsub(/_+/, "_")
        ACTION_ALIASES.fetch(normalized, normalized)
      end

      # Display form used by hint lines: single letters read as command keys,
      # named keys keep their conventional capitalization.
      def self.display_name(name)
        text = name.to_s.strip
        return text.upcase if text.length == 1

        text.split("-").map { |part| part.length <= 1 ? part.upcase : part.capitalize }.join("-")
      end

      def self.workspace_command_label(action)
        WORKSPACE_COMMAND_LABELS.fetch(canonical_action(action), label_for(action))
      end

      def initialize(action_names = DEFAULT_BINDINGS)
        @key_names = DEFAULT_BINDINGS.merge(normalize_action_names(action_names || {}))
        @bindings = @key_names.transform_values { |names| self.class.compile_names(names) }
      end

      def match?(action, key)
        return false unless key.is_a?(String)

        bindings_for(action).include?(key)
      end

      def names_for(action)
        @key_names.fetch(self.class.canonical_action(action), []).dup
      end

      # Returns the unconsumed suffix when +key+ starts with a configured
      # sequence for +action+. This supports terminals that coalesce a leader
      # control byte and its printable command key into one read.
      def consume_prefix(action, key)
        return nil unless key.is_a?(String)

        sequence = bindings_for(action).select { |candidate| !candidate.empty? && key.start_with?(candidate) }.max_by(&:bytesize)
        sequence && key.byteslice(sequence.bytesize..).to_s
      end

      def label_for(action)
        self.class.label_for(action)
      end

      # First configured key for an action, in display form.
      def display_name_for(action)
        name = names_for(action).first
        name && self.class.display_name(name)
      end

      private

      def bindings_for(action)
        @bindings.fetch(self.class.canonical_action(action), [])
      end

      def normalize_action_names(action_names)
        return {} unless action_names.is_a?(Hash)

        action_names.each_with_object({}) do |(action, names), result|
          action_name = self.class.canonical_action(action)
          next unless DEFAULT_BINDINGS.key?(action_name)

          normalized_names = self.class.normalize_configured_names(names)
          next unless normalized_names

          result[action_name] = self.class.valid_names(normalized_names)
        end
      end

      def self.normalize_configured_names(configured_names)
        values = configured_names.is_a?(Array) ? configured_names : [configured_names]
        return nil unless values.all? { |value| value.is_a?(String) }

        values.map(&:strip).reject(&:empty?)
      end

      def self.valid_names(names)
        Array(names).select { |name| compile_name(name).any? }
      end

      def self.compile_names(names)
        Array(names).flat_map { |name| compile_name(name) }.uniq.freeze
      end

      def self.compile_name(name)
        normalized = canonical_key_name(name)
        return KEY_ALIASES.fetch(normalized) if KEY_ALIASES.key?(normalized)
        return [decode_raw_sequence(name[4..])] if normalized.start_with?("raw:") && name.length > 4
        return [ctrl_key(normalized)] if normalized.match?(/\Actrl-[a-z]\z/)
        return [name] if name.length == 1

        []
      end

      def self.canonical_key_name(name)
        name.to_s.strip.downcase.tr("_ ", "--").gsub(/-+/, "-")
      end

      def self.ctrl_key(name)
        letter = name.split("-", 2).last
        (letter.ord - "a".ord + 1).chr
      end

      def self.decode_raw_sequence(value)
        value.to_s.gsub("\\e", "\e")
      end
    end
  end
end
