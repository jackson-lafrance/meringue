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

      def render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        layout.render(state, width: width, height: height, color: color)
      end

      def run(state: nil, state_provider: nil)
        state_provider ||= -> { state || State::Models.empty_state }
        return render_once(state_provider.call) unless terminal.interactive?

        terminal.with_screen do
          terminal.raw do
            last_frame = nil

            loop do
              width, height = terminal.dimensions
              frame = render(state_provider.call, width: width, height: height, color: true)
              if frame != last_frame
                terminal.write_frame(frame)
                last_frame = frame
              end

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
        out.puts render(state, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, color: false)
        0
      end

      def quit_key?(key)
        key && QUIT_KEYS.include?(key)
      end
    end
  end
end
