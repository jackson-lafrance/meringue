#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage for the single no-argument `/prune` command.
#
# `/prune` performs one combined cleanup pass: resolved (completed/killed) and errored
# records are removed together, while retention rules still protect nonterminal issues,
# queued/working/blocked workers, open questions, unsettled or unknown pull requests, and
# projects that still contain ineligible issues. Worker workspaces are never deleted.
#
# Usage:
#   ruby scripts/prune_smoke.rb

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

# Returns the configured status for a PR URL so prune's conservative PR rules can be
# exercised without a live forge.
class StubForgeClient
  def initialize(statuses = {})
    @statuses = statuses
  end

  def pull_request_urls_for_branch(repository:, branch:)
    []
  end

  def pull_request_status(url)
    @statuses.fetch(url.to_s, "provider" => "github", "url" => url.to_s, "state" => "unknown", "error" => "no stubbed status")
  end
end

NOW = Time.now.utc.iso8601

def project(id, status, name: id)
  {
    "id" => id,
    "name" => name,
    "root_path" => "/tmp/#{name}",
    "status" => status,
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

def issue(id, project_id, status, parent_issue_id: nil, pr_urls: [])
  {
    "id" => id,
    "project_id" => project_id,
    "parent_issue_id" => parent_issue_id,
    "title" => "Issue #{id}",
    "description" => "",
    "status" => status,
    "agent_ids" => [],
    "reported_pr_urls" => pr_urls,
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

def worker(id, issue_id, project_id, status, workspace_path: nil)
  {
    "id" => id,
    "type" => "worker",
    "status" => status,
    "project_id" => project_id,
    "issue_id" => issue_id,
    "workspace_path" => workspace_path,
    "workspace_strategy" => workspace_path ? "git_worktree" : nil,
    "harness" => "fake",
    "created_at" => NOW,
    "updated_at" => NOW
  }.compact
end

def head(id, status, issue_id: nil, project_id: nil)
  {
    "id" => id,
    "type" => "head",
    "status" => status,
    "project_id" => project_id,
    "issue_id" => issue_id,
    "harness" => "fake",
    "created_at" => NOW,
    "updated_at" => NOW
  }.compact
end

def question(id, status, project_id: nil, issue_id: nil)
  {
    "id" => id,
    "head_id" => "H99",
    "project_id" => project_id,
    "issue_id" => issue_id,
    "question" => "Should this continue?",
    "context" => "",
    "status" => status,
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

MERGED_PR = "https://github.com/acme/demo/pull/1"
OPEN_PR = "https://github.com/acme/demo/pull/2"
UNKNOWN_PR = "https://github.com/acme/demo/pull/3"
CLOSED_PR = "https://github.com/acme/demo/pull/4"

PR_STATUSES = {
  MERGED_PR => { "provider" => "github", "url" => MERGED_PR, "state" => "merged", "merged_at" => NOW },
  OPEN_PR => { "provider" => "github", "url" => OPEN_PR, "state" => "open", "is_draft" => false },
  UNKNOWN_PR => { "provider" => "github", "url" => UNKNOWN_PR, "state" => "unknown", "error" => "forge unavailable" },
  CLOSED_PR => { "provider" => "github", "url" => CLOSED_PR, "state" => "closed" }
}.freeze

# One fixture tree covering every documented resolved and errored case at once, so a single
# `/prune` pass can be checked for both halves of the cleanup.
def fixture_state(workspace_root)
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [
    project("P1", "working", name: "active-project"),
    project("P2", "completed", name: "finished-project"),
    project("P3", "errored", name: "errored-project"),
    project("P4", "completed", name: "busy-project"),
    project("P5", "completed", name: "questioned-project")
  ]
  state["issues"] = [
    # Resolved half.
    issue("P1-I1", "P1", "completed"),
    issue("P1-I2", "P1", "killed"),
    issue("P1-I3", "P1", "completed", pr_urls: [MERGED_PR]),
    issue("P1-I4", "P1", "completed", pr_urls: [CLOSED_PR]),
    issue("P1-I5", "P1", "completed", pr_urls: [OPEN_PR]),
    issue("P1-I6", "P1", "completed", pr_urls: [UNKNOWN_PR]),
    issue("P1-I7", "P1", "completed"),
    issue("P1-I8", "P1", "working"),
    issue("P1-I9", "P1", "completed"),
    issue("P1-I10", "P1", "working", parent_issue_id: "P1-I9"),
    # Errored half.
    issue("P1-I11", "P1", "errored"),
    issue("P1-I12", "P1", "errored"),
    issue("P1-I13", "P1", "errored"),
    issue("P1-I14", "P1", "errored"),
    # Whole-project cases.
    issue("P2-I1", "P2", "completed"),
    issue("P2-I2", "P2", "errored"),
    issue("P3-I1", "P3", "errored"),
    issue("P4-I1", "P4", "completed"),
    issue("P4-I2", "P4", "working"),
    issue("P5-I1", "P5", "completed")
  ]
  state["agents"] = [
    worker("P1-I1-W1", "P1-I1", "P1", "completed", workspace_path: File.join(workspace_root, "P1-I1-W1")),
    worker("P1-I2-W1", "P1-I2", "P1", "killed"),
    worker("P1-I7-W1", "P1-I7", "P1", "idle"),
    worker("P1-I8-W1", "P1-I8", "P1", "working"),
    worker("P1-I11-W1", "P1-I11", "P1", "errored", workspace_path: File.join(workspace_root, "P1-I11-W1")),
    worker("P1-I12-W1", "P1-I12", "P1", "working"),
    worker("P1-I13-W1", "P1-I13", "P1", "queued"),
    worker("P2-I2-W1", "P2-I2", "P2", "errored"),
    worker("P4-I2-W1", "P4-I2", "P4", "working"),
    head("H1", "errored"),
    head("H2", "working")
  ]
  state["questions"] = [
    question("Q1", "open", project_id: "P1", issue_id: "P1-I14"),
    question("Q2", "answered", project_id: "P1", issue_id: "P1-I1"),
    question("Q3", "open", project_id: "P5")
  ]
  state
end

def run_prune(payload:, workspace_root:, state_path:)
  FileUtils.rm_f(state_path)
  store = Meringue::State::Store.new(path: state_path)
  store.save(fixture_state(workspace_root))
  engine = Meringue::Kernel::Engine.new(
    store: store,
    harness_client: Meringue::Harness::FakeClient.new,
    head_runner: Meringue::Heads::FakeRunner.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
    forge_client: StubForgeClient.new(PR_STATUSES),
    cwd: Dir.pwd,
    config_path: File.join(File.dirname(state_path), "config.toml")
  )
  result = payload.nil? ? engine.apply("type" => "Prune") : engine.apply("type" => "Prune", "payload" => payload)
  [result, engine.list_all]
end

temp_root = Dir.mktmpdir("meringue-prune-smoke-")
workspace_root = File.join(temp_root, "workspaces")
state_path = File.join(temp_root, "state.json")
%w[P1-I1-W1 P1-I11-W1].each do |workspace|
  FileUtils.mkdir_p(File.join(workspace_root, workspace))
  File.write(File.join(workspace_root, workspace, "NOTES.md"), "worker workspace\n")
end

begin
  puts "Scenario 1: bare /prune removes resolved and errored records in one pass"
  result, state = run_prune(payload: nil, workspace_root: workspace_root, state_path: state_path)
  details = result.fetch("result", {}) || {}
  removed_issues = Array(details["removed_issue_ids"])
  removed_projects = Array(details["removed_project_ids"])
  removed_agents = Array(details["removed_agent_ids"])
  issue_ids = state.fetch("issues").map { |record| record.fetch("id") }
  project_ids = state.fetch("projects").map { |record| record.fetch("id") }
  agent_ids = state.fetch("agents").map { |record| record.fetch("id") }

  check("accepts a payload-free Prune command") { [result.fetch("status") == "accepted", result.fetch("status")] }
  check("does not require or echo a selector") { [!details.key?("requested_selector"), details["requested_selector"].inspect] }

  expected_pruned_resolved = %w[P1-I1 P1-I2 P1-I3 P1-I4 P1-I7 P4-I1 P5-I1]
  expected_pruned_errored = %w[P1-I11]
  expected_retained = %w[P1-I5 P1-I6 P1-I8 P1-I9 P1-I10 P1-I12 P1-I13 P1-I14 P4-I2]

  check("prunes resolved issues (completed, killed, merged PR, closed PR)") do
    missing = expected_pruned_resolved - removed_issues
    [missing.empty?, "still present: #{missing.join(", ")}"]
  end
  check("prunes errored issues whose workers are settled") do
    missing = expected_pruned_errored - removed_issues
    [missing.empty?, "still present: #{missing.join(", ")}"]
  end
  check("retains records that unresolved work still needs") do
    unexpected = expected_retained & removed_issues
    [unexpected.empty?, "wrongly removed: #{unexpected.join(", ")}"]
  end
  check("retains a completed issue with an open PR (P1-I5)") { [issue_ids.include?("P1-I5"), nil] }
  check("retains a completed issue with an unresolvable PR status (P1-I6)") { [issue_ids.include?("P1-I6"), nil] }
  check("retains a completed parent with a working child issue (P1-I9, P1-I10)") do
    [issue_ids.include?("P1-I9") && issue_ids.include?("P1-I10"), issue_ids.inspect]
  end
  check("retains an errored issue with a working worker (P1-I12)") { [issue_ids.include?("P1-I12"), nil] }
  check("retains an errored issue with a queued worker (P1-I13)") { [issue_ids.include?("P1-I13"), nil] }
  check("retains an errored issue with an open question (P1-I14)") { [issue_ids.include?("P1-I14"), nil] }
  check("removes workers bundled with pruned issues") do
    leftovers = %w[P1-I1-W1 P1-I2-W1 P1-I7-W1 P1-I11-W1] & agent_ids
    [leftovers.empty?, "leftover: #{leftovers.join(", ")}"]
  end
  check("keeps workers attached to retained issues") do
    missing = %w[P1-I8-W1 P1-I12-W1 P1-I13-W1 P4-I2-W1] - agent_ids
    [missing.empty?, "missing: #{missing.join(", ")}"]
  end
  check("removes a standalone errored head (H1)") do
    [!agent_ids.include?("H1") && Array(details["removed_standalone_agent_ids"]).include?("H1"), agent_ids.inspect]
  end
  check("keeps a live head (H2)") { [agent_ids.include?("H2"), agent_ids.inspect] }
  check("removes a terminal project whose issues are all eligible (P2)") do
    [!project_ids.include?("P2") && removed_projects.include?("P2"), project_ids.inspect]
  end
  check("removes an errored project whose issues are all eligible (P3)") do
    [!project_ids.include?("P3") && removed_projects.include?("P3"), project_ids.inspect]
  end
  check("keeps a terminal project with a project-level open question (Q3 blocks P5)") do
    [project_ids.include?("P5"), project_ids.inspect]
  end
  check("keeps a project that still has ineligible issues (P4)") { [project_ids.include?("P4"), project_ids.inspect] }
  check("keeps the project that still has active work (P1)") { [project_ids.include?("P1"), project_ids.inspect] }
  check("reports the combined summary in one message") do
    [result.fetch("message").to_s.start_with?("Pruned ") && result.fetch("message").to_s.include?("standalone agent"), result.fetch("message")]
  end
  check("emits exactly one prune log entry") do
    [Array(result.fetch("log_entry_ids", [])).length == 1, Array(result.fetch("log_entry_ids", [])).inspect]
  end
  check("never deletes worker workspaces") do
    kept = %w[P1-I1-W1 P1-I11-W1].all? { |dir| File.exist?(File.join(workspace_root, dir, "NOTES.md")) }
    [kept, "workspace root: #{workspace_root}"]
  end
  baseline_removed_issues = removed_issues.sort
  baseline_removed_projects = removed_projects.sort
  baseline_removed_agents = removed_agents.sort

  puts "Scenario 2: legacy selector words are accepted as no-op compatibility aliases"
  %w[resolved errored completed merged].each do |selector|
    aliased, _state = run_prune(payload: { "selector" => selector }, workspace_root: workspace_root, state_path: state_path)
    aliased_details = aliased.fetch("result", {}) || {}
    check("/prune #{selector} prunes exactly what bare /prune prunes") do
      same = Array(aliased_details["removed_issue_ids"]).sort == baseline_removed_issues &&
             Array(aliased_details["removed_project_ids"]).sort == baseline_removed_projects &&
             Array(aliased_details["removed_agent_ids"]).sort == baseline_removed_agents
      [aliased.fetch("status") == "accepted" && same, aliased.fetch("message")]
    end
    check("/prune #{selector} records the legacy selector for traceability") do
      [aliased_details["requested_selector"] == selector, aliased_details["requested_selector"].inspect]
    end
  end

  puts "Scenario 3: a second pass is idempotent"
  store = Meringue::State::Store.new(path: state_path)
  engine = Meringue::Kernel::Engine.new(
    store: store,
    harness_client: Meringue::Harness::FakeClient.new,
    head_runner: Meringue::Heads::FakeRunner.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
    forge_client: StubForgeClient.new(PR_STATUSES),
    cwd: Dir.pwd,
    config_path: File.join(temp_root, "config.toml")
  )
  before = engine.list_all
  second = engine.apply("type" => "Prune")
  after = engine.list_all
  check("re-running /prune removes nothing new") do
    same = before.fetch("issues").map { |record| record.fetch("id") } == after.fetch("issues").map { |record| record.fetch("id") } &&
           before.fetch("projects").map { |record| record.fetch("id") } == after.fetch("projects").map { |record| record.fetch("id") }
    [second.fetch("status") == "accepted" && same, second.fetch("message")]
  end

  puts "Scenario 4: slash command parsing"
  parser = Meringue::Input::SlashCommandParser.new
  bare = parser.parse("/prune")
  check("/prune parses to a Prune command with no payload") do
    [bare.type == "Prune" && bare.payload.empty?, "#{bare.type} #{bare.payload.inspect}"]
  end
  %w[resolved errored completed merged].each do |selector|
    command = parser.parse("/prune #{selector}")
    check("/prune #{selector} still parses to Prune") do
      [command.type == "Prune" && command.payload.fetch("selector", nil) == selector, "#{command.type} #{command.payload.inspect}"]
    end
  end
  rejected = parser.parse("/prune everything")
  check("an unknown argument is rejected with the short usage message") do
    [rejected.type == "InvalidSlashCommand" && rejected.payload.fetch("message").include?("no arguments"), rejected.payload.fetch("message", nil).inspect]
  end
  too_many = parser.parse("/prune resolved errored")
  check("extra arguments are rejected") { [too_many.type == "InvalidSlashCommand", too_many.type] }
  check("help and suggestions advertise /prune without options") do
    usages = Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first) +
             Meringue::Kernel::Engine::HELP_COMMANDS.map(&:first)
    prune_usages = usages.select { |usage| usage.start_with?("/prune") }
    [prune_usages.uniq == ["/prune"], prune_usages.inspect]
  end
  check("/prune offers no argument suggestions") do
    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/prune ", state: engine.list_all)
    [records.none? { |record| record.fetch("kind") == "prune_selectors" }, records.map { |record| record.fetch("usage") }.inspect]
  end

  puts
  if FAILURES.empty?
    puts "All prune checks passed."
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
