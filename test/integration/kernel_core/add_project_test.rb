# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

class KernelCoreAddProjectTest < Minitest::Test
  include KernelCoreSupport

  def test_add_project_returns_full_project_record_and_logs_it
    path = make_project_dir("checkout")

    result = apply_command("AddProject", "path" => path)

    assert_accepted(result)
    assert_equal "AddProject", result.fetch("command_type")
    assert_equal "P1", result.fetch("target_id")
    assert_equal "Added project P1.", result.fetch("message")

    project = result.fetch("result")
    assert_equal %w[created_at id name root_path status updated_at], project.keys.sort
    assert_equal "P1", project.fetch("id")
    assert_equal "checkout", project.fetch("name")
    assert_equal File.expand_path(path), project.fetch("root_path")
    assert_equal "working", project.fetch("status")
    assert_iso8601(project.fetch("created_at"), "project created_at")
    assert_iso8601(project.fetch("updated_at"), "project updated_at")
    assert_equal project.fetch("created_at"), project.fetch("updated_at")

    assert_equal [project], persisted_projects
    assert_equal 1, persisted_state.fetch("counters").fetch("projects")

    assert_equal 1, result.fetch("log_entry_ids").length
    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal "P1", entry.fetch("source_id")
    assert_equal "info", entry.fetch("level")
    assert_equal "Added project P1: checkout", entry.fetch("message")
    assert_equal File.expand_path(path), entry.fetch("details").fetch("root_path")
  end

  def test_add_project_uses_explicit_name_and_trims_it
    path = make_project_dir("api")

    project = apply_command("AddProject", "path" => path, "name" => "  Payments API  ").fetch("result")

    assert_equal "Payments API", project.fetch("name")
    assert_equal "Payments API", persisted_project("P1").fetch("name")
  end

  # Regression: a head that echoed the rendered "Meringue working" label back into
  # AddProject registered a project whose stored name carried a lifecycle status.
  def test_add_project_strips_a_lifecycle_status_from_the_proposed_name
    project = apply_command("AddProject", "path" => make_project_dir("meringue"), "name" => "Meringue working").fetch("result")

    assert_equal "Meringue", project.fetch("name")
    assert_equal "Meringue", persisted_project("P1").fetch("name")

    second = apply_command("AddProject", "path" => make_project_dir("world"), "name" => "World  working").fetch("result")
    assert_equal "World", second.fetch("name")
    assert_equal "Added project P2: World", log_messages.last
  end

  def test_add_project_keeps_a_product_name_that_merely_contains_a_status_word
    project = apply_command("AddProject", "path" => make_project_dir("copy"), "name" => "Working Copy").fetch("result")

    assert_equal "Working Copy", project.fetch("name")
  end

  def test_add_project_falls_back_to_basename_when_name_is_blank
    path = make_project_dir("fallback")

    project = apply_command("AddProject", "path" => path, "name" => "   ").fetch("result")

    assert_equal "fallback", project.fetch("name")
  end

  def test_add_project_normalizes_the_stored_root_path
    path = make_project_dir("normalize")

    project = apply_command("AddProject", "path" => File.join(path, ".", "")).fetch("result")

    assert_equal File.expand_path(path), project.fetch("root_path")
  end

  def test_add_project_requires_a_path
    before = domain_snapshot

    result = apply_command("AddProject", {})

    assert_rejected(result, "path is required")
    assert_equal "Project was not added.", result.fetch("message")
    assert_nil result.fetch("target_id")
    assert_nil result.fetch("result")
    assert_equal before, domain_snapshot
  end

  def test_add_project_rejects_a_nonexistent_directory
    missing = File.join(tmp_root, "does", "not", "exist")

    result = apply_command("AddProject", "path" => missing)

    assert_rejected(result, "path must be an existing directory")
    assert_empty persisted_projects
    assert_equal 0, persisted_state.fetch("counters").fetch("projects")
  end

  def test_add_project_rejects_a_file_path
    file_path = File.join(tmp_root, "not-a-directory.txt")
    File.write(file_path, "hello")

    result = apply_command("AddProject", "path" => file_path)

    assert_rejected(result, "path must be an existing directory")
    assert_empty persisted_projects
  end

  def test_rejected_add_project_only_appends_a_warning_log
    result = apply_command("AddProject", { "path" => File.join(tmp_root, "nope") }, "cmd-add-1")

    assert_rejected(result)
    assert_equal 1, result.fetch("log_entry_ids").length
    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "warning", entry.fetch("level")
    assert_equal "kernel", entry.fetch("source_type")
    assert_match(/\ARejected AddProject: /, entry.fetch("message"))
    assert_equal "cmd-add-1", entry.fetch("details").fetch("command_id")
    assert_equal "rejected", entry.fetch("details").fetch("status")
    assert_log_levels_valid
  end

  def test_add_project_rejects_duplicate_registration_of_the_same_root
    path = make_project_dir("duplicate")
    assert_accepted(apply_command("AddProject", "path" => path))
    before = domain_snapshot

    duplicate = apply_command("AddProject", "path" => File.join(path, "."), "name" => "Another Name")

    assert_rejected(duplicate, "project_already_exists")
    assert_equal "Project is already registered.", duplicate.fetch("message")
    assert_equal before, domain_snapshot
    assert_equal 1, persisted_projects.length
    assert_equal 1, persisted_state.fetch("counters").fetch("projects")
  end

  def test_add_project_assigns_sequential_ids_per_registration
    ids = %w[one two three].map do |name|
      apply_command("AddProject", "path" => make_project_dir(name)).fetch("target_id")
    end

    assert_equal %w[P1 P2 P3], ids
    assert_equal %w[P1 P2 P3], persisted_projects.map { |project| project.fetch("id") }
    assert_equal 3, persisted_state.fetch("counters").fetch("projects")
  end

  def test_add_project_ids_stay_monotonic_after_a_project_is_killed
    apply_command("AddProject", "path" => make_project_dir("first"))
    assert_accepted(apply_command("Kill", "target_id" => "P1"))
    assert_empty persisted_projects

    result = apply_command("AddProject", "path" => make_project_dir("second"))

    assert_equal "P2", result.fetch("target_id")
  end

  def test_add_project_accepts_the_snake_case_alias_and_payload_variants
    path = make_project_dir("aliased")

    result = apply_command("add_project", "Path" => path, "Name" => "Aliased")

    assert_accepted(result)
    assert_equal "AddProject", result.fetch("command_type")
    assert_equal "Aliased", persisted_project("P1").fetch("name")
  end

  def test_add_project_accepts_a_command_object
    path = make_project_dir("command-object")

    result = engine.apply(Meringue::Kernel::Command.new(type: "AddProject", payload: { "path" => path }))

    assert_accepted(result)
    assert_nil result.fetch("command_id")
    assert_equal "P1", result.fetch("target_id")
  end
end
