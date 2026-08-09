# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# Session views are the harness-neutral, read-only rendering contract: they
# summarize a transcript without exposing attach/kill controls.
class HarnessSessionViewTest < HarnessIntegrationTest
  SessionView = Meringue::Harness::SessionView
  PiSessionView = Meringue::Harness::PiSessionView

  def test_unavailable_snapshot_shape
    snapshot = SessionView.unavailable_snapshot(harness: "claude", message: "not supported")

    assert_equal "unsupported", snapshot.fetch("availability")
    assert_includes SessionView::AVAILABILITIES, snapshot.fetch("availability")
    assert_includes SessionView::SESSION_STATES, snapshot.fetch("session_state")
    assert_equal "claude", snapshot.fetch("harness")
    assert_empty snapshot.fetch("items")
    assert_equal "not supported", snapshot.fetch("warning")
    assert_equal({ "live_events" => false, "prompt" => false, "steer" => false, "follow_up" => false,
                   "abort" => false }, snapshot.fetch("capabilities"))
  end

  def test_default_client_view_is_unsupported_and_names_the_harness
    snapshot = Meringue::Harness::FakeClient.new.open_session_view("harness" => "fake").snapshot

    assert_equal "unsupported", snapshot.fetch("availability")
    assert_equal "fake", snapshot.fetch("harness")
    assert_match(/does not provide a native managed session view/, snapshot.fetch("warning"))
    assert_equal 0, snapshot.fetch("live_cursor")
  end

  def test_handle_exposes_no_process_controls
    handle = SessionView::Handle.new(snapshot_loader: -> { { "availability" => "live" } })

    %i[kill kill_session abort abort_session attach attach_session detach pid process prompt].each do |method|
      refute_respond_to handle, method
    end
  end

  def test_handle_polls_events_and_advances_its_own_cursor
    journal = Meringue::Harness::EventJournal.new
    journal.publish("type" => "agent_start")
    handle = SessionView::Handle.new(
      initial_cursor: 0,
      snapshot_loader: -> { { "availability" => "live", "items" => [] } },
      event_reader: ->(cursor, limit) { journal.read(after: cursor, limit: limit) },
      event_normalizer: ->(entry) { PiSessionView.normalize_event(entry) }
    )

    first = handle.poll_events
    assert_equal ["lifecycle"], first.fetch("events").map { |event| event.fetch("kind") }
    assert_equal 1, first.fetch("cursor")
    refute first.fetch("gap")

    assert_empty handle.poll_events.fetch("events")

    journal.publish("type" => "agent_settled")
    second = handle.poll_events
    assert_equal ["settled"], second.fetch("events").map { |event| event.fetch("phase") }
    assert_equal 2, handle.snapshot.fetch("live_cursor")
  end

  def test_handle_without_an_event_reader_returns_an_empty_poll
    handle = SessionView::Handle.new(initial_cursor: 7, snapshot_loader: -> { {} })

    poll = handle.poll_events

    assert_empty poll.fetch("events")
    assert_equal 7, poll.fetch("cursor")
    assert_equal 7, poll.fetch("latest_cursor")
  end

  def test_handle_close_is_idempotent_and_blocks_further_reads
    closed = []
    handle = SessionView::Handle.new(snapshot_loader: -> { {} }, close_callback: -> { closed << true })

    assert handle.close
    refute handle.close
    assert handle.closed?
    assert_equal [true], closed
    assert_raises(IOError) { handle.snapshot }
    assert_raises(IOError) { handle.poll_events }
  end

  def test_history_snapshot_renders_a_persisted_transcript_and_skips_malformed_lines
    path = pi_session_file(
      tmpdir,
      session_id: "sess-1",
      name: "Fix login redirect",
      text: "done: opened the PR",
      extra_lines: ["{ this is not json", "", "null"]
    )
    ref = pi_session_ref(session_file: path)

    snapshot = PiSessionView.history_snapshot(session_ref: ref)

    assert_equal "history", snapshot.fetch("availability")
    assert_equal "completed", snapshot.fetch("session_state")
    assert_equal "pi", snapshot.fetch("harness")
    assert_equal "sess-1", snapshot.fetch("session_id")
    assert_equal "Fix login redirect", snapshot.fetch("session_name")
    assert_equal path, snapshot.fetch("session_file")
    assert_nil snapshot.fetch("warning")
    assert_equal %w[user assistant], snapshot.fetch("items").map { |item| item.fetch("role") }
    assert_equal "done: opened the PR", snapshot.fetch("items").last.fetch("content")
    assert_equal "endTurn", snapshot.fetch("items").last.fetch("stop_reason")
    assert_equal false, snapshot.fetch("capabilities").fetch("live_events")
    assert_equal true, snapshot.fetch("capabilities").fetch("prompt")
  end

  def test_history_snapshot_follows_a_live_but_unowned_process_without_offering_prompting
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1", completed: false))

    snapshot = PiSessionView.history_snapshot(session_ref: ref, process_alive: true)

    assert_equal "history_follow", snapshot.fetch("availability")
    assert_equal "streaming", snapshot.fetch("session_state")
    assert_match(/does not own its RPC transport/, snapshot.fetch("warning"))
    assert_equal false, snapshot.fetch("capabilities").fetch("prompt")
  end

  def test_history_snapshot_is_unavailable_when_the_file_is_missing
    ref = pi_session_ref(session_file: File.join(tmpdir, "missing.jsonl"))

    snapshot = PiSessionView.history_snapshot(session_ref: ref)

    assert_equal "unavailable", snapshot.fetch("availability")
    assert_equal "unknown", snapshot.fetch("session_state")
    assert_empty snapshot.fetch("items")
    assert_match(/Saved agent session history is unavailable/, snapshot.fetch("warning"))
  end

  def test_history_snapshot_keeps_pi_control_entries_on_the_active_branch
    path = File.join(tmpdir, "controls.jsonl")
    File.open(path, "w") do |file|
      [
        { "type" => "session", "id" => "sess-controls", "cwd" => tmpdir },
        { "type" => "message", "id" => "m1", "parentId" => nil,
          "message" => { "role" => "user", "content" => "before compaction" } },
        { "type" => "compaction", "id" => "c1", "parentId" => "m1", "timestamp" => "2026-01-01T00:00:01Z",
          "summary" => "Earlier context was summarized.", "tokensBefore" => 42 },
        { "type" => "model_change", "id" => "model1", "parentId" => "c1", "timestamp" => "2026-01-01T00:00:02Z",
          "provider" => "openai", "modelId" => "gpt-5" },
        { "type" => "custom_message", "id" => "custom1", "parentId" => "model1", "timestamp" => "2026-01-01T00:00:03Z",
          "customType" => "progress", "display" => true, "content" => "Extension checkpoint" },
        { "type" => "message", "id" => "m2", "parentId" => "custom1",
          "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "continuing" }], "stopReason" => "stop" } }
      ].each { |record| file.puts(JSON.generate(record)) }
    end

    snapshot = PiSessionView.history_snapshot(session_ref: { "session_file" => path })

    assert_equal ["message", "compaction", "model_change", "custom_message", "message"], snapshot.fetch("items").map { |item| item.fetch("entry_type") }
    assert_equal "Context compacted: Earlier context was summarized.", snapshot.fetch("items")[1].fetch("content")
    assert_equal 42, snapshot.fetch("items")[1].fetch("tokens_before")
    assert_equal "Model changed: openai/gpt-5", snapshot.fetch("items")[2].fetch("content")
    assert_equal "custom", snapshot.fetch("items")[3].fetch("role")
  end

  def test_history_snapshot_only_renders_the_active_branch
    path = File.join(tmpdir, "branched.jsonl")
    File.open(path, "w") do |file|
      [
        { "type" => "session", "id" => "sess-branch", "cwd" => tmpdir },
        { "type" => "message", "id" => "m1", "parentId" => nil,
          "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "first ask" }] } },
        { "type" => "message", "id" => "abandoned", "parentId" => "m1",
          "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "abandoned branch" }],
                         "stopReason" => "endTurn" } },
        { "type" => "message", "id" => "m2", "parentId" => "m1",
          "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "active branch" }],
                         "stopReason" => "endTurn" } }
      ].each { |record| file.puts(JSON.generate(record)) }
    end

    snapshot = PiSessionView.history_snapshot(session_ref: { "session_file" => path })

    assert_equal ["first ask", "active branch"], snapshot.fetch("items").map { |item| item.fetch("content") }
  end

  def test_live_snapshot_from_entries_uses_the_leaf_branch
    entries = [
      { "type" => "message", "id" => "m1", "parentId" => nil,
        "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "hello" }] } },
      { "type" => "message", "id" => "m2", "parentId" => "m1",
        "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "hi" }] } },
      { "type" => "message", "id" => "other", "parentId" => nil,
        "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "unrelated" }] } }
    ]

    snapshot = PiSessionView.live_snapshot(
      pi_state: { "isStreaming" => true, "sessionId" => "sess-live", "sessionName" => "Live work" },
      entries: entries,
      leaf_id: "m2",
      session_ref: { "session_id" => "ignored" }
    )

    assert_equal "live", snapshot.fetch("availability")
    assert_equal "streaming", snapshot.fetch("session_state")
    assert_equal "sess-live", snapshot.fetch("session_id")
    assert_equal "Live work", snapshot.fetch("session_name")
    assert_equal %w[hello hi], snapshot.fetch("items").map { |item| item.fetch("content") }
    assert_equal true, snapshot.fetch("capabilities").fetch("live_events")
    assert_equal true, snapshot.fetch("capabilities").fetch("steer")
  end

  def test_live_snapshot_from_messages_when_entries_are_unavailable
    snapshot = PiSessionView.live_snapshot(
      pi_state: { "isStreaming" => false },
      messages: [
        { "role" => "user", "content" => "do it" },
        { "role" => "assistant", "content" => [{ "type" => "thinking", "thinking" => "planning" },
                                               { "type" => "text", "text" => "done" }] },
        { "role" => "toolResult", "toolName" => "bash", "toolCallId" => "t1",
          "content" => [{ "type" => "text", "text" => "exit 0" }] }
      ],
      session_ref: { "session_id" => "sess-msgs", "metadata" => { "session_name" => "Named by Meringue" } }
    )

    assert_equal "idle", snapshot.fetch("session_state")
    assert_equal "sess-msgs", snapshot.fetch("session_id")
    assert_equal "Named by Meringue", snapshot.fetch("session_name")
    assert_equal %w[user assistant tool], snapshot.fetch("items").map { |item| item.fetch("role") }
    assert_equal "planning", snapshot.fetch("items")[1].fetch("thinking")
    assert_equal "bash", snapshot.fetch("items")[2].fetch("tool_name")
    assert_equal "tool", snapshot.fetch("items")[2].fetch("kind")
  end

  def test_normalize_message_renders_tool_calls_images_and_bash_execution
    tool_call = PiSessionView.normalize_message(
      { "role" => "assistant",
        "content" => [{ "type" => "text", "text" => "running" },
                      { "type" => "image", "mimeType" => "image/png" },
                      { "type" => "toolCall", "id" => "t1", "name" => "bash", "arguments" => { "command" => "ls" } }] },
      id: "m1"
    )
    assert_equal "running\n[image image/png]", tool_call.fetch("content")
    assert_equal [{ "id" => "t1", "name" => "bash", "arguments" => { "command" => "ls" } }],
                 tool_call.fetch("tool_calls")

    bash = PiSessionView.normalize_message(
      { "role" => "bashExecution", "command" => "ls -la", "output" => "total 0", "exitCode" => 0 },
      id: "b1"
    )
    assert_equal "tool", bash.fetch("role")
    assert_equal "$ ls -la (exit 0)\ntotal 0", bash.fetch("content")

    errored = PiSessionView.normalize_message({ "role" => "assistant", "stopReason" => "aborted" }, id: "m2")
    assert_equal true, errored.fetch("is_error")
  end

  def test_normalize_event_maps_lifecycle_tool_and_transport_events
    assert_equal [{ "kind" => "lifecycle", "phase" => "streaming" }],
                 normalized("agent_start").map { |event| event.slice("kind", "phase") }
    assert_equal [{ "kind" => "lifecycle", "phase" => "turn_complete", "will_retry" => false }],
                 normalized("agent_end").map { |event| event.slice("kind", "phase", "will_retry") }
    assert_equal [{ "kind" => "lifecycle", "phase" => "settled" }],
                 normalized("agent_settled").map { |event| event.slice("kind", "phase") }

    tool = normalized("tool_execution_end", "toolCallId" => "t1", "toolName" => "bash",
                                            "result" => { "content" => [{ "type" => "text", "text" => "ok" }] }).first
    assert_equal "tool", tool.fetch("kind")
    assert_equal "end", tool.fetch("phase")
    assert_equal "t1", tool.fetch("id")
    assert_equal "bash", tool.fetch("tool_name")
    assert_equal "ok", tool.fetch("content")

    exited = normalized("process_exit", "status" => { "exit_code" => 1 }).first
    assert_equal "transport", exited.fetch("kind")
    assert_equal "closed", exited.fetch("phase")

    parse_error = normalized("rpc_parse_error", "error" => "boom", "line" => "junk").first
    assert_equal "transport", parse_error.fetch("kind")
    assert_equal "error", parse_error.fetch("phase")
    assert_equal "boom", parse_error.fetch("message")

    queue = normalized("queue_update", "steering" => ["a"], "followUp" => ["b"]).first
    assert_equal "queue", queue.fetch("kind")
    assert_equal ["a"], queue.fetch("steering")
    assert_equal ["b"], queue.fetch("follow_up")

    tool_delta = normalized(
      "message_update",
      "message" => { "role" => "assistant", "timestamp" => 1234, "content" => [] },
      "assistantMessageEvent" => { "type" => "toolcall_delta", "delta" => "{\\\"command\\\":\\\"rake test\\\"}" }
    ).first
    assert_equal "toolcall_delta", tool_delta.fetch("delta_type")
    assert_equal "1234", tool_delta.fetch("id")

    assert_empty normalized("some_future_pi_event")
  end

  def test_normalize_event_carries_sequence_and_timestamp
    event = PiSessionView.normalize_event(
      "sequence" => 12,
      "timestamp" => "2026-01-01T00:00:00Z",
      "event" => { "type" => "agent_start" }
    ).first

    assert_equal 12, event.fetch("sequence")
    assert_equal "2026-01-01T00:00:00Z", event.fetch("timestamp")
    assert_equal "agent_start", event.fetch("harness_event_type")
  end

  def test_tool_content_is_truncated_in_the_middle
    long = "x" * (PiSessionView::MAX_TOOL_CONTENT_CHARS + 500)

    truncated = PiSessionView.truncate_tool_content(long)

    assert_operator truncated.length, :<, long.length
    assert_includes truncated, "tool output truncated"
    assert_equal "short", PiSessionView.truncate_tool_content("short")
  end

  def test_pi_client_live_session_view_reads_entries_and_streams_events
    entries = [
      { "type" => "message", "id" => "m1", "parentId" => nil,
        "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "do the work" }] } },
      { "type" => "message", "id" => "m2", "parentId" => "m1",
        "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "on it" }],
                       "stopReason" => "endTurn" } }
    ]
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-view",
        "entries" => entries,
        "leaf_id" => "m2",
        "events_before_response" => { "prompt" => [{ "type" => "agent_start" }, { "type" => "agent_settled" }] }
      }
    )
    ref = track_session(client, client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "",
                                                     system_prompt: nil, session_name: "Live view"))

    view = client.open_session_view(ref)
    snapshot = view.snapshot

    assert_equal "live", snapshot.fetch("availability")
    assert_equal "sess-view", snapshot.fetch("session_id")
    assert_equal ["do the work", "on it"], snapshot.fetch("items").map { |item| item.fetch("content") }
    assert_equal 1, stub_commands_of_type(stub, "get_entries").length
    assert_empty stub_commands_of_type(stub, "get_messages")

    client.prompt_session(ref, "next")
    poll = view.poll_events

    assert_equal %w[streaming settled], poll.fetch("events").map { |event| event.fetch("phase") }
    assert_operator poll.fetch("cursor"), :>, 0
    # The kernel consumer keeps its own cursor, so the view did not steal events.
    assert_equal %w[agent_start agent_settled], client.read_events(ref).map { |event| event.fetch("type") }
  end

  def test_pi_client_view_replays_retained_events_when_opened_after_streaming_started
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-replay",
        "events_before_response" => { "prompt" => [{ "type" => "agent_start" }, { "type" => "message_update", "message" => { "role" => "assistant", "timestamp" => 7 }, "assistantMessageEvent" => { "type" => "text_delta", "delta" => "still working" } }] }
      }
    )
    ref = track_session(client, client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "", system_prompt: nil, session_name: "Replay"))

    client.prompt_session(ref, "continue")
    first_view = client.open_session_view(ref)
    replay = first_view.poll_events

    assert_equal %w[streaming update], replay.fetch("events").map { |event| event.fetch("phase", event.fetch("delta_type", nil)) }
    first_view.close

    client.prompt_session(ref, "continue again")
    second_view = client.open_session_view(ref)
    assert_operator second_view.poll_events.fetch("events").length, :>=, 4
    commands = stub_commands_of_type(stub, "abort") + stub_commands_of_type(stub, "kill")
    assert_empty commands, "opening and closing a view must not stop the managed Pi session"
    second_view.close
  end

  def test_pi_client_live_session_view_falls_back_to_get_messages
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => "sess-fallback",
        "fail_commands" => { "get_entries" => "unknown command get_entries" },
        "messages" => [{ "role" => "assistant", "content" => "older pi build" }]
      }
    )
    ref = track_session(client, client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "",
                                                     system_prompt: nil, session_name: "Fallback view"))

    snapshot = client.open_session_view(ref).snapshot

    assert_equal "live", snapshot.fetch("availability")
    assert_equal ["older pi build"], snapshot.fetch("items").map { |item| item.fetch("content") }
    assert_equal 1, stub_commands_of_type(stub, "get_messages").length
  end

  def test_pi_client_history_session_view_when_the_process_is_gone
    client, = build_pi_client(tmpdir)
    ref = pi_session_ref(session_file: pi_session_file(tmpdir, session_id: "sess-1", text: "all done"))

    view = client.open_session_view(ref)
    snapshot = view.snapshot

    assert_equal "history", snapshot.fetch("availability")
    assert_equal ["please fix the redirect", "all done"], snapshot.fetch("items").map { |item| item.fetch("content") }
    assert_empty view.poll_events.fetch("events"), "history views have no live event stream"
    # Repeated snapshots of an unchanged file reuse the cached parse.
    assert_equal snapshot.reject { |key, _| key == "live_cursor" }, view.snapshot.reject { |key, _| key == "live_cursor" }
  end

  private

  def normalized(type, extra = {})
    PiSessionView.normalize_event("sequence" => 1, "timestamp" => "2026-01-01T00:00:00Z",
                                  "event" => { "type" => type }.merge(extra))
  end
end
