# frozen_string_literal: true

require "json"

module Meringue
  class App
    DEMO_STATE_PATH = Meringue.root_path("fixtures", "demo_state.json")

    def initialize(input: $stdin, out: $stdout, err: $stderr,
                   state_path: State::Store::DEFAULT_PATH,
                   state_store: nil,
                   tui_app: nil)
      @input = input
      @out = out
      @err = err
      @state_path = state_path
      @state_store = state_store || State::Store.new(path: state_path)
      @tui_app = tui_app
    end

    def run
      tui.run(state_provider: -> { current_state })
    rescue JSON::ParserError => e
      err.puts "Could not load Meringue state from #{state_path}: #{e.message}"
      1
    end

    private

    attr_reader :input, :out, :err, :state_path, :state_store, :tui_app

    def current_state
      state_store.load
    end

    def tui
      tui_app || TUI::App.new(input: input, out: out)
    end
  end
end
