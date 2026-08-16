# frozen_string_literal: true

require "test_helper"
require "support/supervisor_support"

# Regression coverage for the persistent, harness-agnostic supervisor that
# decouples harness transport ownership from the interactive dashboard process.
#
# These tests drive `Meringue::Supervisor::Service` through a hermetic
# `FakeTransportAdapter` (no real Pi/Claude/Codex process is spawned, nothing
# leaves Dir.mktmpdir) so they exercise the durable ownership, handoff,
# supervision_lost lifecycle, downtime accounting, and no-duplicate-prompt
# recovery contract directly and fast.
class SupervisorServiceTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("meringue-supervisor")
    @now = Time.utc(2026, 1, 1, 12, 0, 0)
    @clock = lambda { @now }
    @adapter = Meringue::Supervisor::FakeTransportAdapter.new(now: @now)
    @store = Meringue::Supervisor::StateStore.new(directory: File.join(@dir, "state"))
    @supervisor = build_supervisor(@adapter, @store)
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def build_supervisor(adapter = @adapter, store = @store, owner_pid: 11_000)
    Meringue::Supervisor::Service.new(
      adapter: adapter,
      state_store: store,
      owner_pid: owner_pid,
      owner_started_at: "2026-01-01T11:00:00Z",
      settle_timeout: 1.0,
      handoff_timeout: 1.0,
      clock: @clock
    )
  end

  def session_ref(session_id: "sess-1", pid: 50_000)
    {
      "harness" => "pi",
      "pid" => pid,
      "cwd" => @dir,
      "session_id" => session_id,
      "session_file" => nil,
      "is_streaming" => false,
      "last_event_at" => nil
    }
  end

  def stub_evidence(session_ref, owner_alive:, harness_alive:, owner_pid: 11_000, harness_pid: 50_000)
    @adapter.set_evidence(
      session_ref,
      "source" => "transport_ownership",
      "transport_key" => @adapter.transport_key(session_ref),
      "owner_pid" => owner_pid,
      "owner_started_at" => "2026-01-01T11:00:00Z",
      "owner_alive" => owner_alive,
      "harness_pid" => harness_pid,
      "harness_alive" => harness_alive,
      "supervisor_exited" => !owner_alive && !harness_alive,
      "observed_at" => "2026-01-01T12:00:00Z"
    )
  end

  # --- durable ownership ----------------------------------------------------

  def test_register_claims_durable_ownership_and_records_active_supervision
    ref = session_ref
    @adapter.seed_session(ref)

    record = @supervisor.register(ref, harness_pid: 50_000, note: "spawned")

    assert_equal "active", record.fetch("state")
    assert_equal 11_000, record.fetch("owner_pid")
    assert_equal 50_000, record.fetch("harness_pid")
    assert_equal 1, @adapter.claims.length
    assert_equal "pi-sess-1", @adapter.claims.first.fetch("key")
    assert_equal "supervision_lost", Meringue::State::Models::LIFECYCLE_STATUSES.last
  end

  def test_the_durable_record_survives_a_dashboard_process_exit_and_restart
    ref = session_ref
    @adapter.seed_session(ref)
    first = build_supervisor(@adapter, @store, owner_pid: 11_000)
    first.register(ref, harness_pid: 50_000, note: "spawned")

    # The dashboard process exits. A fresh supervisor loads the same durable
    # state store and sees the previously registered session.
    restarted = build_supervisor(@adapter, @store, owner_pid: 11_001)

    assert_equal "active", restarted.supervision_state(ref),
                 "the durable ownership record must survive a dashboard exit/restart"
    assert_equal 11_000, restarted.state_store.read(@adapter.transport_key(ref)).fetch("owner_pid")
  end

  # --- supervision_lost lifecycle -------------------------------------------

  def test_detect_loss_transitions_active_to_supervision_lost_with_a_timestamp
    ref = session_ref
    @adapter.seed_session(ref)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)

    evidence = @supervisor.detect_loss(ref)

    assert evidence.fetch("supervisor_exited")
    assert_equal "supervision_lost", evidence.fetch("supervision_state")
    record = @store.read(@adapter.transport_key(ref))
    assert_equal "supervision_lost", record.fetch("state")
    refute_nil record.fetch("lost_at")
    assert record.fetch("lost_at").to_s.start_with?("2026-01-01T12:00:00"),
           "lost_at must record when supervision was lost: #{record.fetch('lost_at')}"
  end

  def test_detect_loss_is_idempotent_and_does_not_reset_the_lost_timestamp
    ref = session_ref
    @adapter.seed_session(ref)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)

    @supervisor.detect_loss(ref)
    first_lost_at = @store.read(@adapter.transport_key(ref)).fetch("lost_at")
    @now = @now + 30
    @supervisor.detect_loss(ref)
    second_lost_at = @store.read(@adapter.transport_key(ref)).fetch("lost_at")

    assert_equal first_lost_at, second_lost_at, "a repeated observation must not reset the lost timestamp"
  end

  def test_an_isolated_harness_crash_is_not_classified_as_supervision_lost
    ref = session_ref
    @adapter.seed_session(ref)
    @supervisor.register(ref, harness_pid: 50_000)
    # Owner alive, child gone: an isolated harness crash, not a shared supervisor exit.
    stub_evidence(ref, owner_alive: true, harness_alive: false)

    evidence = @supervisor.detect_loss(ref)

    refute evidence.fetch("supervisor_exited")
    assert_equal "active", @supervisor.supervision_state(ref),
                 "a lone harness crash must never become supervision_lost"
  end

  # --- downtime accounting --------------------------------------------------

  def test_downtime_accumulates_while_supervision_is_lost_and_freezes_on_recovery
    ref = session_ref
    @adapter.seed_session(ref, streaming: true)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)

    @supervisor.detect_loss(ref)
    @now = @now + 120 # two minutes of paused runtime
    elapsed = @supervisor.downtime(ref)
    assert_in_delta 120.0, elapsed, 1.0, "downtime must accumulate while supervision is lost"

    # Recovery: the original turn is still alive, so the session is adopted
    # without re-prompting. Downtime freezes at recovery.
    @adapter.set_streaming(ref, true)
    result = @supervisor.adopt(ref)
    @now = @now + 600
    assert_in_delta 120.0, @supervisor.downtime(ref), 1.0,
                    "downtime must freeze once the session is recovered"
    assert_equal "recovered", @supervisor.supervision_state(ref)
    refute result.fetch("prompted"), "a still-live turn must not be re-prompted on recovery"
  end

  # --- recovery without duplicate prompting ---------------------------------

  def test_recovery_preserves_a_live_turn_without_re_prompting
    ref = session_ref
    @adapter.seed_session(ref, streaming: true)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)
    @supervisor.detect_loss(ref)

    result = @supervisor.adopt(ref, prompt: "Continue the assigned work.")

    assert_equal 1, @adapter.attaches.length, "recovery must re-attach the transport exactly once"
    assert_empty @adapter.prompts, "a live turn must never be re-prompted during recovery"
    refute result.fetch("prompted")
    assert_equal "recovered", result.fetch("supervision").fetch("state")
    refute_nil result.fetch("recovery_id")
  end

  def test_recovery_prompts_only_a_settled_session_that_needs_to_continue
    ref = session_ref
    @adapter.seed_session(ref, streaming: false)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)
    @supervisor.detect_loss(ref)

    result = @supervisor.adopt(ref, prompt: "Continue the assigned work.")

    assert_equal 1, @adapter.attaches.length
    assert_equal 1, @adapter.prompts.length
    assert result.fetch("prompted"), "a settled session must receive the continuation prompt exactly once"
    assert_equal "Continue the assigned work.", @adapter.prompts.first.fetch("prompt")
  end

  def test_recovery_does_not_prompt_a_settled_session_when_no_continuation_is_supplied
    ref = session_ref
    @adapter.seed_session(ref, streaming: false)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)
    @supervisor.detect_loss(ref)

    result = @supervisor.adopt(ref)

    assert_equal 1, @adapter.attaches.length
    assert_empty @adapter.prompts, "no continuation prompt must be sent when none was requested"
    refute result.fetch("prompted")
  end

  def test_repeated_recovery_does_not_duplicate_prompts
    ref = session_ref
    @adapter.seed_session(ref, streaming: false)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)
    @supervisor.detect_loss(ref)

    @supervisor.adopt(ref, prompt: "Continue the assigned work.")
    @adapter.set_streaming(ref, true) # the first recovery started a live turn
    @supervisor.adopt(ref, prompt: "Continue the assigned work.")

    assert_equal 1, @adapter.prompts.length, "a second adoption while the turn is live must not re-prompt"
  end

  # --- graceful handoff -----------------------------------------------------

  def test_prepare_handoff_settles_an_in_flight_turn_and_releases_the_lease
    ref = session_ref
    @adapter.seed_session(ref, streaming: true)
    @supervisor.register(ref, harness_pid: 50_000)

    released = @supervisor.prepare_handoff(ref)

    assert_equal 1, @adapter.aborts.length, "an active turn must be aborted through the backend boundary"
    assert_equal 1, @adapter.wait_calls.length, "handoff must wait for the aborted turn to settle"
    refute @adapter.streaming?(released)
    assert_equal 1, @adapter.releases.length, "the transport lease must be released on handoff"
    record = @store.read(@adapter.transport_key(ref))
    assert_equal "relinquished", record.fetch("handoff_state")
    assert_nil record.fetch("owner_pid")
  end

  def test_prepare_handoff_does_not_abort_a_settled_session
    ref = session_ref
    @adapter.seed_session(ref, streaming: false)
    @supervisor.register(ref, harness_pid: 50_000)

    @supervisor.prepare_handoff(ref)

    assert_empty @adapter.aborts, "a settled session must not be aborted during handoff"
    assert_equal 1, @adapter.releases.length
  end

  # --- dashboard client attaches to the supervisor --------------------------

  def test_dashboard_client_does_not_claim_transport_directly
    ref = session_ref
    @adapter.seed_session(ref)
    @supervisor.register(ref, harness_pid: 50_000)
    client = Meringue::Supervisor::DashboardClient.new(supervisor: @supervisor, adapter: @adapter)

    client.spawn_session(ref, harness_pid: 50_000)

    # The dashboard client routes through the supervisor; ownership claims only
    # come from the supervisor's register/adopt path, never from the client.
    assert(@adapter.claims.all? { |claim| claim.fetch("note").to_s.start_with?("dashboard") || claim.fetch("note") == "supervisor" })
    assert_equal "active", client.supervision_state(ref)
  end

  def test_dashboard_client_recovers_a_lost_session_before_prompting
    ref = session_ref
    @adapter.seed_session(ref, streaming: true)
    @supervisor.register(ref, harness_pid: 50_000)
    stub_evidence(ref, owner_alive: false, harness_alive: false)
    @supervisor.detect_loss(ref)
    client = Meringue::Supervisor::DashboardClient.new(supervisor: @supervisor, adapter: @adapter)

    client.prompt(ref, "Follow up with the reviewed plan.", mode: "normal")

    assert_equal 1, @adapter.attaches.length, "the dashboard must recover the transport before prompting"
    # The user's follow-up is delivered exactly once. Recovery itself does not
    # add a prompt: the live turn is preserved, and only the user's message is
    # sent, so there is no duplicate of the original turn's continuation.
    assert_equal 1, @adapter.prompts.length
    assert_equal "Follow up with the reviewed plan.", @adapter.prompts.first.fetch("prompt")
    assert_equal "recovered", client.supervision_state(ref)
  end

  # --- kill cleanup ---------------------------------------------------------

  def test_kill_releases_the_transport_and_drops_the_supervision_record
    ref = session_ref
    @adapter.seed_session(ref)
    @supervisor.register(ref, harness_pid: 50_000)

    @supervisor.kill(ref)

    assert_equal 1, @adapter.kills.length
    assert_equal 1, @adapter.releases.length
    assert_nil @store.read(@adapter.transport_key(ref))
  end
end
