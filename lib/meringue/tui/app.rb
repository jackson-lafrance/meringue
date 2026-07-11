# frozen_string_literal: true

module Meringue
  module TUI
    class App
      DEFAULT_WIDTH = 100
      DEFAULT_HEIGHT = 32
      REFRESH_INTERVAL = 0.2
      QUIT_KEYS = ["q", "Q", "\e", "\u0003", "\u0004"].freeze

      def initialize(layout: Layout.new, input: $stdin, out: $stdout, terminal: nil)
        @layout = layout
        @out = out
        @terminal = terminal || Terminal.new(input: input, output: out)
      end

      def render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT)
        layout.render(state, width: width, height: height)
      end

      def run(state: State::Models.empty_state)
        return render_once(state) unless terminal.interactive?

        terminal.with_screen do
          terminal.raw do
            loop do
              width, height = terminal.dimensions
              terminal.write_frame(render(state, width: width, height: height))
              key = terminal.read_key(timeout: REFRESH_INTERVAL)
              break if quit_key?(key)
            end
          end
        end

        0
      rescue Interrupt
        0
      end

      private

      attr_reader :layout, :out, :terminal

      def render_once(state)
        out.puts render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT)
        0
      end

      def quit_key?(key)
        key && QUIT_KEYS.include?(key)
      end
    end
  end
end
