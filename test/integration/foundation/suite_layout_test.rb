# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# Guards the plumbing the whole suite depends on: the Rakefile test task, the
# test-file discovery glob, the shared conventions, and source dependencies.
class FoundationSuiteLayoutTest < Minitest::Test
  def test_rakefile_defines_a_default_test_task
    status, stdout, = FoundationSupport.run_ruby(
      "-e",
      'require "rake"; load "Rakefile"; print Rake::Task.tasks.map(&:name).sort.join(",")'
    )

    assert_equal 0, status
    assert_equal ["default", "test"], stdout.strip.split(",")
  end

  def test_rakefile_wires_lib_and_test_onto_the_load_path
    rakefile = File.read(FoundationSupport.repo_path("Rakefile"))

    assert_includes rakefile, "Rake::TestTask.new(:test)"
    assert_includes rakefile, 't.libs = ["lib", "test"]'
    assert_includes rakefile, 't.test_files = FileList["test/**/*_test.rb"]'
    assert_includes rakefile, "task default: :test"
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
