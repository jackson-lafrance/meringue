# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Editing the chat composer: insertion, deletion, cursor movement, history, and pastes.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

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
        normalize_input_text(key.fetch("text", ""))
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
        input_buffer.to_s.strip.start_with?("/") || Input::SlashCommandParser.inline_suggestion_active?(input_buffer)
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
    end
  end
end
