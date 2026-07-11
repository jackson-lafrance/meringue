# frozen_string_literal: true

require "json"

module Meringue
  module Heads
    class SimpleLoop
      EXIT_COMMANDS = %w[/q /quit /exit].freeze

      def initialize(input: $stdin, out: $stdout, err: $stderr,
                     router: Input::Router.new,
                     runner: FakeRunner.new,
                     initial_state: State::Models.empty_state,
                     cwd: Dir.pwd)
        @input = input
        @out = out
        @err = err
        @router = router
        @runner = runner
        @state = initial_state
        @cwd = File.expand_path(cwd)
        @head_counter = initial_state.fetch("counters", {}).fetch("heads", 0).to_i
      end

      def run
        out.puts "Meringue fake head loop"
        out.puts "Type a prompt to spawn a fake head. Type /quit to exit."

        loop do
          out.print "> " if interactive_input?
          line = input.gets
          break unless line

          text = line.chomp
          next if text.strip.empty?
          break if exit_command?(text)

          out.puts JSON.pretty_generate(handle_input(text))
        rescue StandardError => e
          err.puts JSON.pretty_generate(error_payload(e))
        end

        0
      end

      def handle_input(text)
        route = router.route(text)

        if route.fetch("kind") == "natural_language"
          spawn_command = route.fetch("commands").first
          payload = spawn_command.fetch("payload")
          return spawn_fake_head(
            user_message: payload.fetch("user_message"),
            question_id: payload.fetch("question_id", nil),
            route: route
          )
        end

        {
          "event" => "slash_command_routed",
          "summary" => "Slash commands bypass the fake head runner in this manual loop.",
          "state_mutated" => false,
          "route" => route
        }
      end

      private

      attr_reader :input, :out, :err, :router, :runner, :state, :cwd

      def spawn_fake_head(user_message:, question_id:, route:)
        head_id = next_head_id
        context = Context.new(
          head_id: head_id,
          user_message: user_message,
          snapshot: state,
          question_id: question_id,
          cwd: cwd
        )
        system_prompt = context.system_prompt
        head_result = runner.run(
          user_message: user_message,
          snapshot: state,
          question_id: question_id,
          context: context
        )

        {
          "event" => "fake_head_completed",
          "head_id" => head_id,
          "state_mutated" => false,
          "spawn" => {
            "context_built" => true,
            "system_prompt_bytes" => system_prompt.bytesize,
            "kernel_command_reference_appended" => true,
            "kernel_command_reference" => context.reference_metadata
          },
          "route" => route,
          "head_result" => head_result
        }
      end

      def next_head_id
        @head_counter += 1
        "H#{@head_counter}"
      end

      def exit_command?(text)
        EXIT_COMMANDS.include?(text.strip.downcase)
      end

      def interactive_input?
        input.respond_to?(:tty?) && input.tty?
      end

      def error_payload(error)
        {
          "event" => "error",
          "state_mutated" => false,
          "error" => {
            "class" => error.class.name,
            "message" => error.message
          }
        }
      end
    end
  end
end
