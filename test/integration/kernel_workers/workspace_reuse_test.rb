# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Worktree sharing between related workers.
#
# One durable goal is one issue, and an issue often needs several sequential workers: investigate,
# then implement, then react to review. Provisioning a brand new worktree on a suffixed branch for
# each of those steps means the successor cannot see what the predecessor left uncommitted, and one
# goal ends up spread over several branches and several pull requests.
#
# So a successor that continues a predecessor's line of work on the same issue keeps working in that
# predecessor's worktree and branch. The hard rule is that two live harness sessions must never
# write the same worktree: whenever Meringue cannot prove the checkout is free and healthy it
# refuses to share, says why, and provisions a fresh worktree instead.
class KernelWorkersWorkspaceReuseTest < Minitest::Test
  include KernelWorkersSupport

  # Offline forge that knows about exactly one open pull request for one branch, so branch-based
  # delivery matching can be asserted without touching the network.
  class SingleBranchForgeClient
    PULL_REQUEST_URL = "https://github.com/acme/demo/pull/12"

    def initialize(branch:, repository: "acme/demo", state: "open")
      @branch = branch
      @repository = repository
      @state = state
    end

    def pull_request_urls_for_branch(repository:, branch:)
      repository.to_s == @repository && branch.to_s == @branch ? [PULL_REQUEST_URL] : []
    end

    def pull_request_status(url)
      {
        "provider" => "github",
        "url" => url.to_s,
        "number" => 12,
        "state" => @state,
        "base_repository" => @repository,
        "head_repository" => @repository,
        "head_branch" => @branch,
        "is_cross_repository" => false
      }
    end
  end

  def settled_predecessor(engine, context, title: "Investigate the failure")
    worker_id = spawn_worker(engine, context.fetch("issue_id"), title: title).fetch("target_id")
    engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Findings: the index is missing.")
    worker_id
  end

  def worktree_dirs
    Dir.glob(File.join(workspace_root, "*", "*")).select { |path| File.directory?(path) }
  end

  def reuse_record(engine, agent_id)
    agent(engine, agent_id).fetch("harness_metadata").fetch("workspace_reuse", nil)
  end

  def reuse_log(engine, agent_id)
    worker_scoped_logs(engine, agent_id).find { |entry| entry.fetch("message").match?(/reuse|reused/) }
  end

  # --- the reuse path ---------------------------------------------------------------------------

  def test_a_worker_queued_after_a_settled_worker_continues_in_its_worktree_and_branch
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    predecessor = agent(engine, predecessor_id)
    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Now implement the fix.",
      after_agent_id: predecessor_id,
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")
    worktrees_before = worktree_dirs

    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Findings.")

    successor = agent(engine, successor_id)

    assert_equal predecessor.fetch("workspace_path"), successor.fetch("workspace_path")
    assert_equal predecessor.fetch("workspace_branch"), successor.fetch("workspace_branch")
    assert_equal "git_worktree", successor.fetch("workspace_strategy")
    assert_equal worktrees_before, worktree_dirs, "reuse must not provision a second worktree"
    assert_equal successor.fetch("workspace_path"), @harness_client.spawns.last.fetch("cwd")

    reuse = reuse_record(engine, successor_id)
    assert_equal "reused", reuse.fetch("state")
    assert_equal "continuation", reuse.fetch("source")
    assert_equal predecessor_id, reuse.fetch("of_agent_id")
    assert_equal predecessor.fetch("workspace_branch"), reuse.fetch("workspace_branch")
  end

  def test_reuse_is_reported_in_one_plain_log_line
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    branch = agent(engine, successor_id).fetch("workspace_branch")
    entry = reuse_log(engine, successor_id)

    refute_nil entry, "the user must be told the worker did not get its own worktree"
    assert_equal "info", entry.fetch("level")
    assert_includes entry.fetch("message"), "Worker #{successor_id} reused worker #{predecessor_id}'s worktree"
    assert_includes entry.fetch("message"), branch
    assert_includes entry.fetch("message"), "instead of provisioning a new one"
    assert_equal predecessor_id, entry.dig("details", "of_agent_id")
    assert_equal "reused", entry.dig("details", "state")
  end

  def test_the_successor_sees_committed_and_uncommitted_work_the_predecessor_left_behind
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    workspace = agent(engine, predecessor_id).fetch("workspace_path")
    File.write(File.join(workspace, "notes.md"), "half-finished\n")
    File.write(File.join(workspace, "committed.md"), "landed\n")
    run_git(workspace, "add", "committed.md")
    run_git(workspace, "commit", "-m", "predecessor commit")

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Finish it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    successor_workspace = agent(engine, successor_id).fetch("workspace_path")

    assert_equal workspace, successor_workspace
    assert_equal "half-finished\n", File.read(File.join(successor_workspace, "notes.md")),
                 "a dirty tree is the point of continuing someone else's work, not a reason to refuse"
    assert_includes run_git(successor_workspace, "log", "--oneline"), "predecessor commit"
    assert_equal "reused", reuse_record(engine, successor_id).fetch("state")
  end

  def test_the_successor_is_told_it_shares_the_workspace_and_should_update_the_existing_pull_request
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)

    spawn_worker(engine, context.fetch("issue_id"), prompt: "Implement it.", follow_up_of_agent_id: predecessor_id)

    prompt = @harness_client.spawns.last.fetch("prompt")

    assert_includes prompt, "Implement it."
    assert_includes prompt, "--- Shared workspace ---"
    assert_includes prompt, "existing worktree at #{agent(engine, predecessor_id).fetch("workspace_path")}"
    assert_includes prompt, "update that pull request instead of opening a second one"
  end

  def test_an_explicitly_named_worker_workspace_is_reused_without_any_other_relationship
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Pick up where that left off.",
      reuse_workspace_of_agent_id: predecessor_id
    ).fetch("target_id")

    successor = agent(engine, successor_id)

    assert_equal agent(engine, predecessor_id).fetch("workspace_path"), successor.fetch("workspace_path")
    assert_nil successor.fetch("follow_up_of_agent_id")
    assert_equal "explicit", reuse_record(engine, successor_id).fetch("source")
  end

  def test_a_replacement_reuses_the_workspace_of_the_worker_it_replaces_once_that_session_is_settled
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    predecessor_workspace = agent(engine, predecessor_id).fetch("workspace_path")

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Take a different approach.",
      replace_agent_id: predecessor_id
    ).fetch("target_id")

    assert_equal predecessor_workspace, agent(engine, successor_id).fetch("workspace_path")
    assert_equal "killed", agent(engine, predecessor_id).fetch("status")
    assert Dir.exist?(predecessor_workspace), "killing the replaced worker must not delete the shared checkout"
  end

  def test_reuse_survives_a_restart_and_reconciliation
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")
    expected = agent(engine, successor_id).slice("workspace_path", "workspace_branch", "workspace_strategy")

    # A brand new kernel over the same state file, which is what a restart really is.
    @store = nil
    restarted = build_engine
    apply!(restarted, "ReconcileSessions", {})

    successor = agent(restarted, successor_id)

    assert_equal expected, successor.slice("workspace_path", "workspace_branch", "workspace_strategy")
    assert_equal "reused", successor.fetch("harness_metadata").fetch("workspace_reuse").fetch("state")
    assert_equal predecessor_id, successor.fetch("harness_metadata").fetch("workspace_plan").fetch("inherited_from_agent_id")
    assert_equal true, successor.fetch("harness_metadata").fetch("workspace_plan").fetch("shared")
    refute successor.fetch("harness_metadata").fetch("workspace_plan").fetch("created"),
           "a shared workspace is never owned by the worker that borrowed it"
  end

  # --- opting out ------------------------------------------------------------------------------

  def test_share_workspace_false_keeps_a_continuation_step_in_its_own_worktree
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Try a completely different approach in parallel.",
      follow_up_of_agent_id: predecessor_id,
      share_workspace: false
    ).fetch("target_id")

    predecessor = agent(engine, predecessor_id)
    successor = agent(engine, successor_id)

    refute_equal predecessor.fetch("workspace_path"), successor.fetch("workspace_path")
    refute_equal predecessor.fetch("workspace_branch"), successor.fetch("workspace_branch")
    assert_nil reuse_record(engine, successor_id)
    assert_nil reuse_log(engine, successor_id), "opting out is the caller's decision, not an event to explain"
  end

  # An explicit path used to win over reuse. It is now refused outright - it carries no
  # isolation evidence - so the choice between the two never arises.
  def test_an_explicit_workspace_path_is_refused_rather_than_preferred_over_reuse
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    elsewhere = tmp_path("chosen-directory")
    FileUtils.mkdir_p(elsewhere)

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Work here.",
        "follow_up_of_agent_id" => predecessor_id,
        "workspace_path" => elsewhere
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "version_control_backend_required"
  end

  # --- refusals: state --------------------------------------------------------------------------

  def test_a_predecessor_that_is_still_live_is_never_shared_with
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Start the next part now.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    predecessor = agent(engine, predecessor_id)
    successor = agent(engine, successor_id)

    assert_equal "working", predecessor.fetch("status")
    refute_equal predecessor.fetch("workspace_path"), successor.fetch("workspace_path")
    refute_equal predecessor.fetch("workspace_branch"), successor.fetch("workspace_branch")
    assert Dir.exist?(successor.fetch("workspace_path"))

    reuse = reuse_record(engine, successor_id)
    assert_equal "refused", reuse.fetch("state")
    assert_equal "predecessor_still_live", reuse.fetch("reason")
    assert_equal [predecessor_id], reuse.fetch("occupant_agent_ids")

    entry = reuse_log(engine, successor_id)
    refute_nil entry
    assert_equal "info", entry.fetch("level")
    assert_includes entry.fetch("message"), "two sessions must never share one worktree"
    assert_includes entry.fetch("message"), "provisioned a fresh worktree"
  end

  def test_only_one_of_two_successors_of_the_same_settled_worker_may_share_its_worktree
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    shared_path = agent(engine, predecessor_id).fetch("workspace_path")

    first_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Step one.", follow_up_of_agent_id: predecessor_id).fetch("target_id")
    second_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Step two.", follow_up_of_agent_id: predecessor_id).fetch("target_id")

    assert_equal shared_path, agent(engine, first_id).fetch("workspace_path")
    refute_equal shared_path, agent(engine, second_id).fetch("workspace_path")
    assert_equal "workspace_in_use", reuse_record(engine, second_id).fetch("reason")
    assert_equal [first_id], reuse_record(engine, second_id).fetch("occupant_agent_ids")
  end

  def test_a_workspace_that_is_gone_from_disk_is_not_shared
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    FileUtils.remove_entry(agent(engine, predecessor_id).fetch("workspace_path"))

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    successor = agent(engine, successor_id)

    assert Dir.exist?(successor.fetch("workspace_path"))
    refute_equal agent(engine, predecessor_id).fetch("workspace_path"), successor.fetch("workspace_path")
    assert_equal "workspace_missing", reuse_record(engine, successor_id).fetch("reason")
  end

  def test_a_branch_that_already_merged_is_not_continued_on
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    branch = agent(engine, predecessor_id).fetch("workspace_branch")
    patch_state! do |state|
      issue = state.fetch("issues").find { |record| record.fetch("id") == context.fetch("issue_id") }
      issue["delivery_pull_requests"] = [{
        "provider" => "github",
        "url" => "https://github.com/acme/demo/pull/7",
        "state" => "merged",
        "matched_branch" => branch
      }]
    end

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Follow up on the review.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    successor = agent(engine, successor_id)

    refute_equal branch, successor.fetch("workspace_branch")
    reuse = reuse_record(engine, successor_id)
    assert_equal "delivery_branch_already_merged", reuse.fetch("reason")
    assert_equal "https://github.com/acme/demo/pull/7", reuse.fetch("pull_request_url")
  end

  # There is no such worker any more: a project whose root cannot host an isolated
  # worktree never gets registered, so no predecessor can be sitting in a project root
  # with nothing to share.
  def test_a_project_root_that_cannot_host_a_worktree_is_refused_at_registration
    engine = build_engine
    root = create_plain_directory

    result = apply_raw(engine, "AddProject", { "path" => root, "name" => "Plain" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "version_control_backend_unavailable"
  end

  # --- refusals: git ----------------------------------------------------------------------------

  def test_a_locked_worktree_is_not_shared
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    predecessor = agent(engine, predecessor_id)
    run_git(context.fetch("root"), "worktree", "lock", predecessor.fetch("workspace_path"))

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    successor = agent(engine, successor_id)

    refute_equal predecessor.fetch("workspace_path"), successor.fetch("workspace_path")
    assert Dir.exist?(successor.fetch("workspace_path"))
    assert_equal "worktree_locked", reuse_record(engine, successor_id).fetch("reason")
    assert_includes reuse_log(engine, successor_id).fetch("message"), "that worktree is locked"
  end

  def test_a_worktree_that_moved_to_another_branch_is_not_shared
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    predecessor = agent(engine, predecessor_id)
    run_git(predecessor.fetch("workspace_path"), "switch", "--create", "someone-elses-branch")

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    successor = agent(engine, successor_id)

    refute_equal predecessor.fetch("workspace_path"), successor.fetch("workspace_path")
    reuse = reuse_record(engine, successor_id)
    assert_equal "worktree_branch_moved", reuse.fetch("reason")
    assert_equal "someone-elses-branch", reuse.fetch("checked_out_branch")
  end

  def test_a_directory_git_no_longer_registers_as_a_worktree_is_not_shared
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    predecessor = agent(engine, predecessor_id)
    run_git(context.fetch("root"), "worktree", "remove", "--force", predecessor.fetch("workspace_path"))
    FileUtils.mkdir_p(predecessor.fetch("workspace_path"))

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")

    assert_equal "worktree_not_registered", reuse_record(engine, successor_id).fetch("reason")
    refute_equal predecessor.fetch("workspace_path"), agent(engine, successor_id).fetch("workspace_path")
  end

  # --- rejected contracts -----------------------------------------------------------------------

  def test_reusing_an_unknown_worker_is_rejected_rather_than_silently_ignored
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "reuse_workspace_of_agent_id" => "P1-I1-W9" }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "reuse_workspace_agent_not_found"
    assert_empty @harness_client.spawns
  end

  def test_reusing_a_worker_from_another_issue_is_rejected
    engine = build_engine
    context = project_with_issue(engine)
    other_issue_id = create_issue(engine, "P1", title: "Something else")
    stranger_id = spawn_worker(engine, other_issue_id).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "reuse_workspace_of_agent_id" => stranger_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "reuse_workspace_agent_issue_mismatch"
  end

  def test_share_workspace_needs_a_related_worker_to_share_with
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "share_workspace" => true }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "share_workspace_requires_a_related_worker"
  end

  def test_share_workspace_false_and_an_explicit_reuse_target_cannot_both_be_asked_for
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Go.",
        "reuse_workspace_of_agent_id" => predecessor_id,
        "share_workspace" => false
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "share_workspace_conflicts_with_reuse_workspace_of_agent_id"
  end

  # --- lifecycle --------------------------------------------------------------------------------

  def test_pruning_the_predecessor_keeps_the_shared_worktree_for_the_worker_still_in_it
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")
    shared_path = agent(engine, successor_id).fetch("workspace_path")

    apply!(engine, "Kill", { "target_id" => predecessor_id })
    apply!(engine, "ReconcileSessions", {})

    assert_nil agent(engine, predecessor_id), "the killed record is pruned like any other"
    assert Dir.exist?(shared_path), "the successor is still working in this worktree"
    assert_equal shared_path, agent(engine, successor_id).fetch("workspace_path")
    assert_empty logs_matching(engine, /managed worktree could not be removed/)
  end

  # One branch means one pull request. Two workers sharing a branch must both resolve to the same
  # delivery record rather than each reporting a delivery of its own.
  def test_two_workers_on_one_shared_branch_report_one_delivery_pull_request
    engine = build_engine
    context = project_with_issue(engine)
    run_git(context.fetch("root"), "remote", "set-url", "origin", "https://github.com/acme/demo.git")
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    branch = agent(engine, predecessor_id).fetch("workspace_branch")
    forge = SingleBranchForgeClient.new(branch: branch)
    delivering = build_engine(forge_client: forge)

    delivering.mark_worker_completed(
      agent_id: predecessor_id,
      last_assistant_text: "Opened #{SingleBranchForgeClient::PULL_REQUEST_URL} for review."
    )
    successor_id = spawn_worker(
      delivering,
      context.fetch("issue_id"),
      prompt: "Address the review.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")
    delivering.mark_worker_completed(
      agent_id: successor_id,
      last_assistant_text: "Updated #{SingleBranchForgeClient::PULL_REQUEST_URL} with the fixes."
    )

    assert_equal branch, agent(delivering, successor_id).fetch("workspace_branch")
    delivered = issue(delivering, context.fetch("issue_id")).fetch("delivery_pull_requests")
    assert_equal 1, delivered.length, "one shared branch must not produce two delivery records"
    assert_equal SingleBranchForgeClient::PULL_REQUEST_URL, delivered.fetch(0).fetch("url")
    assert_equal 1, Meringue::TUI::OpenPullRequests.count(state(delivering))
  end

  def test_pruning_the_last_sharer_removes_the_shared_worktree_exactly_once
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = settled_predecessor(engine, context)
    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement it.",
      follow_up_of_agent_id: predecessor_id
    ).fetch("target_id")
    shared_path = agent(engine, successor_id).fetch("workspace_path")
    engine.mark_worker_completed(agent_id: successor_id, last_assistant_text: "Implemented.")

    prune = apply!(engine, "Prune", {})

    assert_equal ["P1-I1"], prune.fetch("result").fetch("removed_issue_ids")
    assert_equal %w[P1-I1-W1 P1-I1-W2], prune.fetch("result").fetch("removed_agent_ids").select { |id| id.include?("-W") }.sort
    refute Dir.exist?(shared_path), "nobody needs the shared worktree any more"
    assert_equal 1, prune.fetch("result").fetch("removed_worktree_agent_ids").length
    assert_empty logs_matching(engine, /managed worktree could not be removed/)
  end
end
