# frozen_string_literal: true

module Meringue
  module TUI
    class Canvas
      attr_reader :width, :height

      def initialize(width:, height:, fill: " ")
        @width = [width.to_i, 1].max
        @height = [height.to_i, 1].max
        @fill = fill.to_s.empty? ? " " : fill.to_s[0]
        @cells = Array.new(@height) { Array.new(@width, @fill) }
      end

      def write(x, y, text, max_width: nil)
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
          @cells[row][start_column + offset] = char
        end
      end

      def draw_box(x, y, box_width, box_height, title: nil)
        left = x.to_i
        top = y.to_i
        box_width = box_width.to_i
        box_height = box_height.to_i
        return if box_width <= 0 || box_height <= 0

        right = left + box_width - 1
        bottom = top + box_height - 1

        if box_height == 1
          write(left, top, single_line_box(box_width), max_width: box_width)
          return
        end

        write(left, top, top_border(box_width), max_width: box_width)
        write(left, bottom, bottom_border(box_width), max_width: box_width)

        (top + 1...bottom).each do |row|
          write(left, row, "|")
          write(right, row, "|") if box_width > 1
        end

        draw_title(left, top, box_width, title) if title
      end

      def render
        @cells.map(&:join).join("\n")
      end

      private

      def sanitize(text)
        text.to_s.tr("\t", " ").gsub(/[[:cntrl:]]/, " ")
      end

      def single_line_box(box_width)
        return "+" if box_width == 1
        return "+" * box_width if box_width == 2

        "+#{"-" * (box_width - 2)}+"
      end

      def top_border(box_width)
        single_line_box(box_width)
      end

      def bottom_border(box_width)
        single_line_box(box_width)
      end

      def draw_title(left, top, box_width, title)
        title_text = " #{sanitize(title)} "
        available_width = box_width - 4
        return if available_width <= 0

        write(left + 2, top, title_text, max_width: available_width)
      end
    end
  end
end
