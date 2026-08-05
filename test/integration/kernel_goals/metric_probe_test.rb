# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# The probe is the one part of the goal loop that runs real commands. It runs harmless shell
# builtins inside a temp directory: no network, no repository under test, no harness.
class KernelGoalsMetricProbeTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("meringue-metric-probe")
    @probe = Meringue::Goals::MetricProbe.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  attr_reader :probe, :tmpdir

  def test_last_number_parsing_reads_the_metric_out_of_ordinary_output
    result = probe.measure(command: "echo 'TOTAL coverage: 72.4%'", cwd: tmpdir)

    assert_equal 72.4, result.fetch("value")
    assert_equal 0, result.fetch("exit_status")
    refute result.fetch("timed_out")
    assert_includes result.fetch("stdout_tail"), "TOTAL"
  end

  def test_regex_parsing_uses_the_requested_capture_group
    result = probe.measure(
      command: "echo 'files 12 offenses 3 total'",
      cwd: tmpdir,
      parse: { "type" => "regex", "pattern" => "offenses (\\d+)", "capture" => 1 }
    )

    assert_equal 3.0, result.fetch("value")
  end

  def test_a_pattern_that_does_not_match_is_a_parse_error_not_a_crash
    result = probe.measure(
      command: "echo 'nothing here'",
      cwd: tmpdir,
      parse: { "type" => "regex", "pattern" => "coverage (\\d+)" }
    )

    assert_nil result.fetch("value")
    assert_equal "metric pattern did not match", result.fetch("parse_error")
  end

  def test_json_path_parsing_walks_nested_documents
    result = probe.measure(
      command: %(echo '{"totals":{"line":81.5}}'),
      cwd: tmpdir,
      parse: { "type" => "json_path", "path" => "totals.line" }
    )

    assert_equal 81.5, result.fetch("value")
  end

  def test_exit_status_parsing_turns_a_pass_fail_command_into_a_metric
    green = probe.measure(command: "true", cwd: tmpdir, parse: { "type" => "exit_status" })
    red = probe.measure(command: "false", cwd: tmpdir, parse: { "type" => "exit_status" })

    assert_equal 1.0, green.fetch("value")
    assert_equal 0.0, red.fetch("value")
    assert_equal 1, red.fetch("exit_status")
  end

  def test_a_failing_command_reports_its_exit_status_and_stderr
    result = probe.measure(command: "echo boom >&2; exit 3", cwd: tmpdir)

    assert_equal 3, result.fetch("exit_status")
    assert_includes result.fetch("stderr_tail"), "boom"
  end

  def test_a_command_that_hangs_is_killed_at_the_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = probe.measure(command: "sleep 30", cwd: tmpdir, timeout: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.fetch("timed_out"), "a wedged metric command must not block the reconcile tick"
    assert_operator elapsed, :<, 20, "the probe must return near its timeout"
  end

  def test_output_is_capped_so_a_chatty_command_cannot_bloat_state
    result = probe.measure(command: "yes abcdefghij | head -c 50000", cwd: tmpdir)

    assert_operator result.fetch("stdout_tail").length, :<=, Meringue::Goals::Record::OUTPUT_TAIL_LIMIT + 1
  end

  def test_a_missing_workspace_is_reported_instead_of_raising
    result = probe.measure(command: "echo 1", cwd: File.join(tmpdir, "nope"))

    assert_includes result.fetch("error"), "does not exist"
    assert_nil result.fetch("value", nil)
  end

  def test_guardrails_are_pass_fail_only
    passing = probe.check_guardrail(command: "true", cwd: tmpdir)
    failing = probe.check_guardrail(command: "exit 2", cwd: tmpdir)

    assert passing.fetch("passed")
    refute failing.fetch("passed")
    assert_equal "exit_zero", passing.fetch("expect")
  end

  # The same bounded runner backs a queued worker's `after_command` wait condition. It reports
  # three distinct things: passed, not yet, and "this can never be judged".
  def test_a_wait_condition_gate_separates_passed_not_yet_and_unusable
    passed = probe.check_gate(command: "true", cwd: tmpdir)
    not_yet = probe.check_gate(command: "exit 1", cwd: tmpdir)
    unusable = probe.check_gate(command: "true", cwd: File.join(tmpdir, "nope"))

    assert passed.fetch("passed")
    refute passed.fetch("unusable")
    refute not_yet.fetch("passed")
    refute not_yet.fetch("unusable"), "a non-zero exit means not yet, not broken"
    refute unusable.fetch("passed")
    assert unusable.fetch("unusable")
  end

  def test_an_output_matching_gate_ignores_the_exit_status
    matched = probe.check_gate(command: "echo APPROVED", cwd: tmpdir, expect: "output_matches", pattern: "APPROVED")
    unmatched = probe.check_gate(command: "echo REVIEW_REQUIRED", cwd: tmpdir, expect: "output_matches", pattern: "APPROVED")
    broken = probe.check_gate(command: "echo APPROVED", cwd: tmpdir, expect: "output_matches", pattern: "APPROVED(")

    assert matched.fetch("passed")
    refute unmatched.fetch("passed")
    refute unmatched.fetch("unusable")
    # A pattern that cannot compile can never match, so it is unusable rather than "not yet".
    refute broken.fetch("passed")
    assert broken.fetch("unusable")
    assert_includes broken.fetch("parse_error"), "invalid wait-condition pattern"
  end

  def test_a_wedged_gate_command_is_killed_at_its_timeout
    result = probe.check_gate(command: "sleep 30", cwd: tmpdir, timeout: 1)

    assert result.fetch("timed_out")
    assert result.fetch("unusable")
    refute result.fetch("passed")
  end

  def test_the_workspace_fingerprint_changes_with_a_commit_and_is_nil_outside_git
    assert_nil probe.workspace_fingerprint(cwd: tmpdir), "a non-repository has no fingerprint"

    repo = File.join(tmpdir, "repo")
    FileUtils.mkdir_p(repo)
    git(repo, "init", "--initial-branch=main")
    git(repo, "config", "user.email", "meringue-tests@example.com")
    git(repo, "config", "user.name", "Meringue Tests")
    File.write(File.join(repo, "a.txt"), "one\n")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "first")
    first = probe.workspace_fingerprint(cwd: repo)

    assert_equal first, probe.workspace_fingerprint(cwd: repo), "the same tree fingerprints the same"

    File.write(File.join(repo, "a.txt"), "two\n")
    dirty = probe.workspace_fingerprint(cwd: repo)
    refute_equal first, dirty, "uncommitted work changes the fingerprint"

    git(repo, "commit", "-am", "second")
    refute_equal first, probe.workspace_fingerprint(cwd: repo), "a new commit changes the fingerprint"
  end

  def git(root, *args)
    env = {
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_AUTHOR_NAME" => "Meringue Tests",
      "GIT_AUTHOR_EMAIL" => "meringue-tests@example.com",
      "GIT_COMMITTER_NAME" => "Meringue Tests",
      "GIT_COMMITTER_EMAIL" => "meringue-tests@example.com"
    }
    stdout, stderr, status = Open3.capture3(env, "git", "-C", root.to_s, *args.map(&:to_s))
    raise "git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end
end
