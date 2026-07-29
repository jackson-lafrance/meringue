# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Read-only OS process inspection: the evidence reconciliation relies on before
# treating a persisted pid as a live harness transport. No harness is started
# here; only this test process and a reaped child are inspected.
class KernelMaintenanceProcessIdentityTest < Minitest::Test
  include KernelMaintenanceSupport

  Identity = Meringue::Harness::ProcessIdentity

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_alive_recognizes_this_process_and_rejects_missing_evidence
    assert Identity.alive?(Process.pid)
    assert Identity.alive?(Process.pid.to_s)
    refute Identity.alive?(nil)
    refute Identity.alive?("")
    refute Identity.alive?("not-a-pid")
  end

  def test_alive_is_false_for_a_reaped_child_pid
    refute Identity.alive?(reaped_pid)
  end

  def test_describe_returns_pid_parent_command_and_start_time_for_a_live_process
    description = Identity.describe(Process.pid)

    refute_nil description, "ps should describe the running test process"
    assert_equal Process.pid, description.fetch("pid")
    assert_equal Process.ppid, description.fetch("ppid")
    refute_empty description.fetch("command").to_s
    assert_kind_of Time, description.fetch("started_at")
  end

  def test_describe_rejects_invalid_and_dead_pids
    assert_nil Identity.describe(nil)
    assert_nil Identity.describe("")
    assert_nil Identity.describe("abc")
    assert_nil Identity.describe(0)
    assert_nil Identity.describe(-1)
    assert_nil Identity.describe(reaped_pid)
  end

  def test_matches_requires_the_recorded_command_to_look_like_the_live_process
    command = File.basename(Identity.describe(Process.pid).fetch("command").to_s.split(/\s+/).first.to_s)

    assert Identity.matches?(Process.pid, command: command)
    assert Identity.matches?(Process.pid, command: nil), "no recorded command means the pid alone is accepted"
    refute Identity.matches?(Process.pid, command: "definitely-not-this-process")
    refute Identity.matches?(reaped_pid, command: command)
  end

  def test_matches_compares_recorded_start_time_within_tolerance
    described = Identity.describe(Process.pid)
    command = File.basename(described.fetch("command").to_s.split(/\s+/).first.to_s)
    started_at = described.fetch("started_at")

    assert Identity.matches?(Process.pid, command: command, started_at: started_at.iso8601)
    refute Identity.matches?(
      Process.pid,
      command: command,
      started_at: (started_at - (Identity::START_TIME_TOLERANCE_SECONDS + 60)).iso8601
    )
    assert Identity.matches?(Process.pid, command: command, started_at: "not a timestamp"),
           "an unparsable recorded start time falls back to the command match"
  end

  def test_executable_name_normalizes_string_and_array_commands
    assert_equal "pi", Identity.executable_name("pi")
    assert_equal "pi", Identity.executable_name("/usr/local/bin/pi --mode rpc")
    assert_equal "pi", Identity.executable_name(["/usr/local/bin/pi", "--mode", "rpc"])
    assert_nil Identity.executable_name("")
    assert_nil Identity.executable_name(nil)
  end

  def test_command_matches_accepts_prefixes_and_rejects_unrelated_commands
    assert Identity.command_matches?("/usr/local/bin/pi --mode rpc", "pi")
    assert Identity.command_matches?("pi", "/usr/local/bin/pi")
    assert Identity.command_matches?("anything", nil)
    refute Identity.command_matches?("", "pi")
    refute Identity.command_matches?("node", "pi")
  end
end
