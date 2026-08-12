# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# The two bounds a provisioning command runs under, and what Meringue does with each of them.
#
# A `git worktree add` that is checking out half a million files is slow, not broken: the old flat
# 60s budget killed it and destroyed the worker. The bounds under test here are:
#
#   * a stall bound - no output at all for N seconds means the command is stuck;
#   * an absolute bound - a command that keeps printing is still killed eventually, so the stall
#     detector can never degrade into a hang.
#
# Every timing in this file is in fractions of a second, and no test waits for a production
# default: the bounds are injected.
class WorkspaceManagerCheckoutTimeoutTest < Minitest::Test
  include WorkspaceSupport

  def test_a_quiet_command_is_killed_by_the_stall_bound
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Meringue::Workspace::Manager::CommandTimeout) do
      manager.send(:run_command, "/bin/sh", "-c", "sleep 30", timeout: 30, stall_timeout: 0.3, deadline: false)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert error.stalled?, "expected a stall, got #{error.reason}"
    assert_in_delta 0.3, error.timeout, 0.001
    assert_operator elapsed, :<, 10, "the stall bound must fire long before the absolute bound"
    assert_includes error.message, "produced no output for 0.3 seconds"
  end

  # The regression this issue is about: output means the command is working, so it must survive a
  # stall bound that is shorter than its total runtime.
  def test_a_slow_but_progressing_command_is_not_killed
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")
    # 1.2s of work reported every 0.1s. The stall bound is well under the total runtime (so the
    # test really exercises "survives a stall bound shorter than the command") and well over the
    # gap between two reports (so a loaded CI machine cannot make it flake).
    script = "i=0; while [ $i -lt 12 ]; do printf 'Updating files: %s%%\\r' $i >&2; sleep 0.1; i=$((i+1)); done"

    result = manager.send(:run_command, "/bin/sh", "-c", script, timeout: 30, stall_timeout: 0.6, deadline: false)

    assert result.fetch("status").success?, "a command that keeps reporting progress must not be killed"
    assert_includes result.fetch("stderr"), "Updating files"
  end

  # ...but progress can never buy unlimited time, so the absolute bound still fires.
  def test_an_endlessly_progressing_command_is_still_killed_by_the_absolute_bound
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")
    script = "while true; do printf 'still going\\r' >&2; sleep 0.05; done"

    error = assert_raises(Meringue::Workspace::Manager::CommandTimeout) do
      manager.send(:run_command, "/bin/sh", "-c", script, timeout: 0.6, stall_timeout: 5, deadline: false)
    end

    refute error.stalled?, "constant output must not be reported as a stall"
    assert_equal Meringue::Workspace::Manager::CommandTimeout::BUDGET, error.reason
    assert_in_delta 0.6, error.timeout, 0.001
  end

  def test_a_long_running_command_reports_progress_to_its_caller
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root", progress_interval: 0.15)
    reports = []
    script = "i=0; while [ $i -lt 12 ]; do printf 'Updating files: 4%% (1/2)\\r' >&2; sleep 0.05; i=$((i+1)); done"

    manager.send(
      :run_command, "/bin/sh", "-c", script,
      timeout: 30, stall_timeout: 5, deadline: false, progress: ->(report) { reports << report }
    )

    refute_empty reports, "a command running past the progress interval must report that it is alive"
    assert_includes reports.first.fetch("detail"), "Updating files"
    assert_operator reports.first.fetch("elapsed"), :>=, 0.15
  end

  def test_command_capture_keeps_bounded_head_and_tail_diagnostics
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")
    bytes = Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES * 4
    script = "printf 'HEAD\\n'; i=0; while [ $i -lt #{bytes} ]; do printf x; i=$((i+1)); done; printf '\\nTAIL\\n'"

    result = manager.send(
      :run_command, "/bin/sh", "-c", script,
      timeout: 30, output_limit: Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES, deadline: false
    )

    assert result.fetch("status").success?
    output = result.fetch("stdout")
    assert_operator output.bytesize, :<=, Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES
    assert_includes output, "HEAD"
    assert_includes output, "output bytes omitted"
    assert_includes output, "TAIL"
    assert_equal bytes + "HEAD\n\nTAIL\n".bytesize, result.dig("diagnostics", "stdout_bytes")
    assert result.dig("diagnostics", "truncated")
  end

  def test_command_capture_is_complete_when_the_caller_does_not_request_a_diagnostic_cap
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")
    bytes = Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES * 2

    result = manager.send(
      :run_command, "/usr/bin/ruby", "-e", "$stdout.write('x' * #{bytes})",
      timeout: 30, deadline: false
    )

    assert_equal bytes, result.fetch("stdout").bytesize
    refute result.dig("diagnostics", "truncated")
  end

  def test_disk_exhaustion_is_detected_even_if_the_signature_falls_in_the_omitted_middle
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")
    padding = "x" * Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES
    script = "$stderr.write(#{padding.inspect} + 'No space left on device' + #{padding.inspect})"

    result = manager.send(
      :run_command, "/usr/bin/ruby", "-e", script,
      timeout: 30, output_limit: Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES, deadline: false
    )

    refute_includes result.fetch("stderr"), "No space left on device",
                    "this test needs the signature to be outside the retained head/tail"
    assert result.dig("diagnostics", "disk_exhausted")
  end

  def test_disk_exhaustion_is_detected_when_the_signature_spans_reader_chunks
    buffer_class = Meringue::Workspace::Manager::DiagnosticBuffer
    monitor_class = Meringue::Workspace::Manager::OutputMonitor
    monitor = monitor_class.new
    buffer = buffer_class.new(limit: 16, on_match: ->(chunk) { monitor.record(chunk) })

    buffer << "prefix No space left on de"
    buffer << "vice suffix"

    assert monitor.disk_exhausted?
  end

  def test_command_capture_normalizes_invalid_utf8_before_it_can_reach_json_state
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")

    result = manager.send(
      :run_command, "/usr/bin/ruby", "-e", '$stdout.binmode; $stdout.write("ok\\xfftail".b)',
      timeout: 30, deadline: false
    )

    assert result.fetch("stdout").valid_encoding?
    assert_includes result.fetch("stdout"), "ok"
    assert_includes result.fetch("stdout"), "tail"
  end

  def test_progress_detail_is_bounded_before_the_callback_can_persist_it
    manager = Meringue::Workspace::Manager.new(
      root_path: "/tmp/unused-workspace-root", progress_interval: 0.05
    )
    reports = []
    script = "printf '#{'x' * 4_000}\\r' >&2; sleep 0.15"

    manager.send(
      :run_command, "/bin/sh", "-c", script,
      timeout: 30, stall_timeout: 5, deadline: false, progress: ->(report) { reports << report }
    )

    refute_empty reports
    assert_operator reports.first.fetch("detail").bytesize, :<=,
                    Meringue::Workspace::Manager::PROGRESS_DETAIL_LIMIT_BYTES + 80
  end

  def test_the_default_checkout_bounds_are_far_larger_than_the_plumbing_budget
    manager = Meringue::Workspace::Manager.new(root_path: "/tmp/unused-workspace-root")

    assert_equal 60.0, manager.command_timeout, "short git plumbing keeps a tight budget"
    assert_operator manager.checkout_stall_timeout, :>, manager.command_timeout
    assert_operator manager.checkout_timeout, :>, manager.checkout_stall_timeout
    # Both bounds are finite: provisioning may be slow, it may never be unbounded.
    assert_operator manager.checkout_timeout, :<=, 3600
    assert_equal manager.checkout_timeout, manager.allocation_budget
  end

  def test_a_stall_bound_above_the_absolute_bound_is_clamped_so_it_can_still_fire
    manager = Meringue::Workspace::Manager.new(
      root_path: "/tmp/unused-workspace-root", checkout_timeout: 30, checkout_stall_timeout: 600
    )

    assert_equal 30.0, manager.checkout_stall_timeout
  end

  def test_config_overrides_the_bounds_and_ignores_nonsense
    config = WorkspaceSupport::StubConfig.new(
      "workspace" => {
        "git_command_timeout" => 15,
        "worktree_stall_timeout" => 45,
        "worktree_checkout_timeout" => 900
      }
    )

    manager = Meringue::Workspace::Manager.from_config(config, root_path: "/tmp/unused-workspace-root")

    assert_equal 15.0, manager.command_timeout
    assert_equal 45.0, manager.checkout_stall_timeout
    assert_equal 900.0, manager.checkout_timeout

    garbage = Meringue::Workspace::Manager.from_config(
      WorkspaceSupport::StubConfig.new("workspace" => { "worktree_checkout_timeout" => "soon" }),
      root_path: "/tmp/unused-workspace-root"
    )
    assert_equal Meringue::Workspace::Manager::DEFAULT_CHECKOUT_TIMEOUT.to_f, garbage.checkout_timeout
  end

  # A stuck command is worth one more automatic attempt; a checkout that blew the absolute budget
  # while still working is not, because the retry would cost the same again.
  def test_a_stall_is_classified_as_retryable_and_a_blown_budget_as_resumable
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)

      stalled = allocate_workspace(
        TimingOutManager.new(reason: "stalled", root_path: File.join(tmp, "workspaces")),
        project,
        task_title: "Stuck on a lock"
      )
      exceeded = allocate_workspace(
        TimingOutManager.new(reason: "budget", root_path: File.join(tmp, "workspaces")),
        project,
        task_title: "Enormous but healthy"
      )

      assert_equal "command_stalled", stalled.fetch("failure_kind")
      assert_equal "retry", stalled.fetch("recovery")
      assert_includes stalled.fetch("errors").join(" "), "git worktree add stalled: no output for 0.25 seconds"

      assert_equal "command_timed_out", exceeded.fetch("failure_kind")
      assert_equal "resume", exceeded.fetch("recovery")
      assert_includes exceeded.fetch("errors"), "git worktree add timed out after 0.25 seconds"
    end
  end

  # The whole allocation is bounded, not just each command, and the failure names the command that
  # was actually killed rather than always blaming `git worktree add`.
  def test_the_allocation_budget_bounds_the_whole_attempt
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = Meringue::Workspace::Manager.new(
        root_path: File.join(tmp, "workspaces"), checkout_timeout: 0.001, checkout_stall_timeout: 0.001
      )

      workspace = allocate_workspace(manager, project, task_title: "No time at all")

      refute workspace.fetch("created")
      assert workspace.fetch("timed_out")
      assert_equal "resume", workspace.fetch("recovery")
      refute_empty workspace.fetch("errors")
      assert_match(/timed out after/, workspace.fetch("errors").join(" "))
    end
  end
end
