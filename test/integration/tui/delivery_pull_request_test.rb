# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiDeliveryPullRequestTest < Minitest::Test
  include TUISupport

  Delivery = Meringue::TUI::DeliveryPullRequest

  NOW = Time.utc(2026, 7, 11, 0, 10, 0)

  def test_issue_owned_pull_request_is_presented_for_the_issue_and_its_worker
    state = state_with_pull_request("state" => "open", "last_checked_at" => "2026-07-11T00:09:00Z")

    issue_presentation = Delivery.for_id(state, "P1-I1", now: NOW)
    worker_presentation = Delivery.for_id(state, "P1-I1-W1", now: NOW)

    assert_equal "9", issue_presentation.fetch("number")
    assert_equal "open", issue_presentation.fetch("state")
    assert_equal "open", Delivery.status_label(issue_presentation)
    assert Delivery.openable?(issue_presentation)
    refute issue_presentation.fetch("stale")
    assert_equal issue_presentation.fetch("url"), worker_presentation.fetch("url")
  end

  def test_missing_records_are_reported_as_not_openable
    presentation = Delivery.for_id(state_with_pull_request("state" => "open"), "H9", now: NOW)

    assert_equal "missing", presentation.fetch("state")
    refute Delivery.openable?(presentation)
    assert_equal "unavailable", Delivery.status_label(presentation)
    assert_equal "not tracked", Delivery.status_label(nil)
    assert_includes presentation.fetch("message"), "No verified delivery pull request"
  end

  def test_stale_metadata_is_flagged_but_still_openable
    presentation = Delivery.for_id(state_with_pull_request("state" => "open", "last_checked_at" => "2026-07-11T00:00:00Z"), "P1-I1", now: NOW)

    assert presentation.fetch("stale")
    assert_equal "open · check stale", Delivery.status_label(presentation)
    assert_includes presentation.fetch("message"), "forge status check is stale"
    assert Delivery.openable?(presentation)
  end

  def test_merged_lifecycle_is_separate_from_stale_check_freshness
    presentation = Delivery.for_id(
      state_with_pull_request("state" => "merged", "last_checked_at" => "2026-07-11T00:00:00Z"),
      "P1-I1",
      now: NOW
    )

    assert_equal "merged", presentation.fetch("state")
    assert presentation.fetch("stale")
    assert_equal "merged · check stale", Delivery.status_label(presentation)
    refute_equal "merged · stale", Delivery.status_label(presentation)
    assert_includes presentation.fetch("message"), "merged"
    assert_includes presentation.fetch("message"), "forge status check is stale"
  end

  def test_unavailable_refresh_keeps_the_link_actionable
    presentation = Delivery.for_id(
      state_with_pull_request("state" => "open", "availability" => "unavailable", "last_checked_at" => "2026-07-11T00:09:00Z"),
      "P1-I1",
      now: NOW
    )

    refute presentation.fetch("metadata_available")
    assert presentation.fetch("stale")
    assert_equal "status unavailable", Delivery.status_label(presentation)
    assert Delivery.openable?(presentation)
    assert_includes presentation.fetch("message"), "temporarily unavailable"
  end

  def test_unsupported_urls_are_invalid
    presentation = Delivery.for_id(state_with_pull_request("url" => "https://example.com/not-a-pr"), "P1-I1", now: NOW)

    assert_equal "invalid", presentation.fetch("state")
    refute Delivery.openable?(presentation)
    assert_includes presentation.fetch("message"), "does not contain a supported GitHub PR URL"
  end

  def test_unknown_states_are_normalized
    presentation = Delivery.for_id(state_with_pull_request("state" => "draft", "last_checked_at" => "2026-07-11T00:09:00Z"), "P1-I1", now: NOW)

    assert_equal "unknown", presentation.fetch("state")
    assert_includes presentation.fetch("message"), "has not been verified recently"

    merged = Delivery.for_id(state_with_pull_request("state" => "merged", "last_checked_at" => "2026-07-11T00:09:00Z"), "P1-I1", now: NOW)
    assert_equal "merged", merged.fetch("state")
  end

  def test_records_without_a_check_time_are_stale
    assert Delivery.stale_record?({}, now: NOW)
    assert Delivery.stale_record?({ "verified_at" => "garbage" }, now: NOW)
    refute Delivery.stale_record?({ "verified_at" => "2026-07-11T00:09:00Z" }, now: NOW)
  end

  def test_string_and_hash_pull_request_records_are_accepted
    assert_equal [{ "url" => "https://github.com/o/r/pull/5" }],
                 Delivery.pull_request_records({ "delivery_pull_requests" => ["https://github.com/o/r/pull/5"] })
    assert_empty Delivery.pull_request_records(nil)
    assert Delivery.valid_url?("https://github.com/o/r/pull/5")
    refute Delivery.valid_url?("https://github.com/o/r/pulls/5")
  end

  def test_agent_tree_and_logs_render_the_pr_marker_for_open_pull_requests
    state = composed_state(
      state_with_pull_request("state" => "open", "last_checked_at" => "2026-07-11T00:09:00Z").merge(
        "projects" => [project_record("P1")],
        "logs" => [
          log_record(
            "L1",
            "source_type" => "worker",
            "source_id" => "P1-I1-W1",
            "message" => "Worker P1-I1-W1 completed.",
            "details" => {
              "last_assistant_text" => "shipped it",
              "delivery_pull_requests" => [{ "url" => "https://github.com/o/r/pull/9" }]
            }
          )
        ]
      ),
      navigation: { "active" => true, "selected_agent_id" => "P1-I1-W1" }
    )
    frame = render_frame(state, width: 110, height: 30)

    assert_includes frame, "↗"
    assert_includes frame, "PR https://github.com/o/r/pull/9"
    # The hint line names the selected worker's PR and its status. Ctrl-B opens it
    # but is no longer spelled out on every frame.
    assert_includes frame, "PR #9"
    refute_includes frame, "Ctrl-B"
  end

  private

  def state_with_pull_request(pull_request_overrides)
    pull_request = { "url" => "https://github.com/o/r/pull/9" }.merge(pull_request_overrides)
    empty_state.merge(
      "issues" => [issue_record("P1-I1", "delivery_pull_requests" => [pull_request])],
      "agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    )
  end
end
