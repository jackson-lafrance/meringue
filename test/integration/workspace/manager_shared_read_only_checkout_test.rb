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
