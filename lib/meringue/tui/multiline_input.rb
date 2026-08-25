# frozen_string_literal: true

module Meringue
  module TUI
    # Shared visual model for editable multiline text. Dashboard chat and inline
    # Settings fields use these exact wrapping, cursor, and selection rules so a
    # soft-wrapped line behaves the same on both surfaces.
    module MultilineInput
      module_function

      def lines(input_buffer, input_cursor:, width: nil, selection: nil,
                prompt_style: Style::ACCENT_BOLD, placeholder: "enter text")
        input = input_buffer.to_s
        if input.empty?
          return [[
            ["›", prompt_style],
            [" #{placeholder}", Style::MUTED]
          ]]
        end

        chars = input.chars
        cursor = input_cursor.nil? ? nil : input_cursor.to_i.clamp(0, chars.length)
        spans = row_spans(input, available_width(input, width))
        cursor_row, cursor_column = cursor.nil? ? [nil, nil] : cursor_location(spans, cursor)
        selection_range = normalized_selection_range(selection, chars.length)
        paste_ranges = PasteRegistry.marker_ranges_in(input)

        spans.each_with_index.map do |span, index|
          line_segments(
            chars,
            span,
            first_line: index.zero?,
            cursor_column: index == cursor_row ? cursor_column : nil,
            selection_range: selection_range,
            prompt_style: prompt_style,
            paste_ranges: paste_ranges
          )
        end
      end

      def vertical_cursor(input_buffer, input_cursor, direction:, width: nil)
        input = input_buffer.to_s
        cursor = input_cursor.to_i.clamp(0, input.chars.length)
        spans = row_spans(input, available_width(input, width))
        return cursor if spans.empty?

        row, column = cursor_location(spans, cursor)
        target_row = direction.to_sym == :up ? row - 1 : row + 1
        return cursor unless target_row.between?(0, spans.length - 1)

        target = spans.fetch(target_row)
        target.fetch(:start) + [column, target.fetch(:length)].min
      end

      def cursor_row(input_buffer, input_cursor, width: nil)
        spans = row_spans(input_buffer.to_s, available_width(input_buffer, width))
        return 0 if spans.empty?

        cursor_location(spans, input_cursor.to_i.clamp(0, input_buffer.to_s.chars.length)).first
      end

      def available_width(input_buffer, width)
        return [width.to_i - 2, 1].max if width

        [input_buffer.to_s.chars.length, 1].max
      end

      # Character spans for visual rows. Hard newlines and soft wraps both map
      # back to exact buffer offsets, which keeps vertical movement and cursor
      # rendering in agreement.
      def row_spans(input_buffer, available_width)
        spans = []
        index = 0
        input_buffer.to_s.split("\n", -1).each do |logical_line|
          line_length = logical_line.chars.length
          if line_length.zero?
            spans << { start: index, length: 0 }
          else
            offset = 0
            while offset < line_length
              length = [available_width, line_length - offset].min
              spans << { start: index + offset, length: length }
              offset += length
            end
          end
          index += line_length + 1
        end
        spans
      end

      def cursor_location(spans, cursor)
        spans.each_with_index do |span, index|
          finish = span.fetch(:start) + span.fetch(:length)
          return [index, cursor - span.fetch(:start)] if cursor < finish
          next unless cursor == finish

          next_span = spans[index + 1]
          # A cursor at a soft-wrap boundary belongs to the continuation row. A
          # hard newline has a one-character gap and therefore stays on this row.
          return [index, cursor - span.fetch(:start)] if next_span.nil? || next_span.fetch(:start) > cursor

          return [index + 1, 0]
        end

        last_span = spans.last
        [[spans.length - 1, 0].max, last_span ? last_span.fetch(:length) : 0]
      end

      def normalized_selection_range(selection, buffer_length)
        return nil unless selection.is_a?(Hash)

        start_index = selection.fetch("start", 0).to_i.clamp(0, buffer_length)
        finish_index = selection.fetch("end", 0).to_i.clamp(0, buffer_length)
        return nil if finish_index <= start_index

        (start_index...finish_index)
      end

      def line_segments(chars, span, first_line:, cursor_column:, selection_range:,
                        prompt_style:, paste_ranges: [])
        prefix = first_line ? "› " : "  "
        segments = [[prefix, first_line ? prompt_style : Style::DIM]]
        run = +""
        run_style = nil

        span.fetch(:length).times do |offset|
          index = span.fetch(:start) + offset
          if cursor_column == offset
            segments << [run.dup, run_style] unless run.empty?
            run.clear
            segments << ["_", Style::ACCENT_BOLD]
          end

          style = if selection_range&.include?(index)
                    Style::SELECTION
                  elsif paste_ranges.any? { |range| range.cover?(index) }
                    Style::ACCENT
                  else
                    Style::TEXT
                  end
          if style != run_style
            segments << [run.dup, run_style] unless run.empty?
            run.clear
            run_style = style
          end
          run << chars[index].to_s
        end

        segments << [run.dup, run_style] unless run.empty?
        segments << ["_", Style::ACCENT_BOLD] if cursor_column && cursor_column >= span.fetch(:length)
        segments
      end
      private_class_method :normalized_selection_range, :line_segments
    end
  end
end
