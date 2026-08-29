# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiAgentTreeNavigationTest < Minitest::Test
  include TUISupport

  Navigation = Meringue::TUI::AgentTreeNavigation

  def test_selectable_ids_follow_the_rendered_tree_order
    ids = Navigation.selectable_agent_ids(composed_state(tui_state))

    assert_equal %w[H1 H2 P1-I1 P1-I1-W1 P1-I1-W2 P1-I2 P1-I2-W1 P1-I3 P1-I3-W1 P2-I1 P2-I1-W1], ids
  end

  def test_selectable_ids_match_the_rendered_rows
    state = composed_state(tui_state)
    rendered_ids = Meringue::TUI::Panes::AgentTreePane.new.line_item_ids(state, width: 34).compact.uniq

    project_ids = state.fetch("projects").map { |project| project.fetch("id") }
    assert_equal rendered_ids.reject { |id| project_ids.include?(id) }, Navigation.selectable_agent_ids(state)
  end

  def test_killed_projects_and_issues_are_not_selectable
    state = tree_state(
      projects: [project_record("P1"), project_record("P2", "status" => "killed")],
      issues: [issue_record("P1-I1"), issue_record("P2-I1"), issue_record("P1-I2", "status" => "killed")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1"),
        agent_record("P1-I2-W1", "issue_id" => "P1-I2"),
        agent_record("P2-I1-W1", "issue_id" => "P2-I1")
      ]
    )

    assert_equal %w[P1-I1 P1-I1-W1], Navigation.selectable_agent_ids(state)
  end

  def test_only_agents_with_open_pull_requests_are_pr_selectable
    open_pr = { "url" => "https://github.com/owner/repo/pull/4", "state" => "open" }
    merged_pr = { "url" => "https://github.com/owner/repo/pull/5", "state" => "merged" }
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1"), issue_record("P1-I2", "delivery_pull_request" => merged_pr)],
      agents: [
        agent_record("H1", "delivery_pull_request" => open_pr),
        agent_record("H2"),
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "delivery_pull_request" => open_pr),
        agent_record("P1-I2-W1", "issue_id" => "P1-I2", "delivery_pull_request" => merged_pr)
      ]
    )

    assert_equal %w[H1 P1-I1], Navigation.selectable_pr_agent_ids(state)
    assert_empty Navigation.selectable_pr_agent_ids(composed_state(tui_state))
  end

  def test_sort_key_orders_numerically_and_falls_back_to_the_raw_id
    assert_equal [1, 10, 2], Navigation.sort_key("P1-I10-W2")
    assert_equal ["abc"], Navigation.sort_key("abc")
    assert_equal(-1, Navigation.sort_key("P1-I2") <=> Navigation.sort_key("P1-I10"))
  end

  def test_navigation_snapshot_accessors_default_to_inactive
    assert_nil Navigation.selected_agent_id(composed_state(tui_state))
    refute Navigation.active?(composed_state(tui_state))

    active = composed_state(tui_state, navigation: { "active" => true, "selected_agent_id" => "H1" })
    assert_equal "H1", Navigation.selected_agent_id(active)
    assert Navigation.active?(active)
  end

  def test_selected_agent_requires_a_selectable_record_and_a_matching_id
    head = { "id" => "H1", "type" => "head" }
    issue = { "id" => "P1-I1", "project_id" => "P1", "agent_ids" => [] }
    project = { "id" => "P1", "name" => "Meringue" }

    assert Navigation.selected_agent?(head, "H1")
    assert Navigation.selected_agent?(issue, "P1-I1")
    refute Navigation.selected_agent?(project, "P1")
    refute Navigation.selected_agent?(head, "H2")
    refute Navigation.selected_agent?(head, nil)
  end

  def test_reported_urls_are_never_treated_as_active_pull_requests
    record = { "harness_metadata" => { "reported_pr_urls" => ["https://github.com/owner/repo/pull/3"] } }

    assert_equal "https://github.com/owner/repo/pull/3", Navigation.agent_pr_url(record)
    assert_nil Navigation.active_agent_pr_url(record)
  end

  def test_active_pull_request_state_is_case_insensitive
    record = { "delivery_pull_request" => { "url" => "https://github.com/owner/repo/pull/3", "state" => "OPEN" } }

    assert_equal "https://github.com/owner/repo/pull/3", Navigation.active_agent_pr_url(record)
  end

  def test_only_github_pull_request_urls_are_recognized
    assert Navigation.pull_request_url?("https://github.com/owner/repo/pull/3")
    assert Navigation.pull_request_url?("https://github.com/owner/repo/pull/3?files=1")
    refute Navigation.pull_request_url?("https://gitlab.com/owner/repo/pull/3")
    refute Navigation.pull_request_url?("https://github.com/owner/repo/issues/3")
    refute Navigation.pull_request_url?("")
  end

  def test_issue_records_are_identified_by_their_shape
    assert Navigation.issue_record?({ "project_id" => "P1", "agent_ids" => [] })
    refute Navigation.issue_record?({ "project_id" => "P1" })
    refute Navigation.issue_record?("P1-I1")
  end
end
