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
      ENABLE_MOUSE = "\e[?1000h\e[?1006h"
      DISABLE_MOUSE = "\e[?1006l\e[?1003l\e[?1002l\e[?1000l"
      BRACKETED_PASTE_START = "\e[200~"
      BRACKETED_PASTE_END = "\e[201~"
      ESCAPE_READ_TIMEOUT = 0.01
      PASTE_READ_TIMEOUT = 0.05
      CLEAR_SCREEN = "\e[2J\e[H"
      HOME = "\e[H"
      CLEAR_LINE = "\e[K"

      attr_reader :input, :output

      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
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
        output.write(ENABLE_MOUSE)
        output.write(CLEAR_SCREEN)
        output.flush
        @last_frame = nil

        yield
      ensure
        if interactive?
          output.write(DISABLE_MOUSE)
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

      def write_frame(frame)
        if interactive?
          write_interactive_frame(frame)
        else
          output.write(frame)
        end
        output.flush
      end

      def read_key(timeout:)
        return nil unless interactive?

        ready = IO.select([input], nil, nil, timeout)
        return nil unless ready

        key = input.getch
        return read_escape_sequence(key) if key == "\e"

        read_pending_plain_text(key)
      end

      private

      def read_escape_sequence(prefix)
        sequence = prefix.dup
        while IO.select([input], nil, nil, ESCAPE_READ_TIMEOUT)
          sequence << input.getch
          return read_bracketed_paste(sequence) if sequence == BRACKETED_PASTE_START
          break if complete_escape_sequence?(sequence)
          break if sequence.length >= 32
        end
        parse_mouse_sequence(sequence) || sequence
      end

      def read_bracketed_paste(sequence)
        until sequence.end_with?(BRACKETED_PASTE_END)
          ready = IO.select([input], nil, nil, PASTE_READ_TIMEOUT)
          break unless ready

          sequence << input.getch
        end

        if sequence.end_with?(BRACKETED_PASTE_END)
          text = sequence[BRACKETED_PASTE_START.length...-BRACKETED_PASTE_END.length]
          { "type" => "paste", "text" => text.to_s }
        else
          sequence
        end
      end

      def read_pending_plain_text(prefix)
        text = prefix.dup
        while IO.select([input], nil, nil, 0)
          break if text.end_with?("\e")

          text << input.getch
        end
        text
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
        kind = case button
               when 64
                 "wheel_up"
               when 65
                 "wheel_down"
               else
                 "button"
               end
        {
          "type" => "mouse",
          "button" => button,
          "x" => match[2].to_i,
          "y" => match[3].to_i,
          "pressed" => match[4] == "M",
          "kind" => kind
        }
      end

      def write_interactive_frame(frame)
        if @last_frame.nil? || frame.lines.length != @last_frame.lines.length
          output.write(CLEAR_SCREEN)
          output.write(frame.gsub("\n", "\r\n"))
        else
          write_frame_diff(@last_frame, frame)
        end
        @last_frame = frame.dup
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
