# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# Mid-work progress extraction, per harness backend.
#
# The contract is deliberately a pure transform of an already-drained event array: some
# transports keep a single shared drain cursor, so reading events a second time for progress
# would steal them from reconciliation. These tests pin the shapes each backend produces and the
# graceful-degradation answer for a backend that cannot supply events at all.
class HarnessSessionProgressTest < HarnessIntegrationTest
  Harness = Meringue::Harness
  SessionProgress = Meringue::Harness::SessionProgress

  PI_EVENTS = [
    { "type" => "agent_start" },
    { "type" => "message_start", "message" => { "role" => "assistant", "content" => [] } },
    { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Reb" } },
    {
      "type" => "message_end",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "thinking", "thinking" => "the branch is behind" },
          { "type" => "text", "text" => "Rebasing onto  origin/main\nbefore editing." },
          { "type" => "toolCall", "name" => "bash", "arguments" => { "command" => "git rebase" } }
        ]
      }
    },
    { "type" => "tool_execution_start", "toolCallId" => "t1", "toolName" => "bash", "args" => { "command" => "rake test" } },
    { "type" => "tool_execution_update", "toolCallId" => "t1", "partialResult" => "..." },
    { "type" => "tool_execution_end", "toolCallId" => "t1" },
    { "type" => "turn_end" }
  ].freeze

  def test_pi_progress_keeps_authored_text_and_tool_calls_and_drops_token_noise
    items = Harness::PiSessionView.progress_items(PI_EVENTS)

    assert_equal %w[assistant_text tool_call], items.map { |item| item.fetch("kind") }
    assert_equal "Rebasing onto origin/main before editing.", items.first.fetch("text")
    assert_equal "bash", items.last.fetch("tool_name")
    assert_equal "rake test", items.last.fetch("summary")
  end

  def test_pi_progress_ignores_non_assistant_messages_and_unknown_events
    events = [
      { "type" => "message_end", "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "do it" }] } },
      { "type" => "message_end", "message" => { "role" => "toolResult", "content" => [{ "type" => "text", "text" => "output" }] } },
      { "type" => "queue_update", "steering" => [] },
      { "type" => "message_end", "message" => { "role" => "assistant", "content" => [{ "type" => "thinking", "thinking" => "quiet" }] } },
      "not-a-hash"
    ]

    assert_empty Harness::PiSessionView.progress_items(events)
  end

  def test_pi_client_exposes_progress_without_touching_the_event_cursor
    client = Harness::PiClient.new(command: "pi")

    items = client.session_progress(PI_EVENTS)

    assert_equal %w[assistant_text tool_call], items.map { |item| item.fetch("kind") }
  end

  def test_process_backed_harnesses_read_progress_from_their_wrapped_records
    events = [
      { "type" => "system", "timestamp" => "t0", "data" => { "type" => "system", "subtype" => "init" } },
      {
        "type" => "assistant",
        "timestamp" => "t1",
        "data" => {
          "type" => "assistant",
          "message" => {
            "content" => [
              { "type" => "text", "text" => "Running the suite before I touch anything." },
              { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "rake test" } }
            ]
          }
        }
      },
      { "type" => "result", "timestamp" => "t2", "data" => { "type" => "result", "result" => "final answer" } }
    ]

    items = SessionProgress.from_process_events(events)

    assert_equal %w[assistant_text tool_call], items.map { |item| item.fetch("kind") }
    assert_equal "Running the suite before I touch anything.", items.first.fetch("text")
    assert_equal "Bash", items.last.fetch("tool_name")
    assert_equal "rake test", items.last.fetch("summary")
  end

  def test_claude_client_derives_progress_from_the_events_it_already_drained
    client, = build_claude_client(stub_config: { "stdout_lines" => CLAUDE_PROGRESS_STREAM })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")
    client.wait_for_settled(ref)

    events = client.read_events(ref)
    items = client.session_progress(events)

    assert_equal ["Reading the failing test first."], items.select { |item| item.fetch("kind") == "assistant_text" }.map { |item| item.fetch("text") }
    assert_empty client.read_events(ref), "progress must not require a second drain"
  end

  def test_a_harness_without_json_events_reports_no_progress_instead_of_failing
    client, = build_antigravity_client(stub_config: { "stdout_lines" => ["plain text output, no JSON here"] })
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: nil, session_name: "Task")
    client.wait_for_settled(ref)

    assert_empty client.session_progress(client.read_events(ref))
  end

  def test_the_base_contract_degrades_to_no_progress
    assert_empty Harness::Client.new.session_progress([{ "type" => "message_end" }])
    assert_empty Harness::FakeClient.new.session_progress([{ "type" => "message_end" }])
    assert_empty SessionProgress.from_process_events(nil)
    assert_empty SessionProgress.from_process_events([nil, "junk", {}])
  end

  def test_progress_text_is_normalized_and_bounded
    assert_nil SessionProgress.assistant_text("   \n  ")
    assert_nil SessionProgress.assistant_text(nil)
    assert_equal "a b c", SessionProgress.assistant_text("a\n  b\tc ").fetch("text")
    long = SessionProgress.assistant_text("x" * (SessionProgress::MAX_TEXT_CHARS + 500))
    assert_equal SessionProgress::MAX_TEXT_CHARS, long.fetch("text").length
  end

  CLAUDE_PROGRESS_STREAM = [
    { "type" => "system", "subtype" => "init", "session_id" => "claude-progress-1" },
    { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "Reading the failing test first." }] } },
    { "type" => "result", "subtype" => "success", "result" => "final answer" }
  ].freeze

  private

  def build_claude_client(stub_config: {}, **kwargs)
    stub = write_process_stub(tmpdir, stub_config, name: "claude_progress_stub.rb")
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
    stub = write_process_stub(tmpdir, stub_config, name: "agy_progress_stub.rb")
    client = Meringue::Harness::AntigravityClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      event_timeout: 15,
      shutdown_timeout: 1,
      **kwargs
    )
    [client, stub]
  end
end
