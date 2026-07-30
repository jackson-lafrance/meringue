#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage for the network-aborted settle classification.
#
# Replays the reported incident with the real Pi harness client: on 2026-07-29 the user's wifi
# dropped, five worker turns ended with `stopReason: "error"` / `errorMessage: "Connection error."`
# and no final assistant message, and Meringue logged all five as "Worker <id> completed." with an
# empty result, flipping five in-flight issues to `completed`.
#
# The Pi session file written here is a byte-shaped copy of one of those real sessions: a real tool
# result, then four empty assistant messages whose stop reason is the connection error. `get_state`
# reports the session as no longer streaming, exactly like Pi's live RPC state did.
#
# Usage:
#   ruby scripts/network_aborted_settle_smoke.rb

require "fileutils"
require "json"
require "tmpdir"
require "time"

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

NOW = Time.now.utc.iso8601

# Real Pi client for turn classification, with only the live RPC transport replaced: the incident's
# Pi process is gone, and what the kernel must read is the persisted session file.
class SettledPiClient < Meringue::Harness::PiClient
  def initialize(streaming: false, **options)
    super(**options)
    @streaming = streaming
  end

  def harness_name
    "pi"
  end

  def get_state(session_ref)
    session_ref.merge(
      "harness" => "pi",
      "is_streaming" => @streaming,
      "metadata" => (session_ref.fetch("metadata", nil) || {}).merge("completed" => !@streaming)
    )
  end

  def read_events(_session_ref)
    []
  end
end

def assistant_error_record(id, parent_id)
  {
    "type" => "message",
    "id" => id,
    "parentId" => parent_id,
    "timestamp" => "2026-07-30T02:27:46.140Z",
    "message" => {
      "role" => "assistant",
      "content" => [],
      "api" => "anthropic-messages",
      "provider" => "anthropic-flex",
      "model" => "claude-opus-5",
      "stopReason" => "error",
      "errorMessage" => "Connection error."
    }
  }
end

def aborted_session_file(dir)
  path = File.join(dir, "pi-sessions", "aborted.jsonl")
  FileUtils.mkdir_p(File.dirname(path))
  records = [
    { "type" => "session", "id" => "aborted-sess", "cwd" => dir, "timestamp" => "2026-07-30T02:01:13.294Z" },
    { "type" => "session_info", "id" => "info-1", "name" => "Fix prune retaining merged-PR records" },
    { "type" => "message", "id" => "m1", "parentId" => nil, "timestamp" => "2026-07-30T02:20:30.637Z",
      "message" => { "role" => "toolResult", "toolName" => "bash", "toolCallId" => "toolu_1",
                     "content" => [{ "type" => "text", "text" => "1116 runs, 33 failures" }], "isError" => false } },
    assistant_error_record("cb38a1ee", "m1"),
    assistant_error_record("cd7d52ed", "cb38a1ee"),
    assistant_error_record("4da357a3", "cd7d52ed"),
    assistant_error_record("20416ac1", "4da357a3")
  ]
  File.open(path, "w") { |file| records.each { |record| file.puts(JSON.generate(record)) } }
  path
end

def finished_session_file(dir)
  path = File.join(dir, "pi-sessions", "finished.jsonl")
  FileUtils.mkdir_p(File.dirname(path))
  records = [
    { "type" => "session", "id" => "finished-sess", "cwd" => dir, "timestamp" => "2026-07-30T02:01:13.294Z" },
    { "type" => "message", "id" => "f1", "parentId" => nil, "timestamp" => "2026-07-30T02:20:30.637Z",
      "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "Done. PR: https://example.test/pr/1" }],
                     "stopReason" => "endTurn" } }
  ]
  File.open(path, "w") { |file| records.each { |record| file.puts(JSON.generate(record)) } }
  path
end

def state_fixture(dir, aborted_file, finished_file)
  {
    "schema_version" => Meringue::State::Models::SCHEMA_VERSION,
    "projects" => [
      { "id" => "P1", "name" => "meringue", "root_path" => dir, "status" => "working", "created_at" => NOW, "updated_at" => NOW }
    ],
    "issues" => [
      { "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Fix prune retention",
        "description" => "Mid-flight when the wifi dropped.", "status" => "working", "agent_ids" => ["P1-I1-W1"],
        "created_at" => NOW, "updated_at" => NOW },
      { "id" => "P1-I2", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Write release notes",
        "description" => "Really finished.", "status" => "working", "agent_ids" => ["P1-I2-W1"],
        "created_at" => NOW, "updated_at" => NOW }
    ],
    "agents" => [
      { "id" => "P1-I1-W1", "type" => "worker", "status" => "working", "project_id" => "P1", "issue_id" => "P1-I1",
        "harness" => "pi", "pid" => Process.pid.to_s, "harness_session_id" => "aborted-sess",
        "harness_session_file" => aborted_file, "workspace_path" => dir,
        "workspace_branch" => "meringue/fix-prune-retention-b77ba668", "workspace_strategy" => "git_worktree",
        "harness_metadata" => { "title" => "Fix prune retention", "is_streaming" => true, "cwd" => dir },
        "created_at" => NOW, "updated_at" => NOW },
      { "id" => "P1-I2-W1", "type" => "worker", "status" => "working", "project_id" => "P1", "issue_id" => "P1-I2",
        "harness" => "pi", "pid" => Process.pid.to_s, "harness_session_id" => "finished-sess",
        "harness_session_file" => finished_file, "workspace_path" => dir,
        "workspace_branch" => "meringue/write-release-notes-a1b2c3d4", "workspace_strategy" => "git_worktree",
        "harness_metadata" => { "title" => "Write release notes", "is_streaming" => true, "cwd" => dir },
        "created_at" => NOW, "updated_at" => NOW }
    ],
    "questions" => [],
    "logs" => [],
    "conversation" => { "messages" => [], "next_message_id" => 0 },
    "counters" => { "projects" => 1, "heads" => 0, "questions" => 0, "logs" => 0,
                    "issues_by_project" => { "P1" => 2 }, "workers_by_issue" => { "P1-I1" => 1, "P1-I2" => 1 } },
    "metadata" => { "created_at" => NOW, "updated_at" => NOW }
  }
end

Dir.mktmpdir("meringue-network-settle-smoke") do |dir|
  aborted_file = aborted_session_file(dir)
  finished_file = finished_session_file(dir)
  state_path = File.join(dir, "state.json")
  File.write(state_path, "#{JSON.pretty_generate(state_fixture(dir, aborted_file, finished_file))}\n")

  session_dir = File.join(dir, "pi-sessions")
  client = SettledPiClient.new(session_dir: session_dir)
  engine = Meringue::Kernel::Engine.new(
    store: Meringue::State::Store.new(path: state_path),
    harness_client: client,
    head_runner: Meringue::Heads::FakeRunner.new,
    harness_client_resolver: ->(_agent) { client },
    workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(dir, "workspaces")),
    cwd: dir,
    config_path: File.join(dir, "config.toml")
  )
  read_state = -> { JSON.parse(File.read(state_path)) }
  agent_of = ->(state, id) { state.fetch("agents").find { |record| record.fetch("id") == id } }
  issue_of = ->(state, id) { state.fetch("issues").find { |record| record.fetch("id") == id } }

  puts "0. The harness classifies the last turn from the persisted session file"
  outcome = client.turn_outcome("session_file" => aborted_file, "session_id" => "aborted-sess")
  check("the aborted turn is reported failed") { [outcome.fetch("state") == "failed", outcome.fetch("state")] }
  check("the failure is recognised as a network failure") { [outcome.fetch("kind") == "network_failure", outcome.fetch("kind")] }
  check("the reason is human readable") do
    [outcome.fetch("reason") == "its model request failed mid-turn (network error: Connection error.)", outcome.fetch("reason")]
  end
  finished_outcome = client.turn_outcome("session_file" => finished_file, "session_id" => "finished-sess")
  check("the finished turn is reported completed") { [finished_outcome.fetch("state") == "completed", finished_outcome.fetch("state")] }

  puts "1. Reconciliation settles the aborted worker as errored and the finished one as completed"
  first = engine.apply({ "type" => "ReconcileSessions", "payload" => {} })
  state = read_state.call
  aborted = agent_of.call(state, "P1-I1-W1")
  finished = agent_of.call(state, "P1-I2-W1")
  check("both sessions were checked") { [first.dig("result", "checked_count") == 2, first.dig("result", "checked_count").inspect] }
  check("the aborted worker is errored") { [aborted.fetch("status") == "errored", aborted.fetch("status")] }
  check("no completed_at was written for it") { [aborted.fetch("harness_metadata")["completed_at"].nil?, aborted.fetch("harness_metadata")["completed_at"].inspect] }
  check("the reason is persisted on the record") do
    reason = aborted.dig("harness_metadata", "settle_failure", "reason")
    [reason.to_s.include?("network error: Connection error."), reason.inspect]
  end
  check("the status reason is user facing") do
    [aborted.dig("harness_metadata", "status_reason").to_s.start_with?("errored without finishing:"),
     aborted.dig("harness_metadata", "status_reason").inspect]
  end
  check("the genuinely finished worker still completed") { [finished.fetch("status") == "completed", finished.fetch("status")] }
  check("its result was captured") do
    [finished.dig("harness_metadata", "last_assistant_text").to_s.include?("Done."), finished.dig("harness_metadata", "last_assistant_text").inspect]
  end

  puts "2. The aborted worker's issue is not flipped to completed"
  check("the aborted worker's issue is errored") { [issue_of.call(state, "P1-I1").fetch("status") == "errored", issue_of.call(state, "P1-I1").fetch("status")] }
  check("the finished worker's issue is completed") { [issue_of.call(state, "P1-I2").fetch("status") == "completed", issue_of.call(state, "P1-I2").fetch("status")] }

  puts "3. The log tells the user what happened, once"
  errored_lines = state.fetch("logs").select { |log| log.fetch("message", "").include?("errored without finishing") }
  completed_lines = state.fetch("logs").select { |log| log.fetch("message", "").include?("completed.") }
  check("one error line for the aborted worker") { [errored_lines.length == 1, errored_lines.map { |log| log.fetch("message") }.inspect] }
  check("its level is error") { [errored_lines.first&.fetch("level", nil) == "error", errored_lines.first&.fetch("level", nil).inspect] }
  check("the aborted worker was never logged completed") do
    [completed_lines.none? { |log| log.fetch("message").include?("P1-I1-W1") }, completed_lines.map { |log| log.fetch("message") }.inspect]
  end
  check("the finished worker was logged completed") do
    [completed_lines.any? { |log| log.fetch("message").include?("P1-I2-W1") }, completed_lines.map { |log| log.fetch("message") }.inspect]
  end
  puts "     #{errored_lines.first&.fetch("message")}"

  puts "4. Nine more passes do not re-log or churn the record"
  before = File.read(state_path)
  9.times { engine.apply({ "type" => "ReconcileSessions", "payload" => {} }) }
  state = read_state.call
  check("still one error line") do
    lines = state.fetch("logs").select { |log| log.fetch("message", "").include?("errored without finishing") }
    [lines.length == 1, lines.length.inspect]
  end
  check("the state file is unchanged by the repeat passes") { [File.read(state_path) == before, "state.json was rewritten"] }

  puts "5. The errored worker is still recoverable"
  aborted = agent_of.call(state, "P1-I1-W1")
  check("its session reference survives") { [aborted.fetch("harness_session_file") == aborted_file, aborted.fetch("harness_session_file").inspect] }
  check("its workspace survives") { [Dir.exist?(aborted.fetch("workspace_path")), aborted.fetch("workspace_path").inspect] }
  check("its branch survives") { [aborted.fetch("workspace_branch") == "meringue/fix-prune-retention-b77ba668", aborted.fetch("workspace_branch").inspect] }
  check("a head is told it can be continued") do
    context = Meringue::Heads::Context.new(
      head_id: "H1", user_message: "re-prompt the agents that died", snapshot: state, cwd: dir, state_path: state_path
    )
    candidate = context.to_prompt_h.dig("routing_context", "worker_candidates").find { |worker| worker.fetch("id") == "P1-I1-W1" }
    [candidate.fetch("resumable") && candidate.fetch("stopped_without_finishing"), candidate.slice("resumable", "status_reason").inspect]
  end

  puts "6. A session that starts streaming again clears the reason"
  streaming_client = SettledPiClient.new(session_dir: session_dir, streaming: true)
  streaming_engine = Meringue::Kernel::Engine.new(
    store: Meringue::State::Store.new(path: state_path),
    harness_client: streaming_client,
    head_runner: Meringue::Heads::FakeRunner.new,
    harness_client_resolver: ->(_agent) { streaming_client },
    workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(dir, "workspaces")),
    cwd: dir,
    config_path: File.join(dir, "config.toml")
  )
  streaming_engine.apply({ "type" => "ReconcileSessions", "payload" => {} })
  aborted = agent_of.call(read_state.call, "P1-I1-W1")
  check("the worker is working again") { [aborted.fetch("status") == "working", aborted.fetch("status")] }
  check("the dead-turn reason is gone") { [aborted.dig("harness_metadata", "settle_failure").nil?, aborted.dig("harness_metadata", "settle_failure").inspect] }
  check("the previous failure is kept for history") do
    [aborted.dig("harness_metadata", "previous_settle_failure", "kind") == "network_failure",
     aborted.dig("harness_metadata", "previous_settle_failure").inspect]
  end
end

puts
if FAILURES.empty?
  puts "All network-aborted settle smoke checks passed."
else
  puts "#{FAILURES.length} check(s) failed:"
  FAILURES.each { |failure| puts "  - #{failure}" }
  exit 1
end
