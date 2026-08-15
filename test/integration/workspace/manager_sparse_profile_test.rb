# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Project-native sparse provisioning profiles.
#
# A project may declare a sparse provisioning profile at
# `.meringue/workspace-profile.toml` so Meringue checks out only the working
# set the project's own tooling expects, using repository-approved patterns
# rather than model-inferred path narrowing. A project without a declared
# profile keeps the current full-checkout behavior unchanged.
class WorkspaceManagerSparseProfileTest < Minitest::Test
  include WorkspaceSupport

  def test_project_without_profile_keeps_full_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Full checkout")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      refute workspace.key?("sparse_checkout")
      refute workspace.key?("profile_validation")
      contents = Dir.children(workspace.fetch("workspace_path")) - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "tests"
      assert_includes contents, "config"
      assert_includes contents, "build"
    end
  end

  def test_sparse_profile_materializes_only_declared_patterns
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_cone = true
        sparse_patterns = ["/src/", "/docs/"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Sparse slice")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      # Cone mode always includes root-level files (README.md); the sparse set
      # adds src/ and docs/ while excluding tests/ and config/.
      assert_includes contents, "src"
      assert_includes contents, "docs"
      refute_includes contents, "tests"
      refute_includes contents, "config"
      refute_includes contents, "build"
      assert_path_exists File.join(workspace.fetch("workspace_path"), "src", "file.txt")
    end
  end

  def test_sparse_profile_records_profile_and_materialized_count_on_plan
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_cone = true
        sparse_patterns = ["/src/"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Persisted profile")

      sparse = workspace.fetch("sparse_checkout")
      assert_equal "profile", sparse.fetch("profile")
      assert_equal true, sparse.fetch("cone")
      assert_equal ["/src/"], sparse.fetch("patterns")
      assert sparse.fetch("materialized_files") >= 1

      profile_meta = workspace.fetch("workspace_profile")
      assert_equal "profile", profile_meta.fetch("name")
      assert_equal ["/src/"], profile_meta.fetch("sparse_patterns")
      assert_equal "profile (sparse, cone, 1 patterns)", profile_meta.fetch("summary")
    end
  end

  def test_per_worktree_sparse_config_does_not_mutate_shared_repository_config
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_cone = false
        sparse_patterns = ["/src/"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Isolated sparse")

      # Sparse settings live on the worktree, not the shared repository config.
      # `git config --get` exits 1 when the key is absent, so read it tolerantly.
      shared_env = project.fetch("git_env")
      _out, _err, shared_status = Open3.capture3(
        shared_env, "git", "-C", project.fetch("project_root"), "config", "--get", "core.sparseCheckout"
      )
      refute shared_status.success?, "shared repository config must not carry core.sparseCheckout"
      worktree_setting = git_output(project, workspace.fetch("workspace_path"), "config", "--get", "core.sparseCheckout").strip
      assert_equal "true", worktree_setting
      # Non-cone profile: core.sparseCheckoutCone is intentionally not set.
      _cout, _cerr, cone_status = Open3.capture3(
        shared_env, "git", "-C", workspace.fetch("workspace_path"), "config", "--get", "core.sparseCheckoutCone"
      )
      refute cone_status.success?, "non-cone profile must not set core.sparseCheckoutCone"
    end
  end

  def test_path_template_lays_out_worktree_at_project_declared_location
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        path_template = "{{root}}/checkouts/{{project}}/{{task}}-{{suffix}}"
        sparse_patterns = ["/src/"]
        sparse_cone = true
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Template layout")

      assert workspace.fetch("created")
      path = workspace.fetch("workspace_path")
      assert path.start_with?(File.join(tmp, "workspaces", "checkouts", "project"))
      assert Dir.exist?(path)
      assert_path_exists File.join(path, "src", "file.txt")
    end
  end

  def test_unsafe_path_template_falls_back_to_default_layout
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        path_template = "{{root}}/../../escape/{{task}}"
        sparse_patterns = ["/src/"]
        sparse_cone = true
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Escape attempt")

      assert workspace.fetch("created")
      # The unsafe template is rejected, so the worktree stays under the
      # managed root with the default layout.
      assert workspace.fetch("workspace_path").start_with?(File.join(tmp, "workspaces", "project"))
    end
  end

  def test_post_provision_validation_success_records_result
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_patterns = ["/src/"]
        sparse_cone = true
        validation_command = ["ruby", "-e", "exit 0"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Validated checkout")

      validation = workspace.fetch("profile_validation")
      assert validation.fetch("success")
      assert_equal 0, validation.fetch("exit_status")
      assert validation.key?("duration_seconds")
    end
  end

  def test_post_provision_validation_failure_fails_provisioning
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_patterns = ["/src/"]
        sparse_cone = true
        validation_command = ["ruby", "-e", "exit 3"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Rejected checkout")

      refute workspace.fetch("created")
      assert workspace.fetch("errors").any? { |error| error.include?("profile validation command failed") }
      assert_equal "validation_failed", workspace.fetch("failure_kind")
      # A failed validation must not leave a half-provisioned worktree behind.
      refute Dir.exist?(workspace.fetch("workspace_path"))
    end
  end

  def test_profile_is_loaded_from_project_root_without_explicit_profile_kwarg
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_patterns = ["/docs/"]
        sparse_cone = true
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Auto loaded")

      assert workspace.fetch("created")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "docs"
      refute_includes contents, "src"
      refute_includes contents, "tests"
    end
  end

  def test_malformed_profile_file_falls_back_to_full_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, "this is not = valid = toml [[[")
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Broken profile")

      assert_equal [], workspace.fetch("errors")
      refute workspace.key?("sparse_checkout")
      contents = Dir.children(workspace.fetch("workspace_path")) - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "tests"
    end
  end

  def test_multiple_profiles_select_default
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        default_profile = "narrow"

        [profiles.narrow]
        sparse_cone = true
        sparse_patterns = ["/src/"]

        [profiles.wide]
        sparse_cone = true
        sparse_patterns = ["/src/", "/docs/", "/tests/"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Default selection")

      assert workspace.fetch("created")
      assert_equal "narrow", workspace.dig("workspace_profile", "name")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      refute_includes contents, "docs"
      refute_includes contents, "tests"
    end
  end

  def test_sparse_worktree_passes_launch_validation
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      write_workspace_profile(project, <<~TOML)
        [profile]
        sparse_cone = true
        sparse_patterns = ["/src/", "/docs/"]
        validation_command = ["ruby", "-e", "exit 0"]
      TOML
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Launch ready")
      validation = manager.validate_worker_workspace(workspace, agent_id: "P1-I1-W1")

      assert validation.fetch("usable"), validation.inspect
    end
  end

  def test_bare_repository_source_supports_sparse_profile
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      # The profile is declared at the registered (non-bare) root, but
      # provisioning runs from the bare origin. Meringue resolves the profile
      # from the project_root argument.
      profile = Meringue::Workspace::Profile.new(
        name: "bare-core",
        sparse_cone: true,
        sparse_patterns: ["/src/"]
      )
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(
        manager,
        project,
        task_title: "Bare sparse",
        project_root: project.fetch("origin_path"),
        profile: profile
      )

      assert workspace.fetch("created")
      assert_equal "git_worktree", workspace.fetch("strategy")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      refute_includes contents, "docs"
      refute_includes contents, "tests"
      validation = manager.validate_worker_workspace(workspace, agent_id: "P1-I1-W1")
      assert validation.fetch("usable"), validation.inspect
    end
  end
end
