# frozen_string_literal: true

module Meringue
  module TUI
    class Keybindings
      DEFAULT_BINDINGS = {
        "quit" => ["ctrl-d"],
        "clear_or_quit" => ["ctrl-c"],
        "cancel_navigation" => ["escape"],
        "focus_next" => ["tab", "ctrl-tab"],
        "focus_previous" => ["shift-tab"],
        "scroll_up" => ["up"],
        "scroll_down" => ["down"],
        "scroll_page_up" => ["page-up"],
        "scroll_page_down" => ["page-down"],
        "submit" => ["enter"],
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
        "agent_select_previous" => ["up", "left"],
        "agent_select_next" => ["down", "right"]
      }.freeze

      ACTION_LABELS = {
        "quit" => "Quit",
        "clear_or_quit" => "Clear input / quit empty prompt",
        "cancel_navigation" => "Cancel navigation",
        "focus_next" => "Focus next pane",
        "focus_previous" => "Focus previous pane",
        "scroll_up" => "Scroll up",
        "scroll_down" => "Scroll down",
        "scroll_page_up" => "Page up",
        "scroll_page_down" => "Page down",
        "submit" => "Submit / open selected item",
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
        "agent_select_previous" => "Select previous agent",
        "agent_select_next" => "Select next agent"
      }.freeze

      KEY_ALIASES = {
        "escape" => ["\e"],
        "esc" => ["\e"],
        "ctrl-c" => ["\u0003", "\e[99;5u", "\e[67;5u", "\e[27;5;99~", "\e[27;5;67~"],
        "ctrl-d" => ["\u0004"],
        "ctrl-w" => ["\u0017"],
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
        action.to_s.strip.downcase.tr("- ", "__").gsub(/_+/, "_")
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

      def label_for(action)
        self.class.label_for(action)
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
