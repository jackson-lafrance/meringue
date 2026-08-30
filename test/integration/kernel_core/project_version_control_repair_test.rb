# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# Isolated-workspace evidence became mandatory after projects were already being
# registered without it, and the allocation gate refuses any project that lacks it.
# Re-registering the path is the repair the gate's own note points at, so these
# cover that it actually repairs rather than reporting "already registered".
class KernelCoreProjectVersionControlRepairTest < Minitest::Test
  include KernelCoreSupport

  VERSION_CONTROL_KEYS = %w[
    version_control_backend version_control_capabilities
    version_control_diagnostic_at version_control_repository_identity
  ].freeze

  def test_a_head_re_registering_the_path_backfills_a_missing_capability_block
    path = add_legacy_project!

    result = apply_command("AddProject", "path" => path, "_head_id" => head_id!)

    assert_accepted(result)
    assert_equal "P1", result.fetch("target_id")
    repaired = persisted_project("P1")
    assert_equal true, repaired.fetch("version_control_capabilities").fetch("isolated_workspaces")
    assert_equal "github_git", repaired.fetch("version_control_backend")
    refute_nil repaired.fetch("version_control_diagnostic_at")
  end

  def test_a_repaired_project_can_spawn_an_isolated_worker
    path = add_legacy_project!
    create_issue!("P1", title: "Ship it")

    rejected = apply_command("SpawnWorker", "issue_id" => "P1-I1", "prompt" => "Do the work")
    assert_rejected(rejected, "version_control_backend_unavailable")

    apply_command("AddProject", "path" => path, "_head_id" => head_id!)

    spawn_worker!("P1-I1")
  end

  def test_a_name_collision_still_repairs_before_rejecting
    path = add_legacy_project!(project_name: "Legacy")

    result = apply_command("AddProject", "path" => path, "name" => "Legacy")

    assert_rejected(result, "project_already_exists")
    assert_match(/capabilities were repaired/, result.fetch("message"))
    assert_equal true,
                 persisted_project("P1").fetch("version_control_capabilities").fetch("isolated_workspaces")
  end

  # Repair has to be idempotent: a healthy project re-registered by a head must not
  # be reported as repaired just because the probe carries a fresh timestamp.
  def test_re_registering_a_healthy_project_reports_no_repair
    path = make_project_dir("checkout")
    apply_command("AddProject", "path" => path)

    apply_command("AddProject", "path" => path, "_head_id" => head_id!)

    reuse_log = persisted_logs.reverse.find { |entry| entry.dig("details", "reused") == true }
    refute_nil reuse_log
    assert_equal false, reuse_log.fetch("details").fetch("version_control_repaired")
  end

  private

  # A project as it was recorded before isolated-workspace evidence existed.
  def add_legacy_project!(project_name: nil)
    path = make_project_dir("checkout")
    apply_command("AddProject", { "path" => path, "name" => project_name }.compact)
    rewrite_persisted_state do |state|
      project = state.fetch("projects").find { |candidate| candidate.fetch("id") == "P1" }
      VERSION_CONTROL_KEYS.each { |key| project.delete(key) }
    end
    path
  end

  def head_id!
    spawn_head!.fetch("target_id")
  end
end
