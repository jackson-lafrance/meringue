# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# First-run setup ends with one kernel command so the "setup has run" marker is
# written by the kernel, validated, journaled, and logged like every other
# config write, instead of the TUI quietly writing a second copy of the config
# file behind `--config PATH`.
class KernelCoreOnboardingMarkerTest < Minitest::Test
  include KernelCoreSupport

  def config_path
    File.join(tmp_root, "config.toml")
  end

  def saved_config
    Meringue::Config.load(path: config_path)
  end

  def test_completing_setup_records_the_marker_in_the_sandbox_config
    refute File.exist?(config_path), "the marker must not be written before setup runs"

    result = apply_command("CompleteOnboarding", "outcome" => "completed")

    assert_accepted(result)
    assert_equal "completed", result.fetch("target_id")
    assert_includes result.fetch("message"), config_path
    assert_equal Meringue::Config::ONBOARDING_VERSION, result.fetch("result").fetch("onboarding_version")

    config = saved_config
    assert_equal Meringue::Config::ONBOARDING_VERSION, config.onboarding_version
    assert_equal "completed", config.onboarding_outcome
    refute_empty config.value("onboarding", "completed_at").to_s
    assert Meringue::TUI::Onboarding.completed?(config)

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "info", entry.fetch("level")
    assert_equal "completed", entry.fetch("details").fetch("outcome")
  end

  # Skipping is a real outcome, not an absence of one: setup must not reopen on
  # the next launch just because the user pressed Esc.
  def test_skipping_setup_also_records_the_marker
    result = apply_command("CompleteOnboarding", "outcome" => "skipped")

    assert_accepted(result)
    assert_equal "skipped", saved_config.onboarding_outcome
    assert Meringue::TUI::Onboarding.completed?(saved_config)
    assert_includes result.fetch("message"), "run /setup any time"
  end

  def test_recording_the_marker_twice_is_idempotent_and_keeps_other_settings
    Meringue::Config.save_tui_theme!("gruvbox", path: config_path)

    apply_command("CompleteOnboarding", "outcome" => "completed")
    apply_command("CompleteOnboarding", "outcome" => "skipped")

    config = saved_config
    assert_equal "skipped", config.onboarding_outcome
    assert_equal Meringue::Config::ONBOARDING_VERSION, config.onboarding_version
    assert_equal "gruvbox", config.value("tui", "colorscheme"), "the marker must not rewrite other settings"
  end

  def test_settings_finish_saves_role_defaults_experiment_and_marker_atomically
    baseline = Meringue::Config::Store.new(path: config_path).fingerprint
    result = apply_command(
      "SaveConfiguration",
      "base_fingerprint" => baseline,
      "changes" => {
        "agent.head_harness" => "claude",
        "agent.worker_harness" => "pi",
        "experiments.split_agent_defaults" => true,
        "agent.head_model" => "openai/gpt-5.6-sol",
        "agent.worker_model" => "anthropic/claude-opus-5",
        "experiments.github_support" => true
      },
      "onboarding_outcome" => "completed"
    )

    assert_accepted(result)
    config = saved_config
    assert_equal "completed", config.onboarding_outcome
    assert_equal "claude", config.setting("agent.head_harness", env: {})
    assert_equal "pi", config.setting("agent.worker_harness", env: {})
    assert_equal "openai/gpt-5.6-sol", config.setting("agent.head_model", env: {})
    assert_equal "anthropic/claude-opus-5", config.setting("agent.worker_model", env: {})
    assert_equal true, config.value("experiments", "github_support")
    assert_equal "completed", result.dig("result", "onboarding_outcome")

    metadata = persisted_state.fetch("metadata")
    assert_equal "claude", metadata.fetch("active_head_harness")
    assert_equal "pi", metadata.fetch("active_worker_harness")
    assert_equal "openai/gpt-5.6-sol", metadata.dig("agent_session_defaults", "roles", "head", "model")
    assert_equal "anthropic/claude-opus-5", metadata.dig("agent_session_defaults", "roles", "worker", "model")
  end

  def test_settings_skip_records_explicit_experiment_default_without_role_changes
    baseline = Meringue::Config::Store.new(path: config_path).fingerprint
    result = apply_command(
      "SaveConfiguration",
      "base_fingerprint" => baseline,
      "changes" => { "experiments.github_support" => false },
      "onboarding_outcome" => "skipped"
    )

    assert_accepted(result)
    assert_equal "skipped", saved_config.onboarding_outcome
    assert_equal false, saved_config.value("experiments", "github_support")
    assert_equal Meringue::Harness::Registry::DEFAULT_MODEL, saved_config.setting("agent.head_model", env: {})
    assert_equal Meringue::Harness::Registry::DEFAULT_MODEL, saved_config.setting("agent.worker_model", env: {})
  end

  def test_save_configuration_rejects_an_unknown_setup_outcome_without_writing
    baseline = Meringue::Config::Store.new(path: config_path).fingerprint
    result = apply_command(
      "SaveConfiguration",
      "base_fingerprint" => baseline,
      "changes" => { "experiments.github_support" => false },
      "onboarding_outcome" => "maybe"
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors").join(" "), "setup.outcome"
    refute File.exist?(config_path)
  end

  def test_an_unknown_outcome_is_rejected_and_writes_nothing
    result = apply_command("CompleteOnboarding", "outcome" => "maybe")

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors").join(" "), "outcome must be one of"
    refute File.exist?(config_path)
  end

  # A missing outcome is the ordinary "the user finished the flow" case.
  def test_a_missing_outcome_defaults_to_completed
    apply_command("CompleteOnboarding", {})

    assert_equal "completed", saved_config.onboarding_outcome
  end

  # It is UI lifecycle: a head cannot know whether a human ever saw the flow.
  def test_the_marker_command_is_not_head_proposable
    refute_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, "CompleteOnboarding"
  end

  def test_a_fresh_config_has_no_marker_so_the_first_launch_is_a_first_run
    refute Meringue::TUI::Onboarding.completed?(Meringue::Config.load(path: config_path))
    assert_equal 0, Meringue::Config.load(path: config_path).onboarding_version
  end
end
