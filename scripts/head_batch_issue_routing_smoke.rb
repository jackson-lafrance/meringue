#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression smoke for intra-batch issue routing in head command batches.
#
# Covers the misroute observed in ~/.meringue/state.json around L353-L358:
#   - head A created P1-I7 and spawned P1-I7-W1 for it,
#   - head B created P1-I8 for unrelated /prune work,
#   - head B's SpawnWorker predicted issue id "P1-I7", which head A had already consumed,
#     so the /prune worker was provisioned as P1-I7-W2 under head A's issue while P1-I8
#     ended up with zero workers.
#
# The kernel now resolves intra-batch issue references itself instead of trusting a predicted
# id, so a head's worker can only land on an issue the head could see or an issue its own
# batch created.
#
# Usage:
#   ruby scripts/head_batch_issue_routing_smoke.rb

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
  raise "command failed (#{argv.join(" ")}): #{output}" unless $?.success?

  output
end

def git_repo!(path)
  FileUtils.mkdir_p(path)
  run!("git", "init", "-q", "-b", "main", ".", chdir: path)
  run!("git", "config", "user.email", "smoke@example.com", chdir: path)
  run!("git", "config", "user.name", "Meringue Smoke", chdir: path)
  File.write(File.join(path, "README.md"), "# issue routing smoke\n")
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

def apply_head_result(engine, head_id, head_result)
  engine.apply(
    "type" => "ApplyHeadResult",
    "payload" => { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false }
  )
end

def head_result(commands, title: "Route work")
  {
    "title" => title,
    "summary" => "Route work for one user message.",
    "commands" => commands,
    "questions" => []
  }
end

def create_issue_command(project_id, title, command_id: nil)
  command = {
    "type" => "CreateIssue",
    "payload" => { "project_id" => project_id, "title" => title, "description" => "#{title} description", "parent_issue_id" => nil }
  }
  command_id ? command.merge("command_id" => command_id) : command
end

def spawn_worker_command(title:, issue_id: nil, extra_payload: {})
  payload = { "title" => title, "prompt" => "#{title}: investigate and report." }
  payload["issue_id"] = issue_id if issue_id
  { "type" => "SpawnWorker", "payload" => payload.merge(extra_payload) }
end

def workers_for(state, issue_id)
  state.fetch("agents").select do |agent|
    agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id
  end
end

def worker_titles(state, issue_id)
  workers_for(state, issue_id).map { |agent| (agent.fetch("harness_metadata", {}) || {}).fetch("title", nil) }
end

def issue_by_title(state, title)
  state.fetch("issues").find { |issue| issue.fetch("title", nil) == title }
end

def remap_warnings(state)
  state.fetch("logs").select { |entry| entry.fetch("message", "").to_s.include?("instead of predicted issue") }
end

def command_result(apply_result, command_type)
  Array(apply_result.dig("result", "command_results")).find { |result| result.fetch("command_type", nil) == command_type }
end

# Blocks inside spawn_session so a second head batch can be applied while this one is mid-flight.
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

temp_root = Dir.mktmpdir("meringue-issue-routing-smoke-")
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

  puts "Scenario 1: two heads predicting the same issue id keep their own workers"
  # Both heads were spawned against the same empty snapshot, so both predict "<project>-I1".
  head_a = spawn_head(engine, "Rebase the open PR onto main")
  head_b = spawn_head(engine, "Make /prune a single no-option command")
  apply_a = apply_head_result(
    engine,
    head_a,
    head_result([
      create_issue_command(project_id, "Rebase PR onto main"),
      spawn_worker_command(title: "Rebase PR onto main", issue_id: "#{project_id}-I1")
    ])
  )
  apply_b = apply_head_result(
    engine,
    head_b,
    head_result([
      create_issue_command(project_id, "Simplify /prune to no-option cleanup"),
      spawn_worker_command(title: "Simplify /prune to no-option cleanup", issue_id: "#{project_id}-I1")
    ])
  )
  state = engine.list_all
  rebase_issue = issue_by_title(state, "Rebase PR onto main")
  prune_issue = issue_by_title(state, "Simplify /prune to no-option cleanup")
  check("both head batches are accepted") do
    [
      apply_a.fetch("status") == "accepted" && apply_b.fetch("status") == "accepted",
      "#{apply_a.fetch("status")}/#{apply_b.fetch("status")}"
    ]
  end
  check("both issues exist") { [rebase_issue && prune_issue, state.fetch("issues").map { |issue| issue.fetch("id") }.inspect] }
  check("the first head's issue keeps exactly its own worker") do
    titles = worker_titles(state, rebase_issue&.fetch("id", nil))
    [titles == ["Rebase PR onto main"], titles.inspect]
  end
  check("the second head's worker lands on the issue that head created") do
    titles = worker_titles(state, prune_issue&.fetch("id", nil))
    [titles == ["Simplify /prune to no-option cleanup"], titles.inspect]
  end
  check("the misrouted spawn is corrected instead of failing") do
    result = command_result(apply_b, "SpawnWorker")
    [result && result.fetch("status", nil) == "accepted", result&.slice("status", "message").inspect]
  end
  check("the correction is visible in the logs") do
    warnings = remap_warnings(state)
    [warnings.length == 1, warnings.map { |entry| entry.fetch("message") }.inspect]
  end

  puts "Scenario 2: a head batch applied while another batch is mid-flight is not misrouted"
  gate = Queue.new
  release = Queue.new
  gated_engine = build_engine(
    state_path: state_path,
    workspace_root: workspace_root,
    project_path: project_path,
    config_path: config_path,
    harness_client: GatedClient.new(gate: gate, release: release)
  )
  other_engine = build_engine(state_path: state_path, workspace_root: workspace_root, project_path: project_path, config_path: config_path)
  head_c = spawn_head(gated_engine, "Add release notes")
  head_d = spawn_head(other_engine, "Document the config file")
  predicted = "#{project_id}-I3"
  applier = Thread.new do
    apply_head_result(
      gated_engine,
      head_c,
      head_result([
        create_issue_command(project_id, "Add release notes"),
        spawn_worker_command(title: "Add release notes", issue_id: predicted)
      ])
    )
  end
  gate.pop
  interleaved = apply_head_result(
    other_engine,
    head_d,
    head_result([
      create_issue_command(project_id, "Document the config file"),
      spawn_worker_command(title: "Document the config file", issue_id: predicted)
    ])
  )
  release << true
  gated = applier.value
  state = engine.list_all
  notes_issue = issue_by_title(state, "Add release notes")
  config_issue = issue_by_title(state, "Document the config file")
  check("both interleaved batches are accepted") do
    [
      gated.fetch("status") == "accepted" && interleaved.fetch("status") == "accepted",
      "#{gated.fetch("status")}/#{interleaved.fetch("status")}"
    ]
  end
  check("each interleaved head keeps its own worker") do
    [
      worker_titles(state, notes_issue&.fetch("id", nil)) == ["Add release notes"] &&
        worker_titles(state, config_issue&.fetch("id", nil)) == ["Document the config file"],
      { notes_issue&.fetch("id", nil) => worker_titles(state, notes_issue&.fetch("id", nil)),
        config_issue&.fetch("id", nil) => worker_titles(state, config_issue&.fetch("id", nil)) }.inspect
    ]
  end

  puts "Scenario 3: symbolic intra-batch references resolve without predicting an id"
  warnings_before_symbolic = remap_warnings(engine.list_all).length
  head_e = spawn_head(engine, "Add a health check endpoint")
  by_command_id = apply_head_result(
    engine,
    head_e,
    head_result([
      create_issue_command(project_id, "Add health check endpoint", command_id: "#{head_e}-C1"),
      spawn_worker_command(title: "Add health check endpoint", extra_payload: { "issue_from_command" => "#{head_e}-C1" })
    ])
  )
  head_f = spawn_head(engine, "Add request logging")
  by_index = apply_head_result(
    engine,
    head_f,
    head_result([
      create_issue_command(project_id, "Add request logging"),
      spawn_worker_command(title: "Add request logging", issue_id: "@index:0")
    ])
  )
  state = engine.list_all
  health_issue = issue_by_title(state, "Add health check endpoint")
  logging_issue = issue_by_title(state, "Add request logging")
  check("issue_from_command routes the worker to the batch's issue") do
    result = command_result(by_command_id, "SpawnWorker")
    [
      result && result.fetch("status", nil) == "accepted" && worker_titles(state, health_issue&.fetch("id", nil)) == ["Add health check endpoint"],
      "#{result&.fetch("status", nil)} #{worker_titles(state, health_issue&.fetch("id", nil)).inspect}"
    ]
  end
  check("an @index reference routes the worker to the batch's issue") do
    result = command_result(by_index, "SpawnWorker")
    [
      result && result.fetch("status", nil) == "accepted" && worker_titles(state, logging_issue&.fetch("id", nil)) == ["Add request logging"],
      "#{result&.fetch("status", nil)} #{worker_titles(state, logging_issue&.fetch("id", nil)).inspect}"
    ]
  end
  check("no remap warning is needed for symbolic references") do
    warnings = remap_warnings(state).length
    [warnings == warnings_before_symbolic, "#{warnings_before_symbolic} -> #{warnings}"]
  end

  puts "Scenario 4: an existing issue id still routes normally"
  existing_issue_id = health_issue.fetch("id")
  head_g = spawn_head(engine, "Follow up on the health check work")
  follow_up = apply_head_result(
    engine,
    head_g,
    head_result([spawn_worker_command(title: "Extend health check coverage", issue_id: existing_issue_id)])
  )
  head_h = spawn_head(engine, "Start a new goal and also extend the health check")
  mixed = apply_head_result(
    engine,
    head_h,
    head_result([
      create_issue_command(project_id, "Add metrics endpoint"),
      spawn_worker_command(title: "Harden health check", issue_id: existing_issue_id)
    ])
  )
  state = engine.list_all
  metrics_issue = issue_by_title(state, "Add metrics endpoint")
  check("a worker for a pre-existing issue is accepted") do
    [follow_up.fetch("status") == "accepted", follow_up.fetch("message")]
  end
  check("a batch that also creates an issue still honours a visible existing issue id") do
    titles = worker_titles(state, existing_issue_id)
    [
      mixed.fetch("status") == "accepted" && titles.sort == ["Add health check endpoint", "Extend health check coverage", "Harden health check"],
      titles.inspect
    ]
  end
  check("the newly created issue is left without a worker") do
    [workers_for(state, metrics_issue&.fetch("id", nil)).empty?, worker_titles(state, metrics_issue&.fetch("id", nil)).inspect]
  end

  puts "Scenario 5: an unresolvable predicted id is rejected instead of routed to the wrong issue"
  head_i = spawn_head(engine, "Split work across two issues")
  ambiguous = apply_head_result(
    engine,
    head_i,
    head_result([
      create_issue_command(project_id, "Split part one"),
      create_issue_command(project_id, "Split part two"),
      spawn_worker_command(title: "Split part two", issue_id: "#{project_id}-I99")
    ])
  )
  state = engine.list_all
  check("the ambiguous spawn is rejected") do
    result = command_result(ambiguous, "SpawnWorker")
    [
      result && result.fetch("status", nil) == "rejected" && Array(result.fetch("errors", [])).include?("issue_id_not_created_by_this_head_result"),
      result&.slice("status", "errors").inspect
    ]
  end
  check("no worker is attached to either split issue") do
    part_one = issue_by_title(state, "Split part one")
    part_two = issue_by_title(state, "Split part two")
    attached = workers_for(state, part_one&.fetch("id", nil)) + workers_for(state, part_two&.fetch("id", nil))
    [attached.empty?, attached.map { |agent| agent.fetch("id") }.inspect]
  end

  puts "Scenario 6: an out-of-order symbolic reference is rejected"
  head_j = spawn_head(engine, "Spawn before creating")
  out_of_order = apply_head_result(
    engine,
    head_j,
    head_result([
      spawn_worker_command(title: "Too early", issue_id: "@index:1"),
      create_issue_command(project_id, "Created after the worker")
    ])
  )
  state = engine.list_all
  check("the early spawn is rejected") do
    result = command_result(out_of_order, "SpawnWorker")
    [
      result && result.fetch("status", nil) == "rejected" && Array(result.fetch("errors", [])).include?("batch_issue_reference_out_of_order"),
      result&.slice("status", "errors").inspect
    ]
  end
  check("the later issue has no worker") do
    late_issue = issue_by_title(state, "Created after the worker")
    [workers_for(state, late_issue&.fetch("id", nil)).empty?, worker_titles(state, late_issue&.fetch("id", nil)).inspect]
  end

  puts "Scenario 7: a predicted id from another project is rejected, not remapped"
  other_project_path = git_repo!(File.join(temp_root, "other-project"))
  other_project = engine.apply("type" => "AddProject", "payload" => { "path" => other_project_path, "name" => "other-project" })
  raise "AddProject was not accepted: #{other_project.inspect}" unless other_project.fetch("status") == "accepted"

  other_project_id = other_project.fetch("target_id")
  head_k = spawn_head(engine, "Plan work in the first project")
  head_l = spawn_head(engine, "Start the other project")
  apply_head_result(
    engine,
    head_l,
    head_result([
      create_issue_command(other_project_id, "Other project goal", command_id: "#{head_l}-C1"),
      spawn_worker_command(title: "Other project goal", extra_payload: { "issue_from_command" => "#{head_l}-C1" })
    ])
  )
  other_issue_id = issue_by_title(engine.list_all, "Other project goal").fetch("id")
  cross_project = apply_head_result(
    engine,
    head_k,
    head_result([
      create_issue_command(project_id, "First project goal"),
      spawn_worker_command(title: "Cross project worker", issue_id: other_issue_id)
    ])
  )
  state = engine.list_all
  check("the cross-project spawn is rejected") do
    result = command_result(cross_project, "SpawnWorker")
    [
      result && result.fetch("status", nil) == "rejected" && Array(result.fetch("errors", [])).include?("issue_id_not_created_by_this_head_result"),
      result&.slice("status", "errors").inspect
    ]
  end
  check("the other project's issue keeps only its own worker") do
    titles = worker_titles(state, other_issue_id)
    [titles == ["Other project goal"], titles.inspect]
  end

  puts "Scenario 8: ModifyIssue is routed to the batch's own issue"
  head_m = spawn_head(engine, "Create a goal and mark it blocked")
  modify = apply_head_result(
    engine,
    head_m,
    head_result([
      create_issue_command(project_id, "Blocked on an answer"),
      {
        "type" => "ModifyIssue",
        "payload" => { "issue_from_command" => 0, "status" => "blocked" }
      }
    ])
  )
  state = engine.list_all
  check("ModifyIssue is accepted") do
    result = command_result(modify, "ModifyIssue")
    [result && result.fetch("status", nil) == "accepted", result&.slice("status", "message").inspect]
  end
  check("the batch's own issue is the one modified") do
    own = issue_by_title(state, "Blocked on an answer")
    [own && own.fetch("status", nil) == "blocked", own&.slice("id", "status").inspect]
  end
  check("the unrelated first issue keeps its status") do
    first = issue_by_title(state, "Rebase PR onto main")
    [first && first.fetch("status", nil) != "blocked", first&.slice("id", "status").inspect]
  end

  puts
  if FAILURES.empty?
    puts "All head batch issue routing checks passed."
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
