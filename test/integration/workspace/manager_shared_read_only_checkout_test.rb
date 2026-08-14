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

  def test_bare_registered_root_without_linked_main_checkout_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      outcome = manager.shared_read_only_checkout(project_root: project.fetch("origin_path"))

      assert_equal false, outcome.fetch("usable")
      assert_equal "bare_repository_has_no_shared_main_checkout", outcome.fetch("reason")
    end
  end

  def test_feature_branch_checkout_is_not_treated_as_shared_main
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      run_git!(project.fetch("project_root"), "switch", "-c", "feature", env: project.fetch("git_env"))
      manager = workspace_manager(tmp)

      outcome = manager.shared_read_only_checkout(project_root: project.fetch("project_root"))

      assert_equal false, outcome.fetch("usable")
      assert_equal "no_readable_main_checkout", outcome.fetch("reason")
    end
  end
end
