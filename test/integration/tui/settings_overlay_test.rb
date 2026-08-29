# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiSettingsOverlayTest < Minitest::Test
  include TUISupport

  class RecordingPullRequestOpener
    attr_reader :urls

    def initialize
      @urls = []
    end

    def open(url)
      @urls << url
      { "status" => "opened", "message" => "opened" }
    end
  end

  ENTER = "\r"
  ESC = "\e"
  DOWN = "\e[B"
  RIGHT = "\e[C"
  UP = "\e[A"
  TAB = "\t"
  SHIFT_TAB = "\e[Z"
  CTRL_S = "\u0013"
  BACKSPACE = "\u007f"

  def setup
    @original_theme = Meringue::TUI::Style.current_colorscheme
    @tmpdir = Dir.mktmpdir("meringue-settings-overlay")
    @config_path = File.join(@tmpdir, "config.toml")
    File.write(@config_path, <<~TOML)
      [settings]
      schema_version = 1
      [experiments]
      github_support = false
      [tui]
      colorscheme = "meringue"
    TOML
    @config = Meringue::Config.load(path: @config_path)
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(layout: @layout, config: @config)
    @state = TUISupport.empty_state
    @submitted = Queue.new
    @handler = lambda do |text|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
  end

  def teardown
    Meringue::TUI::Style.configure!(@original_theme)
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_config_opens_a_full_screen_overlay_instead_of_appending_chat
    assert @app.send(:handle_local_navigation_command, "/config", @state)
    composed = compose
    frame = @app.render(composed, width: 100, height: 30, color: false)

    assert Meringue::TUI::Settings.enabled?(composed)
    assert_includes frame, "meringue · settings"
    assert_includes frame, "Agent defaults"
    assert_includes frame, "Head harness"
    refute_includes frame, "Configuration (read-only)"
    assert_equal "settings", @layout.pane_at(composed, width: 100, height: 30, x: 1, y: 1)
  end

  def test_text_compatibility_form_keeps_the_diagnostic_dump
    assert @app.send(:handle_local_navigation_command, "/config --text", @state)
    refute @app.instance_variable_get(:@settings_active)
    messages = @app.instance_variable_get(:@messages)
    assert messages.any? { |message| message.fetch("text", "").include?("Configuration (read-only)") }
  end

  def test_settings_header_offers_friendly_agent_help_without_cluttering_setup
    @app.send(:open_settings, @state)
    header = @layout.send(:settings_pane).header_segments(compose, width: 100)
    assert_includes header.map(&:first).join, "Not sure what to change? Ask your agent for help."
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "Ask your agent for help"
    compact_header = @layout.send(:settings_pane).header_segments(compose, width: 46)
    assert_includes compact_header.map(&:first).join, "Need help? Ask your agent."

    @app.send(:open_settings, @state, mode: "setup")
    setup_header = @layout.send(:settings_pane).header_segments(compose, width: 100)
    refute_includes setup_header.map(&:first).join, "Ask your agent"
  end

  def test_wide_medium_compact_and_too_small_layouts_are_recoverable
    @app.send(:open_settings, @state)
    {
      [100, 30] => ["categories", "Head harness", "Esc cancel"],
      [79, 24] => ["Tab/Shift-Tab categories", "Head harness"],
      [46, 18] => ["Agent defaults", "Head harness"],
      [32, 10] => ["settings", "Esc cancel"],
      [31, 9] => ["Terminal too small", "Esc cancel"]
    }.each do |(width, height), expected|
      frame = @app.render(compose, width: width, height: height, color: false)
      expected.each { |text| assert_includes frame, text, "#{width}x#{height}" }
      assert_equal height, frame.lines.length
    end

    send_key(ESC, width: 31, height: 9)
    refute @app.instance_variable_get(:@settings_active)
  end

  def test_keyboard_navigation_toggles_experiment_and_saves_once
    @app.send(:open_settings, @state)
    2.times { send_key(TAB) }
    assert_equal "Experiments", @app.send(:settings_category)
    row = @app.send(:selected_settings_row)
    assert_equal "experiments.github_support", row.fetch("id")
    assert_equal false, row.fetch("value")

    send_key(" ")
    assert_equal true, @app.send(:selected_settings_row).fetch("value")
    send_key(CTRL_S)

    encoded_submission = @submitted.pop
    command = Meringue::Input::SlashCommandParser.new.parse(encoded_submission)
    assert_equal "SaveConfiguration", command.type
    assert_equal({ "experiments.github_support" => true }, command.payload.fetch("changes"))
    assert_equal @config.fingerprint, command.payload.fetch("base_fingerprint")
  end

  def test_theme_preview_is_restored_after_confirmed_discard
    @app.send(:open_settings, @state)
    send_key(TAB)
    assert_equal "Appearance", @app.send(:settings_category)
    assert_equal "appearance.theme", @app.send(:selected_settings_row).fetch("id")

    send_key(RIGHT)
    preview = Meringue::TUI::Style.current_colorscheme
    refute_equal @original_theme, preview
    assert_equal preview, @app.send(:selected_settings_row).fetch("value")
    refute File.read(@config_path).include?(preview), "preview must not write the config"

    send_key(ESC)
    assert @app.instance_variable_get(:@settings_discard_confirm)
    send_key(ENTER)
    refute @app.instance_variable_get(:@settings_active)
    assert_equal @original_theme, Meringue::TUI::Style.current_colorscheme
    assert_equal "meringue", Meringue::Config.load(path: @config_path).value("tui", "colorscheme")
  end

  def test_mouse_categories_rows_checkbox_save_and_empty_space_are_safe
    @app.send(:open_settings, @state)
    composed = compose
    geometry = @layout.send(:settings_pane).geometry(composed, width: 100, height: 30)
    rail = geometry.fetch(:rail)
    send_mouse("x" => rail.fetch(:x) + 2, "y" => rail.fetch(:y) + 3)
    assert_equal "Experiments", @app.send(:settings_category)

    detail = geometry.fetch(:detail)
    send_mouse("x" => detail.fetch(:x) + 2, "y" => detail.fetch(:y) + 1)
    assert_equal true, @app.send(:selected_settings_row).fetch("value")

    before = @app.send(:settings_snapshot)
    send_mouse("x" => 0, "y" => 0)
    after = @app.send(:settings_snapshot)
    assert_equal before.slice("category", "row_index", "dirty"), after.slice("category", "row_index", "dirty")

    footer_y = geometry.fetch(:footer_y)
    action_width = Meringue::TUI::Panes::SettingsPane::SAVE_LABEL.length + 1 + Meringue::TUI::Panes::SettingsPane::CANCEL_LABEL.length
    send_mouse("x" => 100 - action_width, "y" => footer_y)
    command = Meringue::Input::SlashCommandParser.new.parse(@submitted.pop)
    assert_equal "SaveConfiguration", command.type
  end

  def test_disabled_github_support_hides_pr_markers_hints_picker_and_opening_actions
    opener = RecordingPullRequestOpener.new
    @app = Meringue::TUI::App.new(layout: @layout, config: @config, pull_request_opener: opener)
    url = "https://github.com/acme/app/pull/8"
    @state["projects"] << project_record("P1", "issue_ids" => ["P1-I1"])
    @state["issues"] << issue_record("P1-I1", "agent_ids" => ["P1-I1-W1"], "delivery_pull_request" => { "url" => url, "state" => "open" })
    @state["agents"] << agent_record("P1-I1-W1", "project_id" => "P1", "issue_id" => "P1-I1")

    frame = @app.render(compose, width: 100, height: 30, color: false)
    refute_includes frame, "PR #8"
    refute_includes frame, "open PR"
    refute_includes @app.send(:workspace_leader_commands).map { |command| command.fetch("action") }, "workspace_open_pull_request"

    assert @app.send(:handle_local_pull_requests_command, @state)
    assert_empty opener.urls
    message = @app.instance_variable_get(:@messages).last.fetch("text")
    assert_includes message, "Settings → Experiments"
    refute @app.send(:open_delivery_pr_for_id, @state, "P1-I1-W1")
    assert_empty opener.urls
  end

  def test_advanced_rows_are_collapsed_but_every_schema_row_is_reachable_once
    @app.send(:open_settings, @state)
    draft = @app.instance_variable_get(:@settings_draft)
    visible_ids = draft.categories.flat_map { |category| draft.definitions_for(category, include_advanced: true).map(&:id) }

    expected_ids = draft.definitions.map(&:id).reject { |id| id == "experiments.worker_spawning_guidance_prompt" }.sort
    assert_equal expected_ids, visible_ids.sort
    assert_includes draft.definitions.map(&:id), "experiments.worker_spawning_guidance_prompt"
    refute_includes visible_ids, "experiments.worker_spawning_guidance_prompt"
    assert_equal visible_ids.length, visible_ids.uniq.length

    3.times { send_key(TAB) }
    assert_equal "Harnesses", @app.send(:settings_category)
    assert_equal "_show_advanced", @app.send(:selected_settings_row).fetch("id")

    # The reveal keeps its place and its cursor, so the key that opened the
    # advanced rows is the key that puts them away.
    send_key(ENTER)
    assert_equal "_show_advanced", @app.send(:selected_settings_row).fetch("id")
    assert_includes @app.send(:selected_settings_row).fetch("label"), "Hide advanced"
    assert_includes @app.send(:settings_rows).map { |row| row.fetch("id") }, "harnesses.pi.command"

    send_key(ENTER)
    assert_equal "_show_advanced", @app.send(:selected_settings_row).fetch("id")
    assert_includes @app.send(:selected_settings_row).fetch("label"), "Show advanced"
    refute_includes @app.send(:settings_rows).map { |row| row.fetch("id") }, "harnesses.pi.command"
  end

  def test_invalid_field_stays_in_editor_and_renders_inline
    @app.send(:open_settings, @state)
    4.times { send_key(TAB) }
    send_key(ENTER) # reveal advanced workspace rows
    rows = @app.send(:settings_rows)
    index = rows.index { |row| row.fetch("id") == "workspace.provisioning_concurrency" }
    refute_nil index
    @app.instance_variable_set(:@settings_row_index, index)
    send_key(ENTER)
    editor = @app.instance_variable_get(:@settings_editor)
    editor["buffer"] = "99"
    editor["cursor"] = 2
    send_key(ENTER)

    refute_nil @app.instance_variable_get(:@settings_editor)
    frame = @app.render(compose, width: 100, height: 30, color: false)
    assert_includes frame, "must be at most 8"
  end

  def test_advanced_reveal_is_scoped_to_the_category_and_counts_are_explicit
    @app.send(:open_settings, @state)
    3.times { send_key(TAB) }
    assert_equal "Harnesses", @app.send(:settings_category)
    hidden = @app.send(:settings_snapshot).fetch("hidden_advanced_count")
    assert_operator hidden, :>, 0
    assert_includes @app.send(:selected_settings_row).fetch("label"), "(#{hidden})"

    send_key(ENTER)
    assert_equal 0, @app.send(:settings_snapshot).fetch("hidden_advanced_count")
    assert @app.send(:settings_rows).any? { |row| row.fetch("id") == "harnesses.pi.command" }

    send_key(TAB)
    assert_equal "Workspace", @app.send(:settings_category)
    workspace_hidden = @app.send(:settings_snapshot).fetch("hidden_advanced_count")
    assert_operator workspace_hidden, :>, 0
    assert_equal "_show_advanced", @app.send(:selected_settings_row).fetch("id")
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "advanced hidden"

    send_key(SHIFT_TAB)
    assert_equal "Harnesses", @app.send(:settings_category)
    assert_equal 0, @app.send(:settings_snapshot).fetch("hidden_advanced_count")
    toggle = @app.send(:settings_rows).find { |row| row.fetch("id") == "_show_advanced" }
    assert_includes toggle.fetch("label"), "Hide advanced"

    # A does the same thing from anywhere in the category, and the footer says so.
    send_key("a")
    assert_equal hidden, @app.send(:settings_snapshot).fetch("hidden_advanced_count")
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "A advanced"
  end

  def test_keybinding_enter_uses_isolated_capture_with_cancel_clear_invalid_and_repeat_paths
    @app.send(:open_settings, @state)
    6.times { send_key(TAB) }
    assert_equal "Keybindings", @app.send(:settings_category)
    send_key("a") # every keybinding row is advanced; the reveal keeps the cursor
    assert_equal "_show_advanced", @app.send(:selected_settings_row).fetch("id")
    @app.instance_variable_set(:@settings_row_index, @app.send(:settings_rows).index { |row| row.fetch("id") == "keybindings.quit" })
    row = @app.send(:selected_settings_row)
    assert_equal "keybindings.quit", row.fetch("id")

    send_key(ENTER)
    assert @app.instance_variable_get(:@settings_keybinding_capture)
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "Press the next keyboard key"

    send_key(UP)
    refute @app.instance_variable_get(:@settings_keybinding_capture), "the navigation key should be captured, not navigate the list"
    assert_equal ["up"], @app.instance_variable_get(:@settings_draft).value("keybindings.quit")
    assert_equal "keybindings.quit", @app.send(:selected_settings_row).fetch("id")

    send_key(ENTER)
    send_key("xy")
    assert @app.instance_variable_get(:@settings_keybinding_capture), "multi-character input is invalid, not a paste"
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "cannot be used"

    send_mouse("x" => 0, "y" => 0)
    assert @app.instance_variable_get(:@settings_keybinding_capture), "mouse input must not close capture"
    assert_includes @app.render(compose, width: 100, height: 30, color: false), "Mouse input cannot"

    original = @app.instance_variable_get(:@settings_draft).value("keybindings.quit")
    send_key(ESC)
    refute @app.instance_variable_get(:@settings_keybinding_capture)
    assert_equal original, @app.instance_variable_get(:@settings_draft).value("keybindings.quit")

    send_key(ENTER)
    send_key("x")
    assert_equal ["x"], @app.instance_variable_get(:@settings_draft).value("keybindings.quit")
    refute @app.instance_variable_get(:@settings_keybinding_capture)

    send_key(ENTER)
    send_key(ENTER) # Enter is captured, not applied as an editor command.
    assert_equal ["enter"], @app.instance_variable_get(:@settings_draft).value("keybindings.quit")
    refute @app.instance_variable_get(:@settings_keybinding_capture)

    send_key(ENTER)
    send_key(BACKSPACE)
    assert_equal [], @app.instance_variable_get(:@settings_draft).value("keybindings.quit")
    refute @app.instance_variable_get(:@settings_keybinding_capture)
  end

  private

  def compose
    @app.send(:compose_state, -> { @state }, "", -1, 0)
  end

  def send_key(key, width: 100, height: 30)
    @app.instance_variable_set(:@last_render_width, width)
    @app.instance_variable_set(:@last_render_height, height)
    @app.send(:handle_chat_key, key, "", 0, -1, @handler, compose)
  end

  def send_mouse(position)
    terminal_position = position.merge("x" => position.fetch("x") + 1, "y" => position.fetch("y") + 1)
    event = terminal_position.merge("type" => "mouse", "kind" => "button", "button" => 0, "pressed" => true)
    send_key(event)
  end
end
