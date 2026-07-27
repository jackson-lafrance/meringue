# frozen_string_literal: true

module Meringue
  module Workspace
    # Small VT-compatible screen model for rendering a shell PTY inside the TUI.
    # It implements the cursor/erase/scroll sequences emitted by common shells;
    # unsupported styling and private modes are safely ignored.
    class TerminalScreen
      DEFAULT_ROWS = TerminalSession::DEFAULT_ROWS
      DEFAULT_COLUMNS = TerminalSession::DEFAULT_COLUMNS

      def initialize(rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS)
        @rows = positive_dimension(rows, DEFAULT_ROWS)
        @columns = positive_dimension(columns, DEFAULT_COLUMNS)
        @cells = Array.new(@rows) { [] }
        @cursor_row = 0
        @cursor_column = 0
        @saved_cursor = [0, 0]
        @parser_state = :text
        @sequence = +""
      end

      attr_reader :rows, :columns

      def feed(bytes)
        bytes.to_s.b.force_encoding(Encoding::UTF_8).scrub.each_char { |character| consume(character) }
        self
      end

      def resize(rows:, columns:)
        new_rows = positive_dimension(rows, @rows)
        new_columns = positive_dimension(columns, @columns)
        @cells = @cells.last(new_rows)
        @cells.unshift(*Array.new(new_rows - @cells.length) { [] }) if @cells.length < new_rows
        @cells.each { |line| line.slice!(new_columns..) if line.length > new_columns }
        @rows = new_rows
        @columns = new_columns
        @cursor_row = @cursor_row.clamp(0, @rows - 1)
        @cursor_column = @cursor_column.clamp(0, @columns - 1)
        self
      end

      def lines
        @cells.map { |line| line.join.rstrip }
      end

      private

      def consume(character)
        case @parser_state
        when :text
          consume_text(character)
        when :escape
          consume_escape(character)
        when :csi
          consume_csi(character)
        when :osc
          consume_osc(character)
        when :osc_escape
          @parser_state = character == "\\" ? :text : :osc
        end
      end

      def consume_text(character)
        case character
        when "\e"
          @parser_state = :escape
        when "\r"
          @cursor_column = 0
        when "\n", "\v", "\f"
          line_feed
        when "\b"
          @cursor_column = [@cursor_column - 1, 0].max
        when "\t"
          @cursor_column = [((@cursor_column / 8) + 1) * 8, @columns - 1].min
        when "\a", "\0"
          nil
        else
          write_character(character) if character >= " " && character != "\u007f"
        end
      end

      def consume_escape(character)
        case character
        when "["
          @sequence.clear
          @parser_state = :csi
        when "]"
          @parser_state = :osc
        when "7"
          save_cursor
          @parser_state = :text
        when "8"
          restore_cursor
          @parser_state = :text
        when "D"
          line_feed
          @parser_state = :text
        when "M"
          reverse_index
          @parser_state = :text
        when "c"
          clear_screen
          @parser_state = :text
        else
          @parser_state = :text
        end
      end

      def consume_csi(character)
        if character.ord.between?(0x40, 0x7e)
          apply_csi(character, @sequence)
          @sequence.clear
          @parser_state = :text
        elsif @sequence.length < 128
          @sequence << character
        else
          @sequence.clear
          @parser_state = :text
        end
      end

      def consume_osc(character)
        case character
        when "\a"
          @parser_state = :text
        when "\e"
          @parser_state = :osc_escape
        end
      end

      def apply_csi(final, sequence)
        private_mode = sequence.start_with?("?", ">", "!")
        values = sequence.sub(/\A[?>!]/, "").split(";", -1).map { |value| value.empty? ? nil : value.to_i }
        count = [values.first.to_i, 1].max

        case final
        when "A" then @cursor_row = [@cursor_row - count, 0].max
        when "B" then @cursor_row = [@cursor_row + count, @rows - 1].min
        when "C" then @cursor_column = [@cursor_column + count, @columns - 1].min
        when "D" then @cursor_column = [@cursor_column - count, 0].max
        when "E"
          @cursor_row = [@cursor_row + count, @rows - 1].min
          @cursor_column = 0
        when "F"
          @cursor_row = [@cursor_row - count, 0].max
          @cursor_column = 0
        when "G" then @cursor_column = position(values.first, @columns)
        when "d" then @cursor_row = position(values.first, @rows)
        when "H", "f"
          @cursor_row = position(values[0], @rows)
          @cursor_column = position(values[1], @columns)
        when "J" then erase_display(values.first.to_i)
        when "K" then erase_line(values.first.to_i)
        when "S" then count.times { scroll_up }
        when "T" then count.times { scroll_down }
        when "P" then delete_characters(count)
        when "@" then insert_blanks(count)
        when "L" then insert_lines(count)
        when "M" then delete_lines(count)
        when "s" then save_cursor
        when "u" then restore_cursor
        when "h", "l"
          clear_screen if private_mode && values.include?(1049)
        end
      end

      def write_character(character)
        if @cursor_column >= @columns
          @cursor_column = 0
          line_feed
        end
        line = @cells[@cursor_row]
        line.fill(" ", line.length...@cursor_column) if line.length < @cursor_column
        line[@cursor_column] = character
        @cursor_column += 1
      end

      def line_feed
        if @cursor_row >= @rows - 1
          scroll_up
        else
          @cursor_row += 1
        end
      end

      def reverse_index
        if @cursor_row.zero?
          scroll_down
        else
          @cursor_row -= 1
        end
      end

      def scroll_up
        @cells.shift
        @cells << []
      end

      def scroll_down
        @cells.pop
        @cells.unshift([])
      end

      def erase_display(mode)
        case mode
        when 1
          (0...@cursor_row).each { |row| @cells[row] = [] }
          erase_line(1)
        when 2, 3
          clear_screen
        else
          erase_line(0)
          ((@cursor_row + 1)...@rows).each { |row| @cells[row] = [] }
        end
      end

      def erase_line(mode)
        line = @cells[@cursor_row]
        case mode
        when 1
          finish = [@cursor_column, @columns - 1].min
          line.fill(" ", 0..finish)
        when 2
          @cells[@cursor_row] = []
        else
          line.slice!(@cursor_column..) if line.length > @cursor_column
        end
      end

      def delete_characters(count)
        @cells[@cursor_row].slice!(@cursor_column, count)
      end

      def insert_blanks(count)
        line = @cells[@cursor_row]
        line.insert(@cursor_column, *Array.new(count, " "))
        line.slice!(@columns..) if line.length > @columns
      end

      def insert_lines(count)
        count.times do
          @cells.insert(@cursor_row, [])
          @cells.pop
        end
      end

      def delete_lines(count)
        count.times do
          @cells.delete_at(@cursor_row)
          @cells << []
        end
      end

      def clear_screen
        @cells = Array.new(@rows) { [] }
        @cursor_row = 0
        @cursor_column = 0
      end

      def save_cursor
        @saved_cursor = [@cursor_row, @cursor_column]
      end

      def restore_cursor
        @cursor_row = @saved_cursor[0].clamp(0, @rows - 1)
        @cursor_column = @saved_cursor[1].clamp(0, @columns - 1)
      end

      def position(value, maximum)
        [[value.to_i, 1].max - 1, maximum - 1].min
      end

      def positive_dimension(value, fallback)
        parsed = Integer(value)
        parsed.positive? ? parsed : fallback
      rescue ArgumentError, TypeError
        fallback
      end
    end
  end
end
