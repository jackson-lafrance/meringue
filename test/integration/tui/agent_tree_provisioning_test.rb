# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# A worker with no session yet has no output and no PR, so without a marker the AgentTree cannot
# distinguish "checking out a half-million files", "about to be retried", and "gave up and is
# waiting for you". Each of those reads differently on the row.
class TuiAgentTreeProvisioningTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane

  def setup
    @pane = Pane.new
  end

  def test_a_worker_being_provisioned_says_so
    rendered = render_worker(
      "status" => "queued",
      "harness_metadata" => { "title" => "Force the right index", "provisioning_state" => "allocating_workspace" }
    )

    assert_includes rendered, "provisioning workspace"
  end

  def test_provisioning_progress_shows_how_far_the_checkout_got
    rendered = render_worker(
      "status" => "queued",
      "harness_metadata" => {
        "title" => "Force the right index",
        "provisioning_state" => "allocating_workspace",
        "provisioning_progress" => { "detail" => "Updating files:  35% (167508/478592)", "elapsed_seconds" => 63.2 }
      }
    )

    assert_includes rendered, "provisioning workspace 35%"
  end

  def test_structured_checkout_progress_is_rendered_without_reparsing_git_output
    rendered = render_worker(
      "status" => "queued",
      "harness_metadata" => {
        "title" => "Force the right index",
        "provisioning_state" => "allocating_workspace",
        "provisioning_progress" => { "phase" => "checkout", "percent" => 42, "detail" => "unstructured output" }
      }
    )

    assert_includes rendered, "provisioning workspace 42%"
    refute_includes rendered, "unstructured output"
  end

  def test_checkout_progress_without_a_percentage_shows_phase_and_elapsed_time
    rendered = render_worker(
      "status" => "queued",
      "harness_metadata" => {
        "title" => "Force the right index",
        "provisioning_state" => "allocating_workspace",
        "provisioning_progress" => { "phase" => "checkout", "elapsed_seconds" => 17.4 }
      }
    )

    assert_includes rendered, "provisioning workspace checkout 17s"
  end

  def test_a_pending_retry_shows_which_attempt_is_next
    rendered = render_worker(
      "status" => "queued",
      "harness_metadata" => {
        "title" => "Force the right index",
        "provisioning_state" => "retry_pending",
        "provisioning_attempts" => 1,
        "provisioning_attempt_limit" => 2
      }
    )

    assert_includes rendered, "workspace retry 2/2"
  end

  def test_an_exhausted_worker_says_what_the_user_can_do
    rendered = render_worker(
      "status" => "blocked",
      "harness_metadata" => {
        "title" => "Force the right index",
        "provisioning_state" => "retry_exhausted",
        "provisioning_attempts" => 2,
        "provisioning_attempt_limit" => 2
      }
    )

    assert_includes rendered, "workspace failed: prompt to retry"
    assert_includes rendered, "!", "a worker waiting for the user renders as blocked"
  end

  def test_a_provisioned_worker_carries_no_marker
    rendered = render_worker(
      "status" => "working",
      "harness_metadata" => { "title" => "Force the right index", "provisioning_state" => "ready" }
    )

    refute_includes rendered, "workspace"
    refute_includes rendered, "provisioning"
  end

  def test_cached_rows_refresh_for_every_provisioning_and_settlement_marker_field
    state = worker_state(
      "status" => "queued",
      "harness_metadata" => { "title" => "Cached worker", "provisioning_state" => "ready" }
    )
    @pane.lines(state, width: 120)
    metadata = state.fetch("agents").first.fetch("harness_metadata")

    metadata["provisioning_state"] = "allocating_workspace"
    assert_includes render_state(state), "provisioning workspace"
    metadata["provisioning_progress"] = { "percent" => 37 }
    assert_includes render_state(state), "provisioning workspace 37%"
    # Mutate the exact nested object captured by the prior key. A shallow key aliases
    # this hash and incorrectly reuses the 37% row because both keys then read 38.
    metadata.fetch("provisioning_progress")["percent"] = 38
    refreshed = render_state(state)
    assert_includes refreshed, "provisioning workspace 38%"
    refute_includes refreshed, "provisioning workspace 37%"
    metadata["provisioning_state"] = "retry_pending"
    metadata["provisioning_attempts"] = 1
    metadata["provisioning_attempt_limit"] = 3
    assert_includes render_state(state), "workspace retry 2/3"
    metadata.delete("provisioning_state")
    metadata["settle_failure"] = { "kind" => "network_failure" }
    assert_includes render_state(state), "stopped: connection lost"
    metadata.delete("settle_failure")
    metadata["completion_continuation"] = {
      "state" => "waiting",
      "command_gate" => { "state" => "pending", "armed_at" => "2026-01-01T00:00:00Z", "label" => "CI" }
    }
    assert_includes render_state(state), "routing after CI"
    metadata.dig("completion_continuation", "command_gate")["label"] = "checks"
    refreshed = render_state(state)
    assert_includes refreshed, "routing after checks"
    refute_includes refreshed, "routing after CI"
    metadata.delete("completion_continuation")
    metadata["deferred_spawn"] = { "state" => "waiting", "after_agent_id" => "P1-I1-W0" }
    assert_includes render_state(state), "waiting on W0"
    metadata.delete("deferred_spawn")
    metadata["title"] = "Retitled after reconciliation"
    assert_includes render_state(state), "Retitled after reconciliation"
    state.fetch("agents").first["replaced_by_agent_id"] = "P1-I1-W2"
    assert_includes render_state(state), "replaced by W2"
  end

  private

  def worker_state(overrides)
    tree_state(
      projects: [project_record("P1", "name" => "World")],
      issues: [issue_record("P1-I1", "title" => "Slow query", "agent_ids" => ["P1-I1-W1"])],
      agents: [agent_record("P1-I1-W1", { "project_id" => "P1", "issue_id" => "P1-I1" }.merge(overrides))]
    )
  end

  def render_state(state)
    plain_lines(@pane.lines(state, width: 120)).join("\n")
  end

  def render_worker(overrides)
    render_state(worker_state(overrides))
  end
end
