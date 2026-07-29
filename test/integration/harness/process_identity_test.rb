# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# A persisted pid alone is never enough evidence to signal a process: pids are
# reused. ProcessIdentity is the liveness + identity gate in front of takeover.
class HarnessProcessIdentityTest < HarnessIntegrationTest
  Identity = Meringue::Harness::ProcessIdentity

  def test_alive_for_current_process
    assert Identity.alive?(Process.pid)
    assert Identity.alive?(Process.pid.to_s)
  end

  def test_alive_is_false_for_blank_or_invalid_pids
    refute Identity.alive?(nil)
    refute Identity.alive?("")
    refute Identity.alive?("   ")
    refute Identity.alive?("not-a-pid")
  end

  def test_alive_is_false_after_the_process_exits
    pid = spawn_idle_ruby_process(seconds: 30)
    assert Identity.alive?(pid)

    reap_pid(pid)
    wait_until(timeout: 5.0) { !Identity.alive?(pid) }

    refute Identity.alive?(pid)
  end

  def test_describe_returns_pid_parent_command_and_start_time
    pid = spawn_idle_ruby_process(seconds: 30)

    description = wait_until(timeout: 5.0) { Identity.describe(pid) }

    refute_nil description, "ps should describe a live child process"
    assert_equal pid, description.fetch("pid")
    assert_equal Process.pid, description.fetch("ppid")
    assert_equal "ruby", File.basename(description.fetch("command").split(/\s+/).first)
    assert_kind_of Time, description.fetch("started_at")
    assert_operator (Time.now.utc - description.fetch("started_at")).abs, :<, 300
  end

  def test_describe_rejects_non_numeric_and_dead_pids
    assert_nil Identity.describe(nil)
    assert_nil Identity.describe("")
    assert_nil Identity.describe("abc")
    assert_nil Identity.describe(0)
    assert_nil Identity.describe(-1)

    pid = spawn_idle_ruby_process(seconds: 30)
    reap_pid(pid)
    wait_until(timeout: 5.0) { Identity.describe(pid).nil? }

    assert_nil Identity.describe(pid)
  end

  def test_matches_live_process_by_command_name
    pid = spawn_idle_ruby_process(seconds: 30)
    wait_until(timeout: 5.0) { Identity.describe(pid) }

    assert Identity.matches?(pid, command: "ruby")
    assert Identity.matches?(pid, command: HarnessSupport::RUBY_BIN)
    assert Identity.matches?(pid, command: [HarnessSupport::RUBY_BIN, "script.rb"])
    assert Identity.matches?(pid), "a nil command should not veto identity"
  end

  def test_matches_is_false_for_a_different_command
    pid = spawn_idle_ruby_process(seconds: 30)
    wait_until(timeout: 5.0) { Identity.describe(pid) }

    refute Identity.matches?(pid, command: "pi")
    refute Identity.matches?(pid, command: "/usr/local/bin/claude")
  end

  def test_matches_uses_recorded_start_time_to_detect_pid_reuse
    pid = spawn_idle_ruby_process(seconds: 30)
    description = wait_until(timeout: 5.0) { Identity.describe(pid) }
    refute_nil description

    assert Identity.matches?(pid, command: "ruby", started_at: description.fetch("started_at").iso8601)
    assert Identity.matches?(pid, command: "ruby", started_at: description.fetch("started_at"))
    refute Identity.matches?(pid, command: "ruby", started_at: (description.fetch("started_at") - 3600).iso8601),
           "a start time far from the observed one means the pid was reused"
    assert Identity.matches?(pid, command: "ruby", started_at: "not a timestamp"),
           "an unparseable recorded start time falls back to the command check"
  end

  def test_matches_is_false_for_dead_processes
    pid = spawn_idle_ruby_process(seconds: 30)
    reap_pid(pid)
    wait_until(timeout: 5.0) { Identity.describe(pid).nil? }

    refute Identity.matches?(pid, command: "ruby")
  end

  def test_command_matches_handles_prefixes_and_blanks
    assert Identity.command_matches?("/usr/bin/ruby", "ruby")
    assert Identity.command_matches?("/usr/bin/ruby31", "ruby")
    assert Identity.command_matches?("ruby", "/opt/bin/ruby31")
    assert Identity.command_matches?("anything", nil)
    assert Identity.command_matches?("anything", "  ")
    refute Identity.command_matches?("", "ruby")
    refute Identity.command_matches?("node", "ruby")
  end

  def test_executable_name_extracts_basename
    assert_equal "pi", Identity.executable_name("/opt/homebrew/bin/pi --mode rpc")
    assert_equal "pi", Identity.executable_name(["/opt/homebrew/bin/pi", "--mode"])
    assert_nil Identity.executable_name("")
    assert_nil Identity.executable_name(nil)
  end
end
