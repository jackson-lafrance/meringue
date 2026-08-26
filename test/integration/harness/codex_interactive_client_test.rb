# frozen_string_literal: true

require "test_helper"
require "support/interactive_agent_support"
require "rbconfig"

# Exercises Codex-specific PTY behavior without an installed CLI, credentials, network, or home
# directory writes. The stand-in chooses its own thread id and emits Codex rollout records.
class HarnessCodexInteractiveClientTest < InteractiveAgentTest
  FAKE_CODEX = File.expand_path("../../fixtures/fake_codex_agent.rb", __dir__)

  class CapturingTerminal
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(value)
      writes << value
    end

    def wait_for_quiet(**_options)
      true
    end
  end

  def build_codex_client(extra_args: [], env: {})
    home = File.join(interactive_root, "codex-home")
    FileUtils.mkdir_p(home)
    client = Meringue::Harness::CodexInteractiveClient.new(
      command: [RbConfig.ruby, FAKE_CODEX],
      codex_home: home,
      env: { "FAKE_CODEX_TRUST_PROMPT" => "1" }.merge(env),
      extra_args: extra_args,
      ready_timeout: 20,
      shutdown_timeout: 1
    )
    interactive_clients << client
    client
  end

  def test_spawn_discovers_codex_assigned_session_and_attaches_focus_to_the_same_process
    argv_log = File.join(interactive_root, "argv.json")
    client = build_codex_client(
      extra_args: ["--sandbox", "read-only", "--ask-for-approval", "never"],
      env: { "FAKE_CODEX_ARGV_LOG" => argv_log }
    )
    cwd = interactive_workspace("codex-spawn")

    ref = client.spawn_session(
      kind: "head",
      cwd: cwd,
      prompt: "route this request",
      system_prompt: "Return structured JSON only.",
      session_name: "routing head",
      session_settings: { "model" => "openai/gpt-test", "thinking_level" => "high" }
    )

    assert_equal "codex", ref.fetch("harness")
    assert_match(/\A[0-9a-f-]{36}\z/, ref.fetch("session_id"))
    assert File.file?(ref.fetch("session_file")), "Codex's rollout path must be persisted"
    assert_equal "interactive_pty", ref.dig("metadata", "transport")
    assert_equal "openai/gpt-test", ref.dig("session_settings", "model", "reference")
    assert_equal "medium", ref.dig("session_settings", "thinking_level")
    refute client.session_settings_supported?, "rollout settings are readable but not mutable through Codex's live session"
    assert_equal ref.fetch("pid"), client.live_terminal(ref).pid

    argv = JSON.parse(File.read(argv_log))
    assert_includes argv.each_cons(2).to_a, ["--model", "gpt-test"]
    assert_includes argv.each_cons(2).to_a, ["-c", "model_reasoning_effort=\"high\""]
    assert_includes argv.each_cons(2).to_a, ["-c", "developer_instructions=\"Return structured JSON only.\""]

    settled = wait_until_settled(client, ref)
    assert_equal "codex answered: route this request", client.last_assistant_text(settled)
    assert_equal "openai/gpt-test", settled.dig("session_settings", "model", "reference")
    assert_equal "medium", settled.dig("session_settings", "thinking_level")
    assert_equal "completed", client.turn_outcome(settled).fetch("state")
    assert_equal "live", client.open_session_view(settled).snapshot.fetch("availability")
  end

  def test_prompting_after_process_loss_resumes_the_same_codex_session
    client = build_codex_client
    ref = client.spawn_session(
      kind: "worker",
      cwd: interactive_workspace("codex-resume"),
      prompt: "first turn",
      system_prompt: "",
      session_name: "worker"
    )
    settled = wait_until_settled(client, ref)
    session_id = settled.fetch("session_id")
    original_pid = settled.fetch("pid")
    client.kill_session(settled)

    resumed = client.prompt_session(settled.merge("pid" => nil), "second turn", mode: "normal")

    assert_equal session_id, resumed.fetch("session_id")
    refute_equal original_pid, resumed.fetch("pid")
    resumed = wait_until_settled(client, resumed)
    assert_equal "codex answered: second turn", client.last_assistant_text(resumed)
  end

  def test_codex_uses_tab_for_follow_up_and_enter_for_normal_submission
    client = build_codex_client
    terminal = CapturingTerminal.new

    client.send(:submit_prompt, terminal, "queued work", mode: "follow_up")
    assert_equal "\t", terminal.writes.last

    terminal = CapturingTerminal.new
    client.send(:submit_prompt, terminal, "normal work", mode: "normal")
    assert_equal "\r", terminal.writes.last
    assert terminal.writes.first.start_with?("\e[200~")
  end

  def test_resume_keeps_recorded_session_settings_instead_of_future_defaults
    client = build_codex_client(
      extra_args: ["--model", "future-model", "-c", "model_reasoning_effort=\"max\"", "--dangerously-bypass-approvals-and-sandbox"]
    )
    ref = {
      "session_id" => "session-1",
      "session_settings" => {
        "model" => { "reference" => "openai/original-model" },
        "thinking_level" => "low"
      },
      "metadata" => { "workspace_mode" => "isolated" }
    }

    argv = client.send(:resume_argv, ref)

    refute_includes argv, "future-model"
    refute_includes argv, "model_reasoning_effort=\"max\""
    assert_includes argv.each_cons(2).to_a, ["--model", "original-model"]
    assert_includes argv.each_cons(2).to_a, ["-c", "model_reasoning_effort=\"low\""]
    assert_equal ["resume", "session-1"], argv.last(2)
  end

  def test_shared_read_only_spawn_replaces_mutating_codex_flags
    argv_log = File.join(interactive_root, "readonly-argv.json")
    client = build_codex_client(
      extra_args: [
        "--dangerously-bypass-approvals-and-sandbox",
        "-c", 'sandbox_mode="danger-full-access"',
        "--config", 'approval_policy="on-request"',
        "-c", "features.example=true",
        "--sandbox=workspace-write",
        "-a=on-request"
      ],
      env: { "FAKE_CODEX_ARGV_LOG" => argv_log }
    )

    ref = client.spawn_session(
      kind: "worker",
      cwd: interactive_workspace("codex-readonly"),
      prompt: "inspect only",
      system_prompt: "",
      session_name: "reader",
      workspace_mode: "shared_read_only"
    )
    wait_until_settled(client, ref)

    argv = JSON.parse(File.read(argv_log))
    refute_includes argv, "--dangerously-bypass-approvals-and-sandbox"
    refute_includes argv, "--config", "a removed approval override must not leave a dangling flag"
    refute argv.any? { |argument| argument.match?(/\A(?:sandbox_mode|approval_policy)\s*=/) }
    refute argv.any? { |argument| argument.match?(/\A(?:--sandbox|-s|--ask-for-approval|-a)=/) }
    assert_includes argv.each_cons(2).to_a, ["-c", "features.example=true"]
    assert_includes argv.each_cons(2).to_a, ["--sandbox", "read-only"]
    assert_includes argv.each_cons(2).to_a, ["--ask-for-approval", "never"]
  end

  def test_codex_rollout_failure_and_auth_errors_are_classified
    records = [
      codex_event("task_started", "turn_id" => "turn-1"),
      codex_event(
        "task_complete",
        "turn_id" => "turn-1",
        "error" => { "message" => "Your access token could not be refreshed; please sign in again" }
      )
    ]

    assert_equal "idle", Meringue::Harness::CodexTranscript.session_state(records)
    outcome = Meringue::Harness::CodexTranscript.turn_outcome(records)
    assert_equal "failed", outcome.fetch("state")
    assert_equal "authentication_failure", outcome.fetch("kind")
    assert_includes outcome.fetch("reason"), "access token"
    assert_nil Meringue::Harness::CodexTranscript.last_assistant_text(records)
  end

  def test_codex_rollout_derives_authored_progress_and_delivery_receipts
    records = [
      codex_event("task_started", "turn_id" => "turn-1"),
      {
        "timestamp" => "2026-08-25T00:00:00Z",
        "type" => "turn_context",
        "payload" => { "turn_id" => "turn-1", "model" => "gpt-5.6-sol", "effort" => "high" }
      },
      codex_event("user_message", "message" => "do work <!-- meringue-delivery: cmd-1 -->"),
      codex_event("agent_message", "message" => "I found the failing boundary", "phase" => "commentary"),
      codex_event("agent_message", "message" => "Done", "phase" => "final_answer"),
      codex_event("task_complete", "turn_id" => "turn-1", "last_agent_message" => "Done")
    ]

    assert Meringue::Harness::CodexTranscript.user_prompt_present?(records, marker: "<!-- meringue-delivery: cmd-1 -->")
    assert_equal(
      [{ "kind" => "assistant_text", "text" => "I found the failing boundary" }],
      Meringue::Harness::CodexTranscript.progress(records)
    )
    assert_equal "Done", Meringue::Harness::CodexTranscript.last_assistant_text(records)
    settings = Meringue::Harness::CodexTranscript.session_settings(records)
    assert_equal "openai/gpt-5.6-sol", settings.dig("model", "reference")
    assert_equal "high", settings.fetch("thinking_level")
  end

  def test_codex_session_view_only_collapses_adjacent_duplicate_representations
    repeated = "Same final answer"
    records = [
      codex_event("user_message", "message" => "first"),
      {
        "type" => "response_item",
        "payload" => {
          "type" => "message", "role" => "assistant", "phase" => "final_answer",
          "content" => [{ "type" => "output_text", "text" => repeated }]
        }
      },
      codex_event("agent_message", "message" => repeated, "phase" => "final_answer"),
      codex_event("task_complete", "last_agent_message" => repeated),
      codex_event("user_message", "message" => "second"),
      codex_event("agent_message", "message" => repeated, "phase" => "final_answer"),
      codex_event("task_complete", "last_agent_message" => repeated)
    ]

    snapshot = Meringue::Harness::CodexTranscript.snapshot(
      records: records,
      session_ref: { "session_id" => "session-1" },
      live: false
    )
    messages = snapshot.fetch("items").select { |item| item["kind"] == "message" }

    assert_equal ["first", repeated, "second", repeated], messages.map { |item| item.fetch("content") }
  end

  private

  def codex_event(type, payload = {})
    {
      "timestamp" => "2026-08-25T00:00:00Z",
      "type" => "event_msg",
      "payload" => { "type" => type }.merge(payload)
    }
  end
end
