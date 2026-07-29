# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

class KernelCoreModifyIssueTest < Minitest::Test
  include KernelCoreSupport

  ANCIENT = "2000-01-01T00:00:00Z"

  def setup
    super
    add_project!(name: "app")
    create_issue!("P1", title: "Original title", "description" => "Original description")
  end

  def test_modify_issue_updates_title_and_description
    result = apply_command(
      "ModifyIssue",
      "issue_id" => "P1-I1",
      "title" => "  Updated title  ",
      "description" => "Updated description"
    )

    assert_accepted(result)
    assert_equal "P1-I1", result.fetch("target_id")
    assert_equal "Modified issue P1-I1.", result.fetch("message")

    issue = result.fetch("result")
    assert_equal "Updated title", issue.fetch("title")
    assert_equal "Updated description", issue.fetch("description")
    assert_equal "Updated title", persisted_issue("P1-I1").fetch("title")
    assert_equal "Updated description", persisted_issue("P1-I1").fetch("description")

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "info", entry.fetch("level")
    assert_equal "P1-I1", entry.fetch("source_id")
    assert_equal "Modified issue P1-I1: title, description", entry.fetch("message")
    assert_equal %w[title description], entry.fetch("details").fetch("changed_fields")
  end

  def test_modify_issue_updates_status_and_propagates_to_the_project
    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "status" => "completed")

    assert_accepted(result)
    assert_equal "completed", result.fetch("result").fetch("status")
    assert_equal "completed", persisted_issue("P1-I1").fetch("status")
    assert_equal "completed", persisted_project("P1").fetch("status")
    assert_equal ["status"], log_entry(result.fetch("log_entry_ids").first).fetch("details").fetch("changed_fields")
  end

  def test_modify_issue_project_status_reflects_the_worst_child_status
    create_issue!("P1", title: "Second issue")

    assert_accepted(apply_command("ModifyIssue", "issue_id" => "P1-I1", "status" => "completed"))
    assert_equal "working", persisted_project("P1").fetch("status")

    assert_accepted(apply_command("ModifyIssue", "issue_id" => "P1-I2", "status" => "errored"))
    assert_equal "errored", persisted_project("P1").fetch("status")

    assert_accepted(apply_command("ModifyIssue", "issue_id" => "P1-I2", "status" => "completed"))
    assert_equal "completed", persisted_project("P1").fetch("status")
  end

  def test_modify_issue_sets_and_clears_the_parent
    create_issue!("P1", title: "Child")

    assert_accepted(apply_command("ModifyIssue", "issue_id" => "P1-I2", "parent_issue_id" => "P1-I1"))
    assert_equal "P1-I1", persisted_issue("P1-I2").fetch("parent_issue_id")

    cleared = apply_command("ModifyIssue", "issue_id" => "P1-I2", "parent_issue_id" => "")

    assert_accepted(cleared)
    assert_nil persisted_issue("P1-I2").fetch("parent_issue_id")
    assert_equal ["parent_issue_id"], log_entry(cleared.fetch("log_entry_ids").first).fetch("details").fetch("changed_fields")
  end

  def test_modify_issue_rejects_an_unknown_issue
    before = domain_snapshot

    result = apply_command("ModifyIssue", "issue_id" => "P1-I99", "title" => "Nope")

    assert_rejected(result, "issue_not_found")
    assert_equal "Issue P1-I99 does not exist.", result.fetch("message")
    assert_equal before, domain_snapshot
  end

  def test_modify_issue_rejects_an_invalid_status_without_touching_state
    before = domain_snapshot

    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "title" => "Also ignored", "status" => "shipping")

    assert_rejected(result, "status must be one of")
    assert_equal "Issue was not modified.", result.fetch("message")
    assert_equal before, domain_snapshot
    assert_equal "Original title", persisted_issue("P1-I1").fetch("title")
  end

  def test_modify_issue_requires_an_issue_id
    result = apply_command("ModifyIssue", "title" => "No id")

    assert_rejected(result, "issue_id is required")
    assert_equal "Original title", persisted_issue("P1-I1").fetch("title")
  end

  def test_modify_issue_rejects_an_unknown_parent
    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "parent_issue_id" => "P1-I99")

    assert_rejected(result, "parent_issue_not_found")
    assert_nil persisted_issue("P1-I1").fetch("parent_issue_id")
  end

  def test_modify_issue_rejects_a_parent_from_another_project
    add_project!(name: "api")
    create_issue!("P2", title: "Other project issue")

    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "parent_issue_id" => "P2-I1")

    assert_rejected(result, "parent_issue_not_found")
    assert_nil persisted_issue("P1-I1").fetch("parent_issue_id")
  end

  def test_modify_issue_rejects_self_parenting
    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "parent_issue_id" => "P1-I1")

    assert_rejected(result, "invalid_parent_issue")
    assert_equal "Issue cannot be its own parent.", result.fetch("message")
    assert_nil persisted_issue("P1-I1").fetch("parent_issue_id")
  end

  def test_modify_issue_bumps_updated_at_on_the_issue_and_project
    rewrite_persisted_state do |state|
      state.fetch("issues").first["updated_at"] = ANCIENT
      state.fetch("projects").first["updated_at"] = ANCIENT
    end

    assert_accepted(apply_command("ModifyIssue", "issue_id" => "P1-I1", "title" => "Bumped"))

    refute_equal ANCIENT, persisted_issue("P1-I1").fetch("updated_at")
    refute_equal ANCIENT, persisted_project("P1").fetch("updated_at")
    assert_iso8601(persisted_issue("P1-I1").fetch("updated_at"), "issue updated_at")
    assert_operator Time.iso8601(persisted_issue("P1-I1").fetch("updated_at")),
                    :>,
                    Time.iso8601(ANCIENT)
    assert_equal persisted_issue("P1-I1").fetch("created_at"), persisted_issues.first.fetch("created_at")
  end

  def test_modify_issue_with_no_fields_still_bumps_timestamps_and_logs_no_changes
    rewrite_persisted_state do |state|
      state.fetch("issues").first["updated_at"] = ANCIENT
    end

    result = apply_command("ModifyIssue", "issue_id" => "P1-I1")

    assert_accepted(result)
    assert_equal "Modified issue P1-I1: no fields changed", log_entry(result.fetch("log_entry_ids").first).fetch("message")
    assert_equal [], log_entry(result.fetch("log_entry_ids").first).fetch("details").fetch("changed_fields")
    refute_equal ANCIENT, persisted_issue("P1-I1").fetch("updated_at")
    assert_equal "Original title", persisted_issue("P1-I1").fetch("title")
  end

  def test_modify_issue_treats_a_present_key_with_blank_value_as_a_change
    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "description" => "")

    assert_accepted(result)
    assert_equal "", persisted_issue("P1-I1").fetch("description")
    assert_equal ["description"], log_entry(result.fetch("log_entry_ids").first).fetch("details").fetch("changed_fields")
  end

  def test_modify_issue_ignores_a_blank_status
    result = apply_command("ModifyIssue", "issue_id" => "P1-I1", "status" => "   ", "title" => "Kept")

    assert_accepted(result)
    assert_equal "queued", persisted_issue("P1-I1").fetch("status")
    assert_equal ["title"], log_entry(result.fetch("log_entry_ids").first).fetch("details").fetch("changed_fields")
  end

  def test_modify_issue_accepts_camel_case_keys_and_alias
    result = apply_command("modify_issue", "IssueID" => "P1-I1", "Title" => "Camel title", "Status" => "blocked")

    assert_accepted(result)
    assert_equal "ModifyIssue", result.fetch("command_type")
    assert_equal "Camel title", persisted_issue("P1-I1").fetch("title")
    assert_equal "blocked", persisted_issue("P1-I1").fetch("status")
    assert_equal "blocked", persisted_project("P1").fetch("status")
  end
end
