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

  # A rename can never reintroduce the "Meringue working" shape either.
  def test_modify_project_strips_a_lifecycle_status_from_the_new_name
    result = apply_command("ModifyProject", "project_id" => "P1", "name" => "Meringue working")

    assert_accepted(result)
    assert_equal "Meringue", result.fetch("result").fetch("name")
    assert_equal "Meringue", persisted_project("P1").fetch("name")
    assert_equal "Renamed project P1: Original project -> Meringue", log_entry(result.fetch("log_entry_ids").first).fetch("message")

    renamed = apply_command("ModifyProject", "project_id" => "P1", "name" => "World  working")
    assert_accepted(renamed)
    assert_equal "World", persisted_project("P1").fetch("name")
  end

  # Regression: renaming a project to the name it already has logged
  # "Renamed project P1: Meringue -> Meringue", which reads as a rename that silently
  # failed. It has to report the no-op honestly and leave the record alone.
  def test_modify_project_reports_a_rename_to_the_current_name_as_no_change
    apply_command("ModifyProject", "project_id" => "P1", "name" => "Meringue")
    before = persisted_project("P1")

    result = apply_command("ModifyProject", "project_id" => "P1", "name" => "  Meringue  ")

    assert_accepted(result)
    assert_equal "P1", result.fetch("target_id")
    assert_equal "Project P1 is already named Meringue; nothing was changed.", result.fetch("message")
    assert_equal before, persisted_project("P1"), "a no-op rename leaves the record, including updated_at, untouched"

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "Project P1 is already named Meringue; nothing was changed.", entry.fetch("message")
    assert_equal [], entry.fetch("details").fetch("changed_fields")
    refute_includes entry.fetch("message"), "->"
  end

  # Only an identical name is a no-op. Changing the case is a real rename, even though the
  # two names collide for the uniqueness check.
  def test_modify_project_still_renames_when_only_the_case_differs
    apply_command("ModifyProject", "project_id" => "P1", "name" => "meringue")

    result = apply_command("ModifyProject", "project_id" => "P1", "name" => "Meringue")

    assert_accepted(result)
    assert_equal "Meringue", persisted_project("P1").fetch("name")
    assert_equal "Renamed project P1: meringue -> Meringue", log_entry(result.fetch("log_entry_ids").first).fetch("message")
  end

  # ModifyProject also accepts the generic target_id spelling, which is what the removed
  # Rename wrapper used to forward.
  def test_modify_project_accepts_a_generic_target_id
    result = apply_command("ModifyProject", "target_id" => "P1", "name" => "New project")

    assert_accepted(result)
    assert_equal "New project", persisted_project("P1").fetch("name")
  end

  # The Rename wrapper only ever existed to back the removed plain `/rename` slash command.
  # ModifyProject and ModifyIssue are now the only rename commands, and Rename is not a kernel
  # command at all: it is neither dispatched nor proposable by a head.
  def test_the_rename_wrapper_command_is_gone
    create_issue!("P1", title: "Old issue")
    before = domain_snapshot

    %w[Rename rename].each do |command_type|
      result = apply_command(command_type, "target_id" => "P1", "name" => "New project")

      assert_rejected(result, "unknown_command")
      assert_includes result.fetch("message"), "Unknown kernel command"
    end

    assert_equal before, domain_snapshot
    refute_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, "Rename"

    project = apply_command("ModifyProject", "project_id" => "P1", "name" => "New project")
    assert_accepted(project)
    assert_equal "New project", persisted_project("P1").fetch("name")

    issue = apply_command("ModifyIssue", "issue_id" => "P1-I1", "title" => "New issue")
    assert_accepted(issue)
    assert_equal "New issue", persisted_issue("P1-I1").fetch("title")
  end
end
