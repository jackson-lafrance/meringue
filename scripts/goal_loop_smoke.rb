#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs a real goal loop end to end without a real harness.
#
# Everything except the coding agent is real: a real git repository in a temp dir, real
# Meringue kernel state, real worker worktrees, and a real metric command executed by
# Goals::MetricProbe. The "agent" is a fake harness client that commits a small improvement
# to its own worktree, which is exactly what the loop is supposed to measure.
#
#   ruby -Ilib scripts/goal_loop_smoke.rb
#
# It prints the baseline, every iteration's metric/verdict/directive, and the stop reason.

require "fileutils"
require "open3"
require "tmpdir"

require_relative "../lib/meringue"

TMPDIR = Dir.mktmpdir("meringue-goal-smoke")
at_exit { FileUtils.remove_entry(TMPDIR) if Dir.exist?(TMPDIR) }

GIT_ENV = {
  "GIT_CONFIG_GLOBAL" => "/dev/null",
  "GIT_CONFIG_SYSTEM" => "/dev/null",
  "GIT_TERMINAL_PROMPT" => "0",
  "GIT_AUTHOR_NAME" => "Meringue Smoke",
  "GIT_AUTHOR_EMAIL" => "smoke@example.com",
  "GIT_COMMITTER_NAME" => "Meringue Smoke",
  "GIT_COMMITTER_EMAIL" => "smoke@example.com"
}.freeze

def git(root, *args)
  stdout, stderr, status = Open3.capture3(GIT_ENV, "git", "-C", root.to_s, *args.map(&:to_s))
  abort "git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

  stdout
end

# The project under measurement: `metric.txt` holds the current score, and the metric command
# simply prints it. A real goal would run a coverage or lint command here.
project_root = File.join(TMPDIR, "demo-project")
FileUtils.mkdir_p(project_root)
File.write(File.join(project_root, "metric.txt"), "60\n")
git(project_root, "init", "--initial-branch=main")
git(project_root, "add", ".")
git(project_root, "commit", "-m", "initial commit")

# Fake coding agent: each attempt commits +8 to the metric on its own branch, then settles.
class ImprovingAgentClient < Meringue::Harness::FakeClient
  STEP = 8

  def initialize
    @counter = 0
    @sessions = {}
  end

  def harness_name
    "pi"
  end

  def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
    @counter += 1
    improve!(cwd)
    session = {
      "harness" => "pi",
      "pid" => Process.pid,
      "cwd" => cwd,
      "session_id" => "smoke-session-#{@counter}",
      "session_file" => File.join(cwd, ".smoke-session.json"),
      "is_streaming" => false,
      "metadata" => { "session_name" => session_name }
    }
    @sessions[session.fetch("session_id")] = session
    puts "  [agent] #{session_name} worked in #{File.basename(cwd)}"
    session
  end

  def prompt_session(session_ref, _prompt, mode: "normal")
    improve!(session_ref.fetch("cwd"))
    puts "  [agent] continued #{session_ref.fetch("session_id")} (#{mode})"
    session_ref.merge("is_streaming" => false)
  end

  def get_state(session_ref)
    session_ref.merge("is_streaming" => false)
  end

  def read_events(_session_ref) = []
  def last_assistant_text(_session_ref = nil) = "Improved the metric."
  def kill_session(session_ref) = session_ref.merge("killed" => true)
  def abort_session(session_ref) = session_ref.merge("is_streaming" => false)

  private

  def improve!(cwd)
    path = File.join(cwd, "metric.txt")
    return unless File.exist?(path)

    File.write(path, "#{File.read(path).to_i + STEP}\n")
    git(cwd, "commit", "-am", "raise the metric")
  end

  def git(root, *args)
    stdout, stderr, status = Open3.capture3(GIT_ENV, "git", "-C", root.to_s, *args.map(&:to_s))
    abort "agent git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end
end

store = Meringue::State::Store.new(path: File.join(TMPDIR, "state.json"))
engine = Meringue::Kernel::Engine.new(
  store: store,
  harness_client: ImprovingAgentClient.new,
  harness_client_resolver: ->(_agent) { ImprovingAgentClient.new },
  head_runner: Meringue::Heads::FakeRunner.new,
  workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(TMPDIR, "workspaces")),
  cwd: TMPDIR,
  config_path: File.join(TMPDIR, "config.toml")
)

def apply!(engine, type, payload)
  result = engine.apply("type" => type, "payload" => payload)
  abort "#{type} was #{result.fetch("status")}: #{result.fetch("message")} #{result.fetch("errors")}" unless result.fetch("status") == "accepted"

  result
end

project_id = apply!(engine, "AddProject", { "path" => project_root, "name" => "Goal demo" }).fetch("target_id")
issue_id = apply!(engine, "CreateIssue", {
  "project_id" => project_id,
  "title" => "Raise the metric to 80",
  "description" => "Smoke fixture for the goal loop."
}).fetch("target_id")

goal = apply!(engine, "CreateGoal", {
  "issue_id" => issue_id,
  "success_criteria" => "metric.txt reports at least 80",
  "metric_command" => "cat metric.txt",
  "target" => 80,
  "max_iterations" => 5,
  "min_seconds_between_iterations" => 0,
  "guardrails" => ["test -f metric.txt"],
  # `accumulate` (the default) continues the same worker, worktree, and branch, so each
  # iteration builds on the previous one. `fresh_attempt` branches from the project's base ref
  # every time, which means independent attempts rather than accumulating progress.
  "continuity" => "accumulate"
}).fetch("result")

puts "Created #{goal.fetch("id")} on #{issue_id}: #{goal.fetch("success_criteria")}"
puts "Metric `#{goal.dig("metric", "command")}` must reach #{goal.dig("metric", "comparator")} #{goal.dig("metric", "target")}"
puts

20.times do |tick|
  current = store.load.fetch("goals").first
  break unless Meringue::Goals::Record::ACTIVE_STATUSES.include?(current.fetch("status"))

  puts "tick #{tick + 1}"
  engine.reconcile_sessions
end

final = store.load.fetch("goals").first
puts
puts "baseline: #{final.dig("baseline_metric", "value")}"
final.fetch("iterations").each do |iteration|
  puts format(
    "  it%<n>d  metric %<value>-6s delta %<delta>-6s %<verdict>-14s %<worker>s",
    n: iteration.fetch("number"),
    value: iteration.dig("metric", "value").inspect,
    delta: iteration.fetch("metric_delta").inspect,
    verdict: iteration.fetch("verdict").to_s,
    worker: iteration.fetch("attempt_worker_id").to_s
  )
  directive = iteration.fetch("next_directive", nil)
  puts "        directive: #{directive[0, 110]}…" if directive
end
puts
puts "goal:   #{final.fetch("status")} (#{final.fetch("stop_reason")})"
puts "issue:  #{store.load.fetch("issues").first.fetch("status")}"
puts "spawned #{final.fetch("workers_spawned")} attempt session(s), budget #{final.dig("budget", "max_workers")}"
puts
puts "goal log lines:"
store.load.fetch("logs").select { |entry| entry.fetch("source_id", nil) == final.fetch("id") }.each do |entry|
  puts "  #{entry.fetch("level")}: #{entry.fetch("message")}"
end

expected_status = "completed"
expected_reason = "goal_met"
unless final.fetch("status") == expected_status && final.fetch("stop_reason") == expected_reason
  abort "\nFAIL: expected #{expected_status}/#{expected_reason}, got #{final.fetch("status")}/#{final.fetch("stop_reason")}"
end
puts "\nOK: the loop measured real commands on each attempt's branch and stopped because the goal was met."
