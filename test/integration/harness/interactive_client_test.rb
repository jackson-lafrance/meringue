# frozen_string_literal: true

require "test_helper"
require "support/interactive_agent_support"

# The interactive transport is what makes a backend both autonomously drivable and directly
# viewable. These tests run a real PTY against a stand-in agent CLI, because the behaviours that
# matter here — bracketed paste, the interrupt key, a transcript written while work happens, and a
# screen a viewer can attach to — only exist in a real terminal.
class InteractiveClientTest < InteractiveAgentTest
  def test_spawning_a_session_starts_one_process_and_delivers_the_first_prompt
    client = build_interactive_client
    cwd = interactive_workspace

    ref = client.spawn_session(
      kind: "worker",
      cwd: cwd,
      prompt: "first instruction",
      system_prompt: "be a worker",
      session_name: "W1 session"
    )

    assert_equal "fake-interactive", ref.fetch("harness")
    assert ref.fetch("pid").positive?, "expected a live process id"
    assert_equal cwd, ref.fetch("cwd")
    assert_equal "interactive_pty", ref.dig("metadata", "transport")
    assert_includes client.prepared_workspaces, cwd

    settled = wait_until_settled(client, ref)
    assert_equal "answered: first instruction", client.last_assistant_text(settled)
    assert_equal ref.fetch("pid"), settled.fetch("pid"), "the session must not be replaced to answer"
  end

  def test_further_prompts_reuse_the_same_process
    client = build_interactive_client
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "one", system_prompt: "", session_name: "W1")
    settled = wait_until_settled(client, ref)
    original_pid = settled.fetch("pid")

    prompted = client.prompt_session(settled, "two", mode: "normal")
    assert_equal original_pid, prompted.fetch("pid")

    settled = wait_until_settled(client, prompted)
    assert_equal "answered: two", client.last_assistant_text(settled)
    assert_equal original_pid, settled.fetch("pid")
  end

  def test_a_prompt_keeps_its_newlines_instead_of_submitting_each_line
    client = build_interactive_client
    ref = client.spawn_session(
      kind: "worker",
      cwd: interactive_workspace,
      prompt: "line one\nline two\nline three",
      system_prompt: "",
      session_name: "W1"
    )

    settled = wait_until_settled(client, ref)
    text = client.last_assistant_text(settled)
    assert_includes text, "line one"
    assert_includes text, "line three"
    view = client.open_session_view(settled).snapshot
    prompts = view.fetch("items").select { |item| item["role"] == "user" }
    assert_equal 1, prompts.length, "a multi-line prompt must arrive as one submission"
  end

  def test_state_stays_streaming_until_the_prompt_reaches_the_transcript
    client = build_interactive_client(agent_flags: ["--turn-delay", "1.0"])
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "slow work", system_prompt: "", session_name: "W1")

    assert ref.fetch("is_streaming"), "a session with an undelivered prompt is not idle"
    # The previous turn's answer must never be reported as this turn's result.
    assert_nil client.last_assistant_text(ref)

    settled = wait_until_settled(client, ref)
    refute settled.fetch("is_streaming")
    assert_equal "answered: slow work", client.last_assistant_text(settled)
  end

  def test_the_session_view_streams_events_without_taking_them_from_reconciliation
    client = build_interactive_client(agent_flags: ["--tool-turn"])
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "do work", system_prompt: "", session_name: "W1")
    view = client.open_session_view(ref)
    settled = wait_until_settled(client, ref)

    # Both readers see the whole turn: the pane's cursor and reconciliation's cursor are separate,
    # so neither can consume the other's records.
    polled = view.poll_events
    assert_operator Array(polled.fetch("events")).length, :>=, 2, polled.inspect

    reconciled = []
    5.times { reconciled.concat(client.read_events(settled)) }
    assert_operator reconciled.length, :>=, 0
    assert_equal "answered: do work", client.last_assistant_text(settled)

    snapshot = view.snapshot
    assert_equal "live", snapshot.fetch("availability")
    assert_operator Array(snapshot.fetch("items")).length, :>=, 3
  ensure
    view&.close
  end

  def test_focused_live_terminal_preserves_streaming_styled_output_and_cursor
    client = build_interactive_client(agent_flags: ["--styled-turn", "--turn-delay", "0.3"])
    ref = client.spawn_session(
      kind: "worker",
      cwd: interactive_workspace,
      prompt: "render this while streaming",
      system_prompt: "",
      session_name: "W1"
    )
    terminal = client.live_terminal(ref)

    streaming = wait_until(message: "styled streaming output never reached the focused screen") do
      snapshot = terminal.snapshot(rows: 18, columns: 64)
      snapshot if snapshot.fetch("lines").any? { |line| line.include?("working on") }
    end
    assert_equal [18, 64], [streaming.fetch("rows"), streaming.fetch("columns")]
    assert streaming.fetch("cursor").is_a?(Array)
    assert streaming.fetch("styled_lines").flatten(1).any? { |text, style| text.include?("working on") && style == "\e[1;33m" }

    settled = wait_until_settled(client, ref)
    final = terminal.snapshot(rows: 18, columns: 64)
    assert_equal "answered: render this while streaming", client.last_assistant_text(settled)
    assert final.fetch("lines").any? { |line| line.include?("done") }
    assert final.fetch("styled_lines").flatten(1).any? { |text, style| text == "done" && style == "\e[1;32m" }
    assert_operator final.fetch("revision"), :>=, streaming.fetch("revision")
  end

  def test_events_carry_the_conversation_and_derive_progress
    client = build_interactive_client(agent_flags: ["--tool-turn"])
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "do work", system_prompt: "", session_name: "W1")
    settled = wait_until_settled(client, ref)

    # Events are drained as they arrive, so collect across the run the way the kernel does.
    events = []
    5.times do
      events.concat(client.read_events(settled))
      sleep 0.05
    end
    view = client.open_session_view(settled).snapshot
    kinds = view.fetch("items").map { |item| item["kind"] }.tally
    assert_operator kinds.fetch("tool", 0), :>=, 1, "tool traffic must reach the session view"
    assert_operator kinds.fetch("message", 0), :>=, 2
  end

  def test_a_failed_turn_is_reported_as_a_failure_not_a_result
    client = build_interactive_client(agent_flags: ["--fail-turn"])
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "will fail", system_prompt: "", session_name: "W1")
    settled = wait_until_settled(client, ref)

    outcome = client.turn_outcome(settled)
    assert_equal "failed", outcome.fetch("state")
    assert_equal "network_failure", outcome.fetch("kind")
    assert_includes outcome.fetch("error_message"), "connection reset"
    assert_nil client.last_assistant_text(settled), "an errored turn has no answer to report"
  end

  def test_prompt_delivery_receipts_prove_a_prompt_landed
    client = build_interactive_client
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "one", system_prompt: "", session_name: "W1")
    settled = wait_until_settled(client, ref)

    prompted = client.prompt_session(settled, "two", mode: "normal", delivery_id: "cmd-42")
    settled = wait_until_settled(client, prompted)

    receipt = client.prompt_delivery_status(settled, delivery_id: "cmd-42", prompt: "two")
    assert_equal "delivered", receipt.fetch("status")
    assert receipt.fetch("process_alive")

    missing = client.prompt_delivery_status(settled, delivery_id: "cmd-never-sent", prompt: "x")
    assert_equal "pending", missing.fetch("status"), "an unseen prompt on a live process is pending, never delivered"
  end

  def test_aborting_settles_the_turn_without_killing_the_session
    client = build_interactive_client(agent_flags: ["--turn-delay", "5.0"])
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "long running", system_prompt: "", session_name: "W1")
    pid = ref.fetch("pid")
    assert ref.fetch("is_streaming")

    aborted = client.abort_session(ref)
    refute aborted.fetch("is_streaming")
    assert_equal pid, client.live_terminal(aborted).pid, "aborting a turn must not replace the session"
  end

  def test_killing_a_session_stops_its_process
    client = build_interactive_client
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "one", system_prompt: "", session_name: "W1")
    pid = ref.fetch("pid")

    killed = client.kill_session(ref)
    assert killed.dig("metadata", "killed")
    refute killed.fetch("is_streaming")
    wait_until(message: "process #{pid} was still alive after kill_session") do
      !process_alive?(pid)
    end
  end

  def test_a_session_with_no_process_reports_history_without_starting_one
    client = build_interactive_client
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "one", system_prompt: "", session_name: "W1")
    settled = wait_until_settled(client, ref)
    client.kill_session(settled)

    attached = client.attach_session(settled)
    assert_nil attached.fetch("pid"), "attaching must not start a second writer"
    assert_equal "transcript_history", attached.dig("metadata", "attach_mode")
    assert_equal "answered: one", client.last_assistant_text(attached)

    view = client.open_session_view(attached).snapshot
    assert_equal "history", view.fetch("availability")
    refute view.dig("capabilities", "prompt"), "history is not promptable"
  end

  def test_prompting_a_session_whose_process_is_gone_resumes_it
    client = build_interactive_client
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "one", system_prompt: "", session_name: "W1")
    settled = wait_until_settled(client, ref)
    original_pid = settled.fetch("pid")
    client.kill_session(settled)

    resumed = client.prompt_session(settled.merge("pid" => nil), "two", mode: "normal")
    refute_equal original_pid, resumed.fetch("pid"), "a dead session needs a new process"
    assert_equal settled.fetch("session_id"), resumed.fetch("session_id"), "the durable session must be the same one"

    settled = wait_until_settled(client, resumed)
    assert_equal "answered: two", client.last_assistant_text(settled)
  end

  def test_a_process_exit_without_an_answer_is_marked_as_gone_not_idle_history
    client = build_interactive_client(agent_flags: ["--exit-before-answer"])
    ref = client.spawn_session(kind: "worker", cwd: interactive_workspace, prompt: "crash during work", system_prompt: "", session_name: "W1")

    gone = wait_until do
      state = client.get_state(ref)
      state if state.dig("metadata", "process_gone")
    end

    assert_equal false, gone.fetch("is_streaming")
    assert_equal 42, gone.dig("metadata", "exit_status", "exit_code")
    assert_nil client.last_assistant_text(gone), "a dead turn without an answer must not expose history as a result"
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
