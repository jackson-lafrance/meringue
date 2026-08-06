# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Worker completion continuations: a worker can ask the kernel to spawn a fresh head after it
# completes, with its final report in the head prompt. The head then routes normal kernel commands.
class KernelWorkersCompletionTriggeredHeadTest < Minitest::Test
  include KernelWorkersSupport

  class RoutingHeadRunner < Meringue::Heads::Runner
    attr_reader :calls

    def initialize(commands: nil)
      @commands = commands
      @calls = []
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      @calls << {
        "user_message" => user_message,
        "snapshot" => snapshot,
        "context" => context,
        "question_id" => question_id
      }
      issue_id = user_message[/issue_id: (P\d+-I\d+)/, 1] || "P1-I1"
      commands = @commands || %w[auth billing].map do |section|
        {
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => issue_id,
            "title" => "Audit #{section}",
            "prompt" => "Investigate the #{section} section from the completed worker report."
          }
        }
      end
      {
        "title" => "Route follow-on work",
        "summary" => "Spawn follow-up workers from the completed worker report.",
        "commands" => commands,
        "questions" => []
      }
    end
  end

  def test_worker_completion_spawns_and_applies_a_head_with_the_worker_result
    head_runner = RoutingHeadRunner.new
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Investigate app sections")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "List app sections that need follow-up.",
      completion_head: {
        prompt: "Create one follow-up worker for each app section named in the report."
      }
    ).fetch("target_id")

    result = engine.mark_worker_completed(
      agent_id: worker_id,
      last_assistant_text: "Sections found: auth, billing."
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal 1, head_runner.calls.length
    head_prompt = head_runner.calls.first.fetch("user_message")
    assert_includes head_prompt, "worker #{worker_id} completed"
    assert_includes head_prompt, "Create one follow-up worker"
    assert_includes head_prompt, "Sections found: auth, billing."

    continuation_results = result.fetch("completion_continuation_results")
    assert_equal 1, continuation_results.length
    assert_equal "accepted", continuation_results.first.fetch("status")
    refute_nil continuation_results.first.dig("result", "head_id")

    follow_up_titles = state(engine).fetch("agents").filter_map do |record|
      next unless record.fetch("type") == "worker"
      next if record.fetch("id") == worker_id

      record.fetch("harness_metadata", {}).fetch("title", nil)
    end
    assert_includes follow_up_titles, "Audit auth"
    assert_includes follow_up_titles, "Audit billing"
    assert_equal "applied", agent(engine, worker_id).fetch("harness_metadata").fetch("completion_continuation").fetch("state")
  end

  def test_reconciliation_triggers_a_waiting_completion_continuation_exactly_once
    head_runner = RoutingHeadRunner.new(commands: [])
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Investigate app sections")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "List app sections that need follow-up.",
      completion_head: "Decide whether the worker report needs follow-up routing."
    ).fetch("target_id")

    patch_agent!(worker_id) do |record|
      record["status"] = "completed"
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "completed_at" => Time.now.utc.iso8601,
        "last_assistant_text" => "Sections found while Meringue was down."
      )
    end

    restarted = build_engine(head_runner: head_runner)
    first = apply!(restarted, "ReconcileSessions")
    second = apply!(restarted, "ReconcileSessions")

    assert_equal 1, head_runner.calls.length
    assert_equal 1, first.dig("result", "completion_continuation_results").length
    assert_empty second.dig("result", "completion_continuation_results")
    continuation = agent(restarted, worker_id).fetch("harness_metadata").fetch("completion_continuation")
    assert_equal "applied", continuation.fetch("state")
    refute_nil continuation.fetch("head_id")
    assert_equal 1, logs_matching(restarted, /Spawned head .* after worker #{Regexp.escape(worker_id)} completed/).length
  end
end
