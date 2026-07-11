# frozen_string_literal: true

module Meringue
  module TUI
    class App
      def initialize(layout: Layout.new, out: $stdout)
        @layout = layout
        @out = out
      end

      def render(state)
        layout.render(state)
      end

      def run(state: State::Models.empty_state)
        out.puts render(state)
        0
      end

      private

      attr_reader :layout, :out
    end
  end
end
