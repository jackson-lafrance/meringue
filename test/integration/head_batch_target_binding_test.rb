# frozen_string_literal: true

# Integration coverage for how the kernel binds head batch commands to their intended
# project/issue targets.
#
# Run it with either of:
#
#   ruby -Ilib -Itest test/integration/head_batch_target_binding_test.rb
#   rake test
require "test_helper"

require "fileutils"
require "json"
require "tmpdir"

class HeadBatchTargetBindingTest < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("meringue-batch-binding-test-")
    @state_path = File.join(@temp_root, "state.json")
    @workspace_root = File.join(@temp_root, "workspaces")
    @config_path = File.join(@temp_root, "config.toml")
    FileUtils.mkdir_p(@workspace_root)
    @project_path = git_repo!(File.join(@temp_root, "demo-project"))
    @engine = build_engine
    @project_id = accepted!(@engine.apply("type" => "AddProject", "payload" => { "path" => @project_path, "name" => "demo-project" })).fetch("target_id")
  end

  def teardown
    FileUtils.remove_entry(@temp_root) if @temp_root && Dir.exist?(@temp_root)
  end

  # Case 1: CreateIssue plus a worker for that new issue.
  def test_worker_binds_to_the_issue_created_in_the_same_batch
    head_id = spawn_head("Add a feature")
    apply_batch(head_id, [
      create_issue("Add a feature", command_id: "c1"),
      spawn_worker("Add a feature", issue_from_command: "c1")
    ])

    issue = issue_by_title("Add a feature")
    assert_equal ["Add a feature"], worker_titles(issue.fetch("id"))
  end

  # Case 2: new issue with its worker, plus a worker deliberately targeting an existing issue.
  def test_batch_serves_a_new_issue_and_an_existing_issue_at_once
    existing_id = seed_issue_with_worker("Existing goal", "Existing worker")

    head_id = spawn_head("Start a new goal and keep the old one moving")
    result = apply_batch(head_id, [
      create_issue("Fresh goal", command_id: "fresh"),
      spawn_worker("Fresh worker", issue_from_command: "fresh"),
      spawn_worker("Another existing worker", issue_id: existing_id)
    ])

    assert_all_accepted(result)
    assert_equal ["Fresh worker"], worker_titles(issue_by_title("Fresh goal").fetch("id"))
    assert_equal ["Another existing worker", "Existing worker"], worker_titles(existing_id).sort
  end

  # Case 3: several new issues in one batch, each with its own workers.
  def test_multiple_created_issues_each_keep_their_own_workers
    head_id = spawn_head("Split into two goals")
    result = apply_batch(head_id, [
      create_issue("Goal one", command_id: "one"),
      create_issue("Goal two", command_id: "two"),
      spawn_worker("Worker one A", issue_from_command: "one"),
      spawn_worker("Worker two A", issue_from_command: "two"),
      spawn_worker("Worker one B", issue_from_command: "one")
    ])

    assert_all_accepted(result)
    assert_equal ["Worker one A", "Worker one B"], worker_titles(issue_by_title("Goal one").fetch("id")).sort
    assert_equal ["Worker two A"], worker_titles(issue_by_title("Goal two").fetch("id"))
  end

  # Case 3 again, but with predicted numeric ids that go stale because another head created an
  # issue first. Each worker must still land on its own new issue.
  def test_predicted_ids_for_two_new_issues_survive_a_concurrent_creation
    head_id = spawn_head("Two goals with predicted ids")
    interloper = spawn_head("Unrelated goal")
    apply_batch(interloper, [
      create_issue("Interloper goal", command_id: "i1"),
      spawn_worker("Interloper worker", issue_from_command: "i1")
    ])

    counter = @engine.list_all.fetch("counters").fetch("issues_by_project").fetch(@project_id).to_i
    result = apply_batch(head_id, [
      create_issue("Predicted one"),
      create_issue("Predicted two"),
      spawn_worker("Predicted worker one", issue_id: "#{@project_id}-I#{counter}"),
      spawn_worker("Predicted worker two", issue_id: "#{@project_id}-I#{counter + 1}")
    ])

    assert_all_accepted(result)
    assert_equal ["Predicted worker one"], worker_titles(issue_by_title("Predicted one").fetch("id"))
    assert_equal ["Predicted worker two"], worker_titles(issue_by_title("Predicted two").fetch("id"))
    assert_equal ["Interloper worker"], worker_titles(issue_by_title("Interloper goal").fetch("id"))
  end

  # One durable goal that needs research and then implementation is one issue with two workers.
  # The implementer references the researcher's SpawnWorker command, because the researcher's agent
  # id only exists after the kernel mints the issue id.
  def test_one_created_issue_carries_a_researcher_and_a_follow_up_implementer
    head_id = spawn_head("Research the auto-research loop and then implement it")
    result = apply_batch(head_id, [
      create_issue("Goal-driven auto-research loop", command_id: "goal"),
      spawn_worker("Research looping approaches", issue_from_command: "goal", command_id: "research"),
      spawn_worker(
        "Implement the recommended loop",
        issue_from_command: "goal",
        extra: { "follow_up_of_command" => "research" }
      )
    ])

    assert_all_accepted(result)
    issue_id = issue_by_title("Goal-driven auto-research loop").fetch("id")
    assert_equal (["Implement the recommended loop", "Research looping approaches"]), worker_titles(issue_id).sort

    researcher = worker_by_title("Research looping approaches")
    implementer = worker_by_title("Implement the recommended loop")
    assert_equal issue_id, researcher.fetch("issue_id")
    assert_equal issue_id, implementer.fetch("issue_id")
    assert_equal researcher.fetch("id"), implementer.fetch("follow_up_of_agent_id")
    assert_nil (implementer.fetch("harness_metadata", {}) || {}).fetch("rerouted_from_issue_id", nil)
    assert_equal 1, @engine.list_all.fetch("issues").count { |issue| issue.fetch("title") == "Goal-driven auto-research loop" }

    logs = @engine.list_all.fetch("logs").map { |entry| entry.fetch("message", "").to_s }
    assert(logs.any? { |message| message.include?("Spawned follow-up worker #{implementer.fetch("id")} after #{researcher.fetch("id")}") })
    refute(logs.any? { |message| message.include?("Rerouted") })
  end

  # The documented shape now combines both intra-batch references: after_from_command for the
  # ordering (the kernel holds the implementer until the researcher settles) and
  # follow_up_of_command for the visible lineage. Both must resolve to the same predecessor.
  def test_queued_implementer_and_researcher_share_one_created_issue
    head_id = spawn_head("Research the loop then implement it, in order")
    result = apply_batch(head_id, [
      create_issue("Ordered auto-research loop", command_id: "goal"),
      spawn_worker("Ordered research", issue_from_command: "goal", command_id: "research"),
      spawn_worker(
        "Ordered implementation",
        issue_from_command: "goal",
        extra: { "after_from_command" => "research", "follow_up_of_command" => "research" }
      )
    ])

    assert_all_accepted(result)
    issue_id = issue_by_title("Ordered auto-research loop").fetch("id")
    researcher = worker_by_title("Ordered research")
    implementer = worker_by_title("Ordered implementation")

    assert_equal issue_id, researcher.fetch("issue_id")
    assert_equal issue_id, implementer.fetch("issue_id")
    assert_equal researcher.fetch("id"), implementer.fetch("after_agent_id")
    assert_equal "queued", implementer.fetch("status")
    # A queued worker carries its lineage as reservation intent; the top-level field is written when
    # the kernel actually spawns it, so both references must survive activation.
    assert_equal researcher.fetch("id"), implementer.fetch("harness_metadata").fetch("follow_up_of_agent_id")
    assert_nil implementer.fetch("harness_metadata").fetch("rerouted_from_issue_id", nil)
    refute(@engine.list_all.fetch("logs").any? { |entry| entry.fetch("message", "").to_s.include?("Rerouted") })

    @engine.mark_worker_completed(agent_id: researcher.fetch("id"), last_assistant_text: "Recommended design: the smallest loop.")

    started = worker_by_title("Ordered implementation")
    assert_equal issue_id, started.fetch("issue_id")
    assert_equal researcher.fetch("id"), started.fetch("follow_up_of_agent_id")
    assert_equal researcher.fetch("id"), started.fetch("after_agent_id")
    refute_equal "queued", started.fetch("status")
  end

  # The motivating shape from the user request: deliver a PR, wait for the pair review to land,
  # then start the worker that responds to it. Both gates ride on one SpawnWorker.
  def test_a_review_response_worker_waits_for_the_delivery_worker_and_the_review_command
    head_id = spawn_head("Ship the fix, then respond to the pair review")
    result = apply_batch(head_id, [
      create_issue("Fix the checkout crash", command_id: "goal"),
      spawn_worker("Fix the crash", issue_from_command: "goal", command_id: "deliver"),
      spawn_worker(
        "Respond to the pair review",
        issue_from_command: "goal",
        extra: {
          "after_from_command" => "deliver",
          "follow_up_of_command" => "deliver",
          "after_command" => "gh pr view --json reviewDecision --jq .reviewDecision | grep -qE 'APPROVED|CHANGES_REQUESTED'",
          "after_command_label" => "pair review on the delivery PR",
          "after_command_interval_seconds" => 120
        }
      )
    ])

    assert_all_accepted(result)
    issue_id = issue_by_title("Fix the checkout crash").fetch("id")
    deliverer = worker_by_title("Fix the crash")
    responder = worker_by_title("Respond to the pair review")
    gate = responder.fetch("harness_metadata").fetch("deferred_spawn").fetch("command_gate")

    assert_equal issue_id, responder.fetch("issue_id"), "one goal, two steps, one issue"
    assert_equal "queued", responder.fetch("status")
    assert_equal deliverer.fetch("id"), responder.fetch("after_agent_id")
    assert_equal "pair review on the delivery PR", gate.fetch("label")
    assert_equal 120, gate.fetch("interval_seconds")
    # The command waits for the PR to exist: it is not armed while the deliverer is still running.
    assert_nil gate.fetch("armed_at", nil)

    @engine.mark_worker_completed(agent_id: deliverer.fetch("id"), last_assistant_text: "Opened the PR.")

    still_queued = worker_by_title("Respond to the pair review")
    assert_equal "queued", still_queued.fetch("status"), "the review still has to land"
    refute_nil still_queued.fetch("harness_metadata").fetch("deferred_spawn").fetch("command_gate").fetch("armed_at")
  end

  # The whole point of the reference: another head creating an issue first must not break the pair.
  def test_follow_up_reference_survives_a_concurrent_issue_creation
    head_id = spawn_head("Research then implement with a concurrent head running")
    interloper = spawn_head("Unrelated goal")
    apply_batch(interloper, [
      create_issue("Interloping goal", command_id: "i1"),
      spawn_worker("Interloping worker", issue_from_command: "i1")
    ])

    result = apply_batch(head_id, [
      create_issue("Paired goal", command_id: "goal"),
      spawn_worker("Paired research", issue_from_command: "goal", command_id: "research"),
      spawn_worker(
        "Paired implementation",
        issue_from_command: "goal",
        extra: { "follow_up_of_agent_id" => "@research" }
      )
    ])

    assert_all_accepted(result)
    issue_id = issue_by_title("Paired goal").fetch("id")
    assert_equal ["Paired implementation", "Paired research"], worker_titles(issue_id).sort
    assert_equal worker_by_title("Paired research").fetch("id"), worker_by_title("Paired implementation").fetch("follow_up_of_agent_id")
    assert_equal ["Interloping worker"], worker_titles(issue_by_title("Interloping goal").fetch("id"))
  end

  def test_follow_up_reference_accepts_a_command_index
    head_id = spawn_head("Research then implement by index")
    result = apply_batch(head_id, [
      create_issue("Indexed goal", command_id: "goal"),
      spawn_worker("Indexed research", issue_from_command: "goal"),
      spawn_worker("Indexed implementation", issue_from_command: "goal", extra: { "follow_up_of_agent_id" => "@index:1" })
    ])

    assert_all_accepted(result)
    assert_equal worker_by_title("Indexed research").fetch("id"), worker_by_title("Indexed implementation").fetch("follow_up_of_agent_id")
  end

  def test_follow_up_reference_to_a_later_command_is_rejected
    head_id = spawn_head("Out of order pair")
    result = apply_batch(head_id, [
      create_issue("Out of order goal", command_id: "goal"),
      spawn_worker("Early implementation", issue_from_command: "goal", extra: { "follow_up_of_command" => "research" }),
      spawn_worker("Late research", issue_from_command: "goal", command_id: "research")
    ])

    rejected = command_results(result).find { |entry| entry.fetch("status", nil) == "rejected" }
    assert_includes rejected.fetch("errors"), "batch_agent_reference_out_of_order"
    assert_equal ["Late research"], worker_titles(issue_by_title("Out of order goal").fetch("id"))
  end

  def test_unknown_follow_up_reference_is_rejected
    head_id = spawn_head("Dangling reference")
    result = apply_batch(head_id, [
      create_issue("Dangling goal", command_id: "goal"),
      spawn_worker("Dangling research", issue_from_command: "goal", command_id: "research"),
      spawn_worker("Dangling implementation", issue_from_command: "goal", extra: { "follow_up_of_command" => "nope" })
    ])

    rejected = command_results(result).find { |entry| entry.fetch("status", nil) == "rejected" }
    assert_includes rejected.fetch("errors"), "batch_agent_reference_not_found"
    assert_equal ["Dangling research"], worker_titles(issue_by_title("Dangling goal").fetch("id"))
  end

  # Documents why the reference exists: a predicted worker id goes stale exactly like a predicted
  # issue id, and the kernel rejects it loudly instead of linking the wrong worker.
  def test_predicted_related_worker_id_is_rejected_when_the_issue_id_shifted
    head_id = spawn_head("Predicted worker id pair")
    predicted_issue = "#{@project_id}-I#{@engine.list_all.fetch("counters").fetch("issues_by_project").fetch(@project_id, 0).to_i + 1}"
    interloper = spawn_head("Interloping goal for the prediction")
    apply_batch(interloper, [
      create_issue("Prediction interloper", command_id: "i1"),
      spawn_worker("Prediction interloper worker", issue_from_command: "i1")
    ])

    result = apply_batch(head_id, [
      create_issue("Predicted pair goal", command_id: "goal"),
      spawn_worker("Predicted pair research", issue_from_command: "goal"),
      spawn_worker(
        "Predicted pair implementation",
        issue_from_command: "goal",
        extra: { "follow_up_of_agent_id" => "#{predicted_issue}-W1" }
      )
    ])

    rejected = command_results(result).find { |entry| entry.fetch("status", nil) == "rejected" }
    assert_includes rejected.fetch("errors"), "related_agent_issue_mismatch"
    assert_includes rejected.fetch("message"), "follow_up_of_command"
    assert_equal ["Predicted pair research"], worker_titles(issue_by_title("Predicted pair goal").fetch("id"))
  end

  # Case 4: no CreateIssue at all; an existing issue id must route untouched.
  def test_existing_issue_only_batch_is_untouched
    existing_id = seed_issue_with_worker("Only existing goal", "First worker")

    head_id = spawn_head("Keep working the existing goal")
    result = apply_batch(head_id, [spawn_worker("Second worker", issue_id: existing_id)])

    assert_all_accepted(result)
    assert_equal ["First worker", "Second worker"], worker_titles(existing_id).sort
  end

  # Case 5: AddProject followed by CreateIssue with a predicted project id, while another project
  # is registered in between.
  def test_predicted_project_id_binds_to_the_project_the_batch_registered
    head_id = spawn_head("Register a repo and start work")
    competing_path = git_repo!(File.join(@temp_root, "competing-project"))
    competing_id = accepted!(@engine.apply("type" => "AddProject", "payload" => { "path" => competing_path, "name" => "competing" })).fetch("target_id")
    new_project_path = git_repo!(File.join(@temp_root, "new-project"))
    predicted_project_id = "P#{@engine.list_all.fetch("counters").fetch("projects").to_i}"

    result = apply_batch(head_id, [
      { "type" => "AddProject", "payload" => { "path" => new_project_path, "name" => "new-project" } },
      create_issue("Bootstrap", project_id: predicted_project_id, command_id: "boot"),
      spawn_worker("Bootstrap worker", issue_from_command: "boot")
    ])

    assert_all_accepted(result)
    registered = @engine.list_all.fetch("projects").find { |project| File.expand_path(project.fetch("root_path")) == File.expand_path(new_project_path) }
    issue = issue_by_title("Bootstrap")
    assert_equal registered.fetch("id"), issue.fetch("project_id")
    refute_equal competing_id, issue.fetch("project_id")
    assert_equal ["Bootstrap worker"], worker_titles(issue.fetch("id"))
  end

  # A head that starts a goal loop does not have to create the issue first: the prompt form of
  # CreateGoal mints it. The project it lands in is bound the same way CreateIssue binds one,
  # so "register this repo and drive it to green" is a single batch with nothing predicted.
  def test_a_prompt_goal_binds_to_the_project_the_batch_registered
    head_id = spawn_head("This is critical: register the repo and keep going until the suite is green")
    new_project_path = git_repo!(File.join(@temp_root, "goal-project"))

    result = apply_batch(head_id, [
      { "type" => "AddProject", "command_id" => "add", "payload" => { "path" => new_project_path, "name" => "goal-project" } },
      {
        "type" => "CreateGoal",
        "payload" => {
          "project_from_command" => "add",
          "prompt" => "Keep going until rake test passes with zero failures.",
          "metric" => { "command" => "rake test", "comparator" => "eq", "target" => 0, "parse" => { "type" => "last_number" } }
        }
      }
    ])

    assert_all_accepted(result)
    registered = @engine.list_all.fetch("projects").find { |project| File.expand_path(project.fetch("root_path")) == File.expand_path(new_project_path) }
    goal = @engine.list_all.fetch("goals").first
    issue = issue_by_title("Keep going until rake test passes with zero failures")

    assert_equal registered.fetch("id"), goal.fetch("project_id")
    assert_equal registered.fetch("id"), issue.fetch("project_id")
    assert_equal issue.fetch("id"), goal.fetch("issue_id")
    assert_equal head_id, issue.fetch("originating_head_id"), "the minted issue is attributed to its head"
  end

  # The reported recurrence: one CreateIssue plus a large fan-out of workers that all name the
  # previous, still-visible issue id.
  def test_large_fan_out_binds_to_the_created_issue_instead_of_the_previous_issue
    previous_id = seed_issue_with_worker("Previous goal", "Previous worker")
    slice_titles = (1..13).map { |slice| "Slice #{slice}" }

    head_id = spawn_head("Replace the ad-hoc checks with a real test suite")
    result = apply_batch(
      head_id,
      [create_issue("Test suite goal")] + slice_titles.map { |title| spawn_worker(title, issue_id: previous_id) }
    )

    assert_all_accepted(result)
    suite_issue = issue_by_title("Test suite goal")
    assert_equal slice_titles.sort, worker_titles(suite_issue.fetch("id")).sort
    assert_equal ["Previous worker"], worker_titles(previous_id)
  end

  def test_fan_out_reroute_is_logged_and_recorded_on_each_worker
    previous_id = seed_issue_with_worker("Prior goal", "Prior worker")
    head_id = spawn_head("Route a new goal")
    apply_batch(head_id, [
      create_issue("Rerouted goal"),
      spawn_worker("Rerouted worker", issue_id: previous_id)
    ])

    state = @engine.list_all
    issue_id = issue_by_title("Rerouted goal").fetch("id")
    worker = state.fetch("agents").find { |agent| agent.fetch("issue_id", nil) == issue_id }
    assert_equal previous_id, (worker.fetch("harness_metadata", {}) || {}).fetch("rerouted_from_issue_id", nil)

    spawn_log = state.fetch("logs").find { |entry| entry.fetch("message", "").to_s.start_with?("Spawned worker #{worker.fetch("id")}") }
    assert_includes spawn_log.fetch("message"), "Rerouted from predicted issue #{previous_id}"
    assert(state.fetch("logs").any? { |entry| entry.fetch("level", nil) == "warning" && entry.fetch("message", "").to_s.include?("would otherwise have had no worker") })
  end

  def test_deliberate_existing_issue_worker_is_honoured_when_marked
    existing_id = seed_issue_with_worker("Marked goal", "Marked worker")
    head_id = spawn_head("Track a backlog goal and keep working")
    result = apply_batch(head_id, [
      create_issue("Backlog goal"),
      spawn_worker("Deliberate worker", issue_id: existing_id, extra: { "existing_issue" => true })
    ])

    assert_all_accepted(result)
    assert_equal ["Deliberate worker", "Marked worker"], worker_titles(existing_id).sort
    assert_empty worker_titles(issue_by_title("Backlog goal").fetch("id"))
  end

  def test_ambiguous_target_is_rejected_rather_than_misrouted
    existing_id = seed_issue_with_worker("Ambiguous base", "Base worker")
    head_id = spawn_head("Two new goals but a worker pointing elsewhere")
    result = apply_batch(head_id, [
      create_issue("Ambiguous one"),
      create_issue("Ambiguous two"),
      spawn_worker("Homeless worker", issue_id: existing_id)
    ])

    spawn_result = command_results(result).find { |entry| entry.fetch("command_type", nil) == "SpawnWorker" }
    assert_equal "rejected", spawn_result.fetch("status")
    assert_includes spawn_result.fetch("errors"), "ambiguous_batch_issue_target"
    assert_equal ["Base worker"], worker_titles(existing_id)
    assert_empty worker_titles(issue_by_title("Ambiguous one").fetch("id"))
    assert_empty worker_titles(issue_by_title("Ambiguous two").fetch("id"))
  end

  def test_no_command_re_parents_an_existing_worker
    existing_id = seed_issue_with_worker("Stable goal", "Stable worker")
    head_id = spawn_head("Create a goal and leave the old worker alone")
    apply_batch(head_id, [
      create_issue("New goal", command_id: "n1"),
      spawn_worker("New worker", issue_from_command: "n1")
    ])

    before = @engine.list_all.fetch("agents").to_h { |agent| [agent.fetch("id"), agent.fetch("issue_id", nil)] }
    @engine.apply("type" => "ModifyIssue", "payload" => { "issue_id" => existing_id, "status" => "blocked" })
    @engine.apply("type" => "ReconcileSessions", "payload" => {})
    after = @engine.list_all.fetch("agents").to_h { |agent| [agent.fetch("id"), agent.fetch("issue_id", nil)] }

    before.each do |agent_id, issue_id|
      next unless after.key?(agent_id)

      if issue_id.nil?
        assert_nil after[agent_id], "#{agent_id} changed issue"
      else
        assert_equal issue_id, after[agent_id], "#{agent_id} changed issue"
      end
    end
  end

  private

  def build_engine
    Meringue::Kernel::Engine.new(
      store: Meringue::State::Store.new(path: @state_path),
      harness_client: Meringue::Harness::FakeClient.new,
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: @workspace_root),
      cwd: @project_path,
      config_path: @config_path
    )
  end

  def git_repo!(path)
    FileUtils.mkdir_p(path)
    system("git", "init", "-q", "-b", "main", ".", chdir: path, out: File::NULL, err: File::NULL) || raise("git init failed")
    system("git", "config", "user.email", "test@example.com", chdir: path) || raise("git config failed")
    system("git", "config", "user.name", "Meringue Test", chdir: path) || raise("git config failed")
    File.write(File.join(path, "README.md"), "# fixture\n")
    system("git", "add", "README.md", chdir: path) || raise("git add failed")
    system("git", "commit", "-q", "-m", "initial", chdir: path, out: File::NULL, err: File::NULL) || raise("git commit failed")
    path
  end

  def accepted!(result)
    assert_equal "accepted", result.fetch("status"), result.fetch("message", "")
    result
  end

  def spawn_head(message)
    accepted!(@engine.apply("type" => "SpawnHead", "payload" => { "user_message" => message })).fetch("target_id")
  end

  def apply_batch(head_id, commands)
    @engine.apply(
      "type" => "ApplyHeadResult",
      "payload" => {
        "head_id" => head_id,
        "head_result" => { "title" => "Route work", "summary" => "Route work.", "commands" => commands, "questions" => [] },
        "_cleanup_head" => false
      }
    )
  end

  def create_issue(title, project_id: nil, command_id: nil)
    command = {
      "type" => "CreateIssue",
      "payload" => { "project_id" => project_id || @project_id, "title" => title, "description" => "#{title} description", "parent_issue_id" => nil }
    }
    command_id ? command.merge("command_id" => command_id) : command
  end

  def spawn_worker(title, issue_id: nil, issue_from_command: nil, command_id: nil, extra: {})
    payload = { "title" => title, "prompt" => "#{title}: do the work." }
    payload["issue_id"] = issue_id if issue_id
    payload["issue_from_command"] = issue_from_command if issue_from_command
    command = { "type" => "SpawnWorker", "payload" => payload.merge(extra) }
    command_id ? command.merge("command_id" => command_id) : command
  end

  def worker_by_title(title)
    @engine.list_all.fetch("agents").find do |agent|
      agent.fetch("type", nil) == "worker" && (agent.fetch("harness_metadata", {}) || {}).fetch("title", nil) == title
    end
  end

  def seed_issue_with_worker(issue_title, worker_title)
    head_id = spawn_head("Seed #{issue_title}")
    apply_batch(head_id, [
      create_issue(issue_title, command_id: "seed-#{issue_title.downcase.gsub(/\W+/, "-")}"),
      spawn_worker(worker_title, issue_from_command: "seed-#{issue_title.downcase.gsub(/\W+/, "-")}")
    ])
    issue_by_title(issue_title).fetch("id")
  end

  def issue_by_title(title)
    @engine.list_all.fetch("issues").find { |issue| issue.fetch("title", nil) == title }
  end

  def worker_titles(issue_id)
    @engine.list_all.fetch("agents").select do |agent|
      agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id
    end.map { |agent| (agent.fetch("harness_metadata", {}) || {}).fetch("title", nil) }
  end

  def command_results(apply_result)
    Array(apply_result.dig("result", "command_results"))
  end

  def assert_all_accepted(apply_result)
    results = command_results(apply_result)
    refute_empty results
    results.each { |entry| assert_equal "accepted", entry.fetch("status"), "#{entry.fetch("command_type")}: #{entry.fetch("message")} #{entry.fetch("errors").inspect}" }
  end
end
