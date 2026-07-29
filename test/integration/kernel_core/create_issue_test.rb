# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

class KernelCoreCreateIssueTest < Minitest::Test
  include KernelCoreSupport

  def setup
    super
    add_project!(name: "app")
  end

  def test_create_issue_returns_full_issue_record_and_logs_it
    result = apply_command(
      "CreateIssue",
      "project_id" => "P1",
      "title" => "  Fix signup validation  ",
      "description" => "Detailed context for the worker."
    )

    assert_accepted(result)
    assert_equal "P1-I1", result.fetch("target_id")
    assert_equal "Created issue P1-I1.", result.fetch("message")

    issue = result.fetch("result")
    expected_keys = %w[
      agent_ids created_at description id originating_head_id parent_issue_id project_id
      status title updated_at
    ]
    assert_equal expected_keys, issue.keys.sort
    assert_equal "P1-I1", issue.fetch("id")
    assert_equal "P1", issue.fetch("project_id")
    assert_nil issue.fetch("parent_issue_id")
    assert_nil issue.fetch("originating_head_id")
    assert_equal "Fix signup validation", issue.fetch("title")
    assert_equal "Detailed context for the worker.", issue.fetch("description")
    assert_equal "queued", issue.fetch("status")
    assert_equal [], issue.fetch("agent_ids")
    assert_iso8601(issue.fetch("created_at"), "issue created_at")
    assert_iso8601(issue.fetch("updated_at"), "issue updated_at")
    assert_equal issue.fetch("created_at"), issue.fetch("updated_at")

    assert_equal [issue], persisted_issues

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "info", entry.fetch("level")
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal "P1-I1", entry.fetch("source_id")
    assert_equal "Created issue P1-I1: Fix signup validation", entry.fetch("message")
    assert_equal "P1", entry.fetch("details").fetch("project_id")
    assert_nil entry.fetch("details").fetch("parent_issue_id")
  end

  def test_create_issue_defaults_description_to_empty_string
    issue = create_issue!("P1", title: "No description").fetch("result")

    assert_equal "", issue.fetch("description")
  end

  def test_create_issue_composes_ids_per_project
    assert_equal "P1-I1", create_issue!("P1", title: "First").fetch("target_id")
    assert_equal "P1-I2", create_issue!("P1", title: "Second").fetch("target_id")

    add_project!(name: "api")

    assert_equal "P2-I1", create_issue!("P2", title: "Other project").fetch("target_id")
    assert_equal "P1-I3", create_issue!("P1", title: "Third").fetch("target_id")

    counters = persisted_state.fetch("counters").fetch("issues_by_project")
    assert_equal({ "P1" => 3, "P2" => 1 }, counters)
  end

  def test_create_issue_ids_stay_monotonic_after_an_issue_is_removed
    create_issue!("P1", title: "First")
    create_issue!("P1", title: "Second")
    assert_accepted(apply_command("Kill", "target_id" => "P1-I1"))
    assert_equal ["P1-I2"], persisted_issues.map { |issue| issue.fetch("id") }

    assert_equal "P1-I3", create_issue!("P1", title: "Third").fetch("target_id")
  end

  def test_create_issue_nests_under_a_parent_issue
    parent = create_issue!("P1", title: "Parent").fetch("target_id")

    child = create_issue!("P1", title: "Child", "parent_issue_id" => parent)
    grandchild = create_issue!("P1", title: "Grandchild", "parent_issue_id" => child.fetch("target_id"))

    assert_equal "P1-I1", child.fetch("result").fetch("parent_issue_id")
    assert_equal "P1-I2", grandchild.fetch("result").fetch("parent_issue_id")
    assert_equal "P1-I2", log_entry(grandchild.fetch("log_entry_ids").first).fetch("details").fetch("parent_issue_id")
    assert_equal %w[P1-I1 P1-I2 P1-I3], persisted_issues.map { |issue| issue.fetch("id") }
    assert_equal ["P1-I1", "P1-I2"], persisted_issues.map { |issue| issue.fetch("parent_issue_id") }.compact
  end

  def test_create_issue_rejects_a_parent_from_another_project
    create_issue!("P1", title: "Parent in P1")
    add_project!(name: "api")
    before = domain_snapshot

    result = apply_command("CreateIssue", "project_id" => "P2", "title" => "Child", "parent_issue_id" => "P1-I1")

    assert_rejected(result, "parent_issue_not_found")
    assert_equal before, domain_snapshot
    assert_equal({ "P1" => 1 }, persisted_state.fetch("counters").fetch("issues_by_project"))
  end

  def test_create_issue_rejects_an_unknown_parent
    result = apply_command("CreateIssue", "project_id" => "P1", "title" => "Child", "parent_issue_id" => "P1-I99")

    assert_rejected(result, "parent_issue_not_found")
    assert_empty persisted_issues
  end

  def test_create_issue_treats_a_blank_parent_as_no_parent
    issue = create_issue!("P1", title: "Root", "parent_issue_id" => "   ").fetch("result")

    assert_nil issue.fetch("parent_issue_id")
  end

  def test_create_issue_rejects_an_unknown_project
    before = domain_snapshot

    result = apply_command("CreateIssue", "project_id" => "P99", "title" => "Orphan")

    assert_rejected(result, "project_not_found")
    assert_equal "Project P99 does not exist.", result.fetch("message")
    assert_equal before, domain_snapshot
    assert_equal({}, persisted_state.fetch("counters").fetch("issues_by_project"))
  end

  def test_create_issue_requires_project_id_and_title
    result = apply_command("CreateIssue", {})

    assert_rejected(result, "project_id is required", "title is required")
    assert_equal "Issue was not created.", result.fetch("message")
    assert_empty persisted_issues
  end

  def test_create_issue_rejects_an_invalid_status
    result = apply_command("CreateIssue", "project_id" => "P1", "title" => "Bad status", "status" => "in_progress")

    assert_rejected(result, "status must be one of")
    assert_empty persisted_issues
  end

  def test_create_issue_accepts_every_lifecycle_status
    Meringue::State::Models::LIFECYCLE_STATUSES.each_with_index do |status, index|
      result = create_issue!("P1", title: "Issue #{status}", "status" => status)

      assert_equal status, result.fetch("result").fetch("status")
      assert_equal "P1-I#{index + 1}", result.fetch("target_id")
    end
  end

  def test_create_issue_records_the_originating_head_id
    issue = create_issue!("P1", title: "From a head", "_head_id" => "H7").fetch("result")

    assert_equal "H7", issue.fetch("originating_head_id")
    assert_equal "H7", persisted_issue("P1-I1").fetch("originating_head_id")
  end

  def test_create_issue_bumps_the_project_updated_at
    rewrite_persisted_state do |state|
      state.fetch("projects").first["updated_at"] = "2000-01-01T00:00:00Z"
    end

    create_issue!("P1", title: "Touches the project")

    refute_equal "2000-01-01T00:00:00Z", persisted_project("P1").fetch("updated_at")
    assert_iso8601(persisted_project("P1").fetch("updated_at"), "project updated_at")
  end

  def test_create_issue_accepts_camel_case_payload_keys_and_alias
    result = apply_command("create_issue", "ProjectID" => "P1", "Title" => "Camel", "Description" => "Body")

    assert_accepted(result)
    assert_equal "CreateIssue", result.fetch("command_type")
    assert_equal "Camel", persisted_issue("P1-I1").fetch("title")
    assert_equal "Body", persisted_issue("P1-I1").fetch("description")
  end
end
