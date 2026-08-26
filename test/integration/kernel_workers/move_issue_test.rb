# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# MoveIssue reparents an issue under another issue, promotes it to the top level,
# or moves it to a different logical project over the same checkout. Descendants
# and their workers travel with it; crossing projects renumbers the subtree while
# leaving harness sessions and checkouts alone.
class KernelWorkersMoveIssueTest < Minitest::Test
  include KernelWorkersSupport

  def setup
    super
    @engine = build_engine
  end

  def move(payload)
    apply_raw(@engine, "MoveIssue", payload)
  end

  def shared_root_projects
    root = create_git_repo("shared-root")
    migration = add_project(@engine, root, name: "Yugabyte migration")
    resiliency = add_project(@engine, root, name: "Resiliency")
    { "root" => root, "migration" => migration, "resiliency" => resiliency }
  end

  # --- reparenting inside one project ----------------------------------------------------

  def test_issue_can_be_reparented_under_another_issue_without_renumbering
    project = add_project(@engine, create_git_repo("reparent"))
    parent = create_issue(@engine, project, title: "Parent")
    child = create_issue(@engine, project, title: "Child")

    result = move("issue_id" => child, "parent_issue_id" => parent)

    assert_equal "accepted", result.fetch("status")
    # Parentage changed; the id did not, so nothing referring to it had to move.
    assert_equal child, result.fetch("target_id")
    assert_equal parent, issue(@engine, child).fetch("parent_issue_id")
    assert_equal project, issue(@engine, child).fetch("project_id")
  end

  def test_a_child_issue_can_be_promoted_to_the_top_level
    project = add_project(@engine, create_git_repo("promote"))
    parent = create_issue(@engine, project, title: "Parent")
    child = apply!(
      @engine, "CreateIssue",
      { "project_id" => project, "title" => "Child", "parent_issue_id" => parent }
    ).fetch("target_id")

    assert_equal parent, issue(@engine, child).fetch("parent_issue_id")
    assert_equal "accepted", move("issue_id" => child, "parent_issue_id" => "").fetch("status")
    assert_nil issue(@engine, child).fetch("parent_issue_id")
  end

  def test_an_issue_cannot_become_a_child_of_its_own_descendant
    project = add_project(@engine, create_git_repo("cycle"))
    parent = create_issue(@engine, project, title: "Parent")
    child = apply!(
      @engine, "CreateIssue",
      { "project_id" => project, "title" => "Child", "parent_issue_id" => parent }
    ).fetch("target_id")

    result = move("issue_id" => parent, "parent_issue_id" => child)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "parent_is_descendant"
    assert_nil issue(@engine, parent).fetch("parent_issue_id")
  end

  # --- moving between logical projects over one checkout ---------------------------------

  def test_issue_moves_between_projects_sharing_a_root_and_renumbers_its_workers
    context = shared_root_projects
    source_issue = create_issue(@engine, context.fetch("migration"), title: "Backfill")
    worker = spawn_worker(@engine, source_issue).fetch("target_id")
    original = agent(@engine, worker)

    result = move("issue_id" => source_issue, "target_project_id" => context.fetch("resiliency"))

    assert_equal "accepted", result.fetch("status")
    moved_issue_id = result.fetch("target_id")
    refute_equal source_issue, moved_issue_id
    assert moved_issue_id.start_with?("#{context.fetch("resiliency")}-I")
    assert_nil issue(@engine, source_issue)
    assert_equal context.fetch("resiliency"), issue(@engine, moved_issue_id).fetch("project_id")

    moved_worker = agent(@engine, "#{moved_issue_id}-W1")
    refute_nil moved_worker
    assert_equal context.fetch("resiliency"), moved_worker.fetch("project_id")
    assert_equal moved_issue_id, moved_worker.fetch("issue_id")
    # Same checkout, so the live session and workspace are untouched.
    assert_equal original.fetch("harness_session_id"), moved_worker.fetch("harness_session_id")
    assert_equal original.fetch("workspace_path"), moved_worker.fetch("workspace_path")
    assert_equal original.fetch("workspace_branch"), moved_worker.fetch("workspace_branch")
    assert_equal(
      original.dig("harness_metadata", "workspace_plan", "workspace_owner_id"),
      moved_worker.dig("harness_metadata", "workspace_plan", "workspace_owner_id")
    )
    assert_nil agent(@engine, worker)
  end

  def test_moving_an_issue_carries_its_children_and_their_workers
    context = shared_root_projects
    parent = create_issue(@engine, context.fetch("migration"), title: "Parent")
    child = apply!(
      @engine, "CreateIssue",
      { "project_id" => context.fetch("migration"), "title" => "Child", "parent_issue_id" => parent }
    ).fetch("target_id")
    spawn_worker(@engine, child)

    result = move("issue_id" => parent, "target_project_id" => context.fetch("resiliency"))
    assert_equal "accepted", result.fetch("status")

    moved_ids = result.fetch("result") && state(@engine).fetch("issues").select do |record|
      record.fetch("project_id") == context.fetch("resiliency")
    end.map { |record| record.fetch("id") }

    assert_equal 2, moved_ids.length
    moved_parent = result.fetch("target_id")
    moved_child = (moved_ids - [moved_parent]).first
    # The child stays a child, repointed to its parent's new id.
    assert_equal moved_parent, issue(@engine, moved_child).fetch("parent_issue_id")
    # The root itself becomes top-level in the project it landed in.
    assert_nil issue(@engine, moved_parent).fetch("parent_issue_id")
    refute_nil agent(@engine, "#{moved_child}-W1")
    assert_empty state(@engine).fetch("issues").select { |r| r.fetch("project_id") == context.fetch("migration") }
  end

  def test_move_across_different_repositories_is_rejected
    first = add_project(@engine, create_git_repo("repo-one"), name: "One")
    second = add_project(@engine, create_git_repo("repo-two"), name: "Two")
    source_issue = create_issue(@engine, first, title: "Stays put")
    spawn_worker(@engine, source_issue)
    before = issue(@engine, source_issue)

    result = move("issue_id" => source_issue, "target_project_id" => second)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "cross_repository_move_unsupported"
    assert_equal before, issue(@engine, source_issue)
  end

  def test_moving_into_the_project_it_already_sits_in_is_rejected
    project = add_project(@engine, create_git_repo("same-project"))
    source_issue = create_issue(@engine, project, title: "Already here")

    result = move("issue_id" => source_issue, "target_project_id" => project)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "already_in_target_location"
  end

  def test_unknown_issue_and_project_are_rejected
    project = add_project(@engine, create_git_repo("unknown"))
    source_issue = create_issue(@engine, project, title: "Real")

    assert_includes move("issue_id" => "P9-I9", "target_project_id" => project).fetch("errors"), "issue_not_found"
    assert_includes move("issue_id" => source_issue, "target_project_id" => "P9").fetch("errors"), "target_project_not_found"
    assert_includes move("issue_id" => source_issue).fetch("errors"), "target_project_id or parent_issue_id is required"
  end

  def test_a_new_issue_after_a_move_does_not_reuse_a_moved_id
    context = shared_root_projects
    source_issue = create_issue(@engine, context.fetch("migration"), title: "Moves away")
    moved = move("issue_id" => source_issue, "target_project_id" => context.fetch("resiliency")).fetch("target_id")

    fresh = create_issue(@engine, context.fetch("resiliency"), title: "Created after")

    refute_equal moved, fresh
    assert_equal 2, state(@engine).fetch("issues").length
  end
end
