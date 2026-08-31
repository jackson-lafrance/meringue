# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# What a worker is allowed to run in. A worker's workspace must be one a version-control
# backend provisioned and can prove is isolated from the project root; every other
# outcome the resolver used to offer — the project root itself, a directory the caller
# named — is now a refusal rather than a fallback.
#
# The engine is driven with a throwaway state file and a throwaway workspaces root;
# nothing under ~/.meringue is read or written.
class WorkspaceStrategySelectionTest < Minitest::Test
  include WorkspaceSupport

  ISOLATED_PROJECT_CAPABILITIES = { "isolated_workspaces" => true, "mutable_workspace" => true }.freeze

  def test_a_project_without_isolation_evidence_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)

      resolved = resolve(tmp, project_root: project.fetch("project_root"), requested_workspace_path: nil, capabilities: {})

      assert_equal "unavailable", resolved.fetch("workspace_strategy")
      assert_nil resolved.fetch("workspace_path")
      assert_equal ["version_control_backend_unavailable"], resolved.fetch("errors")
      assert_equal "version_control_backend_unavailable", resolved.fetch("failure_kind")
    end
  end

  # A directory the caller points at carries no isolation evidence, so it is refused
  # whether or not it exists, and whether or not it is the project root.
  def test_a_requested_directory_is_refused_because_no_backend_provisioned_it
    with_workspace_tmpdir do |tmp|
      dedicated = File.join(tmp, "dedicated-workspace")
      FileUtils.mkdir_p(dedicated)

      %W[#{dedicated} #{File.join(tmp, "project")} #{File.join(tmp, "not-created-yet")}].each do |requested|
        resolved = resolve(tmp, requested_workspace_path: requested)

        assert_equal "unvalidated", resolved.fetch("workspace_strategy"), requested
        assert_equal ["version_control_backend_required"], resolved.fetch("errors"), requested
      end

      refute Dir.exist?(File.join(tmp, "not-created-yet")), "resolution must not create directories"
    end
  end

  # A reservation names the worktree the backend will create and provisions it later.
  # Nothing is on disk yet, and that is not a failure: treating an uncreated plan as one
  # is what made every SpawnWorker reservation report "Worker workspace is invalid".
  def test_a_preview_reserves_the_planned_worktree_without_creating_it
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)

      resolved = resolve(tmp, project_root: project.fetch("project_root"), requested_workspace_path: nil)

      assert_equal "git_worktree", resolved.fetch("workspace_strategy")
      assert_equal [], resolved.fetch("errors")
      refute resolved.fetch("created")
      assert_equal "Version-control backend planned an isolated workspace for this worker.", resolved.fetch("note")
      assert_match(/\A[a-z0-9][a-z0-9-]*\z/, resolved.fetch("workspace_branch"))
      assert_equal resolved.dig("plan", "workspace_path"), resolved.fetch("workspace_path")
      refute_equal real_path(project.fetch("project_root")), resolved.fetch("workspace_path")
      refute Dir.exist?(resolved.fetch("workspace_path")), "a preview must not create the worktree"
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
      assert_match(/\A[a-z0-9][a-z0-9-]*\z/, resolved.fetch("workspace_branch"))
    end
  end

  # A project root that is not a repository cannot host an isolated worktree. There is no
  # fallback to running in it; the allocation fails and says why.
  def test_creation_outside_a_git_repository_fails_instead_of_using_the_project_root
    with_workspace_tmpdir do |tmp|
      resolved = resolve(tmp, requested_workspace_path: nil, create: true)

      refute resolved.fetch("created")
      assert_includes resolved.fetch("errors").join(" "), "project root is not inside a git repository"
      assert_equal "version_control_backend_unavailable", resolved.fetch("failure_kind")
    end
  end

  def test_worktree_allocation_errors_are_surfaced_with_their_recovery
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      engine = build_engine(tmp, manager: WorkspaceSupport::TimingOutManager.new(root_path: File.join(tmp, "workspaces")))

      resolved = engine.send(
        :resolve_worker_workspace,
        project: isolated_project(project.fetch("project_root")),
        issue: { "id" => "P1-I1" },
        requested_workspace_path: nil,
        preview_agent_id: "P1-I1-W1",
        task_title: "Timing out allocation",
        create: true
      )

      assert_equal "git_worktree", resolved.fetch("workspace_strategy")
      refute resolved.fetch("created")
      assert_includes resolved.fetch("errors").join(" "), "git worktree add timed out"
    end
  end

  def test_missing_project_root_is_reported_as_an_error
    with_workspace_tmpdir do |tmp|
      resolved = resolve(tmp, project_root: File.join(tmp, "never-created"), requested_workspace_path: nil, create: true)

      refute resolved.fetch("created")
      refute_empty resolved.fetch("errors")
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

  # The project record as registration writes it: the backend's isolation evidence is on
  # the project, and the resolver reads it from there rather than re-probing.
  def isolated_project(root_path, capabilities: ISOLATED_PROJECT_CAPABILITIES)
    {
      "id" => "P1",
      "root_path" => root_path,
      "version_control_backend" => "github_git",
      "version_control_capabilities" => capabilities
    }
  end

  def resolve(tmp, requested_workspace_path:, project_root: nil, create: false, capabilities: ISOLATED_PROJECT_CAPABILITIES)
    root = project_root || File.join(tmp, "project")
    FileUtils.mkdir_p(root) if project_root.nil?

    build_engine(tmp).send(
      :resolve_worker_workspace,
      project: isolated_project(root, capabilities: capabilities),
      issue: { "id" => "P1-I1" },
      requested_workspace_path: requested_workspace_path,
      preview_agent_id: "P1-I1-W1",
      task_title: "Strategy selection",
      create: create
    )
  end
end
