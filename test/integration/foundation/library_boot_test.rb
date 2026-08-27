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
  # A silently discarded duplicate definition is how `Engine#harness_client` became private
  # and how a whole `prompt_agent` body became dead code, so redefinition warnings are no
  # longer tolerated: any warning from this repository's own files fails the suite.
  def test_verbose_load_emits_no_warnings
    status, _stdout, stderr = FoundationSupport.run_ruby("-w", "-Ilib", "-e", 'require "meringue"')

    assert_equal 0, status

    local_warnings = stderr.lines.select { |line| line.include?(FoundationSupport::REPO_ROOT) }

    assert_empty local_warnings.map(&:strip), "warnings while loading the library"
  end

  # The two accessors an embedder (`Heads::PromptLoop`, `Heads::SimpleLoop`) needs in order to
  # settle spawned workers. They were public readers shadowed by a duplicate pair defined
  # below the engine's `private` keyword, so every caller raised `NoMethodError`.
  def test_the_engine_exposes_its_harness_client_and_head_runner_publicly
    assert Meringue::Kernel::Engine.public_method_defined?(:harness_client)
    assert Meringue::Kernel::Engine.public_method_defined?(:head_runner)
  end

  private

  def constant_defined?(name)
    Object.const_get(name)
    true
  rescue NameError
    false
  end
end
