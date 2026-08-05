# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# `SpawnWorker` with `after_command`: queueing a worker behind a shell condition instead of (or as
# well as) another agent, polling that condition from the reconcile pass, the handover it produces,
# and what happens when the condition never passes.
class KernelWorkersCommandGatedWorkerTest < Minitest::Test
  include KernelWorkersSupport

  # --- Queueing -------------------------------------------------------------------------------

  def test_a_worker_gated_on_a_command_is_recorded_queued_with_an_armed_gate
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the pair review.",
      title: "Respond to the review",
      after_command: "test -f #{tmp_path("approved")}",
      after_command_label: "pair review on the delivery PR"
    )
    worker = agent(engine, result.fetch("target_id"))
    deferred = worker.fetch("harness_metadata").fetch("deferred_spawn")
    gate = deferred.fetch("command_gate")

    assert_equal "queued", worker.fetch("status")
    assert_equal "waiting", deferred.fetch("state")
    assert_nil worker.fetch("after_agent_id")
    assert_equal "test -f #{tmp_path("approved")}", gate.fetch("command")
    assert_equal "pair review on the delivery PR", gate.fetch("label")
    assert_equal "exit_zero", gate.fetch("expect")
    assert_equal "project_root", gate.fetch("cwd")
    assert_equal "cancel", gate.fetch("if_gate_expires")
    assert_equal "pending", gate.fetch("state")
    # A gate with no predecessor is live immediately, so it has a budget and is due for a check.
    refute_nil gate.fetch("armed_at")
    refute_nil gate.fetch("expires_at")
    assert_nil worker.fetch("harness_session_id")
    assert_empty @harness_client.spawns
  end

  def test_queueing_on_a_command_names_the_condition_in_the_log
    engine = build_engine
    context = project_with_issue(engine)

    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_command: "gh pr view --json reviewDecision",
      after_command_label: "pair review"
    ).fetch("target_id")

    assert_includes log_messages(engine), "Queued worker #{worker_id} on P1-I1 to start after pair review passes."
    details = state(engine).fetch("logs").find { |entry| entry.fetch("details", {})["agent_id"] == worker_id }.fetch("details")
    assert_equal "queue_deferred_worker", details.fetch("routing_action")
    assert_equal "gh pr view --json reviewDecision", details.fetch("after_command")
    assert_equal "cancel", details.fetch("if_gate_expires")
  end

  def test_the_defaults_bound_the_gate_without_the_caller_saying_anything
    engine = build_engine
    context = project_with_issue(engine)

    worker_id = spawn_worker(engine, context.fetch("issue_id"), after_command: "true").fetch("target_id")
    gate = command_gate(engine, worker_id)

    assert_equal 60, gate.fetch("interval_seconds")
    assert_equal 30, gate.fetch("timeout_seconds")
    assert_equal 4 * 60 * 60, gate.fetch("max_wait_seconds")
  end

  def test_out_of_range_gate_numbers_are_clamped_rather_than_rejected
    engine = build_engine
    context = project_with_issue(engine)

    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      after_command: "true",
      after_command_interval_seconds: 0,
      after_command_timeout_seconds: 9_999,
      after_command_max_wait_seconds: 10 * 24 * 60 * 60
    ).fetch("target_id")
    gate = command_gate(engine, worker_id)

    assert_equal 5, gate.fetch("interval_seconds")
    assert_equal 120, gate.fetch("timeout_seconds")
    assert_equal 24 * 60 * 60, gate.fetch("max_wait_seconds")
  end

  # --- Rejections -----------------------------------------------------------------------------

  def test_a_gate_that_could_never_pass_is_rejected_at_spawn_time
    engine = build_engine
    context = project_with_issue(engine)

    missing_pattern = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Go.",
        "after_command" => "gh pr view --json reviewDecision",
        "after_command_expect" => "output_matches"
      }
    )
    broken_pattern = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Go.",
        "after_command" => "gh pr view --json reviewDecision",
        "after_command_expect" => "output_matches",
        "after_command_pattern" => "APPROVED("
      }
    )

    assert_equal "rejected", missing_pattern.fetch("status")
    assert_includes missing_pattern.fetch("errors"), "invalid_after_command_pattern"
    assert_equal "rejected", broken_pattern.fetch("status")
    assert_includes broken_pattern.fetch("errors"), "invalid_after_command_pattern"
    assert_empty state(engine).fetch("agents")
  end

  def test_unusable_gate_options_are_rejected
    engine = build_engine
    context = project_with_issue(engine)

    cases = {
      "invalid_after_command_expect" => { "after_command" => "true", "after_command_expect" => "vibes" },
      "invalid_after_command_cwd" => { "after_command" => "true", "after_command_cwd" => "somewhere_else" },
      "invalid_if_gate_expires" => { "after_command" => "true", "if_gate_expires" => "maybe" },
      # Gate options with no gate command would silently start the worker immediately.
      "after_command_required" => { "after_command_label" => "pair review" }
    }
    cases.each do |expected_error, payload|
      result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." }.merge(payload))

      assert_equal "rejected", result.fetch("status"), expected_error
      assert_includes result.fetch("errors"), expected_error
    end
    assert_empty state(engine).fetch("agents")
  end

  def test_a_command_gate_cannot_be_combined_with_a_replacement
    engine = build_engine
    context = project_with_issue(engine)
    existing_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Take over.",
        "replace_agent_id" => existing_id,
        "after_command" => "true"
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "after_command_conflicts_with_replace"
    assert_equal 1, @harness_client.spawns.length
  end

  # --- Polling and activation -----------------------------------------------------------------

  def test_the_worker_starts_when_the_command_passes_and_gets_the_output_as_handover
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review comments.",
      after_command: "cat #{tmp_path("review.json")}",
      after_command_label: "pair review"
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions")
    assert_equal "queued", agent(engine, worker_id).fetch("status"), "the condition has not passed yet"
    assert_empty @harness_client.spawns

    File.write(tmp_path("review.json"), "reviewDecision: APPROVED\n")
    make_gate_due!(worker_id)
    result = apply!(engine, "ReconcileSessions")

    worker = agent(engine, worker_id)
    gate = command_gate(engine, worker_id)
    prompt = @harness_client.spawns.last.fetch("prompt")

    assert_equal "working", worker.fetch("status")
    assert_equal "activated", worker.fetch("harness_metadata").fetch("deferred_spawn").fetch("state")
    assert_equal "satisfied", gate.fetch("state")
    assert_equal 2, gate.fetch("checks")
    assert_includes prompt, "Respond to the review comments."
    assert_includes prompt, "--- Wait condition: pair review ---"
    assert_includes prompt, "reviewDecision: APPROVED"
    assert_includes log_messages(engine), "Starting queued worker #{worker_id} because its wait condition pair review passed after 2 checks."
    refute_empty result.dig("result", "deferred_worker_gate_results")
  end

  def test_an_output_matching_gate_reads_the_command_output_instead_of_its_exit_status
    engine = build_engine
    context = project_with_issue(engine)
    File.write(tmp_path("decision"), "{\"reviewDecision\":\"REVIEW_REQUIRED\"}\n")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond.",
      after_command: "cat #{tmp_path("decision")}",
      after_command_expect: "output_matches",
      after_command_pattern: "APPROVED|CHANGES_REQUESTED"
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions")
    # The command exits 0 every time; only the output decides.
    assert_equal "queued", agent(engine, worker_id).fetch("status")
    assert_equal 0, command_gate(engine, worker_id).fetch("last_check").fetch("exit_status")

    File.write(tmp_path("decision"), "{\"reviewDecision\":\"CHANGES_REQUESTED\"}\n")
    make_gate_due!(worker_id)
    apply!(engine, "ReconcileSessions")

    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_equal "satisfied", command_gate(engine, worker_id).fetch("state")
  end

  def test_a_gate_is_not_re_run_before_its_interval_elapses
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), after_command: "false").fetch("target_id")

    3.times { apply!(engine, "ReconcileSessions") }

    assert_equal 1, command_gate(engine, worker_id).fetch("checks"), "the poll interval bounds how often the command runs"
    assert_equal "queued", agent(engine, worker_id).fetch("status")
  end

  def test_the_gate_runs_in_the_project_root_by_default
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), after_command: "pwd && test -f README.md").fetch("target_id")

    apply!(engine, "ReconcileSessions")

    assert_equal context.fetch("root"), command_gate(engine, worker_id).fetch("last_check").fetch("cwd")
    assert_equal "working", agent(engine, worker_id).fetch("status")
  end

  def test_include_predecessor_result_false_omits_the_gate_output
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Just start.",
      after_command: "echo secret-review-output",
      include_predecessor_result: false
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions")
    prompt = @harness_client.spawns.last.fetch("prompt")

    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_equal "Just start.", prompt
    refute_includes prompt, "secret-review-output"
  end

  # --- Composing with an agent gate ------------------------------------------------------------

  def test_a_command_gate_behind_a_predecessor_is_only_armed_once_that_predecessor_settles
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Open the PR.").fetch("target_id")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_agent_id: predecessor_id,
      after_command: "test -f #{tmp_path("reviewed")}",
      after_command_label: "pair review"
    ).fetch("target_id")

    assert_equal predecessor_id, agent(engine, worker_id).fetch("after_agent_id")
    assert_nil command_gate(engine, worker_id).fetch("armed_at", nil), "the gate waits for the predecessor first"
    apply!(engine, "ReconcileSessions")
    assert_equal 0, command_gate(engine, worker_id).fetch("checks", 0), "the command is not polled before the PR exists"
    assert_includes(
      log_messages(engine),
      "Queued worker #{worker_id} on P1-I1 to start after #{predecessor_id} settles and pair review passes."
    )

    File.write(tmp_path("reviewed"), "approved")
    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Opened PR #42.")

    # Settling the predecessor arms the gate; it does not start the worker.
    assert_equal "queued", agent(engine, worker_id).fetch("status")
    refute_nil command_gate(engine, worker_id).fetch("armed_at")
    assert_includes log_messages(engine), "Queued worker #{worker_id} is now waiting on pair review."

    apply!(engine, "ReconcileSessions")
    prompt = @harness_client.spawns.last.fetch("prompt")

    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_includes prompt, "Handover from #{predecessor_id}"
    assert_includes prompt, "Opened PR #42."
    assert_includes prompt, "--- Wait condition: pair review ---"
  end

  def test_a_killed_predecessor_cancels_the_worker_without_ever_running_its_command
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_agent_id: predecessor_id,
      after_command: "touch #{tmp_path("gate-ran")}"
    ).fetch("target_id")

    apply!(engine, "Kill", { "target_id" => predecessor_id })
    apply!(engine, "ReconcileSessions")

    assert_nil agent(engine, worker_id)
    refute_path_exists tmp_path("gate-ran")
  end

  def test_a_predecessor_that_already_completed_still_leaves_the_worker_queued_on_its_command
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Done.")

    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_agent_id: predecessor_id,
      after_command: "test -f #{tmp_path("never")}"
    ).fetch("target_id")

    assert_equal "queued", agent(engine, worker_id).fetch("status")
    assert_equal "waiting", agent(engine, worker_id).fetch("harness_metadata").fetch("deferred_spawn").fetch("state")

    # Its predecessor is already settled, so the very next pass arms the condition, and only the
    # condition keeps the worker queued from then on.
    apply!(engine, "ReconcileSessions")
    refute_nil command_gate(engine, worker_id).fetch("armed_at")
    assert_equal "queued", agent(engine, worker_id).fetch("status")
    assert_equal 1, @harness_client.spawns.length
  end

  # --- Giving up ------------------------------------------------------------------------------

  def test_a_condition_that_never_passes_cancels_the_worker_with_a_warning
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_command: "false",
      after_command_label: "pair review",
      after_command_max_wait_seconds: 60
    ).fetch("target_id")

    expire_gate!(worker_id)
    apply!(engine, "ReconcileSessions")

    assert_nil agent(engine, worker_id), "a cancelled queued worker is removed like a killed one"
    assert_includes(
      log_messages(engine),
      "Wait condition pair review for queued worker #{worker_id} did not pass within 60s."
    )
    assert_includes(
      log_messages(engine),
      "Cancelled queued worker #{worker_id} because its wait condition pair review did not pass within 60s."
    )
    assert_empty @harness_client.spawns
  end

  def test_if_gate_expires_run_starts_the_worker_anyway_and_says_so
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_command: "false",
      after_command_label: "pair review",
      after_command_max_wait_seconds: 60,
      if_gate_expires: "run"
    ).fetch("target_id")

    expire_gate!(worker_id)
    apply!(engine, "ReconcileSessions")
    prompt = @harness_client.spawns.last.fetch("prompt")
    warnings = state(engine).fetch("logs").select { |entry| entry.fetch("level") == "warning" }.map { |entry| entry.fetch("message") }

    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_includes prompt, "It never passed within its 60s budget"
    assert_includes(
      warnings,
      "Starting queued worker #{worker_id} because its wait condition pair review never passed within its 60s budget and if_gate_expires is \"run\"."
    )
  end

  # A gate that cannot even be run can never pass, so it must not quietly burn its whole budget.
  def test_a_gate_that_cannot_be_run_is_abandoned_after_three_consecutive_failures
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_command: "true",
      after_command_label: "pair review"
    ).fetch("target_id")
    FileUtils.remove_entry(context.fetch("root"))

    3.times do
      make_gate_due!(worker_id)
      apply!(engine, "ReconcileSessions")
    end

    assert_nil agent(engine, worker_id)
    warnings = state(engine).fetch("logs").select { |entry| entry.fetch("level") == "warning" }.map { |entry| entry.fetch("message") }
    assert_equal 3, warnings.count { |message| message.include?("could not be evaluated") }
    assert(warnings.any? { |message| message.include?("Cancelled queued worker #{worker_id} because its wait condition pair review could not be run 3 times in a row") })
    assert_empty @harness_client.spawns
  end

  # --- Durability -----------------------------------------------------------------------------

  def test_a_gate_survives_a_restart_because_it_lives_on_the_worker_record
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Respond to the review.",
      after_command: "test -f #{tmp_path("approved")}"
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions")
    assert_equal "queued", agent(engine, worker_id).fetch("status")

    File.write(tmp_path("approved"), "yes")
    make_gate_due!(worker_id)
    restarted = build_engine
    apply!(restarted, "ReconcileSessions")

    assert_equal "working", agent(restarted, worker_id).fetch("status")
    assert_equal "reconcile", agent(restarted, worker_id).fetch("harness_metadata").fetch("deferred_spawn").fetch("activation_trigger")
  end

  def test_reservation_recovery_leaves_a_command_gated_worker_alone
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), after_command: "test -f #{tmp_path("never")}").fetch("target_id")

    3.times { apply!(build_engine, "ReconcileSessions") }

    assert_equal "queued", agent(engine, worker_id).fetch("status")
    assert_empty @harness_client.spawns
  end

  # State compaction truncates long strings, and `harness_metadata.command` (the spawn argv) is
  # capped at 2,000 bytes per element. A gate command is a scalar Meringue still has to *run*, so
  # truncating it would silently poll a corrupted command forever. The array-scoped limit must not
  # reach it, exactly as it must not reach a goal's metric command.
  def test_a_long_gate_command_survives_state_compaction_verbatim
    engine = build_engine
    context = project_with_issue(engine)
    command = "test -f #{tmp_path("approved")} # #{"x" * 1_800}"
    worker_id = spawn_worker(engine, context.fetch("issue_id"), after_command: command).fetch("target_id")

    apply!(engine, "ReconcileSessions")

    assert_equal command, command_gate(build_engine, worker_id).fetch("command")
  end

  def test_get_info_says_what_the_worker_is_waiting_on
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      after_command: "gh pr view --json reviewDecision",
      after_command_label: "pair review"
    ).fetch("target_id")

    info = apply!(engine, "GetInfo", { "target_id" => worker_id })

    assert_equal "pair review", info.dig("result", "deferred_spawn", "command_gate", "label")
  end

  private

  def command_gate(engine, worker_id)
    agent(engine, worker_id).fetch("harness_metadata").fetch("deferred_spawn").fetch("command_gate")
  end

  # Rewinds the gate's next check so the following reconcile pass polls it, instead of sleeping
  # through a real poll interval.
  def make_gate_due!(worker_id)
    patch_agent!(worker_id) do |record|
      record.dig("harness_metadata", "deferred_spawn", "command_gate")["next_check_at"] = (Time.now - 3_600).iso8601
    end
  end

  # Same idea for the total wait budget.
  def expire_gate!(worker_id)
    patch_agent!(worker_id) do |record|
      gate = record.dig("harness_metadata", "deferred_spawn", "command_gate")
      gate["expires_at"] = (Time.now - 60).iso8601
    end
  end
end
