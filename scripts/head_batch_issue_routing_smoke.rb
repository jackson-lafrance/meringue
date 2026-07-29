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
# Rejection codes the kernel uses when a batch target cannot be resolved without guessing.
REJECTION_CODES = %w[issue_id_not_created_by_this_head_result ambiguous_batch_issue_target ambiguous_batch_issue_prediction].freeze

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

  puts "Scenario 4: existing-issue targets still route normally"
  existing_issue_id = health_issue.fetch("id")
  head_g = spawn_head(engine, "Follow up on the health check work")
  follow_up = apply_head_result(
    engine,
    head_g,
    head_result([spawn_worker_command(title: "Extend health check coverage", issue_id: existing_issue_id)])
  )
  # Mixed batch: the created issue gets its own worker, and a second worker deliberately targets
  # the pre-existing issue. Both must land where the head said.
  head_h = spawn_head(engine, "Start a new goal and also extend the health check")
  mixed = apply_head_result(
    engine,
    head_h,
    head_result([
      create_issue_command(project_id, "Add metrics endpoint", command_id: "#{head_h}-C1"),
      spawn_worker_command(title: "Add metrics endpoint", extra_payload: { "issue_from_command" => "#{head_h}-C1" }),
      spawn_worker_command(title: "Harden health check", issue_id: existing_issue_id)
    ])
  )
  state = engine.list_all
  metrics_issue = issue_by_title(state, "Add metrics endpoint")
  check("a worker for a pre-existing issue is accepted") do
    [follow_up.fetch("status") == "accepted", follow_up.fetch("message")]
  end
  check("the mixed batch honours the visible existing issue id") do
    titles = worker_titles(state, existing_issue_id)
    [
      mixed.fetch("status") == "accepted" && titles.sort == ["Add health check endpoint", "Extend health check coverage", "Harden health check"],
      titles.inspect
    ]
  end
  check("the mixed batch's new issue gets its own worker") do
    titles = worker_titles(state, metrics_issue&.fetch("id", nil))
    [titles == ["Add metrics endpoint"], titles.inspect]
  end
  # A batch may also create an issue for later and deliberately work only on an existing issue,
  # as long as it says so explicitly.
  head_h2 = spawn_head(engine, "Track a backlog goal and keep working the health check")
  backlog = apply_head_result(
    engine,
    head_h2,
    head_result([
      create_issue_command(project_id, "Backlog: split health checks"),
      spawn_worker_command(title: "Health check pass three", issue_id: existing_issue_id, extra_payload: { "existing_issue" => true })
    ])
  )
  state = engine.list_all
  backlog_issue = issue_by_title(state, "Backlog: split health checks")
  check("an explicitly marked existing-issue worker is honoured") do
    titles = worker_titles(state, existing_issue_id)
    [backlog.fetch("status") == "accepted" && titles.include?("Health check pass three"), titles.inspect]
  end
  check("the backlog issue is intentionally left without a worker") do
    [workers_for(state, backlog_issue&.fetch("id", nil)).empty?, worker_titles(state, backlog_issue&.fetch("id", nil)).inspect]
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
      result && result.fetch("status", nil) == "rejected" && REJECTION_CODES.intersect?(Array(result.fetch("errors", []))),
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
      result && result.fetch("status", nil) == "rejected" && REJECTION_CODES.intersect?(Array(result.fetch("errors", []))),
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

  puts "Scenario 9: the reported incident timeline is corrected loudly, not silently"
  # Mirrors 2026-07-29 11:28-11:29 in ~/.meringue/state.json: the /prune head was spawned while
  # the rebase head's issue did not exist yet, so its predicted id later resolved to the rebase
  # head's issue and its worker was attached there as P1-I7-W2.
  prune_head = spawn_head(engine, "Make /prune a single no-option command")
  rebase_head = spawn_head(engine, "Rebase the open PR onto main")
  apply_head_result(
    engine,
    rebase_head,
    head_result([
      create_issue_command(project_id, "Rebase the other PR", command_id: "#{rebase_head}-C1"),
      spawn_worker_command(title: "Rebase the other PR", extra_payload: { "issue_from_command" => "#{rebase_head}-C1" })
    ])
  )
  rebase_issue_id = issue_by_title(engine.list_all, "Rebase the other PR").fetch("id")
  incident = apply_head_result(
    engine,
    prune_head,
    head_result([
      create_issue_command(project_id, "Prune without options"),
      spawn_worker_command(title: "Simplify /prune", issue_id: rebase_issue_id)
    ])
  )
  state = engine.list_all
  prune_issue = issue_by_title(state, "Prune without options")
  check("the /prune worker lands on the /prune issue") do
    titles = worker_titles(state, prune_issue&.fetch("id", nil))
    [titles == ["Simplify /prune"], titles.inspect]
  end
  check("the rebase issue keeps only its own worker") do
    titles = worker_titles(state, rebase_issue_id)
    [titles == ["Rebase the other PR"], titles.inspect]
  end
  check("the spawn log itself reports the reroute") do
    spawn_log = state.fetch("logs").reverse.find { |entry| entry.fetch("message", "").to_s.start_with?("Spawned worker") && entry.fetch("message", "").to_s.include?("Rerouted from predicted issue") }
    [spawn_log && spawn_log.dig("details", "rerouted_from_issue_id") == rebase_issue_id, spawn_log&.fetch("message", nil).inspect]
  end
  check("the worker record remembers the corrected route") do
    worker = workers_for(state, prune_issue&.fetch("id", nil)).first
    metadata = worker ? (worker.fetch("harness_metadata", {}) || {}) : {}
    [metadata.fetch("rerouted_from_issue_id", nil) == rebase_issue_id, metadata.fetch("rerouted_from_issue_id", nil).inspect]
  end
  check("the batch is still reported as accepted") do
    result = command_result(incident, "SpawnWorker")
    [result && result.fetch("status", nil) == "accepted", result&.slice("status", "message").inspect]
  end

  puts "Scenario 10: nothing re-parents an existing agent across issues"
  before = engine.list_all.fetch("agents").to_h { |agent| [agent.fetch("id"), agent.fetch("issue_id", nil)] }
  logging_worker = workers_for(engine.list_all, logging_issue.fetch("id")).first.fetch("id")
  engine.apply("type" => "ModifyIssue", "payload" => { "issue_id" => prune_issue.fetch("id"), "title" => "Prune without options (v2)", "status" => "blocked" })
  engine.apply("type" => "PromptAgent", "payload" => { "agent_id" => workers_for(engine.list_all, prune_issue.fetch("id")).first.fetch("id"), "prompt" => "Keep going.", "mode" => "normal" })
  engine.apply("type" => "Kill", "payload" => { "target_id" => logging_worker })
  engine.apply("type" => "ReconcileSessions", "payload" => {})
  state = engine.list_all
  after = state.fetch("agents").to_h { |agent| [agent.fetch("id"), agent.fetch("issue_id", nil)] }
  check("every surviving agent keeps its original issue") do
    moved = after.reject { |agent_id, issue_id| !before.key?(agent_id) || before.fetch(agent_id) == issue_id }
    [moved.empty?, moved.inspect]
  end
  check("the killed worker is removed rather than moved") do
    [!after.key?(logging_worker), after.fetch(logging_worker, nil).inspect]
  end
  check("the kernel never assigns issue_id on an existing agent record") do
    source = File.read(File.expand_path("../lib/meringue/kernel/engine.rb", __dir__))
    assignments = source.scan(/^.*\b(?:agent|worker|reserved_agent|related_agent|existing)\w*\["issue_id"\]\s*=[^=].*$/)
    [assignments.empty?, assignments.inspect]
  end

  puts "Scenario 11: killing a worker leaves no dangling routing pointer behind"
  head_o = spawn_head(engine, "Add one more worker to the rebase issue")
  apply_head_result(
    engine,
    head_o,
    head_result([spawn_worker_command(title: "Second rebase pass", issue_id: rebase_issue_id)])
  )
  state = engine.list_all
  extra_worker = workers_for(state, rebase_issue_id).find { |agent| (agent.fetch("harness_metadata", {}) || {}).fetch("title", nil) == "Second rebase pass" }
  check("the extra worker is recorded as the issue's last routed agent") do
    issue = state.fetch("issues").find { |candidate| candidate.fetch("id") == rebase_issue_id }
    [issue.fetch("last_agent_id", nil) == extra_worker&.fetch("id", nil), issue.fetch("last_agent_id", nil).inspect]
  end
  engine.apply("type" => "Kill", "payload" => { "target_id" => extra_worker.fetch("id") })
  state = engine.list_all
  check("last_agent_id no longer names the killed worker") do
    issue = state.fetch("issues").find { |candidate| candidate.fetch("id") == rebase_issue_id }
    last_agent_id = issue.fetch("last_agent_id", nil)
    surviving = workers_for(state, rebase_issue_id).map { |agent| agent.fetch("id") }
    [last_agent_id != extra_worker.fetch("id") && (last_agent_id.nil? || surviving.include?(last_agent_id)), "#{last_agent_id.inspect} of #{surviving.inspect}"]
  end

  puts "Scenario 12: large fan-out batch (13 workers) binds to the issue the batch created"
  # Reproduces 2026-07-29 11:48 in ~/.meringue/state.json: head H62 created P1-I10 for the test
  # suite goal, then spawned H62-C2..H62-C14 with issue_id "P1-I9" (the previous, still visible
  # issue). P1-I10 ended up with zero workers and P1-I9 collected 13 unrelated ones.
  head_p = spawn_head(engine, "Replace the smoke scripts with a real test suite")
  previous_issue_id = prune_issue.fetch("id")
  slice_titles = (1..13).map { |slice| "Test slice #{slice}" }
  fan_out = apply_head_result(
    engine,
    head_p,
    head_result(
      [create_issue_command(project_id, "Replace smoke scripts with a test suite")] +
        slice_titles.map { |title| spawn_worker_command(title: title, issue_id: previous_issue_id) }
    )
  )
  state = engine.list_all
  suite_issue = issue_by_title(state, "Replace smoke scripts with a test suite")
  check("all 13 workers land on the issue this batch created") do
    titles = worker_titles(state, suite_issue&.fetch("id", nil)).sort
    [titles == slice_titles.sort, "#{titles.length} workers: #{titles.first(3).inspect}"]
  end
  check("the previous issue gains no unrelated workers") do
    titles = worker_titles(state, previous_issue_id)
    [(titles & slice_titles).empty?, titles.inspect]
  end
  check("every rerouted spawn is accepted and logged") do
    results = Array(fan_out.dig("result", "command_results")).select { |result| result.fetch("command_type", nil) == "SpawnWorker" }
    warnings = state.fetch("logs").count { |entry| entry.fetch("message", "").to_s.include?("which would otherwise have had no worker") }
    [results.length == 13 && results.all? { |result| result.fetch("status", nil) == "accepted" } && warnings == 13, "#{results.map { |r| r["status"] }.uniq.inspect} warnings=#{warnings}"]
  end

  puts "Scenario 13: fan-out across two new issues plus one existing issue"
  head_q = spawn_head(engine, "Split the work into two new goals and keep the old one moving")
  multi = apply_head_result(
    engine,
    head_q,
    head_result([
      create_issue_command(project_id, "Front-end split", command_id: "#{head_q}-front"),
      create_issue_command(project_id, "Back-end split", command_id: "#{head_q}-back"),
      spawn_worker_command(title: "Front-end worker A", extra_payload: { "issue_from_command" => "#{head_q}-front" }),
      spawn_worker_command(title: "Front-end worker B", extra_payload: { "issue_from_command" => "#{head_q}-front" }),
      spawn_worker_command(title: "Back-end worker A", extra_payload: { "issue_from_command" => "#{head_q}-back" }),
      spawn_worker_command(title: "Existing issue worker", issue_id: existing_issue_id)
    ])
  )
  state = engine.list_all
  front_issue = issue_by_title(state, "Front-end split")
  back_issue = issue_by_title(state, "Back-end split")
  check("every command in the mixed fan-out batch is accepted") do
    results = Array(multi.dig("result", "command_results"))
    [results.all? { |result| result.fetch("status", nil) == "accepted" }, results.map { |r| [r["command_type"], r["status"]] }.inspect]
  end
  check("the first new issue keeps both of its workers") do
    titles = worker_titles(state, front_issue&.fetch("id", nil)).sort
    [titles == ["Front-end worker A", "Front-end worker B"], titles.inspect]
  end
  check("the second new issue keeps its own worker") do
    titles = worker_titles(state, back_issue&.fetch("id", nil))
    [titles == ["Back-end worker A"], titles.inspect]
  end
  check("the pre-existing issue keeps the worker meant for it") do
    titles = worker_titles(state, existing_issue_id)
    [titles.include?("Existing issue worker"), titles.inspect]
  end

  puts "Scenario 14: predicted ids for two new issues survive a concurrent issue creation"
  head_r = spawn_head(engine, "Two more goals with predicted ids")
  interloper = spawn_head(engine, "Unrelated goal that steals the next id")
  apply_head_result(
    engine,
    interloper,
    head_result([
      create_issue_command(project_id, "Interloper goal", command_id: "#{interloper}-C1"),
      spawn_worker_command(title: "Interloper worker", extra_payload: { "issue_from_command" => "#{interloper}-C1" })
    ])
  )
  issue_counter = engine.list_all.fetch("counters").fetch("issues_by_project").fetch(project_id).to_i
  # head_r was spawned before the interloper applied, so its predictions are now two ids too low.
  predicted_first = "#{project_id}-I#{issue_counter}"
  predicted_second = "#{project_id}-I#{issue_counter + 1}"
  predicted = apply_head_result(
    engine,
    head_r,
    head_result([
      create_issue_command(project_id, "Predicted goal one"),
      create_issue_command(project_id, "Predicted goal two"),
      spawn_worker_command(title: "Predicted worker one", issue_id: predicted_first),
      spawn_worker_command(title: "Predicted worker two", issue_id: predicted_second)
    ])
  )
  state = engine.list_all
  first_goal = issue_by_title(state, "Predicted goal one")
  second_goal = issue_by_title(state, "Predicted goal two")
  check("both predicted batches are accepted") do
    results = Array(predicted.dig("result", "command_results"))
    [results.all? { |result| result.fetch("status", nil) == "accepted" }, results.map { |r| [r["command_type"], r["status"], r["errors"]] }.inspect]
  end
  check("each predicted worker lands on its own new issue") do
    first_titles = worker_titles(state, first_goal&.fetch("id", nil))
    second_titles = worker_titles(state, second_goal&.fetch("id", nil))
    [
      first_titles == ["Predicted worker one"] && second_titles == ["Predicted worker two"],
      "#{first_goal&.fetch("id", nil)}=#{first_titles.inspect} #{second_goal&.fetch("id", nil)}=#{second_titles.inspect}"
    ]
  end
  check("the interloper's issue keeps only its own worker") do
    interloper_issue = issue_by_title(state, "Interloper goal")
    titles = worker_titles(state, interloper_issue&.fetch("id", nil))
    [titles == ["Interloper worker"], titles.inspect]
  end

  puts "Scenario 15: AddProject then CreateIssue with a predicted project id"
  new_project_path = git_repo!(File.join(temp_root, "third-project"))
  head_s = spawn_head(engine, "Register a new repo and start work in it")
  competing_path = git_repo!(File.join(temp_root, "competing-project"))
  competing = engine.apply("type" => "AddProject", "payload" => { "path" => competing_path, "name" => "competing-project" })
  raise "AddProject was not accepted: #{competing.inspect}" unless competing.fetch("status") == "accepted"

  predicted_project_id = "P#{engine.list_all.fetch("counters").fetch("projects").to_i}"
  new_project = apply_head_result(
    engine,
    head_s,
    head_result([
      { "type" => "AddProject", "payload" => { "path" => new_project_path, "name" => "third-project" } },
      create_issue_command(predicted_project_id, "Bootstrap the third project", command_id: "#{head_s}-C2"),
      spawn_worker_command(title: "Bootstrap the third project", extra_payload: { "issue_from_command" => "#{head_s}-C2" })
    ])
  )
  state = engine.list_all
  bootstrap_issue = issue_by_title(state, "Bootstrap the third project")
  registered = state.fetch("projects").find { |project| File.expand_path(project.fetch("root_path")) == File.expand_path(new_project_path) }
  check("the whole AddProject batch is accepted") do
    results = Array(new_project.dig("result", "command_results"))
    [results.all? { |result| result.fetch("status", nil) == "accepted" }, results.map { |r| [r["command_type"], r["status"], r["message"]] }.inspect]
  end
  check("the issue lands in the project this batch registered") do
    [
      bootstrap_issue && registered && bootstrap_issue.fetch("project_id") == registered.fetch("id"),
      "#{bootstrap_issue&.fetch("project_id", nil).inspect} vs #{registered&.fetch("id", nil).inspect}"
    ]
  end
  check("the competing project keeps no issues from this batch") do
    competing_issues = state.fetch("issues").select { |issue| issue.fetch("project_id") == competing.fetch("target_id") }
    [competing_issues.empty?, competing_issues.map { |issue| issue.fetch("id") }.inspect]
  end
  check("the worker lands on the new project's issue") do
    titles = worker_titles(state, bootstrap_issue&.fetch("id", nil))
    [titles == ["Bootstrap the third project"], titles.inspect]
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
