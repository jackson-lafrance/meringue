#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression smoke for question answering.
#
# Reproduces and covers the reported no-op: answering an open question logged only
# "Answered question Q<n>." and no head, worker, or prompt work followed, so the answer
# never reached the context the question came from.
#
# Checks:
#   1. /answer parses to AnswerQuestion, and AnswerQuestion records the answer, closes the
#      question, and spawns a head carrying the answer plus the original question context
#      (question text, context, project/issue scope, asking head, original user message).
#   2. Head context surfaces full open-question records and implicit-answer inference rules.
#   3. A HeadResult that combines AnswerQuestion with routing commands is accepted and applied
#      in order, closes the question, and does not spawn a second head for the same answer.
#   4. Ambiguous or unrelated messages leave open questions untouched.
#
# Usage:
#   ruby scripts/question_answer_smoke.rb

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

# Head runner stub. Returns a scripted HeadResult per spawn and records the head context it was
# given, so the smoke can assert on the contract the real head agent reads.
class ScriptedRunner < Meringue::Heads::Runner
  attr_reader :contexts, :messages

  def initialize
    @results = []
    @contexts = []
    @messages = []
  end

  def script(&builder)
    @results << builder
    self
  end

  def run(user_message:, snapshot:, context: nil, question_id: nil)
    @messages << user_message
    @contexts << context
    builder = @results.shift
    return empty_result("No scripted head result remained.") unless builder

    builder.call(user_message: user_message, snapshot: snapshot, context: context, question_id: question_id)
  end

  def last_context_hash
    context = @contexts.compact.last
    context ? context.to_prompt_h : {}
  end

  def empty_result(summary)
    { "title" => "No routing", "summary" => summary, "commands" => [], "questions" => [] }
  end
end

def open_questions(state)
  state.fetch("questions").select { |question| question.fetch("status", nil) == "open" }
end

def question_by_id(state, id)
  state.fetch("questions").find { |question| question.fetch("id", nil) == id }
end

def heads(state)
  state.fetch("agents").select { |agent| agent.fetch("type", nil) == "head" }
end

def head_count(engine)
  state = engine.list_all
  # Heads are removed from active state once their result is applied, so count spawn logs instead.
  state.fetch("logs").count { |entry| (entry.fetch("details", {}) || {}).key?("head_id") && entry.fetch("source_type", nil) == "user" }
end

def spawn_head(engine, message)
  result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => message })
  raise "SpawnHead was not accepted: #{result.inspect}" unless result.fetch("status") == "accepted"

  result.fetch("target_id")
end

def apply_head_result(engine, head_id, head_result)
  engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => head_result })
end

temp_root = Dir.mktmpdir("meringue-question-answer-smoke-")
project_path = File.join(temp_root, "demo-project")
state_path = File.join(temp_root, "state.json")
workspace_root = File.join(temp_root, "workspaces")
config_path = File.join(temp_root, "config.toml")
FileUtils.mkdir_p(project_path)
FileUtils.mkdir_p(workspace_root)
File.write(File.join(project_path, "README.md"), "# Question answering smoke\n")

runner = ScriptedRunner.new
engine = Meringue::Kernel::Engine.new(
  store: Meringue::State::Store.new(path: state_path),
  harness_client: Meringue::Harness::FakeClient.new,
  head_runner: runner,
  workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
  cwd: project_path,
  config_path: config_path
)

begin
  project = engine.apply("type" => "AddProject", "payload" => { "path" => project_path, "name" => "demo-project" })
  raise "AddProject failed: #{project.inspect}" unless project.fetch("status") == "accepted"

  project_id = project.fetch("target_id")
  issue = engine.apply(
    "type" => "CreateIssue",
    "payload" => { "project_id" => project_id, "title" => "Explain worker spawning", "description" => "Question answering smoke." }
  )
  raise "CreateIssue failed: #{issue.inspect}" unless issue.fetch("status") == "accepted"

  issue_id = issue.fetch("target_id")
  worker = engine.apply(
    "type" => "SpawnWorker",
    "payload" => { "issue_id" => issue_id, "title" => "Explain worker spawning", "prompt" => "Start the investigation." }
  )
  raise "SpawnWorker failed: #{worker.inspect}" unless worker.fetch("status") == "accepted"

  worker_id = worker.fetch("target_id")

  puts "Scenario 1: a head asks a clarifying question"
  original_user_message = "the worker from i8 got spawned into i7 somehow, look into it"
  runner.script do |_args|
    {
      "title" => "Clarify the report",
      "summary" => "Need the evidence before routing.",
      "commands" => [],
      "questions" => [
        {
          "question" => "Can you share the exact snippet or log lines that show the worker being spawned into the wrong issue?",
          "context" => "Without the evidence the worker cannot reproduce the mis-routed spawn.",
          "project_id" => project_id,
          "issue_id" => issue_id
        }
      ]
    }
  end
  asking_head_id = spawn_head(engine, original_user_message)
  asking_head_result = engine.list_all.fetch("agents").find { |agent| agent.fetch("id") == asking_head_id }
                             .fetch("harness_metadata").fetch("head_result")
  apply_head_result(engine, asking_head_id, asking_head_result)
  state = engine.list_all
  question = open_questions(state).last
  check("stores the open question") { [!question.nil?, "questions: #{state.fetch("questions").length}"] }
  check("captures the original triggering user message on the question") do
    [question&.fetch("original_user_message", nil).to_s.include?("i8"), question&.fetch("original_user_message", nil).inspect]
  end
  question_id = question&.fetch("id")

  puts "Scenario 2: head context surfaces open questions and inference rules"
  context = Meringue::Heads::Context.new(
    head_id: "H?",
    user_message: "ANSWERING #{question_id} here is the snippet from the log",
    snapshot: engine.list_all,
    cwd: project_path,
    state_path: state_path
  )
  routing_context = context.to_prompt_h.fetch("routing_context")
  # Defaults keep the remaining scenarios runnable against older code that only exposed a count.
  open_records = routing_context.fetch("open_questions", [])
  inference = routing_context.fetch("answer_inference", {})
  being_answered = routing_context.fetch("question_being_answered", nil)
  check("head context lists full open-question records") do
    record = open_records.first || {}
    missing = %w[id question context project_id issue_id head_id created_at].reject { |key| record.key?(key) }
    [open_records.length == 1 && missing.empty?, "records=#{open_records.length} missing=#{missing.inspect}"]
  end
  check("head context marks the referenced question and is not ambiguous") do
    [
      inference.fetch("explicitly_referenced_question_ids", nil) == [question_id] && inference.fetch("ambiguous", nil) == false,
      inference.slice("explicitly_referenced_question_ids", "ambiguous").inspect
    ]
  end
  check("head context explains the AnswerQuestion + routing pairing") do
    text = Array(inference.fetch("rules", [])).join(" ")
    [text.include?("AnswerQuestion") && text.include?("Never propose AnswerQuestion alone"), text[0, 80]]
  end
  check("question_being_answered is populated from a prose reference") do
    [being_answered && being_answered.fetch("id") == question_id, being_answered.inspect[0, 120]]
  end

  puts "Scenario 3: /answer records the answer and drives a head with the question context"
  parsed = Meringue::Input::SlashCommandParser.new.parse("/answer #{question_id.downcase} \"here is the snippet: worker P1-I8-W1 landed under I7\"")
  check("/answer parses to AnswerQuestion with an upcased question id") do
    [
      parsed.type == "AnswerQuestion" && parsed.payload.fetch("question_id") == question_id,
      parsed.to_h.inspect
    ]
  end
  check("/answer without answer text is rejected with usage") do
    invalid = Meringue::Input::SlashCommandParser.new.parse("/answer #{question_id}")
    [invalid.type == "InvalidSlashCommand", invalid.type]
  end

  runner.script do |args|
    context = args.fetch(:context)
    answered = context.to_prompt_h.dig("routing_context", "question_being_answered") || {}
    {
      "title" => "Route the answer",
      "summary" => "Prompt the existing worker with the user's answer.",
      "commands" => [
        {
          "type" => "PromptAgent",
          "payload" => {
            "agent_id" => worker_id,
            "prompt" => "The user answered #{answered.fetch("id", "the question")}: #{answered.fetch("answer", "")}",
            "mode" => "normal"
          }
        }
      ],
      "questions" => []
    }
  end

  answer_result = engine.apply(parsed.to_h)
  state = engine.list_all
  answered_question = question_by_id(state, question_id)
  check("AnswerQuestion is accepted") { [answer_result.fetch("status") == "accepted", answer_result.fetch("message", nil)] }
  check("the question is marked answered with the answer stored") do
    [
      answered_question.fetch("status") == "answered" && answered_question.fetch("answer").to_s.include?("snippet"),
      answered_question.slice("status", "answer").inspect
    ]
  end
  check("answering spawns a head instead of only logging") do
    head_id = answer_result.dig("result", "routing", "head_id")
    [!head_id.to_s.empty?, answer_result.dig("result", "routing").inspect]
  end
  check("the head result is applied, so the answer reaches real work") do
    [answer_result.dig("result", "routing", "apply_head_result_status") == "accepted", answer_result.dig("result", "routing").inspect]
  end
  routed_context = runner.last_context_hash
  routed_question = routed_context.dig("routing_context", "question_being_answered") || {}
  check("the routed head receives question_being_answered with the answer") do
    [
      routed_question.fetch("id", nil) == question_id && routed_question.fetch("answer", "").to_s.include?("snippet"),
      routed_question.slice("id", "status", "answer").inspect
    ]
  end
  check("the routed head keeps the question's project and issue scope") do
    [
      routed_question.fetch("project_id", nil) == project_id && routed_question.fetch("issue_id", nil) == issue_id,
      routed_question.slice("project_id", "issue_id").inspect
    ]
  end
  check("the routed head prompt carries the question, answer, and original user message") do
    prompt = runner.messages.last.to_s
    [
      prompt.include?(question_id) && prompt.include?("User answer:") && prompt.include?("i8") && prompt.include?(issue_id),
      prompt[0, 160]
    ]
  end
  check("the existing worker on the question's issue was prompted") do
    prompt_logs = state.fetch("logs").select do |entry|
      details = entry.fetch("details", {}) || {}
      details.fetch("agent_id", nil) == worker_id && details.key?("mode")
    end
    [prompt_logs.any?, "prompt logs: #{prompt_logs.length}"]
  end
  check("answering the same question again does not spawn another head") do
    repeat = engine.apply(parsed.to_h)
    [repeat.fetch("status") == "accepted" && repeat.dig("result", "routing").nil?, repeat.fetch("message", nil)]
  end

  puts "Scenario 4: a head infers an implicit answer and routes it in one HeadResult"
  runner.script do |_args|
    {
      "title" => "Clarify the target",
      "summary" => "Ambiguous target.",
      "commands" => [],
      "questions" => [
        {
          "question" => "Should the retry live in the API client or the job runner?",
          "context" => "Both are plausible and the change differs.",
          "project_id" => project_id,
          "issue_id" => issue_id
        }
      ]
    }
  end
  implicit_head = spawn_head(engine, "add retries around the flaky call")
  apply_head_result(
    engine,
    implicit_head,
    engine.list_all.fetch("agents").find { |agent| agent.fetch("id") == implicit_head }.fetch("harness_metadata").fetch("head_result")
  )
  implicit_question_id = open_questions(engine.list_all).last.fetch("id")
  heads_before = head_count(engine)

  inferring_head = spawn_head(engine, "the job runner please")
  combined = apply_head_result(
    engine,
    inferring_head,
    "title" => "Answer and route",
    "summary" => "The reply answers the open question; close it and continue the work.",
    "commands" => [
      {
        "type" => "AnswerQuestion",
        "payload" => { "question_id" => implicit_question_id, "answer" => "the job runner please" }
      },
      {
        "type" => "PromptAgent",
        "payload" => { "agent_id" => worker_id, "prompt" => "Put the retry in the job runner.", "mode" => "normal" }
      }
    ],
    "questions" => []
  )
  state = engine.list_all
  command_results = combined.dig("result", "command_results") || []
  check("AnswerQuestion is accepted inside a HeadResult alongside routing commands") do
    [
      command_results.length == 2 &&
        command_results[0].fetch("command_type") == "AnswerQuestion" && command_results[0].fetch("status") == "accepted" &&
        command_results[1].fetch("command_type") == "PromptAgent" && command_results[1].fetch("status") == "accepted",
      command_results.map { |result| result.slice("command_type", "status") }.inspect
    ]
  end
  check("the inferred question is closed") do
    record = question_by_id(state, implicit_question_id)
    [record.fetch("status") == "answered", record.slice("status", "answer").inspect]
  end
  check("a head-proposed AnswerQuestion does not spawn a second head") do
    [head_count(engine) == heads_before + 1, "spawn logs before=#{heads_before} after=#{head_count(engine)}"]
  end

  puts "Scenario 5: ambiguous and unrelated messages leave open questions untouched"
  runner.script do |_args|
    {
      "title" => "Clarify rollout",
      "summary" => "Ambiguous rollout.",
      "commands" => [],
      "questions" => [
        { "question" => "Should the retry ship behind a flag?", "context" => "Rollout unclear.", "project_id" => project_id, "issue_id" => issue_id },
        { "question" => "Should the retry cap at three attempts?", "context" => "Limit unclear.", "project_id" => project_id, "issue_id" => issue_id }
      ]
    }
  end
  ambiguous_head = spawn_head(engine, "how should the retry behave")
  apply_head_result(
    engine,
    ambiguous_head,
    engine.list_all.fetch("agents").find { |agent| agent.fetch("id") == ambiguous_head }.fetch("harness_metadata").fetch("head_result")
  )
  ambiguous_ids = open_questions(engine.list_all).map { |record| record.fetch("id") }
  check("two questions are open before the ambiguous message") { [ambiguous_ids.length == 2, ambiguous_ids.inspect] }

  ambiguous_context = Meringue::Heads::Context.new(
    head_id: "H?",
    user_message: "yes",
    snapshot: engine.list_all,
    cwd: project_path,
    state_path: state_path
  )
  ambiguous_inference = ambiguous_context.to_prompt_h.dig("routing_context", "answer_inference") || {}
  check("head context flags the ambiguity instead of naming a question") do
    [
      ambiguous_inference.fetch("ambiguous", nil) == true &&
        ambiguous_inference.fetch("single_referenced_question_id", nil).nil? &&
        ambiguous_inference.fetch("only_open_question_id", nil).nil?,
      ambiguous_inference.slice("ambiguous", "single_referenced_question_id", "only_open_question_id").inspect
    ]
  end
  check("question_being_answered stays null when nothing is clearly referenced") do
    value = ambiguous_context.to_prompt_h.dig("routing_context", "question_being_answered")
    [value.nil?, value.inspect]
  end

  runner.script do |_args|
    {
      "title" => "Route a new goal",
      "summary" => "Unrelated new goal; questions stay open.",
      "commands" => [
        { "type" => "PromptAgent", "payload" => { "agent_id" => worker_id, "prompt" => "Also update the README.", "mode" => "normal" } }
      ],
      "questions" => []
    }
  end
  unrelated_head = spawn_head(engine, "unrelated: please update the README next")
  apply_head_result(
    engine,
    unrelated_head,
    engine.list_all.fetch("agents").find { |agent| agent.fetch("id") == unrelated_head }.fetch("harness_metadata").fetch("head_result")
  )
  state = engine.list_all
  check("an unrelated routed message leaves both questions open") do
    still_open = open_questions(state).map { |record| record.fetch("id") }
    [still_open.sort == ambiguous_ids.sort, still_open.inspect]
  end
  check("no error-level logs were emitted") do
    errors = state.fetch("logs").select { |entry| entry.fetch("level", nil) == "error" }
    [errors.empty?, errors.map { |entry| entry.fetch("message") }.inspect]
  end

  puts "Scenario 6: the TUI/CLI prompt loop routes /answer end to end"
  runner.script do |_args|
    {
      "title" => "Clarify the branch",
      "summary" => "Ambiguous branch.",
      "commands" => [],
      "questions" => [
        { "question" => "Which branch should the fix land on?", "context" => "Two branches are plausible.", "project_id" => project_id, "issue_id" => issue_id }
      ]
    }
  end
  loop_head = spawn_head(engine, "land the fix somewhere sensible")
  apply_head_result(
    engine,
    loop_head,
    engine.list_all.fetch("agents").find { |agent| agent.fetch("id") == loop_head }.fetch("harness_metadata").fetch("head_result")
  )
  loop_question_id = open_questions(engine.list_all).last.fetch("id")
  runner.script do |_args|
    {
      "title" => "Route the branch answer",
      "summary" => "Continue on the existing worker.",
      "commands" => [
        { "type" => "PromptAgent", "payload" => { "agent_id" => worker_id, "prompt" => "Land the fix on main.", "mode" => "normal" } }
      ],
      "questions" => []
    }
  end
  prompt_loop = Meringue::Heads::PromptLoop.new(engine: engine)
  loop_payload = prompt_loop.call("/answer #{loop_question_id} \"use main\"")
  loop_result = Array(loop_payload.fetch("command_results", [])).first || {}
  check("the prompt loop applies AnswerQuestion for /answer") do
    [loop_result.fetch("command_type", nil) == "AnswerQuestion" && loop_result.fetch("status", nil) == "accepted", loop_result.slice("command_type", "status").inspect]
  end
  check("the prompt loop surfaces the routed head and its applied commands") do
    routing = loop_result.dig("result", "routing") || {}
    nested = Array(routing.fetch("command_results", []))
    [
      !routing.fetch("head_id", nil).to_s.empty? && nested.any? { |entry| entry.fetch("command_type", nil) == "PromptAgent" && entry.fetch("status", nil) == "accepted" },
      routing.slice("head_id", "apply_head_result_status").inspect
    ]
  end
  check("the answered question is closed after the prompt loop run") do
    record = question_by_id(engine.list_all, loop_question_id)
    [record.fetch("status") == "answered", record.slice("status", "answer").inspect]
  end

  puts
  if FAILURES.empty?
    puts "All question answering checks passed."
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
