# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiGithubAccessActionTest < Minitest::Test
  include TUISupport

  ENTER = "\r"
  TAB = "\t"

  def setup
    @tmpdir = Dir.mktmpdir("meringue-github-access-ui")
    @config_path = File.join(@tmpdir, "config.toml")
    write_config
    @config = Meringue::Config.load(path: @config_path)
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(layout: @layout, config: @config)
    @state = empty_state
    @submitted = Queue.new
    @handler = lambda do |text|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_action_is_present_in_settings_and_setup_and_does_not_persist_itself
    @app.send(:open_settings, @state)
    # The Test GitHub access action lives in the Alternate backend category, not
    # Experiments, now that GitHub support is default behavior.
    navigate_to_category("Alternate backend")
    rows = @app.send(:settings_rows)
    action = rows.find { |row| row.fetch("id") == "forge.test_github_access" }
    refute_nil action
    assert_equal "Run test", action.fetch("display_value")

    before = File.read(@config_path)
    @app.instance_variable_set(:@settings_row_index, rows.index(action))
    @app.send(:activate_settings_row, @state, on_submit: @handler)
    command = Meringue::Input::SlashCommandParser.new.parse(@submitted.pop)

    assert_equal "TestGitHubAccess", command.type
    assert_equal before, File.read(@config_path)
    assert_equal "Testing…", @app.send(:selected_settings_row).fetch("display_value")

    @app.send(
      :apply_slash_command_results,
      [{
        "command_type" => "TestGitHubAccess",
        "status" => "accepted",
        "message" => "GitHub access is ready; read access to acme/app is confirmed.",
        "result" => {
          "outcome" => "success",
          "message" => "GitHub access is ready; read access to acme/app is confirmed.",
          "repository" => "acme/app"
        }
      }]
    )
    assert_equal "Ready", @app.send(:selected_settings_row).fetch("display_value")
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "read access to acme/app"

    @app.send(:open_settings, @state, mode: "setup")
    %w[agent.head_harness agent.worker_harness].each do |id|
      @app.instance_variable_get(:@settings_draft).set(id, "pi")
    end
    # Welcome, Harness, Theme, Alternate backend, then Experiments.
    4.times { send_key(TAB) }
    assert_equal "Experiments", @app.send(:settings_category)
    assert @app.send(:settings_rows).none? { |row| row.fetch("id") == "forge.test_github_access" }
  end

  def test_setup_access_check_runs_from_the_alternate_backend_step
    @app = Meringue::TUI::App.new(layout: @layout, config: Meringue::Config.load(path: @config_path))
    @app.send(:open_settings, @state, mode: "setup")
    %w[agent.head_harness agent.worker_harness].each do |id|
      @app.instance_variable_get(:@settings_draft).set(id, "pi")
    end
    # Welcome, Harness, Theme, Alternate backend.
    3.times { send_key(TAB) }
    assert_equal "Alternate backend", @app.send(:settings_category)
    rows = @app.send(:settings_rows)
    @app.instance_variable_set(:@settings_row_index, rows.index { |row| row.fetch("id") == "forge.test_github_access" })

    @app.send(:activate_settings_row, @state, on_submit: @handler)
    command = Meringue::Input::SlashCommandParser.new.parse(@submitted.pop)

    assert_equal "TestGitHubAccess", command.type
    assert_nil Meringue::Config.load(path: @config_path).value("experiments", "github_support")
  end

  def test_action_is_absent_when_an_alternate_frontend_is_selected
    File.write(
      @config_path,
      "[settings]\nschema_version = 3\n[forge]\nfrontend = \"command\"\n[tui]\ncolorscheme = \"meringue\"\n"
    )
    @app = Meringue::TUI::App.new(layout: @layout, config: Meringue::Config.load(path: @config_path))
    @app.send(:open_settings, @state)
    navigate_to_category("Alternate backend")

    refute @app.send(:settings_rows).any? { |row| row.fetch("id") == "forge.test_github_access" }
    refute_includes @app.render(compose, width: 100, height: 30, color: false), "Test GitHub access"
    assert_equal 0, @submitted.size
  end

  def test_all_client_outcomes_have_clear_configuration_labels
    expected = {
      "success" => "Ready",
      "disabled" => "Disabled",
      "unavailable" => "Unavailable",
      "missing_tooling" => "GitHub CLI missing",
      "unauthenticated" => "Not authenticated",
      "permission_denied" => "Permission denied",
      "repository_read_failure" => "Repository not readable",
      "timeout" => "Timed out",
      "malformed_remote" => "Malformed remote"
    }
    expected.each do |outcome, label|
      assert_equal label, @app.send(:github_access_test_label, outcome)
    end
  end

  private

  def write_config
    File.write(
      @config_path,
      "[settings]\nschema_version = 3\n[tui]\ncolorscheme = \"meringue\"\n"
    )
  end

  def navigate_to_category(name)
    until @app.send(:settings_category) == name
      send_key(TAB)
    end
  end

  def send_key(key)
    @app.instance_variable_set(:@last_render_width, 100)
    @app.instance_variable_set(:@last_render_height, 30)
    @app.send(:handle_chat_key, key, "", 0, -1, @handler, compose)
  end

  def compose
    @app.send(:compose_state, -> { @state }, "", -1, 0)
  end
end
