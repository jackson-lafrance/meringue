# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# Drives Meringue::Harness::PiClient against a scripted JSONL stub that speaks
# the same RPC protocol as `pi --mode rpc`. No real pi process is started.
class HarnessPiClientProtocolTest < HarnessIntegrationTest
  PiClient = Meringue::Harness::PiClient

  def spawn(client, prompt: "", session_name: "Fix login redirect", system_prompt: nil, kind: "worker", cwd: nil)
    ref = client.spawn_session(
      kind: kind,
      cwd: cwd || tmpdir,
      prompt: prompt,
      system_prompt: system_prompt,
      session_name: session_name
    )
    track_session(client, ref)
  end

  def test_spawn_session_negotiates_rpc_and_returns_a_contract_shaped_session_ref
    session_file = File.join(tmpdir, "pi-sessions", "sess-42.jsonl")
    client, stub = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-42", "session_file" => session_file },
      extra_args: ["--tools", "read,bash"]
    )

    ref = spawn(client, system_prompt: "you are a worker")

    HarnessSupport::REQUIRED_SESSION_REF_KEYS.each { |key| assert ref.key?(key), "missing #{key} in session ref" }
    assert_equal "pi", ref.fetch("harness")
    assert_equal "sess-42", ref.fetch("session_id")
    assert_equal session_file, ref.fetch("session_file")
    assert_equal tmpdir, ref.fetch("cwd")
    assert_equal false, ref.fetch("is_streaming")
    assert_kind_of Integer, ref.fetch("pid")
    assert process_alive?(ref.fetch("pid"))
    assert_equal "worker", ref.fetch("metadata").fetch("kind")
    assert_equal "Fix login redirect", ref.fetch("metadata").fetch("session_name")
    assert_equal "sess-42", ref.fetch("metadata").fetch("pi_state").fetch("sessionId")

    argv = stub_argv(stub)
    assert_equal %w[--mode rpc], argv.first(2)
    assert_includes argv.each_cons(2).to_a, ["--session-dir", File.join(tmpdir, "pi-sessions")]
    assert_includes argv.each_cons(2).to_a, ["--name", "Fix login redirect"]
    assert_includes argv.each_cons(2).to_a, ["--append-system-prompt", "you are a worker"]
    assert_equal %w[--tools read,bash], argv.last(2)
  end

  def test_spawn_arguments_can_change_for_future_sessions_without_replacing_the_client_or_live_processes
    client, first_stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-42" })
    first = spawn(client, session_name: "First task")

    returned = client.configure_spawn_arguments(["--model", "openai/gpt-5.6-sol", "--thinking", "xhigh"])

    assert_equal ["--model", "openai/gpt-5.6-sol", "--thinking", "xhigh"], returned
    assert process_alive?(first.fetch("pid")), "changing defaults must not terminate an existing Pi transport"
    # The next spawn reads the new argv. The stub executable is reusable, so no
    # real Pi process or second client is needed; give its next process a unique
    # session id just as Pi would.
    config_path = first_stub.fetch("env").fetch("PI_STUB_CONFIG")
    next_config = first_stub.fetch("config").merge("session_id" => "sess-43")
    File.write(config_path, JSON.generate(next_config))
    second = spawn(client, session_name: "Second task")
    assert process_alive?(second.fetch("pid"))
    assert_equal ["--model", "openai/gpt-5.6-sol", "--thinking", "xhigh"], stub_argv(first_stub).last(4)
  end

  def test_live_session_settings_are_discovered_and_updated_through_pi_rpc
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-settings",
        "model" => { "provider" => "anthropic", "id" => "claude-opus-5" },
        "thinking_level" => "max",
        "available_thinking_levels" => %w[high xhigh max]
      }
    )
    ref = spawn(client)

    inspected = client.get_session_settings(ref)
    assert_equal "anthropic/claude-opus-5", inspected.dig("settings", "model", "reference")
    assert_equal "max", inspected.dig("settings", "thinking_level")

    model = client.set_session_model(ref, "openai/gpt-5.6-sol")
    assert_equal "openai/gpt-5.6-sol", model.dig("settings", "model", "reference")
    thinking = client.set_session_thinking_level(model.fetch("session_ref"), "xhigh")
    assert_equal "xhigh", thinking.dig("settings", "thinking_level")
    assert_equal ["set_model"], stub_commands_of_type(stub, "set_model").map { |command| command.fetch("type") }
    assert_equal ["xhigh"], stub_commands_of_type(stub, "set_thinking_level").map { |command| command.fetch("level") }
  end

  def test_switching_models_downgrades_an_unsupported_thinking_level
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-compatibility",
        "thinking_level" => "max",
        "available_thinking_levels" => ["xhigh"]
      }
    )
    ref = spawn(client)

    updated = client.set_session_model(ref, "openai/gpt-5.6-sol")

    assert_equal "openai/gpt-5.6-sol", updated.dig("settings", "model", "reference")
    assert_equal "xhigh", updated.dig("settings", "thinking_level")
    assert_equal ["xhigh"], stub_commands_of_type(stub, "set_thinking_level").map { |command| command.fetch("level") }
  end

  def test_spawn_session_sets_a_human_facing_session_name_without_meringue_or_pi_ids
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-42" })

    spawn(client, session_name: "Fix login redirect")

    names = stub_commands_of_type(stub, "set_session_name").map { |command| command.fetch("name") }
    assert_equal ["Fix login redirect"], names
    names.each do |name|
      refute_match(/meringue/i, name)
      refute_match(/\bP\d+-I\d+/, name)
      refute_match(/W\d+\b/, name)
      refute_match(/sess-|req_|session_id/i, name)
    end
  end

  def test_spawn_session_skips_the_name_rpc_when_no_session_name_is_given
    client, stub = build_pi_client(tmpdir)

    spawn(client, session_name: nil)

    assert_empty stub_commands_of_type(stub, "set_session_name")
    refute_includes stub_argv(stub), "--name"
  end

  def test_spawn_session_sends_the_initial_prompt_and_records_the_command_order
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-42" })

    spawn(client, prompt: "start the task")

    types = stub_commands(stub).map { |command| command.fetch("type") }
    assert_equal %w[get_state set_session_name get_state get_state prompt get_state], types
    prompt_command = stub_commands_of_type(stub, "prompt").fetch(0)
    assert_equal "start the task", prompt_command.fetch("message")
    assert_match(/\Areq_[0-9a-f]+\z/, prompt_command.fetch("id"))
  end

  def test_spawn_session_claims_the_transport_lock_and_kill_releases_it
    ownership = build_transport_ownership(tmpdir)
    stub = write_pi_stub(tmpdir, "session_id" => "sess-42")
    client = PiClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: ownership
    )
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "", system_prompt: nil, session_name: "Task")

    record = ownership.record_for("pi-sess-42")
    assert_equal ref.fetch("pid"), record.fetch("pid")
    assert_equal Process.pid, record.fetch("owner_pid")
    assert_equal "spawned", record.fetch("note")

    killed = client.kill_session(ref)

    assert_equal true, killed.fetch("metadata").fetch("killed")
    assert_equal false, killed.fetch("is_streaming")
    wait_until { !process_alive?(ref.fetch("pid")) }
    refute process_alive?(ref.fetch("pid"))
    released = ownership.record_for("pi-sess-42")
    assert_nil released["owner_pid"]
    assert_equal Process.pid, released.fetch("released_by")
  end

  def test_get_state_captures_session_id_and_session_file
    session_file = File.join(tmpdir, "custom-session.jsonl")
    client, = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-99", "session_file" => session_file, "session_name" => "Pi Named Session" }
    )
    ref = spawn(client, session_name: nil)

    state = client.get_state(ref)

    assert_equal "sess-99", state.fetch("session_id")
    assert_equal session_file, state.fetch("session_file")
    assert_equal false, state.fetch("is_streaming")
    assert_equal "Pi Named Session", state.fetch("metadata").fetch("session_name")
    assert_equal "sess-99", state.fetch("metadata").fetch("pi_state").fetch("sessionId")
  end

  def test_parses_responses_split_across_reads_and_ignores_interleaved_non_json_noise
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-split",
        "split_responses" => true,
        "noise" => ["pi: loading extensions", "", "not json at all {"]
      }
    )

    ref = spawn(client, prompt: "hello")

    assert_equal "sess-split", ref.fetch("session_id")
    assert_equal ["hello"], stub_commands_of_type(stub, "prompt").map { |command| command.fetch("message") }

    parse_errors = client.read_events(ref).select { |event| event.fetch("type") == "rpc_parse_error" }
    assert_equal 2, parse_errors.length, "non-JSON stdout noise is surfaced as transport parse errors, not crashes"
    assert_equal ["pi: loading extensions", "not json at all {"], parse_errors.map { |event| event.fetch("line") }
  end

  def test_read_events_drains_lifecycle_events_once_per_consumer
    client, = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-events",
        "events_before_response" => {
          "prompt" => [
            { "type" => "agent_start" },
            { "type" => "tool_execution_start", "toolCallId" => "t1", "toolName" => "bash" },
            { "type" => "tool_execution_end", "toolCallId" => "t1", "toolName" => "bash", "result" => "ok" },
            { "type" => "agent_end" },
            { "type" => "agent_settled" }
          ]
        }
      }
    )
    ref = spawn(client)

    client.prompt_session(ref, "do the work")
    events = client.read_events(ref)

    assert_equal %w[agent_start tool_execution_start tool_execution_end agent_end agent_settled],
                 events.map { |event| event.fetch("type") }
    assert_empty client.read_events(ref), "the kernel consumer cursor advances so events are drained once"
  end

  def test_prompt_modes_map_to_distinct_rpc_commands
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-modes" })
    ref = spawn(client)

    client.prompt_session(ref, "plain", mode: "normal")
    client.prompt_session(ref, "urgent", mode: "steer")
    client.prompt_session(ref, "later", mode: "follow_up")
    client.prompt_session(ref, "also later", mode: "followUp")

    assert_equal [%w[prompt plain]], stub_commands_of_type(stub, "prompt").map { |c| [c["type"], c["message"]] }
    assert_equal [%w[steer urgent]], stub_commands_of_type(stub, "steer").map { |c| [c["type"], c["message"]] }
    assert_equal [["follow_up", "later"], ["follow_up", "also later"]],
                 stub_commands_of_type(stub, "follow_up").map { |c| [c["type"], c["message"]] }
  end

  def test_unknown_prompt_mode_is_rejected
    client, = build_pi_client(tmpdir)
    ref = spawn(client)

    error = assert_raises(PiClient::InvalidModeError) { client.prompt_session(ref, "hi", mode: "yolo") }

    assert_match(/Unknown Pi prompt mode/, error.message)
    refute Meringue::Harness.transient_session_error?(error)
  end

  # Regression: a normal-mode prompt into a mid-turn session used to raise InvalidModeError, which
  # the kernel reported as a failed PromptAgent and the user's message was lost.
  def test_normal_prompt_mid_turn_is_queued_as_a_follow_up_instead_of_being_dropped
    client, stub = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-busy", "is_streaming" => true }
    )
    ref = spawn(client, prompt: "")

    prompted = client.prompt_session(ref, "hi", mode: "normal")

    assert_empty stub_commands_of_type(stub, "prompt"), "a mid-turn session must not receive a blind prompt"
    assert_equal ["hi"], stub_commands_of_type(stub, "follow_up").map { |command| command.fetch("message") }
    assert_empty stub_commands_of_type(stub, "steer"), "queueing must never interrupt the active turn"
    assert_equal true, prompted.fetch("is_streaming")
    metadata = prompted.fetch("metadata")
    assert_equal "normal", metadata.fetch("requested_prompt_mode")
    assert_equal "follow_up", metadata.fetch("delivered_prompt_mode")
    assert_match(/mid-turn/, metadata.fetch("prompt_mode_note"))
  end

  def test_steer_and_follow_up_keep_their_semantics_mid_turn
    client, stub = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-busy-modes", "is_streaming" => true }
    )
    ref = spawn(client, prompt: "")

    steered = client.prompt_session(ref, "stop, wrong file", mode: "steer")
    queued = client.prompt_session(ref, "then open the PR", mode: "follow_up")

    assert_equal ["stop, wrong file"], stub_commands_of_type(stub, "steer").map { |command| command.fetch("message") }
    assert_equal ["then open the PR"], stub_commands_of_type(stub, "follow_up").map { |command| command.fetch("message") }
    assert_nil steered.fetch("metadata")["delivered_prompt_mode"], "steer is delivered as requested"
    assert_nil queued.fetch("metadata")["delivered_prompt_mode"], "follow_up is delivered as requested"
  end

  def test_normal_prompt_on_a_settled_session_is_still_a_plain_prompt
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-settled" })
    ref = spawn(client, prompt: "")

    prompted = client.prompt_session(ref, "keep going", mode: "normal")

    assert_equal ["keep going"], stub_commands_of_type(stub, "prompt").map { |command| command.fetch("message") }
    assert_empty stub_commands_of_type(stub, "follow_up")
    assert_nil prompted.fetch("metadata")["delivered_prompt_mode"]
  end

  def test_abort_sends_the_abort_command_and_refreshes_state
    client, stub = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-abort", "is_streaming" => true }
    )
    ref = spawn(client, prompt: "")

    aborted = client.abort_session(ref)

    assert_equal 1, stub_commands_of_type(stub, "abort").length
    assert_equal false, aborted.fetch("is_streaming"), "the stub clears streaming when it handles abort"
    assert process_alive?(ref.fetch("pid")), "abort must not kill the session process"
  end

  def test_abort_without_a_live_process_raises_process_not_found
    client, = build_pi_client(tmpdir)

    error = assert_raises(PiClient::ProcessNotFoundError) do
      client.abort_session("pid" => 999_999, "session_id" => "sess-gone", "cwd" => tmpdir)
    end

    assert_match(/No live Pi RPC process/, error.message)
  end

  def test_kill_session_without_a_live_process_is_idempotent
    client, = build_pi_client(tmpdir)

    killed = client.kill_session("pid" => 999_999, "session_id" => "sess-gone", "cwd" => tmpdir, "metadata" => {})

    assert_equal true, killed.fetch("metadata").fetch("killed")
    assert_equal "no live Pi process found", killed.fetch("metadata").fetch("kill_note")
    assert_equal false, killed.fetch("is_streaming")
  end

  def test_rpc_failures_are_reported_as_rpc_errors
    client, = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-fail", "fail_commands" => { "prompt" => "pi refused the prompt" } }
    )
    ref = spawn(client)

    error = assert_raises(PiClient::RpcError) { client.prompt_session(ref, "hi") }

    assert_equal "pi refused the prompt", error.message
  end

  def test_malformed_rpc_responses_are_reported_as_rpc_errors
    client, = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-nodata" })

    missing_data = assert_raises(PiClient::RpcError) do
      client.send(:rpc_data, { "type" => "response", "success" => true, "command" => "get_state", "data" => nil })
    end
    assert_match(/did not include data/, missing_data.message)

    not_a_response = assert_raises(PiClient::RpcError) { client.send(:rpc_data, { "type" => "event" }) }
    assert_match(/Expected Pi RPC response/, not_a_response.message)

    unexplained_failure = assert_raises(PiClient::RpcError) do
      client.send(:rpc_data, { "type" => "response", "success" => false, "error" => "" })
    end
    assert_equal "Pi RPC command failed", unexplained_failure.message

    assert_nil client.send(:rpc_data, { "type" => "response", "success" => true, "data" => nil }, allow_nil_data: true)
  end

  def test_request_timeouts_are_reported_as_rpc_timeouts
    client, = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-slow", "ignore_commands" => ["never_answered"] },
      command_timeout: 0.2
    )
    ref = spawn(client)
    process = client.send(:process_for, ref)

    error = assert_raises(PiClient::RpcTimeoutError) do
      process.request({ "type" => "never_answered", "id" => "req_deadbeef" }, timeout: 0.2)
    end

    assert_match(/Timed out waiting for Pi RPC response/, error.message)
  end

  def test_pending_request_fails_when_the_process_exits_mid_turn
    client, = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-crash", "exit_before" => "prompt", "exit_code" => 3 }
    )
    ref = spawn(client)

    error = assert_raises(PiClient::ProcessExitedError) { client.prompt_session(ref, "crash now") }

    assert_match(/exited with/, error.message)
    wait_until { !process_alive?(ref.fetch("pid")) }
    refute process_alive?(ref.fetch("pid"))
  end

  def test_process_exit_is_published_as_a_transport_event
    client, = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-exit" })
    ref = spawn(client)

    waiter = Thread.new { client.wait_for_event(ref, type: "process_exit", timeout: 10) }
    sleep 0.1
    Process.kill("TERM", ref.fetch("pid"))
    events = waiter.value

    exit_event = events.last
    assert_equal "process_exit", exit_event.fetch("type")
    assert_equal ref.fetch("pid"), exit_event.fetch("pid")
    assert_equal 15, exit_event.fetch("status").fetch("termsig")
    assert_nil exit_event.fetch("status").fetch("exit_code")
  end

  def test_read_events_is_empty_once_the_transport_process_is_gone
    client, = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-dead" })
    ref = spawn(client)
    client.kill_session(ref)

    assert_empty client.read_events(ref)
  end

  def test_last_assistant_text_prefers_the_live_rpc_answer
    client, = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-text", "last_assistant_text" => "opened the PR" }
    )
    ref = spawn(client)

    assert_equal "opened the PR", client.last_assistant_text(ref)
  end

  def test_last_assistant_text_falls_back_to_the_persisted_session_file
    client, = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-file" })
    session_file = pi_session_file(tmpdir, session_id: "sess-file", text: "finished from the session file")
    ref = pi_session_ref(session_file: session_file, session_id: "sess-file", cwd: tmpdir)

    assert_equal "finished from the session file", client.last_assistant_text(ref)
  end

  def test_cwd_must_exist
    client, = build_pi_client(tmpdir)

    error = assert_raises(ArgumentError) do
      client.spawn_session(kind: "worker", cwd: File.join(tmpdir, "missing"), prompt: "", system_prompt: nil,
                           session_name: "Task")
    end

    assert_match(/must be an existing directory/, error.message)
  end

  def test_unstartable_command_is_reported_as_a_harness_error
    client = PiClient.new(
      command: [File.join(tmpdir, "definitely-not-installed")],
      session_dir: File.join(tmpdir, "pi-sessions"),
      transport_ownership: build_transport_ownership(tmpdir)
    )

    error = assert_raises(PiClient::Error) do
      client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "", system_prompt: nil, session_name: "Task")
    end

    assert_match(/Unable to start Pi RPC process/, error.message)
  end
end
