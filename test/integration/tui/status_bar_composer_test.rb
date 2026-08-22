# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiStatusBarComposerTest < Minitest::Test
  include TUISupport

  ESC = "\e"
  ENTER = "\r"
  TAB = "\t"
  LEFT = "\e[D"
  RIGHT = "\e[C"

  def setup
    @tmpdir = Dir.mktmpdir("meringue-status-bars")
    @config_path = File.join(@tmpdir, "config.toml")
    @config = Meringue::Config.load(path: @config_path)
    @state = empty_state
    @submitted = Queue.new
    @handler = lambda do |text|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
    @app = Meringue::TUI::App.new(config: @config, layout: Meringue::TUI::Layout.new)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_absent_layout_preserves_the_existing_dashboard_frame
    baseline = Meringue::TUI::Layout.new.render(composed_state(@state), width: 100, height: 30, color: false)
    configured = composed_state(@state, "_status_bar_layout" => nil)

    assert_equal baseline, Meringue::TUI::Layout.new.render(configured, width: 100, height: 30, color: false)
    refute Meringue::TUI::StatusBarLayout.configured?(configured)
  end

  def test_invalid_and_legacy_documents_fall_back_or_migrate_safely
    assert_nil Meringue::TUI::StatusBarLayout.normalize("not json")
    assert_nil Meringue::TUI::StatusBarLayout.normalize({ "version" => 99, "bars" => {} })
    invalid_item = Meringue::TUI::StatusBarLayout.default_configuration
    invalid_item.fetch("bars")["bottom"] = ["status", "unknown"]
    assert_nil Meringue::TUI::StatusBarLayout.normalize(invalid_item)

    legacy = {
      "schema_version" => 1,
      "bottom_bar" => ["status", "hint"],
      "agent-info" => ["commands", "agent"],
      "focused-worker" => ["commands", "worker_status"]
    }
    normalized = Meringue::TUI::StatusBarLayout.normalize(legacy)

    assert_equal 1, normalized.fetch("version")
    assert_equal %w[status context], normalized.dig("bars", "bottom")
    assert_equal %w[controls identity], normalized.dig("bars", "agent_information")
    assert_equal %w[controls status], normalized.dig("bars", "focused_worker")
  end

  def test_store_persists_a_canonical_layout_and_keeps_invalid_file_safe
    layout = Meringue::TUI::StatusBarLayout.default_configuration
    layout.fetch("bars")["bottom"] = %w[status context]
    store = Meringue::Config::Store.new(path: @config_path)
    store.save(
      base_fingerprint: store.fingerprint,
      changes: { "appearance.status_bar_layout" => Meringue::TUI::StatusBarLayout.serialized(layout) }
    )
    loaded = Meringue::Config.load(path: @config_path)
    assert_equal %w[status context], Meringue::TUI::StatusBarLayout.from_config(loaded).dig("bars", "bottom")

    File.write(@config_path, "[tui]\nstatus_bar_layout = \"{not json}\"\n")
    refute Meringue::TUI::StatusBarLayout.from_config(Meringue::Config.load(path: @config_path))
  end

  def test_draft_reorders_each_bar_and_reset_removes_customization
    draft = Meringue::TUI::StatusBarComposer::Draft.new(@config)
    draft.move_selected(1)
    draft.cycle_bar(1)
    draft.move_selected(1)

    assert_equal %w[status context], draft.layout.items("bottom")
    assert_equal %w[controls identity], draft.layout.items("agent_information")
    assert draft.dirty?
    assert_equal "appearance.status_bar_layout", draft.changes.keys.first
    refute_empty draft.changes.fetch("appearance.status_bar_layout")

    draft.reset!
    refute draft.dirty?
    assert_empty draft.changes
  end

  def test_composer_preview_is_live_and_escape_never_writes
    assert @app.send(:handle_local_navigation_command, "/status-bar", @state)
    frame = @app.render(compose, width: 80, height: 20, color: false)
    assert_includes frame, "status bar composer"
    assert_includes frame, "Live preview"

    send_key(RIGHT)
    assert_equal %w[status context], @app.instance_variable_get(:@status_bar_composer_draft).layout.items("bottom")
    refute File.exist?(@config_path)

    send_key(ESC)
    refute @app.instance_variable_get(:@status_bar_composer_active)
    refute File.exist?(@config_path)
  end

  def test_keyboard_save_uses_one_atomic_configuration_command
    @app.send(:open_status_bar_composer, @state)
    send_key(RIGHT)
    send_key(ENTER)

    command = Meringue::Input::SlashCommandParser.new.parse(@submitted.pop)
    assert_equal "SaveConfiguration", command.type
    assert_equal @config.fingerprint, command.payload.fetch("base_fingerprint")
    value = command.payload.fetch("changes").fetch("appearance.status_bar_layout")
    assert_equal %w[status context], Meringue::TUI::StatusBarLayout.normalize(value).dig("bars", "bottom")
    assert @app.instance_variable_get(:@status_bar_composer_saving)
  end

  def test_manual_and_first_run_setup_open_the_composer_and_keep_it_in_the_setup_transaction
    @app.send(:open_settings, @state, mode: "setup")
    open_setup_status_bar_composer(@app)
    assert_includes @app.render(compose, width: 80, height: 20, color: false), "status bar composer"

    send_key(RIGHT)
    send_key(ENTER)

    refute @app.instance_variable_get(:@status_bar_composer_active)
    assert @app.instance_variable_get(:@settings_active)
    value = @app.instance_variable_get(:@settings_draft).value("appearance.status_bar_layout")
    assert_equal %w[status context], Meringue::TUI::StatusBarLayout.normalize(value).dig("bars", "bottom")
    assert_equal 0, @submitted.size
    refute File.exist?(@config_path)

    send_key(TAB) # Meringue Xtras / final step
    assert_equal "Experiments", @app.send(:settings_category)
    send_key("\u0013") # Complete through the setup transaction
    command = Meringue::Input::SlashCommandParser.new.parse(@submitted.pop)
    assert_equal "completed", command.payload.fetch("onboarding_outcome")
    saved_layout = command.payload.fetch("changes").fetch("appearance.status_bar_layout")
    assert_equal %w[status context], Meringue::TUI::StatusBarLayout.normalize(saved_layout).dig("bars", "bottom")
    refute File.exist?(@config_path)

    first_run = Meringue::TUI::App.new(
      config: @config,
      layout: Meringue::TUI::Layout.new,
      onboarding_enabled: true,
      terminal: TUISupport::FakeTerminal.new(width: 80, height: 20)
    )
    assert first_run.send(:maybe_open_onboarding, -> { @state })
    assert_includes first_run.send(:settings_categories), "Status bar"
    open_setup_status_bar_composer(first_run)
    assert first_run.instance_variable_get(:@status_bar_composer_active)
  end

  def test_mouse_drag_reorders_an_item_and_resize_keeps_a_full_frame
    @app.send(:open_status_bar_composer, @state)
    snapshot = compose.fetch(Meringue::TUI::StatusBarComposer::STATE_KEY)
    pane = Meringue::TUI::StatusBarComposer::Pane.new
    geometry = pane.geometry(width: 80, height: 20)
    x = geometry.dig(:preview, :x) + 3
    first_y = geometry.dig(:preview, :y) + 3
    second_y = first_y + 1
    assert_equal :reset, pane.hit(snapshot, width: 80, height: 20, x: 46, y: 19)
    assert_equal :save, pane.hit(snapshot, width: 80, height: 20, x: 56, y: 19)
    assert_equal :cancel, pane.hit(snapshot, width: 80, height: 20, x: 70, y: 19)

    send_mouse("kind" => "button", "pressed" => true, "x" => x, "y" => first_y)
    send_mouse("kind" => "motion", "pressed" => true, "x" => x, "y" => second_y)
    send_mouse("kind" => "button", "pressed" => false, "x" => x, "y" => second_y)

    assert_equal %w[status context], @app.instance_variable_get(:@status_bar_composer_draft).layout.items("bottom")
    [
      [80, 20], [64, 18], [48, 12], [47, 11]
    ].each do |width, height|
      frame = @app.render(compose, width: width, height: height, color: false)
      assert_equal height, frame.lines.length, "#{width}x#{height} should not clip its canvas"
    end
    refute_nil snapshot
  end

  def test_custom_order_changes_only_the_configured_status_surface
    custom = Meringue::TUI::StatusBarLayout.default_configuration
    custom.fetch("bars")["bottom"] = %w[status context]
    state = composed_state(@state, "_status_bar_layout" => custom)
    frame = Meringue::TUI::Layout.new.render(state, width: 100, height: 30, color: false)

    # The configured layout remains a valid state snapshot and the ordinary
    # dashboard still renders all its panes; the unconfigured path is not used
    # as a substitute for malformed data.
    assert_includes frame, "agent tree"
    assert_equal custom, Meringue::TUI::StatusBarLayout.from_state(state)
  end

  def test_configured_agent_information_and_focused_worker_bars_render_after_resize
    state = composed_state(@state, "_status_bar_layout" => Meringue::TUI::StatusBarLayout.default_configuration)
    state["_status_bar_layout"]["bars"]["agent_information"] = %w[controls identity]
    state["_status_bar_layout"]["bars"]["focused_worker"] = %w[controls status]
    state["agents"] << agent_record("P1-I1-W1", "issue_id" => "P1-I1")
    state["_agent_workspace"] = {
      "active" => true,
      "embedded" => false,
      "agent_id" => "P1-I1-W1",
      "view" => "agent",
      "input_buffer" => "",
      "input_cursor" => 0,
      "leader_commands" => []
    }

    [
      [80, 20], [64, 18], [48, 12]
    ].each do |width, height|
      frame = Meringue::TUI::Layout.new.render(state, width: width, height: height, color: false)
      assert_equal height, frame.lines.length
      assert_includes frame, "focused worker"
    end
  end

  private

  def open_setup_status_bar_composer(app)
    steps = app.send(:settings_categories)
    app.instance_variable_set(:@settings_category_index, steps.index("Status bar"))
    assert_equal "status_bar", app.send(:selected_settings_row).fetch("editor")
    assert app.send(:activate_settings_row, @state, on_submit: @handler)
  end

  def composed_state(state, extras = {})
    TUISupport.composed_state(state).merge(extras)
  end

  def compose
    @app.send(:compose_state, -> { @state }, "", -1, 0)
  end

  def send_key(key)
    @app.instance_variable_set(:@last_render_width, 80)
    @app.instance_variable_set(:@last_render_height, 20)
    @app.send(:handle_chat_key, key, "", 0, -1, @handler, compose)
  end

  def send_mouse(event)
    send_key(event.merge("type" => "mouse", "x" => event.fetch("x") + 1, "y" => event.fetch("y") + 1))
  end
end
