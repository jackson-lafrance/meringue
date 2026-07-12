# frozen_string_literal: true

require "json"

module Meringue
  class App
    DEMO_STATE_PATH = Meringue.root_path("fixtures", "demo_state.json")

    RECONCILE_INTERVAL = 2.0

    def initialize(input: $stdin, out: $stdout, err: $stderr,
                   state_path: State::Store::DEFAULT_PATH,
                   state_store: nil,
                   tui_app: nil,
                   prompt_handler: nil,
                   reconciler: nil)
      @input = input
      @out = out
      @err = err
      @state_path = state_path
      @state_store = state_store || State::Store.new(path: state_path)
      @tui_app = tui_app
      @prompt_handler = prompt_handler
      @reconciler = reconciler
      @last_reconcile_at = nil
      @reconcile_mutex = Mutex.new
    end

    def run
      state_store.compact! if state_store.respond_to?(:compact!)
      reconcile_now
      ui = tui
      loaded_state = state_store.load
      ui.restore_conversation!(loaded_state) if ui.respond_to?(:restore_conversation!)
      ui.remember_existing_conversation_events!(loaded_state) if ui.respond_to?(:remember_existing_conversation_events!)
      ui.run(state_provider: -> { current_state }, on_submit: prompt_handler)
    rescue JSON::ParserError => e
      err.puts "Could not load Meringue state from #{state_path}: #{e.message}"
      1
    end

    private

    attr_reader :input, :out, :err, :state_path, :state_store, :tui_app, :prompt_handler, :reconciler

    def current_state
      reconcile_if_due
      state_store.load
    end

    def reconcile_if_due
      return unless reconciler
      return if @last_reconcile_at && (Time.now - @last_reconcile_at) < RECONCILE_INTERVAL

      reconcile_now
    end

    def reconcile_now
      return unless reconciler

      @reconcile_mutex.synchronize do
        return if @last_reconcile_at && (Time.now - @last_reconcile_at) < RECONCILE_INTERVAL

        @last_reconcile_at = Time.now
        reconciler.call
      end
    rescue StandardError
      nil
    end

    def tui
      tui_app || TUI::App.new(input: input, out: out, conversation_store: state_store)
    end
  end
end
