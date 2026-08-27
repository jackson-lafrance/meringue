# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Selecting text in the logs pane and the composer, by mouse or keyboard, and copying it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

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
    end
  end
end
