#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression smoke for exactly-once head command batches and collision-safe worker workspaces.
#
# Covers the failures observed at 20:40 in ~/.meringue/state.json:
#   - one SpawnWorker command producing two "Spawned worker P1-I6-W1 for P1-I6." log lines,
#   - "git worktree add failed: ... a branch named 'meringue/<slug>' already exists",
#   - "Session reconciliation failed: Head H55 disappeared before command 2 was checkpointed."
#
# Usage:
#   ruby scripts/head_batch_apply_smoke.rb

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/meringue"

FAILURES = []

def check(description)
  ok, detail = yield
  if ok
    puts "  ok   #{description}"
  else
    puts "  FAIL #{description}#{detail ? " (#{detail})" : ""}"
    FAILURES << description
  end
end

def run!(*argv, chdir:)
  output = IO.popen(argv, chdir: chdir, err: [:child, :out], &:read)
  raise "command failed (#{argv.join(" ")}): #{output}" unless $CHILD_STATUS.nil? ? $?.success? : $CHILD_STATUS.success?

  output
end

def git_repo!(path)
  FileUtils.mkdir_p(path)
  run!("git", "init", "-q", "-b", "main", ".", chdir: path)
  run!("git", "config", "user.email", "smoke@example.com", chdir: path)
  run!("git", "config", "user.name", "Meringue Smoke", chdir: path)
  File.write(File.join(path, "README.md"), "# batch apply smoke\n")
  run!("git", "add", "README.md", chdir: path)
  run!("git", "commit", "-q", "-m", "initial commit", chdir: path)
  path
end

def build_engine(state_path:, workspace_root:, project_path:, config_path:, harness_client: Meringue::Harness::FakeClient.new)
  Meringue::Kernel::Engine.new(
    store: Meringue::State::Store.new(path: state_path),
    harness_client: harness_client,
    head_runner: Meringue::Heads::FakeRunner.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
    cwd: project_path,
    config_path: config_path
  )
end

def spawn_head(engine, message)
  result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => message })
  raise "SpawnHead was not accepted: #{result.inspect}" unless result.fetch("status") == "accepted"

  result.fetch("target_id")
end

def batch(project_id:, issue_id:, title:, prompt: "Investigate and report.")
  {
    "title" => "Route one goal",
    "summary" => "Create one issue and spawn one worker.",
    "commands" => [
      {
        "type" => "CreateIssue",
        "payload" => { "project_id" => project_id, "title" => title, "description" => "#{title} description", "parent_issue_id" => nil }
      },
      {
        "type" => "SpawnWorker",
        "payload" => { "issue_id" => issue_id, "title" => title, "prompt" => prompt }
      }
    ],
    "questions" => []
  }
end

def spawn_logs(state, agent_id)
  state.fetch("logs").select do |entry|
    entry.fetch("source_id", nil) == agent_id && entry.fetch("message", "").to_s.start_with?("Spawned worker")
  end
end

def error_logs(state)
  state.fetch("logs").select { |entry| entry.fetch("level", nil) == "error" }
end

# Blocks inside spawn_session so a second kernel instance can try to apply the same batch.
class GatedClient < Meringue::Harness::FakeClient
  def initialize(gate:, release:)
    @gate = gate
    @release = release
    super()
  end

  def spawn_session(**kwargs)
    @gate << true
    @release.pop
    super(**kwargs)
  end
end

# Removes the head record mid-batch, the way a second kernel instance does when it finishes and
# cleans up the same head while this instance is still applying commands.
class HeadKillingClient < Meringue::Harness::FakeClient
  attr_accessor :engine, :head_id

  def spawn_session(**kwargs)
    engine&.apply("type" => "Kill", "payload" => { "target_id" => head_id }) if head_id
    self.head_id = nil
    super(**kwargs)
  end
end

temp_root = Dir.mktmpdir("meringue-batch-apply-smoke-")
state_path = File.join(temp_root, "state.json")
workspace_root = File.join(temp_root, "workspaces")
config_path = File.join(temp_root, "config.toml")
project_path = git_repo!(File.join(temp_root, "demo-project"))
FileUtils.mkdir_p(workspace_root)

begin
  engine = build_engine(state_path: state_path, workspace_root: workspace_root, project_path: project_path, config_path: config_path)
  project = engine.apply("type" => "AddProject", "payload" => { "path" => project_path, "name" => "demo-project" })
  raise "AddProject was not accepted: #{project.inspect}" unless project.fetch("status") == "accepted"

  project_id = project.fetch("target_id")

  puts "Scenario 1: re-applying the same head batch does not re-run its commands"
  head_id = spawn_head(engine, "Investigate the first goal")
  head_result = batch(project_id: project_id, issue_id: "#{project_id}-I1", title: "First goal")
  first = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false }
  )
  second = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false }
  )
  state = engine.list_all
  workers = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == "#{project_id}-I1" }
  check("first apply is accepted") { [first.fetch("status") == "accepted", first.fetch("message")] }
  check("second apply is accepted") { [second.fetch("status") == "accepted", second.fetch("message")] }
  check("issue has exactly one worker") { [workers.length == 1, "workers: #{workers.map { |agent| agent.fetch("id") }.inspect}"] }
  check("exactly one issue was created") do
    issues = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project_id }
    [issues.length == 1, "issues: #{issues.map { |issue| issue.fetch("id") }.inspect}"]
  end
  check("exactly one spawn log line") do
    logs = spawn_logs(state, workers.first&.fetch("id", nil))
    [logs.length == 1, "logged #{logs.length}"]
  end
  check("no error logs") { [error_logs(state).empty?, error_logs(state).map { |entry| entry.fetch("message") }.inspect] }

  puts "Scenario 2: two kernel instances applying one batch concurrently"
  gate = Queue.new
  release = Queue.new
  gated_engine = build_engine(
    state_path: state_path,
    workspace_root: workspace_root,
    project_path: project_path,
    config_path: config_path,
    harness_client: GatedClient.new(gate: gate, release: release)
  )
  second_engine = build_engine(state_path: state_path, workspace_root: workspace_root, project_path: project_path, config_path: config_path)
  head_id = spawn_head(gated_engine, "Investigate the second goal")
  head_result = batch(project_id: project_id, issue_id: "#{project_id}-I2", title: "Second goal")
  applier = Thread.new do
    gated_engine.apply(
      "type" => "ApplyHeadResult",
      "payload" => { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false }
    )
  end
  gate.pop
  concurrent = second_engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false }
  )
  release << true
  primary = applier.value
  state = engine.list_all
  workers = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == "#{project_id}-I2" }
  check("primary apply is accepted") { [primary.fetch("status") == "accepted", primary.fetch("message")] }
  check("second instance skips the in-flight batch") do
    [
      concurrent.dig("result", "skipped") == "head_result_apply_in_progress",
      "#{concurrent.fetch("status")}: #{concurrent.fetch("message")}"
    ]
  end
  check("issue has exactly one worker") { [workers.length == 1, "workers: #{workers.map { |agent| agent.fetch("id") }.inspect}"] }
  check("exactly one spawn log line") do
    logs = spawn_logs(state, workers.first&.fetch("id", nil))
    [logs.length == 1, "logged #{logs.length}"]
  end
  check("the owning instance still records the batch as applied") do
    head = state.fetch("agents").find { |agent| agent.fetch("id", nil) == head_id }
    metadata = head ? (head.fetch("harness_metadata", {}) || {}) : {}
    [metadata.fetch("head_result_apply_state", nil) == "applied" && !metadata.fetch("head_result_applied_at", nil).nil?, metadata.slice("head_result_apply_state", "head_result_applied_at").inspect]
  end
  check("no error logs") { [error_logs(state).empty?, error_logs(state).map { |entry| entry.fetch("message") }.inspect] }

  puts "Scenario 3: worker provisioning survives a branch already checked out elsewhere"
  manager = Meringue::Workspace::Manager.new(root_path: workspace_root)
  worker_title = "Third goal"
  planned = manager.plan_worker_workspace(
    project_root: project_path,
    project_id: project_id,
    issue_id: "#{project_id}-I3",
    agent_id: "#{project_id}-I3-W1",
    task_title: worker_title
  )
  taken_branch = planned.fetch("workspace_branch")
  run!("git", "worktree", "add", "-q", "-b", taken_branch, File.join(temp_root, "taken-worktree"), "main", chdir: project_path)
  head_id = spawn_head(engine, "Investigate the third goal")
  collision = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => {
      "head_id" => head_id,
      "head_result" => batch(project_id: project_id, issue_id: "#{project_id}-I3", title: worker_title),
      "_cleanup_head" => false
    }
  )
  state = engine.list_all
  worker = state.fetch("agents").find { |agent| agent.fetch("issue_id", nil) == "#{project_id}-I3" && agent.fetch("type", nil) == "worker" }
  command_results = collision.dig("result", "command_results") || []
  check("every command in the batch is accepted") do
    [command_results.all? { |result| result.fetch("status", nil) == "accepted" }, command_results.map { |result| [result["command_type"], result["status"], result["message"]] }.inspect]
  end
  check("worker gets a usable workspace") { [worker && Dir.exist?(worker.fetch("workspace_path").to_s), worker&.fetch("workspace_path", nil).inspect] }
  check("worker branch avoids the taken branch") do
    [worker && worker.fetch("workspace_branch", nil) != taken_branch, worker&.fetch("workspace_branch", nil).inspect]
  end
  check("no provisioning error logs") do
    provisioning_errors = error_logs(state).select { |entry| entry.fetch("message", "").to_s.include?("workspace provisioning failed") }
    [provisioning_errors.empty?, provisioning_errors.map { |entry| entry.fetch("message") }.inspect]
  end

  puts "Scenario 4: worker provisioning reuses an orphaned meringue branch"
  worker_title = "Fourth goal"
  planned = manager.plan_worker_workspace(
    project_root: project_path,
    project_id: project_id,
    issue_id: "#{project_id}-I4",
    agent_id: "#{project_id}-I4-W1",
    task_title: worker_title
  )
  run!("git", "branch", planned.fetch("workspace_branch"), "main", chdir: project_path)
  head_id = spawn_head(engine, "Investigate the fourth goal")
  orphan = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => {
      "head_id" => head_id,
      "head_result" => batch(project_id: project_id, issue_id: "#{project_id}-I4", title: worker_title),
      "_cleanup_head" => false
    }
  )
  state = engine.list_all
  worker = state.fetch("agents").find { |agent| agent.fetch("issue_id", nil) == "#{project_id}-I4" && agent.fetch("type", nil) == "worker" }
  check("every command in the batch is accepted") do
    results = orphan.dig("result", "command_results") || []
    [results.all? { |result| result.fetch("status", nil) == "accepted" }, results.map { |result| [result["command_type"], result["status"], result["message"]] }.inspect]
  end
  check("worker gets a usable workspace") { [worker && Dir.exist?(worker.fetch("workspace_path").to_s), worker&.fetch("workspace_path", nil).inspect] }

  puts "Scenario 5: a blocked worktree path is retried without leaving a stray branch behind"
  worker_title = "Fifth goal"
  planned = manager.plan_worker_workspace(
    project_root: project_path,
    project_id: project_id,
    issue_id: "#{project_id}-I5",
    agent_id: "#{project_id}-I5-W1",
    task_title: worker_title
  )
  blocked_path = File.expand_path(planned.fetch("workspace_path"))
  blocked_branch = planned.fetch("workspace_branch")
  FileUtils.mkdir_p(blocked_path)
  File.write(File.join(blocked_path, "leftover.txt"), "not a worktree\n")
  head_id = spawn_head(engine, "Investigate the fifth goal")
  blocked = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => {
      "head_id" => head_id,
      "head_result" => batch(project_id: project_id, issue_id: "#{project_id}-I5", title: worker_title),
      "_cleanup_head" => false
    }
  )
  state = engine.list_all
  worker = state.fetch("agents").find { |agent| agent.fetch("issue_id", nil) == "#{project_id}-I5" && agent.fetch("type", nil) == "worker" }
  check("every command in the batch is accepted") do
    results = blocked.dig("result", "command_results") || []
    [results.all? { |result| result.fetch("status", nil) == "accepted" }, results.map { |result| [result["command_type"], result["status"], result["message"]] }.inspect]
  end
  check("worker gets a usable workspace outside the blocked path") do
    path = worker&.fetch("workspace_path", nil)
    [path && path != blocked_path && Dir.exist?(path.to_s), path.inspect]
  end
  check("no stray branch is left for the blocked candidate") do
    listed = run!("git", "branch", "--list", blocked_branch, chdir: project_path).strip
    [listed.empty?, listed.inspect]
  end

  puts "Scenario 6: a head removed mid-batch does not raise or fail reconciliation"
  killing_client = HeadKillingClient.new
  killing_engine = build_engine(
    state_path: state_path,
    workspace_root: workspace_root,
    project_path: project_path,
    config_path: config_path,
    harness_client: killing_client
  )
  killing_client.engine = killing_engine
  head_id = spawn_head(killing_engine, "Investigate the sixth goal")
  killing_client.head_id = head_id
  interrupted = killing_engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => {
      "head_id" => head_id,
      "head_result" => batch(project_id: project_id, issue_id: "#{project_id}-I6", title: "Sixth goal"),
      "_cleanup_head" => false
    }
  )
  check("apply reports a result instead of raising") do
    [%w[accepted rejected].include?(interrupted.fetch("status")), interrupted.fetch("status")]
  end
  check("apply does not fail with a checkpoint exception") do
    [
      interrupted.fetch("status") != "failed" && !interrupted.fetch("message", "").to_s.include?("was checkpointed"),
      interrupted.fetch("message")
    ]
  end
  reconciled = killing_engine.apply("type" => "ReconcileSessions", "payload" => {})
  check("reconciliation stays healthy afterwards") do
    [reconciled.fetch("status") == "accepted", "#{reconciled.fetch("status")}: #{reconciled.fetch("message")}"]
  end
  check("no checkpoint error was logged") do
    checkpoint_errors = error_logs(engine.list_all).select { |entry| entry.fetch("message", "").to_s.include?("was checkpointed") }
    [checkpoint_errors.empty?, checkpoint_errors.map { |entry| entry.fetch("message") }.inspect]
  end

  puts
  if FAILURES.empty?
    puts "All head batch apply checks passed."
  else
    puts "#{FAILURES.length} check(s) failed:"
    FAILURES.each { |failure| puts "  - #{failure}" }
  end
ensure
  if ENV["MERINGUE_KEEP_SMOKE"] == "1"
    puts "State kept at #{state_path}"
  elsif Dir.exist?(temp_root)
    FileUtils.remove_entry(temp_root)
  end
end

exit(FAILURES.empty? ? 0 : 1)
