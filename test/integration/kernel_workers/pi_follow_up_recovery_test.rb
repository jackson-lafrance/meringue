# frozen_string_literal: true

require "test_helper"
require "support/harness_support"
require "support/kernel_workers_support"

# Reconciliation now correctly refuses to call an interrupted Pi turn completed when the saved
# transcript ends with a newer user message. The worker remains recoverable, but a follow-up routed
# to that worker must be able to reattach the saved session: Pi has no live turn to queue behind, so
# it delivers the follow-up as a normal continuation.
class KernelWorkersPiFollowUpRecoveryTest < Minitest::Test
  include KernelWorkersSupport
  include HarnessSupport

  PiClient = Meringue::Harness::PiClient

  def setup
    super
    harness_setup
    @kernel_workers_tmpdir = Dir.mktmpdir("meringue-pi-follow-up-recovery")

    @session_file = pi_session_file(
      tmpdir,
      session_id: "sess-follow-up",
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
    stub = write_pi_stub(
      tmpdir,
      "session_id" => "sess-follow-up",
      "session_file" => @session_file,
      "is_streaming" => false
    )
    @harness_client = PiClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 10,
      event_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: build_transport_ownership(tmpdir)
    )
  end

  def teardown
    harness_teardown
    FileUtils.remove_entry(@kernel_workers_tmpdir) if @kernel_workers_tmpdir && Dir.exist?(@kernel_workers_tmpdir)
    super
  end

  # Keep both support modules in one test without letting HarnessSupport allocate its own unrelated
  # temp directory for the state, project, session, and worktree fixtures.
  def tmpdir
    @kernel_workers_tmpdir
  end

  def test_reconciliation_keeps_an_interrupted_follow_up_promptable
    engine = build_engine(harness_client: @harness_client)
    context = project_with_issue(engine, title: "Resume the interrupted Pi follow-up")
    worker_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Do the initial work.").fetch("target_id")
    worker_before_exit = agent(engine, worker_id)

    # The process dies after Pi accepted a follow-up, before that follow-up produced an assistant
    # message. The fixture's newer user record is the exact state that PR #207 made visible to
    # reconciliation instead of mistaking the prior assistant result for completion.
    @harness_client.kill_session(
      "harness" => "pi",
      "pid" => worker_before_exit.fetch("pid"),
      "cwd" => worker_before_exit.dig("harness_metadata", "cwd"),
      "session_id" => worker_before_exit.fetch("harness_session_id"),
      "session_file" => worker_before_exit.fetch("harness_session_file"),
      "metadata" => worker_before_exit.fetch("harness_metadata")
    )

    reconcile = apply!(engine, "ReconcileSessions", {})
    assert_equal "settle_failed", reconcile.dig("result", "poll_results").first.fetch("state")
    assert_equal "errored", agent(engine, worker_id).fetch("status")

    follow_up = apply!(
      engine,
      "PromptAgent",
      {
        "agent_id" => worker_id,
        "prompt" => "Continue from the interrupted follow-up.",
        "mode" => "follow_up"
      }
    )

    assert_equal "accepted", follow_up.fetch("status")
    resumed = agent(engine, worker_id)
    assert_equal "working", resumed.fetch("status")
    assert_equal "follow_up", resumed.dig("harness_metadata", "requested_prompt_mode")
    assert_equal "normal", resumed.dig("harness_metadata", "delivered_prompt_mode")
    assert_match(
      /resumed and this follow-up was delivered as a normal continuation/,
      resumed.dig("harness_metadata", "prompt_mode_note")
    )
  end
end
