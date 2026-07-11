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
      CLEAR_SCREEN = "\e[2J\e[H"
      HOME = "\e[H"

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
        output.write(CLEAR_SCREEN)
        output.flush

        yield
      ensure
        if interactive?
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
        output.write(CLEAR_SCREEN) if interactive?
        output.write(frame)
        output.flush
      end

      def read_key(timeout:)
        return nil unless interactive?

        ready = IO.select([input], nil, nil, timeout)
        return nil unless ready

        input.getch
      end
    end
  end
end
