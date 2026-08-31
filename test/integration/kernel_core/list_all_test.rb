# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

class KernelCoreListAllTest < Minitest::Test
  include KernelCoreSupport

  SNAPSHOT_KEYS = %w[
    agents conversation counters goals issues logs metadata projects questions schema_version ui
  ].freeze

  def test_list_all_returns_the_agent_tree_snapshot_shape
    result = apply_command("ListAll")

    assert_accepted(result)
    assert_equal "Loaded Meringue state.", result.fetch("message")
    assert_nil result.fetch("target_id")
    assert_empty result.fetch("log_entry_ids")

    snapshot = result.fetch("result")
    assert_equal SNAPSHOT_KEYS, snapshot.keys.sort
    assert_equal Meringue::State::Models::SCHEMA_VERSION, snapshot.fetch("schema_version")
    %w[projects issues agents questions logs].each do |key|
      assert_kind_of Array, snapshot.fetch(key), "#{key} should be an array"
    end
    %w[projects heads questions goals logs issues_by_project workers_by_issue].each do |key|
      assert snapshot.fetch("counters").key?(key), "counters should include #{key}"
    end
    assert_iso8601(snapshot.fetch("metadata").fetch("created_at"), "metadata created_at")
    assert_iso8601(snapshot.fetch("metadata").fetch("updated_at"), "metadata updated_at")
  end

  def test_list_all_nests_projects_issues_workers_and_heads
    build_tree

    snapshot = apply_command("ListAll").fetch("result")

    assert_equal %w[P1 P2], snapshot.fetch("projects").map { |project| project.fetch("id") }
    assert_equal %w[P1-I1 P1-I2 P2-I1], snapshot.fetch("issues").map { |issue| issue.fetch("id") }

    issues_by_id = snapshot.fetch("issues").to_h { |issue| [issue.fetch("id"), issue] }
    assert_nil issues_by_id.fetch("P1-I1").fetch("parent_issue_id")
    assert_equal "P1-I1", issues_by_id.fetch("P1-I2").fetch("parent_issue_id")
    assert_equal "P2", issues_by_id.fetch("P2-I1").fetch("project_id")

    workers = snapshot.fetch("agents").select { |agent| agent.fetch("type") == "worker" }
    heads = snapshot.fetch("agents").select { |agent| agent.fetch("type") == "head" }
    assert_equal %w[P1-I2-W1], workers.map { |worker| worker.fetch("id") }
    assert_equal %w[H1], heads.map { |head| head.fetch("id") }

    worker = workers.first
    assert_equal "P1-I2", worker.fetch("issue_id")
    assert_equal "P1", worker.fetch("project_id")
    assert_equal "working", worker.fetch("status")
    assert_equal ["P1-I2-W1"], issues_by_id.fetch("P1-I2").fetch("agent_ids")
    assert_equal [], issues_by_id.fetch("P1-I1").fetch("agent_ids")

    head = heads.first
    assert_nil head.fetch("issue_id")
    assert_nil head.fetch("project_id")
    assert_equal "completed", head.fetch("status")
  end

  def test_list_all_includes_pending_questions_with_their_scope
    build_tree

    questions = apply_command("ListAll").fetch("result").fetch("questions")

    assert_equal 1, questions.length
    question = questions.first
    assert_equal "Q1", question.fetch("id")
    assert_equal "open", question.fetch("status")
    assert_equal "H1", question.fetch("head_id")
    assert_equal "P1", question.fetch("project_id")
    assert_equal "P1-I2", question.fetch("issue_id")
    assert_nil question.fetch("answer")
    assert_includes Meringue::State::Models::QUESTION_STATUSES, question.fetch("status")
  end

  def test_list_all_reports_derived_status_counts
    build_tree

    snapshot = apply_command("ListAll").fetch("result")

    project_statuses = snapshot.fetch("projects").to_h { |project| [project.fetch("id"), project.fetch("status")] }
    issue_statuses = snapshot.fetch("issues").to_h { |issue| [issue.fetch("id"), issue.fetch("status")] }

    assert_equal({ "P1" => "working", "P2" => "working" }, project_statuses)
    assert_equal({ "P1-I1" => "queued", "P1-I2" => "working", "P2-I1" => "queued" }, issue_statuses)

    counts = issue_statuses.values.tally
    assert_equal({ "queued" => 2, "working" => 1 }, counts)
    snapshot.fetch("issues").each do |issue|
      assert_includes Meringue::State::Models::LIFECYCLE_STATUSES, issue.fetch("status")
    end
    snapshot.fetch("agents").each do |agent|
      assert_includes Meringue::State::Models::LIFECYCLE_STATUSES, agent.fetch("status")
    end

    assert_equal 2, snapshot.fetch("counters").fetch("projects")
    assert_equal 1, snapshot.fetch("counters").fetch("heads")
    assert_equal 1, snapshot.fetch("counters").fetch("questions")
    assert_equal({ "P1" => 2, "P2" => 1 }, snapshot.fetch("counters").fetch("issues_by_project"))
    assert_equal({ "P1-I2" => 1 }, snapshot.fetch("counters").fetch("workers_by_issue"))
  end

  def test_list_all_matches_the_persisted_snapshot_and_the_public_reader
    build_tree

    snapshot = apply_command("ListAll").fetch("result")

    assert_equal snapshot, engine.list_all
    assert_equal snapshot.fetch("projects"), persisted_projects
    assert_equal snapshot.fetch("issues"), persisted_issues
    assert_equal snapshot.fetch("agents"), persisted_agents
    assert_equal snapshot.fetch("questions"), persisted_questions
  end

  def test_list_all_does_not_mutate_persisted_state
    build_tree
    before = File.read(state_path)

    assert_accepted(apply_command("ListAll"))
    assert_accepted(apply_command("list_all"))

    assert_equal before, File.read(state_path)
  end

  def test_list_all_alias_is_canonicalized
    result = apply_command("list_all")

    assert_accepted(result)
    assert_equal "ListAll", result.fetch("command_type")
  end

  def test_list_all_snapshot_logs_stay_within_supported_levels
    build_tree

    snapshot = apply_command("ListAll").fetch("result")

    refute_empty snapshot.fetch("logs")
    snapshot.fetch("logs").each do |entry|
      assert_equal %w[details id level message source_id source_type timestamp], entry.keys.sort
      assert_includes Meringue::State::Models::LOG_LEVELS, entry.fetch("level")
      assert_includes Meringue::State::Models::LOG_SOURCE_TYPES, entry.fetch("source_type")
      assert_iso8601(entry.fetch("timestamp"), "log timestamp")
    end
    assert_log_levels_valid
  end

  private

  # P1 -> P1-I1 -> P1-I2 (worker W1), plus P2 -> P2-I1, one completed head, one open question.
  def build_tree
    project_path = add_project!(name: "app").fetch("result").fetch("root_path")
    add_project!(name: "api")
    create_issue!("P1", title: "Parent issue")
    create_issue!("P1", title: "Child issue", "parent_issue_id" => "P1-I1")
    create_issue!("P2", title: "Other project issue")
    spawn_worker!("P1-I2")
    spawn_head!(user_message: "Check the flaky signup spec")
    ask_question!("H1", question: "Should this target staging?", "project_id" => "P1", "issue_id" => "P1-I2")
  end
end
