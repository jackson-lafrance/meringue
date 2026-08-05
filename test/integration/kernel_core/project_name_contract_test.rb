# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# A project is named with its product name. A lifecycle status describes what Meringue is
# doing to the project and is rendered separately, so it can never be stored as part of
# the name. This covers the end-to-end regression where projects read "Meringue working"
# and "World working": names proposed with a status are normalized on the way in, and a
# state file that already holds a polluted name is repaired rather than left broken.
class KernelCoreProjectNameContractTest < Minitest::Test
  include KernelCoreSupport

  def test_a_project_registered_with_a_status_word_is_stored_with_only_the_product_name
    apply_command("AddProject", "path" => make_project_dir("meringue"), "name" => "Meringue working")
    apply_command("AddProject", "path" => make_project_dir("world"), "name" => "World working")

    assert_equal %w[Meringue World], persisted_projects.map { |project| project.fetch("name") }
    assert_equal %w[working working], persisted_projects.map { |project| project.fetch("status") }
  end

  def test_every_lifecycle_status_is_stripped_from_a_proposed_name
    Meringue::State::Models::LIFECYCLE_STATUSES.each_with_index do |status, index|
      result = apply_command("AddProject", "path" => make_project_dir("repo-#{index}"), "name" => "Meringue #{status}")

      assert_accepted(result)
      assert_equal "Meringue", result.fetch("result").fetch("name"), "#{status} must not survive in the name"
    end
  end

  # State written by an older Meringue (or by a head that echoed a rendered label) keeps a
  # status word in the stored name. Loading it repairs the name, and the next save makes
  # the repair durable, so the user never has to rename the project by hand.
  def test_a_stored_name_that_already_carries_a_status_word_is_repaired_and_persisted
    add_project!(name: "meringue", project_name: "Meringue")
    rewrite_persisted_state { |state| state.fetch("projects").first["name"] = "Meringue working" }
    assert_equal "Meringue working", persisted_project("P1").fetch("name")

    snapshot = apply_command("ListAll").fetch("result")
    assert_equal "Meringue", snapshot.fetch("projects").first.fetch("name")

    create_issue!("P1", title: "Anything that saves state")
    assert_equal "Meringue", persisted_project("P1").fetch("name")
    assert_equal "working", persisted_project("P1").fetch("status")
  end

  def test_repairing_a_stored_name_keeps_a_product_name_that_looks_like_a_status
    add_project!(name: "copy", project_name: "Working Copy")
    rewrite_persisted_state { |state| state.fetch("projects").first["name"] = "Working Copy" }

    snapshot = apply_command("ListAll").fetch("result")

    assert_equal "Working Copy", snapshot.fetch("projects").first.fetch("name")
  end

  # The AgentTree is where the user reads the name, so the repaired state must render as
  # the concise product name with no status word beside it.
  def test_the_agent_tree_renders_the_repaired_project_name_without_a_status_word
    add_project!(name: "meringue", project_name: "Meringue working")
    add_project!(name: "world", project_name: "World working")

    rendered = Meringue::TUI::Panes::AgentTreePane.new.render(apply_command("ListAll").fetch("result"), width: 40)

    assert_includes rendered, "P1  Meringue"
    assert_includes rendered, "P2  World"
    refute_includes rendered, "Meringue working"
    refute_includes rendered, "World working"
  end
end
