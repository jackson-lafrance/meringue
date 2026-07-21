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
      @reconcile_mutex = Mutex.new
      @reconcile_condition = ConditionVariable.new
      @reconcile_thread = nil
      @stop_reconciliation = false
    end

    def run
      state_store.compact! if state_store.respond_to?(:compact!)
      start_reconciliation
      ui = tui
      loaded_state = state_store.load
      ui.restore_logs!(loaded_state) if ui.respond_to?(:restore_logs!)
      ui.remember_existing_log_events!(loaded_state) if ui.respond_to?(:remember_existing_log_events!)
      ui.run(state_provider: -> { current_state }, on_submit: prompt_handler)
    rescue JSON::ParserError => e
      err.puts "Could not load Meringue state from #{state_path}: #{e.message}"
      1
    ensure
      stop_reconciliation
    end

    private

    attr_reader :input, :out, :err, :state_path, :state_store, :tui_app, :prompt_handler, :reconciler

    def current_state
      state_store.load
    end

    def start_reconciliation
      return unless reconciler
      return if @reconcile_thread&.alive?

      @reconcile_mutex.synchronize { @stop_reconciliation = false }
      @reconcile_thread = Thread.new do
        Thread.current.name = "meringue-reconciler" if Thread.current.respond_to?(:name=)
        loop do
          break if reconciliation_stopping?

          begin
            reconciler.call
          rescue StandardError => e
            @last_reconcile_error = e
          end

          @reconcile_mutex.synchronize do
            break if @stop_reconciliation

            @reconcile_condition.wait(@reconcile_mutex, RECONCILE_INTERVAL)
          end
        end
      end
    end

    def stop_reconciliation
      thread = @reconcile_thread
      return unless thread

      @reconcile_mutex.synchronize do
        @stop_reconciliation = true
        @reconcile_condition.broadcast
      end
      thread.join(RECONCILE_INTERVAL + 0.5)
      thread.kill if thread.alive?
      @reconcile_thread = nil
    end

    def reconciliation_stopping?
      @reconcile_mutex.synchronize { @stop_reconciliation }
    end

    def tui
      tui_app || TUI::App.new(input: input, out: out, log_store: state_store)
    end
  end
end
