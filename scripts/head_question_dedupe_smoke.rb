#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression smoke for head clarification recording.
#
# A single clarification must produce exactly one stored question and exactly one
# user-visible question log line, whether the head expressed it in the HeadResult
# `questions` array, as an `AskQuestion` kernel command, or (incorrectly) as both.
#
# Usage:
#   ruby scripts/head_question_dedupe_smoke.rb

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

def questions_for(state, head_id)
  state.fetch("questions").select { |question| question.fetch("head_id", nil) == head_id }
end

def question_logs_for(state, head_id)
  state.fetch("logs").select do |entry|
    details = entry.fetch("details", {}) || {}
    details.fetch("head_id", nil) == head_id && entry.fetch("message", "").to_s.start_with?("Question Q")
  end
end

def spawn_head(engine, message)
  result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => message })
  raise "SpawnHead was not accepted: #{result.inspect}" unless result.fetch("status") == "accepted"

  result.fetch("target_id")
end

def apply_head_result(engine, head_id, head_result)
  engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => { "head_id" => head_id, "head_result" => head_result }
  )
end

temp_root = Dir.mktmpdir("meringue-head-question-dedupe-")
project_path = File.join(temp_root, "demo-project")
state_path = File.join(temp_root, "state.json")
workspace_root = File.join(temp_root, "workspaces")
config_path = File.join(temp_root, "config.toml")
FileUtils.mkdir_p(project_path)
FileUtils.mkdir_p(workspace_root)
File.write(File.join(project_path, "README.md"), "# Head question dedupe smoke\n")

engine = Meringue::Kernel::Engine.new(
  store: Meringue::State::Store.new(path: state_path),
  harness_client: Meringue::Harness::FakeClient.new,
  head_runner: Meringue::Heads::FakeRunner.new,
  workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
  cwd: project_path,
  config_path: config_path
)

begin
  project = engine.apply("type" => "AddProject", "payload" => { "path" => project_path, "name" => "demo-project" })
  raise "AddProject was not accepted: #{project.inspect}" unless project.fetch("status") == "accepted"

  project_id = project.fetch("target_id")

  # Reproduces the reported H53 duplicate: the head restated one clarification as both a
  # questions entry and an AskQuestion command, and the kernel stored Q1 and Q2 for it.
  puts "Scenario 1: AskQuestion command plus a matching questions entry (the reported duplicate)"
  head_id = spawn_head(engine, "What is the issue?")
  duplicate_result = apply_head_result(
    engine,
    head_id,
    "title" => "Clarify routing",
    "summary" => "Need one clarification before routing.",
    "commands" => [
      {
        "type" => "AskQuestion",
        "payload" => {
          "head_id" => head_id,
          "question" => "What would you like me to route here? Are you (a) asking about a previously killed/pruned Meringue issue (e.g. P1-I3), or (b) reporting a problem in the meringue project that a worker should investigate? If (b), please describe the symptom or area.",
          "context" => "The same clarification, restated as a command."
        }
      }
    ],
    "questions" => [
      {
        "question" => "What would you like me to route here? Are you asking about a previously killed/pruned Meringue issue (e.g. P1-I3), or reporting a problem in the meringue project for a worker to investigate?",
        "context" => "No active issues or workers exist in state, so there is nothing to reuse or prompt.",
        "project_id" => project_id
      }
    ]
  )
  state = engine.list_all
  stored = questions_for(state, head_id)
  logs = question_logs_for(state, head_id)
  command_results = duplicate_result.dig("result", "command_results") || []
  check("stores exactly one question") { [stored.length == 1, "stored #{stored.length}: #{stored.map { |q| q.fetch("id") }.join(", ")}"] }
  check("emits exactly one question log line") { [logs.length == 1, "logged #{logs.length}"] }
  check("keeps the canonical questions-array record") do
    [stored.first&.fetch("project_id", nil) == project_id, stored.first&.fetch("project_id", nil).inspect]
  end
  check("accepts the duplicate AskQuestion command against the stored question") do
    result = command_results.first || {}
    [
      result.fetch("status", nil) == "accepted" && result.fetch("target_id", nil) == stored.first&.fetch("id", nil),
      result.slice("status", "target_id", "message").to_s
    ]
  end
  first_question_id = stored.first&.fetch("id", nil)

  puts "Scenario 2: questions array only"
  head_id = spawn_head(engine, "Which repo should this go to?")
  apply_head_result(
    engine,
    head_id,
    "title" => "Clarify project",
    "summary" => "Ambiguous project.",
    "commands" => [],
    "questions" => [
      { "question" => "Which project should receive this change?", "context" => "Multiple projects are plausible." }
    ]
  )
  state = engine.list_all
  stored = questions_for(state, head_id)
  check("stores exactly one question") { [stored.length == 1, "stored #{stored.length}"] }
  check("emits exactly one question log line") { [question_logs_for(state, head_id).length == 1, nil] }

  puts "Scenario 3: AskQuestion command only"
  head_id = spawn_head(engine, "Do the thing")
  command_only_result = apply_head_result(
    engine,
    head_id,
    "title" => "Clarify scope",
    "summary" => "Ambiguous scope.",
    "commands" => [
      {
        "type" => "AskQuestion",
        "payload" => {
          "head_id" => head_id,
          "question" => "Which part of the app should change?",
          "context" => "The request does not name an area.",
          "project_id" => project_id
        }
      }
    ],
    "questions" => []
  )
  state = engine.list_all
  stored = questions_for(state, head_id)
  check("stores exactly one question") { [stored.length == 1, "stored #{stored.length}"] }
  check("emits exactly one question log line") { [question_logs_for(state, head_id).length == 1, nil] }
  check("accepts the AskQuestion command") do
    result = (command_only_result.dig("result", "command_results") || []).first || {}
    [result.fetch("status", nil) == "accepted" && result.fetch("target_id", nil) == stored.first&.fetch("id", nil), result.inspect]
  end

  puts "Scenario 4: repeated AskQuestion commands for the same clarification"
  head_id = spawn_head(engine, "Retry the same question twice")
  repeated_payload = {
    "head_id" => head_id,
    "question" => "Should I reuse the existing issue?",
    "context" => "Two plausible issues."
  }
  apply_head_result(
    engine,
    head_id,
    "title" => "Clarify reuse",
    "summary" => "Ambiguous issue reuse.",
    "commands" => [
      { "type" => "AskQuestion", "payload" => repeated_payload },
      { "type" => "AskQuestion", "payload" => repeated_payload.merge("question" => "  Should I reuse the existing issue?  ") }
    ],
    "questions" => []
  )
  state = engine.list_all
  check("stores exactly one question") { [questions_for(state, head_id).length == 1, "stored #{questions_for(state, head_id).length}"] }
  check("emits exactly one question log line") { [question_logs_for(state, head_id).length == 1, nil] }

  puts "Scenario 5: two distinct clarifications from one head"
  head_id = spawn_head(engine, "Two ambiguities at once")
  apply_head_result(
    engine,
    head_id,
    "title" => "Clarify twice",
    "summary" => "Two independent ambiguities.",
    "commands" => [
      {
        "type" => "AskQuestion",
        "payload" => { "head_id" => head_id, "question" => "Which project should receive the fix?", "context" => "Ambiguous project." }
      }
    ],
    "questions" => [
      { "question" => "Should the fix ship behind a flag?", "context" => "Rollout is unclear." }
    ]
  )
  state = engine.list_all
  stored = questions_for(state, head_id)
  check("stores both distinct questions") { [stored.length == 2, "stored #{stored.length}: #{stored.map { |q| q.fetch("question") }.inspect}"] }
  check("emits one log line per question") { [question_logs_for(state, head_id).length == 2, nil] }
  distinct_ids = stored.map { |question| question.fetch("id") }

  puts "Scenario 6: question lifecycle still works"
  answered = engine.apply("type" => "AnswerQuestion", "payload" => { "question_id" => first_question_id, "answer" => "Route it to a worker." })
  dismissed = engine.apply("type" => "DismissQuestion", "payload" => { "question_id" => distinct_ids.first })
  state = engine.list_all
  answered_question = state.fetch("questions").find { |question| question.fetch("id") == first_question_id }
  dismissed_question = state.fetch("questions").find { |question| question.fetch("id") == distinct_ids.first }
  check("AnswerQuestion marks the question answered") do
    [answered.fetch("status") == "accepted" && answered_question.fetch("status") == "answered", answered_question.fetch("status")]
  end
  check("DismissQuestion marks the question dismissed") do
    [dismissed.fetch("status") == "accepted" && dismissed_question.fetch("status") == "dismissed", dismissed_question.fetch("status")]
  end

  puts
  if FAILURES.empty?
    puts "All head clarification checks passed."
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
