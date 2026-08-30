# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Recount compacts ids, which means it also *reuses* them: a worker that was pruned can have
# its id handed to a completely unrelated live worker by the very next pass. Everything already
# written about the pruned worker - log lines, log routing details, reports, prompts, chat
# history, lineage metadata - must therefore stop spelling that id as a bare id, or it starts
# reading as the live worker's history ("this guy is not the same guy").
#
# The fixture below is the user-reported shape: project `P2` "Meringue" and its workers were
# pruned, project `P4` "World" survived, and the pass renames `P4` -> `P2`, `P4-I3` -> `P2-I2`,
# and the live World worker `P4-I3-W1` -> `P2-I2-W1`, which is exactly the id the removed
# Meringue worker's history still used.
class KernelMaintenanceRecountHistoryTest < Minitest::Test
  include KernelMaintenanceSupport

  # The test's own idea of "a string that reads as a record id", kept independent of the
  # implementation's constants.
  ID_TOKEN = %r{(?<![\w/-])(P\d+(?:-I\d+(?:-W\d+)?)?|Q\d+|G\d+)(?![\w/-])}
  RETIRED_MARKER = " (old id)"

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  # Pruned before this pass: project P2 ("Meringue"), its issues P2-I2/P2-I3, its workers
  # P2-I2-W1/P2-I2-W2, question Q1, goal G1, and worker P4-I1-W1. Their ids are all about to be
  # handed to surviving records.
  def scrambled_history_state
    state = state_fixture(
      projects: [project_record(id: "P1", name: "Notes", status: "working"),
                 project_record(id: "P4", name: "World", status: "working")],
      issues: [
        issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: ["P1-I1-W1"]),
        issue_record(id: "P4-I1", project_id: "P4", status: "completed", agent_ids: ["P4-I1-W2"]),
        issue_record(
          id: "P4-I3",
          project_id: "P4",
          title: "Fix slow delivery_contexts query",
          status: "working",
          agent_ids: %w[P4-I3-W1 P4-I3-W2],
          extra: {
            "description" => "Recovery note: P2-I2-W1 never started, and P2-I2 was pruned. Continues P4-I1."
          }
        )
      ],
      agents: [
        worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "working"),
        worker_record(
          id: "P4-I1-W2",
          issue_id: "P4-I1",
          project_id: "P4",
          status: "completed",
          extra: { "replaces_agent_id" => "P4-I1-W1" },
          harness_metadata: { "replace_agent_id" => "P4-I1-W1" }
        ),
        worker_record(
          id: "P4-I3-W1",
          issue_id: "P4-I3",
          project_id: "P4",
          status: "working",
          pid: "4242",
          session_id: "pi-session-world",
          session_file: "/tmp/pi/world.jsonl",
          workspace_path: "/tmp/workspaces/P2-I2-W1-leftover",
          extra: { "workspace_branch" => "meringue/P2-I2-W1-leftover-a1b2c3d4" },
          harness_metadata: {
            # Lineage pointing at a worker that no longer exists. Left alone, the compacted id
            # would make this worker its own predecessor.
            "follow_up_of_agent_id" => "P2-I2-W1",
            "rerouted_from_issue_id" => "P2-I3",
            "session_recovery" => { "restarted_from_agent_id" => "P4-I1-W2" },
            "spawn_prompt" => "Continue what P2-I2-W1 shipped on P2-I2 and finish P4-I3.",
            "last_assistant_text" => "Picked up the handoff from P2-I2-W1.",
            "command" => ["pi", "--mode", "rpc", "--append-system-prompt", "Work only on P4-I3."]
          }
        ),
        worker_record(
          id: "P4-I3-W2",
          issue_id: "P4-I3",
          project_id: "P4",
          status: "queued",
          extra: { "after_agent_id" => "P4-I3-W1" },
          harness_metadata: {
            "deferred_spawn" => {
              "state" => "waiting",
              "after_agent_id" => "P4-I3-W1",
              "queued_prompt" => "Implement what P4-I3-W1 found for P4-I3."
            }
          }
        )
      ],
      questions: [
        question_record(id: "Q3", project_id: "P4", issue_id: "P4-I3", status: "open").merge(
          "context" => "Q1 asked the same thing about P2-I2 before it was pruned; this one is about P4-I3."
        )
      ],
      logs: history_logs,
      counters: {
        "projects" => 4,
        "heads" => 31,
        "questions" => 3,
        "goals" => 2,
        "logs" => 411,
        "issues_by_project" => { "P1" => 1, "P4" => 3 },
        "workers_by_issue" => { "P1-I1" => 1, "P4-I1" => 2, "P4-I3" => 2 }
      },
      conversation: {
        "messages" => [
          { "id" => 4, "role" => "you", "text" => "kill P2-I2-W1 please", "timestamp" => BASE_TIME },
          { "id" => 5, "role" => "meringue", "source_id" => "P4-I3-W1",
            "text" => "Delivery PR for P4-I3-W1 is unavailable.", "timestamp" => BASE_TIME }
        ],
        "next_message_id" => 6
      },
      metadata: {
        "created_at" => BASE_TIME,
        "updated_at" => BASE_TIME,
        # A previous pass's mapping is history about a rename: both spellings stay verbatim.
        "last_recount" => { "recounted_at" => BASE_TIME, "changed_id_count" => 1,
                            "mappings" => { "project_ids" => { "P3" => "P2" } } }
      }
    )
    state["goals"] = [
      {
        "id" => "G2",
        "issue_id" => "P4-I3",
        "project_id" => "P4",
        "status" => "working",
        "success_criteria" => "The query in P4-I3 runs under 50ms; G1 tracked this before P2-I2 was pruned.",
        "active_worker_id" => "P4-I3-W1",
        "iterations" => [
          { "number" => 1, "phase" => "settled", "attempt_worker_id" => "P2-I2-W1",
            "directive" => "Reuse the index P2-I2-W1 added." }
        ],
        "created_at" => BASE_TIME,
        "updated_at" => BASE_TIME
      }
    ]
    state["ui"] = {
      "agent_workspace" => {
        "selected_agent_id" => "P4-I3-W1",
        "view" => "agent",
        "filter" => "all",
        "draft" => "ask P4-I3-W1 for the plan"
      }
    }
    state
  end

  # Append-only history written before the pass, mirroring the reported log pane.
  def history_logs
    [
      log_record(
        id: "L400",
        source_type: "worker",
        source_id: "P2-I2-W1",
        message: "Worker P2-I2-W1 completed.",
        details: {
          "agent_id" => "P2-I2-W1",
          "issue_id" => "P2-I2",
          "project_id" => "P2",
          "last_assistant_text" => "Assessed the two open review comments on P2-I2. PR https://github.com/jackson-lafrance/meringue/pull/160",
          "delivery_pull_requests" => [{ "url" => "https://github.com/jackson-lafrance/meringue/pull/160" }]
        }
      ),
      log_record(id: "L401", source_id: "P2-I2",
                 message: "Continued worker P2-I2-W1 on P2-I2 using its existing session."),
      log_record(id: "L402", message: "It was queued behind P2-I2-W2, which that worker replaced."),
      log_record(
        id: "L403",
        message: "Removed managed worktree for worker P2-I2-W1.",
        details: { "removed_worktree_agent_ids" => ["P2-I2-W1"], "removed_issue_ids" => %w[P2-I2 P2-I3],
                   "removed_project_ids" => ["P2"] }
      ),
      log_record(id: "L404", message: "Pruned 2 issues, 1 project, and 0 standalone agents."),
      log_record(id: "L405", message: "Pruned issue P2-I3."),
      log_record(id: "L406", message: "Answered question Q1 about P2-I3.", details: { "question_id" => "Q1" }),
      log_record(
        id: "L407",
        message: "Recounted AgentTree IDs; renamed 1 record.",
        details: { "changed_id_count" => 1, "mappings" => { "project_ids" => { "P3" => "P2" } } }
      ),
      log_record(id: "L408", source_type: "worker", source_id: "P4-I1-W2",
                 message: "Worker P4-I1-W2 completed.", details: { "agent_id" => "P4-I1-W2" }),
      log_record(id: "L409", source_type: "worker", source_id: "P4-I3-W1",
                 message: "Spawned worker P4-I3-W1 for P4-I3.", details: { "agent_id" => "P4-I3-W1", "issue_id" => "P4-I3" }),
      log_record(id: "L410", source_type: "user",
                 message: "Received user message.", details: { "input" => "/prompt P2-I2-W1 \"keep going\"" }),
      log_record(id: "L411", source_id: "P4-I3",
                 message: "Queued worker P4-I3-W2 on P4-I3 to start after P4-I3-W1 settles.")
    ]
  end

  # --- the reported failure -------------------------------------------------------------

  def test_no_pre_recount_history_can_be_read_as_another_records_history
    write_state(scrambled_history_state)
    engine = build_engine

    assert_equal "accepted", apply_command(engine, "Recount", {}).fetch("status")

    state = read_state
    # Every id still spelled as a bare id names a record that exists right now.
    assert_no_masquerading_ids(state)
  end

  def test_removed_workers_completion_report_is_not_attached_to_the_worker_that_inherited_its_id
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    # The live World worker really does hold the removed Meringue worker's old id now.
    assert agent_by_id(state, "P2-I2-W1"), "expected the World worker to be renumbered to P2-I2-W1"
    assert_equal "Fix slow delivery_contexts query", issue_by_id(state, "P2-I2").fetch("title")

    report = log_by_id(state, "L400")
    assert_equal "P2-I2-W1 (old id)", report.fetch("source_id")
    assert_equal "Worker P2-I2-W1 (old id) completed.", report.fetch("message")
    assert_equal "P2-I2-W1 (old id)", report.dig("details", "agent_id")
    assert_equal "P2-I2 (old id)", report.dig("details", "issue_id")
    assert_equal "P2 (old id)", report.dig("details", "project_id")
    assert_includes report.dig("details", "last_assistant_text"), "P2-I2 (old id)"
    assert_includes report.dig("details", "last_assistant_text"), "pull/160"

    # Nothing about the removed worker is attributed to the live one.
    attributed = state.fetch("logs").select { |log| log.fetch("source_id", nil) == "P2-I2-W1" }
    assert_equal %w[L409], attributed.map { |log| log.fetch("id") }
    assert_equal "Spawned worker P2-I2-W1 for P2-I2.", log_by_id(state, "L409").fetch("message")
  end

  # The TUI renders a worker's final report only while the log message and the log's source_id
  # agree, so rewriting one without the other silently detaches (or misattributes) the report.
  def test_worker_completion_lines_keep_agreeing_with_their_source_id
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    completions = read_state.fetch("logs").select { |log| log.fetch("source_type", nil) == "worker" }
                            .select { |log| log.fetch("message").match?(/\AWorker .+ completed\.\z/) }
    refute_empty completions
    completions.each do |log|
      assert_equal "Worker #{log.fetch("source_id")} completed.", log.fetch("message"),
                   "log #{log.fetch("id")} no longer identifies the worker it reports on"
    end
  end

  def test_history_about_renamed_records_follows_the_rename_everywhere
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    assert_equal "Worker P2-I1-W1 completed.", log_by_id(state, "L408").fetch("message")
    assert_equal "P2-I1-W1", log_by_id(state, "L408").fetch("source_id")
    assert_equal "P2-I1-W1", log_by_id(state, "L408").dig("details", "agent_id")
    assert_equal "Queued worker P2-I2-W2 on P2-I2 to start after P2-I2-W1 settles.",
                 log_by_id(state, "L411").fetch("message")
    assert_equal "Delivery PR for P2-I2-W1 is unavailable.",
                 state.dig("conversation", "messages").last.fetch("text")
    assert_equal "P2-I2-W1", state.dig("conversation", "messages").last.fetch("source_id")
  end

  def test_history_about_removed_records_is_marked_instead_of_being_reused
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    assert_equal "Continued worker P2-I2-W1 (old id) on P2-I2 (old id) using its existing session.",
                 log_by_id(state, "L401").fetch("message")
    assert_equal "P2-I2 (old id)", log_by_id(state, "L401").fetch("source_id")
    assert_equal "It was queued behind P2-I2-W2 (old id), which that worker replaced.",
                 log_by_id(state, "L402").fetch("message")
    assert_equal ["P2-I2-W1 (old id)"], log_by_id(state, "L403").dig("details", "removed_worktree_agent_ids")
    assert_equal ["P2-I2 (old id)", "P2-I3 (old id)"], log_by_id(state, "L403").dig("details", "removed_issue_ids")
    assert_equal "Answered question Q1 (old id) about P2-I3 (old id).", log_by_id(state, "L406").fetch("message")
    assert_equal "Q1 (old id)", log_by_id(state, "L406").dig("details", "question_id")
    assert_equal "/prompt P2-I2-W1 (old id) \"keep going\"", log_by_id(state, "L410").dig("details", "input")
    assert_equal "kill P2-I2-W1 (old id) please", state.dig("conversation", "messages").first.fetch("text")
    # A line that names no id at all is untouched.
    assert_equal "Pruned 2 issues, 1 project, and 0 standalone agents.", log_by_id(state, "L404").fetch("message")
  end

  # The counters are rebuilt to the compacted range, so the next created record takes the next
  # free number - which is exactly the id some pruned record's history used to spell.
  def test_a_record_created_after_the_pass_does_not_inherit_a_removed_records_history
    write_state(scrambled_history_state)
    engine = build_engine
    apply_command(engine, "Recount", {})

    created = apply_command(engine, "CreateIssue",
                            "project_id" => "P2", "title" => "New goal", "description" => "after recount")

    assert_equal "P2-I3", created.fetch("target_id")
    state = read_state
    assert_equal "Pruned issue P2-I3 (old id).", log_by_id(state, "L405").fetch("message")
    assert_no_masquerading_ids(state)
  end

  # --- live records ---------------------------------------------------------------------

  def test_lineage_pointing_at_a_removed_worker_is_cleared_rather_than_repointed
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    world_worker = agent_by_id(state, "P2-I2-W1")
    metadata = world_worker.fetch("harness_metadata")
    assert_nil metadata.fetch("follow_up_of_agent_id"),
               "a lineage link to a removed worker must not resolve to the worker that inherited its id"
    assert_nil metadata.fetch("rerouted_from_issue_id")
    assert_nil agent_by_id(state, "P2-I1-W1").fetch("replaces_agent_id")
    assert_nil agent_by_id(state, "P2-I1-W1").fetch("harness_metadata").fetch("replace_agent_id")
    # Surviving lineage still follows the rename.
    assert_equal "P2-I1-W1", metadata.dig("session_recovery", "restarted_from_agent_id")
  end

  def test_queued_dependency_and_its_prompt_follow_the_rename
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    dependent = agent_by_id(read_state, "P2-I2-W2")
    assert_equal "P2-I2-W1", dependent.fetch("after_agent_id")
    assert_equal "P2-I2-W1", dependent.dig("harness_metadata", "deferred_spawn", "after_agent_id")
    assert_equal "Implement what P2-I2-W1 found for P2-I2.",
                 dependent.dig("harness_metadata", "deferred_spawn", "queued_prompt")
  end

  def test_prompts_descriptions_questions_and_goals_are_resolved
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    assert_equal "Recovery note: P2-I2-W1 (old id) never started, and P2-I2 (old id) was pruned. Continues P2-I1.",
                 issue_by_id(state, "P2-I2").fetch("description")
    metadata = agent_by_id(state, "P2-I2-W1").fetch("harness_metadata")
    assert_equal "Continue what P2-I2-W1 (old id) shipped on P2-I2 (old id) and finish P2-I2.",
                 metadata.fetch("spawn_prompt")
    assert_equal "Picked up the handoff from P2-I2-W1 (old id).", metadata.fetch("last_assistant_text")
    assert_equal "Q1 (old id) asked the same thing about P2-I2 (old id) before it was pruned; this one is about P2-I2.",
                 question_by_id(state, "Q1").fetch("context")

    goal = state.fetch("goals").first
    assert_equal "G1", goal.fetch("id")
    assert_equal "The query in P2-I2 runs under 50ms; G1 (old id) tracked this before P2-I2 (old id) was pruned.",
                 goal.fetch("success_criteria")
    assert_equal "P2-I2-W1", goal.fetch("active_worker_id")
    iteration = goal.fetch("iterations").first
    assert_nil iteration.fetch("attempt_worker_id"),
               "an attempt worker that was removed must not resolve to the worker that inherited its id"
    assert_equal "Reuse the index P2-I2-W1 (old id) added.", iteration.fetch("directive")
  end

  # Meringue writes ids in canonical upper case, so lower-case ids inside a quoted user request
  # are the user's words rather than references the kernel put there.
  def test_lowercase_ids_quoted_from_a_user_request_are_left_as_written
    state = scrambled_history_state
    quote = 'User request (verbatim): "kill p2-i2-w1 and retry p4-i3".'
    state.fetch("issues").last["description"] = quote
    write_state(state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    assert_equal quote, issue_by_id(read_state, "P2-I2").fetch("description")
  end

  def test_presentation_selection_follows_a_renamed_worker
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    workspace = read_state.dig("ui", "agent_workspace")
    assert_equal "P2-I2-W1", workspace.fetch("selected_agent_id")
    assert_equal "ask P2-I2-W1 for the plan", workspace.fetch("draft")
  end

  def test_presentation_selection_of_a_removed_worker_is_cleared
    state = Meringue::State::Models.ensure_state_shape!(scrambled_history_state)
    state["ui"]["agent_workspace"]["selected_agent_id"] = "P2-I2-W1"

    Meringue::State::Recounter.recount!(state)

    assert_nil state.dig("ui", "agent_workspace", "selected_agent_id")
  end

  # --- invariants that must survive the fix ---------------------------------------------

  def test_opaque_runtime_identity_and_verbatim_evidence_are_untouched
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    worker = agent_by_id(state, "P2-I2-W1")
    assert_equal "/tmp/workspaces/P2-I2-W1-leftover", worker.fetch("workspace_path")
    assert_equal "meringue/P2-I2-W1-leftover-a1b2c3d4", worker.fetch("workspace_branch")
    assert_equal "pi-session-world", worker.fetch("harness_session_id")
    assert_equal "/tmp/pi/world.jsonl", worker.fetch("harness_session_file")
    assert_equal "4242", worker.fetch("pid")
    assert_equal ["pi", "--mode", "rpc", "--append-system-prompt", "Work only on P4-I3."],
                 worker.dig("harness_metadata", "command")
    assert_equal "https://github.com/jackson-lafrance/meringue/pull/160",
                 log_by_id(state, "L400").dig("details", "delivery_pull_requests", 0, "url")
    # A previous pass's mapping records a rename that happened; both spellings stay as written.
    assert_equal({ "project_ids" => { "P3" => "P2" } }, log_by_id(state, "L407").dig("details", "mappings"))
  end

  def test_append_only_log_and_message_ids_are_not_renumbered
    write_state(scrambled_history_state)
    engine = build_engine

    apply_command(engine, "Recount", {})

    state = read_state
    assert_equal %w[L400 L401 L402 L403 L404 L405 L406 L407 L408 L409 L410 L411],
                 state.fetch("logs").map { |log| log.fetch("id") }.first(12)
    assert_equal "L412", state.fetch("logs").last.fetch("id")
    assert_equal [4, 5], state.dig("conversation", "messages").map { |message| message.fetch("id") }
    assert_equal 6, state.dig("conversation", "next_message_id")
    assert_equal 31, state.dig("counters", "heads")
  end

  def test_a_second_pass_neither_re_marks_nor_re_maps_history
    write_state(scrambled_history_state)
    engine = build_engine
    apply_command(engine, "Recount", {})
    first = read_state

    second_result = apply_command(engine, "Recount", {})

    assert_equal 0, second_result.dig("result", "changed_id_count")
    second = read_state
    %w[L400 L401 L402 L403 L405 L406 L410 L411].each do |log_id|
      assert_equal log_by_id(first, log_id).fetch("message"), log_by_id(second, log_id).fetch("message"),
                   "log #{log_id} changed again on an idempotent pass"
      assert_equal log_by_id(first, log_id).fetch("details"), log_by_id(second, log_id).fetch("details")
    end
    refute_includes log_by_id(second, "L401").fetch("message"), "#{RETIRED_MARKER}#{RETIRED_MARKER}"
    assert_no_masquerading_ids(second)
  end

  def test_recount_still_refuses_to_run_while_another_head_is_in_flight
    state = scrambled_history_state
    state["agents"] << head_record(id: "H32", status: "working")
    write_state(state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "rejected", result.fetch("status")
    persisted = read_state
    assert_equal "Worker P2-I2-W1 completed.", log_by_id(persisted, "L400").fetch("message")
    assert_equal %w[P1 P4], ids(persisted.fetch("projects"))
  end

  private

  def log_by_id(state, id)
    Array(state.fetch("logs")).find { |log| log.fetch("id", nil) == id }
  end

  def live_ids(state)
    (ids(state.fetch("projects")) + ids(state.fetch("issues")) + ids(state.fetch("agents")) +
      ids(state.fetch("questions")) + ids(state.fetch("goals", []))).to_set
  end

  # Everything a user reads, or that the kernel and heads hand to another agent later. Opaque
  # evidence (paths, branches, argv, urls, recount mappings) is deliberately excluded: it is
  # never read as a record reference.
  def history_strings(state)
    strings = []
    state.fetch("logs").each do |log|
      strings << ["log #{log.fetch("id")} source_id", log.fetch("source_id", nil)]
      strings << ["log #{log.fetch("id")} message", log.fetch("message", nil)]
      details = log.fetch("details", {}) || {}
      details.each do |key, value|
        next if key == "mappings"

        collect_strings(value, "log #{log.fetch("id")} details.#{key}", strings)
      end
    end
    Array(state.dig("conversation", "messages")).each do |message|
      strings << ["message #{message.fetch("id")}", message.fetch("text", nil)]
      strings << ["message #{message.fetch("id")} source_id", message.fetch("source_id", nil)]
    end
    state.fetch("issues").each do |issue|
      strings << ["issue #{issue.fetch("id")} title", issue.fetch("title", nil)]
      strings << ["issue #{issue.fetch("id")} description", issue.fetch("description", nil)]
      strings << ["issue #{issue.fetch("id")} parent", issue.fetch("parent_issue_id", nil)]
      collect_strings(issue.fetch("agent_ids", []), "issue #{issue.fetch("id")} agent_ids", strings)
    end
    state.fetch("agents").each do |agent|
      %w[project_id issue_id after_agent_id follow_up_of_agent_id replaces_agent_id replaced_by_agent_id].each do |key|
        strings << ["agent #{agent.fetch("id")} #{key}", agent.fetch(key, nil)]
      end
      metadata = agent.fetch("harness_metadata", {}) || {}
      metadata.each do |key, value|
        next if key == "command"

        collect_strings(value, "agent #{agent.fetch("id")} harness_metadata.#{key}", strings)
      end
    end
    state.fetch("questions").each do |question|
      %w[question context answer project_id issue_id].each do |key|
        strings << ["question #{question.fetch("id")} #{key}", question.fetch(key, nil)]
      end
    end
    Array(state.fetch("goals", [])).each do |goal|
      goal.each do |key, value|
        next if key == "metric"

        collect_strings(value, "goal #{goal.fetch("id")} #{key}", strings)
      end
    end
    workspace = state.dig("ui", "agent_workspace") || {}
    strings << ["ui selected_agent_id", workspace.fetch("selected_agent_id", nil)]
    strings << ["ui draft", workspace.fetch("draft", nil)]
    strings.select { |_path, value| value.is_a?(String) }
  end

  def collect_strings(value, path, strings)
    case value
    when String then strings << [path, value]
    when Array then value.each_with_index { |child, index| collect_strings(child, "#{path}[#{index}]", strings) }
    when Hash then value.each { |key, child| collect_strings(child, "#{path}.#{key}", strings) }
    end
    strings
  end

  def unmarked_id_tokens(text)
    tokens = []
    text.scan(ID_TOKEN) do
      match = Regexp.last_match
      next if match.post_match.start_with?(RETIRED_MARKER)

      tokens << match[0]
    end
    tokens
  end

  def assert_no_masquerading_ids(state)
    live = live_ids(state)
    history_strings(state).each do |path, text|
      unmarked_id_tokens(text).each do |token|
        assert_includes live, token,
                        "#{path} still spells #{token}, which no longer names the record it was written about: #{text.inspect}"
      end
    end
  end
end
