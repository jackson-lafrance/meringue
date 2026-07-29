#!/usr/bin/env ruby
# frozen_string_literal: true

# Verification for exactly-once head command application, collision-safe worker
# workspace provisioning, and tolerant reconciliation.
#
# Run with:
#   ruby scripts/kernel_exactly_once_smoke.rb
#
# Each scenario reproduces a duplication symptom that was observed in real logs
# (duplicate questions, duplicate worker spawns, "head disappeared" reconcile
# failures, mid-turn prompt errors) and asserts the kernel now handles it.

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/meringue"

$failures = []
$checks = 0

def check(label)
  $checks += 1
  ok = yield
  if ok
    puts "  ok   #{label}"
  else
    puts "  FAIL #{label}"
    $failures << label
  end
rescue StandardError => e
  puts "  FAIL #{label} (#{e.class}: #{e.message})"
  $failures << label
end

def scenario(name)
  puts "\n#{name}"
  yield
end

# Every scenario gets its own state file so counts assert one scenario's effects.
def scenario_root(temp_root, name)
  root = File.join(temp_root, "state-#{name}")
  FileUtils.mkdir_p(root)
  root
end

def git(*argv, chdir:)
  system("git", *argv, chdir: chdir, out: File::NULL, err: File::NULL) || raise("git #{argv.join(" ")} failed in #{chdir}")
end

def build_git_project(root)
  FileUtils.mkdir_p(root)
  git("init", "--initial-branch", "main", chdir: root)
  git("config", "user.email", "smoke@example.com", chdir: root)
  git("config", "user.name", "Meringue Smoke", chdir: root)
  File.write(File.join(root, "README.md"), "# smoke project\n")
  git("add", ".", chdir: root)
  git("commit", "-m", "initial", chdir: root)
  root
end

def build_engine(temp_root, harness_client: Meringue::Harness::FakeClient.new, instance_pid: Process.pid, instance_id: nil)
  Meringue::Kernel::Engine.new(
    store: Meringue::State::Store.new(path: File.join(temp_root, "state.json")),
    harness_client: harness_client,
    head_runner: Meringue::Heads::FakeRunner.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(temp_root, "workspaces")),
    cwd: File.join(temp_root, "project"),
    forge_client: nil,
    config_path: File.join(temp_root, "config.toml"),
    instance_pid: instance_pid,
    instance_id: instance_id
  )
end

def spawn_head(engine, message)
  result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => message })
  raise "SpawnHead was not accepted: #{result.fetch("message")}" unless result.fetch("status") == "accepted"

  result.fetch("target_id")
end

def logs(engine)
  engine.store.load.fetch("logs")
end

def log_messages(engine)
  logs(engine).map { |entry| entry.fetch("message") }
end

temp_root = Dir.mktmpdir("meringue-exactly-once-smoke-")
project_root = build_git_project(File.join(temp_root, "project"))

begin
  scenario "1. A head result delivered twice applies its commands exactly once" do
    engine = build_engine(scenario_root(temp_root, "duplicate-apply"))
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    head_id = spawn_head(engine, "fix the duplicate clarifying questions")
    head_result = {
      "title" => "Fix duplicate clarifying questions",
      "summary" => "Create the issue and spawn one worker.",
      "commands" => [
        { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Duplicate questions", "description" => "One logical command must apply once." } },
        { "type" => "SpawnWorker", "payload" => { "issue_id" => "P1-I1", "title" => "Fix duplicate clarifying questions", "prompt" => "Investigate the duplication." } }
      ],
      "questions" => []
    }
    first = engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => head_result })
    second = engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => head_result })

    state = engine.store.load
    spawn_logs = log_messages(engine).select { |message| message.start_with?("Spawned worker") }
    check("first apply is accepted") { first.fetch("status") == "accepted" }
    check("second apply does not re-apply the batch") do
      second.dig("result", "duplicate_apply") ||
        second.fetch("message").include?("already applied") ||
        (second.fetch("status") == "rejected" && second.fetch("errors").include?("head_not_found"))
    end
    check("exactly one issue exists") { state.fetch("issues").length == 1 }
    check("exactly one worker exists") { state.fetch("agents").count { |agent| agent.fetch("type") == "worker" } == 1 }
    check("exactly one spawn log line") { spawn_logs.length == 1 }
    check("no error logs") { logs(engine).none? { |entry| entry.fetch("level") == "error" } }
  end

  scenario "2. A reworded second head result for the same head is ignored" do
    engine = build_engine(scenario_root(temp_root, "reworded-variant"))
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    head_id = spawn_head(engine, "what is the issue?")
    first_result = {
      "title" => "Clarify the request",
      "summary" => "Ask what to route.",
      "commands" => [],
      "questions" => [{ "question" => "What would you like me to route here?", "context" => "No active issues exist.", "project_id" => "P1" }]
    }
    reworded_result = {
      "title" => "Clarify the request",
      "summary" => "Ask what to route.",
      "commands" => [
        { "type" => "AskQuestion", "payload" => { "head_id" => head_id, "question" => "What would you like me to route here? Are you (a) asking about a killed issue, or (b) reporting a problem?", "context" => "Rephrased by a second delivery.", "project_id" => "P1" } }
      ],
      "questions" => [{ "question" => "What would you like me to route here? Please describe the symptom.", "context" => "Rephrased by a second delivery.", "project_id" => "P1" }]
    }
    engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => first_result, "_cleanup_head" => false })
    engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => reworded_result, "_cleanup_head" => false })

    state = engine.store.load
    question_logs = log_messages(engine).select { |message| message.start_with?("Question Q") }
    check("exactly one question is stored") { state.fetch("questions").length == 1 }
    check("exactly one question log line") { question_logs.length == 1 }
    check("the question keeps its project id") { state.fetch("questions").first.fetch("project_id") == "P1" }
  end

  scenario "3. One head result using both question channels stores one question" do
    engine = build_engine(scenario_root(temp_root, "both-question-channels"))
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    head_id = spawn_head(engine, "what is the issue?")
    head_result = {
      "title" => "Clarify the request",
      "summary" => "Ask what to route.",
      "commands" => [
        { "type" => "AskQuestion", "payload" => { "head_id" => head_id, "question" => "Which project should receive this? (command channel)", "context" => "Ambiguous." } }
      ],
      "questions" => [{ "question" => "Which project should receive this? (questions channel)", "context" => "Ambiguous.", "project_id" => "P1" }]
    }
    result = engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false })

    state = engine.store.load
    ask_result = Array(result.dig("result", "command_results")).first || {}
    check("exactly one question is stored") { state.fetch("questions").length == 1 }
    check("the AskQuestion command resolves to that question") { ask_result.fetch("target_id", nil) == state.fetch("questions").first.fetch("id") }
    check("exactly one question log line") { log_messages(engine).count { |message| message.start_with?("Question Q") } == 1 }
  end

  scenario "4. A worker workspace is provisioned despite branch and worktree collisions" do
    manager = Meringue::Workspace::Manager.new(root_path: File.join(temp_root, "collision-workspaces"))
    plan = manager.plan_worker_workspace(
      project_root: project_root,
      project_id: "P1",
      issue_id: "P1-I6",
      agent_id: "P1-I6-W1",
      task_title: "Fix duplicate clarifying questions"
    )
    branch = plan.fetch("workspace_branch")

    # Symptom: the branch survived a released worktree, so `worktree add -b` failed.
    git("branch", branch, chdir: project_root)
    reused = manager.allocate_worker_workspace(project_root: project_root, project_id: "P1", issue_id: "P1-I6", agent_id: "P1-I6-W1", task_title: "Fix duplicate clarifying questions")
    check("an orphaned owned branch is reused") { reused.fetch("errors").empty? && reused.fetch("workspace_branch") == branch }
    check("the reused workspace directory exists") { Dir.exist?(reused.fetch("workspace_path")) }

    # Same allocation again while the first worktree is live: uniquify instead of failing.
    second = manager.allocate_worker_workspace(project_root: project_root, project_id: "P1", issue_id: "P1-I6", agent_id: "P1-I6-W1", task_title: "Fix duplicate clarifying questions")
    check("a live collision is adopted or uniquified") { second.fetch("errors").empty? }
    check("the second workspace is usable") { Dir.exist?(second.fetch("workspace_path")) }

    # Stale registration: the directory is gone but git still lists the worktree.
    FileUtils.rm_rf(reused.fetch("worktree_root_path"))
    third = manager.allocate_worker_workspace(project_root: project_root, project_id: "P1", issue_id: "P1-I6", agent_id: "P1-I6-W1", task_title: "Fix duplicate clarifying questions")
    check("a stale worktree registration does not block allocation") { third.fetch("errors").empty? && Dir.exist?(third.fetch("workspace_path")) }
    check("branch names stay human facing") { [reused, second, third].all? { |workspace| workspace.fetch("workspace_branch").start_with?("meringue/fix-duplicate-clarifying-questions") } }
  end

  scenario "5. A head killed mid-batch does not fail reconciliation" do
    engine = build_engine(scenario_root(temp_root, "mid-batch-kill"))
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    head_id = spawn_head(engine, "kill me mid batch")
    engine.apply("type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Mid batch", "description" => "Mid batch issue." })
    head_result = {
      "title" => "Mid batch",
      "summary" => "Two commands where the head is removed after the first.",
      "commands" => [
        { "type" => "ModifyIssue", "payload" => { "issue_id" => "P1-I1", "title" => "Mid batch (renamed)" } },
        { "type" => "ModifyIssue", "payload" => { "issue_id" => "P1-I1", "description" => "Second command." } }
      ],
      "questions" => []
    }

    # Remove the head between commands, exactly like a concurrent cleanup did.
    killer = Thread.new do
      sleep 0.01
      engine.apply("type" => "Kill", "payload" => { "target_id" => head_id })
    end
    apply_result = engine.apply("type" => "ApplyHeadResult", "payload" => { "head_id" => head_id, "head_result" => head_result })
    killer.join
    reconcile = engine.apply("type" => "ReconcileSessions", "payload" => {})

    check("the interrupted apply is not a command failure") { %w[accepted rejected].include?(apply_result.fetch("status")) }
    check("reconciliation still succeeds") { reconcile.fetch("status") == "accepted" }
    check("no 'disappeared before command' error is logged") { log_messages(engine).none? { |message| message.include?("disappeared before command") } }
  end

  scenario "6. Another live instance does not recover an in-flight head result" do
    shared_root = scenario_root(temp_root, "instance-ownership")
    engine = build_engine(shared_root)
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    head_id = spawn_head(engine, "owned by this instance")

    # The owning instance is this live process; the foreign instance shares state.
    other_engine_pid = Process.pid
    state = engine.store.load
    head = state.fetch("agents").find { |agent| agent.fetch("id") == head_id }
    head["harness_metadata"] = head.fetch("harness_metadata").merge(
      "owner_instance_pid" => other_engine_pid,
      "owner_instance_id" => "owning-instance",
      "owner_instance_started_at" => nil,
      "head_result" => {
        "title" => "In flight",
        "summary" => "Being applied by its owner.",
        "commands" => [{ "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "In flight", "description" => "Owned elsewhere." } }],
        "questions" => []
      },
      "head_result_apply_state" => "applying"
    )
    engine.store.save(state)

    foreign = build_engine(shared_root, instance_pid: other_engine_pid + 100_000)
    reconcile = foreign.apply("type" => "ReconcileSessions", "payload" => {})
    recovered = Array(reconcile.dig("result", "recovered_head_results"))
    check("the foreign instance skips the in-flight head") { recovered.empty? }
    check("no issue was created by the foreign instance") { foreign.store.load.fetch("issues").none? { |issue| issue.fetch("title") == "In flight" } }
    check("the owning instance can still recover it") do
      owner = build_engine(shared_root, instance_pid: other_engine_pid, instance_id: "owning-instance")
      owner.apply("type" => "ReconcileSessions", "payload" => {})
      owner.store.load.fetch("issues").any? { |issue| issue.fetch("title") == "In flight" }
    end
  end

  scenario "7. A mid-turn prompt is queued and retried instead of failing" do
    mid_turn_client = Class.new(Meringue::Harness::FakeClient) do
      def initialize
        super
        @attempts = 0
      end

      def prompt_session(session_ref, prompt, mode: "normal")
        @attempts += 1
        if @attempts == 1
          raise Meringue::Harness::PiClient::SessionBusyError,
                "Meringue instance 6869 owns this Pi session (process 1920) and is still mid-turn. Retry in a moment."
        end

        super
      end
    end.new

    engine = build_engine(scenario_root(temp_root, "prompt-retry"), harness_client: mid_turn_client)
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    engine.apply("type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Prompt retry", "description" => "Prompt retry issue." })
    spawn = engine.apply("type" => "SpawnWorker", "payload" => { "issue_id" => "P1-I1", "title" => "Prompt retry", "prompt" => "Start." })
    agent_id = spawn.fetch("target_id")

    prompt_result = engine.apply("type" => "PromptAgent", "payload" => { "agent_id" => agent_id, "prompt" => "Follow up please.", "mode" => "follow_up" })
    queued_agent = engine.store.load.fetch("agents").find { |agent| agent.fetch("id") == agent_id }
    check("the mid-turn prompt is not a failure") { prompt_result.fetch("status") == "accepted" }
    check("no 'Failed PromptAgent' error is logged") { log_messages(engine).none? { |message| message.start_with?("Failed PromptAgent") } }
    check("the prompt is queued on the worker") { Array(queued_agent.fetch("harness_metadata").fetch("pending_prompts", [])).length == 1 }

    engine.apply("type" => "ReconcileSessions", "payload" => {})
    delivered_agent = engine.store.load.fetch("agents").find { |agent| agent.fetch("id") == agent_id }
    check("reconciliation delivers the queued prompt") { Array(delivered_agent.fetch("harness_metadata").fetch("pending_prompts", [])).empty? }
    check("the delivery is logged") { log_messages(engine).any? { |message| message.include?("follow-up") || message.include?("Prompted") } }
  end

  scenario "8. Two instances applying one head result spawn one worker" do
    shared_root = scenario_root(temp_root, "concurrent-instances")
    owner = build_engine(shared_root, instance_pid: Process.pid)
    owner.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    head_id = spawn_head(owner, "fix the double applied head commands")
    head_result = {
      "title" => "Fix double applied head commands",
      "summary" => "Create the issue and spawn one worker.",
      "commands" => [
        { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Double applied commands", "description" => "One logical command, one side effect." } },
        { "type" => "SpawnWorker", "payload" => { "issue_id" => "P1-I1", "title" => "Fix double applied head commands", "prompt" => "Investigate." } }
      ],
      "questions" => []
    }
    # The second instance shares the state file, exactly like two `bin/meringue`
    # windows on one machine.
    other = build_engine(shared_root, instance_pid: Process.pid)
    payload = { "head_id" => head_id, "head_result" => head_result, "_cleanup_head" => false }
    results = [owner, other].map do |engine|
      Thread.new { engine.apply("type" => "ApplyHeadResult", "payload" => payload) }
    end.map(&:value)

    state = owner.store.load
    workers = state.fetch("agents").select { |agent| agent.fetch("type") == "worker" }
    spawn_logs = state.fetch("logs").map { |entry| entry.fetch("message") }.select { |message| message.start_with?("Spawned worker") }
    branches = workers.map { |worker| worker.fetch("workspace_branch") }
    check("both applies return a result") { results.all? { |result| result.is_a?(Hash) } }
    check("exactly one issue exists") { state.fetch("issues").length == 1 }
    check("exactly one worker exists") { workers.length == 1 }
    check("exactly one spawn log line") { spawn_logs.length == 1 }
    check("exactly one workspace branch was used") { branches.uniq.length == 1 }
    check("no provisioning error is logged") { state.fetch("logs").none? { |entry| entry.fetch("message").include?("workspace provisioning failed") } }
  end

  scenario "9. The state lock keeps concurrent instances from losing updates" do
    lock_root = File.join(temp_root, "lock-check")
    FileUtils.mkdir_p(lock_root)
    lock = Meringue::State::FileLock.new(path: File.join(lock_root, "state.json.lock"), timeout: 0.2)
    check("the lock is reentrant") { lock.synchronize { lock.synchronize { lock.held? } } }
    check("the lock is released afterwards") { !lock.held? }
    check("a second process cannot hold it at the same time") do
      lock.synchronize do
        script = <<~RUBY
          $LOAD_PATH.unshift(#{Meringue.root_path("lib").inspect})
          require "meringue"
          lock = Meringue::State::FileLock.new(path: #{File.join(lock_root, "state.json.lock").inspect}, timeout: 0.05)
          lock.synchronize { }
          exit(lock.timeout_count.positive? ? 0 : 1)
        RUBY
        system(RbConfig.ruby, "-e", script)
      end
    end
  end
  scenario "10. Concurrent Meringue processes do not lose state updates" do
    shared_root = scenario_root(temp_root, "concurrent-processes")
    engine = build_engine(shared_root)
    engine.apply("type" => "AddProject", "payload" => { "path" => project_root, "name" => "smoke" })
    child_script = File.join(shared_root, "child.rb")
    File.write(child_script, <<~RUBY)
      $LOAD_PATH.unshift(#{Meringue.root_path("lib").inspect})
      require "meringue"

      tag = ARGV.fetch(0)
      engine = Meringue::Kernel::Engine.new(
        store: Meringue::State::Store.new(path: File.join(#{shared_root.inspect}, "state.json")),
        harness_client: Meringue::Harness::FakeClient.new,
        head_runner: Meringue::Heads::FakeRunner.new,
        workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(#{shared_root.inspect}, "workspaces")),
        cwd: #{project_root.inspect},
        forge_client: nil,
        config_path: File.join(#{shared_root.inspect}, "config.toml")
      )
      10.times do |index|
        engine.apply(
          "type" => "CreateIssue",
          "payload" => { "project_id" => "P1", "title" => "\#{tag}-\#{index}", "description" => "Concurrent write." }
        )
      end
    RUBY

    pids = %w[alpha beta].map { |tag| Process.spawn(RbConfig.ruby, child_script, tag) }
    pids.each { |pid| Process.wait(pid) }

    issues = engine.store.load.fetch("issues")
    check("every concurrent issue survived") { issues.length == 20 }
    check("no issue id was reused") { issues.map { |issue| issue.fetch("id") }.uniq.length == issues.length }
    check("both processes contributed") do
      titles = issues.map { |issue| issue.fetch("title") }
      titles.count { |title| title.start_with?("alpha-") } == 10 && titles.count { |title| title.start_with?("beta-") } == 10
    end
  end
ensure
  FileUtils.remove_entry(temp_root) if Dir.exist?(temp_root) && ENV["MERINGUE_KEEP_SMOKE"] != "1"
end

puts "\n#{$checks - $failures.length}/#{$checks} checks passed"
if $failures.empty?
  puts "kernel exactly-once smoke: PASS"
  exit 0
end

puts "kernel exactly-once smoke: FAIL"
$failures.each { |failure| puts "  - #{failure}" }
exit 1
