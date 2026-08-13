# frozen_string_literal: true

module Meringue
  module TUI
    class Canvas
      attr_reader :width, :height

      def initialize(width:, height:, fill: " ")
        @width = [width.to_i, 1].max
        @height = [height.to_i, 1].max
        @fill = fill.to_s.empty? ? " " : fill.to_s[0]
        @chars = Array.new(@height) { Array.new(@width, @fill) }
        @styles = Array.new(@height) { Array.new(@width) }
      end

      def write(x, y, text, max_width: nil, style: nil)
        row = y.to_i
        return if row.negative? || row >= height

        column = x.to_i
        limit = max_width ? max_width.to_i : width
        return if limit <= 0

        text_chars = sanitize(text).chars
        visible_start = [0, -column].max
        visible_width = [limit - visible_start, width - [column, 0].max].min
        return if visible_width <= 0

        start_column = [column, 0].max
        text_chars.drop(visible_start).take(visible_width).each_with_index do |char, offset|
          @chars[row][start_column + offset] = char
          @styles[row][start_column + offset] = style
        end
      end

      def write_segments(x, y, segments, max_width:, default_style: nil)
        cursor = x.to_i
        remaining = max_width.to_i
        return if remaining <= 0

        segments.each do |segment|
          text, style = segment_text_and_style(segment, default_style)
          chars = sanitize(text).chars
          next if chars.empty?

          visible_text = chars.take(remaining).join
          write(cursor, y, visible_text, max_width: remaining, style: style)

          written = visible_text.length
          cursor += written
          remaining -= written
          break if remaining <= 0
        end
      end

      # Restyles already-drawn cells without touching their characters. Selection
      # highlights use this so a drag never re-wraps or re-renders pane content.
      def restyle(x, y, cell_count, style)
        row = y.to_i
        return if row.negative? || row >= height

        start_column = [x.to_i, 0].max
        finish_column = [x.to_i + cell_count.to_i, width].min
        return if finish_column <= start_column

        (start_column...finish_column).each do |column|
          @styles[row][column] = style
        end
      end

      def draw_box(x, y, box_width, box_height, title: nil, style: Style::BORDER, title_style: Style::PANEL_TITLE)
        left = x.to_i
        top = y.to_i
        box_width = box_width.to_i
        box_height = box_height.to_i
        return if box_width <= 0 || box_height <= 0

        right = left + box_width - 1
        bottom = top + box_height - 1

        if box_height == 1
          write(left, top, horizontal_line(box_width, "─", "─"), max_width: box_width, style: style)
          return
        end

        write(left, top, horizontal_line(box_width, "╭", "╮"), max_width: box_width, style: style)
        write(left, bottom, horizontal_line(box_width, "╰", "╯"), max_width: box_width, style: style)

        (top + 1...bottom).each do |row|
          write(left, row, "│", style: style)
          write(right, row, "│", style: style) if box_width > 1
        end

        draw_title(left, top, box_width, title, title_style) if title
      end

      def render(color: true)
        @chars.each_with_index.map do |row, row_index|
          render_row(row, @styles[row_index], color: color)
        end.join("\n")
      end

      private

      def sanitize(text)
        text.to_s.tr("\t", " ").gsub(/[[:cntrl:]]/, " ")
      end

      def segment_text_and_style(segment, default_style)
        return [segment.to_s, default_style] unless segment.is_a?(Array)

        [segment.fetch(0, "").to_s, segment.fetch(1, default_style)]
      end

      def horizontal_line(box_width, left, right)
        return "│" if box_width == 1
        return "#{left}#{right}" if box_width == 2

        "#{left}#{"─" * (box_width - 2)}#{right}"
      end

      def draw_title(left, top, box_width, title, title_style)
        title_text = " #{sanitize(title)} "
        available_width = box_width - 4
        return if available_width <= 0

        write(left + 2, top, title_text, max_width: available_width, style: title_style)
      end

      def render_row(row, styles, color:)
        return row.join unless color

        # Styles normally change only at segment boundaries (borders, labels, and
        # pane content). Appending one character at a time made the normal ANSI
        # path scan and grow a Ruby String for every terminal cell on every
        # keystroke; the scalability benchmark did not see it because it forced
        # NO_COLOR. Emit complete same-style runs instead, keeping work tied to
        # rendered segments rather than viewport area.
        rendered = String.new
        run_start = 0
        current_style = styles.first
        index = 1
        while index < row.length
          next_style = styles[index]
          if next_style != current_style
            append_styled_run(rendered, row, run_start, index, current_style)
            rendered << Style::RESET if current_style
            run_start = index
            current_style = next_style
          end
          index += 1
        end
        append_styled_run(rendered, row, run_start, row.length, current_style)
        rendered << Style::RESET if current_style
        rendered
      end

      def append_styled_run(rendered, row, start_index, end_index, style)
        rendered << style if style
        rendered << row[start_index...end_index].join
      end
    end
  end
end
