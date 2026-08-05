# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# A worker turn can die in a way no resume can repair: the model provider rejects the *saved
# transcript* it is asked to replay ("`thinking` or `redacted_thinking` blocks in the latest
# assistant message cannot be modified"). Resuming replays the same turn, so every attempt fails
# identically. That is what dead-ended a real worker: it errored, the kernel resumed its session,
# it errored again three seconds later with the identical 400, and the worker queued behind it with
# `if_predecessor_fails: "cancel"` could never start.
#
# The transcript belongs to the harness, so Meringue does not try to repair it. What Meringue owns
# is the workspace, so the recovery is a fresh session on the *same* worktree and branch.
class KernelWorkersUnreplayableSessionRecoveryTest < Minitest::Test
  include KernelWorkersSupport

  # Reports a turn outcome the way PiClient does for a transcript the provider refuses to replay.
  class TurnOutcomeHarnessClient < RecordingHarnessClient
    attr_accessor :outcome
    attr_reader :attaches

    def initialize(outcome: nil, **options)
      super(**options)
      @outcome = outcome
      @attaches = []
    end

    def turn_outcome(_session_ref)
      @outcome
    end

    def attach_session(session_ref)
      @attaches << session_ref.fetch("session_id", nil)
      session_ref
    end
  end

  # The session transport is gone (the Pi process died), which is the state that makes
  # reconciliation reach for a resume in the first place.
  class DeadTransportHarnessClient < TurnOutcomeHarnessClient
    def get_state(_session_ref)
      raise IOError, "session transport is gone"
    end
  end

  # A harness that cannot classify its own turns, so the kernel must recognise the same rejection
  # from the session events alone.
  class EventOnlyHarnessClient < RecordingHarnessClient
    undef_method :turn_outcome
  end

  PROVIDER_REJECTION = '400 {"type":"error","error":{"type":"invalid_request_error","message":' \
                       '"messages.1.content.44: `thinking` or `redacted_thinking` blocks in the latest ' \
                       'assistant message cannot be modified. These blocks must remain as they were in ' \
                       'the original response."},"request_id":"req_vrtx_011CdkGWzRwt7tYzvySe6hSA"}'

  UNREPLAYABLE_SESSION = {
    "state" => "failed",
    "kind" => "unreplayable_session",
    "reason" => "its saved session can no longer be replayed to the model, so resuming it fails the " \
                "same way every time (#{PROVIDER_REJECTION})",
    "recovery" => "fresh_session",
    "stop_reason" => "error",
    "error_message" => PROVIDER_REJECTION
  }.freeze

  def unreplayable_client(client_class: TurnOutcomeHarnessClient)
    client_class.new(provider: "pi", outcome: UNREPLAYABLE_SESSION).tap { |client| client.last_assistant_text = "" }
  end

  def build_worker(client)
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), title: "Force the right index").fetch("target_id")
    [engine, context, worker_id]
  end

  def successor_of(engine, worker_id)
    state(engine).fetch("agents").find { |record| record.fetch("replaces_agent_id", nil) == worker_id }
  end

  def worktree_dirs
    Dir.glob(File.join(workspace_root, "*", "*")).select { |path| File.directory?(path) }
  end

  # --- classification and reporting -------------------------------------------------------------

  def test_a_rejected_transcript_is_recorded_as_an_unreplayable_session_with_actionable_reporting
    engine, _context, worker_id = build_worker(unreplayable_client)
    branch = agent(engine, worker_id).fetch("workspace_branch")

    apply!(engine, "ReconcileSessions", {})

    dead = agent(engine, worker_id)
    metadata = dead.fetch("harness_metadata")

    assert_equal "unreplayable_session", metadata.dig("settle_failure", "kind")
    assert_equal "harness_turn_outcome", metadata.dig("settle_failure", "source")
    assert_includes metadata.fetch("status_reason"), "can no longer be replayed to the model"
    assert_includes metadata.fetch("status_reason"), branch
    assert_includes metadata.fetch("status_reason"), "continuing means a fresh session on the same workspace"
    assert_equal "restart_session_in_place", metadata.dig("session_recovery", "recommended_action")

    settle_log = worker_scoped_logs(engine, worker_id).find { |entry| entry.fetch("level") == "error" }
    refute_nil settle_log, "the user needs one visible line saying what happened"
    assert_includes settle_log.fetch("message"), "can no longer be replayed to the model"
    assert_includes settle_log.fetch("message"), branch
    refute settle_log.dig("details", "recoverable"), "this session is not resumable, so the record must not claim it is"
  end

  # --- the recovery itself ----------------------------------------------------------------------

  def test_the_work_continues_in_a_fresh_session_on_the_same_worktree_and_branch
    client = unreplayable_client
    engine, context, worker_id = build_worker(client)
    dead = agent(engine, worker_id)
    worktrees_before = worktree_dirs

    apply!(engine, "ReconcileSessions", {})

    successor = successor_of(engine, worker_id)
    refute_nil successor, "the worker must not be dead-ended by a session that cannot be resumed"
    assert_equal "working", successor.fetch("status")
    assert_equal dead.fetch("workspace_path"), successor.fetch("workspace_path")
    assert_equal dead.fetch("workspace_branch"), successor.fetch("workspace_branch")
    assert_equal context.fetch("issue_id"), successor.fetch("issue_id")
    assert_equal worktrees_before, worktree_dirs, "the recovery must reuse the worktree, not allocate a second one"
    assert Dir.exist?(dead.fetch("workspace_path")), "the work already committed there is the thing being preserved"

    assert_equal "killed", agent(engine, worker_id).fetch("status")
    assert_equal successor.fetch("id"), agent(engine, worker_id).fetch("replaced_by_agent_id")
    assert_includes client.killed_session_ids, dead.fetch("harness_session_id")

    spawn_call = client.spawns.last
    assert_equal dead.fetch("workspace_path"), spawn_call.fetch("cwd")
    assert_includes spawn_call.fetch("prompt"), "could no longer be replayed"
    assert_includes spawn_call.fetch("prompt"), dead.fetch("workspace_branch")
    assert_includes spawn_call.fetch("prompt"), "git status"
    assert_includes spawn_call.fetch("prompt"), "Do the work.", "the original assignment must survive the restart"

    recovery_log = worker_scoped_logs(engine, worker_id).find { |entry| entry.fetch("message").include?("took over") }
    refute_nil recovery_log, "the recovery must be visible, not silent"
    assert_includes recovery_log.fetch("message"), successor.fetch("id")
    assert_includes recovery_log.fetch("message"), dead.fetch("workspace_branch")
    assert_equal worker_id, successor.dig("harness_metadata", "session_recovery", "restarted_from_agent_id")
    assert_equal 1, successor.dig("harness_metadata", "session_recovery", "restart_chain_depth")
    assert_equal successor.fetch("id"), agent(engine, worker_id).dig("harness_metadata", "session_recovery", "restarted_by_agent_id")
  end

  # The classification cannot depend on one harness knowing how to label the failure: the same
  # provider rejection arriving as a session event must reach the same conclusion.
  def test_the_same_rejection_seen_only_in_session_events_is_also_unreplayable
    client = EventOnlyHarnessClient.new(provider: "pi")
    client.events = [
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "error", "errorMessage" => PROVIDER_REJECTION } },
      { "type" => "agent_settled" }
    ]
    client.last_assistant_text = ""
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})

    assert_equal "unreplayable_session", agent(engine, worker_id).dig("harness_metadata", "settle_failure", "kind")
    refute_nil successor_of(engine, worker_id), "event-sourced evidence must recover the work too"
  end

  def test_a_queued_dependent_follows_the_successor_instead_of_dead_ending_behind_a_poisoned_session
    engine, context, worker_id = build_worker(unreplayable_client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Prove the speedup.",
      after_agent_id: worker_id,
      if_predecessor_fails: "cancel"
    ).fetch("target_id")

    assert_equal "queued", agent(engine, dependent_id).fetch("status")

    apply!(engine, "ReconcileSessions", {})

    successor = successor_of(engine, worker_id)
    dependent = agent(engine, dependent_id)

    assert_equal "queued", dependent.fetch("status"), "a dependent must not be cancelled by a recoverable session failure"
    assert_equal successor.fetch("id"), dependent.fetch("after_agent_id")
    assert_equal worker_id, dependent.dig("harness_metadata", "deferred_spawn", "repointed_from_agent_id")
  end

  # --- never retry the poisoned session ---------------------------------------------------------

  def test_the_poisoned_session_is_never_resumed_again
    client = unreplayable_client(client_class: DeadTransportHarnessClient)
    engine, _context, worker_id = build_worker(client)
    # The first resume attempt is what discovers the failure; it is recorded here as already spent.
    patch_agent!(worker_id) do |record|
      record["status"] = "errored"
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "settle_failure" => stringify(UNREPLAYABLE_SESSION).merge("source" => "harness_turn_outcome"),
        "session_recovery" => {
          "state" => "session_unreplayable",
          "restart_attempts" => 1,
          "restart_chain_depth" => 0
        }
      )
    end

    apply!(engine, "ReconcileSessions", {})

    assert_empty client.attaches, "resuming a session the provider already refused only reproduces the same 400"
    assert_nil successor_of(engine, worker_id), "the restart was already spent, so nothing may spawn a second one"
    assert_equal "errored", agent(engine, worker_id).fetch("status")
  end

  def test_only_one_automatic_restart_is_spent_per_worker
    engine, _context, worker_id = build_worker(unreplayable_client)

    apply!(engine, "ReconcileSessions", {})
    successor = successor_of(engine, worker_id)
    refute_nil successor

    recovery = agent(engine, worker_id).dig("harness_metadata", "session_recovery")
    assert_equal 1, recovery.fetch("restart_attempts")
    assert_equal successor.fetch("id"), recovery.fetch("restarted_by_agent_id")

    # A second settle observation of the same dead worker must not spawn another worker.
    engine.mark_worker_settle_failed(agent_id: worker_id, settle_failure: stringify(UNREPLAYABLE_SESSION))

    successors = state(engine).fetch("agents").select { |record| record.fetch("replaces_agent_id", nil) == worker_id }
    assert_equal 1, successors.length
  end

  def test_a_restart_chain_that_reached_its_limit_stops_recovering_and_says_so
    engine, context, worker_id = build_worker(unreplayable_client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Prove the speedup.",
      after_agent_id: worker_id,
      if_predecessor_fails: "cancel"
    ).fetch("target_id")
    patch_agent!(worker_id) do |record|
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "session_recovery" => { "restart_chain_depth" => Meringue::Kernel::Engine::WORKER_SESSION_RESTART_MAX_CHAIN_DEPTH }
      )
    end

    apply!(engine, "ReconcileSessions", {})

    assert_nil successor_of(engine, worker_id), "an endless chain of restarts is not a recovery"
    assert_equal "errored", agent(engine, worker_id).fetch("status")
    # The dependent is resolved rather than left waiting on a worker that can never continue.
    assert_nil agent(engine, dependent_id), "a cancelled queued worker is removed, not left waiting forever"
    assert_includes log_messages(engine).join("\n"), "Cancelled queued worker #{dependent_id}"

    prompted = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "keep going" })

    assert_equal "rejected", prompted.fetch("status")
    assert_includes prompted.fetch("errors"), "session_unreplayable"
    assert_includes prompted.fetch("message"), "can no longer be replayed to the model"
    assert_includes prompted.fetch("message"), "automatic restart"
  end

  # --- prompting an unreplayable worker ---------------------------------------------------------

  def test_prompting_an_unreplayable_worker_continues_it_in_a_fresh_session_with_the_instruction
    client = unreplayable_client
    engine, _context, worker_id = build_worker(client)
    # Recorded by a settle in another Meringue instance: the record is unreplayable but nothing has
    # restarted it yet, which is exactly the state a user meets when they type `/prompt`.
    patch_agent!(worker_id) do |record|
      record["status"] = "errored"
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "settle_failure" => stringify(UNREPLAYABLE_SESSION).merge("source" => "harness_turn_outcome")
      )
    end

    result = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Rebase on main first." })
    successor = successor_of(engine, worker_id)

    refute_nil successor
    assert_equal successor.fetch("id"), result.fetch("target_id")
    assert_equal agent(engine, worker_id).fetch("workspace_path"), successor.fetch("workspace_path")
    assert_includes client.spawns.last.fetch("prompt"), "Rebase on main first."
    assert_includes client.spawns.last.fetch("prompt"), "Do the work."
    assert_empty client.prompts, "the poisoned session must never be prompted"
  end

  def test_prompting_a_worker_whose_work_was_taken_over_names_the_successor
    engine, _context, worker_id = build_worker(unreplayable_client)
    apply!(engine, "ReconcileSessions", {})
    successor = successor_of(engine, worker_id)

    rejected = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "continue" })

    assert_equal "rejected", rejected.fetch("status")
    assert_includes rejected.fetch("message"), successor.fetch("id")
    assert_includes rejected.fetch("message"), "took over its workspace"
  end

  # --- the shared worktree survives -------------------------------------------------------------

  def test_pruning_the_replaced_worker_keeps_the_shared_worktree_and_stays_quiet
    client = unreplayable_client
    engine, _context, worker_id = build_worker(client)
    apply!(engine, "ReconcileSessions", {})
    successor = successor_of(engine, worker_id)
    workspace_path = successor.fetch("workspace_path")
    # The fresh session is mid-turn from here on, so later passes only prune.
    client.streaming = true

    # The pass that prunes killed records: the predecessor's record goes, its worktree does not.
    apply!(engine, "ReconcileSessions", {})
    apply!(engine, "ReconcileSessions", {})

    assert_nil agent(engine, worker_id), "the replaced record is pruned like any other killed worker"
    assert Dir.exist?(workspace_path), "the successor is still working in this worktree"
    assert_equal "working", agent(engine, successor.fetch("id")).fetch("status")
    assert_empty logs_matching(engine, /managed worktree could not be removed/),
                 "a handover must not warn once per reconcile pass about a worktree it no longer owns"
  end
end
