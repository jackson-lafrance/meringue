# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# Proves the library loads cleanly and exposes the architectural entrypoints
# the rest of the suite uses.
class FoundationLibraryBootTest < Minitest::Test
  def test_version_is_a_sane_semantic_version
    assert_kind_of String, Meringue::VERSION
    assert_match(/\A\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?\z/, Meringue::VERSION)
    assert Gem::Version.correct?(Meringue::VERSION), "VERSION must parse as a Gem::Version"
  end

  def test_root_path_points_at_the_checkout_and_joins_parts
    assert_equal FoundationSupport::REPO_ROOT, Meringue::ROOT
    assert_equal File.join(Meringue::ROOT, "lib", "meringue.rb"), Meringue.root_path("lib", "meringue.rb")
    assert File.file?(Meringue.root_path("lib", "meringue.rb"))
  end

  def test_requiring_meringue_loads_every_library_file
    missing = FoundationSupport.library_files - FoundationSupport.loaded_library_files

    assert_empty missing, "require \"meringue\" did not load: #{missing.join(", ")}"
  end

  def test_public_entrypoints_are_defined
    expected = [
      "Meringue::CLI",
      "Meringue::App",
      "Meringue::Config",
      "Meringue::State::Models",
      "Meringue::State::Store",
      "Meringue::Kernel::Engine",
      "Meringue::Kernel::Command",
      "Meringue::Kernel::Result",
      "Meringue::Heads::Context",
      "Meringue::Heads::ResultParser",
      "Meringue::Heads::FakeRunner",
      "Meringue::Heads::SimpleLoop",
      "Meringue::Harness::FakeClient",
      "Meringue::Harness::Registry",
      "Meringue::Input::SlashCommandParser",
      "Meringue::Workspace::Manager",
      "Meringue::TUI::App"
    ]

    missing = expected.reject { |name| constant_defined?(name) }

    assert_empty missing, "expected constants to be defined after require: #{missing.join(", ")}"
  end

  def test_library_can_be_required_in_a_fresh_process
    status, stdout, = FoundationSupport.run_ruby("-Ilib", "-e", 'require "meringue"; print Meringue::VERSION')

    assert_equal 0, status
    assert_equal Meringue::VERSION, stdout
  end

  # Documents current actual behavior: loading the library under `-w` is free of
  # errors, and the only warnings it emits from this checkout are duplicate
  # method definitions in lib/meringue/kernel/engine.rb (see
  # test/findings/foundation.md). This assertion still passes once those
  # duplicates are removed.
  def test_verbose_load_emits_no_unexpected_warnings
    status, _stdout, stderr = FoundationSupport.run_ruby("-w", "-Ilib", "-e", 'require "meringue"')

    assert_equal 0, status

    local_warnings = stderr.lines.select { |line| line.include?(FoundationSupport::REPO_ROOT) }
    unexpected = local_warnings.reject do |line|
      line.match?(/warning: (?:method redefined; discarding old|previous definition of)/)
    end

    assert_empty unexpected.map(&:strip), "unexpected warnings while loading the library"
  end

  private

  def constant_defined?(name)
    Object.const_get(name)
    true
  rescue NameError
    false
  end
end
