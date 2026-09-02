# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class SelfFixingWorkersTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("meringue-self-fixing")
    @config_path = File.join(@dir, "config.toml")
    File.write(@config_path, <<~TOML)
      [settings]
      schema_version = 1
      [experiments]
      self_fixing_workers = true
    TOML
    @state_path = File.join(@dir, "state.json")
    @store = Meringue::State::Store.new(path: @state_path)
    @store.save(initial_state)
    @engine = Meringue::Kernel::Engine.new(
      store: @store,
      config: Meringue::Config.load(path: @config_path),
      config_path: @config_path
    )
    @spawned = []
    spawned = @spawned
    @engine.define_singleton_method(:spawn_worker) do |command_id, command_type, payload|
      spawned << [command_id, command_type, payload]
      {
        "status" => "accepted",
        "command_id" => command_id,
        "command_type" => command_type,
        "target_id" => "P1-I1-W2",
        "result" => { "id" => "P1-I1-W2" },
        "log_entry_ids" => []
      }
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.exist?(@dir)
  end

  def test_claims_one_recovery_and_persists_a_non_recursive_marker
    results = @engine.send(:reconcile_self_fixing_workers)

    assert_equal 1, results.length
    assert_equal 1, @spawned.length
    command_id, = @spawned.first
    assert_equal "self-fix:P1-I1-W1:1", command_id
    payload = @spawned.first.fetch(2)
    assert_equal "P1-I1-W1", payload.fetch("follow_up_of_agent_id")
    assert_equal "P1-I1-W1", payload.fetch("_self_fixing_recovery").fetch("source_worker_id")

    source = @store.load.fetch("agents").find { |agent| agent.fetch("id") == "P1-I1-W1" }
    recovery = source.fetch("harness_metadata").fetch("self_fixing_recovery")
    assert_equal "spawned", recovery.fetch("state")
    assert_equal 1, recovery.fetch("attempts")
    assert_equal "P1-I1-W2", recovery.fetch("recovery_worker_id")

    assert_empty @engine.send(:reconcile_self_fixing_workers)
    assert_equal 1, @spawned.length
  end

  def test_recovery_title_includes_source_task_title
    assert_equal "Self-fix: Fix checkout", Meringue::Experiments::SelfFixingWorkers.title("title" => "Fix checkout")
  end

  def test_default_classification_starts_only_the_original_task_lane
    worker = initial_state.fetch("agents").first
    assert_equal "original_task", Meringue::Experiments::SelfFixingWorkers.classification(worker).fetch("kind")
    refute Meringue::Experiments::SelfFixingWorkers.repair_lane?(worker)
  end

  def test_explicit_platform_defect_starts_a_separate_repair_lane
    state = initial_state
    worker = state.fetch("agents").first
    worker.fetch("harness_metadata")["failure_classification"] = {
      "kind" => "platform_or_configuration", "reason" => "missing tool", "repair_issue_id" => "P1-I2"
    }
    state.fetch("issues") << {
      "id" => "P1-I2", "project_id" => "P1", "title" => "Repair setup", "status" => "open",
      "agent_ids" => [], "created_at" => "2026-08-16T00:00:00Z", "updated_at" => "2026-08-16T00:00:00Z"
    }
    @store.save(state)

    results = @engine.send(:reconcile_self_fixing_workers)

    assert_equal %w[continuation repair], results.map { |result| result.fetch("self_fixing_lane") }
    assert_equal "P1-I1-W1", @spawned.fetch(0).fetch(2).fetch("follow_up_of_agent_id")
    assert_includes @spawned.fetch(0).fetch(2).fetch("prompt"), "--- Original assignment ---"
    assert_equal "P1-I2", @spawned.fetch(1).fetch(2).fetch("issue_id")
    assert_equal false, @spawned.fetch(1).fetch(2).fetch("share_workspace")
    recovery = @store.load.fetch("agents").first.fetch("harness_metadata").fetch("self_fixing_recovery")
    assert_equal "spawned", recovery.fetch("lanes").fetch("repair").fetch("state")
  end

  def test_recovery_workers_are_not_eligible_for_another_recovery
    worker = initial_state.fetch("agents").first.merge(
      "status" => "errored",
      "harness_metadata" => {
        "self_fixing_recovery" => { "source_worker_id" => "P1-I1-W0", "attempt" => 1 }
      }
    )

    refute Meringue::Experiments::SelfFixingWorkers.eligible?(worker)
    refute Meringue::Experiments::SelfFixingWorkers.claimable?(worker)
  end

  def test_pending_human_input_does_not_trigger_recovery
    state = initial_state
    worker = state.fetch("agents").first
    worker["status"] = "blocked"
    worker["harness_metadata"] = {
      "human_input_request" => { "state" => "pending", "source" => "approval_request" }
    }
    @store.save(state)

    refute Meringue::Experiments::SelfFixingWorkers.claimable?(worker)
    assert_empty @engine.send(:reconcile_self_fixing_workers)
    assert_empty @spawned
  end

  def test_focus_preparation_failure_alone_does_not_trigger_recovery
    state = initial_state
    worker = state.fetch("agents").first
    worker["status"] = "blocked"
    worker["harness_metadata"] = worker.fetch("harness_metadata").merge(
      "last_interactive_handoff" => {
        "state" => "failed",
        "outcome" => "prepare_failed",
        "error" => "No live agent process was available"
      }
    )
    state.fetch("issues").first["status"] = "blocked"
    @store.save(state)

    refute Meringue::Experiments::SelfFixingWorkers.claimable?(worker)
    assert_empty @engine.send(:reconcile_self_fixing_workers)
    assert_empty @spawned
  end

  private

  def initial_state
    now = "2026-08-16T00:00:00Z"
    state = Meringue::State::Models.empty_state(now: now)
    state["projects"] << {
      "id" => "P1", "name" => "App", "root_path" => @dir, "status" => "errored",
      "issue_ids" => ["P1-I1"], "created_at" => now, "updated_at" => now
    }
    state["issues"] << {
      "id" => "P1-I1", "project_id" => "P1", "title" => "Fix it", "status" => "errored",
      "agent_ids" => ["P1-I1-W1"], "created_at" => now, "updated_at" => now
    }
    state["agents"] << {
      "id" => "P1-I1-W1", "type" => "worker", "status" => "errored",
      "project_id" => "P1", "issue_id" => "P1-I1", "harness" => "fake",
      "harness_metadata" => { "title" => "Original" }, "created_at" => now, "updated_at" => now
    }
    state
  end
end
