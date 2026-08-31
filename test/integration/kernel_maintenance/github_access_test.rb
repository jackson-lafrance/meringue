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

  def test_access_check_runs_by_default_without_an_opt_in
    write_config
    forge = KernelMaintenanceSupport::StubForgeClient.new(
      access_results: { "acme/app" => { "outcome" => "success", "message" => "read access confirmed" } }
    )
    engine = build_engine(forge_client: forge)

    result = engine.apply("type" => "TestGitHubAccess", "payload" => { "repository" => "acme/app" })

    assert_equal "success", result.dig("result", "outcome")
    assert_nil Meringue::Config.load(path: tmp_path("config.toml")).value("experiments", "github_support")
  end

  def test_enabled_access_check_calls_the_existing_client_with_a_bound
    write_config
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

  def test_access_check_runs_from_setup_without_persisting_an_experiment
    write_config
    forge = KernelMaintenanceSupport::StubForgeClient.new(
      access_results: { "acme/app" => { "outcome" => "success", "message" => "read access confirmed" } }
    )
    engine = build_engine(forge_client: forge)

    result = engine.apply(
      "type" => "TestGitHubAccess",
      "payload" => { "repository" => "acme/app", "draft_github_support" => true }
    )

    assert_equal "success", result.dig("result", "outcome")
    assert_equal 1, forge.access_calls.length
    assert_nil Meringue::Config.load(path: tmp_path("config.toml")).value("experiments", "github_support")
  end

  def test_malformed_origin_is_reported_without_calling_github
    write_config
    forge = KernelMaintenanceSupport::StubForgeClient.new
    engine = build_engine(forge_client: forge)

    result = engine.apply(
      "type" => "TestGitHubAccess",
      "payload" => { "remote" => "git@gitlab.example.com:acme/app.git" }
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal "malformed_remote", result.dig("result", "outcome")
    assert_match(/frontend can resolve/, result.fetch("message"))
    assert_empty forge.access_calls
  end

  def test_each_client_outcome_is_returned_and_retry_is_safe
    write_config
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

  def write_config
    File.write(tmp_path("config.toml"), "[settings]\nschema_version = 3\n")
  end
end
