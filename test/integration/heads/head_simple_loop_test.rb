# frozen_string_literal: true

require "test_helper"
require "stringio"
require "support/heads_support"

# Drives Heads::SimpleLoop, the scripted head-loop entrypoint, end to end with a
# fake runner and a fake harness client.
class HeadSimpleLoopTest < Minitest::Test
  include HeadsSupport

  def test_run_prints_a_banner_applies_a_head_cycle_and_exits_cleanly
    setup = simple_loop_setup
    out = StringIO.new
    err = StringIO.new

    status = build_simple_loop(setup, input: "\nadd a docs cleanup task\n/quit\n", out: out, err: err).run

    assert_equal 0, status
    assert_equal "", err.string
    banner = out.string.lines.first(4).map(&:chomp)
    assert_equal "Meringue fake head loop", banner[0]
    assert_equal "Natural-language prompts run through SpawnHead -> ApplyHeadResult -> proposed kernel commands.", banner[1]
    assert_equal "Type a prompt to spawn a fake head. Type /quit to exit.", banner[2]
    assert_equal "State path: #{setup.fetch(:store).path}", banner[3]

    payload = JSON.parse(out.string[out.string.index("{")..])
    assert_equal "head_loop_iteration", payload.fetch("event")
    assert payload.fetch("state_mutated")

    state = setup.fetch(:store).load
    assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal ["P1-I1-W1"], state.fetch("agents").map { |agent| agent.fetch("id") }
    assert_empty state.fetch("agents").select { |agent| agent.fetch("type") == "head" }
  end

  def test_handle_input_returns_the_payload_without_reading_stdin
    setup = simple_loop_setup
    loop_under_test = build_simple_loop(setup, input: "")

    payload = loop_under_test.handle_input("add a docs cleanup task")

    assert_equal "head_loop_iteration", payload.fetch("event")
    assert_equal "accepted", payload.dig("apply_head_result", "status")
    assert_equal ["P1-I1"], setup.fetch(:store).load.fetch("issues").map { |issue| issue.fetch("id") }
  end

  def test_handle_input_routes_slash_commands
    setup = simple_loop_setup
    payload = build_simple_loop(setup, input: "").handle_input("/questions")

    assert_equal "slash_command_applied", payload.fetch("event")
    assert_equal "Loaded 0 questions.", payload.fetch("summary")
  end

  def test_all_exit_commands_stop_the_loop_before_spawning_a_head
    %w[/q /quit /exit /QUIT].each do |command|
      setup = simple_loop_setup
      out = StringIO.new

      assert_equal 0, build_simple_loop(setup, input: "#{command}\n", out: out).run
      assert_empty setup.fetch(:store).load.fetch("agents")
      refute_includes out.string, "head_loop_iteration"
    end
  end

  def test_end_of_input_stops_the_loop
    setup = simple_loop_setup

    assert_equal 0, build_simple_loop(setup, input: "").run
    assert_empty setup.fetch(:store).load.fetch("agents")
  end

  def test_runner_errors_are_reported_on_stderr_and_the_loop_keeps_going
    setup = simple_loop_setup(runner: ScriptedHeadRunner.new(error: Timeout::Error.new("head never settled")))
    out = StringIO.new
    err = StringIO.new

    status = build_simple_loop(setup, input: "first prompt\n/questions\n/quit\n", out: out, err: err).run

    assert_equal 0, status
    assert_equal "", err.string
    payload = JSON.parse(out.string[out.string.index("{")..out.string.index("}\n{") + 1])
    assert_equal "failed", payload.dig("spawn_head_result", "status")
    assert_includes payload.dig("spawn_head_result", "errors"), "Timeout::Error"
    assert_includes out.string, "slash_command_applied"
    assert_equal "errored", setup.fetch(:store).load.fetch("agents").first.fetch("status")
  end

  def test_unexpected_errors_are_written_to_stderr_as_an_error_payload
    setup = simple_loop_setup
    err = StringIO.new
    loop_under_test = build_simple_loop(setup, input: "boom\n/quit\n", err: err)
    loop_under_test.define_singleton_method(:handle_input) do |_text|
      raise ArgumentError, "kernel exploded"
    end

    assert_equal 0, loop_under_test.run
    payload = JSON.parse(err.string)
    assert_equal "error", payload.fetch("event")
    refute payload.fetch("state_mutated")
    assert_equal "ArgumentError", payload.dig("error", "class")
    assert_equal "kernel exploded", payload.dig("error", "message")
    assert_equal 0, payload.dig("state_summary", "agent_count")
  end

  # `meringue head-loop` builds this loop with wait_for_workers: true. It used to raise
  # `NoMethodError: private method 'harness_client'` because a second definition below the
  # engine's `private` keyword shadowed the public reader.
  def test_waiting_for_workers_settles_the_spawned_worker
    setup = simple_loop_setup(harness_client: SettlingHarnessClient.new(assistant_text: "finished"))
    out = StringIO.new
    err = StringIO.new

    status = build_simple_loop(
      setup,
      input: "add a docs cleanup task\n/quit\n",
      out: out,
      err: err,
      wait_for_workers: true
    ).run

    assert_equal 0, status
    assert_empty err.string
    payload = JSON.parse(out.string[out.string.index("{")..])
    wait_result = payload.fetch("worker_wait_results").first

    assert_equal "P1-I1-W1", wait_result.fetch("agent_id")
    assert_equal "settled", wait_result.fetch("status")
    assert_equal "finished", wait_result.fetch("last_assistant_text")
    assert_equal [["P1-I1-W1", "worker", "completed"]],
                 payload.dig("state_summary", "recent_agents").map { |agent| agent.values_at("id", "type", "status") }
  end

  def test_initial_state_seeds_an_empty_store_and_is_reused_for_routing
    seeded = head_snapshot
    setup = simple_loop_setup
    project_path = setup.fetch(:project_path)
    seeded.fetch("projects").first["root_path"] = project_path

    loop_under_test = build_simple_loop(setup, input: "", initial_state: seeded)
    payload = loop_under_test.handle_input("P1-I1-W1 please keep the existing branch")

    command_results = payload.dig("apply_head_result", "result", "command_results")
    assert_equal ["PromptAgent"], command_results.map { |result| result.fetch("command_type") }
    assert_equal "accepted", command_results.first.fetch("status")

    state = setup.fetch(:store).load
    assert_equal %w[P1], state.fetch("projects").map { |project| project.fetch("id") }
    assert_equal %w[P1-I1 P1-I2], state.fetch("issues").map { |issue| issue.fetch("id") }.sort
    worker_metadata = state.fetch("agents").find { |agent| agent.fetch("id") == "P1-I1-W1" }.fetch("harness_metadata")
    assert_equal 3, worker_metadata.fetch("prompt_count")
    assert_equal "normal", worker_metadata.fetch("last_prompt_mode")
    assert_equal "resume_session", worker_metadata.fetch("routing_action")
  end

  def test_an_existing_state_file_is_not_overwritten_by_initial_state
    setup = simple_loop_setup
    store = setup.fetch(:store)
    existing = Meringue::State::Models.empty_state
    existing["projects"] << {
      "id" => "P1",
      "name" => "already-here",
      "root_path" => setup.fetch(:project_path),
      "status" => "working",
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-01T00:00:00Z"
    }
    existing["counters"]["projects"] = 1
    store.save(existing)

    build_simple_loop(setup, input: "", initial_state: head_snapshot)

    assert_equal ["already-here"], store.load.fetch("projects").map { |project| project.fetch("name") }
  end

  def test_default_store_is_a_temporary_file_and_never_touches_the_home_state
    out = StringIO.new
    loop_under_test = Meringue::Heads::SimpleLoop.new(
      input: StringIO.new("/quit\n"),
      out: out,
      err: StringIO.new,
      cwd: head_temp_root,
      workspace_manager: StubWorkspaceManager.new(root_path: File.join(head_temp_root, "workspaces"))
    )

    assert_equal 0, loop_under_test.run
    state_path = out.string.lines.find { |line| line.start_with?("State path: ") }.sub("State path: ", "").chomp

    refute_includes state_path, File.expand_path("~/.meringue")
    assert_includes state_path, "meringue-head-loop-"
    assert File.exist?(state_path)
  ensure
    FileUtils.remove_entry(File.dirname(state_path)) if state_path && Dir.exist?(File.dirname(state_path))
  end

  def test_runner_name_is_reflected_in_the_banner
    setup = simple_loop_setup
    out = StringIO.new

    build_simple_loop(setup, input: "/quit\n", out: out, runner_name: "pi").run

    assert_includes out.string, "Meringue pi head loop"
    assert_includes out.string, "Type a prompt to spawn a pi head."
  end

  private

  def simple_loop_setup(runner: Meringue::Heads::FakeRunner.new, harness_client: Meringue::Harness::FakeClient.new)
    root = head_temp_root
    project_path = File.join(root, "demo-project")
    FileUtils.mkdir_p(File.join(project_path, ".git"))
    File.write(File.join(project_path, "README.md"), "# demo project\n")
    workspace_root = File.join(root, "workspaces")
    FileUtils.mkdir_p(workspace_root)

    {
      root: root,
      project_path: project_path,
      store: Meringue::State::Store.new(path: File.join(root, "state.json")),
      workspace_manager: StubWorkspaceManager.new(root_path: workspace_root),
      runner: runner,
      harness_client: harness_client
    }
  end

  def build_simple_loop(setup, input:, out: StringIO.new, err: StringIO.new, initial_state: nil,
                        wait_for_workers: false, runner_name: "fake")
    Meringue::Heads::SimpleLoop.new(
      input: StringIO.new(input),
      out: out,
      err: err,
      runner: setup.fetch(:runner),
      runner_name: runner_name,
      initial_state: initial_state || Meringue::State::Models.empty_state,
      cwd: setup.fetch(:project_path),
      store: setup.fetch(:store),
      harness_client: setup.fetch(:harness_client),
      workspace_manager: setup.fetch(:workspace_manager),
      wait_for_workers: wait_for_workers,
      worker_wait_timeout: 5
    )
  end
end
