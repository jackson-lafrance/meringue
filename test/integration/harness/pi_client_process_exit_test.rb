# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# What a Pi session's own process exit is allowed to be discovered as.
#
# A Pi RPC session is one long-lived process, so its exit is terminal for that session's transport:
# every later RPC can only time out. The exit is also the only place the *reason* lives - the exit
# status, the stderr, and the `process_exit` event the client journalled on its way out - and that
# evidence used to be unreachable, because reading it required a live process.
class HarnessPiClientProcessExitTest < HarnessIntegrationTest
  PiClient = Meringue::Harness::PiClient

  # A session that accepted its prompt and then left, which is the incident's shape: the spawn round
  # trip succeeded, the worker looked like live work, and the process was already gone. The session
  # file is left mid-turn, so there is no completed assistant response to settle on either.
  def spawn_then_exit(session_id: "sess-1")
    session_file = pi_session_file(tmpdir, session_id: session_id, completed: false)
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "session_id" => session_id,
        "session_file" => session_file,
        "exit_after" => "prompt",
        "exit_code" => 3
      }
    )
    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: nil,
                               system_prompt: nil, session_name: "Fix login redirect")
    track_session(client, ref)
    assert_raises(PiClient::ProcessExitedError) { client.prompt_session(ref, "do the work") }
    wait_until { client.session_exit_evidence(ref)&.fetch("exit_status", nil) }
    [client, stub, ref]
  end

  # --- classification ----------------------------------------------------------------------------

  # The marker is the whole contract: it is what lets the kernel tell "this session's process is
  # gone" apart from "this session is momentarily unreachable" without matching on message text.
  def test_a_session_whose_process_is_gone_raises_an_error_marked_as_process_gone
    client, _stub, ref = spawn_then_exit

    error = assert_raises(PiClient::ProcessExitedError) { client.get_state(ref) }

    assert_match(/no live process and no completed assistant response/, error.message)
    assert Meringue::Harness.session_process_gone_error?(error),
           "the kernel must be able to recognise this without parsing the message"
  end

  def test_process_gone_is_not_confused_with_a_transient_session_failure
    refute Meringue::Harness.session_process_gone_error?(PiClient::SessionBusyError.new("busy")),
           "a busy session comes back; a dead process does not"
    refute Meringue::Harness.session_process_gone_error?(PiClient::RpcTimeoutError.new("timed out")),
           "a timeout is not proof that the process left"
    refute Meringue::Harness.session_process_gone_error?(StandardError.new("boom"))
    refute Meringue::Harness.session_process_gone_error?(nil)
    refute PiClient::ProcessExitedError.include?(Meringue::Harness::TransientSessionError),
           "a process that exited must never be retried as a transient failure"
  end

  # --- the evidence the exit leaves behind --------------------------------------------------------

  def test_the_journalled_process_exit_event_is_still_readable_after_the_process_is_gone
    client, _stub, ref = spawn_then_exit

    events = client.read_events(ref)

    exit_event = events.find { |event| event.fetch("type", nil) == "process_exit" }
    refute_nil exit_event, "the exit event is the only durable record of the exit"
    assert_equal ref.fetch("pid"), exit_event.fetch("pid")
    assert_equal 3, exit_event.fetch("status").fetch("exit_code")
  end

  def test_the_exit_status_is_reported_as_harness_neutral_evidence
    client, _stub, ref = spawn_then_exit

    evidence = client.session_exit_evidence(ref)

    assert_equal ref.fetch("pid"), evidence.fetch("pid")
    assert_equal 3, evidence.fetch("exit_status").fetch("exit_code")
    assert_equal false, evidence.fetch("exit_status").fetch("success")
    assert_nil evidence.fetch("exit_status").fetch("termsig")
  end

  # A different Meringue instance (or this one after a restart) never owned the process, so it can
  # only report what the state record already says. Nothing may be invented here.
  def test_a_session_this_client_never_owned_reports_no_exit_evidence
    client, = build_pi_client(tmpdir)
    dead_pid = spawn_idle_ruby_process
    reap_pid(dead_pid)
    ref = pi_session_ref(session_file: pi_session_file(tmpdir), pid: dead_pid, cwd: tmpdir)

    assert_nil client.session_exit_evidence(ref)
    assert_empty client.read_events(ref)
  end

  # Reading the leftovers must never resurrect the session as something promptable.
  def test_reading_the_exit_evidence_does_not_make_the_dead_session_look_live
    client, stub, ref = spawn_then_exit

    client.session_exit_evidence(ref)
    client.read_events(ref)

    assert_raises(PiClient::ProcessExitedError) { client.get_state(ref) }
    assert_equal 1, stub_commands_of_type(stub, "prompt").length,
                 "reading what a dead process left behind must not replay an RPC into it"
  end
end
