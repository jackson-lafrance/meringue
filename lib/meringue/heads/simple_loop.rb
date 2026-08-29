# frozen_string_literal: true

require "json"
require "tmpdir"

module Meringue
  module Heads
    class SimpleLoop
      EXIT_COMMANDS = %w[/q /quit /exit].freeze

      def initialize(input: $stdin, out: $stdout, err: $stderr,
                     router: Input::Router.new,
                     runner: FakeRunner.new,
                     runner_name: "fake",
                     initial_state: State::Models.empty_state,
                     cwd: Dir.pwd,
                     store: nil,
                     harness_client: Harness::FakeClient.new,
                     workspace_manager: Workspace::Manager.new,
                     engine: nil,
                     wait_for_workers: false,
                     worker_wait_timeout: 120)
        @input = input
        @out = out
        @err = err
        @runner_name = runner_name
        @cwd = File.expand_path(cwd)
        @store = store || build_temp_store
        seed_store!(initial_state)
        @engine = engine || Kernel::Engine.new(
          store: @store,
          harness_client: harness_client,
          head_runner: runner,
          workspace_manager: workspace_manager,
          cwd: @cwd
        )
        @prompt_loop = PromptLoop.new(
          engine: @engine,
          router: router,
          wait_for_workers: wait_for_workers,
          worker_wait_timeout: worker_wait_timeout
        )
      end

      def run
        out.puts "Meringue #{runner_name} head loop"
        out.puts "Natural-language prompts run through SpawnHead -> ApplyHeadResult -> proposed kernel commands."
        out.puts "Type a prompt to spawn a #{runner_name} head. Type /quit to exit."
        out.puts "State path: #{state_path_description}"

        loop do
          out.print "> " if interactive_input?
          line = input.gets
          break unless line

          text = line.chomp
          next if text.strip.empty?
          break if exit_command?(text)

          out.puts JSON.pretty_generate(handle_input(text))
        rescue StandardError => e
          err.puts JSON.pretty_generate(prompt_loop.error_payload(e))
        end

        0
      end

      def handle_input(text)
        prompt_loop.call(text)
      end

      private

      # PromptLoop owns prompt routing, command handling, summaries, and worker orchestration;
      # this class only frames console input and output around it.
      attr_reader :input, :out, :err, :runner_name, :store, :prompt_loop

      def seed_store!(initial_state)
        return if store.respond_to?(:path) && File.exist?(store.path)

        state = JSON.parse(JSON.generate(initial_state || State::Models.empty_state))
        store.save(state)
      end

      def build_temp_store
        @temporary_state_root = Dir.mktmpdir("meringue-head-loop-")
        State::Store.new(path: File.join(@temporary_state_root, "state.json"))
      end

      def state_path_description
        return store.path if store.respond_to?(:path)

        "in-memory"
      end

      def exit_command?(text)
        EXIT_COMMANDS.include?(text.strip.downcase)
      end

      def interactive_input?
        input.respond_to?(:tty?) && input.tty?
      end

    end
  end
end
