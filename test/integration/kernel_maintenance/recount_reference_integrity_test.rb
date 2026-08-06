# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Recount renames records in place, so referential integrity is the whole contract: every field
# that stores a renamed id must be rewritten in the same pass, and anything the pass would strand
# must fail loudly instead of being persisted.
#
# The audited reference classes are: queued/deferred worker chains (flat `after_agent_id` plus the
# nested `harness_metadata.deferred_spawn` copy), worker lineage, issue parentage/agent lists,
# question ownership, goal worker/question links and iteration history, log `source_id` and the
# structured log routing hash, persisted chat-message routing, and free-form harness metadata.
class KernelMaintenanceRecountReferenceIntegrityTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  # One tree that carries every reference class at once. Numbering is gapped (P1/P3 and the lower
  # issue/worker numbers are gone) so every id really moves:
  #   P2 -> P1, P4 -> P2, P2-I2 -> P1-I1, P4-I5 -> P2-I1,
  #   P2-I2-W2 -> P1-I1-W1, P2-I2-W3 -> P1-I1-W2, P4-I5-W1 -> P2-I1-W1, Q2 -> Q1, Q5 -> Q2, G3 -> G1
  def referenced_state
    state_fixture(
      projects: [project_record(id: "P2", status: "working"), project_record(id: "P4", status: "working")],
      issues: [
        issue_record(id: "P2-I2", project_id: "P2", status: "working", agent_ids: %w[P2-I2-W2 P2-I2-W3],
                     extra: { "last_agent_id" => "P2-I2-W3" }),
        issue_record(id: "P4-I5", project_id: "P4", status: "working", agent_ids: ["P4-I5-W1"])
      ],
      agents: [
        worker_record(id: "P2-I2-W2", issue_id: "P2-I2", project_id: "P2", status: "working",
                      harness_metadata: { "title" => "Investigate" }),
        worker_record(
          id: "P2-I2-W3",
          issue_id: "P2-I2",
          project_id: "P2",
          status: "queued",
          harness_metadata: {
            "title" => "Implement",
            "provisioning_state" => "deferred",
            "spawn_command_id" => "cmd-queue-1",
            "deferred_spawn" => {
              "state" => "waiting",
              "after_agent_id" => "P2-I2-W2",
              "after_agent_issue_id" => "P2-I2",
              "after_agent_title" => "Investigate",
              "if_predecessor_fails" => "cancel",
              "include_predecessor_result" => true,
              "chain_depth" => 1,
              "queued_prompt" => "Implement what P2-I2-W2 found."
            },
            "pending_prompts" => [
              { "id" => "P2-I2-W3-PP1", "command_id" => "cmd-prompt-9", "prompt" => "Also update the docs.",
                "mode" => "follow_up", "attempts" => 1 }
            ]
          },
          extra: { "after_agent_id" => "P2-I2-W2", "follow_up_of_agent_id" => "P2-I2-W2" }
        ),
        worker_record(id: "P4-I5-W1", issue_id: "P4-I5", project_id: "P4", status: "working",
                      harness_metadata: { "title" => "Goal attempt", "created_for_goal" => true })
      ],
      questions: [
        question_record(id: "Q2", project_id: "P2", issue_id: "P2-I2", status: "answered"),
        question_record(id: "Q5", project_id: "P4", issue_id: "P4-I5", status: "open")
      ],
      logs: [
        # An earlier pass's own log entry. Its recorded mapping is history: the new-id side is a
        # live id, so it proves a previous rename is never renumbered a second time.
        log_record(
          id: "L6",
          message: "Recounted AgentTree IDs; renamed 1 record.",
          details: { "changed_id_count" => 1, "mappings" => { "worker_ids" => { "P9-I1-W1" => "P2-I2-W2" } } }
        ),
        log_record(
          id: "L7",
          source_id: "P2-I2-W3",
          message: "Queued worker P2-I2-W3 on P2-I2 to start after P2-I2-W2 settles.",
          details: {
            "project_id" => "P2",
            "issue_id" => "P2-I2",
            "agent_id" => "P2-I2-W3",
            "after_agent_id" => "P2-I2-W2",
            "head_id" => "H1",
            "routing_action" => "queue_deferred_worker"
          }
        )
      ],
      conversation: {
        "messages" => [
          { "id" => 4, "role" => "agent", "text" => "Investigated the signup path.", "source_id" => "P2-I2-W2" },
          { "id" => 5, "role" => "user", "text" => "thanks" }
        ],
        "next_message_id" => 6
      },
      counters: {
        "projects" => 4, "heads" => 1, "questions" => 5, "goals" => 3, "logs" => 7,
        "issues_by_project" => { "P2" => 1, "P4" => 1 },
        "workers_by_issue" => { "P2-I2" => 2, "P4-I5" => 1 }
      },
      metadata: { "created_at" => BASE_TIME, "updated_at" => BASE_TIME }
    ).merge(
      "goals" => [
        {
          "id" => "G3",
          "project_id" => "P4",
          "issue_id" => "P4-I5",
          "title" => "Get the suite green",
          "success_criteria" => "0 failures",
          "status" => "working",
          "active_worker_id" => "P4-I5-W1",
          "last_worker_id" => "P4-I5-W1",
          "question_id" => "Q5",
          "iterations" => [
            { "number" => 1, "phase" => "settled", "attempt_worker_id" => "P4-I5-W1",
              "attempt_command_id" => "G3-IT1-ATTEMPT" }
          ],
          "created_at" => BASE_TIME,
          "updated_at" => BASE_TIME
        }
      ],
      "ui" => { "agent_workspace" => { "selected_agent_id" => "P2-I2-W2", "view" => "agent", "filter" => "all" } }
    )
  end

  def recounted_state
    write_state(referenced_state)
    engine = build_engine
    result = apply_command(engine, "Recount", {})
    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    read_state
  end

  # --- Queued worker chains -------------------------------------------------------------------

  # The user-named case: a worker queued behind another worker. The dependency lives in two
  # places, so both must move together or the dependent waits on an id that no longer exists.
  def test_a_queued_worker_still_points_at_its_renamed_predecessor
    state = recounted_state

    dependent = agent_by_id(state, "P1-I1-W2")
    deferred = dependent.fetch("harness_metadata").fetch("deferred_spawn")

    assert_equal "P1-I1-W1", dependent.fetch("after_agent_id")
    assert_equal "P1-I1-W1", deferred.fetch("after_agent_id")
    assert_equal "P1-I1", deferred.fetch("after_agent_issue_id")
    assert_equal "waiting", deferred.fetch("state")
    assert_equal "queued", dependent.fetch("status")
    assert_equal "P1-I1-W1", dependent.fetch("follow_up_of_agent_id")
  end

  # End-to-end proof that the renamed chain is still schedulable: settling the renamed
  # predecessor must start the renamed dependent with the handover prompt.
  def test_a_queued_worker_still_activates_after_a_recount
    write_state(referenced_state)
    engine = build_engine
    apply_command(engine, "Recount", {})

    engine.mark_worker_completed(agent_id: "P1-I1-W1", last_assistant_text: "The bug is in SignupsController.")

    state = read_state
    dependent = agent_by_id(state, "P1-I1-W2")
    deferred = dependent.fetch("harness_metadata").fetch("deferred_spawn")

    assert_equal "working", dependent.fetch("status")
    assert_equal "activated", deferred.fetch("state")
    assert_equal "P1-I1-W1", deferred.fetch("after_agent_id")
    assert_includes dependent.fetch("harness_metadata").fetch("spawn_prompt"), "Handover from P1-I1-W1"
    assert_includes log_messages(state), "Started queued worker P1-I1-W2 on P1-I1 because P1-I1-W1 settled (completed)."
  end

  # --- Goals ----------------------------------------------------------------------------------

  def test_goal_worker_and_question_references_follow_the_rename
    goal = recounted_state.fetch("goals").first

    assert_equal "G1", goal.fetch("id")
    assert_equal "P2", goal.fetch("project_id")
    assert_equal "P2-I1", goal.fetch("issue_id")
    assert_equal "P2-I1-W1", goal.fetch("active_worker_id")
    # `last_worker_id` is what Kill uses to stop the session a goal owns, so a stale value here
    # silently leaves an attempt worker running.
    assert_equal "P2-I1-W1", goal.fetch("last_worker_id")
    assert_equal "Q2", goal.fetch("question_id")
    assert_equal "P2-I1-W1", goal.fetch("iterations").first.fetch("attempt_worker_id")
  end

  # `last_worker_id` is the only handle Kill has on the session a paused goal owns, so a stale
  # value leaves that worker running after the goal is killed. The goal here sits between
  # iterations (no active worker), which is exactly when the stale value is not repaired by the
  # settle path.
  def test_killing_a_paused_goal_after_a_recount_still_kills_the_worker_it_owns
    write_state(
      state_fixture(
        projects: [project_record(id: "P2", status: "working"), project_record(id: "P4", status: "working")],
        issues: [
          issue_record(id: "P2-I2", project_id: "P2", status: "working", agent_ids: ["P2-I2-W2"]),
          issue_record(id: "P4-I5", project_id: "P4", status: "working", agent_ids: ["P4-I5-W1"])
        ],
        agents: [
          worker_record(id: "P2-I2-W2", issue_id: "P2-I2", project_id: "P2", status: "working"),
          worker_record(id: "P4-I5-W1", issue_id: "P4-I5", project_id: "P4", status: "working")
        ]
      ).merge(
        "goals" => [
          { "id" => "G3", "project_id" => "P4", "issue_id" => "P4-I5", "title" => "Get the suite green",
            "success_criteria" => "0 failures", "status" => "working", "paused" => true,
            "active_worker_id" => nil, "last_worker_id" => "P4-I5-W1", "iterations" => [],
            "created_at" => BASE_TIME, "updated_at" => BASE_TIME }
        ]
      )
    )
    engine = build_engine
    apply_command(engine, "Recount", {})

    result = apply_command(engine, "Kill", "target_id" => "G1")

    assert_equal "accepted", result.fetch("status")
    kill_log = read_state.fetch("logs").reverse.find { |entry| entry.fetch("message") == "Killed G1." }
    assert_includes kill_log.fetch("details").fetch("killed_agent_ids"), "P2-I1-W1"
  end

  # --- Questions, issues, and lineage ---------------------------------------------------------

  def test_question_and_issue_references_follow_the_rename
    state = recounted_state

    assert_equal "P1", question_by_id(state, "Q1").fetch("project_id")
    assert_equal "P1-I1", question_by_id(state, "Q1").fetch("issue_id")
    assert_equal "P2-I1", question_by_id(state, "Q2").fetch("issue_id")
    assert_equal %w[P1-I1-W1 P1-I1-W2], issue_by_id(state, "P1-I1").fetch("agent_ids")
    assert_equal "P1-I1-W2", issue_by_id(state, "P1-I1").fetch("last_agent_id")
  end

  # --- Logs and chat routing ------------------------------------------------------------------

  # Log routing is what groups a log line under its record in the AgentTree, the focused pane, and
  # GetInfo, so every id in the routing hash has to move with the record.
  def test_log_routing_references_follow_the_rename
    log = recounted_state.fetch("logs").find { |entry| entry.fetch("id") == "L7" }
    details = log.fetch("details")

    assert_equal "P1-I1-W2", log.fetch("source_id")
    assert_equal "P1", details.fetch("project_id")
    assert_equal "P1-I1", details.fetch("issue_id")
    assert_equal "P1-I1-W2", details.fetch("agent_id")
    assert_equal "P1-I1-W1", details.fetch("after_agent_id")
    assert_equal "H1", details.fetch("head_id"), "head ids are never renamed"
  end

  # Persisted chat messages carry the worker they came from. The chat pane resolves that id to an
  # agent record and uses it to deduplicate a completion message against the kernel log entry for
  # the same event, so a stale value renders an orphaned, doubled-up line.
  def test_persisted_chat_message_routing_follows_the_rename
    messages = recounted_state.fetch("conversation").fetch("messages")

    assert_equal "P1-I1-W1", messages.first.fetch("source_id")
    assert_equal [4, 5], messages.map { |message| message.fetch("id") }, "message ids stay append-only"
  end

  def test_agent_workspace_selection_follows_the_rename
    assert_equal "P1-I1-W1", recounted_state.dig("ui", "agent_workspace", "selected_agent_id")
  end

  # --- Deliberate preservation -----------------------------------------------------------------

  # Decision: ids inside human-readable text are history, not references. The line was true when
  # it was written, the mapping needed to translate it is stored by the same pass, and rewriting
  # prose would silently rewrite the record of what happened.
  def test_ids_inside_log_message_text_are_preserved_as_history
    log = recounted_state.fetch("logs").find { |entry| entry.fetch("id") == "L7" }

    assert_equal "Queued worker P2-I2-W3 on P2-I2 to start after P2-I2-W2 settles.", log.fetch("message")
  end

  def test_a_previous_recount_mapping_is_not_renumbered_again
    earlier = recounted_state.fetch("logs").find { |entry| entry.fetch("id") == "L6" }

    assert_equal({ "worker_ids" => { "P9-I1-W1" => "P2-I2-W2" } }, earlier.fetch("details").fetch("mappings"))
  end

  # Composite correlation ids embed a record id but are only ever compared against copies of
  # themselves (exactly-once dedupe). Renaming one copy and not another would break that dedupe,
  # so they are preserved verbatim like harness session ids and log ids.
  def test_opaque_composite_correlation_ids_are_preserved
    state = recounted_state
    metadata = agent_by_id(state, "P1-I1-W2").fetch("harness_metadata")

    assert_equal "cmd-queue-1", metadata.fetch("spawn_command_id")
    assert_equal "P2-I2-W3-PP1", metadata.fetch("pending_prompts").first.fetch("id")
    assert_equal "G3-IT1-ATTEMPT", state.fetch("goals").first.fetch("iterations").first.fetch("attempt_command_id")
  end

  # --- Validation ------------------------------------------------------------------------------

  # The backstop. `blocking_workers` stands in for any field that stores an id under a key the
  # rewriter does not recognise: rather than persisting a tree with a stranded pointer, the pass
  # fails, names the value and its path, and leaves state exactly as it was.
  def test_a_reference_the_rewrite_cannot_reach_fails_the_pass_and_writes_nothing
    write_state(
      state_fixture(
        projects: [project_record(id: "P2", status: "working")],
        issues: [
          issue_record(id: "P2-I2", project_id: "P2", status: "working", agent_ids: ["P2-I2-W2"],
                       extra: { "blocking_workers" => ["P2-I2-W2"] })
        ],
        agents: [worker_record(id: "P2-I2-W2", issue_id: "P2-I2", project_id: "P2", status: "working")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "failed", result.fetch("status")
    assert_match(/pointing at an ID that no longer exists/, result.fetch("message"))
    assert_match(/P2-I2-W2/, result.fetch("message"))
    state = read_state
    assert_equal ["P2"], ids(state.fetch("projects"))
    assert_equal ["P2-I2"], ids(state.fetch("issues"))
    assert_equal ["P2-I2-W2"], ids(state.fetch("agents"))
  end

  def test_a_failed_recount_leaves_the_in_memory_state_untouched
    state = Meringue::State::Models.ensure_state_shape!(
      state_fixture(
        projects: [project_record(id: "P2", status: "working")],
        issues: [
          issue_record(id: "P2-I2", project_id: "P2", status: "working", agent_ids: ["P2-I2-W2"],
                       extra: { "blocking_workers" => ["P2-I2-W2"] })
        ],
        agents: [worker_record(id: "P2-I2-W2", issue_id: "P2-I2", project_id: "P2", status: "working")]
      )
    )
    before = JSON.parse(JSON.generate(state))

    assert_raises(ArgumentError) { Meringue::State::Recounter.recount!(state) }

    assert_equal before, state, "a failed recount must not partially rename the caller's state"
  end

  # References that were already dangling before the pass cannot be repaired by renumbering, so
  # they must not make `/recount` unusable.
  def test_references_to_already_removed_records_do_not_block_a_recount
    write_state(
      state_fixture(
        projects: [project_record(id: "P2", status: "working")],
        issues: [issue_record(id: "P2-I2", project_id: "P2", status: "working", agent_ids: ["P2-I2-W2"])],
        agents: [
          worker_record(id: "P2-I2-W2", issue_id: "P2-I2", project_id: "P2", status: "working",
                        harness_metadata: { "replace_agent_id" => "P2-I2-W1" })
        ],
        logs: [log_record(id: "L3", source_id: "P9-I9-W9", details: { "agent_id" => "P9-I9-W9" })]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    state = read_state
    assert_equal ["P1-I1-W1"], ids(state.fetch("agents"))
    assert_equal "P9-I9-W9", state.fetch("logs").first.fetch("source_id")
  end

  # A queued worker's two copies of its dependency must agree. If a rename ever updated one and
  # not the other the dependent would wait forever or be cancelled, so the pass refuses to
  # persist that state.
  def test_a_split_queued_dependency_fails_validation
    state = Meringue::State::Models.ensure_state_shape!(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: %w[P1-I1-W1 P1-I1-W2])],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "working"),
          worker_record(
            id: "P1-I1-W2", issue_id: "P1-I1", project_id: "P1", status: "queued",
            harness_metadata: { "deferred_spawn" => { "state" => "waiting", "after_agent_id" => "P4-I2-W2" } },
            extra: { "after_agent_id" => "P1-I1-W1" }
          )
        ]
      )
    )

    error = assert_raises(ArgumentError) do
      Meringue::State::Recounter.validate_deferred_chains!(state, { "P1-I1-W2" => { "agreed" => true } })
    end

    assert_match(/disagrees about the worker it is queued behind/, error.message)
  end

  def log_messages(state)
    Array(state.fetch("logs")).map { |entry| entry.fetch("message") }
  end
end
