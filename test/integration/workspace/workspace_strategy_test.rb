# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Workspace strategy selection: git_worktree when the manager can allocate one,
# project_root/dedicated_directory when it cannot or when an explicit directory
# was requested. The engine is driven with a throwaway state file and a
# throwaway workspaces root; nothing under ~/.meringue is read or written.
class WorkspaceStrategySelectionTest < Minitest::Test
  include WorkspaceSupport

  def test_requested_directory_outside_the_project_is_a_dedicated_directory
    with_workspace_tmpdir do |tmp|
      dedicated = File.join(tmp, "dedicated-workspace")
      FileUtils.mkdir_p(dedicated)

      resolved = resolve(tmp, requested_workspace_path: dedicated)

      assert_equal "dedicated_directory", resolved.fetch("workspace_strategy")
      assert_equal dedicated, resolved.fetch("workspace_path")
      assert_nil resolved.fetch("workspace_branch")
      assert_nil resolved.fetch("plan")
      assert_equal [], resolved.fetch("errors")
    end
  end

  def test_requested_project_root_is_the_project_root_strategy
    with_workspace_tmpdir do |tmp|
      resolved = resolve(tmp, requested_workspace_path: File.join(tmp, "project"))

      assert_equal "project_root", resolved.fetch("workspace_strategy")
      assert_equal File.join(tmp, "project"), resolved.fetch("workspace_path")
      assert_equal [], resolved.fetch("errors")
    end
  end

  def test_requested_directory_that_does_not_exist_records_an_error
    with_workspace_tmpdir do |tmp|
      missing = File.join(tmp, "not-created-yet")

      resolved = resolve(tmp, requested_workspace_path: missing)

      assert_equal "dedicated_directory", resolved.fetch("workspace_strategy")
      assert_equal ["workspace_path must be an existing directory"], resolved.fetch("errors")
      refute Dir.exist?(missing), "resolution must not create directories"
    end
  end

  def test_preview_without_creation_keeps_the_project_root_cwd_and_reports_the_plan
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)

      resolved = resolve(tmp, project_root: project.fetch("project_root"), requested_workspace_path: nil)

      assert_equal "project_root", resolved.fetch("workspace_strategy")
      assert_equal project.fetch("project_root"), resolved.fetch("workspace_path")
      refute resolved.fetch("created")
      assert_equal "Workspace manager planned a git worktree for this worker.", resolved.fetch("note")
      assert_equal "git_worktree", resolved.dig("plan", "strategy")
      assert_match(/\A[a-z0-9-]+-[0-9a-f]{8}\z/, resolved.dig("plan", "workspace_branch"))
      refute Dir.exist?(resolved.dig("plan", "workspace_path"))
    end
  end

  def test_creation_in_a_git_repository_uses_the_allocated_worktree
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)

      resolved = resolve(tmp, project_root: project.fetch("project_root"), requested_workspace_path: nil, create: true)

      assert_equal "git_worktree", resolved.fetch("workspace_strategy")
      assert resolved.fetch("created")
      assert_equal [], resolved.fetch("errors")
      assert_nil resolved.fetch("note")
      assert Dir.exist?(resolved.fetch("workspace_path"))
      assert_equal resolved.dig("plan", "workspace_path"), resolved.fetch("workspace_path")
      assert_match(/\A[a-z0-9-]+-[0-9a-f]{8}\z/, resolved.fetch("workspace_branch"))
    end
  end

  def test_creation_outside_a_git_repository_falls_back_to_the_project_root
    with_workspace_tmpdir do |tmp|
      resolved = resolve(tmp, requested_workspace_path: nil, create: true)

      assert_equal "project_root", resolved.fetch("workspace_strategy")
      assert_equal real_path(File.join(tmp, "project")), resolved.fetch("workspace_path")
      refute resolved.fetch("created")
      assert_equal "project root is not inside a git repository", resolved.fetch("note")
      assert_equal [], resolved.fetch("errors")
    end
  end

  def test_worktree_allocation_errors_are_surfaced_with_the_project_root_fallback
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      engine = build_engine(tmp, manager: WorkspaceSupport::TimingOutManager.new(root_path: File.join(tmp, "workspaces")))

      resolved = engine.send(
        :resolve_worker_workspace,
        project: { "id" => "P1", "root_path" => project.fetch("project_root") },
        issue: { "id" => "P1-I1" },
        requested_workspace_path: nil,
        preview_agent_id: "P1-I1-W1",
        task_title: "Timing out allocation",
        create: true
      )

      assert_equal File.join(tmp, "project"), resolved.fetch("workspace_path")
      assert_equal "git_worktree", resolved.fetch("workspace_strategy")
      refute resolved.fetch("created")
      assert_includes resolved.fetch("errors").join(" "), "git worktree add timed out"
    end
  end

  def test_missing_project_root_is_reported_as_an_error
    with_workspace_tmpdir do |tmp|
      resolved = resolve(tmp, project_root: File.join(tmp, "never-created"), requested_workspace_path: nil, create: true)

      assert_equal "project_root", resolved.fetch("workspace_strategy")
      assert_equal ["project root must be an existing directory"], resolved.fetch("errors")
    end
  end

  private

  def build_engine(tmp, manager: nil)
    Meringue::Kernel::Engine.new(
      store: Meringue::State::Store.new(path: File.join(tmp, "state.json")),
      workspace_manager: manager || workspace_manager(tmp),
      cwd: tmp,
      config_path: File.join(tmp, "config.toml")
    )
  end

  def resolve(tmp, requested_workspace_path:, project_root: nil, create: false)
    root = project_root || File.join(tmp, "project")
    FileUtils.mkdir_p(root) if project_root.nil?

    build_engine(tmp).send(
      :resolve_worker_workspace,
      project: { "id" => "P1", "root_path" => root },
      issue: { "id" => "P1-I1" },
      requested_workspace_path: requested_workspace_path,
      preview_agent_id: "P1-I1-W1",
      task_title: "Strategy selection",
      create: create
    )
  end
end
