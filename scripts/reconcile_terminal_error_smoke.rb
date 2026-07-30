#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage for the reconciliation log-once contract.
#
# `ReconcileSessions` runs every two seconds for as long as Meringue is open. A head whose
# harness session can never return a parseable HeadResult (for example a provider that keeps
# returning "Overloaded" and therefore empty assistant messages) used to be re-polled,
# re-marked `errored`, and re-logged on every pass, producing several identical error lines per
# second and evicting the user's real log history.
#
# This script drives ten reconciliation passes over one unrepairable head and one unrepairable
# worker and asserts that each failure is recorded exactly once, that state stops changing, and
# that `/prune` is what finally clears the records.
#
# Usage:
#   ruby scripts/reconcile_terminal_error_smoke.rb

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

# Stands in for a harness whose sessions are settled but useless: the head answers with prose
# instead of HeadResult JSON, and the worker's process is gone.
class BrokenHarnessClient
  attr_reader :calls

  def initialize
    @calls = []
  end

  def harness_name
    "stub"
  end

  def get_state(session_ref)
    @calls << ["get_state", session_ref.fetch("session_id", nil)]
    raise RuntimeError, "harness process is not alive" if session_ref.fetch("session_id", nil) == "worker-sess"

    session_ref.merge("is_streaming" => false, "metadata" => (session_ref.fetch("metadata", nil) || {}).merge("completed" => true))
  end

  def read_events(_session_ref)
    []
  end

  def last_assistant_text(_session_ref)
    "Sorry, I could not do that."
  end

  def prompt_session(session_ref, _prompt, mode: "normal")
    @calls << ["prompt_session", session_ref.fetch("session_id", nil), mode]
    session_ref
  end

  def kill_session(session_ref)
    @calls << ["kill_session", session_ref.fetch("session_id", nil)]
    session_ref.merge("is_streaming" => false)
  end
end

def state_fixture
  {
    "schema_version" => Meringue::State::Models::SCHEMA_VERSION,
    "projects" => [
      { "id" => "P1", "name" => "demo", "root_path" => Dir.tmpdir, "status" => "working", "created_at" => NOW, "updated_at" => NOW }
    ],
    "issues" => [
      { "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Demo", "description" => "Demo",
        "status" => "working", "agent_ids" => ["P1-I1-W1"], "created_at" => NOW, "updated_at" => NOW }
    ],
    "agents" => [
      { "id" => "H1", "type" => "head", "status" => "working", "project_id" => nil, "issue_id" => nil,
        "title" => "Head H1", "harness" => "pi", "pid" => Process.pid.to_s, "harness_session_id" => "head-sess",
        "harness_session_file" => nil,
        "harness_metadata" => { "head_session_state" => "active", "head_result_repair_count" => 1 },
        "created_at" => NOW, "updated_at" => NOW },
      { "id" => "P1-I1-W1", "type" => "worker", "status" => "working", "project_id" => "P1", "issue_id" => "P1-I1",
        "title" => "Worker P1-I1-W1", "harness" => "pi", "pid" => Process.pid.to_s,
        "harness_session_id" => "worker-sess", "harness_session_file" => nil,
        "harness_metadata" => { "reconcile" => { "resume_attempt_count" => 3 } },
        "created_at" => NOW, "updated_at" => NOW }
    ],
    "questions" => [],
    "logs" => [],
    "conversation" => { "messages" => [], "next_message_id" => 0 },
    "counters" => { "projects" => 1, "heads" => 1, "questions" => 0, "logs" => 0,
                    "issues_by_project" => { "P1" => 1 }, "workers_by_issue" => { "P1-I1" => 1 } },
    "metadata" => { "created_at" => NOW, "updated_at" => NOW }
  }
end

def reconcile_error_lines(state)
  Array(state.fetch("logs")).select do |log|
    log.fetch("level", nil) == "error" && log.fetch("message", "").include?("errored while reconciling")
  end
end

Dir.mktmpdir("meringue-reconcile-smoke") do |dir|
  state_path = File.join(dir, "state.json")
  File.write(state_path, JSON.pretty_generate(state_fixture) + "\n")

  client = BrokenHarnessClient.new
  engine = Meringue::Kernel::Engine.new(
    store: Meringue::State::Store.new(path: state_path),
    harness_client: client,
    head_runner: Meringue::Heads::FakeRunner.new,
    harness_client_resolver: ->(_agent) { client },
    workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(dir, "workspaces")),
    cwd: dir,
    config_path: File.join(dir, "config.toml")
  )

  puts "1. First reconciliation pass records both failures"
  first = engine.apply({ "type" => "ReconcileSessions", "payload" => {} })
  state = JSON.parse(File.read(state_path))
  check("both sessions were checked") { [first.dig("result", "checked_count") == 2, first.dig("result", "checked_count").inspect] }
  check("the head is errored") { [state.fetch("agents").find { |a| a.fetch("id") == "H1" }.fetch("status") == "errored", nil] }
  check("the worker is errored") { [state.fetch("agents").find { |a| a.fetch("id") == "P1-I1-W1" }.fetch("status") == "errored", nil] }
  check("the failed head session was released") do
    metadata = state.fetch("agents").find { |a| a.fetch("id") == "H1" }.fetch("harness_metadata")
    [metadata.fetch("head_session_state", nil) == "released", metadata.fetch("head_session_state", nil).inspect]
  end
  check("the orphaned head process was killed") { [client.calls.include?(["kill_session", "head-sess"]), nil] }
  check("exactly two error lines were logged") { [reconcile_error_lines(state).length == 2, reconcile_error_lines(state).length.to_s] }

  puts "\n2. Ten more passes add no log lines, no state writes, and no harness traffic"
  settled_json = File.read(state_path)
  settled_calls = client.calls.dup
  changed = 0
  10.times do
    result = engine.apply({ "type" => "ReconcileSessions", "payload" => {} })
    changed += result.dig("result", "changed_count").to_i
    changed += 1 unless result.dig("result", "checked_count").to_i.zero?
  end
  state = JSON.parse(File.read(state_path))
  check("no record was checked or changed again") { [changed.zero?, changed.to_s] }
  check("the state file is byte-identical") { [settled_json == File.read(state_path), nil] }
  check("the harness was not contacted again") { [settled_calls == client.calls, (client.calls - settled_calls).inspect] }
  check("still exactly two error lines") { [reconcile_error_lines(state).length == 2, reconcile_error_lines(state).length.to_s] }

  puts "\n3. /prune is what clears the settled records"
  prune = engine.apply({ "type" => "Prune", "payload" => {} })
  state = JSON.parse(File.read(state_path))
  check("prune removed the standalone errored head") do
    [Array(prune.dig("result", "removed_standalone_agent_ids")).include?("H1"), prune.dig("result", "removed_standalone_agent_ids").inspect]
  end
  check("prune removed the errored worker's issue bundle") { [state.fetch("agents").empty?, state.fetch("agents").map { |a| a.fetch("id") }.inspect] }
end

puts
if FAILURES.empty?
  puts "reconcile terminal error smoke: PASS"
else
  puts "reconcile terminal error smoke: FAIL (#{FAILURES.length} check(s))"
  exit 1
end
