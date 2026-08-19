# frozen_string_literal: true

module Meringue
  module TUI
    # Pane-scoped text selection geometry.
    #
    # Logs selections are stored in content coordinates (index into the wrapped
    # log lines plus a column into that line) so highlights follow the content
    # when the pane scrolls, and so a drag can never leak into another pane.
    module Selection
      # Segment metadata used by renderers for chrome that occupies display
      # columns but should never become clipboard text. Selection coordinates
      # remain tied to what is visible; extraction skips only the intersecting
      # display-only segment instead of guessing from a glyph or prefix.
      DISPLAY_ONLY = :display_only

      # Characters that read as one "word" when the user double-clicks.
      #
      # Alphanumerics and underscore are the core. The joiners are only part of a
      # word when they sit between word characters, which is what keeps ids like
      # P1-I18-W2, paths like lib/meringue/tui/app.rb:643, and URLs whole while
      # still selecting "done" out of "done." and "yes" out of "yes,".
      WORD_CORE_PATTERN = /[[:alnum:]_]/.freeze
      WORD_JOINERS = "-./\\:@~+#%&=?!,;'".freeze

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

      # Column range (exclusive end) of the word under +column+, the way a
      # terminal double-click behaves. Returns nil when there is nothing
      # word-like to select there (blank columns and newlines), so a double-click
      # in empty space is a no-op instead of copying whitespace.
      def word_range(text, column)
        chars = text.to_s.chars
        return nil if chars.empty?

        index = column.to_i.clamp(0, chars.length)
        # Clicking past the end of a line grabs the last character's word, which
        # is what editors do when you click in the trailing blank area.
        index -= 1 if index >= chars.length
        return nil if index.negative?

        character_group = character_group(chars.fetch(index))
        return nil unless %i[word symbol].include?(character_group)

        start_index = index
        start_index -= 1 while start_index.positive? && character_group(chars.fetch(start_index - 1)) == character_group
        finish_index = index + 1
        finish_index += 1 while finish_index < chars.length && character_group(chars.fetch(finish_index)) == character_group
        return (start_index...finish_index) if character_group == :symbol

        trimmed_word_range(chars, start_index, finish_index, index)
      end

      # Trailing/leading joiners are dropped, but never the clicked column, so
      # clicking the period in "done." still selects something visible.
      def trimmed_word_range(chars, start_index, finish_index, index)
        finish_index -= 1 while finish_index - 1 > index && word_joiner?(chars.fetch(finish_index - 1))
        start_index += 1 while start_index < index && word_joiner?(chars.fetch(start_index))
        (start_index...finish_index)
      end

      def character_group(character)
        text = character.to_s
        return :newline if text == "\n"
        return :blank if text.empty? || text.match?(/\s/)
        return :word if word_character?(text)

        :symbol
      end

      def word_character?(character)
        text = character.to_s
        return false if text.empty?

        text.match?(WORD_CORE_PATTERN) || WORD_JOINERS.include?(text)
      end

      def word_joiner?(character)
        text = character.to_s
        return false if text.empty?

        WORD_JOINERS.include?(text) && !text.match?(WORD_CORE_PATTERN)
      end

      # Marks one [text, style] Canvas segment as visible but not copyable.
      # Existing segment consumers read only the first two values, so the marker
      # changes clipboard extraction without changing layout or styling.
      def display_only_segment(segment, style = nil)
        return segment if display_only_segment?(segment)

        if segment.is_a?(Array)
          [segment.fetch(0, "").to_s, segment.fetch(1, style), DISPLAY_ONLY]
        else
          [segment.to_s, style, DISPLAY_ONLY]
        end
      end

      def display_only_segment?(segment)
        segment.is_a?(Array) && segment.fetch(2, nil) == DISPLAY_ONLY
      end

      # Joins selected portions of rendered lines into clipboard-ready text.
      # Values may be plain strings or arrays of Canvas segments. Display
      # columns still determine the selected range, while segments explicitly
      # marked as presentation are omitted from the resulting text.
      def text_for(selection, lines)
        return "" unless selection.is_a?(Hash)
        return "" if empty?(selection)

        start_line = (selection.fetch("start", {}) || {}).fetch("line", 0).to_i
        end_line = (selection.fetch("end", {}) || {}).fetch("line", 0).to_i
        (start_line..end_line).map do |line_index|
          line = lines.fetch(line_index, "")
          range = columns_for(selection, line_index, display_length(line))
          range ? text_from_range(line, range) : ""
        end.join("\n")
      end

      def display_length(line)
        return line.to_s.length unless line.is_a?(Array)

        line.sum { |segment| segment_text(segment).length }
      end

      def text_from_range(line, range)
        return line.to_s[range].to_s unless line.is_a?(Array)

        selected = +""
        display_offset = 0
        line.each do |segment|
          text = segment_text(segment)
          segment_start = display_offset
          segment_end = segment_start + text.length
          display_offset = segment_end
          next if display_only_segment?(segment)

          overlap_start = [range.begin, segment_start].max
          overlap_end = [range.end, segment_end].min
          next if overlap_end <= overlap_start

          selected << text[(overlap_start - segment_start)...(overlap_end - segment_start)].to_s
        end
        selected
      end

      def segment_text(segment)
        segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s
      end
    end
  end
end
