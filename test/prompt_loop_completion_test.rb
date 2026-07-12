# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../lib/meringue"

class PromptLoopCompletionTest < Minitest::Test
  class SettlingHarness < Meringue::Harness::FakeClient
    attr_reader :waited_session_refs

    def initialize
      super
      @waited_session_refs = []
    end

    def wait_for_settled(session_ref, timeout:)
      waited_session_refs << session_ref
      [{ "type" => "agent_settled" }]
    end

    def last_assistant_text(_session_ref)
      "worker finished"
    end
  end

  class SpawnWorkerRouter
    def initialize(issue_id)
      @issue_id = issue_id
    end

    def route(_text)
      {
        "kind" => "slash_command",
        "commands" => [
          {
            "type" => "SpawnWorker",
            "payload" => {
              "issue_id" => @issue_id,
              "prompt" => "finish the issue",
              "title" => "Complete worker"
            }
          }
        ]
      }
    end
  end

  def test_slash_spawned_worker_completion_updates_agent_issue_project_and_tree
    Dir.mktmpdir("meringue-completion-test-") do |root|
      store = Meringue::State::Store.new(path: File.join(root, "state.json"))
      harness = SettlingHarness.new
      engine = Meringue::Kernel::Engine.new(
        store: store,
        harness_client: harness,
        cwd: root
      )

      add_project = engine.apply(
        "type" => "AddProject",
        "payload" => { "path" => root, "name" => "demo" }
      )
      assert_equal "accepted", add_project.fetch("status")

      create_issue = engine.apply(
        "type" => "CreateIssue",
        "payload" => { "project_id" => "P1", "title" => "Done issue" }
      )
      assert_equal "accepted", create_issue.fetch("status")

      loop = Meringue::Heads::PromptLoop.new(
        engine: engine,
        wait_for_workers: true,
        router: SpawnWorkerRouter.new("P1-I1")
      )

      result = loop.call('/worker spawn P1-I1 "finish the issue"')
      assert_equal "slash_command_applied", result.fetch("event")
      assert_equal ["settled"], result.fetch("worker_wait_results").map { |worker| worker.fetch("status") }
      assert_equal 1, harness.waited_session_refs.length

      state = store.load
      agent = state.fetch("agents").find { |candidate| candidate.fetch("id") == "P1-I1-W1" }
      issue = state.fetch("issues").find { |candidate| candidate.fetch("id") == "P1-I1" }
      project = state.fetch("projects").find { |candidate| candidate.fetch("id") == "P1" }

      assert_equal "completed", agent.fetch("status")
      assert_equal "completed", issue.fetch("status")
      assert_equal "completed", project.fetch("status")
      assert_equal false, agent.fetch("harness_metadata").fetch("is_streaming")
      assert_equal "worker finished", agent.fetch("harness_metadata").fetch("last_assistant_text")

      tree = Meringue::TUI::Panes::AgentTreePane.new.render(state)
      assert_includes tree, "✓ W1  Complete worker"
      refute_includes tree, "● W1  Complete worker"
    end
  end
end
