# frozen_string_literal: true

module Meringue
  module TUI
    # Pane-scoped text selection geometry.
    #
    # Logs selections are stored in content coordinates (index into the wrapped
    # log lines plus a column into that line) so highlights follow the content
    # when the pane scrolls, and so a drag can never leak into another pane.
    module Selection
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
