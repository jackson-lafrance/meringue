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

  private

  def plain(segments)
    Array(segments).map { |segment| segment.fetch(0, "").to_s }.join
  end
end
