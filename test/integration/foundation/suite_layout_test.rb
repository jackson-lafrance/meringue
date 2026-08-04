# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# Guards the plumbing the whole suite depends on: the Rakefile test task, the
# test-file discovery glob, the shared conventions, and gemspec packaging.
class FoundationSuiteLayoutTest < Minitest::Test
  def test_rakefile_defines_a_default_test_task
    status, stdout, = FoundationSupport.run_ruby(
      "-e",
      'require "rake"; load "Rakefile"; print Rake::Task.tasks.map(&:name).sort.join(",")'
    )

    assert_equal 0, status
    assert_equal "default,test", stdout.strip
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

  def test_gemspec_packages_the_expected_files
    spec = Gem::Specification.load(FoundationSupport.repo_path("meringue.gemspec"))

    refute_nil spec
    assert_equal "meringue", spec.name
    assert_equal Meringue::VERSION, spec.version.to_s
    assert_equal ["meringue"], spec.executables
    assert_equal ["lib"], spec.require_paths

    %w[
      AGENTS.md
      README.md
      bin/meringue
      docs/testing.md
      lib/meringue.rb
      lib/meringue/cli.rb
      lib/meringue/kernel/engine.rb
    ].each do |path|
      assert_includes spec.files, path
    end
  end

  def test_gemspec_does_not_ship_the_test_suite
    spec = Gem::Specification.load(FoundationSupport.repo_path("meringue.gemspec"))
    packaged_tests = spec.files.select { |path| path.start_with?("test/") }

    assert_empty packaged_tests
  end

  def test_removed_smoke_script_is_gone_and_undocumented
    refute File.exist?(FoundationSupport.repo_path("scripts", "head_loop_smoke.rb")),
           "scripts/head_loop_smoke.rb was replaced by test/integration/foundation"

    docs = File.read(FoundationSupport.repo_path("docs", "agent_workspace_integration.md"))

    refute_includes docs, "head_loop_smoke"
    assert_includes docs, "rake test"
  end
end
