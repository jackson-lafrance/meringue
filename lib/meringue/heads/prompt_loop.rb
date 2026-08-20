# frozen_string_literal: true

module Meringue
  module Heads
    class PromptLoop
      attr_reader :engine, :worker_wait_timeout, :submission_queue

      def initialize(engine:, wait_for_workers: false, worker_wait_timeout: 120,
                     engine_mutex: Mutex.new, router: Input::Router.new, submission_queue: nil)
        @engine = engine
        @wait_for_workers = wait_for_workers
        @worker_wait_timeout = worker_wait_timeout
        @engine_mutex = engine_mutex
        @router = router
        @submission_queue = submission_queue || Input::DurableSubmissionQueue.new(state_path: engine.store.path)
      end

      # Called synchronously by the TUI before it clears the composer. The append is a tiny fsynced
      # sidecar write and never waits for the orchestration-state lock held by prune/reconciliation.
      def enqueue_submission(text, selected_target: nil)
        submission_queue.enqueue(text: text, selected_target: selected_target)
      end

      def deliver_submission(submission, &on_event)
        record = submission.is_a?(Hash) ? submission : submission_queue.pending.find { |entry| entry.fetch("id") == submission.to_s }
        return nil unless record

        result = route_submission(
          record.fetch("text"),
          selected_target: record.fetch("selected_target", nil),
          submission_id: record.fetch("id"),
          &on_event
        )
        submission_queue.complete(record.fetch("id"))
        result
      end

      def recover_pending_submissions(&on_event)
        submission_queue.pending.map do |submission|
          Thread.new { deliver_submission(submission, &on_event) }
        end
      end

      def call(text, selected_target: nil, &on_event)
        deliver_submission(enqueue_submission(text, selected_target: selected_target), &on_event)
      end

      def route_submission(text, selected_target: nil, submission_id: nil, &on_event)
        route = if selected_target
                  router.route(text, selected_target: selected_target)
                else
                  router.route(text)
                end
        route = correlate_submission(route, submission_id)
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
          payload["summary"] = ""
          payload["state_mutated"] = true
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
        # Head-proposed user commands need the same local side effects as the typed slash path
        # (clearing the visible chat for ClearState, switching the theme for SetTheme).
        emit(
          on_event,
          "head_result_applied",
          "head_id" => spawn_result.fetch("target_id"),
          "head_result" => head_result,
          "apply_result" => apply_result,
          "command_results" => command_results_from(apply_result)
        )
        payload["worker_wait_results"] = wait_for_spawned_workers(apply_result, on_event: on_event)
        payload["state_mutated"] = apply_result.fetch("status", nil) == "accepted"
        payload["state_summary"] = state_summary
        payload
      end

      private

      attr_reader :router

      def correlate_submission(route, submission_id)
        return route unless submission_id

        correlated = route.merge("submission_id" => submission_id.to_s)
        correlated["commands"] = Array(route.fetch("commands", [])).each_with_index.map do |command, index|
          command = command.to_h if command.respond_to?(:to_h)
          payload = (command.fetch("payload", {}) || {}).dup
          payload["_input_submission_id"] = submission_id.to_s
          command.merge(
            "command_id" => command.fetch("command_id", nil),
            "payload" => payload
          )
        end
        correlated
      end

      def handle_slash_command(route, on_event: nil)
        record_user_kernel_command(route)
        command_results = route.fetch("commands", []).map { |command| apply_kernel(command) }
        record_user_kernel_command_output(route, command_results)
        head_apply_result = apply_synchronous_head_result(command_results, on_event: on_event)
        worker_wait_results = wait_for_spawned_command_workers(
          command_results + [head_apply_result].compact,
          on_event: on_event
        )
        payload = {
          "event" => "slash_command_applied",
          "summary" => slash_summary(command_results),
          "state_mutated" => command_results.any? { |result| result.fetch("status", nil) == "accepted" } ||
            head_apply_result&.fetch("status", nil) == "accepted" ||
            worker_wait_results.any? { |result| result.fetch("status", nil) == "settled" },
          "route" => route,
          "command_results" => command_results,
          "worker_wait_results" => worker_wait_results,
          "state_summary" => state_summary
        }
        payload["apply_head_result"] = head_apply_result if head_apply_result
        emit(on_event, "slash_command_applied", "command_results" => command_results, "worker_wait_results" => worker_wait_results)
        payload
      end

      # `/retry H13` starts a fresh retry head, and a synchronous head runner hands back its
      # HeadResult inside that command result. Applying it here is what makes the typed retry
      # converge with the natural-language head loop; when heads run asynchronously there is no
      # result yet and the kernel's own polling applies it, so this does nothing.
      def apply_synchronous_head_result(command_results, on_event: nil)
        pending = Array(command_results).find do |result|
          result.is_a?(Hash) && result.fetch("status", nil) == "accepted" && unapplied_head_result?(result)
        end
        return nil unless pending

        head_id = pending.fetch("target_id")
        head_result = head_result_from(pending)
        emit(on_event, "head_completed", "head_id" => head_id, "head_result" => head_result)
        apply_result = apply_kernel(
          "type" => "ApplyHeadResult",
          "payload" => { "head_id" => head_id, "head_result" => head_result }
        )
        emit(
          on_event,
          "head_result_applied",
          "head_id" => head_id,
          "head_result" => head_result,
          "apply_result" => apply_result,
          "command_results" => command_results_from(apply_result)
        )
        apply_result
      end

      def unapplied_head_result?(command_result)
        record = command_result.fetch("result", nil)
        return false unless record.is_a?(Hash) && record.fetch("type", nil) == "head"

        metadata = record.fetch("harness_metadata", {}) || {}
        metadata.fetch("head_result", nil).is_a?(Hash) && metadata.fetch("head_result_applied_at", nil).nil?
      end

      def record_user_kernel_command(route)
        return unless engine.respond_to?(:record_user_kernel_command)

        @engine_mutex.synchronize do
          engine.record_user_kernel_command(
            input: route.fetch("input", ""),
            commands: route.fetch("commands", [])
          )
        end
      end

      def record_user_kernel_command_output(route, command_results)
        return unless engine.respond_to?(:record_user_kernel_command_output)

        @engine_mutex.synchronize do
          engine.record_user_kernel_command_output(
            input: route.fetch("input", ""),
            command_results: command_results
          )
        end
      end

      def slash_summary(command_results)
        accepted = command_results.select { |result| result.fetch("status", nil) == "accepted" }
        return accepted.map { |result| result.fetch("message", "Command accepted.") }.join("\n") unless accepted.empty?

        command_results.map { |result| result.fetch("message", "Command was not accepted.") }.join("\n")
      end

      def natural_language_route(text, selected_target: nil)
        payload = { "user_message" => text.to_s }
        payload["selected_target"] = selected_target if selected_target
        {
          "kind" => "natural_language",
          "commands" => [
            Meringue::Kernel::Command.new(
              type: "SpawnHead",
              payload: payload
            ).to_h
          ]
        }
      end

      def apply_kernel(command)
        # SpawnHead has always been independently synchronized by the engine. Prune and Kill now
        # do the same and deliberately perform unbounded work (forge I/O, harness process exit)
        # outside the state lock; do not hold the prompt-loop mutex across that work or every later
        # submission would queue behind `/prune` or a storm of `/kill` commands.
        return engine.apply(command) if independently_synchronized_command?(command)

        @engine_mutex.synchronize { engine.apply(command) }
      end

      def independently_synchronized_command?(command)
        type = command.respond_to?(:[]) && (command["type"] || command[:type] || command["command_type"] || command[:command_type])
        # Kill manages its own state lock and defers unbounded harness process termination until
        # after the lock is released, so the prompt-loop mutex must not be held across a kill or
        # rapid `/kill` commands would queue behind each other instead of running concurrently.
        %w[SpawnHead spawn_head Prune prune Kill kill].include?(type.to_s)
      end

      def mark_worker_completed(agent_id:, harness_events:, last_assistant_text:, session_ref: nil)
        @engine_mutex.synchronize do
          engine.mark_worker_completed(
            agent_id: agent_id,
            harness_events: harness_events,
            last_assistant_text: last_assistant_text,
            session_ref: session_ref
          )
        end
      end

      def emit(callback, event, payload = {})
        callback&.call(payload.merge("event" => event))
      end

      def wait_for_spawned_workers(apply_result, on_event: nil)
        wait_for_worker_results(worker_results_from(apply_result), on_event: on_event)
      end

      def wait_for_spawned_command_workers(command_results, on_event: nil)
        wait_for_worker_results(worker_results_from_command_results(command_results), on_event: on_event)
      end

      def wait_for_worker_results(worker_results, on_event: nil)
        return [] unless wait_for_workers?
        return [] unless engine.harness_client.respond_to?(:wait_for_settled)

        worker_results.map do |worker_result|
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
          last_assistant_text: assistant_text,
          session_ref: session_ref
        )
        completed_agent_id = completion_result.fetch("target_id", nil) || agent.fetch("id")
        pr_urls = worker_pr_urls_from_completion(completion_result)
        emit(
          on_event,
          "worker_completed",
          "agent_id" => completed_agent_id,
          "last_assistant_text" => assistant_text,
          "pr_urls" => pr_urls
        )
        {
          "agent_id" => completed_agent_id,
          "status" => "settled",
          "event_count" => events.length,
          "last_assistant_text" => assistant_text,
          "pr_urls" => pr_urls,
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
        worker_results_from_command_results(command_results_from(apply_result))
      end

      def command_results_from(apply_result)
        result = apply_result.fetch("result", {}) || {}
        Array(result.fetch("command_results", []))
      end

      def worker_results_from_command_results(command_results)
        Array(command_results).flat_map do |command_result|
          next [] unless command_result.is_a?(Hash)
          next [command_result] if spawned_worker_result?(command_result)

          worker_results_from_command_results(nested_command_results(command_result))
        end
      end

      def spawned_worker_result?(command_result)
        command_result.fetch("command_type", nil) == "SpawnWorker" &&
          command_result.fetch("status", nil) == "accepted" &&
          command_result.fetch("result", nil).is_a?(Hash)
      end

      # An accepted AnswerQuestion spawns a head, and that head's applied commands can include
      # SpawnWorker. Those nested results are the work the answer started, so they must be visible
      # to worker waiting just like a directly proposed SpawnWorker.
      def nested_command_results(command_result)
        result = command_result.fetch("result", nil)
        return [] unless result.is_a?(Hash)

        [
          *Array(result.fetch("command_results", [])),
          *Array(result.dig("routing", "command_results"))
        ]
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

      def worker_pr_urls_from_completion(completion_result)
        result = completion_result.fetch("result", {}) || {}
        metadata = result.fetch("harness_metadata", {}) || {}
        issue = result.fetch("issue", {}) || {}
        delivery_pull_requests = [
          issue["delivery_pull_request"],
          *Array(issue["delivery_pull_requests"]),
          metadata["delivery_pull_request"],
          *Array(metadata["delivery_pull_requests"])
        ].compact
        delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }.uniq
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
        agents = state.fetch("agents", [])
        {
          "project_count" => state.fetch("projects", []).length,
          "issue_count" => state.fetch("issues", []).length,
          "agent_count" => agents.length,
          "active_head_count" => agents.count { |agent| agent.fetch("type", nil) == "head" && agent.fetch("status", nil) == "working" },
          "working_worker_count" => agents.count { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("status", nil) == "working" },
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
