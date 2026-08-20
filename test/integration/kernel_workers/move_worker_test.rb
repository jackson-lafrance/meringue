# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# MoveWorker reparents an existing worker onto another issue in the same project without killing,
# restarting, or re-provisioning its harness session, worktree, or branch. The worker id and every
# live reference move in lockstep while external ownership identifiers remain stable.
class KernelWorkersMoveWorkerTest < Minitest::Test
  include KernelWorkersSupport

  def setup
    super
    @engine = build_engine
  end

  def teardown
    super
  end

  def agent_tree_text(state)
    Meringue::TUI::Panes::AgentTreePane.new.render(state, width: 100)
  end

  def project_with_two_issues(engine, repo_name: "demo-project")
    root = create_git_repo(repo_name)
    project_id = add_project(engine, root)
    first = create_issue(engine, project_id, title: "First issue")
    second = create_issue(engine, project_id, title: "Second issue")
    { "root" => root, "project_id" => project_id, "first_issue_id" => first, "second_issue_id" => second }
  end

  # --- same-project reparent -------------------------------------------------------------

  def test_same_project_move_renumbers_the_worker_and_preserves_the_harness_session
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id"), prompt: "Do the work.").fetch("target_id")
    session_id = agent(@engine, worker).fetch("harness_session_id")
    pid = agent(@engine, worker).fetch("pid")
    workspace_path = agent(@engine, worker).fetch("workspace_path")
    workspace_branch = agent(@engine, worker).fetch("workspace_branch")
    workspace_owner_id = agent(@engine, worker).dig("harness_metadata", "workspace_plan", "workspace_owner_id")

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})

    assert_equal "accepted", result.fetch("status")
    new_id = result.fetch("target_id")
    assert_equal "#{context.fetch("second_issue_id")}-W1", new_id
    assert_equal "Moved worker #{worker} to #{new_id} on issue #{context.fetch("second_issue_id")}.", result.fetch("message")

    moved = agent(@engine, new_id)
    assert_equal context.fetch("second_issue_id"), moved.fetch("issue_id")
    assert_equal context.fetch("project_id"), moved.fetch("project_id")
    # The harness session, workspace, and branch are byte-exact evidence and must stay intact.
    assert_equal session_id, moved.fetch("harness_session_id")
    assert_equal pid, moved.fetch("pid")
    assert_equal workspace_path, moved.fetch("workspace_path")
    assert_equal workspace_branch, moved.fetch("workspace_branch")
    assert_equal workspace_owner_id, moved.dig("harness_metadata", "workspace_plan", "workspace_owner_id")
    assert_equal worker, workspace_owner_id
    assert_equal "working", moved.fetch("status")

    # The old id no longer resolves; the old issue dropped the worker and the new issue gained it.
    assert_nil agent(@engine, worker)
    assert_includes issue(@engine, context.fetch("second_issue_id")).fetch("agent_ids"), new_id
    refute_includes issue(@engine, context.fetch("first_issue_id")).fetch("agent_ids"), new_id
    assert_empty issue(@engine, context.fetch("first_issue_id")).fetch("agent_ids")
    assert_equal "idle", issue(@engine, context.fetch("first_issue_id")).fetch("status")
    assert_equal "working", issue(@engine, context.fetch("second_issue_id")).fetch("status")

    # No harness session was killed, aborted, or re-spawned by the move.
    assert_empty @harness_client.kills
    assert_empty @harness_client.aborts
    assert_equal 1, @harness_client.spawns.length
  end

  def test_same_project_move_logs_the_reparent_and_marks_the_session_preserved
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})
    entry = state(@engine).fetch("logs").find { |log| log.fetch("id") == result.fetch("log_entry_ids").first }

    assert_equal "info", entry.fetch("level")
    assert_equal result.fetch("target_id"), entry.fetch("source_id")
    assert_includes entry.fetch("message"), "without restarting its harness session"
    assert_equal true, entry.fetch("details").fetch("harness_session_preserved")
    assert_equal false, entry.fetch("details").fetch("cross_project")
  end

  # --- cross-project safety --------------------------------------------------------------

  def test_cross_project_move_is_rejected_to_preserve_repository_routing
    first = project_with_two_issues(@engine, repo_name: "demo-project")
    second_root = create_git_repo("other-project")
    second_project = add_project(@engine, second_root, name: "Other")
    second_issue = create_issue(@engine, second_project, title: "Other issue")

    worker = spawn_worker(@engine, first.fetch("first_issue_id")).fetch("target_id")
    original = agent(@engine, worker)

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => second_issue })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "cross_project_move_unsupported"
    assert_includes result.fetch("message"), "without changing repositories"
    assert_equal original, agent(@engine, worker)
    assert_nil agent(@engine, "#{second_issue}-W1")
  end

  # --- streaming (in-flight) worker ------------------------------------------------------

  def test_streaming_worker_reparent_lands_without_interrupting_the_turn
    @harness_client.streaming = true
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")

    streaming_before = agent(@engine, worker).fetch("harness_metadata").fetch("is_streaming")
    assert streaming_before, "fixture: the worker should be mid-turn before the move"

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})
    assert_equal "accepted", result.fetch("status")

    moved = agent(@engine, result.fetch("target_id"))
    # The turn keeps streaming: the streaming marker, status, and session reference are unchanged.
    assert_equal "working", moved.fetch("status")
    assert_equal true, moved.fetch("harness_metadata").fetch("is_streaming")
    # The old worker id no longer resolves; the session id is unchanged on the moved record.
    assert_nil agent(@engine, worker)
    # No abort/kill/spawn touched the harness.
    assert_empty @harness_client.aborts
    assert_empty @harness_client.kills
    assert_equal 1, @harness_client.spawns.length
  end

  # --- settled worker --------------------------------------------------------------------

  def test_settled_worker_reparent_keeps_the_resumable_session_reference
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")
    session_id = agent(@engine, worker).fetch("harness_session_id")
    pid = agent(@engine, worker).fetch("pid")

    # A settled worker is no longer mid-turn but still holds its resumable harness session
    # reference, the way a reconciled `idle` worker looks. Move it onto the other issue.
    patch_agent!(worker) do |record|
      record["status"] = "idle"
      record.fetch("harness_metadata")["is_streaming"] = false
    end

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id") })
    assert_equal "accepted", result.fetch("status")

    moved = agent(@engine, result.fetch("target_id"))
    assert_equal "idle", moved.fetch("status")
    assert_equal false, moved.fetch("harness_metadata").fetch("is_streaming")
    # The resumable session reference is preserved so a later prompt can reattach it.
    assert_equal session_id, moved.fetch("harness_session_id")
    assert_equal pid, moved.fetch("pid")
    assert_equal context.fetch("second_issue_id"), moved.fetch("issue_id")
  end

  # --- reference re-pointing of dependents ----------------------------------------------

  def test_dependents_queued_behind_the_moved_worker_are_repointed_to_the_new_id
    context = project_with_two_issues(@engine)
    predecessor = spawn_worker(@engine, context.fetch("first_issue_id"), prompt: "Investigate.").fetch("target_id")
    dependent = spawn_worker(
      @engine,
      context.fetch("first_issue_id"),
      prompt: "Implement.",
      after_agent_id: predecessor
    ).fetch("target_id")

    assert_equal predecessor, agent(@engine, dependent).fetch("after_agent_id")

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => predecessor, "target_issue_id" => context.fetch("second_issue_id")})
    new_predecessor_id = result.fetch("target_id")

    repointed = agent(@engine, dependent)
    assert_equal new_predecessor_id, repointed.fetch("after_agent_id")
    deferred = repointed.fetch("harness_metadata").fetch("deferred_spawn")
    assert_equal new_predecessor_id, deferred.fetch("after_agent_id")
    # The dependent still waits; only its predecessor reference moved.
    assert_equal "queued", repointed.fetch("status")
    # The recorded predecessor issue was refreshed so the deferred chain stays coherent.
    assert_equal context.fetch("second_issue_id"), deferred.fetch("after_agent_issue_id")
  end

  def test_replace_and_follow_up_lineage_pointing_at_the_moved_worker_is_repointed
    context = project_with_two_issues(@engine)
    original = spawn_worker(@engine, context.fetch("first_issue_id"), prompt: "First pass.").fetch("target_id")
    follow_up = spawn_worker(
      @engine,
      context.fetch("first_issue_id"),
      prompt: "Second pass.",
      follow_up_of_agent_id: original
    ).fetch("target_id")

    assert_equal original, agent(@engine, follow_up).fetch("follow_up_of_agent_id")
    assert_includes agent(@engine, original).fetch("follow_up_agent_ids"), follow_up

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => original, "target_issue_id" => context.fetch("second_issue_id")})
    new_id = result.fetch("target_id")

    moved = agent(@engine, new_id)
    # The moved worker keeps its own lineage (it is still followed by the same successor).
    assert_includes moved.fetch("follow_up_agent_ids"), follow_up
    # The successor's back-reference now points at the moved worker's new id.
    assert_equal new_id, agent(@engine, follow_up).fetch("follow_up_of_agent_id")
  end

  def test_ids_quoted_in_log_prose_are_repointed_to_the_new_worker_id
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id"), prompt: "Do the work.").fetch("target_id")
    # A prior log line mentions the worker by its old id.
    apply_raw(@engine, "PromptAgent", { "agent_id" => worker, "prompt" => "status?" })

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})
    new_id = result.fetch("target_id")

    messages = state(@engine).fetch("logs").map { |entry| entry.fetch("message").to_s }
    # No log line still quotes the old worker id as a live reference.
    refute messages.any? { |message| message =~ /#{Regexp.escape(worker)}(?![\w\/-])/ && !message.include?(new_id) },
           "expected log prose to stop quoting #{worker} after the move, got:\n#{messages.join("\n")}"
  end

  # --- AgentTree re-render ---------------------------------------------------------------

  def test_agent_tree_renders_the_moved_worker_under_the_new_issue
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id"), prompt: "Do the work.").fetch("target_id")

    before = agent_tree_text(state(@engine))
    assert_includes before, "First issue"
    assert_includes before, "Second issue"
    # The worker is rendered under the first issue before the move.
    first_section = before.split("Second issue").first
    assert_includes first_section, "W1"

    apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})

    after = agent_tree_text(state(@engine))
    # After the move the worker appears under the second issue and not under the first.
    first_after = after.split("Second issue").first
    refute_includes first_after, "W1"
    second_after = after.split("Second issue").last
    assert_includes second_after, "W1"
  end

  # --- validation ------------------------------------------------------------------------

  def test_move_rejects_an_unknown_agent
    context = project_with_two_issues(@engine)
    before = state(@engine).fetch("agents").map { |record| record.fetch("id") }

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => "P1-I1-W9", "target_issue_id" => context.fetch("second_issue_id")})

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_found"
    assert_includes result.fetch("message"), "Agent P1-I1-W9 does not exist."
    assert_includes result.fetch("message"), "Dropped move of P1-I1-W9"
    assert_equal before, state(@engine).fetch("agents").map { |record| record.fetch("id") }
  end

  def test_move_rejects_a_head_agent
    context = project_with_two_issues(@engine)
    head_id = apply_raw(@engine, "SpawnHead", { "user_message" => "hello" }).fetch("target_id")

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => head_id, "target_issue_id" => context.fetch("second_issue_id")})

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_is_not_worker"
    assert_includes result.fetch("message"), "is a head, not a worker"
  end

  def test_move_rejects_an_unknown_target_issue
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => "P1-I99" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "target_issue_not_found"
    assert_includes result.fetch("message"), "Issue P1-I99 does not exist."
    # The worker stayed put.
    assert_equal context.fetch("first_issue_id"), agent(@engine, worker).fetch("issue_id")
  end

  def test_move_rejects_a_target_issue_in_a_missing_project_via_state_edit
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")

    # Simulate a target issue whose project was removed out of band.
    patch_state! do |state|
      issue = state.fetch("issues").find { |record| record.fetch("id") == context.fetch("second_issue_id") }
      issue["project_id"] = "P99"
    end

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "target_project_not_found"
  end

  def test_move_rejects_a_worker_while_background_provisioning_owns_its_id
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")
    patch_agent!(worker) do |record|
      record["harness_session_id"] = nil
      record["harness_session_file"] = nil
      record["pid"] = nil
      record.fetch("harness_metadata")["provisioning_state"] = "provisioning_queued"
    end

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id") })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "worker_provisioning_in_progress"
    assert_equal context.fetch("first_issue_id"), agent(@engine, worker).fetch("issue_id")
  end

  def test_move_rejects_a_worker_already_on_the_target_issue
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")

    result = apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("first_issue_id")})

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "already_on_target_issue"
    assert_includes result.fetch("message"), "already on issue"
  end

  def test_move_requires_both_arguments
    assert_rejected move_result(agent_id: nil, target_issue_id: "P1-I1"), "agent_id is required"
    assert_rejected move_result(agent_id: "P1-I1-W1", target_issue_id: nil), "target_issue_id is required"
  end

  def test_move_accepts_camel_case_keys_and_alias
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")

    result = apply_raw(@engine, "move_worker", { "AgentID" => worker, "TargetIssueID" => context.fetch("second_issue_id")})

    assert_equal "accepted", result.fetch("status")
    assert_equal "MoveWorker", result.fetch("command_type")
  end

  def test_move_is_head_proposable
    assert_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, "MoveWorker"
  end

  def test_recount_stays_valid_after_a_move
    context = project_with_two_issues(@engine)
    worker = spawn_worker(@engine, context.fetch("first_issue_id")).fetch("target_id")
    apply_raw(@engine, "MoveWorker", { "agent_id" => worker, "target_issue_id" => context.fetch("second_issue_id")})

    # Recount renumbers every record and audits referential integrity; a moved worker whose id
    # and references were not re-pointed in lockstep would fail this.
    result = apply_raw(@engine, "Recount")
    assert_equal "accepted", result.fetch("status"), result.inspect
  end

  private

  def move_result(agent_id:, target_issue_id:)
    payload = { "agent_id" => agent_id, "target_issue_id" => target_issue_id }.compact
    apply_raw(@engine, "MoveWorker", payload)
  end

  def assert_rejected(result, expected_error)
    assert_equal "rejected", result.fetch("status"), result.inspect
    assert result.fetch("errors").any? { |error| error.to_s.include?(expected_error) },
           "expected errors #{result.fetch("errors").inspect} to include #{expected_error.inspect}"
  end
end
