# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiDefaultStatusBarTest < Minitest::Test
  include TUISupport

  def setup
    @tmpdir = Dir.mktmpdir("meringue-default-status-bar")
    @config_path = File.join(@tmpdir, "config.toml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_dashboard_always_renders_the_default_status_bar
    config = Meringue::Config.load(path: @config_path)
    app = Meringue::TUI::App.new(config: config, layout: Meringue::TUI::Layout.new)
    state = empty_state.merge(
      "agents" => [agent_record("P1-I1-W1", "status" => "working", "type" => "worker")],
      "metadata" => { "active_harness" => "pi", "agent_session_defaults" => {
        "model" => "openai/gpt-5.6-sol", "thinking_level" => "high"
      } }
    )

    left, right = Meringue::TUI::Layout.new.send(:dashboard_status_bar_lines, state)
    assert_equal "Ctrl-C clear/quit · Tab focus · / commands · no open PRs · ● 1 worker · 0 heads", plain(left)
    assert_equal "harness: Pi · model: openai/gpt-5.6-sol · thinking: high", plain(right)

    refute app.send(:handle_local_navigation_command, "/status-bar", state)
    refute app.send(:handle_local_navigation_command, "/layout", state)
  end

  # Regression: the left status bar is assembled from semantic components, and
  # two of them used to answer the same question. `open_pull_requests` renders
  # the all-open-PR count, and `context` fell back to that same count whenever
  # no node was selected, so the bar read "1 open PR · 1 open PR · 0 workers".
  def test_the_open_pull_request_count_is_rendered_exactly_once
    { 0 => "no open PRs", 1 => "1 open PR", 3 => "3 open PRs" }.each do |total, label|
      left = plain(status_bar_left(state_with_open_pull_requests(total)))

      assert_equal 1, left.scan(label).length, "expected one #{label.inspect} segment, got #{left.inspect}"
      assert_includes left, "#{label} · 0 workers · ● 1 head"
    end
  end

  # The neighbouring counts share the same component assembly, so they get the
  # same guard: one segment each, whatever the PR count is.
  def test_the_worker_and_head_counts_are_rendered_exactly_once
    left = plain(status_bar_left(state_with_open_pull_requests(2)))

    assert_equal 1, left.scan("0 workers").length, left
    assert_equal 1, left.scan("1 head").length, left
  end

  # A selected node still gets its own PR in the context component, and the
  # all-open-PR count still appears once beside it.
  def test_a_scoped_selection_shows_its_own_pull_request_beside_the_count
    state = state_with_open_pull_requests(2)
    app = Meringue::TUI::App.new(layout: Meringue::TUI::Layout.new)
    assert app.send(:select_agent_tree_item, state, "P1-I1")
    app.send(:exit_agent_tree_navigation)
    left = plain(status_bar_left(compose_app_state(app, state)))

    assert_includes left, "PR #101"
    assert_equal 1, left.scan("2 open PRs").length, left
  end

  private

  # `total` open delivery PRs spread one per issue, plus one head so the bar has
  # the neighbouring counts to render.
  def state_with_open_pull_requests(total)
    issues = Array.new(total) do |index|
      number = (101 + index).to_s
      issue_record(
        "P1-I#{index + 1}",
        "delivery_pull_requests" => [{
          "number" => number,
          "url" => "https://github.com/owner/repo/pull/#{number}",
          "state" => "open",
          "matched_by" => "workspace_branch"
        }]
      )
    end
    composed_state(
      empty_state.merge(
        "issues" => issues,
        "agents" => [agent_record("P1-I1-H1", "type" => "head", "status" => "working", "issue_id" => "P1-I1")]
      )
    )
  end

  def status_bar_left(state)
    Meringue::TUI::Layout.new.send(:dashboard_status_bar_lines, state).first
  end

  def plain(segments)
    Array(segments).map { |segment| segment.fetch(0, "").to_s }.join
  end
end
