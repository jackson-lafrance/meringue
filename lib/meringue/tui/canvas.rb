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
        write_cells(x, y, DisplayWidth.cells(sanitize(text)), max_width: max_width, style: style)
      end

      def write_segments(x, y, segments, max_width:, default_style: nil)
        cursor = x.to_i
        remaining = max_width.to_i
        return if remaining <= 0

        segments.each do |segment|
          text, style = segment_text_and_style(segment, default_style)
          cells = DisplayWidth.cells(sanitize(text))
          next if cells.empty?

          written = write_cells(cursor, y, cells, max_width: remaining, style: style)
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

      CONTROL_CHARACTER = /[[:cntrl:]]/.freeze

      def sanitize(text)
        value = text.to_s
        value.match?(CONTROL_CHARACTER) ? value.gsub(CONTROL_CHARACTER, " ") : value
      end

      # Canvas writes are rectangular array replacement, not a Ruby callback per
      # terminal cell. Callers hand over DisplayWidth cells (one element per
      # terminal column, "" for the second half of a wide glyph) so clipping,
      # max_width, and the returned consumed count all measure what the terminal
      # will actually draw rather than how many codepoints the text had.
      def write_cells(x, y, cells, max_width:, style:)
        limit = max_width ? max_width.to_i : width
        return 0 if limit <= 0

        consumed_width = [cells.length, limit].min
        row = y.to_i
        return consumed_width if row.negative? || row >= height

        column = x.to_i
        visible_start = [0, -column].max
        visible_width = [limit - visible_start, width - [column, 0].max, cells.length - visible_start].min
        return consumed_width if visible_width <= 0

        start_column = [column, 0].max
        visible = cells[visible_start, visible_width]
        # A wide glyph cut in half at either clip edge would still render two
        # columns and push the rest of the row over; draw a blank in its place.
        visible[0] = " " if visible[0].empty?
        visible[-1] = " " if cells[visible_start + visible_width] == ""
        row_cells = @chars[row]
        # The same applies to a wide glyph already on the canvas whose head or
        # continuation cell this write overwrites.
        row_cells[start_column - 1] = " " if start_column.positive? && row_cells[start_column] == ""
        finish_column = start_column + visible_width
        row_cells[finish_column] = " " if finish_column < width && row_cells[finish_column] == ""
        row_cells[start_column, visible_width] = visible
        @styles[row][start_column, visible_width] = Array.new(visible_width, style)
        consumed_width
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
        #
        # Runs are joined from the cell array rather than sliced out of a joined
        # string: a cell may hold "" (the tail of a wide glyph) or several
        # codepoints (a base character plus combining marks), so cell indexes
        # are not character indexes.
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
