# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"
require "tmpdir"

# ProjectNaming is the one place that decides what a project is called. Every layer that
# derives, stores, repairs, or renders a project name goes through it, so the naming
# contract ("a project is named with its product name, never with a lifecycle status")
# is asserted here.
class FoundationProjectNamingTest < Minitest::Test
  Naming = Meringue::ProjectNaming

  def test_status_suffixes_cover_every_lifecycle_status
    assert_equal Meringue::State::Models::LIFECYCLE_STATUSES.sort, Naming::STATUS_SUFFIXES.sort
    assert Naming::STATUS_SUFFIXES.frozen?, "status suffixes must be frozen"
    Naming::STATUS_SUFFIXES.each do |status|
      assert_includes Naming::NON_PRODUCT_SUFFIXES, status
    end
  end

  # The exact regression the user reported: "Meringue working" / "World working".
  def test_without_status_suffix_removes_a_rendered_status_word
    assert_equal "Meringue", Naming.without_status_suffix("Meringue working")
    assert_equal "World", Naming.without_status_suffix("World working")
    assert_equal "Meringue", Naming.without_status_suffix("Meringue  working")
    assert_equal "Meringue", Naming.without_status_suffix("  Meringue working  ")
    assert_equal "Meringue", Naming.without_status_suffix("Meringue (working)")
    assert_equal "Meringue", Naming.without_status_suffix("Meringue - killed")
    assert_equal "Meringue", Naming.without_status_suffix("Meringue · idle")
    assert_equal "Payments API", Naming.without_status_suffix("Payments API blocked queued")
  end

  def test_without_status_suffix_keeps_real_product_names
    ["Meringue", "World", "Payments API", "Payments Integration", "Working Copy", "rails"].each do |name|
      assert_equal name, Naming.without_status_suffix(name)
    end
  end

  # A repository really named "working" keeps its name: at least one word always survives.
  def test_without_status_suffix_never_empties_a_name
    assert_equal "working", Naming.without_status_suffix("working")
    assert_equal "Working", Naming.without_status_suffix("  Working  ")
    assert_nil Naming.without_status_suffix("   ")
    assert_nil Naming.without_status_suffix(nil)
  end

  def test_status_suffix_flags_only_polluted_names
    assert Naming.status_suffix?("Meringue working")
    assert Naming.status_suffix?("World  working")
    refute Naming.status_suffix?("Meringue")
    refute Naming.status_suffix?("Working Copy")
    refute Naming.status_suffix?("working")
    refute Naming.status_suffix?(nil)
  end

  # canonical_name is the aggressive cleanup used for names Meringue derives itself.
  def test_canonical_name_also_drops_task_words_and_statuses
    assert_equal "Meringue", Naming.canonical_name("Meringue working")
    assert_equal "Meringue", Naming.canonical_name("Meringue fix")
    assert_equal "Signup", Naming.canonical_name("Signup update")
    assert_nil Naming.canonical_name("")
  end

  def test_name_for_prefers_the_readme_heading_without_a_status
    Dir.mktmpdir("meringue-naming-test-") do |dir|
      root = File.join(dir, "meringue-worktrees", "fix-project-name")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "README.md"), "# Meringue working\n\nOrchestration.\n")

      assert_equal "Meringue", Naming.name_for(root)
    end
  end

  def test_name_for_humanizes_the_basename_when_there_is_no_readme
    Dir.mktmpdir("meringue-naming-test-") do |dir|
      root = File.join(dir, "world")
      FileUtils.mkdir_p(root)

      assert_equal "World", Naming.name_for(root)
    end
  end
end
