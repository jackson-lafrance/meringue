# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# Single-writer transport rules for Pi sessions: reattach from a persisted
# session file when the RPC process is gone, and only take a live session over
# when its owning Meringue instance is gone (or its turn has settled).
class HarnessPiClientTransportTest < HarnessIntegrationTest
  PiClient = Meringue::Harness::PiClient

  def test_get_state_reconnects_from_the_persisted_session_file_when_the_process_is_gone
    client, = build_pi_client(tmpdir)
    dead_pid = spawn_idle_ruby_process
    reap_pid(dead_pid)
    session_file = pi_session_file(tmpdir, session_id: "sess-1", text: "worker finished the task")
    ref = pi_session_ref(session_file: session_file, pid: dead_pid, cwd: tmpdir)

    state = client.get_state(ref)

    assert_equal "pi", state.fetch("harness")
    assert_equal "sess-1", state.fetch("session_id")
    assert_equal session_file, state.fetch("session_file")
    assert_equal false, state.fetch("is_streaming")
    assert_equal true, state.fetch("metadata").fetch("reconnected_from_session_file")
    assert_equal true, state.fetch("metadata").fetch("pi_state").fetch("fromSessionFile")
    assert_equal "worker finished the task",
                 state.fetch("metadata").fetch("session_file_summary").fetch("last_assistant_text")
    assert_equal "Fix login redirect", state.fetch("metadata").fetch("session_name")
  end

  def test_get_state_reports_an_unowned_but_live_transport_without_attaching
    client, = build_pi_client(tmpdir)
    live_pid = spawn_idle_ruby_process
    session_file = pi_session_file(tmpdir, session_id: "sess-1")
    ref = pi_session_ref(session_file: session_file, pid: live_pid, cwd: tmpdir)

    state = client.get_state(ref)

    assert_equal true, state.fetch("is_streaming")
    assert_equal false, state.fetch("metadata").fetch("transport_available")
    assert_nil state.fetch("metadata").fetch("transport_owner_pid")
    assert_match(/no Meringue instance owns its RPC pipes/, state.fetch("metadata").fetch("transport_note"))
    assert process_alive?(live_pid), "reading state must never signal an unowned process"
  end

  def test_get_state_names_the_owning_instance_when_a_lock_record_exists
    client, = build_pi_client(tmpdir)
    live_pid = spawn_idle_ruby_process
    owner_pid = spawn_idle_ruby_process
    build_transport_ownership(tmpdir, owner_pid: owner_pid).claim("pi-sess-1", pid: live_pid, session_id: "sess-1")
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1"), pid: live_pid, cwd: tmpdir)

    state = client.get_state(ref)

    assert_equal owner_pid, state.fetch("metadata").fetch("transport_owner_pid")
    assert_match(/Meringue instance #{owner_pid} owns its RPC pipes/, state.fetch("metadata").fetch("transport_note"))
  end

  def test_supervision_evidence_distinguishes_shared_owner_exit_from_an_isolated_pi_exit
    owner_pid = spawn_idle_ruby_process
    harness_pid = spawn_idle_ruby_process
    ownership = build_transport_ownership(tmpdir, owner_pid: owner_pid)
    ownership.claim("pi-sess-1", pid: harness_pid, session_id: "sess-1")
    ref = pi_session_ref(
      session_file: pi_session_file(tmpdir, session_id: "sess-1", completed: false),
      pid: harness_pid,
      cwd: tmpdir
    )
    client, = build_pi_client(tmpdir, transport_ownership: ownership)

    isolated = client.session_supervision_evidence(ref)
    assert_equal true, isolated.fetch("owner_alive")
    assert_equal true, isolated.fetch("harness_alive")
    assert_equal false, isolated.fetch("supervisor_exited")

    reap_pid(harness_pid)
    harness_pid = nil
    child_only = client.session_supervision_evidence(ref)
    assert_equal true, child_only.fetch("owner_alive")
    assert_equal false, child_only.fetch("harness_alive")
    assert_equal false, child_only.fetch("supervisor_exited"), "a lone Pi crash must not be auto-replayed"

    reap_pid(owner_pid)
    owner_pid = nil
    shared_exit = client.session_supervision_evidence(ref)
    assert_equal "transport_ownership", shared_exit.fetch("source")
    assert_equal false, shared_exit.fetch("owner_alive")
    assert_equal false, shared_exit.fetch("harness_alive")
    assert_equal true, shared_exit.fetch("supervisor_exited")
    assert shared_exit.fetch("owner_started_at").to_s.start_with?("20")
    assert shared_exit.fetch("harness_started_at").to_s.start_with?("20")
  ensure
    reap_pid(harness_pid) if harness_pid
    reap_pid(owner_pid) if owner_pid
  end

  def test_supervision_evidence_falls_back_to_the_saved_session_identity_when_no_lease_exists
    dead_owner_pid = spawn_idle_ruby_process
    dead_harness_pid = spawn_idle_ruby_process
    owner_started_at = Meringue::Harness::ProcessIdentity.describe(dead_owner_pid).fetch("started_at").iso8601
    harness_started_at = Meringue::Harness::ProcessIdentity.describe(dead_harness_pid).fetch("started_at").iso8601
    reap_pid(dead_owner_pid)
    reap_pid(dead_harness_pid)
    client, = build_pi_client(tmpdir)
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1"), cwd: tmpdir)
    ref.fetch("metadata")["supervision"] = {
      "owner_pid" => dead_owner_pid,
      "owner_started_at" => owner_started_at,
      "harness_pid" => dead_harness_pid,
      "harness_started_at" => harness_started_at
    }

    evidence = client.session_supervision_evidence(ref)

    assert_equal "session_metadata", evidence.fetch("source")
    assert_equal dead_owner_pid, evidence.fetch("owner_pid")
    assert_equal dead_harness_pid, evidence.fetch("harness_pid")
    assert_equal true, evidence.fetch("supervisor_exited")
  end

  def test_a_reused_pid_cannot_route_one_session_to_another_sessions_managed_rpc_transport
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "session-b" })
    session_b_file = pi_session_file(tmpdir, session_id: "session-b", completed: false)
    session_b = client.attach_session(pi_session_ref(session_file: session_b_file, session_id: "session-b", cwd: tmpdir))
    @harness_sessions << [client, session_b]
    rpc_reads_before_collision = stub_commands_of_type(stub, "get_state").length
    session_a_file = pi_session_file(tmpdir, session_id: "session-a", text: "session A result")
    collided_ref = pi_session_ref(
      session_file: session_a_file,
      session_id: "session-a",
      pid: session_b.fetch("pid"),
      cwd: tmpdir
    )

    observed = client.get_state(collided_ref)

    assert_equal "session-a", observed.fetch("session_id")
    assert_equal "session A result", observed.dig("metadata", "session_file_summary", "last_assistant_text")
    assert_equal rpc_reads_before_collision, stub_commands_of_type(stub, "get_state").length,
                 "pid reuse must not read or command session B's pipes"
    assert process_alive?(session_b.fetch("pid"))
  end

  def test_get_state_uses_a_newer_live_transport_lease_before_recovering_a_stale_pid
    ownership = build_transport_ownership(tmpdir)
    stub = write_pi_stub(tmpdir, "session_id" => "sess-1", "is_streaming" => true)
    client_options = {
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: ownership
    }
    first_client = PiClient.new(**client_options)
    second_client = PiClient.new(**client_options)
    old_pid = spawn_idle_ruby_process
    stale_pid = old_pid
    reap_pid(old_pid)
    old_pid = nil
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    stale_ref = pi_session_ref(session_file: session_file, pid: stale_pid, cwd: tmpdir)
    attached = first_client.attach_session(stale_ref)
    @harness_sessions << [first_client, attached]
    rpc_state_reads_before_observer = stub_commands_of_type(stub, "get_state").length

    observed = second_client.get_state(stale_ref)

    assert_equal attached.fetch("pid"), observed.fetch("pid")
    assert_equal true, observed.fetch("is_streaming")
    assert_equal false, observed.dig("metadata", "transport_available")
    assert_nil observed.dig("metadata", "transport_owner_pid"),
               "both clients share this test process, so ownership is local at the PID boundary"
    assert_equal rpc_state_reads_before_observer, stub_commands_of_type(stub, "get_state").length,
                 "the observer cannot use another client's RPC pipes"
    assert process_alive?(attached.fetch("pid"))
  ensure
    reap_pid(old_pid) if old_pid
  end

  def test_get_state_raises_when_a_head_session_has_no_completed_response_and_no_process
    client, = build_pi_client(tmpdir)
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    ref = pi_session_ref(session_file: session_file, cwd: tmpdir, kind: "head")

    error = assert_raises(PiClient::ProcessExitedError) { client.get_state(ref) }

    assert_match(/no live process and no completed assistant response/, error.message)
  end

  def test_get_state_raises_when_the_session_file_is_missing
    client, = build_pi_client(tmpdir)
    ref = pi_session_ref(session_file: File.join(tmpdir, "gone.jsonl"), cwd: tmpdir)

    error = assert_raises(PiClient::ProcessNotFoundError) { client.get_state(ref) }

    assert_match(/session file is missing/, error.message)
  end

  def test_session_settings_are_discovered_from_the_current_persisted_pi_branch
    session_file = pi_session_file(
      tmpdir,
      session_id: "sess-settings",
      extra_lines: [
        JSON.generate(
          "type" => "model_change",
          "id" => "model-1",
          "parentId" => "m2",
          "provider" => "openai",
          "modelId" => "gpt-5.6-sol"
        ),
        JSON.generate(
          "type" => "thinking_level_change",
          "id" => "thinking-1",
          "parentId" => "model-1",
          "thinkingLevel" => "xhigh"
        )
      ]
    )
    client, = build_pi_client(tmpdir)
    ref = pi_session_ref(session_file: session_file, session_id: "sess-settings", cwd: tmpdir)

    outcome = client.get_session_settings(ref)

    assert_equal "openai/gpt-5.6-sol", outcome.dig("settings", "model", "reference")
    assert_equal "xhigh", outcome.dig("settings", "thinking_level")
    assert_equal "persisted_session", outcome.dig("settings", "source")
  end

  def test_attach_session_resumes_from_the_persisted_session_file
    ownership = build_transport_ownership(tmpdir)
    stub = write_pi_stub(tmpdir, "session_id" => "sess-1")
    client = PiClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      shutdown_timeout: 1,
      extra_args: ["--model", "openai/future-model", "--thinking", "xhigh", "--tools", "read,bash"],
      transport_ownership: ownership
    )
    session_file = pi_session_file(tmpdir, session_id: "sess-1")
    ref = pi_session_ref(session_file: session_file, cwd: tmpdir)

    attached = track_session(client, client.attach_session(ref))

    assert_equal true, attached.fetch("metadata").fetch("resumed_from_session")
    assert_equal session_file, attached.fetch("metadata").fetch("resume_session")
    assert_equal true, attached.fetch("metadata").fetch("attach_supported")
    assert_equal "worker", attached.fetch("metadata").fetch("kind")
    argv = stub_argv(stub)
    assert_includes argv.each_cons(2).to_a, ["--session", session_file]
    assert_includes argv.each_cons(2).to_a, ["--name", "Fix login redirect"]
    assert_includes argv.each_cons(2).to_a, ["--tools", "read,bash"]
    refute_includes argv, "openai/future-model"
    refute_includes argv, "xhigh"
    assert_equal ["Fix login redirect"], stub_commands_of_type(stub, "set_session_name").map { |c| c.fetch("name") }
    assert_equal "resumed", ownership.record_for("pi-sess-1").fetch("note")
    assert_equal attached.fetch("pid"), ownership.record_for("pi-sess-1").fetch("pid")
  end

  def test_prepare_interactive_session_aborts_and_settles_a_pending_tool_turn_before_handoff
    progress = {
      "type" => "message_end",
      "message" => {
        "role" => "assistant",
        "content" => [{ "type" => "text", "text" => "Found the race in the ownership transfer." }]
      }
    }
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-1",
        "is_streaming" => true,
        "startup_events" => [progress]
      }
    )
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    ref = pi_session_ref(session_file: session_file, cwd: tmpdir)
    ref.fetch("metadata")["interactive_handoff"] = {
      "context" => {
        "issue_id" => "P6-I24",
        "issue_title" => "Coordinate native focus handoff",
        "assignment" => "Preserve active work while changing focus ownership.",
        "workspace_path" => tmpdir,
        "workspace_branch" => "focus-handoff"
      }
    }
    managed = client.attach_session(ref)
    @harness_sessions << [client, managed]

    prepared = client.prepare_interactive_session(managed)

    assert_equal 1, stub_commands_of_type(stub, "abort").length
    refute process_alive?(managed.fetch("pid")), "the settled RPC writer must exit before native focus launches"
    assert_equal false, prepared.fetch("session_ref").fetch("is_streaming")
    assert_nil prepared.fetch("session_ref").fetch("pid")
    assert_equal true, prepared.dig("handoff", "was_streaming")
    assert_equal true, prepared.dig("handoff", "continuation_required")
    assert_equal false, prepared.dig("handoff", "exact_stream_transfer")
    assert_equal "coordinated_turn_abort", prepared.dig("handoff", "transfer")
    assert_equal "rpc_abort", prepared.dig("handoff", "interruption_method")
    assert_equal "incomplete", prepared.dig("handoff", "turn_checkpoint", "state")
    assert_equal "toolUse", prepared.dig("handoff", "turn_checkpoint", "stop_reason")
    continuation = prepared.dig("handoff", "prompt")
    assert_includes continuation, "P6-I24 — Coordinate native focus handoff"
    assert_includes continuation, "Preserve active work while changing focus ownership."
    assert_includes continuation, "Found the race in the ownership transfer."
    assert_includes continuation, tmpdir
    assert_equal continuation, prepared.fetch("interactive_argv").last
    assert_includes prepared.fetch("interactive_argv").each_cons(2).to_a, ["--session", session_file]
  end

  def test_failed_active_turn_abort_leaves_the_managed_writer_and_ownership_untouched
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-1",
        "is_streaming" => true,
        "fail_commands" => { "abort" => "tool cancellation refused" }
      }
    )
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    managed = client.attach_session(pi_session_ref(session_file: session_file, cwd: tmpdir))
    @harness_sessions << [client, managed]

    error = assert_raises(PiClient::RpcError) { client.prepare_interactive_session(managed) }

    assert_includes error.message, "tool cancellation refused"
    assert process_alive?(managed.fetch("pid")), "failed coordination must not terminate the active writer"
    assert_equal 1, stub_commands_of_type(stub, "abort").length
  end

  def test_dashboard_return_automatically_continues_when_native_focus_has_no_new_final_result
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1", "is_streaming" => true })
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    managed = client.attach_session(pi_session_ref(session_file: session_file, cwd: tmpdir))
    @harness_sessions << [client, managed]
    prepared = client.prepare_interactive_session(managed)

    resumed = client.resume_dashboard_session(prepared.fetch("session_ref"), handoff: prepared.fetch("handoff"))
    @harness_sessions << [client, resumed]

    prompts = stub_commands_of_type(stub, "prompt") + stub_commands_of_type(stub, "follow_up")
    assert_equal [prepared.dig("handoff", "prompt")], prompts.map { |command| command.fetch("message") }
    assert_equal true, resumed.fetch("is_streaming")
    assert_equal "started", resumed.dig("metadata", "interactive_dashboard_continuation")
  end

  def test_dashboard_return_does_not_repeat_a_continuation_that_finished_in_native_focus
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1", "is_streaming" => true })
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    managed = client.attach_session(pi_session_ref(session_file: session_file, cwd: tmpdir))
    @harness_sessions << [client, managed]
    prepared = client.prepare_interactive_session(managed)
    File.open(session_file, "a") do |file|
      file.puts(JSON.generate(
        "type" => "message",
        "id" => "native-final",
        "parentId" => "m2",
        "timestamp" => "2026-01-01T00:00:03Z",
        "message" => {
          "role" => "assistant",
          "content" => [{ "type" => "text", "text" => "Finished safely in native focus." }],
          "stopReason" => "endTurn"
        }
      ))
    end

    resumed = client.resume_dashboard_session(prepared.fetch("session_ref"), handoff: prepared.fetch("handoff"))
    @harness_sessions << [client, resumed]

    assert_empty stub_commands_of_type(stub, "prompt")
    assert_empty stub_commands_of_type(stub, "follow_up")
    refute_equal "started", resumed.dig("metadata", "interactive_dashboard_continuation")
  end

  def test_prepare_interactive_session_opens_a_settled_resumable_session_with_no_rpc_process
    client, = build_pi_client(tmpdir)
    session_file = pi_session_file(tmpdir, session_id: "settled-session", text: "Completed report")
    ref = pi_session_ref(session_file: session_file, session_id: "settled-session", pid: nil, cwd: tmpdir)

    prepared = client.prepare_interactive_session(ref)

    assert_nil prepared.fetch("session_ref").fetch("pid")
    assert_equal false, prepared.fetch("session_ref").fetch("is_streaming")
    assert_equal true, prepared.dig("session_ref", "metadata", "interactive_rpc_already_stopped")
    assert_equal "settled_session", prepared.dig("handoff", "transfer")
    assert_equal true, prepared.dig("handoff", "exact_stream_transfer")
    assert_nil prepared.dig("handoff", "prompt")
    assert_includes prepared.fetch("interactive_argv").each_cons(2).to_a, ["--session", session_file]
  end

  def test_prepare_interactive_session_quiesces_a_settled_rpc_quickly_and_opens_the_same_session
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1", "is_streaming" => false })
    session_file = pi_session_file(tmpdir, session_id: "sess-1")
    managed = client.attach_session(pi_session_ref(session_file: session_file, cwd: tmpdir))
    @harness_sessions << [client, managed]

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    prepared = client.prepare_interactive_session(managed)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.75
    assert_equal false, prepared.fetch("session_ref").fetch("is_streaming")
    assert_nil prepared.fetch("session_ref").fetch("pid")
    assert_equal true, prepared.dig("handoff", "exact_stream_transfer")
    assert_equal "settled_session", prepared.dig("handoff", "transfer")
    assert_nil prepared.dig("handoff", "prompt")
    assert_includes prepared.fetch("interactive_argv").each_cons(2).to_a, ["--session", session_file]
    refute_includes prepared.fetch("interactive_argv"), "--mode"
    refute process_alive?(managed.fetch("pid")), "the RPC writer must be gone before the PTY launches"
    assert_empty stub_commands_of_type(stub, "abort")
  end

  def test_prepare_interactive_session_resolves_a_bare_pi_command_from_the_harness_path
    stub = write_pi_stub(tmpdir, stub_config: { "session_id" => "sess-restricted" })
    bin_dir = File.join(tmpdir, "restricted-bin")
    pi_path = write_executable(
      tmpdir,
      "restricted-bin/pi",
      "#!/bin/sh\nexec #{RUBY_BIN} #{stub.fetch("command").fetch(1)} \"$@\"\n"
    )
    client = PiClient.new(
      command: "pi",
      env: { "PATH" => bin_dir, "PI_STUB_CONFIG" => stub.fetch("env").fetch("PI_STUB_CONFIG") },
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      event_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: build_transport_ownership(tmpdir)
    )
    # The app is intentionally launched with no inherited PATH. The only way to
    # start Pi is the provider's effective environment supplied to the client.
    with_env("PATH" => "") do
      session_file = pi_session_file(tmpdir, session_id: "sess-restricted")
      ref = pi_session_ref(session_file: session_file, cwd: tmpdir)
      managed = client.attach_session(ref)
      @harness_sessions << [client, managed]

      prepared = client.prepare_interactive_session(managed)

      assert_equal pi_path, prepared.fetch("interactive_executable")
      assert_equal bin_dir, prepared.fetch("interactive_env").fetch("PATH")
      assert_equal "pi", prepared.fetch("interactive_argv").first
      assert_equal false, prepared.fetch("session_ref").fetch("is_streaming")
    end
  end

  def test_prepare_interactive_session_preserves_the_inherited_path_that_started_rpc
    stub = write_pi_stub(tmpdir, stub_config: { "session_id" => "sess-inherited" })
    bin_dir = File.join(tmpdir, "inherited-bin")
    pi_path = write_executable(
      tmpdir,
      "inherited-bin/pi",
      "#!/bin/sh\nexec #{RUBY_BIN} #{stub.fetch("command").fetch(1)} \"$@\"\n"
    )
    client = PiClient.new(
      command: "pi",
      env: { "PI_STUB_CONFIG" => stub.fetch("env").fetch("PI_STUB_CONFIG") },
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      event_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: build_transport_ownership(tmpdir)
    )

    with_env("PATH" => bin_dir) do
      session_file = pi_session_file(tmpdir, session_id: "sess-inherited")
      managed = client.attach_session(pi_session_ref(session_file: session_file, cwd: tmpdir))
      @harness_sessions << [client, managed]

      prepared = client.prepare_interactive_session(managed)

      assert_equal pi_path, prepared.fetch("interactive_executable")
      assert_equal bin_dir, prepared.fetch("interactive_env").fetch("PATH")
    end
  end

  def test_prepare_interactive_session_reports_the_effective_path_when_pi_cannot_be_resolved
    missing_path = File.join(tmpdir, "missing-bin")
    client = PiClient.new(
      command: "pi-not-installed",
      env: { "PATH" => missing_path },
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      event_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: build_transport_ownership(tmpdir)
    )
    session_file = pi_session_file(tmpdir, session_id: "sess-missing")

    error = assert_raises(PiClient::Error) do
      client.prepare_interactive_session(pi_session_ref(session_file: session_file, cwd: tmpdir))
    end

    assert_includes error.message, 'Pi command "pi-not-installed"'
    assert_includes error.message, "PATH=#{missing_path.inspect}"
    assert_includes error.message, "[harness.pi.env] PATH"
  end

  def test_prepare_interactive_session_rebuilds_a_replacement_jsonl_when_rpc_has_no_session_path
    entry = {
      "type" => "message",
      "id" => "entry-1",
      "parentId" => nil,
      "timestamp" => "2026-01-01T00:00:01Z",
      "message" => { "role" => "user", "content" => "preserve this request" }
    }
    client, = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => nil, "is_streaming" => false, "entries" => [entry] }
    )
    source_file = pi_session_file(tmpdir, session_id: "source-session")
    ref = pi_session_ref(session_file: source_file, session_id: nil, cwd: tmpdir)
    managed = client.attach_session(ref)
    @harness_sessions << [client, managed]
    managed = managed.merge("session_id" => nil, "session_file" => nil)

    prepared = client.prepare_interactive_session(managed)
    replacement = prepared.dig("handoff", "replacement")

    assert_equal "rpc_session_file_unavailable", replacement.fetch("reason")
    assert_equal 1, replacement.fetch("entry_count")
    assert_equal "preserve this request", replacement.fetch("latest_user_intent")
    refute_includes prepared.fetch("interactive_argv"), "preserve this request"
    replacement_lines = File.readlines(replacement.fetch("session_file"), chomp: true).map { |line| JSON.parse(line) }
    assert_equal "session", replacement_lines.first.fetch("type")
    assert_equal entry, replacement_lines.last
    assert_includes prepared.fetch("interactive_argv").each_cons(2).to_a, ["--session", replacement.fetch("session_file")]
  end

  def test_reclaim_interactive_session_only_signals_a_matching_orphaned_pi_process
    client, = build_pi_client(tmpdir)
    orphan_pid = spawn_idle_ruby_process
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1"), cwd: tmpdir)
    ref.fetch("metadata")["interactive_handoff"] = {
      "interactive_started_at" => Meringue::Harness::ProcessIdentity.describe(orphan_pid).fetch("started_at").iso8601
    }

    assert client.reclaim_interactive_session(ref, pid: orphan_pid)
    refute process_alive?(orphan_pid)
  end

  def test_attach_session_refuses_to_start_a_second_process_while_the_saved_one_lives
    client, = build_pi_client(tmpdir)
    live_pid = spawn_idle_ruby_process
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1"), pid: live_pid, cwd: tmpdir)

    error = assert_raises(PiClient::SessionTransportUnavailableError) { client.attach_session(ref) }

    assert_match(/Refusing to start a second Pi process/, error.message)
    assert process_alive?(live_pid)
  end

  def test_prompting_a_settled_session_with_no_process_reattaches_and_delivers_normally
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1" })
    session_file = pi_session_file(tmpdir, session_id: "sess-1")
    ref = pi_session_ref(session_file: session_file, cwd: tmpdir)

    prompted = track_session(client, client.prompt_session(ref, "keep going"))

    assert_equal ["keep going"], stub_commands_of_type(stub, "prompt").map { |command| command.fetch("message") }
    assert_kind_of Integer, prompted.fetch("pid")
    assert process_alive?(prompted.fetch("pid"))
    assert_equal "sess-1", prompted.fetch("session_id")
    assert_nil prompted.fetch("metadata")["prompt_mode_downgraded_from"]
    assert_includes stub_argv(stub).each_cons(2).to_a, ["--session", session_file]
    # Current behaviour: prompt_session returns a state rebuilt from the live
    # process, so the attach markers set during the silent reattach are not
    # carried on the returned ref (see test/findings/harness.md).
    assert_nil prompted.fetch("metadata")["resumed_from_session"]
  end

  def test_steering_a_resumed_session_is_downgraded_to_a_normal_prompt
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1" })
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1"), cwd: tmpdir)

    prompted = track_session(client, client.prompt_session(ref, "urgent", mode: "steer"))

    assert_equal ["urgent"], stub_commands_of_type(stub, "prompt").map { |command| command.fetch("message") }
    assert_empty stub_commands_of_type(stub, "steer")
    assert_equal "steer", prompted.fetch("metadata").fetch("prompt_mode_downgraded_from")
  end

  def test_steering_an_unresumable_session_is_rejected_instead_of_silently_resuming
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1" })
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1", completed: false), cwd: tmpdir)

    error = assert_raises(PiClient::InvalidModeError) { client.prompt_session(ref, "urgent", mode: "steer") }

    assert_match(/resume it with mode: "normal"/, error.message)
    assert_empty stub_argv(stub, wait: false), "no Pi process should have been started"
  end

  # Regression for the reconciliation path: PR #207 correctly stopped treating a stale assistant
  # result as completion when a newer follow-up turn had not finished. That leaves a resumable Pi
  # transcript with no completed result, so a follow-up must be downgraded to a normal continuation
  # after reattaching instead of being rejected by the mode guard.
  def test_following_up_an_unresumable_saved_turn_reattaches_as_a_normal_continuation
    client, stub = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-1" })
    session_file = pi_session_file(
      tmpdir,
      session_id: "sess-1",
      extra_lines: [
        JSON.generate(
          "type" => "message",
          "id" => "follow-up-user",
          "parentId" => "m2",
          "timestamp" => "2026-01-01T00:00:03Z",
          "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "continue" }] }
        )
      ]
    )
    ref = pi_session_ref(session_file: session_file, cwd: tmpdir)

    prompted = track_session(client, client.prompt_session(ref, "continue the interrupted work", mode: "follow_up"))

    assert_equal ["continue the interrupted work"], stub_commands_of_type(stub, "prompt").map { |command| command.fetch("message") }
    assert_empty stub_commands_of_type(stub, "follow_up"), "a resumed session has no live turn to queue behind"
    assert_equal "follow_up", prompted.fetch("metadata").fetch("prompt_mode_downgraded_from")
    assert_equal "normal", prompted.fetch("metadata").fetch("delivered_prompt_mode")
    assert_match(/resumed and this follow-up was delivered as a normal continuation/, prompted.fetch("metadata").fetch("prompt_mode_note"))
    assert_includes stub_argv(stub).each_cons(2).to_a, ["--session", session_file]
  end

  def test_prompting_a_session_owned_by_another_live_instance_mid_turn_is_transient
    client, stub = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-1" },
      takeover_settle_timeout: 0.05
    )
    harness_pid = spawn_idle_ruby_process
    owner_pid = spawn_idle_ruby_process
    build_transport_ownership(tmpdir, owner_pid: owner_pid).claim("pi-sess-1", pid: harness_pid, session_id: "sess-1")
    session_file = pi_session_file(tmpdir, session_id: "sess-1", completed: false)
    ref = pi_session_ref(session_file: session_file, pid: harness_pid, cwd: tmpdir)

    error = assert_raises(PiClient::SessionBusyError) { client.prompt_session(ref, "take over") }

    assert_match(/Meringue instance #{owner_pid} owns this Pi session/, error.message)
    assert_match(/retry in a moment/, error.message)
    assert error.transient?, "a mid-turn conflict must be queued and retried, not surfaced as a hard failure"
    assert Meringue::Harness.transient_session_error?(error)
    assert process_alive?(harness_pid), "a session owned by a live instance must never be killed"
    assert_empty stub_argv(stub, wait: false), "no replacement Pi process should have been started"
  end

  def test_prompting_reclaims_the_transport_when_the_previous_owner_is_gone
    client, stub = build_pi_client(
      tmpdir,
      stub_config: { "session_id" => "sess-1" },
      takeover_settle_timeout: 0.05
    )
    harness_pid = spawn_idle_ruby_process
    dead_owner_pid = spawn_idle_ruby_process
    ownership = build_transport_ownership(tmpdir, owner_pid: dead_owner_pid)
    ownership.claim("pi-sess-1", pid: harness_pid, session_id: "sess-1")
    reap_pid(dead_owner_pid)
    session_file = pi_session_file(tmpdir, session_id: "sess-1")
    ref = pi_session_ref(session_file: session_file, pid: harness_pid, cwd: tmpdir)

    prompted = track_session(client, client.prompt_session(ref, "continue the work"))

    metadata = prompted.fetch("metadata")
    assert_equal true, metadata.fetch("transport_available")
    assert_equal harness_pid, metadata.fetch("transport_reclaimed_pid")
    assert_equal dead_owner_pid, metadata.fetch("transport_previous_owner_pid")
    assert_match(/took this Pi session over/, metadata.fetch("transport_note"))
    refute_nil metadata.fetch("transport_reclaimed_at")
    refute process_alive?(harness_pid), "the abandoned harness process is reclaimed"
    refute_equal harness_pid, prompted.fetch("pid")
    assert_equal ["continue the work"], stub_commands_of_type(stub, "prompt").map { |command| command.fetch("message") }
    assert_includes stub_argv(stub).each_cons(2).to_a, ["--session", session_file]
  end

  def test_session_busy_error_is_the_only_transient_pi_error
    assert Meringue::Harness.transient_session_error?(PiClient::SessionBusyError.new("busy"))
    refute Meringue::Harness.transient_session_error?(PiClient::SessionTransportUnavailableError.new("gone"))
    refute Meringue::Harness.transient_session_error?(PiClient::ProcessNotFoundError.new("missing"))
    refute Meringue::Harness.transient_session_error?(PiClient::InvalidModeError.new("bad mode"))
    refute Meringue::Harness.transient_session_error?(StandardError.new("boom"))
    assert_kind_of PiClient::SessionTransportUnavailableError, PiClient::SessionBusyError.new("busy")
  end

  def test_session_file_discovery_falls_back_to_the_session_directory
    session_dir = File.join(tmpdir, "pi-sessions")
    FileUtils.mkdir_p(session_dir)
    client, = build_pi_client(tmpdir, session_dir: session_dir)
    discovered = pi_session_file(session_dir, session_id: "sess-discovered", text: "found by session id")
    ref = { "harness" => "pi", "session_id" => "sess-discovered", "cwd" => tmpdir, "metadata" => {} }

    state = client.get_state(ref)

    assert_equal discovered, state.fetch("session_file")
    assert_equal "found by session id", state.fetch("metadata").fetch("session_file_summary").fetch("last_assistant_text")
  end
end
