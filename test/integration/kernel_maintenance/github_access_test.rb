# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Kernel coverage uses the injected forge fake so the command can prove its gate,
# repository resolution, result persistence, and bounded timeout contract without
# running git over a real checkout or contacting GitHub.
class KernelMaintenanceGithubAccessTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_enabled_access_check_calls_the_existing_client_with_a_bound
    write_enabled_config
    forge = KernelMaintenanceSupport::StubForgeClient.new(
      access_results: {
        "acme/app" => {
          "outcome" => "success",
          "message" => "GitHub access is ready as octocat; read access to acme/app is confirmed.",
          "identity" => "octocat"
        }
      }
    )
    engine = build_engine(forge_client: forge)

    result = engine.apply(
      "type" => "TestGitHubAccess",
      "payload" => { "repository" => "acme/app" }
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal "success", result.dig("result", "outcome")
    assert_equal "octocat", result.dig("result", "identity")
    assert_equal [{ "repository" => "acme/app", "timeout" => Meringue::Kernel::Engine::GITHUB_ACCESS_TEST_BUDGET_SECONDS }], forge.access_calls
    assert_equal "github_access_test", read_state.fetch("logs").last.fetch("details").fetch("kind")
  end

  def test_disabled_experiment_is_gated_without_calling_github
    write_config(false)
    forge = KernelMaintenanceSupport::StubForgeClient.new
    engine = build_engine(forge_client: forge)

    result = engine.apply("type" => "TestGitHubAccess", "payload" => { "repository" => "acme/app" })

    assert_equal "accepted", result.fetch("status")
    assert_equal "unavailable", result.dig("result", "outcome")
    assert_match(/Enable GitHub support/, result.fetch("message"))
    assert_empty forge.access_calls
    refute File.exist?(state_path), "a disabled check must not create a state/log record"
  end

  def test_malformed_origin_is_reported_without_calling_github
    write_enabled_config
    forge = KernelMaintenanceSupport::StubForgeClient.new
    engine = build_engine(forge_client: forge)

    result = engine.apply(
      "type" => "TestGitHubAccess",
      "payload" => { "remote" => "git@gitlab.example.com:acme/app.git" }
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal "malformed_remote", result.dig("result", "outcome")
    assert_match(/supported GitHub repository URL/, result.fetch("message"))
    assert_empty forge.access_calls
  end

  def test_each_client_outcome_is_returned_and_retry_is_safe
    write_enabled_config
    outcomes = %w[unavailable unauthenticated permission_denied timeout]
    calls = []

    outcomes.each do |outcome|
      forge = KernelMaintenanceSupport::StubForgeClient.new(
        access_results: {
          "acme/app" => { "outcome" => outcome, "message" => "#{outcome} from fake client" }
        }
      )
      engine = build_engine(forge_client: forge)
      result = engine.apply("type" => "TestGitHubAccess", "payload" => { "repository" => "acme/app" })
      calls.concat(forge.access_calls)
      assert_equal "accepted", result.fetch("status")
      assert_equal outcome, result.dig("result", "outcome")
    end

    assert_equal outcomes.length, calls.length
    assert_equal outcomes.length, read_state.fetch("logs").length
  end

  private

  def write_enabled_config
    write_config(true)
  end

  def write_config(enabled)
    File.write(
      tmp_path("config.toml"),
      "[settings]\nschema_version = 1\n[experiments]\ngithub_support = #{enabled}\n"
    )
  end
end
