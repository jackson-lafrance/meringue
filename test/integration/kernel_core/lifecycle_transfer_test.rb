# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

class KernelCoreLifecycleTransferTest < Minitest::Test
  include KernelCoreSupport

  def test_project_merge_rewrites_issue_ids_and_removes_source_atomically
    path = make_project_dir("checkout")
    apply_command("AddProject", "path" => path, "name" => "Primary")
    apply_command("AddProject", "path" => path, "name" => "Duplicate")
    issue = apply_command("CreateIssue", "project_id" => "P2", "title" => "Queued work").fetch("result")

    result = apply_command("MergeProject", "source_id" => "P2", "destination_id" => "P1")

    assert_accepted(result)
    assert_nil persisted_project("P2")
    moved = persisted_issues.find { |candidate| candidate["title"] == "Queued work" }
    assert_equal "P1", moved.fetch("project_id")
    refute_equal issue.fetch("id"), moved.fetch("id")
  end

  def test_transfer_requires_both_distinct_records_and_rolls_back
    path = make_project_dir("checkout")
    apply_command("AddProject", "path" => path, "name" => "Primary")
    before = persisted_state

    result = apply_command("MergeProject", "source_id" => "P1", "destination_id" => "P1")

    assert_rejected(result)
    assert_equal before.fetch("projects"), persisted_state.fetch("projects")
  end
end
