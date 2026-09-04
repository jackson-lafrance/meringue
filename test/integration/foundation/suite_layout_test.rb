# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# Guards the plumbing the whole suite depends on: the Rakefile test task, the
# test-file discovery glob, the shared conventions, and source dependencies.
class FoundationSuiteLayoutTest < Minitest::Test
  # Loads the Rakefile in a subprocess and prints what the `test` task was built from.
  # Rake::TestTask keeps no reference from the task back to itself, so the instances
  # are captured as they are defined instead.
  RAKEFILE_INSPECTION = <<~RUBY
    require "json"
    require "rake/testtask"
    TEST_TASKS = {}
    Rake::TestTask.prepend(Module.new do
      def define
        TEST_TASKS[name.to_s] = self
        super
      end
    end)
    load "Rakefile"
    test_task = TEST_TASKS.fetch("test")
    puts JSON.generate(
      "default_prerequisites" => Rake::Task["default"].prerequisites,
      "libs" => test_task.libs,
      "all_test_files" => ALL_TEST_FILES,
      "selected_test_files" => test_task.file_list.to_a
    )
  RUBY

  def all_test_files
    Dir[FoundationSupport.repo_path("test", "**", "*_test.rb")].map do |path|
      path.delete_prefix("#{FoundationSupport::REPO_ROOT}/")
    end.sort
  end

  def test_rakefile_defines_a_default_test_task
    status, stdout, = FoundationSupport.run_ruby(
      "-e",
      'require "rake"; load "Rakefile"; print Rake::Task.tasks.map(&:name).sort.join(",")'
    )

    assert_equal 0, status
    # test:smoke is the deliberate quick subset behind `bundle exec rake test:smoke`.
    assert_equal ["default", "test", "test:smoke"], stdout.strip.split(",")
  end

  # Checks the wiring by loading the Rakefile rather than grepping its spelling, so
  # the task helper and sharding can be refactored without breaking this guard.
  def test_rakefile_wires_lib_and_test_onto_the_load_path
    status, stdout, stderr = FoundationSupport.run_ruby("-e", RAKEFILE_INSPECTION)

    assert_equal 0, status, stderr
    inspection = JSON.parse(stdout)

    assert_equal ["test"], inspection.fetch("default_prerequisites")
    assert_equal ["lib", "test"], inspection.fetch("libs")
    assert_equal all_test_files, inspection.fetch("all_test_files")
    assert_equal all_test_files, inspection.fetch("selected_test_files")
  end

  # CI runs the suite in shards: TEST_SHARD=n selects every n-th file (1-based) of the
  # sorted list, so together the shards cover every file exactly once.
  def test_rakefile_shards_select_a_deterministic_slice_of_the_sorted_test_files
    status, stdout, stderr = FoundationSupport.run_ruby(
      "-e", RAKEFILE_INSPECTION, env: { "TEST_SHARDS" => "8", "TEST_SHARD" => "3" }
    )

    assert_equal 0, status, stderr
    inspection = JSON.parse(stdout)

    expected = all_test_files.each_with_index.select { |_, index| index % 8 == 2 }.map(&:first)
    refute_empty expected
    assert_equal all_test_files, inspection.fetch("all_test_files")
    assert_equal expected, inspection.fetch("selected_test_files")
  end

  def test_test_helper_exposes_the_library_and_minitest
    helper = File.read(FoundationSupport.repo_path("test", "test_helper.rb"))

    assert_includes helper, 'require "minitest/autorun"'
    assert_includes helper, 'require "meringue"'
    assert defined?(Minitest::Test), "test_helper must load minitest"
  end

  def test_discovery_glob_finds_this_slices_tests
    discovered = Dir[FoundationSupport.repo_path("test", "**", "*_test.rb")].map do |path|
      path.delete_prefix("#{FoundationSupport::REPO_ROOT}/")
    end

    refute_empty discovered
    assert_includes discovered, "test/integration/foundation/suite_layout_test.rb"
    assert_includes discovered, "test/integration/foundation/cli_entrypoint_test.rb"
    assert_includes discovered, "test/integration/foundation/library_boot_test.rb"
  end

  def test_no_test_file_requires_the_helper_relatively
    offenders = Dir[FoundationSupport.repo_path("test", "**", "*_test.rb")].select do |path|
      File.read(path).match?(/require_relative\s+["'][^"']*test_helper/)
    end

    assert_empty offenders, "test files must use require \"test_helper\""
  end

  def test_foundation_test_files_follow_the_shared_conventions
    files = Dir[FoundationSupport.repo_path("test", "integration", "foundation", "*.rb")]

    refute_empty files
    files.each do |path|
      source = File.read(path)
      name = File.basename(path)

      assert_match(/_test\.rb\z/, name, "#{name} must be named *_test.rb")
      assert_includes source, 'require "test_helper"', "#{name} must require \"test_helper\""
      assert_match(/class Foundation\w+Test < Minitest::Test/, source, "#{name} needs a Foundation-prefixed class")
    end
  end

  def test_source_checkout_declares_runtime_and_development_dependencies
    gemfile = File.read(FoundationSupport.repo_path("Gemfile"))

    assert_includes gemfile, 'gem "base64", ">= 0.2"'
    assert_includes gemfile, 'gem "minitest", ">= 5.0"'
    assert_includes gemfile, 'gem "rake", ">= 13.0"'
  end

  def test_one_off_behavior_check_scripts_are_not_tracked
    ruby_scripts = Dir[FoundationSupport.repo_path("scripts", "*.rb")]
    assert_empty ruby_scripts, "put repeatable behavior assertions under test/, not scripts/"

    documented_script_commands = Dir[
      FoundationSupport.repo_path("README.md"),
      FoundationSupport.repo_path("docs", "**", "*.md")
    ].flat_map do |path|
      File.readlines(path).grep(/ruby\s+scripts\//).map { |line| "#{path.delete_prefix("#{FoundationSupport::REPO_ROOT}/")}: #{line.strip}" }
    end

    assert_empty documented_script_commands, "docs should point reviewers at rake test or focused test files"
  end
end
