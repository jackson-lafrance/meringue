# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# State::Models shape normalization: defaults, tolerance for unknown fields, the
# documented status/level vocabularies, counters, and agent-workspace presentation state.
class StateModelsShapeTest < Minitest::Test
  include StateSupport

  def test_allowed_status_and_level_vocabularies
    assert_equal %w[queued working idle blocked paused completed errored killed supervision_lost], Models::LIFECYCLE_STATUSES
    assert_equal %w[open answered dismissed], Models::QUESTION_STATUSES
    assert_equal %w[info warning error], Models::LOG_LEVELS
    assert_equal %w[user kernel head worker harness system], Models::LOG_SOURCE_TYPES
    assert_equal 500, Models::LOG_RETENTION_LIMIT
    assert_equal 1, Models::SCHEMA_VERSION

    [Models::LIFECYCLE_STATUSES, Models::QUESTION_STATUSES, Models::LOG_LEVELS, Models::LOG_SOURCE_TYPES].each do |list|
      assert list.frozen?, "status vocabularies must be frozen"
    end
  end

  def test_empty_state_has_every_required_section
    state = Models.empty_state(now: "2026-07-11T00:00:00Z")

    assert_equal(
      %w[schema_version projects issues agents questions goals logs conversation ui counters metadata].sort,
      state.keys.sort
    )
    assert_equal "2026-07-11T00:00:00Z", state.dig("metadata", "created_at")
    assert_equal "2026-07-11T00:00:00Z", state.dig("metadata", "updated_at")
    assert_equal(
      %w[projects heads questions goals logs issues_by_project workers_by_issue].sort,
      state.fetch("counters").keys.sort
    )
  end

  def test_ensure_state_shape_is_idempotent
    state = Models.ensure_state_shape!({}, now: "2026-07-11T00:00:00Z")
    snapshot = JSON.generate(state)

    Models.ensure_state_shape!(state, now: "2027-01-01T00:00:00Z")

    assert_equal snapshot, JSON.generate(state), "re-normalizing an already-normal state must not change it"
  end

  def test_ensure_state_shape_preserves_unknown_sections_and_record_fields
    state = {
      "unknown_section" => { "keep" => true },
      "projects" => [{ "id" => "P1", "unknown_project_field" => 7 }],
      "questions" => [{ "id" => "Q1", "status" => "answered", "unknown" => nil }]
    }

    Models.ensure_state_shape!(state)

    assert_equal({ "keep" => true }, state.fetch("unknown_section"))
    assert_equal 7, state.fetch("projects").first.fetch("unknown_project_field")
    assert state.fetch("questions").first.key?("unknown")
  end

  def test_ensure_state_shape_migrates_legacy_pi_defaults_to_agent_defaults
    state = {
      "metadata" => {
        "pi_session_defaults" => {
          "model" => "openai/gpt-5.6-sol",
          "roles" => {
            "head" => { "thinking_level" => "low" },
            "worker" => { "thinking_level" => "max" }
          }
        }
      }
    }

    Models.ensure_state_shape!(state)
    defaults = state.dig("metadata", "agent_session_defaults")

    assert_equal "openai/gpt-5.6-sol", state.dig("metadata", "pi_session_defaults", "model")
    assert_nil state.dig("metadata", "pi_session_defaults", "roles", "head", "model")
    assert_equal({ "thinking_level" => "max" }, state.dig("metadata", "pi_session_defaults", "roles", "worker"))
    assert_equal "openai/gpt-5.6-sol", defaults.fetch("model")
    assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "head", "model")
    assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "worker", "model")
    assert_equal "low", defaults.dig("roles", "head", "thinking_level")
    assert_equal "max", defaults.dig("roles", "worker", "thinking_level")

    snapshot = JSON.generate(state)
    Models.ensure_state_shape!(state)
    assert_equal snapshot, JSON.generate(state), "the defaults migration must be idempotent"
  end

  def test_agent_session_defaults_are_authoritative_over_legacy_pi_defaults
    state = {
      "metadata" => {
        "agent_session_defaults" => { "model" => "anthropic/claude-opus-5" },
        "pi_session_defaults" => { "model" => "openai/legacy" }
      }
    }

    Models.ensure_state_shape!(state)

    assert_equal "anthropic/claude-opus-5", state.dig("metadata", "agent_session_defaults", "model")
    assert_equal "openai/legacy", state.dig("metadata", "pi_session_defaults", "model")
  end

  # A lifecycle status is never part of a project's name. State written before that was
  # enforced is repaired on load, so a project stored as "Meringue working" comes back as
  # "Meringue" instead of staying broken until the user renames it.
  def test_ensure_state_shape_repairs_project_names_that_carry_a_lifecycle_status
    state = {
      "projects" => [
        { "id" => "P1", "name" => "Meringue working", "status" => "working" },
        { "id" => "P2", "name" => "World  working", "status" => "working" },
        { "id" => "P3", "name" => "Working Copy", "status" => "idle" },
        { "id" => "P4", "name" => "Payments Integration", "status" => "completed" },
        { "id" => "P5", "status" => "queued" }
      ]
    }

    Models.ensure_state_shape!(state)
    names = state.fetch("projects").map { |project| project["name"] }

    assert_equal ["Meringue", "World", "Working Copy", "Payments Integration", nil], names
    assert_equal %w[working working idle completed queued], state.fetch("projects").map { |project| project.fetch("status") }
  end

  def test_repairing_project_names_is_idempotent
    state = { "projects" => [{ "id" => "P1", "name" => "Meringue working", "status" => "working" }] }

    Models.ensure_state_shape!(state)
    snapshot = JSON.generate(state)
    Models.ensure_state_shape!(state)

    assert_equal snapshot, JSON.generate(state)
  end

  def test_ensure_state_shape_does_not_reject_out_of_vocabulary_statuses
    # Normalization is tolerant by design: the kernel owns lifecycle transitions, so a
    # hand-edited or future status is preserved rather than raising or being rewritten.
    state = {
      "agents" => [{ "id" => "P1-I1-W1", "type" => "worker", "issue_id" => "P1-I1", "status" => "sleeping" }],
      "questions" => [{ "id" => "Q1", "status" => "escalated" }],
      "logs" => [{ "id" => "L1", "level" => "trace", "source_type" => "cosmic" }]
    }

    Models.ensure_state_shape!(state)

    assert_equal "sleeping", state.fetch("agents").first.fetch("status")
    assert_equal "escalated", state.fetch("questions").first.fetch("status")
    assert_equal "trace", state.fetch("logs").first.fetch("level")
  end

  def test_counters_are_derived_from_the_highest_existing_identifier
    state = {
      "projects" => [{ "id" => "P2" }, { "id" => "P10" }, { "id" => "not-a-project" }],
      "agents" => [
        { "id" => "H3", "type" => "head" },
        { "id" => "H11", "type" => "head" },
        { "id" => "P1-I1-W9", "type" => "worker" }
      ],
      "questions" => [{ "id" => "Q4" }],
      "logs" => [{ "id" => "L12" }]
    }

    Models.ensure_state_shape!(state)

    counters = state.fetch("counters")
    assert_equal 10, counters.fetch("projects")
    assert_equal 11, counters.fetch("heads")
    assert_equal 4, counters.fetch("questions")
    assert_equal 12, counters.fetch("logs")
  end

  def test_existing_counters_are_never_lowered_for_logs
    state = { "counters" => { "logs" => 99 }, "logs" => [{ "id" => "L3" }] }

    Models.ensure_state_shape!(state)

    assert_equal 99, state.dig("counters", "logs")
  end

  def test_existing_counters_are_preserved_for_other_record_types
    state = { "counters" => { "projects" => 42, "questions" => 7 }, "projects" => [{ "id" => "P1" }] }

    Models.ensure_state_shape!(state)

    assert_equal 42, state.dig("counters", "projects")
    assert_equal 7, state.dig("counters", "questions")
  end

  def test_conversation_next_message_id_defaults_to_the_highest_message_id
    state = { "conversation" => { "messages" => [{ "id" => 4 }, { "id" => 9 }, { "id" => 2 }] } }

    Models.ensure_state_shape!(state)

    assert_equal 9, state.dig("conversation", "next_message_id")
    assert_equal 9, Models.max_log_message_id(state)
    assert_equal 0, Models.max_log_message_id({})
  end

  def test_agent_workspace_state_defaults_and_invalid_selection_clearing
    state = {
      "agents" => [{ "id" => "P1-I1-W1", "type" => "worker" }],
      "ui" => { "agent_workspace" => { "selected_agent_id" => "P9-I9-W9", "view" => "hologram", "filter" => "sparkles", "draft" => "hi" } }
    }

    Models.ensure_state_shape!(state)
    workspace = state.dig("ui", "agent_workspace")

    refute workspace.key?("selected_agent_id"), "a selection pointing at a pruned worker is cleared"
    assert_equal "agent", workspace.fetch("view")
    assert_equal "all", workspace.fetch("filter")
    assert_equal "", workspace.fetch("draft"), "the draft is dropped with the selection"
    assert_equal 0, workspace.fetch("agent_scroll_offset")
    assert_equal 0, workspace.fetch("terminal_scroll_offset")
  end

  def test_agent_workspace_state_keeps_valid_selection_and_bounds_offsets
    state = {
      "agents" => [{ "id" => "P1-I1-W1", "type" => "worker" }],
      "ui" => {
        "agent_workspace" => {
          "selected_agent_id" => "P1-I1-W1", "view" => "terminal", "filter" => "tools",
          "draft" => "ship it", "agent_scroll_offset" => -5, "terminal_scroll_offset" => "12"
        }
      }
    }

    Models.ensure_state_shape!(state)
    workspace = Models.agent_workspace_state(state)

    assert_equal "P1-I1-W1", workspace.fetch("selected_agent_id")
    assert_equal "terminal", workspace.fetch("view")
    assert_equal "tools", workspace.fetch("filter")
    assert_equal "ship it", workspace.fetch("draft")
    assert_equal 0, workspace.fetch("agent_scroll_offset")
    assert_equal 12, workspace.fetch("terminal_scroll_offset")
    assert_equal %w[agent terminal], Models::AGENT_WORKSPACE_VIEWS
    assert_equal %w[all output final reasoning tools], Models::AGENT_WORKSPACE_FILTERS
  end

  def test_nonnegative_integer_tolerates_garbage
    assert_equal 0, Models.nonnegative_integer(nil)
    assert_equal 0, Models.nonnegative_integer("nope")
    assert_equal 0, Models.nonnegative_integer(-3)
    assert_equal 4, Models.nonnegative_integer("4")
  end

  # The kernel performs head retries, the AgentTree offers them, and `/prompt` completion lists
  # them, so all three read this one classifier. A head is retryable while any part of the request
  # it was given is still unrouted.
  def test_head_retry_targets_are_heads_whose_request_is_still_unrouted
    assert_equal %w[errored killed blocked], Models::HEAD_RETRY_STATUSES

    refute Models.head_retry_target?(head_record(status: "working")), "a head that is still routing is not a retry target"
    refute Models.head_retry_target?(head_record(status: "completed")), "a head that routed everything is not a retry target"
    refute Models.head_retry_target?({ "id" => "P1-I1-W1", "type" => "worker", "status" => "errored" })

    assert Models.head_retry_target?(head_record(status: "errored")), "an errored head never routed its request"
    assert Models.head_retry_target?(head_record(status: "killed"))

    # Applied but nothing landed: the request was dropped, so it is still owed.
    nothing_routed = head_record(
      status: "blocked",
      metadata: {
        "head_result_applied_at" => "2026-08-05T16:56:30Z",
        "head_result_command_journal" => [
          { "command_type" => "ModifyIssue", "status" => "rejected" },
          { "command_type" => "SpawnWorker", "status" => "rejected" }
        ]
      }
    )
    assert Models.head_retry_target?(nothing_routed)
    assert_empty Models.head_applied_commands(nothing_routed)
    assert_equal 2, Models.head_unrouted_commands(nothing_routed).length
    refute Models.head_routed_anything?(nothing_routed)

    # Applied and half landed: retryable, and the journal separates the two halves so a retry can
    # leave the accepted command alone.
    partial = head_record(
      status: "blocked",
      metadata: {
        "head_result_applied_at" => "2026-08-05T12:59:56Z",
        "head_result_command_journal" => [
          { "command_type" => "CreateIssue", "status" => "accepted", "target_id" => "P4-I2" },
          { "command_type" => "SpawnWorker", "status" => "failed" }
        ]
      }
    )
    assert Models.head_retry_target?(partial)
    assert_equal ["P4-I2"], Models.head_applied_commands(partial).map { |entry| entry.fetch("target_id") }
    assert_equal ["SpawnWorker"], Models.head_unrouted_commands(partial).map { |entry| entry.fetch("command_type") }
    assert Models.head_routed_anything?(partial)

    # Everything landed, so re-running it would route the same work twice.
    fully_routed = head_record(
      status: "blocked",
      metadata: {
        "head_result_applied_at" => "2026-08-05T12:59:56Z",
        "head_result_command_journal" => [{ "command_type" => "CreateIssue", "status" => "accepted", "target_id" => "P4-I2" }]
      }
    )
    refute Models.head_retry_target?(fully_routed)

    # A head that asked a question instead of routing handed the request back deliberately; the
    # question is the affordance, not a retry.
    asked_question = head_record(
      status: "blocked",
      metadata: {
        "head_result_applied_at" => "2026-08-05T12:59:56Z",
        "head_result_question_ids" => ["Q3"]
      }
    )
    refute Models.head_retry_target?(asked_question)

    # A plain response is also a complete handled result. It has no synthetic NoOp journal entry,
    # but it must not become retryable merely because its command list is empty.
    answered_directly = head_record(
      status: "blocked",
      metadata: {
        "head_result_applied_at" => "2026-08-05T12:59:56Z",
        "response" => "No action is needed; that label describes a queued dependency."
      }
    )
    assert Models.head_routed_anything?(answered_directly)
    refute Models.head_retry_target?(answered_directly)
  end

  def head_record(status:, metadata: {})
    { "id" => "H26", "type" => "head", "status" => status, "harness_metadata" => metadata }
  end

  def test_worker_pull_request_records_migrate_onto_the_issue
    state = {
      "issues" => [{ "id" => "P1-I1", "project_id" => "P1" }],
      "agents" => [{
        "id" => "P1-I1-W1", "type" => "worker", "issue_id" => "P1-I1",
        "delivery_pull_request" => { "url" => "https://github.com/o/r/pull/1", "state" => "open" },
        "reported_pr_urls" => ["https://github.com/o/r/pull/1"],
        "harness_metadata" => { "candidate_pr_urls" => ["https://github.com/o/r/pull/2"] }
      }]
    }

    Models.ensure_state_shape!(state)

    issue = state.fetch("issues").first
    worker = state.fetch("agents").first
    assert_equal "https://github.com/o/r/pull/1", issue.fetch("delivery_pull_request").fetch("url")
    assert_equal ["https://github.com/o/r/pull/1"], issue.fetch("delivery_pull_requests").map { |record| record.fetch("url") }
    assert_equal ["https://github.com/o/r/pull/2"], issue.fetch("candidate_pr_urls")
    assert_equal ["https://github.com/o/r/pull/1"], issue.fetch("reported_pr_urls")
    Models::PULL_REQUEST_STORAGE_KEYS.each do |key|
      refute worker.key?(key), "worker should no longer store #{key}"
      refute worker.fetch("harness_metadata").key?(key), "worker harness_metadata should no longer store #{key}"
    end
  end

  # `ensure_state_shape!` runs on every state read and every kernel command, not only on the one
  # load that migrates an old file. Rebuilding every worker and every issue each time was ~75% of
  # the cost of normalizing a snapshot. Freezing the records is a structural way to assert the
  # work is skipped: any write at all raises FrozenError, so this fails the moment normalization
  # starts touching records that have nothing to migrate.
  def test_normalizing_an_already_normal_state_does_not_write_to_its_records
    state = {
      "projects" => [{ "id" => "P1", "name" => "demo", "root_path" => "/tmp/demo", "status" => "working" }],
      "issues" => (1..25).map { |n| { "id" => "P1-I#{n}", "project_id" => "P1", "title" => "issue #{n}", "status" => "working" } },
      "agents" => (1..25).map do |n|
        {
          "id" => "P1-I#{n}-W1", "type" => "worker", "issue_id" => "P1-I#{n}", "project_id" => "P1",
          "status" => "working", "workspace_mode" => "isolated", "effective_workspace_mode" => "isolated",
          "harness_metadata" => { "workspace_mode" => "isolated", "effective_workspace_mode" => "isolated" }.freeze
        }
      end
    }
    state.fetch("issues").each(&:freeze)
    state.fetch("agents").each(&:freeze)
    state.fetch("projects").each(&:freeze)

    Models.ensure_state_shape!(state)

    assert_equal 25, state.fetch("issues").length
    assert_equal 25, state.fetch("agents").length
  end

  # The skip is keyed on the pull-request keys actually being present, so a single legacy worker
  # in an otherwise modern state is still migrated.
  def test_one_legacy_worker_among_many_modern_ones_is_still_migrated
    state = {
      "issues" => (1..5).map { |n| { "id" => "P1-I#{n}", "project_id" => "P1" } },
      "agents" => (1..5).map do |n|
        agent = { "id" => "P1-I#{n}-W1", "type" => "worker", "issue_id" => "P1-I#{n}" }
        agent["delivery_pull_request"] = { "url" => "https://github.com/o/r/pull/9", "state" => "open" } if n == 4
        agent
      end
    }

    Models.ensure_state_shape!(state)

    migrated = state.fetch("issues").find { |issue| issue.fetch("id") == "P1-I4" }
    assert_equal "https://github.com/o/r/pull/9", migrated.fetch("delivery_pull_request").fetch("url")
    refute state.fetch("agents")[3].key?("delivery_pull_request")
    state.fetch("issues").reject { |issue| issue.fetch("id") == "P1-I4" }.each do |issue|
      refute issue.key?("delivery_pull_request"), "#{issue.fetch("id")} has no pull request to record"
    end
  end

  # An issue whose only pull-request key is an empty array is still normalized: the key is
  # present, so it is visited and deleted rather than left behind.
  def test_an_empty_pull_request_array_on_an_issue_is_still_cleaned_up
    state = {
      "issues" => [{ "id" => "P1-I1", "project_id" => "P1", "candidate_pr_urls" => [], "reported_pr_urls" => [] }],
      "agents" => []
    }

    Models.ensure_state_shape!(state)

    issue = state.fetch("issues").first
    refute issue.key?("candidate_pr_urls")
    refute issue.key?("reported_pr_urls")
  end

  def test_a_worker_with_an_unusable_workspace_mode_is_still_corrected
    state = {
      "issues" => [],
      "agents" => [
        { "id" => "P1-I1-W1", "type" => "worker", "workspace_mode" => "nonsense", "harness_metadata" => {} },
        { "id" => "P1-I1-W2", "type" => "worker", "harness_metadata" => {} }
      ]
    }

    Models.ensure_state_shape!(state)

    state.fetch("agents").each do |worker|
      assert_equal "isolated", worker.fetch("workspace_mode")
      assert_equal "isolated", worker.fetch("effective_workspace_mode")
      assert_equal "isolated", worker.fetch("harness_metadata").fetch("workspace_mode")
      assert_equal "isolated", worker.fetch("harness_metadata").fetch("effective_workspace_mode")
    end
  end
end
