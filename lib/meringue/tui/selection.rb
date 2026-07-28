# frozen_string_literal: true

module Meringue
  module TUI
    # Pane-scoped text selection geometry.
    #
    # Logs selections are stored in content coordinates (index into the wrapped
    # log lines plus a column into that line) so highlights follow the content
    # when the pane scrolls, and so a drag can never leak into another pane.
    module Selection
      module_function

      def point(line, column)
        { "line" => [line.to_i, 0].max, "column" => [column.to_i, 0].max }
      end

      # Normalizes an anchor/focus pair into ordered start/end points.
      def normalize(pane, anchor, focus)
        return nil unless pane && anchor && focus

        ordered = [anchor, focus].sort_by { |candidate| [candidate.fetch("line", 0).to_i, candidate.fetch("column", 0).to_i] }
        {
          "pane" => pane.to_s,
          "start" => ordered.first,
          "end" => ordered.last
        }
      end

      def empty?(selection)
        return true unless selection.is_a?(Hash)

        selection.fetch("start", nil) == selection.fetch("end", nil)
      end

      def pane(selection)
        selection.is_a?(Hash) ? selection.fetch("pane", nil).to_s : ""
      end

      # Column range (exclusive end) covered on a single content line, or nil
      # when the line is outside the selection.
      def columns_for(selection, line_index, text_length)
        return nil unless selection.is_a?(Hash)
        return nil if empty?(selection)

        start_point = selection.fetch("start", nil) || {}
        end_point = selection.fetch("end", nil) || {}
        start_line = start_point.fetch("line", 0).to_i
        end_line = end_point.fetch("line", 0).to_i
        return nil unless line_index.between?(start_line, end_line)

        text_length = [text_length.to_i, 0].max
        from = line_index == start_line ? start_point.fetch("column", 0).to_i : 0
        to = line_index == end_line ? end_point.fetch("column", 0).to_i : text_length
        from = from.clamp(0, text_length)
        to = to.clamp(0, text_length)
        return nil if to <= from

        (from...to)
      end

      # Joins the selected substrings of `texts` (a Hash of content line index
      # to plain text) into clipboard-ready text.
      def text_for(selection, texts)
        return "" unless selection.is_a?(Hash)
        return "" if empty?(selection)

        start_line = (selection.fetch("start", {}) || {}).fetch("line", 0).to_i
        end_line = (selection.fetch("end", {}) || {}).fetch("line", 0).to_i
        (start_line..end_line).map do |line_index|
          text = texts.fetch(line_index, "").to_s
          range = columns_for(selection, line_index, text.length)
          range ? text[range].to_s : ""
        end.join("\n")
      end
    end
  end
end
