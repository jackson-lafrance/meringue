# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

class WorkspaceManagerSharedReadOnlyCheckoutTest < Minitest::Test
  include WorkspaceSupport

  def test_resolves_existing_main_checkout_without_creating_a_worktree
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal "shared_checkout", workspace.fetch("strategy")
      assert_equal real_path(project.fetch("project_root")), workspace.fetch("workspace_path")
      assert_equal "main", workspace.fetch("workspace_branch")
      assert_equal false, workspace.fetch("created")
      assert_equal true, workspace.fetch("read_only")
      assert manager.validate_worker_workspace(workspace).fetch("usable")
      refute Dir.exist?(File.join(tmp, "workspaces")), "discovery must not provision anything"
    end
  end

  def test_bare_registered_root_uses_an_existing_linked_main_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      shared_main = File.join(tmp, "world-main")
      run_git!(project.fetch("origin_path"), "worktree", "add", shared_main, "main", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))

      assert_equal "shared_checkout", workspace.fetch("strategy")
      assert_equal real_path(shared_main), workspace.fetch("workspace_path")
      assert_equal real_path(project.fetch("origin_path")), workspace.fetch("git_root")
      assert_equal "false", git_output(project, shared_main, "rev-parse", "--is-bare-repository").strip
      assert manager.validate_worker_workspace(workspace).fetch("usable")
    end
  end

  def test_bare_registered_root_without_linked_main_checkout_creates_and_reuses_managed_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      first = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))
      second = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))

      assert_equal "shared_checkout", first.fetch("strategy")
      assert_equal true, first.fetch("created")
      assert_equal true, first.fetch("managed_shared_checkout")
      assert_equal "main", first.fetch("workspace_branch")
      assert_equal real_path(first.fetch("workspace_path")), real_path(second.fetch("workspace_path"))
      assert_equal false, second.fetch("created"), "the second reader reuses the completed checkout"
      assert_equal "false", git_output(project, first.fetch("workspace_path"), "rev-parse", "--is-bare-repository").strip
      assert manager.validate_worker_workspace(first).fetch("usable")
      assert manager.validate_worker_workspace(second).fetch("usable")
    end
  end

  def test_concurrent_readers_serialize_managed_checkout_creation
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      outcomes = threads.map(&:value)

      assert outcomes.all? { |outcome| outcome.fetch("strategy", nil) == "shared_checkout" }
      assert_equal 1, outcomes.count { |outcome| outcome.fetch("created") }
      assert_equal 1, outcomes.map { |outcome| real_path(outcome.fetch("workspace_path")) }.uniq.length
    end
  end

  def test_managed_checkout_recovers_an_owned_stale_registration
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))
      checkout = first.fetch("workspace_path")
      FileUtils.rm_rf(checkout)

      recovered = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))

      assert_equal "shared_checkout", recovered.fetch("strategy")
      assert_equal true, recovered.fetch("managed_shared_checkout")
      assert Dir.exist?(recovered.fetch("workspace_path"))
      assert manager.validate_worker_workspace(recovered).fetch("usable")
    end
  end

  def test_dirty_managed_checkout_is_preserved_and_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))
      readme = File.join(first.fetch("workspace_path"), "README.md")
      File.write(readme, "unexpected change\n")

      outcome = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))

      assert_equal false, outcome.fetch("usable")
      assert_equal "managed_shared_checkout_dirty", outcome.fetch("reason")
      assert_equal "unexpected change\n", File.read(readme), "recovery must never delete a dirty completed cache"
    end
  end

  def test_dirty_main_checkout_is_not_shared
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      File.write(File.join(project.fetch("project_root"), "README.md"), "dirty\n")
      manager = workspace_manager(tmp)

      outcome = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal false, outcome.fetch("usable")
      assert_equal "shared_checkout_dirty", outcome.fetch("reason")
    end
  end

  def test_clean_feature_branch_at_a_mainline_commit_is_shared_as_a_mainline_snapshot
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "-c", "feature", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal "shared_checkout", workspace.fetch("strategy")
      assert_equal real_path(project.fetch("project_root")), workspace.fetch("workspace_path")
      assert_equal "feature", workspace.fetch("workspace_branch")
      assert_equal "mainline_snapshot", workspace.fetch("shared_checkout_selection")
      assert_equal true, workspace.fetch("read_only")
      assert manager.validate_worker_workspace(workspace).fetch("usable")
      refute Dir.exist?(File.join(tmp, "workspaces")), "a clean branch checkout is shared, not replaced by a new worktree"
    end
  end

  def test_clean_feature_branch_with_its_own_commits_is_shared_as_another_branch
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "-c", "feature", env: project.fetch("git_env"))
      advance_local_main(project)
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal "shared_checkout", workspace.fetch("strategy")
      assert_equal "feature", workspace.fetch("workspace_branch")
      assert_equal "other_branch", workspace.fetch("shared_checkout_selection")
      assert manager.validate_worker_workspace(workspace).fetch("usable")
    end
  end

  def test_main_checkout_is_preferred_over_a_clean_feature_branch_checkout_listed_first
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "-c", "feature", env: project.fetch("git_env"))
      linked_main = File.join(tmp, "linked-main")
      run_git!(project.fetch("project_root"), "worktree", "add", linked_main, "main", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal real_path(linked_main), workspace.fetch("workspace_path")
      assert_equal "main", workspace.fetch("workspace_branch")
      assert_equal "main_branch", workspace.fetch("shared_checkout_selection")
    end
  end

  def test_mainline_snapshot_is_preferred_over_a_branch_with_its_own_commits_listed_first
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "-c", "feature", env: project.fetch("git_env"))
      advance_local_main(project)
      stale = File.join(tmp, "stale-branch")
      run_git!(project.fetch("project_root"), "worktree", "add", "-b", "stale", stale, "origin/main", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal real_path(stale), workspace.fetch("workspace_path")
      assert_equal "stale", workspace.fetch("workspace_branch")
      assert_equal "mainline_snapshot", workspace.fetch("shared_checkout_selection")
    end
  end

  def test_dirty_main_checkout_falls_back_to_a_clean_feature_branch_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      File.write(File.join(project.fetch("project_root"), "README.md"), "dirty\n")
      feature = File.join(tmp, "feature-checkout")
      run_git!(project.fetch("project_root"), "worktree", "add", "-b", "feature", feature, "main", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal "shared_checkout", workspace.fetch("strategy")
      assert_equal real_path(feature), workspace.fetch("workspace_path")
      assert_equal "feature", workspace.fetch("workspace_branch")
      assert_equal "dirty\n", File.read(File.join(project.fetch("project_root"), "README.md")), "the dirty checkout is left alone"
    end
  end

  def test_bare_registered_root_uses_a_clean_linked_feature_checkout_instead_of_creating_a_managed_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      feature = File.join(tmp, "world-feature")
      run_git!(project.fetch("origin_path"), "worktree", "add", "-b", "feature", feature, "main", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      workspace = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))

      assert_equal "shared_checkout", workspace.fetch("strategy")
      assert_equal real_path(feature), workspace.fetch("workspace_path")
      assert_equal "feature", workspace.fetch("workspace_branch")
      assert_equal false, workspace.fetch("created")
      assert_equal false, workspace.fetch("managed_shared_checkout")
      assert manager.validate_worker_workspace(workspace).fetch("usable")
      refute Dir.exist?(File.join(tmp, "workspaces")), "an existing clean checkout is reused before a managed one is created"
    end
  end

  def test_detached_checkout_is_not_shared
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "--detach", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      outcome = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal false, outcome.fetch("usable")
      assert_equal "no_readable_checkout", outcome.fetch("reason")
    end
  end

  def test_shared_checkout_that_switched_branch_after_selection_fails_validation
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "-c", "feature", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)
      workspace = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))
      assert_equal "feature", workspace.fetch("workspace_branch")

      run_git!(project.fetch("project_root"), "switch", "main", env: project.fetch("git_env"))
      validation = manager.validate_worker_workspace(workspace)

      assert_equal false, validation.fetch("usable")
      assert_equal "shared_checkout_branch_moved", validation.fetch("reason")
    end
  end
end
