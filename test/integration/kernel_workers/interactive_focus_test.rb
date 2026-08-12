# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

class KernelWorkersInteractiveFocusTest < Minitest::Test
  include KernelWorkersSupport

  class InteractiveHarnessClient < RecordingHarnessClient
    attr_reader :prepared, :resumed, :reclaimed
    attr_accessor :replacement_session

    def initialize
      super(provider: "pi")
      @prepared = []
      @resumed = []
      @reclaimed = []
    end

    def interactive_session_supported?
      true
    end

    def prepare_interactive_session(session_ref)
      @prepared << session_ref.dup
      ref = session_ref.merge("pid" => nil, "is_streaming" => false)
      ref = ref.merge(@replacement_session) if @replacement_session
      {
        "session_ref" => ref,
        "interactive_argv" => ["pi", "--session", ref.fetch("session_file")],
        "handoff" => {
          "mode" => "native_interactive",
          "exact_stream_transfer" => false,
          "captured_event_count" => 3
        }
      }
    end

    def reclaim_interactive_session(_session_ref, pid:)
      @reclaimed << pid
      true
    end

    def resume_dashboard_session(session_ref)
      @resumed << session_ref.dup
      session_ref.merge("pid" => 49_999, "is_streaming" => false)
    end
  end

  def test_focus_quiesces_the_managed_session_and_reconciliation_stands_down
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    prepared = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "accepted", prepared.fetch("status")
    assert_equal ["pi", "--session", agent(engine, worker_id).fetch("harness_session_file")], prepared.dig("result", "interactive_argv")
    assert_equal "interactive_pending", agent(engine, worker_id).dig("harness_metadata", "interactive_handoff", "state")
    assert_equal 1, client.prepared.length

    # A background tick cannot read or settle the same JSONL while the native PTY owns it.
    before = agent(engine, worker_id).fetch("updated_at")
    engine.reconcile_sessions
    assert_equal before, agent(engine, worker_id).fetch("updated_at")

    started = engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    assert_equal "accepted", started.fetch("status")
    assert_equal "interactive", agent(engine, worker_id).dig("harness_metadata", "interactive_handoff", "state")

    blocked = engine.apply(
      "type" => "PromptAgent",
      "payload" => { "agent_id" => worker_id, "prompt" => "Do not create a second writer." }
    )
    assert_equal "rejected", blocked.fetch("status")
    assert_equal "interactive_focus_active", blocked.fetch("errors").first

    resumed = engine.end_agent_interactive_focus(worker_id)
    assert_equal "accepted", resumed.fetch("status")
    assert_equal 1, client.resumed.length
    refute agent(engine, worker_id).fetch("harness_metadata").key?("interactive_handoff")
    assert_equal 49_999, agent(engine, worker_id).fetch("pid")

    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["interactive_handoff"] = {
        "state" => "interactive",
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => 999_998
      }
    end
    recovered = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "accepted", recovered.fetch("status")
  end

  def test_replacement_session_ref_is_used_for_both_native_focus_and_dashboard_return
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    replacement_file = tmp_path("replacement-session.jsonl")
    client.replacement_session = { "session_id" => "replacement-session", "session_file" => replacement_file }

    prepared = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", prepared.fetch("status")
    assert_equal "replacement-session", agent(engine, worker_id).fetch("harness_session_id")
    assert_equal replacement_file, agent(engine, worker_id).fetch("harness_session_file")
    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    engine.end_agent_interactive_focus(worker_id)
    assert_equal replacement_file, client.resumed.last.fetch("session_file")
  end

  def test_focus_reclaims_a_live_native_process_left_by_a_crashed_owner
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    orphan_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30")

    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["interactive_handoff"] = {
        "state" => "interactive",
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => orphan_pid
      }
    end

    result = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", result.fetch("status")
    assert_equal [orphan_pid], client.reclaimed
  ensure
    begin
      Process.kill("TERM", orphan_pid) if orphan_pid && Meringue::Harness::ProcessIdentity.alive?(orphan_pid)
      Process.wait(orphan_pid) if orphan_pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_unsupported_harness_is_rejected_without_mutating_worker_state
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    original = agent(engine, worker_id).fetch("harness_metadata").dup

    result = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "rejected", result.fetch("status")
    assert_equal "interactive_session_unsupported", result.fetch("errors").first
    assert_equal original, agent(engine, worker_id).fetch("harness_metadata")
  end
end
