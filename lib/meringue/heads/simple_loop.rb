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
        @router = router
        @runner_name = runner_name
        @cwd = File.expand_path(cwd)
        @store = store || build_temp_store
        @wait_for_workers = wait_for_workers
        @worker_wait_timeout = worker_wait_timeout
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

      attr_reader :input, :out, :err, :router, :runner_name, :store, :engine, :cwd,
                  :worker_wait_timeout, :prompt_loop

      def handle_natural_language(route)
        prompt_loop.handle_prompt(route.fetch("commands").first.dig("payload", "user_message"), route: route)
      end

      def wait_for_spawned_workers(apply_result)
        return [] unless wait_for_workers?
        return [] unless engine.harness_client.respond_to?(:wait_for_settled)

        worker_results_from(apply_result).map do |worker_result|
          wait_for_worker(worker_result.fetch("result"))
        end
      end

      def wait_for_worker(agent)
        session_ref = session_ref_from_agent(agent)
        events = engine.harness_client.wait_for_settled(session_ref, timeout: worker_wait_timeout)
        assistant_text = safe_last_assistant_text(session_ref)
        completion_result = engine.mark_worker_completed(
          agent_id: agent.fetch("id"),
          harness_events: events,
          last_assistant_text: assistant_text
        )
        {
          "agent_id" => agent.fetch("id"),
          "status" => "settled",
          "event_count" => events.length,
          "last_assistant_text" => assistant_text,
          "completion_result" => completion_result
        }
      rescue StandardError => e
        {
          "agent_id" => agent.fetch("id", nil),
          "status" => "error",
          "error" => error_details(e)
        }
      end

      def worker_results_from(apply_result)
        result = apply_result.fetch("result", {}) || {}
        result.fetch("command_results", []).select do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" &&
            command_result.fetch("status", nil) == "accepted" &&
            command_result.fetch("result", nil).is_a?(Hash)
        end
      end

      def session_ref_from_agent(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        {
          "harness" => agent.fetch("harness", nil),
          "pid" => agent.fetch("pid", nil),
          "cwd" => metadata.fetch("cwd", agent.fetch("workspace_path", nil)),
          "session_id" => agent.fetch("harness_session_id", nil),
          "session_file" => agent.fetch("harness_session_file", nil),
          "is_streaming" => metadata.fetch("is_streaming", false),
          "last_event_at" => metadata.fetch("last_event_at", nil),
          "metadata" => metadata
        }
      end

      def safe_last_assistant_text(session_ref)
        return nil unless engine.harness_client.respond_to?(:last_assistant_text)

        engine.harness_client.last_assistant_text(session_ref)
      rescue StandardError
        nil
      end

      def wait_for_workers?
        @wait_for_workers
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
