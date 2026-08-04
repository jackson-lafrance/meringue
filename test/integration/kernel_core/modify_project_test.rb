# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

class KernelCoreModifyProjectTest < Minitest::Test
  include KernelCoreSupport

  def setup
    super
    add_project!(name: "app", project_name: "Original project")
  end

  def test_modify_project_updates_name_and_logs_the_change
    result = apply_command("ModifyProject", "project_id" => "P1", "name" => "  Renamed app  ")

    assert_accepted(result)
    assert_equal "P1", result.fetch("target_id")
    assert_equal "Renamed app", result.fetch("result").fetch("name")
    assert_equal "Renamed app", persisted_project("P1").fetch("name")

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "P1", entry.fetch("source_id")
    assert_equal ["name"], entry.fetch("details").fetch("changed_fields")
    assert_equal "Original project", entry.fetch("details").fetch("previous_name")
  end

  def test_modify_project_rejects_blank_names_without_touching_state
    before = domain_snapshot

    result = apply_command("ModifyProject", "project_id" => "P1", "name" => "  ")

    assert_rejected(result, "name is required")
    assert_equal before, domain_snapshot
    assert_equal "Original project", persisted_project("P1").fetch("name")
  end

  def test_rename_dispatches_to_projects_and_issues
    project = apply_command("Rename", "target_id" => "P1", "name" => "New project")
    assert_accepted(project)
    assert_equal "Rename", project.fetch("command_type")
    assert_equal "New project", persisted_project("P1").fetch("name")

    create_issue!("P1", title: "Old issue")
    issue = apply_command("rename", "target_id" => "P1-I1", "name" => "New issue")
    assert_accepted(issue)
    assert_equal "Rename", issue.fetch("command_type")
    assert_equal "New issue", persisted_issue("P1-I1").fetch("title")
  end
end
