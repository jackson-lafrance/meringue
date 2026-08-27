# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Recount compacts user-facing AgentTree numbering after removals and repairs the
# drifted counters, without touching opaque runtime identity or append-only ids.
class KernelMaintenanceRecountTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  # Gapped tree left behind by pruning: P1/P3 are gone, so are some issues,
  # workers, and questions, and the counters drifted well past reality.
  def gapped_state
    state_fixture(
      projects: [project_record(id: "P2", status: "working"), project_record(id: "P4", status: "working")],
      issues: [
        issue_record(id: "P2-I2", project_id: "P2", status: "working", agent_ids: %w[P2-I2-W2 P2-I2-W3]),
        issue_record(id: "P2-I3", project_id: "P2", status: "completed", parent_issue_id: "P2-I2"),
        issue_record(id: "P4-I5", project_id: "P4", status: "working", agent_ids: ["P4-I5-W1"])
      ],
      agents: [
        worker_record(
          id: "P2-I2-W2",
          issue_id: "P2-I2",
          project_id: "P2",
          status: "working",
          harness: "pi",
          pid: "4242",
          session_id: "pi-session-abc",
          session_file: "/tmp/pi/abc.jsonl",
          workspace_path: "/tmp/workspaces/fix-signup-a1b2c3d4",
          extra: {
            "workspace_branch" => "meringue/fix-signup-a1b2c3d4",
            "replaces_agent_id" => "P2-I2-W1",
            "follow_up_agent_ids" => %w[P2-I2-W3]
          }
        ),
        worker_record(
          id: "P2-I2-W3",
          issue_id: "P2-I2",
          project_id: "P2",
          status: "completed",
          extra: { "follow_up_of_agent_id" => "P2-I2-W2" }
        ),
        worker_record(id: "P4-I5-W1", issue_id: "P4-I5", project_id: "P4", status: "completed")
      ],
      questions: [
        question_record(id: "Q2", project_id: "P2", issue_id: "P2-I2", status: "answered"),
        question_record(id: "Q5", project_id: "P4", issue_id: "P4-I5", status: "open")
      ],
      logs: [
        log_record(
          id: "L7",
          source_id: "P2-I2",
          message: "Historical log text about P2-I2",
          details: { "issue_id" => "P2-I3", "agent_id" => "P2-I2-W3", "pid" => "4242" }
        )
      ],
      counters: {
        "projects" => 9,
        "heads" => 3,
        "questions" => 12,
        "logs" => 7,
        "issues_by_project" => { "P2" => 9, "P4" => 5 },
        "workers_by_issue" => { "P2-I2" => 7 }
      },
      conversation: { "messages" => [{ "id" => 4, "role" => "user", "text" => "keep me" }], "next_message_id" => 5 }
    )
  end

  def test_recount_compacts_projects_issues_workers_and_questions
    write_state(gapped_state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "accepted", result.fetch("status")
    mappings = result.dig("result", "mappings")
    assert_equal({ "P2" => "P1", "P4" => "P2" }, mappings.fetch("project_ids"))
    assert_equal({ "P2-I2" => "P1-I1", "P2-I3" => "P1-I2", "P4-I5" => "P2-I1" }, mappings.fetch("issue_ids"))
    assert_equal({ "P2-I2-W2" => "P1-I1-W1", "P2-I2-W3" => "P1-I1-W2", "P4-I5-W1" => "P2-I1-W1" },
                 mappings.fetch("worker_ids"))
    assert_equal({ "Q2" => "Q1", "Q5" => "Q2" }, mappings.fetch("question_ids"))
    assert_equal mappings.values.sum(&:length), result.dig("result", "changed_id_count")

    state = read_state
    assert_equal %w[P1 P2], ids(state.fetch("projects"))
    assert_equal %w[P1-I1 P1-I2 P2-I1], ids(state.fetch("issues")).sort
    assert_equal %w[P1-I1-W1 P1-I1-W2 P2-I1-W1], ids(state.fetch("agents")).sort
    assert_equal %w[Q1 Q2], ids(state.fetch("questions"))
    assert_documented_status_vocabulary(state)
  end

  def test_recount_rewrites_relationships_and_prunes_dangling_worker_links
    write_state(gapped_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    child = issue_by_id(state, "P1-I2")
    assert_equal "P1-I1", child.fetch("parent_issue_id")
    assert_equal "P1", child.fetch("project_id")
    assert_equal %w[P1-I1-W1 P1-I1-W2], issue_by_id(state, "P1-I1").fetch("agent_ids")

    renamed = agent_by_id(state, "P1-I1-W1")
    assert_equal "P1-I1", renamed.fetch("issue_id")
    assert_equal "P1", renamed.fetch("project_id")
    assert_equal ["P1-I1-W2"], renamed.fetch("follow_up_agent_ids")
    assert_nil renamed.fetch("replaces_agent_id"), "a link to an already removed worker must be cleared"
    assert_equal "P1-I1-W1", agent_by_id(state, "P1-I1-W2").fetch("follow_up_of_agent_id")

    question = question_by_id(state, "Q1")
    assert_equal "P1", question.fetch("project_id")
    assert_equal "P1-I1", question.fetch("issue_id")
  end

  def test_recount_leaves_opaque_runtime_identity_untouched
    write_state(gapped_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    worker = agent_by_id(read_state, "P1-I1-W1")
    assert_equal "4242", worker.fetch("pid")
    assert_equal "pi-session-abc", worker.fetch("harness_session_id")
    assert_equal "/tmp/pi/abc.jsonl", worker.fetch("harness_session_file")
    assert_equal "/tmp/workspaces/fix-signup-a1b2c3d4", worker.fetch("workspace_path")
    assert_equal "meringue/fix-signup-a1b2c3d4", worker.fetch("workspace_branch")
  end

  def test_recount_repairs_drifted_counters_without_breaking_monotonic_ids
    write_state(gapped_state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    counters = result.dig("result", "counters")
    assert_equal 2, counters.fetch("projects")
    assert_equal 2, counters.fetch("questions")
    assert_equal({ "P1" => 2, "P2" => 1 }, counters.fetch("issues_by_project"))
    assert_equal({ "P1-I1" => 2, "P1-I2" => 0, "P2-I1" => 1 }, counters.fetch("workers_by_issue"))
    # Head ids are transient correlation ids and log ids are append-only, so their
    # counters must not be rewound by a recount.
    assert_equal 3, counters.fetch("heads")
    assert_operator counters.fetch("logs"), :>=, 7

    state = read_state
    assert_equal "L7", state.fetch("logs").first.fetch("id")
    assert_equal "L8", state.fetch("logs").last.fetch("id")
    assert_equal [4], state.dig("conversation", "messages").map { |message| message.fetch("id") }
    assert_equal 5, state.dig("conversation", "next_message_id")
  end

  def test_recount_updates_log_references_and_the_ids_embedded_in_log_text
    write_state(gapped_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    log = read_state.fetch("logs").find { |entry| entry.fetch("id") == "L7" }
    assert_equal "P1-I1", log.fetch("source_id")
    assert_equal "P1-I2", log.dig("details", "issue_id")
    assert_equal "P1-I1-W2", log.dig("details", "agent_id")
    assert_equal "4242", log.dig("details", "pid"), "opaque pid keys stay untouched"
    # The line still describes the same record, so it has to spell that record's current id:
    # `P2-I2` now belongs to a different issue. See recount_history_test.rb.
    assert_equal "Historical log text about P1-I1", log.fetch("message")
  end

  def test_recount_records_its_mapping_in_metadata_and_logs_one_entry
    write_state(gapped_state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    state = read_state
    last_recount = state.dig("metadata", "last_recount")
    assert last_recount.fetch("recounted_at")
    assert_equal result.dig("result", "changed_id_count"), last_recount.fetch("changed_id_count")
    assert_equal result.dig("result", "mappings"), last_recount.fetch("mappings")

    recount_logs = state.fetch("logs").select { |log| log.fetch("message").start_with?("Recounted AgentTree IDs") }
    assert_equal 1, recount_logs.length
    assert_equal result.fetch("message"), recount_logs.first.fetch("message")
    assert_includes recount_logs.first.dig("details", "unchanged_id_types"), "head"
  end

  def test_next_created_records_continue_after_the_compacted_range
    write_state(gapped_state)
    engine = build_engine
    apply_command(engine, "Recount", {})

    created_issue = apply_command(engine, "CreateIssue", "project_id" => "P1", "title" => "New goal",
                                                         "description" => "after recount")
    added_project = apply_command(engine, "AddProject", "path" => make_dir("another-project"))

    assert_equal "P1-I3", created_issue.fetch("target_id")
    assert_equal "P3", added_project.fetch("target_id")
  end

  def test_recount_is_refused_while_a_head_record_is_in_flight
    state = gapped_state
    state["agents"] << head_record(id: "H4", status: "working")
    write_state(state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "rejected", result.fetch("status")
    assert_equal "AgentTree IDs were not recounted because a head result is still in flight.", result.fetch("message")
    assert_includes result.fetch("errors"), "H4"
    assert_equal %w[P2 P4], ids(read_state.fetch("projects"))
  end

  def test_recount_of_empty_state_is_accepted_and_changes_nothing
    write_state(state_fixture)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "accepted", result.fetch("status")
    assert_equal 0, result.dig("result", "changed_id_count")
    assert_equal "Recounted AgentTree IDs; renamed 0 records.", result.fetch("message")
  end

  def test_malformed_ids_abort_the_recount_and_leave_state_on_disk_untouched
    state = state_fixture(
      projects: [project_record(id: "P1", status: "working")],
      issues: [issue_record(id: "not-an-issue-id", project_id: "P1", status: "working")]
    )
    write_state(state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "failed", result.fetch("status")
    assert_match(/Cannot recount malformed AgentTree ID/, result.fetch("message"))
    assert_equal ["not-an-issue-id"], ids(read_state.fetch("issues"))
  end

  # An issue whose project is gone used to abort inside the id mapping with a bare
  # `KeyError: key not found: "P1-I1"`. It now names the record and what to do about it.
  def test_orphaned_issue_is_refused_by_name_before_the_id_mapping_runs
    state = Meringue::State::Models.ensure_state_shape!(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P9", status: "working")]
      )
    )

    error = assert_raises(Meringue::State::Recounter::UnrecountableStateError) do
      Meringue::State::Recounter.recount!(state)
    end

    assert_includes error.message, "P1-I1"
    assert_includes error.message, "P9"
    assert_includes error.message, "/recount"
  end

  def test_orphaned_worker_is_refused_by_name_too
    state = Meringue::State::Models.ensure_state_shape!(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working")],
        agents: [worker_record(id: "P1-I2-W1", issue_id: "P1-I2", project_id: "P1", status: "working")]
      )
    )

    error = assert_raises(Meringue::State::Recounter::UnrecountableStateError) do
      Meringue::State::Recounter.recount!(state)
    end

    assert_includes error.message, "P1-I2-W1"
  end

  def test_orphaned_issue_recount_is_rejected_without_writing_state
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P9", status: "working")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "recount_refused"
    assert_includes result.fetch("message"), "P1-I1"
    state = read_state
    assert_equal ["P1-I1"], ids(state.fetch("issues"))
    assert_equal "P9", issue_by_id(state, "P1-I1").fetch("project_id")
  end
end
