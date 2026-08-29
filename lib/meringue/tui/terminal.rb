# frozen_string_literal: true

require "io/console"

module Meringue
  module TUI
    class Terminal
      DEFAULT_WIDTH = 100
      DEFAULT_HEIGHT = 32
      ENTER_ALT_SCREEN = "\e[?1049h"
      EXIT_ALT_SCREEN = "\e[?1049l"
      HIDE_CURSOR = "\e[?25l"
      SHOW_CURSOR = "\e[?25h"
      DISABLE_AUTOWRAP = "\e[?7l"
      ENABLE_AUTOWRAP = "\e[?7h"
      ENABLE_BRACKETED_PASTE = "\e[?2004h"
      DISABLE_BRACKETED_PASTE = "\e[?2004l"
      # Ask compatible terminals to report modified Enter separately from plain Enter.
      # Kitty/CSI-u uses \e[>1u / \e[<u; xterm modifyOtherKeys uses \e[>4;2m / \e[>4;0m.
      ENABLE_KEYBOARD_DISAMBIGUATION = "\e[>1u\e[>4;2m"
      DISABLE_KEYBOARD_DISAMBIGUATION = "\e[<u\e[>4;0m"
      # 1000 reports button press/release, 1002 adds motion reports while a
      # button is held (native drag selection), 1006 is SGR extended coordinates.
      ENABLE_MOUSE = "\e[?1000h\e[?1002h\e[?1006h"
      DISABLE_MOUSE = "\e[?1006l\e[?1003l\e[?1002l\e[?1000l"
      BRACKETED_PASTE_START = "\e[200~"
      BRACKETED_PASTE_END = "\e[201~"
      ESCAPE_READ_TIMEOUT = 0.01
      PASTE_READ_TIMEOUT = 0.05
      # A 3000-line paste is a quarter of a megabyte. Reading it one `getch` at a
      # time is a syscall per byte, which is half a second of latency before the
      # app has even seen the text, so bulk input is read in chunks instead.
      READ_CHUNK_BYTES = 65_536
      MAX_COALESCED_MOUSE_WHEEL_EVENTS = 200
      CLEAR_SCREEN = "\e[2J\e[H"
      HOME = "\e[H"
      CLEAR_LINE = "\e[K"
      # Canvas frames are rectangular in terminal cells, but colored rows carry
      # extra CSI bytes for every SGR run. Geometry must be measured after those
      # control sequences are removed or streaming styled output looks like a
      # resize and triggers a full-screen clear.
      ANSI_CSI_SEQUENCE = /\e\[[0-?]*[ -\/]*[@-~]/.freeze

      attr_reader :input, :output

      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
        @pending_keys = []
        # Raw bytes read past the end of a chunked read (the keystrokes that
        # arrived in the same chunk as a paste terminator). They are consumed
        # before the input stream so nothing typed during a paste is lost.
        @pending_input = +""
      end

      def interactive?
        input.respond_to?(:tty?) && output.respond_to?(:tty?) && input.tty? && output.tty?
      end

      def dimensions
        columns = ENV.fetch("COLUMNS", DEFAULT_WIDTH).to_i
        rows = ENV.fetch("LINES", DEFAULT_HEIGHT).to_i

        if interactive? && input.respond_to?(:winsize)
          tty_rows, tty_columns = input.winsize
          rows = tty_rows if tty_rows&.positive?
          columns = tty_columns if tty_columns&.positive?
        end

        columns -= 1 if interactive? && columns > 1
        rows -= 1 if interactive? && rows > 1

        [[columns, 1].max, [rows, 1].max]
      rescue SystemCallError, IOError
        [DEFAULT_WIDTH, DEFAULT_HEIGHT]
      end

      def with_screen
        return yield unless interactive?

        output.write(ENTER_ALT_SCREEN)
        output.write(HIDE_CURSOR)
        output.write(DISABLE_AUTOWRAP)
        output.write(ENABLE_BRACKETED_PASTE)
        output.write(ENABLE_KEYBOARD_DISAMBIGUATION)
        output.write(ENABLE_MOUSE)
        output.write(CLEAR_SCREEN)
        output.flush
        @last_frame = nil

        yield
      ensure
        if interactive?
          output.write(DISABLE_MOUSE)
          output.write(DISABLE_KEYBOARD_DISAMBIGUATION)
          output.write(DISABLE_BRACKETED_PASTE)
          output.write(ENABLE_AUTOWRAP)
          output.write(SHOW_CURSOR)
          output.write(EXIT_ALT_SCREEN)
          output.flush
        end
      end

      def raw
        return yield unless interactive? && input.respond_to?(:raw)

        input.raw { yield }
      end

      # Temporarily give the terminal back to a full-screen external editor.
      # Re-enter the dashboard screen and invalidate its diff baseline even when
      # the editor fails, so stale rows cannot be patched over the editor output.
      def with_external_editor
        return yield unless interactive?

        input.cooked do
          output.write(DISABLE_MOUSE)
          output.write(DISABLE_KEYBOARD_DISAMBIGUATION)
          output.write(DISABLE_BRACKETED_PASTE)
          output.write(ENABLE_AUTOWRAP)
          output.write(SHOW_CURSOR)
          output.write(EXIT_ALT_SCREEN)
          output.flush
          yield
        ensure
          output.write(ENTER_ALT_SCREEN)
          output.write(HIDE_CURSOR)
          output.write(DISABLE_AUTOWRAP)
          output.write(ENABLE_BRACKETED_PASTE)
          output.write(ENABLE_KEYBOARD_DISAMBIGUATION)
          output.write(ENABLE_MOUSE)
          output.write(CLEAR_SCREEN)
          output.flush
          invalidate_frame!
        end
      end

      def write_frame(frame)
        if interactive?
          write_interactive_frame(frame)
        else
          output.write(frame)
        end
        output.flush
      end

      # A major layout transition (dashboard ↔ focused workspace) changes
      # nearly every row. Discarding the diff baseline lets the next frame be
      # written as one clear/full-frame update instead of visible row patches.
      def invalidate_frame!
        @last_frame = nil
      end

      def read_key(timeout:)
        return nil unless interactive?

        key = if @pending_keys.empty?
                read_next_key(timeout: timeout)
              else
                @pending_keys.shift
              end
        return nil unless key

        return coalesce_mouse_wheel_events(key) if mouse_wheel_event?(key)
        return coalesce_mouse_motion_events(key) if mouse_motion_event?(key)

        key
      end

      private

      def read_next_key(timeout:)
        key = next_character(timeout: timeout)
        return nil unless key

        return read_escape_sequence(key) if key == "\e"

        read_pending_plain_text(key)
      end

      def read_escape_sequence(prefix)
        sequence = prefix.dup
        while (character = next_character(timeout: ESCAPE_READ_TIMEOUT))
          sequence << character
          return read_bracketed_paste(sequence) if sequence == BRACKETED_PASTE_START
          break if complete_escape_sequence?(sequence)
          break if sequence.length >= 32
        end
        parse_mouse_sequence(sequence) || sequence
      end

      # The body of a paste is bulk data, not keystrokes: it is read in chunks
      # and searched for the terminator by byte offset, so the cost is a handful
      # of reads instead of one per pasted character. Anything a chunk carries
      # past the terminator is pushed back for the next key read.
      def read_bracketed_paste(sequence)
        buffer = sequence.dup.b
        search_from = 0
        while (terminator = buffer.index(BRACKETED_PASTE_END, search_from)).nil?
          chunk = read_available_text(timeout: PASTE_READ_TIMEOUT)
          break if chunk.empty?

          search_from = [buffer.bytesize - BRACKETED_PASTE_END.bytesize + 1, 0].max
          buffer << chunk.b
        end

        return buffer.force_encoding(Encoding::UTF_8) unless terminator

        text = buffer.byteslice(BRACKETED_PASTE_START.bytesize, terminator - BRACKETED_PASTE_START.bytesize).to_s
        push_back_input(buffer.byteslice(terminator + BRACKETED_PASTE_END.bytesize, buffer.bytesize).to_s)
        { "type" => "paste", "text" => text.force_encoding(Encoding::UTF_8) }
      end

      # Terminals without bracketed paste deliver a paste as a burst of plain
      # text. Reading that burst in chunks keeps it as cheap as the bracketed
      # form. An escape byte ends the run and is pushed back whole, so a key
      # pressed at the tail of a burst is still parsed as its own escape
      # sequence instead of being glued onto the pasted text.
      def read_pending_plain_text(prefix)
        text = prefix.dup
        loop do
          break if text.end_with?("\e")

          chunk = read_available_text(timeout: 0)
          break if chunk.empty?

          escape_index = chunk.index("\e")
          if escape_index
            text << chunk[0...escape_index]
            push_back_input(chunk[escape_index..].to_s)
            break
          end

          text << chunk
        end
        text
      end

      # Pushed-back bytes are consumed before the input stream, so a key that
      # arrived in the same chunk as a paste is read exactly once and in order.
      def next_character(timeout:)
        character = if @pending_input.empty?
                      IO.select([input], nil, nil, timeout) ? input.getch : nil
                    else
                      @pending_input.slice!(0)
                    end
        return nil if character.nil?

        character.dup.force_encoding(Encoding::UTF_8)
      end

      # Whatever is already available, in one read. Falls back to a single
      # character for inputs that cannot do a non-blocking bulk read.
      def read_available_text(timeout: 0)
        return @pending_input.slice!(0, @pending_input.length) unless @pending_input.empty?
        return "" unless IO.select([input], nil, nil, timeout)
        return input.getch.to_s.dup.force_encoding(Encoding::UTF_8) unless input.respond_to?(:read_nonblock)

        chunk = input.read_nonblock(READ_CHUNK_BYTES, exception: false)
        chunk.is_a?(String) ? chunk.dup.force_encoding(Encoding::UTF_8) : ""
      rescue ArgumentError
        input.getch.to_s.dup.force_encoding(Encoding::UTF_8)
      rescue IO::WaitReadable, EOFError, IOError, SystemCallError
        ""
      end

      def push_back_input(text)
        return if text.to_s.empty?

        @pending_input = "#{text.to_s.dup.force_encoding(Encoding::UTF_8)}#{@pending_input}"
      end

      def complete_escape_sequence?(sequence)
        return true if sequence.match?(/\A\e\[<\d+;\d+;\d+[Mm]\z/)
        return false unless sequence.start_with?("\e[") || sequence.start_with?("\eO")

        sequence.length >= 3 && sequence[-1].match?(/[A-Za-z~]/)
      end

      def parse_mouse_sequence(sequence)
        match = sequence.match(/\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/)
        return nil unless match

        button = match[1].to_i
        {
          "type" => "mouse",
          "button" => button,
          "x" => match[2].to_i,
          "y" => match[3].to_i,
          "pressed" => match[4] == "M",
          "kind" => mouse_event_kind(button),
          "shift" => (button & 4).positive?,
          "alt" => (button & 8).positive?,
          "ctrl" => (button & 16).positive?
        }
      end

      # SGR button bits: 0-1 button number, 4 shift, 8 meta, 16 ctrl,
      # 32 motion, 64 wheel. Mask the modifier bits so Shift-drag and
      # Ctrl-wheel keep reporting the same kind as an unmodified event.
      def mouse_event_kind(button)
        return (button & 1).zero? ? "wheel_up" : "wheel_down" if (button & 64).positive?
        return "motion" if (button & 32).positive?

        "button"
      end

      def mouse_motion_event?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "motion"
      end

      # A drag floods the input with motion reports. Only the newest position
      # matters for selection, so collapse the queued run into one event.
      def coalesce_mouse_motion_events(first_key)
        latest = first_key
        while (next_key = read_next_key(timeout: 0))
          unless mouse_motion_event?(next_key)
            @pending_keys << next_key
            break
          end

          latest = next_key
        end
        latest
      end

      def mouse_wheel_event?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && %w[wheel_up wheel_down].include?(key.fetch("kind", nil))
      end

      def coalesce_mouse_wheel_events(first_key)
        count = [first_key.fetch("count", 1).to_i, 1].max
        while count < MAX_COALESCED_MOUSE_WHEEL_EVENTS
          next_key = read_next_key(timeout: 0)
          break unless next_key

          unless matching_mouse_wheel_event?(first_key, next_key)
            @pending_keys << next_key
            break
          end

          count += [next_key.fetch("count", 1).to_i, 1].max
        end

        first_key.merge("count" => count)
      end

      def matching_mouse_wheel_event?(first_key, next_key)
        mouse_wheel_event?(next_key) && next_key.fetch("kind", nil) == first_key.fetch("kind", nil)
      end

      def write_interactive_frame(frame)
        # A resize can change the viewport width without changing the number of
        # rows. A row diff is not enough in that case: columns that were outside
        # the previous frame can retain stale content, while a frame rendered for
        # a larger viewport can be clipped by the smaller terminal. Repaint the
        # whole screen whenever either frame dimension changes.
        dimensions_changed = @last_frame && frame_dimensions(frame) != frame_dimensions(@last_frame)
        if @last_frame.nil? || dimensions_changed
          output.write(CLEAR_SCREEN)
          output.write(frame.gsub("\n", "\r\n"))
        else
          write_frame_diff(@last_frame, frame)
        end
        @last_frame = frame.dup
      end

      def frame_dimensions(frame)
        lines = frame.to_s.lines(chomp: true)
        visible_width = lines.map { |line| line.gsub(ANSI_CSI_SEQUENCE, "").length }.max.to_i
        [lines.length, visible_width]
      end

      def write_frame_diff(previous_frame, frame)
        previous_lines = previous_frame.lines(chomp: true)
        lines = frame.lines(chomp: true)

        lines.each_with_index do |line, index|
          next if line == previous_lines[index]

          output.write("\e[#{index + 1};1H")
          output.write(line)
          output.write(CLEAR_LINE)
        end
      end
    end
  end
end
