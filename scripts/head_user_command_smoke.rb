#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage for head agents running user slash commands as kernel commands.
#
# A head should be able to satisfy a housekeeping request in natural language by proposing the
# matching user command, with the same validation, exactly-once journaling, logging, and visible
# output as the typed slash path. Destructive commands stay gated: `ClearState` and a full-project
# `Kill` require both an explicit user instruction (checked against the message the kernel recorded
# when it spawned the head) and a `confirmed_by_user` payload flag.
#
# Usage:
#   ruby scripts/head_user_command_smoke.rb

require "fileutils"
require "json"
require "time"
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

# Keeps prune's pull request rules deterministic without touching a real forge.
class StubForgeClient
  def pull_request_urls_for_branch(repository:, branch:)
    []
  end

  def pull_request_status(url)
    { "provider" => "github", "url" => url.to_s, "state" => "unknown", "error" => "no stubbed status" }
  end
end

NOW = Time.now.utc.iso8601

def project_record(id, status, name: id)
  {
    "id" => id, "name" => name, "root_path" => "/tmp/#{name}", "status" => status,
    "created_at" => NOW, "updated_at" => NOW
  }
end

def issue_record(id, project_id, status)
  {
    "id" => id, "project_id" => project_id, "parent_issue_id" => nil, "title" => "Issue #{id}",
    "description" => "", "status" => status, "agent_ids" => [], "created_at" => NOW, "updated_at" => NOW
  }
end

def worker_record(id, issue_id, project_id, status, session: false)
  record = {
    "id" => id, "type" => "worker", "status" => status, "project_id" => project_id,
    "issue_id" => issue_id, "harness" => "fake", "created_at" => NOW, "updated_at" => NOW
  }
  return record unless session

  record.merge(
    "pid" => 4321,
    "harness_session_id" => "fake-session-#{id}",
    "harness_metadata" => { "is_streaming" => false }
  )
end

def head_record(id, status)
  {
    "id" => id, "type" => "head", "status" => status, "harness" => "fake",
    "created_at" => NOW, "updated_at" => NOW
  }
end

def question_record(id, status, issue_id: nil, project_id: nil)
  {
    "id" => id, "head_id" => "H99", "project_id" => project_id, "issue_id" => issue_id,
    "question" => "Should this continue?", "context" => "", "status" => status,
    "created_at" => NOW, "updated_at" => NOW
  }
end

# One fixture tree with prunable and retained records, an errored standalone head, an open
# question, and a live worker, so every user command has something real to act on.
def fixture_state
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [
    project_record("P1", "working", name: "active-project"),
    project_record("P2", "completed", name: "finished-project")
  ]
  state["issues"] = [
    issue_record("P1-I1", "P1", "completed"),
    issue_record("P1-I2", "P1", "errored"),
    issue_record("P1-I3", "P1", "working"),
    issue_record("P2-I1", "P2", "completed")
  ]
  state["agents"] = [
    worker_record("P1-I1-W1", "P1-I1", "P1", "completed"),
    worker_record("P1-I3-W1", "P1-I3", "P1", "idle", session: true),
    head_record("H9", "errored")
  ]
  state["questions"] = [question_record("Q1", "open", issue_id: "P1-I3", project_id: "P1")]
  state["counters"] = state.fetch("counters").merge(
    "projects" => 2,
    "issues_by_project" => { "P1" => 3, "P2" => 1 },
    "questions" => 1
  )
  state
end

def build_engine(dir, seed: true)
  state_path = File.join(dir, "state.json")
  FileUtils.rm_f(state_path)
  FileUtils.rm_f("#{state_path}.lock")
  store = Meringue::State::Store.new(path: state_path)
  store.save(fixture_state) if seed
  engine = Meringue::Kernel::Engine.new(
    store: store,
    harness_client: Meringue::Harness::FakeClient.new,
    head_runner: Meringue::Heads::FakeRunner.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(dir, "workspaces")),
    forge_client: StubForgeClient.new,
    cwd: dir,
    config_path: File.join(dir, "config.toml")
  )
  [engine, state_path]
end

def spawn_head!(engine, user_message)
  result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => user_message })
  raise "SpawnHead was not accepted: #{result.inspect}" unless result.fetch("status") == "accepted"

  result.fetch("target_id")
end

# Applies a batch as if the head had proposed it for `user_message`.
def head_batch(engine, user_message, commands, cleanup_head: true, summary: "Ran the requested Meringue command.")
  head_id = spawn_head!(engine, user_message)
  result = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => {
      "head_id" => head_id,
      "head_result" => {
        "title" => "User command",
        "summary" => summary,
        "commands" => commands,
        "questions" => []
      },
      "_cleanup_head" => cleanup_head
    }
  )
  [head_id, result]
end

def command_results(apply_result)
  Array(apply_result.fetch("result", {})&.fetch("command_results", []))
end

def result_for(apply_result, command_type)
  command_results(apply_result).find { |entry| entry.fetch("command_type", nil) == command_type }
end

def log_messages(state)
  state.fetch("logs").map { |entry| entry.fetch("message", "") }
end

def cmd(type, payload = {})
  { "type" => type, "payload" => payload }
end

temp_root = Dir.mktmpdir("meringue-head-user-command-smoke-")

begin
  puts "Scenario 1: one head batch containing every newly allowed user command"
  dir = File.join(temp_root, "batch")
  FileUtils.mkdir_p(dir)
  engine, = build_engine(dir)
  _head_id, applied = head_batch(
    engine,
    "prune the merged issues, renumber the tree, and show me what P1 looks like",
    # Recount renames existing ids, so it is proposed last: the doc tells heads not to mix it
    # with commands that reference ids which are about to change.
    [
      cmd("Prune"),
      cmd("GetInfo", "target_id" => "P1"),
      cmd("ListAll"),
      cmd("GetState"),
      cmd("ListQuestions"),
      cmd("Help"),
      cmd("ModifyIssue", "issue_id" => "P1-I3", "title" => "Renamed by the head"),
      cmd("PromptAgent", "agent_id" => "P1-I3-W1", "prompt" => "Status check.", "mode" => "normal"),
      cmd("AnswerQuestion", "question_id" => "Q1", "answer" => "Yes, continue."),
      cmd("SetTheme", "theme" => "gruvbox"),
      cmd("Recount")
    ]
  )
  state = engine.list_all
  results = command_results(applied)
  check("the batch is accepted") { [applied.fetch("status") == "accepted", applied.fetch("message")] }
  check("every proposed user command is accepted") do
    bad = results.reject { |entry| entry.fetch("status", nil) == "accepted" }
    [bad.empty?, bad.map { |entry| "#{entry.fetch("command_type")}: #{entry.fetch("message")} #{entry.fetch("errors", []).inspect}" }.join(" | ")]
  end
  check("Prune ran and reported its own summary") do
    message = result_for(applied, "Prune").fetch("message")
    [message.start_with?("Pruned ") && log_messages(state).include?(message), message]
  end
  check("Recount is accepted even though the proposing head is alive") do
    entry = result_for(applied, "Recount")
    [entry.fetch("status") == "accepted", "#{entry.fetch("status")}: #{entry.fetch("errors", []).inspect}"]
  end
  check("the proposing head survives its own Prune") do
    entry = result_for(applied, "GetInfo")
    [entry.fetch("status") == "accepted", "GetInfo after prune: #{entry.fetch("message")}"]
  end
  check("read-only command output reaches the visible log") do
    outputs = log_messages(state).select { |message| message.start_with?("Command output: ") }
    missing = %w[GetInfo ListAll GetState ListQuestions Help].reject do |type|
      outputs.any? { |message| message.include?("#{type}: accepted") }
    end
    [missing.empty?, "missing: #{missing.inspect} in #{outputs.inspect}"]
  end
  check("the kernel does not double-log commands that already log themselves") do
    outputs = log_messages(state).select { |message| message.start_with?("Command output: Prune") }
    [outputs.empty?, outputs.inspect]
  end
  check("ModifyIssue applied the new title") do
    issue = state.fetch("issues").find { |candidate| candidate.fetch("title", nil) == "Renamed by the head" }
    [!issue.nil?, state.fetch("issues").map { |candidate| candidate.fetch("title") }.inspect]
  end
  check("AnswerQuestion answered the open question") do
    question = state.fetch("questions").first
    [question && question.fetch("status") == "answered", question.inspect]
  end
  check("SetTheme persisted the theme") do
    config = File.read(File.join(dir, "config.toml"))
    [config.include?("gruvbox"), config]
  end
  check("no error-level logs were recorded") do
    errors = state.fetch("logs").select { |entry| entry.fetch("level", nil) == "error" }
    [errors.empty?, errors.map { |entry| entry.fetch("message") }.inspect]
  end

  # /harness refuses to switch while workers are active, so it gets its own quiet tree. The point
  # of the check is that the proposing head is not counted as its own blocker.
  harness_dir = File.join(temp_root, "harness")
  FileUtils.mkdir_p(harness_dir)
  harness_engine, = build_engine(harness_dir)
  _head_id, harness_applied = head_batch(
    harness_engine,
    "switch the harness to pi",
    [cmd("SetHarness", "provider" => "pi")]
  )
  check("SetHarness is accepted from a head with no active workers") do
    entry = result_for(harness_applied, "SetHarness")
    [entry.fetch("status") == "accepted", "#{entry.fetch("status")}: #{entry.fetch("errors", []).inspect}"]
  end

  puts "Scenario 2: typed /prune and a head-proposed Prune produce the same output"
  typed_dir = File.join(temp_root, "typed")
  head_dir = File.join(temp_root, "head")
  FileUtils.mkdir_p([typed_dir, head_dir])
  typed_engine, = build_engine(typed_dir)
  head_engine, = build_engine(head_dir)
  typed = Meringue::Heads::PromptLoop.new(engine: typed_engine).call("/prune")
  typed_command_result = Array(typed.fetch("command_results")).first
  _head_id, head_applied = head_batch(head_engine, "prune the merged issues", [cmd("Prune")])
  head_command_result = result_for(head_applied, "Prune")
  typed_state = typed_engine.list_all
  head_state = head_engine.list_all
  check("both paths accept the command") do
    [
      typed_command_result.fetch("status") == "accepted" && head_command_result.fetch("status") == "accepted",
      "#{typed_command_result.fetch("status")} / #{head_command_result.fetch("status")}"
    ]
  end
  check("both paths return the same summary message") do
    [
      typed_command_result.fetch("message") == head_command_result.fetch("message"),
      "#{typed_command_result.fetch("message").inspect} vs #{head_command_result.fetch("message").inspect}"
    ]
  end
  check("both paths log the same visible prune summary") do
    typed_line = log_messages(typed_state).find { |message| message.start_with?("Pruned ") }
    head_line = log_messages(head_state).find { |message| message.start_with?("Pruned ") }
    [!typed_line.nil? && typed_line == head_line, "#{typed_line.inspect} vs #{head_line.inspect}"]
  end
  check("both paths remove the same records") do
    typed_ids = typed_state.fetch("issues").map { |issue| issue.fetch("id") }.sort
    head_ids = head_state.fetch("issues").map { |issue| issue.fetch("id") }.sort
    [typed_ids == head_ids, "#{typed_ids.inspect} vs #{head_ids.inspect}"]
  end
  check("the head summary does not have to restate the kernel output") do
    [
      log_messages(head_state).none? { |message| message.include?("Ran the requested Meringue command.") },
      "head summary log lines: #{log_messages(head_state).inspect}"
    ]
  end

  puts "Scenario 3: a head-proposed batch is still applied exactly once"
  once_dir = File.join(temp_root, "once")
  FileUtils.mkdir_p(once_dir)
  once_engine, = build_engine(once_dir)
  head_id = spawn_head!(once_engine, "prune the merged issues")
  payload = {
    "head_id" => head_id,
    "head_result" => {
      "title" => "Prune",
      "summary" => "Run the cleanup pass.",
      "commands" => [cmd("Prune")],
      "questions" => []
    },
    "_cleanup_head" => false
  }
  first = once_engine.apply("type" => "ApplyHeadResult", "payload" => payload)
  second = once_engine.apply("type" => "ApplyHeadResult", "payload" => payload)
  once_state = once_engine.list_all
  check("both applies are accepted") do
    [
      first.fetch("status") == "accepted" && second.fetch("status") == "accepted",
      "#{first.fetch("status")} / #{second.fetch("status")}"
    ]
  end
  check("the second apply is recognized as a duplicate") do
    [second.dig("result", "duplicate_apply") == true, second.fetch("message")]
  end
  check("exactly one prune summary was logged") do
    lines = log_messages(once_state).select { |message| message.start_with?("Pruned ") }
    [lines.length == 1, "logged #{lines.length}"]
  end

  puts "Scenario 4: ClearState guardrails"
  vague_dir = File.join(temp_root, "vague-clear")
  FileUtils.mkdir_p(vague_dir)
  vague_engine, = build_engine(vague_dir)
  _head_id, vague_applied = head_batch(vague_engine, "can you tidy things up in here", [cmd("ClearState")])
  vague_state = vague_engine.list_all
  vague_result = result_for(vague_applied, "ClearState")
  check("an unconfirmed ClearState from a vague prompt is rejected") do
    [vague_result.fetch("status") == "rejected", vague_result.fetch("message")]
  end
  check("the rejection names both missing guardrails") do
    errors = vague_result.fetch("errors")
    [
      errors.include?("clear_state_requires_user_confirmation") &&
        errors.include?("clear_state_requires_explicit_user_instruction"),
      errors.inspect
    ]
  end
  check("state survives the refused wipe") do
    [vague_state.fetch("projects").length == 2, vague_state.fetch("projects").map { |p| p.fetch("id") }.inspect]
  end
  check("the refusal is visible to the user") do
    outputs = log_messages(vague_state).select { |message| message.start_with?("Rejected ClearState:") }
    [outputs.any?, log_messages(vague_state).inspect]
  end

  flagged_dir = File.join(temp_root, "flagged-clear")
  FileUtils.mkdir_p(flagged_dir)
  flagged_engine, = build_engine(flagged_dir)
  _head_id, flagged_applied = head_batch(
    flagged_engine,
    "delete the merged issues please",
    [cmd("ClearState", "confirmed_by_user" => true)]
  )
  flagged_state = flagged_engine.list_all
  flagged_result = result_for(flagged_applied, "ClearState")
  check("a confirmation flag cannot substitute for an explicit user instruction") do
    [
      flagged_result.fetch("status") == "rejected" &&
        flagged_result.fetch("errors").include?("clear_state_requires_explicit_user_instruction"),
      "#{flagged_result.fetch("status")}: #{flagged_result.fetch("errors").inspect}"
    ]
  end
  check("a prune-flavored request never wipes state") do
    [flagged_state.fetch("projects").length == 2, flagged_state.fetch("projects").length.to_s]
  end

  explicit_dir = File.join(temp_root, "explicit-clear")
  FileUtils.mkdir_p(explicit_dir)
  explicit_engine, = build_engine(explicit_dir)
  _head_id, explicit_applied = head_batch(
    explicit_engine,
    "clear the meringue state, I want to start from an empty tree",
    [cmd("ClearState", "confirmed_by_user" => true), cmd("Prune")]
  )
  explicit_state = explicit_engine.list_all
  explicit_result = result_for(explicit_applied, "ClearState")
  check("an explicit, confirmed ClearState is accepted") do
    [explicit_result.fetch("status") == "accepted", "#{explicit_result.fetch("status")}: #{explicit_result.fetch("errors", []).inspect}"]
  end
  check("state is cleared") do
    [
      explicit_state.fetch("projects").empty? && explicit_state.fetch("issues").empty? && explicit_state.fetch("agents").empty?,
      "projects: #{explicit_state.fetch("projects").length}, issues: #{explicit_state.fetch("issues").length}, agents: #{explicit_state.fetch("agents").length}"
    ]
  end
  check("the batch reports the wipe and stops after it") do
    [
      explicit_applied.dig("result", "state_cleared") == true && explicit_applied.dig("result", "skipped_command_count") == 1,
      explicit_applied.fetch("result").slice("state_cleared", "skipped_command_count").inspect
    ]
  end
  check("the wipe is visible in the fresh log") do
    outputs = log_messages(explicit_state).select { |message| message.include?("ClearState: accepted") }
    [outputs.any?, log_messages(explicit_state).inspect]
  end

  puts "Scenario 5: Kill guardrails"
  kill_dir = File.join(temp_root, "kill")
  FileUtils.mkdir_p(kill_dir)
  kill_engine, = build_engine(kill_dir)
  kill_head_id, kill_applied = head_batch(
    kill_engine,
    "kill the P1-I3-W1 worker, it is stuck, drop Q1 and prune what is left",
    [
      cmd("Kill", "target_id" => "P1-I3-W1"),
      cmd("DismissQuestion", "question_id" => "Q1"),
      cmd("Prune"),
      cmd("ListAll")
    ],
    cleanup_head: false
  )
  kill_state = kill_engine.list_all
  check("killing one worker needs no confirmation") do
    entry = result_for(kill_applied, "Kill")
    [entry.fetch("status") == "accepted", "#{entry.fetch("status")}: #{entry.fetch("errors", []).inspect}"]
  end
  check("the worker is gone") do
    ids = kill_state.fetch("agents").map { |agent| agent.fetch("id") }
    [!ids.include?("P1-I3-W1"), ids.inspect]
  end
  check("DismissQuestion is accepted from a head") do
    entry = result_for(kill_applied, "DismissQuestion")
    question = kill_state.fetch("questions").find { |candidate| candidate.fetch("id") == "Q1" }
    [
      entry.fetch("status") == "accepted" && (question.nil? || question.fetch("status") == "dismissed"),
      "#{entry.fetch("status")}: #{question.inspect}"
    ]
  end
  check("a Prune that follows the head's own Kill does not abort the batch") do
    prune_entry = result_for(kill_applied, "Prune")
    tail_entry = result_for(kill_applied, "ListAll")
    [
      prune_entry.fetch("status") == "accepted" && tail_entry && tail_entry.fetch("status") == "accepted",
      "#{prune_entry.fetch("status")} / #{tail_entry.inspect}"
    ]
  end
  check("the proposing head is not pruned by its own commands") do
    ids = kill_state.fetch("agents").select { |agent| agent.fetch("type") == "head" }.map { |agent| agent.fetch("id") }
    [ids.include?(kill_head_id), ids.inspect]
  end

  self_kill_dir = File.join(temp_root, "self-kill")
  FileUtils.mkdir_p(self_kill_dir)
  self_engine, = build_engine(self_kill_dir)
  self_head_id = spawn_head!(self_engine, "stop everything")
  self_applied = self_engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => {
      "head_id" => self_head_id,
      "head_result" => {
        "title" => "Self kill",
        "summary" => "Try to kill myself.",
        "commands" => [cmd("Kill", "target_id" => self_head_id), cmd("ListAll")],
        "questions" => []
      },
      "_cleanup_head" => false
    }
  )
  check("a head cannot kill itself") do
    entry = result_for(self_applied, "Kill")
    [
      entry.fetch("status") == "rejected" && entry.fetch("errors").include?("head_cannot_kill_itself"),
      "#{entry.fetch("status")}: #{entry.fetch("errors").inspect}"
    ]
  end
  check("the rest of the batch still runs after the refusal") do
    entry = result_for(self_applied, "ListAll")
    [entry && entry.fetch("status") == "accepted", entry.inspect]
  end

  project_kill_dir = File.join(temp_root, "project-kill")
  FileUtils.mkdir_p(project_kill_dir)
  project_engine, = build_engine(project_kill_dir)
  _head_id, vague_kill = head_batch(
    project_engine,
    "things look messy, clean up whatever you want",
    [cmd("Kill", "target_id" => "P1")]
  )
  check("a full-project kill from a vague prompt is rejected") do
    entry = result_for(vague_kill, "Kill")
    [
      entry.fetch("status") == "rejected" &&
        entry.fetch("errors").include?("project_kill_requires_explicit_user_instruction"),
      "#{entry.fetch("status")}: #{entry.fetch("errors").inspect}"
    ]
  end
  check("the project survives the refused kill") do
    ids = project_engine.list_all.fetch("projects").map { |project| project.fetch("id") }
    [ids.include?("P1"), ids.inspect]
  end
  _head_id, explicit_kill = head_batch(
    project_engine,
    "kill project P1, I am done with it",
    [cmd("Kill", "target_id" => "P1", "confirmed_by_user" => true)]
  )
  check("an explicit, confirmed project kill is accepted") do
    entry = result_for(explicit_kill, "Kill")
    [entry.fetch("status") == "accepted", "#{entry.fetch("status")}: #{entry.fetch("errors", []).inspect}"]
  end
  check("the project is gone") do
    ids = project_engine.list_all.fetch("projects").map { |project| project.fetch("id") }
    [!ids.include?("P1"), ids.inspect]
  end

  puts "Scenario 6: kernel-internal commands stay off limits"
  internal_dir = File.join(temp_root, "internal")
  FileUtils.mkdir_p(internal_dir)
  internal_engine, = build_engine(internal_dir)
  _head_id, internal_applied = head_batch(
    internal_engine,
    "apply my previous result again",
    [cmd("ApplyHeadResult", "head_id" => "H1"), cmd("InvalidSlashCommand", "message" => "nope")]
  )
  check("ApplyHeadResult is not proposable by a head") do
    entry = result_for(internal_applied, "ApplyHeadResult")
    [
      entry.fetch("status") == "rejected" && entry.fetch("errors").include?("command_not_proposable_by_head"),
      "#{entry.fetch("status")}: #{entry.fetch("errors").inspect}"
    ]
  end
  check("InvalidSlashCommand is not proposable by a head") do
    entry = result_for(internal_applied, "InvalidSlashCommand")
    [
      entry.fetch("status") == "rejected" && entry.fetch("errors").include?("command_not_proposable_by_head"),
      "#{entry.fetch("status")}: #{entry.fetch("errors").inspect}"
    ]
  end

  puts "Scenario 7: the fake head runner maps housekeeping language to user commands"
  runner = Meringue::Heads::FakeRunner.new
  snapshot = fixture_state
  mappings = {
    "prune the merged issues" => ["Prune"],
    "clean up the completed issues" => ["Prune"],
    "renumber the tree" => ["Recount"],
    "kill P1-I3-W1" => ["Kill"],
    "what is P1-I1" => ["GetInfo"],
    "wipe the meringue state" => ["ClearState"]
  }
  mappings.each do |message, expected_types|
    check("#{message.inspect} maps to #{expected_types.inspect}") do
      types = runner.run(user_message: message, snapshot: snapshot).fetch("commands").map { |command| command.fetch("type") }
      [types == expected_types, types.inspect]
    end
  end
  check("ordinary work prompts still route to a worker") do
    types = runner.run(user_message: "clean up the signup validation code", snapshot: snapshot)
                  .fetch("commands").map { |command| command.fetch("type") }
    [types.include?("SpawnWorker"), types.inspect]
  end

  puts "Scenario 8: end-to-end natural language prune through the head loop"
  loop_dir = File.join(temp_root, "loop")
  FileUtils.mkdir_p(loop_dir)
  loop_engine, = build_engine(loop_dir)
  events = []
  loop_result = Meringue::Heads::PromptLoop.new(engine: loop_engine).call("prune the merged issues") { |event| events << event }
  loop_state = loop_engine.list_all
  check("the head loop applied a Prune command") do
    types = command_results(loop_result.fetch("apply_head_result")).map { |entry| entry.fetch("command_type") }
    [types == ["Prune"], types.inspect]
  end
  check("the user sees the kernel's prune summary") do
    line = log_messages(loop_state).find { |message| message.start_with?("Pruned ") }
    [!line.nil?, log_messages(loop_state).inspect]
  end
  check("the applied event carries command results for local TUI side effects") do
    applied_event = events.find { |event| event.fetch("event", nil) == "head_result_applied" }
    types = Array(applied_event&.fetch("command_results", [])).map { |entry| entry.fetch("command_type") }
    [types == ["Prune"], types.inspect]
  end
ensure
  FileUtils.remove_entry(temp_root)
end

puts
if FAILURES.empty?
  puts "All head user command checks passed."
else
  puts "#{FAILURES.length} check(s) failed:"
  FAILURES.each { |failure| puts "  - #{failure}" }
  exit 1
end
