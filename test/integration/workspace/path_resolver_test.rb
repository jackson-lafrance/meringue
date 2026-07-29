# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# PathResolver decides where a UI-owned shell/editor starts. Nested
# `.meringue/workspaces/...` paths were caused by resolving relative candidates
# against the process cwd, so these tests pin the base-directory rules too.
class WorkspacePathResolverTest < Minitest::Test
  include WorkspaceSupport

  def test_prefers_the_recorded_workspace_path_when_it_exists
    with_workspace_tmpdir do |tmp|
      worktree = File.join(tmp, "workspaces", "project", "task")
      subdirectory = File.join(worktree, "app")
      FileUtils.mkdir_p(subdirectory)
      agent = worker_agent(workspace_path: subdirectory, plan: { "worktree_root_path" => worktree })

      resolution = Meringue::Workspace::PathResolver.resolve(agent)

      assert_equal subdirectory, resolution.fetch("path")
      assert_equal subdirectory, resolution.fetch("expected_path")
      refute resolution.fetch("recovered")
      refute resolution.key?("message")
      assert_equal subdirectory, Meringue::Workspace::PathResolver.path_for(agent)
    end
  end

  def test_falls_back_to_the_worktree_root_with_a_recovery_message
    with_workspace_tmpdir do |tmp|
      worktree = File.join(tmp, "workspaces", "project", "task")
      FileUtils.mkdir_p(worktree)
      agent = worker_agent(
        workspace_path: File.join(worktree, "deleted-subdirectory"),
        plan: { "workspace_path" => File.join(worktree, "also-gone"), "worktree_root_path" => worktree }
      )

      resolution = Meringue::Workspace::PathResolver.resolve(agent)

      assert_equal worktree, resolution.fetch("path")
      assert_equal File.join(worktree, "deleted-subdirectory"), resolution.fetch("expected_path")
      assert resolution.fetch("recovered")
      assert_equal(
        "Using #{worktree} because the recorded workspace #{File.join(worktree, "deleted-subdirectory")} is missing.",
        resolution.fetch("message")
      )
    end
  end

  def test_relative_candidates_resolve_against_the_recorded_project_root
    with_workspace_tmpdir do |tmp|
      project_root = File.join(tmp, "project")
      nested = File.join(project_root, "packages", "core")
      FileUtils.mkdir_p(nested)
      agent = worker_agent(workspace_path: "packages/core", plan: { "project_root" => project_root })

      Dir.chdir(tmp) do
        resolution = Meringue::Workspace::PathResolver.resolve(agent)

        assert_equal nested, resolution.fetch("path")
        refute resolution.fetch("recovered")
      end
    end
  end

  def test_relative_candidates_never_resolve_against_the_process_working_directory
    with_workspace_tmpdir do |tmp|
      project_root = File.join(tmp, "project")
      elsewhere = File.join(tmp, "elsewhere")
      decoy = File.join(elsewhere, "packages", "core")
      FileUtils.mkdir_p([project_root, decoy])
      agent = worker_agent(workspace_path: "packages/core", plan: { "project_root" => project_root })

      Dir.chdir(elsewhere) do
        resolution = Meringue::Workspace::PathResolver.resolve(agent)

        refute_equal decoy, resolution["path"]
        assert_nil resolution["path"]
        assert_equal File.join(project_root, "packages", "core"), resolution.fetch("expected_path")
      end
    end
  end

  def test_git_root_is_used_as_the_base_when_no_project_root_is_recorded
    with_workspace_tmpdir do |tmp|
      git_root = File.join(tmp, "checkout")
      nested = File.join(git_root, "services", "api")
      FileUtils.mkdir_p(nested)
      agent = worker_agent(workspace_path: "services/api", plan: { "git_root" => git_root })

      assert_equal nested, Meringue::Workspace::PathResolver.path_for(agent)
    end
  end

  def test_tilde_paths_are_expanded_against_home
    with_workspace_tmpdir do |tmp|
      fake_home = File.join(tmp, "home")
      workspace = File.join(fake_home, "worktrees", "task")
      FileUtils.mkdir_p(workspace)
      original_home = ENV["HOME"]
      begin
        ENV["HOME"] = fake_home
        agent = worker_agent(workspace_path: "~/worktrees/task")

        assert_equal workspace, Meringue::Workspace::PathResolver.resolve(agent).fetch("path")
        assert_equal workspace, Meringue::Workspace::PathResolver.resolve("~/worktrees/task").fetch("path")
      ensure
        ENV["HOME"] = original_home
      end
    end
  end

  def test_plain_absolute_string_paths_are_resolved_directly
    with_workspace_tmpdir do |tmp|
      existing = File.join(tmp, "worktree")
      FileUtils.mkdir_p(existing)

      resolution = Meringue::Workspace::PathResolver.resolve(existing)

      assert_equal existing, resolution.fetch("path")
      assert_equal existing, resolution.fetch("expected_path")
      refute resolution.fetch("recovered")
    end
  end

  def test_missing_directory_is_refused_with_an_actionable_message
    with_workspace_tmpdir do |tmp|
      missing = File.join(tmp, "removed-worktree")

      resolution = Meringue::Workspace::PathResolver.resolve(missing)

      assert_nil resolution["path"]
      refute resolution.key?("path")
      assert_equal missing, resolution.fetch("expected_path")
      assert_includes resolution.fetch("message"), "Worker worktree #{missing} is missing."
      assert_includes resolution.fetch("message"), "open the delivery PR instead"
      assert_nil Meringue::Workspace::PathResolver.path_for(missing)
    end
  end

  def test_blank_and_missing_candidates_are_refused_without_an_expected_path
    ["", "   ", nil].each do |value|
      resolution = Meringue::Workspace::PathResolver.resolve(value)

      assert_nil resolution["path"]
      refute resolution.key?("expected_path")
      assert_equal(
        "This worker has no assigned workspace directory, so Meringue cannot open a shell for it.",
        resolution.fetch("message")
      )
    end

    assert_nil Meringue::Workspace::PathResolver.resolve(worker_agent)["path"]
    assert_nil Meringue::Workspace::PathResolver.resolve({})["path"]
  end

  def test_regular_files_are_not_accepted_as_workspaces
    with_workspace_tmpdir do |tmp|
      file = File.join(tmp, "not-a-directory.txt")
      File.write(file, "x")

      resolution = Meringue::Workspace::PathResolver.resolve(worker_agent(workspace_path: file))

      assert_nil resolution["path"]
      assert_equal file, resolution.fetch("expected_path")
    end
  end

  # Current behavior: a null byte escapes as ArgumentError instead of being
  # reported as an unusable destination. Recorded in test/findings/workspace.md.
  def test_null_byte_paths_raise_argument_error_today
    error = assert_raises(ArgumentError) do
      Meringue::Workspace::PathResolver.resolve("/tmp/bad\u0000path")
    end

    assert_match(/null byte/, error.message)
  end
end
