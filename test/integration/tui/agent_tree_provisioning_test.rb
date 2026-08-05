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

  private

  def render_worker(overrides)
    state = tree_state(
      projects: [project_record("P1", "name" => "World")],
      issues: [issue_record("P1-I1", "title" => "Slow query", "agent_ids" => ["P1-I1-W1"])],
      agents: [agent_record("P1-I1-W1", { "project_id" => "P1", "issue_id" => "P1-I1" }.merge(overrides))]
    )
    plain_lines(@pane.lines(state, width: 120)).join("\n")
  end
end
