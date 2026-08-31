# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"
require "tmpdir"
require "fileutils"

# Unit coverage for the project-declared workspace profile value object and
# loader. These exercises avoid real git operations and stay fast; the
# end-to-end sparse provisioning flow lives in manager_sparse_profile_test.rb.
class WorkspaceProfileTest < Minitest::Test
  include WorkspaceSupport

  def with_profile_tmpdir(&block)
    Dir.mktmpdir("meringue-profile-test", &block)
  end

  def write_profile(root, body)
    FileUtils.mkdir_p(File.join(root, ".meringue"))
    File.write(File.join(root, ".meringue", "workspace-profile.toml"), body)
  end

  def test_load_returns_nil_when_no_profile_file_declared
    with_profile_tmpdir do |tmp|
      assert_nil Meringue::Workspace::Profile.load(tmp)
    end
  end

  def test_load_returns_nil_for_malformed_profile_file
    with_profile_tmpdir do |tmp|
      write_profile(tmp, "this is not = valid = toml [[[")
      assert_nil Meringue::Workspace::Profile.load(tmp)
    end
  end

  def test_load_reads_flat_profile_table
    with_profile_tmpdir do |tmp|
      write_profile(tmp, <<~TOML)
        [profile]
        sparse_cone = true
        sparse_patterns = ["/src/", "/docs/"]
        validation_command = ["bin/check"]
      TOML
      profile = Meringue::Workspace::Profile.load(tmp)

      refute_nil profile
      assert_equal "profile", profile.name
      assert profile.sparse?
      assert profile.cone?
      assert_equal ["/src/", "/docs/"], profile.sparse_patterns
      assert_equal ["bin/check"], profile.validation_command
      assert profile.validation?
    end
  end

  def test_load_selects_default_profile_from_map
    with_profile_tmpdir do |tmp|
      write_profile(tmp, <<~TOML)
        default_profile = "narrow"

        [profiles.narrow]
        sparse_cone = true
        sparse_patterns = ["/src/"]

        [profiles.wide]
        sparse_cone = true
        sparse_patterns = ["/src/", "/docs/"]
      TOML
      profile = Meringue::Workspace::Profile.load(tmp)

      assert_equal "narrow", profile.name
      assert_equal ["/src/"], profile.sparse_patterns
    end
  end

  def test_load_explicit_profile_name_overrides_default
    with_profile_tmpdir do |tmp|
      write_profile(tmp, <<~TOML)
        default_profile = "narrow"

        [profiles.narrow]
        sparse_patterns = ["/src/"]

        [profiles.wide]
        sparse_patterns = ["/src/", "/docs/"]
      TOML
      profile = Meringue::Workspace::Profile.load(tmp, profile_name: "wide")

      assert_equal "wide", profile.name
      assert_equal ["/src/", "/docs/"], profile.sparse_patterns
    end
  end

  def test_sparse_predicates_reflect_declared_patterns
    profile = Meringue::Workspace::Profile.new(name: "x", sparse_cone: false, sparse_patterns: ["/a/"])
    assert profile.sparse?
    refute profile.cone?
    refute profile.validation?
    refute profile.custom_path_template?

    empty = Meringue::Workspace::Profile.new(name: "empty")
    refute empty.sparse?
    refute empty.cone?
  end

  def test_validation_command_normalizes_string_and_array
    profile = Meringue::Workspace::Profile.new(name: "x", validation_command: "bin/check")
    assert_equal ["bin/check"], profile.validation_command

    profile2 = Meringue::Workspace::Profile.new(name: "x", validation_command: ["a", "", "b"])
    assert_equal ["a", "b"], profile2.validation_command

    profile3 = Meringue::Workspace::Profile.new(name: "x", validation_command: [])
    refute profile3.validation?
  end

  def test_default_path_template_is_valid_and_expands_under_root
    profile = Meringue::Workspace::Profile.new(name: "x")
    assert profile.path_template_valid?
    expanded = profile.expand_path(root: "/tmp/r", project_slug: "proj", task_slug: "task")
    assert_equal "/tmp/r/proj/task", expanded
  end

  def test_custom_path_template_expands_with_placeholders
    profile = Meringue::Workspace::Profile.new(
      name: "x",
      path_template: "{{root}}/checkouts/{{project}}/{{task}}"
    )
    assert profile.path_template_valid?
    assert profile.custom_path_template?
    expanded = profile.expand_path(root: "/tmp/r", project_slug: "proj", task_slug: "task")
    assert_equal "/tmp/r/checkouts/proj/task", expanded
  end

  def test_path_template_with_parent_segment_is_rejected
    profile = Meringue::Workspace::Profile.new(
      name: "x",
      path_template: "{{root}}/../../escape/{{task}}"
    )
    refute profile.path_template_valid?
    assert_nil profile.expand_path(root: "/tmp/r", project_slug: "p", task_slug: "t")
  end

  def test_path_template_with_shell_metacharacters_is_rejected
    profile = Meringue::Workspace::Profile.new(
      name: "x",
      path_template: "{{root}}/$(whoami)/{{task}}"
    )
    refute profile.path_template_valid?
  end

  def test_path_template_cannot_restore_retired_suffix_placeholder
    profile = Meringue::Workspace::Profile.new(
      name: "x",
      path_template: "{{root}}/{{project}}/{{task}}-{{suffix}}"
    )
    refute profile.path_template_valid?
    assert_nil profile.expand_path(root: "/tmp/r", project_slug: "p", task_slug: "t")
  end

  def test_path_template_escaping_managed_root_returns_nil
    profile = Meringue::Workspace::Profile.new(
      name: "x",
      path_template: "{{root}}/../escape/{{task}}"
    )
    refute profile.path_template_valid?
    assert_nil profile.expand_path(root: "/tmp/r", project_slug: "p", task_slug: "t")
  end

  def test_to_h_round_trips_declared_fields
    profile = Meringue::Workspace::Profile.new(
      name: "core",
      sparse_cone: true,
      sparse_patterns: ["/src/"],
      validation_command: ["bin/check"]
    )
    snapshot = profile.to_h
    assert_equal "core", snapshot.fetch("name")
    assert_equal true, snapshot.fetch("sparse_cone")
    assert_equal ["/src/"], snapshot.fetch("sparse_patterns")
    assert_equal ["bin/check"], snapshot.fetch("validation_command")
  end

  def test_summary_describes_sparse_profile
    profile = Meringue::Workspace::Profile.new(name: "core", sparse_cone: true, sparse_patterns: ["/src/", "/docs/"])
    assert_equal "core (sparse, cone, 2 patterns)", profile.summary

    full = Meringue::Workspace::Profile.new(name: "default")
    assert_equal "default (full checkout)", full.summary
  end
end
