# frozen_string_literal: true

module Meringue
  module Heads
    class PromptLoop
      attr_reader :engine, :worker_wait_timeout

      def initialize(engine:, wait_for_workers: false, worker_wait_timeout: 120,
                     engine_mutex: Mutex.new, router: Input::Router.new)
        @engine = engine
        @wait_for_workers = wait_for_workers
        @worker_wait_timeout = worker_wait_timeout
        @engine_mutex = engine_mutex
        @router = router
      end

      def call(text, &on_event)
        route = router.route(text)
        return handle_slash_command(route, on_event: on_event) if route.fetch("kind", nil) == "slash_command"

        handle_prompt(text, route: route, on_event: on_event)
      end

      def handle_prompt(text, route: nil, on_event: nil)
        route ||= natural_language_route(text)
        spawn_command = route.fetch("commands").first
        spawn_result = apply_kernel(spawn_command)
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

        emit(on_event, "head_completed", "head_id" => spawn_result.fetch("target_id"), "head_result" => head_result)

        apply_result = apply_kernel(
          "type" => "ApplyHeadResult",
          "payload" => {
            "head_id" => spawn_result.fetch("target_id"),
            "head_result" => head_result
          }
        )
        payload["apply_head_result"] = apply_result
        emit(on_event, "head_result_applied", "head_id" => spawn_result.fetch("target_id"), "apply_result" => apply_result)
        payload["worker_wait_results"] = wait_for_spawned_workers(apply_result, on_event: on_event)
        payload["state_mutated"] = apply_result.fetch("status", nil) == "accepted"
        payload["state_summary"] = state_summary
        payload
      end

      private

      attr_reader :router

      def handle_slash_command(route, on_event: nil)
        command_results = route.fetch("commands", []).map { |command| apply_kernel(command) }
        payload = {
          "event" => "slash_command_applied",
          "summary" => slash_summary(command_results),
          "state_mutated" => command_results.any? { |result| result.fetch("status", nil) == "accepted" },
          "route" => route,
          "command_results" => command_results,
          "state_summary" => state_summary
        }
        emit(on_event, "slash_command_applied", "command_results" => command_results)
        payload
      end

      def slash_summary(command_results)
        accepted = command_results.select { |result| result.fetch("status", nil) == "accepted" }
        return accepted.map { |result| result.fetch("message", "Command accepted.") }.join("\n") unless accepted.empty?

        command_results.map { |result| result.fetch("message", "Command was not accepted.") }.join("\n")
      end

      def natural_language_route(text)
        {
          "kind" => "natural_language",
          "commands" => [
            Meringue::Kernel::Command.new(
              type: "SpawnHead",
              payload: { "user_message" => text.to_s }
            ).to_h
          ]
        }
      end

      def apply_kernel(command)
        @engine_mutex.synchronize { engine.apply(command) }
      end

      def mark_worker_completed(agent_id:, harness_events:, last_assistant_text:)
        @engine_mutex.synchronize do
          engine.mark_worker_completed(
            agent_id: agent_id,
            harness_events: harness_events,
            last_assistant_text: last_assistant_text
          )
        end
      end

      def emit(callback, event, payload = {})
        callback&.call(payload.merge("event" => event))
      end

      def wait_for_spawned_workers(apply_result, on_event: nil)
        return [] unless wait_for_workers?
        return [] unless engine.harness_client.respond_to?(:wait_for_settled)

        worker_results_from(apply_result).map do |worker_result|
          wait_for_worker(worker_result.fetch("result"), on_event: on_event)
        end
      end

      def wait_for_worker(agent, on_event: nil)
        session_ref = session_ref_from_agent(agent)
        emit(on_event, "worker_wait_started", "agent_id" => agent.fetch("id"))
        events = engine.harness_client.wait_for_settled(session_ref, timeout: worker_wait_timeout)
        assistant_text = safe_last_assistant_text(session_ref)
        completion_result = mark_worker_completed(
          agent_id: agent.fetch("id"),
          harness_events: events,
          last_assistant_text: assistant_text
        )
        emit(on_event, "worker_completed", "agent_id" => agent.fetch("id"), "last_assistant_text" => assistant_text)
        {
          "agent_id" => agent.fetch("id"),
          "status" => "settled",
          "event_count" => events.length,
          "last_assistant_text" => assistant_text,
          "completion_result" => completion_result
        }
      rescue StandardError => e
        error = {
          "agent_id" => agent.fetch("id", nil),
          "status" => "error",
          "error" => error_details(e)
        }
        emit(on_event, "worker_wait_failed", error)
        error
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
        state = engine.store.load
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
