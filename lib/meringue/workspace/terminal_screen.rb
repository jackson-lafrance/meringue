# frozen_string_literal: true

module Meringue
  module Workspace
    # Small VT-compatible screen model for rendering a shell PTY inside the TUI.
    # It implements cursor/erase/scroll sequences and preserves SGR styling
    # emitted by common shells; unsupported private modes are safely ignored.
    class TerminalScreen
      DEFAULT_ROWS = TerminalSession::DEFAULT_ROWS
      DEFAULT_COLUMNS = TerminalSession::DEFAULT_COLUMNS

      def initialize(rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS)
        @rows = positive_dimension(rows, DEFAULT_ROWS)
        @columns = positive_dimension(columns, DEFAULT_COLUMNS)
        @cells = Array.new(@rows) { [] }
        @styles = Array.new(@rows) { [] }
        @current_style = nil
        @cursor_row = 0
        @cursor_column = 0
        @saved_cursor = [0, 0]
        @parser_state = :text
        @sequence = +""
        @pending_bytes = +"".b
        @revision = 0
        @render_snapshot_revision = nil
        @render_snapshot = nil
      end

      attr_reader :rows, :columns

      # Monotonic counter bumped whenever fed bytes or a resize change the
      # screen. Renderers use it to reuse cached lines instead of re-laying out
      # an unchanged screen on every frame.
      attr_reader :revision

      def cursor
        [@cursor_row, @cursor_column]
      end

      # PTY reads split wherever the kernel happens to break, so a multi-byte
      # character (a Nerd Font icon, box drawing, emoji) can straddle two chunks.
      # An incomplete trailing sequence is held back instead of being scrubbed
      # into replacement characters, which is what turned glyphs into garbage.
      def feed(bytes)
        buffer = @pending_bytes.empty? ? bytes.to_s.b : (@pending_bytes + bytes.to_s.b)
        return self if buffer.empty?

        held = incomplete_tail_length(buffer)
        if held.positive?
          @pending_bytes = buffer.byteslice(buffer.bytesize - held, held)
          buffer = buffer.byteslice(0, buffer.bytesize - held)
        else
          @pending_bytes = +"".b
        end
        return self if buffer.empty?

        buffer.force_encoding(Encoding::UTF_8).scrub.each_char { |character| consume(character) }
        @revision += 1
        self
      end

      def resize(rows:, columns:)
        new_rows = positive_dimension(rows, @rows)
        new_columns = positive_dimension(columns, @columns)
        return self if new_rows == @rows && new_columns == @columns

        @revision += 1
        if new_rows < @rows
          start_row = [@cursor_row - new_rows + 1, 0].max
          @cells = @cells.slice(start_row, new_rows) || []
          @styles = @styles.slice(start_row, new_rows) || []
          @cursor_row -= start_row
          @saved_cursor[0] -= start_row
        elsif new_rows > @rows
          missing = new_rows - @cells.length
          @cells.concat(Array.new(missing) { [] })
          @styles.concat(Array.new(missing) { [] })
        end
        @cells.each { |line| line.slice!(new_columns..) if line.length > new_columns }
        @styles.each { |line| line.slice!(new_columns..) if line.length > new_columns }
        @rows = new_rows
        @columns = new_columns
        @cursor_row = @cursor_row.clamp(0, @rows - 1)
        @cursor_column = @cursor_column.clamp(0, @columns - 1)
        self
      end

      def lines
        render_snapshot.fetch("lines").map(&:dup)
      end

      # Styled segments preserve child-process SGR colors without allowing raw
      # PTY escape sequences to enter Canvas content. Public arrays remain
      # mutable for compatibility, while focused renderers use render_snapshot
      # to share the immutable cached representation directly.
      def styled_lines
        render_snapshot.fetch("styled_lines").map do |line|
          line.map { |text, style| [text.dup, style] }
        end
      end

      # Builds plain and styled rows together once per screen revision. Focused
      # sessions are sampled on a low-latency cadence even when idle; sharing
      # this deeply frozen snapshot keeps those samples from reconstructing the
      # complete PTY viewport and competing with dashboard chat input.
      def render_snapshot
        return @render_snapshot if @render_snapshot && @render_snapshot_revision == @revision

        indexes = visible_row_indexes
        plain_lines = []
        styled = []
        indexes.each do |row_index|
          chars = @cells[row_index]
          styles = @styles[row_index]
          plain_lines << chars.join.rstrip.freeze
          length = visible_line_length(chars, styles)
          if length.zero?
            styled << [].freeze
            next
          end

          segments = []
          chars.first(length).each_with_index do |character, column|
            style = styles[column]
            if segments.last && segments.last[1] == style
              segments.last[0] << character
            else
              segments << [+"#{character}", style]
            end
          end
          styled << segments.map do |text, style|
            [text.freeze, style.nil? || style.frozen? ? style : style.dup.freeze].freeze
          end.freeze
        end

        @render_snapshot_revision = @revision
        @render_snapshot = {
          "lines" => plain_lines.freeze,
          "styled_lines" => styled.freeze,
          "cursor" => cursor.freeze,
          "revision" => @revision
        }.freeze
      end

      private

      # Bytes of an unfinished UTF-8 sequence at the end of +buffer+, or 0 when it
      # already ends on a character boundary. Never holds more than one sequence.
      def incomplete_tail_length(buffer)
        length = buffer.bytesize
        index = length - 1
        while index >= 0 && (length - index) <= 4
          byte = buffer.getbyte(index)
          return 0 if byte < 0x80

          if byte >= 0xC0
            expected = if byte >= 0xF0
                         4
                       elsif byte >= 0xE0
                         3
                       else
                         2
                       end
            have = length - index
            return have < expected ? have : 0
          end

          index -= 1
        end
        0
      end

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
        when :charset
          consume_charset(character)
        end
      end

      # Charset designation and DEC private single-parameter escapes. Their final
      # byte is a printable character, so failing to consume it prints debris:
      # terminfo's sgr0 is "ESC ( B ESC [ m", which leaked a literal "B" into
      # shell output for every attribute reset.
      def consume_charset(character)
        # Multi-byte designators (for example "ESC ( % 5") take one more byte.
        return if character == "%"

        @parser_state = :text
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
        when "]", "P", "_", "^", "X"
          # OSC, DCS, APC, PM, and SOS all carry a string payload terminated by
          # ST or BEL. Their payloads are never screen content.
          @parser_state = :osc
        when "(", ")", "*", "+", "-", ".", "/", "#", "%", " "
          @parser_state = :charset
        when "E"
          @cursor_column = 0
          line_feed
          @parser_state = :text
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
        when "m" then apply_sgr(sequence)
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
        styles = @styles[@cursor_row]
        if line.length < @cursor_column
          line.fill(" ", line.length...@cursor_column)
          styles.fill(nil, styles.length...@cursor_column)
        end
        # Freeze/dedupe stored characters so no reader can mutate the screen by
        # appending to a cell string it received.
        line[@cursor_column] = -character
        styles[@cursor_column] = @current_style
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
        @styles.shift
        @cells << []
        @styles << []
      end

      def scroll_down
        @cells.pop
        @styles.pop
        @cells.unshift([])
        @styles.unshift([])
      end

      def erase_display(mode)
        case mode
        when 1
          (0...@cursor_row).each { |row| clear_row(row) }
          erase_line(1)
        when 2, 3
          clear_screen
        else
          erase_line(0)
          ((@cursor_row + 1)...@rows).each { |row| clear_row(row) }
        end
      end

      def erase_line(mode)
        line = @cells[@cursor_row]
        styles = @styles[@cursor_row]
        case mode
        when 1
          finish = [@cursor_column, @columns - 1].min
          line.fill(" ", 0..finish)
          styles.fill(nil, 0..finish)
        when 2
          clear_row(@cursor_row)
        else
          line.slice!(@cursor_column..) if line.length > @cursor_column
          styles.slice!(@cursor_column..) if styles.length > @cursor_column
        end
      end

      def delete_characters(count)
        @cells[@cursor_row].slice!(@cursor_column, count)
        @styles[@cursor_row].slice!(@cursor_column, count)
      end

      def insert_blanks(count)
        line = @cells[@cursor_row]
        styles = @styles[@cursor_row]
        line.insert(@cursor_column, *Array.new(count, " "))
        styles.insert(@cursor_column, *Array.new(count))
        line.slice!(@columns..) if line.length > @columns
        styles.slice!(@columns..) if styles.length > @columns
      end

      def insert_lines(count)
        count.times do
          @cells.insert(@cursor_row, [])
          @styles.insert(@cursor_row, [])
          @cells.pop
          @styles.pop
        end
      end

      def delete_lines(count)
        count.times do
          @cells.delete_at(@cursor_row)
          @styles.delete_at(@cursor_row)
          @cells << []
          @styles << []
        end
      end

      def clear_screen
        @cells = Array.new(@rows) { [] }
        @styles = Array.new(@rows) { [] }
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

      def apply_sgr(sequence)
        parts = sequence.to_s.split(";", -1)
        parts = ["0"] if parts.empty? || parts.all?(&:empty?)
        last_reset = parts.rindex { |part| part.empty? || part.to_i.zero? }
        if last_reset
          @current_style = nil
          parts = parts.drop(last_reset + 1)
        end
        return if parts.empty?

        addition = "\e[#{parts.join(";")}m"
        @current_style = "#{@current_style}#{addition}"
      end

      def clear_row(row)
        @cells[row] = []
        @styles[row] = []
      end

      def visible_row_indexes
        content_row = @cells.each_index.reverse_each.find do |row_index|
          line = @cells[row_index]
          styles = @styles[row_index]
          line.each_index.any? do |column|
            line[column].to_s != " " || !styles[column].to_s.empty?
          end
        end
        finish = [content_row || 0, @cursor_row].max
        (0..finish).to_a
      end

      # A terminal row can be visually meaningful even when every character is a
      # space: interactive programs use styled padding for selected/highlighted
      # rows. Keep those cells so the ANSI background reaches the viewport
      # edge instead of being mistaken for trailing empty space.
      def visible_line_length(chars, styles = nil)
        index = chars.each_index.reverse_each.find do |column|
          chars[column].to_s != " " || (styles && !styles[column].to_s.empty?)
        end
        index ? index + 1 : 0
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
