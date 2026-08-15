# frozen_string_literal: true

require "test_helper"
require "support/harness_support"
require "support/supervisor_support"

# End-to-end exercise of the persistent supervisor through the real Pi adapter:
# the supervisor registers a Pi session spawned by the stubbed Pi RPC process,
# detects a shared supervisor exit from the durable transport lease, recovers
# the session through `attach_session`, and hands a session off without killing
# an in-flight turn. This proves the harness-agnostic contract is wired through
# the actual Pi backend, not just the fake adapter.
class SupervisorPiAdapterIntegrationTest < HarnessIntegrationTest
  def setup
    super
    @dir = tmpdir
    @store_dir = File.join(@dir, "supervisor-state")
    client, stub = build_pi_client(@dir, stub_config: { "session_id" => "sess-1" })
    @client = client
    @stub = stub
    @adapter = Meringue::Supervisor::PiAdapter.new(client: client, transport_ownership: build_transport_ownership(@dir))
    @store = Meringue::Supervisor::StateStore.new(directory: @store_dir)
    @supervisor = Meringue::Supervisor::Service.new(
      adapter: @adapter,
      state_store: @store,
      owner_pid: Process.pid,
      settle_timeout: 5.0,
      handoff_timeout: 5.0
    )
  end

  def test_register_claims_the_durable_pi_transport_lease_through_the_adapter
    ref = spawn_managed_session(session_id: "sess-1")

    record = @supervisor.register(ref, harness_pid: ref.fetch("pid"))

    assert_equal "active", record.fetch("state")
    lease = @adapter.record_for(ref)
    assert_equal ref.fetch("pid"), lease.fetch("pid")
    assert_equal "pi", record.fetch("harness")
  end

  def test_detect_loss_reports_supervision_lost_when_the_owner_and_child_both_exit
    owner_pid = spawn_idle_ruby_process
    harness_pid = spawn_idle_ruby_process
    ownership = Meringue::Harness::TransportOwnership.new(
      directory: File.join(@dir, "transport-locks"),
      owner_pid: owner_pid
    )
    ownership.claim("pi-sess-1", pid: harness_pid, session_id: "sess-1")
    session_file = pi_session_file(@dir, session_id: "sess-1", completed: false)
    ref = pi_session_ref(session_file: session_file, pid: harness_pid, cwd: @dir)
    adapter = Meringue::Supervisor::PiAdapter.new(client: @client, transport_ownership: ownership)
    supervisor = Meringue::Supervisor::Service.new(
      adapter: adapter,
      state_store: @store,
      owner_pid: Process.pid
    )
    supervisor.register(ref, harness_pid: harness_pid)

    reap_pid(harness_pid)
    reap_pid(owner_pid)
    harness_pid = nil
    owner_pid = nil

    evidence = supervisor.detect_loss(ref)

    assert evidence.fetch("supervisor_exited")
    assert_equal "supervision_lost", evidence.fetch("supervision_state")
    assert_equal "supervision_lost", supervisor.supervision_state(ref)
  ensure
    reap_pid(harness_pid) if harness_pid
    reap_pid(owner_pid) if owner_pid
  end

  def test_adopt_recovers_a_settled_pi_session_and_prompts_exactly_once
    session_file = pi_session_file(@dir, session_id: "sess-1", completed: true)
    ref = pi_session_ref(session_file: session_file, pid: nil, cwd: @dir)
    @adapter.claim(ref, harness_pid: 60_000, note: "previous-owner")
    @store.save(@store.blank_record(@adapter.transport_key(ref)).merge(
                  "state" => "supervision_lost",
                  "lost_at" => Time.now.utc.iso8601(6),
                  "harness_pid" => 60_000
                ))

    result = @supervisor.adopt(ref, prompt: "Continue the assigned work.")

    assert_equal "recovered", result.fetch("supervision").fetch("state")
    assert result.fetch("prompted"), "a settled session must receive the continuation prompt once"
    prompt_commands = stub_commands_of_type(@stub, "prompt")
    assert_equal 1, prompt_commands.length, "the continuation prompt must be delivered exactly once"
  end

  def test_prepare_handoff_releases_the_transport_lease_without_leaving_a_second_writer
    ref = spawn_managed_session(session_id: "sess-1")
    @supervisor.register(ref, harness_pid: ref.fetch("pid"))

    released = @supervisor.prepare_handoff(ref)

    refute released.fetch("is_streaming")
    record = @store.read(@adapter.transport_key(ref))
    assert_equal "relinquished", record.fetch("handoff_state")
    assert_nil record.fetch("owner_pid")
  end

  private

  def spawn_managed_session(session_id:)
    ref = @client.spawn_session(
      kind: "worker",
      cwd: @dir,
      prompt: nil,
      system_prompt: nil,
      session_name: "supervised worker",
      workspace_mode: "isolated"
    )
    @harness_sessions << [@client, ref]
    ref
  end
end
