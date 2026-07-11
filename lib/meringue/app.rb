# frozen_string_literal: true

require "json"

module Meringue
  class App
    DEMO_STATE_PATH = Meringue.root_path("fixtures", "demo_state.json")

    def initialize(input: $stdin, out: $stdout, err: $stderr, state_path: DEMO_STATE_PATH, tui_app: nil)
      @input = input
      @out = out
      @err = err
      @state_path = state_path
      @tui_app = tui_app
    end

    def run
      tui.run(state: demo_state)
    rescue Errno::ENOENT, JSON::ParserError => e
      err.puts "Could not load demo state from #{state_path}: #{e.message}"
      1
    end

    private

    attr_reader :input, :out, :err, :state_path, :tui_app

    def demo_state
      JSON.parse(File.read(state_path))
    end

    def tui
      tui_app || TUI::App.new(input: input, out: out)
    end
  end
end
