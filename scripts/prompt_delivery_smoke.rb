#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression smoke for prompt delivery when a worker session is momentarily busy.
#
# Covers the 20:42 failure in ~/.meringue/state.json:
#   "Failed PromptAgent: Harness failed to prompt agent P1-I6-W1: Meringue instance 6869 owns this
#    Pi session (process 1920) and is still mid-turn. ..."
#
# A busy session is transient, so the kernel queues the prompt, redelivers it during reconciliation,
# and logs the delivery only once the harness has accepted it. Non-transient harness failures must
# still fail the command.
#
# Usage:
#   ruby scripts/prompt_delivery_smoke.rb

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

def logs_matching(state, snippet)
  state.fetch("logs").select { |entry| entry.fetch("message", "").to_s.include?(snippet) }
end

def error_logs(state)
  state.fetch("logs").select { |entry| entry.fetch("level", nil) == "error" }
end

def pending_prompts(state, agent_id)
  agent = state.fetch("agents").find { |candidate| candidate.fetch("id", nil) == agent_id }
  metadata = agent ? (agent.fetch("harness_metadata", {}) || {}) : {}
  Array(metadata.fetch("pending_prompts", []))
end

# The busy-session error class is new; fall back so this script also runs against older code and
# shows how the same harness rejection behaved before the fix.
BUSY_ERROR_CLASS = if Meringue::Harness::PiClient.const_defined?(:SessionBusyError)
                     Meringue::Harness::PiClient::SessionBusyError
                   else
                     Meringue::Harness::PiClient::SessionTransportUnavailableError
                   end

# Rejects prompts with the harness's transient "another instance is mid-turn" error until the
# configured number of attempts have been made.
class BusyThenReadyClient < Meringue::Harness::FakeClient
  attr_reader :prompt_attempts

  def initialize(busy_attempts:)
    @busy_attempts = busy_attempts
    @prompt_attempts = 0
    super()
  end

  def prompt_session(session_ref, prompt, mode: "normal")
    @prompt_attempts += 1
    if @prompt_attempts <= @busy_attempts
      raise BUSY_ERROR_CLASS,
            "Meringue instance 6869 owns this Pi session (process 1920) and is still mid-turn. " \
            "Prompting will take it over automatically once that turn settles: retry in a moment."
    end

    super
  end
end

class BrokenPromptClient < Meringue::Harness::FakeClient
  def prompt_session(_session_ref, _prompt, mode: "normal")
    raise Meringue::Harness::PiClient::ProcessExitedError, "Pi process 1920 exited before the prompt was delivered."
  end
end

def build_engine(state_path:, workspace_root:, project_path:, config_path:, harness_client:)
  Meringue::Kernel::Engine.new(
    store: Meringue::State::Store.new(path: state_path),
    harness_client: harness_client,
    head_runner: Meringue::Heads::FakeRunner.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
    cwd: project_path,
    config_path: config_path
  )
end

def seed_worker!(engine, project_path)
  project = engine.apply("type" => "AddProject", "payload" => { "path" => project_path, "name" => "demo-project" })
  raise "AddProject failed: #{project.inspect}" unless project.fetch("status") == "accepted"

  project_id = project.fetch("target_id")
  issue = engine.apply(
    "type" => "CreateIssue",
    "payload" => { "project_id" => project_id, "title" => "Busy session goal", "description" => "Prompt delivery smoke." }
  )
  raise "CreateIssue failed: #{issue.inspect}" unless issue.fetch("status") == "accepted"

  worker = engine.apply(
    "type" => "SpawnWorker",
    "payload" => { "issue_id" => issue.fetch("target_id"), "title" => "Busy session goal", "prompt" => "Start the work." }
  )
  raise "SpawnWorker failed: #{worker.inspect}" unless worker.fetch("status") == "accepted"

  worker.fetch("target_id")
end

temp_root = Dir.mktmpdir("meringue-prompt-delivery-smoke-")
state_path = File.join(temp_root, "state.json")
workspace_root = File.join(temp_root, "workspaces")
config_path = File.join(temp_root, "config.toml")
project_path = File.join(temp_root, "demo-project")
FileUtils.mkdir_p(project_path)
FileUtils.mkdir_p(workspace_root)
File.write(File.join(project_path, "README.md"), "# prompt delivery smoke\n")

begin
  puts "Scenario 1: a busy session queues the follow-up instead of failing the command"
  busy_client = BusyThenReadyClient.new(busy_attempts: 1)
  engine = build_engine(state_path: state_path, workspace_root: workspace_root, project_path: project_path,
                        config_path: config_path, harness_client: busy_client)
  worker_id = seed_worker!(engine, project_path)
  queued = engine.apply(
    "command_id" => "H56-C2",
    "type" => "PromptAgent",
    "payload" => { "agent_id" => worker_id, "prompt" => "Also check the reconcile path.", "mode" => "follow_up" }
  )
  state = engine.list_all
  check("PromptAgent is accepted rather than failed") { [queued.fetch("status") == "accepted", "#{queued.fetch("status")}: #{queued.fetch("message")}"] }
  check("the prompt is recorded as queued") { [queued.dig("result", "queued") == true, queued.fetch("result").inspect] }
  check("no error log is emitted") { [error_logs(state).empty?, error_logs(state).map { |entry| entry.fetch("message") }.inspect] }
  check("no success log is emitted before the harness accepts") do
    delivered = logs_matching(state, "Queued a follow-up for worker")
    [delivered.empty?, "logged #{delivered.length}"]
  end
  check("a waiting notice is logged once") do
    waiting = logs_matching(state, "Waiting to deliver the follow-up")
    [waiting.length == 1, "logged #{waiting.length}"]
  end
  check("one pending prompt is stored on the worker") { [pending_prompts(state, worker_id).length == 1, pending_prompts(state, worker_id).inspect] }

  puts "Scenario 2: reconciliation redelivers the queued follow-up exactly once"
  reconciled = engine.apply("type" => "ReconcileSessions", "payload" => {})
  state = engine.list_all
  check("reconciliation is accepted") { [reconciled.fetch("status") == "accepted", reconciled.fetch("message")] }
  check("the follow-up is delivered and logged once") do
    delivered = logs_matching(state, "Queued a follow-up for worker")
    [delivered.length == 1, "logged #{delivered.length}"]
  end
  check("the pending prompt is cleared") { [pending_prompts(state, worker_id).empty?, pending_prompts(state, worker_id).inspect] }
  check("still no error logs") { [error_logs(state).empty?, error_logs(state).map { |entry| entry.fetch("message") }.inspect] }
  check("a later reconciliation does not resend it") do
    engine.apply("type" => "ReconcileSessions", "payload" => {})
    delivered = logs_matching(engine.list_all, "Queued a follow-up for worker")
    [delivered.length == 1, "logged #{delivered.length}"]
  end

  puts "Scenario 3: duplicate PromptAgent commands for one queued prompt do not stack up"
  busy_client_two = BusyThenReadyClient.new(busy_attempts: 5)
  engine = build_engine(state_path: state_path, workspace_root: workspace_root, project_path: project_path,
                        config_path: config_path, harness_client: busy_client_two)
  first = engine.apply(
    "command_id" => "H57-C1",
    "type" => "PromptAgent",
    "payload" => { "agent_id" => worker_id, "prompt" => "Look at the checkpoint path too.", "mode" => "follow_up" }
  )
  second = engine.apply(
    "command_id" => "H57-C1",
    "type" => "PromptAgent",
    "payload" => { "agent_id" => worker_id, "prompt" => "Look at the checkpoint path too.", "mode" => "follow_up" }
  )
  state = engine.list_all
  check("both applications are accepted") do
    [[first, second].all? { |result| result.fetch("status") == "accepted" }, [first.fetch("status"), second.fetch("status")].inspect]
  end
  check("only one pending prompt is stored") { [pending_prompts(state, worker_id).length == 1, pending_prompts(state, worker_id).inspect] }
  check("only one waiting notice is logged") do
    waiting = logs_matching(state, "Waiting to deliver the follow-up")
    [waiting.length == 2, "expected 1 new notice, logged #{waiting.length - 1}"]
  end

  puts "Scenario 4: a non-transient harness failure still fails the command"
  broken_engine = build_engine(state_path: state_path, workspace_root: workspace_root, project_path: project_path,
                               config_path: config_path, harness_client: BrokenPromptClient.new)
  broken = broken_engine.apply(
    "type" => "PromptAgent",
    "payload" => { "agent_id" => worker_id, "prompt" => "This one cannot be delivered.", "mode" => "normal" }
  )
  check("PromptAgent fails for a non-transient error") { [broken.fetch("status") == "failed", "#{broken.fetch("status")}: #{broken.fetch("message")}"] }
  check("the failure is not queued") do
    entries = pending_prompts(broken_engine.list_all, worker_id)
    [entries.none? { |entry| entry.fetch("prompt", nil) == "This one cannot be delivered." }, entries.inspect]
  end

  puts
  if FAILURES.empty?
    puts "All prompt delivery checks passed."
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
