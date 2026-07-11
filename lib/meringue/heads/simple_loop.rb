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
                     engine: nil)
        @input = input
        @out = out
        @err = err
        @router = router
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
          err.puts JSON.pretty_generate(error_payload(e))
        end

        0
      end

      def handle_input(text)
        route = router.route(text)

        if route.fetch("kind") == "natural_language"
          return handle_natural_language(route)
        end

        command_results = engine.apply_all(route.fetch("commands", []))
        {
          "event" => "slash_command_applied",
          "summary" => "Slash command bypassed the head runner and was sent to kernel validation.",
          "state_mutated" => command_results.any? { |result| result.fetch("status", nil) == "accepted" },
          "route" => route,
          "command_results" => command_results,
          "state_summary" => state_summary
        }
      end

      private

      attr_reader :input, :out, :err, :router, :runner_name, :store, :engine, :cwd

      def handle_natural_language(route)
        spawn_command = route.fetch("commands").first
        spawn_result = engine.apply(spawn_command)
        payload = {
          "event" => "head_loop_iteration",
          "summary" => "Spawned a head, collected its HeadResult, and asked the kernel to apply the proposed commands.",
          "state_mutated" => false,
          "route" => route,
          "spawn_head_result" => spawn_result
        }

        unless spawn_result.fetch("status", nil) == "accepted"
          payload["summary"] = "Head spawn failed or was rejected; proposed commands were not applied."
          payload["state_summary"] = state_summary
          return payload
        end

        head_result = head_result_from(spawn_result)
        unless head_result
          payload["summary"] = "Head completed but did not return a stored HeadResult; proposed commands were not applied."
          payload["state_summary"] = state_summary
          return payload
        end

        apply_result = engine.apply(
          "type" => "ApplyHeadResult",
          "payload" => {
            "head_id" => spawn_result.fetch("target_id"),
            "head_result" => head_result
          }
        )
        payload["apply_head_result"] = apply_result
        payload["state_mutated"] = apply_result.fetch("status", nil) == "accepted"
        payload["state_summary"] = state_summary
        payload
      end

      def head_result_from(spawn_result)
        result = spawn_result.fetch("result", {}) || {}
        metadata = result.fetch("harness_metadata", {}) || {}
        metadata["head_result"]
      end

      def state_summary
        state = store.load
        {
          "project_count" => state.fetch("projects", []).length,
          "issue_count" => state.fetch("issues", []).length,
          "agent_count" => state.fetch("agents", []).length,
          "open_question_count" => state.fetch("questions", []).count { |question| question.fetch("status", nil) == "open" },
          "recent_projects" => state.fetch("projects", []).last(3).map { |project| project.slice("id", "name", "status", "root_path") },
          "recent_issues" => state.fetch("issues", []).last(5).map { |issue| issue.slice("id", "project_id", "title", "status", "agent_ids") },
          "recent_agents" => state.fetch("agents", []).last(5).map { |agent| agent.slice("id", "type", "status", "project_id", "issue_id", "harness") },
          "recent_logs" => state.fetch("logs", []).last(8).map { |log| log.slice("id", "source_type", "source_id", "level", "message") }
        }
      end

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

      def error_payload(error)
        {
          "event" => "error",
          "state_mutated" => false,
          "error" => error_details(error),
          "state_summary" => state_summary
        }
      end

      def error_details(error)
        details = {
          "class" => error.class.name,
          "message" => error.message
        }
        details["validation_errors"] = error.validation_errors if error.respond_to?(:validation_errors)
        details["raw_output"] = error.raw_output if error.respond_to?(:raw_output)
        details
      end
    end
  end
end
