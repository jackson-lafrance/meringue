# frozen_string_literal: true

module Meringue
  class App
    def initialize(out: $stdout)
      @out = out
    end

    def run
      out.puts "Meringue #{VERSION}"
      out.puts "Ruby CLI app scaffold is ready."
      out.puts "Next slice: render fixtures/demo_state.json in a fake-state TUI demo."
      0
    end

    private

    attr_reader :out
  end
end
