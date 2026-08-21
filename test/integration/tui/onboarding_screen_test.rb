# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiSetupOverlayScreenTest < Minitest::Test
  include TUISupport

  ENTER = "\r"
  ESC = "\e"
  RIGHT = "\e[C"
  TAB = "\t"
  DOWN = "\e[B"
  LEFT = "\e[D"
  BACKSPACE = "\u007f"
  DELETE = "\e[3~"
  WIDTH = 100
  HEIGHT = 32

  def setup
    @original_theme = Meringue::TUI::Style.current_colorscheme
    @tmpdir = Dir.mktmpdir("meringue-setup-screen")
    @config_path = File.join(@tmpdir, "config.toml")
    File.write(@config_path, "[settings]\nschema_version = 1\n[experiments]\ngithub_support = false\n")
    @config = Meringue::Config.load(path: @config_path)
    @state = TUISupport.empty_state
    @submitted = Queue.new
    @handler = ->(text) { @submitted << text; { "event" => "slash_command_applied", "command_results" => [] } }
    @layout = Meringue::TUI::Layout.new
    @app = build_app
  end

  def teardown
    Meringue::TUI::Style.configure!(@original_theme)
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_setup_uses_the_same_full_screen_responsive_overlay_as_config
    open_setup

    {
      [100, 32] => ["Setup", "Welcome to Meringue", "Step 1 of 5", "Navigate: Enter Next", "[ Begin Setup ]", "[ Next ]", "[ Back ]"],
      [79, 24] => ["Setup", "Welcome to Meringue", "Step 1 of 5", "Navigate: Enter Next", "[ Begin Setup ]"],
      [46, 18] => ["Setup", "Welcome to Meringue", "Step 1 of 5", "Navigate: Enter Next"],
      [32, 10] => ["Setup", "Welcome", "Step 1 of 5", "Navigate"],
      [31, 9] => ["Terminal too small for Setup", "Esc cancel"]
    }.each do |(width, height), expected|
      frame = render(width: width, height: height)
      expected.each { |text| assert_includes frame, text, "#{width}x#{height}" }
      assert_equal height, frame.lines.length
    end

    state = compose
    assert_equal "settings", @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: 1, y: 1)
    assert_equal({ "agent_tree" => 0, "logs" => 0, "chat" => 0 }, @layout.scroll_limits(state, width: WIDTH, height: HEIGHT))
    refute_includes render, "agent tree"
  end

  def test_wide_step_indicator_has_no_duplicate_listing_and_experiments_is_final
    open_setup
    frame = render
    assert_includes frame, "Step 1 of 5"
    assert_includes frame, "Welcome to Meringue"
    refute_includes frame, "Step 1 of 5 · Welcome"
    refute_includes frame, "1●"
    refute_includes frame, "Review"
    refute_includes frame, "Continue"

    send_key(ENTER)
    3.times { send_key(TAB) }
    snap = snapshot
    assert_equal "Experiments", snap.fetch("category")
    assert snap.fetch("setup_last_step")
    assert_equal Meringue::Experiments::Registry.setting_ids, snap.fetch("rows").map { |row| row.fetch("id") }
    assert_includes render, "[ Complete ]"
  end

  def test_experiment_checkboxes_are_registry_derived_and_mouse_toggleable
    open_setup
    send_key(ENTER)
    3.times { send_key(TAB) }
    assert_equal "Experiments", snapshot.fetch("category")
    assert_equal Meringue::Experiments::Registry.setting_ids, snapshot.fetch("rows").map { |row| row.fetch("id") }

    geometry = @layout.send(:settings_pane).geometry(compose, width: WIDTH, height: HEIGHT)
    card = geometry.fetch(:card)
    view = @layout.send(:settings_pane).setup_view(compose, width: WIDTH, height: HEIGHT)
    send_mouse("x" => card.fetch(:x) + 2, "y" => view.fetch(:row_y))
    assert_equal true, snapshot.fetch("rows").first.fetch("value")

    before = snapshot.slice("category", "row_index", "dirty")
    send_mouse("x" => 0, "y" => 0)
    assert_equal before, snapshot.slice("category", "row_index", "dirty")
  end

  def test_centered_card_click_and_next_button_advance_without_writing
    open_setup
    geometry = @layout.send(:settings_pane).geometry(compose, width: WIDTH, height: HEIGHT)
    refute geometry.key?(:rail)
    card = geometry.fetch(:card)
    assert_equal (WIDTH - card.fetch(:width)) / 2, card.fetch(:x)
    view = @layout.send(:settings_pane).setup_view(compose, width: WIDTH, height: HEIGHT)
    send_mouse("x" => card.fetch(:x) + 2, "y" => view.fetch(:row_y))
    assert_equal "Theme", snapshot.fetch("category")
    assert_empty drain_submitted

    snap = compose
    geometry = @layout.send(:settings_pane).geometry(snap, width: WIDTH, height: HEIGHT)
    footer_y = geometry.fetch(:footer_y)
    actions = @layout.send(:settings_pane).action_segments(snap)
    action_width = actions.sum { |text, _style| text.length }
    send_mouse("x" => WIDTH - action_width, "y" => footer_y)
    assert_equal "Head defaults", snapshot.fetch("category")
    assert_empty drain_submitted
  end

  def test_setup_arrow_navigation_never_advances_and_footer_enter_navigates
    open_setup
    send_key(RIGHT)
    assert_equal "Welcome", snapshot.fetch("category")
    send_key(ENTER) # Theme
    assert_equal "Theme", snapshot.fetch("category")
    send_key(RIGHT)
    assert_equal "Theme", snapshot.fetch("category")
    refute snapshot.fetch("dirty")
    2.times { send_key("\e[B") } # focus the navigation footer
    assert snapshot.fetch("footer_focus")
    send_key(ENTER)
    assert_equal "Head defaults", snapshot.fetch("category")
    assert_empty drain_submitted
  end

  def test_backspace_goes_back_and_right_arrow_cannot_advance_the_wizard
    open_setup
    send_key(RIGHT)
    assert_equal "Welcome", snapshot.fetch("category")
    send_key(ENTER)
    send_key(TAB)
    assert_equal "Head defaults", snapshot.fetch("category")
    send_key(BACKSPACE)
    assert_equal "Theme", snapshot.fetch("category")
    send_key(DELETE)
    assert_equal "Welcome", snapshot.fetch("category")
  end

  def test_focused_controls_use_contextual_hints_and_enter_opens_pickers
    open_setup
    send_key(ENTER)
    assert_equal "Theme", snapshot.fetch("category")
    assert_includes render, "Enter open picker"

    send_key(DOWN)
    assert_includes render, "Enter toggle"
    send_key(LEFT)
    assert_equal false, snapshot.fetch("rows").fetch(snapshot.fetch("row_index")).fetch("value")
    assert_equal "Theme", snapshot.fetch("category")
    send_key(ENTER)
    assert_equal true, snapshot.fetch("rows").fetch(snapshot.fetch("row_index")).fetch("value")

    send_key(TAB)
    send_key(DOWN) # Head model
    send_key(ENTER)
    assert_equal "agent.head_model", snapshot.fetch("picker").fetch("id")
    assert_includes render, "Choose Head model"
  end

  def test_setup_animation_and_ascii_fallbacks_are_restrained_and_accessible
    open_setup
    assert_operator snapshot.fetch("setup_step_count"), :>, 1

    with_env("MERINGUE_ASCII_GLYPHS" => "1") do
      frame = render
      refute_includes frame, "✦"
      refute_includes frame, "●"
      assert_includes frame, "Step 1 of 5"
    end

    @app.instance_variable_get(:@settings_draft).set("appearance.animations", false)
    assert_equal 0, snapshot.fetch("setup_animation_phase")
    assert_includes render, "Welcome to Meringue"
  end

  def test_resize_below_minimum_is_recoverable_and_does_not_record_an_outcome
    open_setup
    @app.instance_variable_set(:@last_render_width, 31)
    @app.instance_variable_set(:@last_render_height, 9)
    @app.send(:handle_chat_key, ESC, "", 0, -1, @handler, compose)

    refute @app.instance_variable_get(:@settings_active)
    assert_empty drain_submitted
    assert_equal 0, Meringue::Config.load(path: @config_path).onboarding_version
  end

  def test_auto_setup_does_not_open_when_the_overlay_cannot_show_its_recovery_keys
    tiny = build_app(terminal: TUISupport::FakeTerminal.new(width: 31, height: 9))
    refute tiny.send(:onboarding_autostart?)
    refute tiny.send(:maybe_open_onboarding, -> { @state })

    minimum = build_app(terminal: TUISupport::FakeTerminal.new(width: 32, height: 10))
    assert minimum.send(:onboarding_autostart?)
  end

  private

  def build_app(terminal: nil)
    Meringue::TUI::App.new(
      layout: @layout || Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: terminal || TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: @config,
      onboarding_enabled: true
    )
  end

  def open_setup
    send_key(ENTER, input_buffer: "/setup")
    assert_equal "setup", snapshot.fetch("mode")
  end

  def send_key(key, input_buffer: "")
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    @app.send(:handle_key, key, input_buffer, input_buffer.length, -1, @handler, compose)
  end

  def send_mouse(position)
    event = {
      "type" => "mouse",
      "kind" => "button",
      "button" => 0,
      "pressed" => true,
      "x" => position.fetch("x") + 1,
      "y" => position.fetch("y") + 1
    }
    send_key(event)
  end

  def compose
    @app.send(:compose_state, -> { @state }, "", -1, 0)
  end

  def snapshot
    Meringue::TUI::Settings.snapshot(compose)
  end

  def render(width: WIDTH, height: HEIGHT)
    @app.render(compose, width: width, height: height, color: false)
  end

  def drain_submitted
    values = []
    values << @submitted.pop(true) while true
  rescue ThreadError
    values
  end
end
