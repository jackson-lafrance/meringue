# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# Pi's `auth check` is a separate CLI call per provider during a model catalog
# refresh, so a single hung check used to stall the whole refresh: `Timeout`
# around `Open3.capture3` never actually bounded the child. These tests pin the
# real process timeout, its kill path, and the exit-status-aware reason codes,
# all against the scripted Pi stub so no real harness is involved.
class HarnessPiAuthCheckTimeoutTest < HarnessIntegrationTest
  Catalog = Meringue::Harness::ModelCatalog

  SINGLE_MODEL = [
    { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5", "reasoning" => true }
  ].freeze

  def test_hung_auth_check_is_killed_and_reported_as_timed_out_without_stderr_noise
    pid_file = File.join(tmpdir, "auth-check.pid")
    client, = build_pi_client(
      tmpdir,
      stub_config: { "available_models" => SINGLE_MODEL, "auth_sleep" => 5, "auth_pid_file" => pid_file },
      model_auth_timeout: 0.3
    )

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stderr_output, catalog = capturing_stderr { client.available_models(cwd: tmpdir) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.0, "auth check timeout did not bound the call (#{elapsed.round(2)}s)"
    assert catalog.available?, catalog.to_h.inspect
    assert_equal(
      { "status" => Catalog::AUTHENTICATION_UNKNOWN, "reason" => "auth_check_timed_out" },
      catalog.authentication.fetch("providers").fetch("anthropic")
    )
    assert_equal Catalog::AUTHENTICATION_UNKNOWN, catalog.authentication_for("anthropic/claude-opus-5")
    refute_includes stderr_output, "terminated with exception"
    assert_empty stderr_output.strip

    assert File.file?(pid_file), "stub never recorded its auth check pid"
    assert_process_gone(File.read(pid_file).to_i)
  end

  def test_non_zero_exit_without_json_is_reported_as_auth_check_failed
    client, = build_pi_client(
      tmpdir,
      stub_config: { "available_models" => SINGLE_MODEL, "auth_exit_code" => 3, "auth_raw_stdout" => "usage: pi auth check\n" }
    )

    catalog = client.available_models(cwd: tmpdir)

    assert_equal(
      { "status" => Catalog::AUTHENTICATION_UNKNOWN, "reason" => "auth_check_failed" },
      catalog.authentication.fetch("providers").fetch("anthropic")
    )
  end

  def test_zero_exit_without_json_is_reported_as_invalid_auth_response
    client, = build_pi_client(
      tmpdir,
      stub_config: { "available_models" => SINGLE_MODEL, "auth_raw_stdout" => "not json\n" }
    )

    catalog = client.available_models(cwd: tmpdir)

    assert_equal(
      { "status" => Catalog::AUTHENTICATION_UNKNOWN, "reason" => "invalid_auth_response" },
      catalog.authentication.fetch("providers").fetch("anthropic")
    )
  end

  def test_successful_auth_check_still_returns_the_stub_status_and_source
    client, = build_pi_client(
      tmpdir,
      stub_config: {
        "available_models" => SINGLE_MODEL,
        "auth_statuses" => { "anthropic" => { "status" => "ready", "source" => "stored" } }
      }
    )

    catalog = client.available_models(cwd: tmpdir)

    assert_equal(
      { "status" => Catalog::AUTHENTICATED, "source" => "stored" },
      catalog.authentication.fetch("providers").fetch("anthropic")
    )
    assert_equal Catalog::AUTHENTICATED, catalog.authentication_for("anthropic/claude-opus-5")
  end

  def test_model_auth_timeout_defaults_to_the_client_constant
    client, = build_pi_client(tmpdir)

    assert_in_delta Meringue::Harness::PiClient::DEFAULT_MODEL_AUTH_TIMEOUT, client.model_auth_timeout, 0.001
  end

  private

  # Reader threads and the killed child must never print to the parent's
  # stderr: in the TUI that output lands on top of the rendered screen.
  def capturing_stderr
    original = $stderr
    buffer = StringIO.new
    $stderr = buffer
    result = yield
    [buffer.string, result]
  ensure
    $stderr = original
  end

  def assert_process_gone(pid, wait: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      Process.kill(0, pid)
      flunk "auth check process #{pid} is still alive" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    rescue Errno::ESRCH
      break
    end
  end
end
