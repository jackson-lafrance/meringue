#!/usr/bin/env ruby
# frozen_string_literal: true

# Demonstrates the head-agent harness session lifetime without touching a real harness.
# A head owns one tracked harness session from SpawnHead until the kernel tears it down,
# so this script prints the head record and lifecycle logs at each stage.

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/meringue"

HEAD_RESULT = {
  "title" => "Head session smoke",
  "summary" => "Routing-only result used to demonstrate head session teardown.",
  "commands" => [],
  "questions" => []
}.freeze

# Stands in for a harness process: hands out session identities, records kills, and
# returns a valid HeadResult as its last assistant message.
class SmokeHarnessClient < Meringue::Harness::FakeClient
  attr_reader :killed_session_ids

  def initialize
    @session_count = 0
    @killed_session_ids = []
  end

  def harness_name
    "pi"
  end

  def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
    @session_count += 1
    {
      "harness" => "pi",
      "pid" => 40_000 + @session_count,
      "cwd" => cwd,
      "session_id" => "smoke-#{kind}-#{@session_count}",
      "session_file" => File.join(cwd, "smoke-#{kind}-#{@session_count}.jsonl"),
      "is_streaming" => false,
      "last_event_at" => nil,
      "metadata" => { "session_name" => session_name }
    }
  end

  def kill_session(session_ref)
    @killed_session_ids << session_ref.fetch("session_id", nil)
    session_ref.merge("killed" => true, "is_streaming" => false)
  end

  def last_assistant_text(_session_ref)
    JSON.generate(HEAD_RESULT)
  end
end

def print_head_session(store, label)
  head = store.load.fetch("agents").find { |agent| agent.fetch("type", nil) == "head" }
  puts "\n#{label}"
  if head.nil?
    puts "  head record: (removed from active state)"
    return
  end

  metadata = head.fetch("harness_metadata", {})
  puts "  id: #{head.fetch("id")} status: #{head.fetch("status")} harness: #{head.fetch("harness")}"
  puts "  pid: #{head.fetch("pid").inspect} session_id: #{head.fetch("harness_session_id").inspect}"
  puts "  session_file: #{head.fetch("harness_session_file").inspect}"
  puts "  head_session_state: #{metadata.fetch("head_session_state", nil).inspect}"
  puts "  head_session_started_at: #{metadata.fetch("head_session_started_at", nil).inspect}"
  puts "  head_session_released_at: #{metadata.fetch("head_session_released_at", nil).inspect}"
  puts "  head_session_release_reason: #{metadata.fetch("head_session_release_reason", nil).inspect}"
end

def print_session_logs(store)
  puts "\nHead lifecycle logs:"
  store.load.fetch("logs").select { |log| %w[harness head kernel].include?(log.fetch("source_type", nil)) }.each do |log|
    puts "  #{log.fetch("id")} [#{log.fetch("source_type")}] #{log.fetch("source_id").inspect} #{log.fetch("message")}"
  end
end

prompt = ARGV.join(" ").strip
prompt = "route a harmless docs cleanup" if prompt.empty?

temp_root = Dir.mktmpdir("meringue-head-session-smoke-")
begin
  store = Meringue::State::Store.new(path: File.join(temp_root, "state.json"))
  client = SmokeHarnessClient.new
  runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: temp_root, timeout: 5)
  engine = Meringue::Kernel::Engine.new(
    store: store,
    harness_client: client,
    head_runner: runner,
    harness_client_resolver: ->(_agent) { client },
    harness_client_provider: ->(_provider) { client },
    head_runner_provider: ->(_provider) { runner },
    default_harness_provider: "pi",
    cwd: temp_root
  )

  spawn_result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => prompt })
  puts "SpawnHead: #{spawn_result.fetch("status")} — #{spawn_result.fetch("message")}"
  print_head_session(store, "Head record while the head is still alive (result collected, not yet applied):")
  puts "\nHarness sessions killed so far: #{client.killed_session_ids.inspect}"

  head_result = spawn_result.dig("result", "harness_metadata", "head_result")
  apply_result = engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => { "head_id" => spawn_result.fetch("target_id"), "head_result" => head_result }
  )
  puts "\nApplyHeadResult: #{apply_result.fetch("status")} — #{apply_result.fetch("message")}"
  puts "Head cleanup: #{JSON.generate(apply_result.dig("result", "head_cleanup"))}"
  print_head_session(store, "Head record after its result was applied:")
  puts "\nHarness sessions killed after teardown: #{client.killed_session_ids.inspect}"
  print_session_logs(store)
ensure
  unless ENV["MERINGUE_KEEP_SMOKE"] == "1"
    FileUtils.remove_entry(temp_root) if Dir.exist?(temp_root)
  end
end
