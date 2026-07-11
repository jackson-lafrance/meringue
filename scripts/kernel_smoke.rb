#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "tmpdir"

require_relative "../lib/meringue/state/models"
require_relative "../lib/meringue/state/store"
require_relative "../lib/meringue/kernel/commands"
require_relative "../lib/meringue/kernel/results"
require_relative "../lib/meringue/kernel/engine"
require_relative "../lib/meringue/workspace/manager"
require_relative "../lib/meringue/harness/client"
require_relative "../lib/meringue/harness/fake_client"
require_relative "../lib/meringue/heads/runner"
require_relative "../lib/meringue/heads/fake_runner"

options = {
  pi: false,
  keep_alive: false,
  project_path: nil,
  state_path: nil,
  prompt: "Reply with one short acknowledgement that the smoke worker session started.",
  wait: false,
  timeout: 90
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby -Ilib scripts/kernel_smoke.rb [options]"

  parser.on("--pi", "Use the real Pi RPC harness instead of the fake harness.") do
    options[:pi] = true
  end

  parser.on("--keep-alive", "With --pi, leave the spawned Pi worker process running after the smoke.") do
    options[:keep_alive] = true
  end

  parser.on("--wait", "With --pi, wait for the worker prompt to settle and print the last assistant text.") do
    options[:wait] = true
  end

  parser.on("--timeout SECONDS", Integer, "Pi event timeout for --wait. Defaults to 90.") do |seconds|
    options[:timeout] = seconds
  end

  parser.on("--project PATH", "Project directory to register. Defaults to a temp demo project.") do |path|
    options[:project_path] = path
  end

  parser.on("--state PATH", "State JSON path. Defaults to a temp state file.") do |path|
    options[:state_path] = path
  end

  parser.on("--prompt PROMPT", "Worker prompt. Defaults to a harmless acknowledgement prompt.") do |prompt|
    options[:prompt] = prompt
  end
end.parse!

temp_root = Dir.mktmpdir("meringue-kernel-smoke-")
project_path = File.expand_path(options[:project_path] || File.join(temp_root, "demo-project"))
state_path = File.expand_path(options[:state_path] || File.join(temp_root, "state.json"))
workspace_root = File.join(temp_root, "workspaces")
session_dir = File.join(temp_root, "pi-sessions")
FileUtils.mkdir_p(project_path)
FileUtils.mkdir_p(File.dirname(state_path))
FileUtils.mkdir_p(workspace_root)
FileUtils.mkdir_p(session_dir)
if options[:project_path].nil?
  File.write(File.join(project_path, "README.md"), "# Kernel smoke demo\n")
end

if options[:pi]
  require_relative "../lib/meringue/harness/pi_client"

  harness_client = Meringue::Harness::PiClient.new(
    session_dir: session_dir,
    extra_args: [
      "--thinking", "minimal",
      "--no-tools",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-context-files"
    ],
    event_timeout: options[:timeout]
  )
else
  harness_client = Meringue::Harness::FakeClient.new
end

def session_ref_from_agent(agent)
  metadata = agent.fetch("harness_metadata", {}) || {}
  {
    "harness" => agent.fetch("harness", nil),
    "pid" => agent.fetch("pid", nil),
    "cwd" => metadata.fetch("cwd", agent.fetch("workspace_path", nil)),
    "session_id" => agent.fetch("harness_session_id", nil),
    "session_file" => agent.fetch("harness_session_file", nil),
    "is_streaming" => metadata.fetch("is_streaming", false),
    "last_event_at" => metadata.fetch("last_event_at", nil),
    "metadata" => metadata
  }
end

store = Meringue::State::Store.new(path: state_path)
engine = Meringue::Kernel::Engine.new(
  store: store,
  harness_client: harness_client,
  workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root)
)

results = []
worker_agent = nil

begin
  results << engine.apply(
    "type" => "AddProject",
    "payload" => {
      "path" => project_path,
      "name" => "KernelSmoke"
    }
  )

  project_id = results.last.fetch("target_id")
  results << engine.apply(
    "type" => "CreateIssue",
    "payload" => {
      "project_id" => project_id,
      "title" => "Smoke worker session",
      "description" => "Create a worker through the kernel and persist its harness session metadata."
    }
  )

  issue_id = results.last.fetch("target_id")
  results << engine.apply(
    "type" => "SpawnWorker",
    "payload" => {
      "issue_id" => issue_id,
      "prompt" => options[:prompt]
    }
  )

  worker_agent = results.last.fetch("result") if results.last.fetch("status") == "accepted"

  puts "Kernel command results:"
  puts JSON.pretty_generate(results)

  if options[:pi] && options[:wait] && worker_agent
    session_ref = session_ref_from_agent(worker_agent)
    events = harness_client.wait_for_settled(session_ref, timeout: options[:timeout])
    puts "\nPi worker settled after #{events.length} structured event(s)."
    puts "Last assistant text:"
    puts harness_client.last_assistant_text(session_ref)
  end

  puts "\nPersisted state path: #{state_path}"
  puts JSON.pretty_generate(store.load)
ensure
  if options[:pi] && worker_agent && !options[:keep_alive]
    harness_client.kill_session(session_ref_from_agent(worker_agent))
    warn "\nCleaned up Pi worker process. The temp state above still shows the spawned session metadata."
  end

  unless options[:state_path] || options[:project_path] || options[:keep_alive]
    FileUtils.remove_entry(temp_root) if Dir.exist?(temp_root)
  end
end

