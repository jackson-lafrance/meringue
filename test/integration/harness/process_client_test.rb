# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# ProcessClient-backed harnesses (Claude Code, Antigravity) run one short-lived
# process per turn and stream JSONL on stdout. These tests drive a scripted stub
# instead of the real CLI.
class HarnessProcessClientTest < HarnessIntegrationTest
  ProcessClient = Meringue::Harness::ProcessClient

  CLAUDE_STREAM = [
    { "type" => "system", "subtype" => "init", "session_id" => "claude-sess-1" },
    { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "working on it" }] } },
    { "type" => "result", "subtype" => "success", "result" => "final answer" }
  ].freeze

  def build_claude_client(stub_config: {}, **kwargs)
    stub = write_process_stub(tmpdir, stub_config, name: "claude_stub.rb")
    client = Meringue::Harness::ClaudeCodeClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      claude_home: File.join(tmpdir, "claude-home"),
      event_timeout: 15,
      shutdown_timeout: 1,
      **kwargs
    )
    [client, stub]
  end

  def build_antigravity_client(stub_config: {}, **kwargs)
    stub = write_process_stub(tmpdir, stub_config, name: "agy_stub.rb")
    client = Meringue::Harness::AntigravityClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      event_timeout: 15,
      shutdown_timeout: 1,
      **kwargs
    )
    [client, stub]
  end

  def test_claude_spawn_returns_a_contract_shaped_session_ref_while_the_turn_runs
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM, "sleep" => 0.4 })

    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil,
                               session_name: "Fix login redirect")
    track_session(client, ref)

    HarnessSupport::REQUIRED_SESSION_REF_KEYS.each { |key| assert ref.key?(key), "missing #{key} in session ref" }
    assert_equal "claude", ref.fetch("harness")
    assert_kind_of Integer, ref.fetch("pid")
    assert_equal tmpdir, ref.fetch("cwd")
    assert_equal true, ref.fetch("is_streaming")
    assert_equal "worker", ref.fetch("metadata").fetch("kind")
    assert_equal "Fix login redirect", ref.fetch("metadata").fetch("session_name")
    refute_nil ref.fetch("last_event_at")
  end

  def test_claude_worker_argv_uses_streaming_json_and_a_generated_session_id
    client, stub = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM }, extra_args: ["--effort", "high"])

    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: "be careful",
                               session_name: "Fix login redirect")
    client.wait_for_settled(ref)

    argv = stub_argv(stub)
    assert_equal %w[--print --output-format stream-json --verbose], argv.first(4)
    pairs = argv.each_cons(2).to_a
    assert_includes pairs, ["--system-prompt", "be careful"]
    assert_includes pairs, %w[--effort high]
    session_id = pairs.find { |pair| pair.first == "--session-id" }&.last
    assert_match(/\A[0-9a-f-]{36}\z/, session_id)
    refute_includes argv, "--json-schema"
    assert_equal "do it", argv.last
  end

  def test_claude_head_argv_requests_the_structured_result_schema
    client, stub = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })

    client.spawn_session(kind: "head", cwd: tmpdir, prompt: "route this", system_prompt: nil, session_name: "Head")

    argv = stub_argv(stub)
    schema = argv.each_cons(2).find { |pair| pair.first == "--json-schema" }&.last
    refute_nil schema
    assert_equal Meringue::Heads::ResultParser.json_schema, schema
  end

  def test_claude_head_argv_can_disable_the_json_schema
    client, stub = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM }, use_json_schema: false)

    client.spawn_session(kind: "head", cwd: tmpdir, prompt: "route this", system_prompt: nil, session_name: "Head")

    refute_includes stub_argv(stub), "--json-schema"
  end

  def test_claude_turn_settles_and_state_reports_the_harness_session_id_and_result
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")

    settled = client.wait_for_settled(ref)
    state = client.get_state(ref)

    assert_equal ["agent_settled"], settled.map { |event| event.fetch("type") }
    assert_equal 0, settled.first.fetch("status")
    assert_equal "claude-sess-1", state.fetch("session_id")
    assert_equal false, state.fetch("is_streaming")
    assert_equal true, state.fetch("metadata").fetch("completed")
    assert_equal "final answer", state.fetch("metadata").fetch("last_assistant_text")
    assert_equal "final answer", client.last_assistant_text(state)
    assert_equal 0, state.fetch("metadata").fetch("exit_status")
  end

  def test_claude_read_events_normalizes_every_structured_record_once
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")
    client.wait_for_settled(ref)

    events = client.read_events(ref)

    assert_equal %w[system assistant result], events.map { |event| event.fetch("type") }
    assert(events.all? { |event| event.key?("timestamp") && event.key?("data") })
    assert_equal "claude-sess-1", events.first.fetch("data").fetch("session_id")
    assert_empty client.read_events(ref), "events are drained once per reader"
  end

  def test_claude_ignores_non_json_stdout_noise_but_keeps_it_in_the_stdout_tail
    lines = ["Welcome to Claude Code!", JSON.generate(CLAUDE_STREAM.last)]
    client, = build_claude_client(stub_config: { "stdout_lines" => lines })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")
    client.wait_for_settled(ref)

    state = client.get_state(ref)

    assert_equal ["result"], client.read_events(ref).map { |event| event.fetch("type") }
    assert_includes state.fetch("metadata").fetch("stdout_tail"), "Welcome to Claude Code!"
    assert_equal "final answer", state.fetch("metadata").fetch("last_assistant_text")
  end

  def test_claude_prompt_is_rejected_while_the_previous_turn_is_still_running
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM, "sleep" => 1.0 })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")
    track_session(client, ref)

    error = assert_raises(ProcessClient::InvalidModeError) { client.prompt_session(ref, "and this too", mode: "steer") }

    assert_match(/do not support live steer prompts yet/, error.message)
  end

  def test_claude_prompt_after_settling_resumes_the_recorded_session
    client, stub = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")
    client.wait_for_settled(ref)
    settled = client.get_state(ref)

    resumed = client.prompt_session(settled, "keep going")
    client.wait_for_settled(resumed)

    pairs = stub_argv(stub).each_cons(2).to_a
    assert_includes pairs, ["--resume", "claude-sess-1"]
    assert_equal "keep going", stub_argv(stub).last
    assert_equal "claude", resumed.fetch("harness")
    assert_equal "Task", resumed.fetch("metadata").fetch("session_name")
  end

  def test_claude_non_zero_exit_is_reported_with_stderr_context
    client, = build_claude_client(
      stub_config: { "stdout_lines" => [], "stderr" => "authentication failed\n", "exit_code" => 7 }
    )
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")

    assert_raises(ProcessClient::Error) { client.wait_for_settled(ref) }
    error = assert_raises(ProcessClient::ProcessExitedError) { client.get_state(ref) }

    assert_match(/exited with status 7/, error.message)
    assert_match(/authentication failed/, error.message)
  end

  def test_claude_abort_and_kill_stop_the_turn
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM, "sleep" => 30 })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")

    aborted = client.abort_session(ref)

    assert_equal false, aborted.fetch("is_streaming")
    refute process_alive?(ref.fetch("pid"))
    # The process registry forgot the aborted process, so a second stop is a no-op.
    assert_equal false, client.abort_session(ref).fetch("is_streaming")

    second = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "again", system_prompt: nil,
                                  session_name: "Task")
    killed = client.kill_session(second)

    assert_equal true, killed.fetch("metadata").fetch("killed")
    assert_equal false, killed.fetch("is_streaming")
    refute process_alive?(second.fetch("pid"))
  end

  def test_claude_kill_without_a_live_process_is_reported_but_not_fatal
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })

    killed = client.kill_session("pid" => 999_999, "cwd" => tmpdir, "metadata" => {})

    assert_equal true, killed.fetch("metadata").fetch("killed")
    assert_equal "no live claude process found", killed.fetch("metadata").fetch("kill_note")
  end

  def test_claude_get_state_for_a_forgotten_process_reports_completion
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })

    state = client.get_state("harness" => "claude", "pid" => 999_999, "cwd" => tmpdir,
                             "session_id" => "claude-sess-1", "metadata" => {})

    assert_equal false, state.fetch("is_streaming")
    assert_equal true, state.fetch("metadata").fetch("completed")
    assert_empty client.read_events("pid" => 999_999)
  end

  def test_claude_attach_is_delegated_to_the_terminal_opener
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })

    attached = client.attach_session("pid" => 1, "cwd" => tmpdir, "metadata" => {})

    assert_equal false, attached.fetch("metadata").fetch("attach_supported")
    assert_match(/TerminalSessionOpener/, attached.fetch("metadata").fetch("attach_note"))
  end

  def test_claude_last_assistant_text_falls_back_to_the_persisted_session_file
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })
    project_dir = File.join(tmpdir, "claude-home", "projects", "-some-workspace")
    FileUtils.mkdir_p(project_dir)
    File.open(File.join(project_dir, "sess-from-file.jsonl"), "w") do |file|
      file.puts(JSON.generate("type" => "assistant",
                              "message" => { "content" => [{ "type" => "text", "text" => "recovered from disk" }] }))
      file.puts("not json")
    end

    text = client.last_assistant_text("session_id" => "sess-from-file", "cwd" => tmpdir, "metadata" => {})

    assert_equal "recovered from disk", text
  end

  def test_claude_cwd_must_exist
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_STREAM })

    error = assert_raises(ProcessClient::Error) do
      client.spawn_session(kind: "worker", cwd: File.join(tmpdir, "nope"), prompt: "hi", system_prompt: nil,
                           session_name: "Task")
    end

    assert_match(/Working directory does not exist/, error.message)
  end

  def test_missing_binary_is_reported_as_a_harness_error
    client = Meringue::Harness::AntigravityClient.new(command: [File.join(tmpdir, "not-installed")])

    error = assert_raises(ProcessClient::Error) do
      client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "hi", system_prompt: nil, session_name: "Task")
    end

    assert_match(/Unable to start antigravity process/, error.message)
  end

  def test_antigravity_spawn_combines_the_system_prompt_into_the_user_prompt
    client, stub = build_antigravity_client(
      stub_config: { "stdout_lines" => [{ "type" => "result", "result" => "agy done" }] },
      extra_args: ["--quiet"]
    )

    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "ship it", system_prompt: "you are a worker",
                               session_name: "Task")
    client.wait_for_settled(ref)

    argv = stub_argv(stub)
    assert_equal "--print", argv.first
    assert_includes argv, "--quiet"
    assert_includes argv.last, "System instructions:\nyou are a worker"
    assert_includes argv.last, "User prompt:\nship it"
    assert_equal "antigravity", client.harness_name
    assert_equal "agy done", client.last_assistant_text(client.get_state(ref))
  end

  def test_antigravity_resume_uses_continue
    client, stub = build_antigravity_client(
      stub_config: { "stdout_lines" => [{ "type" => "result", "result" => "agy done" }] }
    )
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "ship it", system_prompt: nil, session_name: "Task")
    client.wait_for_settled(ref)

    resumed = client.prompt_session(client.get_state(ref), "one more thing")
    client.wait_for_settled(resumed)

    argv = stub_argv(stub)
    assert_equal %w[--print --continue], argv.first(2)
    assert_equal "one more thing", argv.last
    assert_equal "antigravity", resumed.fetch("harness")
  end

  def test_wait_for_settled_times_out_instead_of_hanging
    client, = build_antigravity_client(stub_config: { "stdout_lines" => [], "sleep" => 30 })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "hi", system_prompt: nil, session_name: "Task")
    track_session(client, ref)

    error = assert_raises(ProcessClient::Error) { client.wait_for_settled(ref, timeout: 0.2) }

    assert_match(/Timed out waiting for antigravity session to settle/, error.message)
  end
end
