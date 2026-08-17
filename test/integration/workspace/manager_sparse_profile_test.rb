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

  # ---------------------------------------------------------------------
  # Synthetic large-bare default profile
  #
  # A bare source with no declared profile and a packed object count above the
  # configured threshold gets a generic root-only cone sparse profile so an
  # isolated writable worker does not materialize the whole tree. The synthetic
  # profile carries no project-specific paths: `/*` is cone-mode for root-level
  # files only. Below the threshold, for non-bare sources, when a profile is
  # declared, and when the operator opts into full checkout, the legacy full
  # checkout is preserved.
  # ---------------------------------------------------------------------

  def allocate_bare_workspace(manager, project, task_title:, **options)
    allocate_workspace(
      manager,
      project,
      task_title: task_title,
      project_root: project.fetch("origin_path"),
      **options
    )
  end

  def test_large_bare_source_without_profile_defaults_to_root_only_sparse
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      workspace = allocate_bare_workspace(manager, project, task_title: "Bare default")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      assert_equal "git_worktree", workspace.fetch("strategy")

      profile_meta = workspace.fetch("workspace_profile")
      assert_equal "bare-default-root", profile_meta.fetch("name")
      assert_equal ["/*", "!/*/"], profile_meta.fetch("sparse_patterns")
      assert_equal false, profile_meta.fetch("sparse_cone")

      sparse = workspace.fetch("sparse_checkout")
      assert_equal "bare-default-root", sparse.fetch("profile")
      assert_equal false, sparse.fetch("cone")
      assert_equal ["/*", "!/*/"], sparse.fetch("patterns")

      path = workspace.fetch("workspace_path")
      contents = Dir.children(path).sort - [".git"]
      # Root-files-only materializes root-level files (README.md) and skips every
      # subdirectory until the worker expands its working set.
      assert_includes contents, "README.md"
      refute_includes contents, "src"
      refute_includes contents, "docs"
      refute_includes contents, "tests"
      assert_path_exists File.join(path, "README.md")
      refute_path_exists File.join(path, "src")

      # Per-worktree sparse config is active (non-cone) and the bare-sourced
      # worktree is non-bare, while the shared repository config stays untouched.
      worktree_setting = git_output(project, path, "config", "--get", "core.sparseCheckout").strip
      assert_equal "true", worktree_setting
      bare_setting = git_output(project, path, "config", "--get", "core.bare").strip
      assert_equal "false", bare_setting
      _out, _err, cone_status = Open3.capture3(
        project.fetch("git_env"), "git", "-C", path, "config", "--get", "core.sparseCheckoutCone"
      )
      refute cone_status.success?, "non-cone synthetic default must not set core.sparseCheckoutCone"
      _out, _err, shared_status = Open3.capture3(
        project.fetch("git_env"), "git", "-C", project.fetch("origin_path"),
        "config", "--get", "core.sparseCheckout"
      )
      refute shared_status.success?, "shared bare repository config must not carry core.sparseCheckout"
    end
  end

  def test_large_bare_default_workspace_passes_launch_validation
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      workspace = allocate_bare_workspace(manager, project, task_title: "Validatable bare default")
      validation = manager.validate_worker_workspace(workspace, agent_id: "P1-I1-W1")

      assert validation.fetch("usable"), validation.inspect
    end
  end

  def test_large_bare_default_is_deterministic_across_plan_and_allocate
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      plan = manager.plan_worker_workspace(
        project_root: project.fetch("origin_path"),
        project_id: "P1",
        issue_id: "P1-I1",
        agent_id: "P1-I1-W1",
        task_title: "Deterministic plan"
      )
      plan_profile = plan.fetch("workspace_profile")
      assert_equal "bare-default-root", plan_profile.fetch("name")
      assert_equal ["/*", "!/*/"], plan_profile.fetch("sparse_patterns")

      workspace = allocate_bare_workspace(manager, project, task_title: "Deterministic plan")
      allocated_profile = workspace.fetch("workspace_profile")
      assert_equal plan_profile, allocated_profile
    end
  end

  def test_small_bare_source_without_profile_keeps_full_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      # Threshold above the small test repo's object count so the synthetic
      # default never engages.
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 10_000_000)

      workspace = allocate_bare_workspace(manager, project, task_title: "Small bare full")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      refute workspace.key?("sparse_checkout")
      refute workspace.key?("workspace_profile")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "tests"
      assert_includes contents, "README.md"
    end
  end

  def test_non_bare_source_above_threshold_keeps_full_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      # project_root is the non-bare working clone, not the bare origin.
      workspace = allocate_workspace(manager, project, task_title: "Non bare full")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      refute workspace.key?("sparse_checkout")
      refute workspace.key?("workspace_profile")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "tests"
    end
  end

  def test_declared_sparse_profile_wins_over_synthetic_bare_default
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      declared = Meringue::Workspace::Profile.new(
        name: "core",
        sparse_cone: true,
        sparse_patterns: ["/src/", "/docs/"]
      )
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      workspace = allocate_bare_workspace(manager, project, task_title: "Declared wins", profile: declared)

      assert workspace.fetch("created")
      assert_equal "core", workspace.dig("workspace_profile", "name")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "docs"
      refute_includes contents, "tests"
    end
  end

  def test_declared_full_checkout_profile_wins_over_synthetic_bare_default
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      declared = Meringue::Workspace::Profile.new(name: "full")
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      workspace = allocate_bare_workspace(manager, project, task_title: "Declared full wins", profile: declared)

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      assert_equal "full", workspace.dig("workspace_profile", "name")
      refute workspace.key?("sparse_checkout")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "tests"
    end
  end

  def test_operator_full_checkout_opt_out_keeps_full_checkout_on_large_bare
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1, default_bare_checkout_mode: "full")

      workspace = allocate_bare_workspace(manager, project, task_title: "Opted out full")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created")
      refute workspace.key?("sparse_checkout")
      refute workspace.key?("workspace_profile")
      contents = Dir.children(workspace.fetch("workspace_path")).sort - [".git"]
      assert_includes contents, "src"
      assert_includes contents, "tests"
    end
  end

  def test_synthetic_bare_default_preserves_collision_and_branch_reuse
    with_workspace_tmpdir do |tmp|
      project = create_git_project_with_dirs(tmp)
      manager = workspace_manager(tmp, bare_sparse_object_threshold: 1)

      first = allocate_bare_workspace(manager, project, task_title: "Collision reuse", agent_id: "P1-I1-W1")
      assert first.fetch("created")
      first_path = first.fetch("workspace_path")

      # A second worker on the same large bare source must provision into its
      # own distinct worktree without disturbing the first: ownership and
      # collision handling are preserved under the synthetic sparse default.
      second = allocate_bare_workspace(manager, project, task_title: "Collision reuse", agent_id: "P1-I1-W2")
      assert second.fetch("created")
      refute_equal first_path, second.fetch("workspace_path")
      assert Dir.exist?(first_path)
      assert Dir.exist?(second.fetch("workspace_path"))

      first_validation = manager.validate_worker_workspace(first, agent_id: "P1-I1-W1")
      second_validation = manager.validate_worker_workspace(second, agent_id: "P1-I1-W2")
      assert first_validation.fetch("usable"), first_validation.inspect
      assert second_validation.fetch("usable"), second_validation.inspect

      released = manager.release_worker_workspace(first, delete_branch: true)
      assert released, "release_worker_workspace should return true for an owned synthetic sparse worktree"
      refute Dir.exist?(first_path)
    end
  end
end
