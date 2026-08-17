# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiSetupOverlayScreenTest < Minitest::Test
  include TUISupport

  ENTER = "\r"
  ESC = "\e"
  TAB = "\t"
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
      [100, 32] => ["setup · 1/6", "Welcome to Meringue", "Step 1 of 6", "Enter begin", "[ Begin ]"],
      [79, 24] => ["setup · 1/6", "Welcome to Meringue", "Step 1 of 6", "Enter begin"],
      [46, 18] => ["setup · 1/6", "Welcome to Meringue", "Esc skip for now"],
      [32, 10] => ["setup · 1/6", "Welcome", "Esc skip"],
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

  def test_wide_step_rail_and_review_are_compact_but_complete
    open_setup
    frame = render
    assert_includes frame, "Step 1 of 6"
    assert_includes frame, "Welcome to Meringue"
    refute_includes frame, "setup steps"

    send_key(ENTER)
    4.times { send_key(TAB) }
    snap = snapshot
    assert_equal "Review", snap.fetch("category")
    ids = snap.fetch("rows").map { |row| row.fetch("id") }
    expected = Meringue::TUI::Settings::SetupFlow.steps.flat_map do |step|
      Meringue::TUI::Settings::SetupFlow.setting_ids(step).map { |id| "_setup_review:#{id}" }
    end
    assert_equal expected + ["_setup_finish"], ids
    assert_includes render, "[ Finish ]"
    assert_includes render, "Head harness"
  end

  def test_experiment_checkboxes_are_registry_derived_and_mouse_toggleable
    open_setup
    send_key(ENTER)
    3.times { send_key(TAB) }
    assert_equal "Experiments", snapshot.fetch("category")
    assert_equal Meringue::Experiments::Registry.ids.map { |id| "experiments.#{id}" } + ["_setup_next"], snapshot.fetch("rows").map { |row| row.fetch("id") }

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

  def test_setup_arrow_navigation_and_explicit_next_action
    open_setup
    send_key(ENTER) # Theme
    assert_equal "Theme", snapshot.fetch("category")
    send_key("\e[C")
    assert snapshot.fetch("dirty")
    2.times { send_key("\e[B") }
    assert_equal "_setup_next", snapshot.fetch("rows")[snapshot.fetch("row_index")].fetch("id")
    send_key(ENTER)
    assert_equal "Head defaults", snapshot.fetch("category")
    assert_empty drain_submitted
  end

  def test_setup_animation_and_ascii_fallbacks_are_restrained_and_accessible
    open_setup
    assert_operator snapshot.fetch("setup_step_count"), :>, 1

    with_env("MERINGUE_ASCII_GLYPHS" => "1") do
      frame = render
      refute_includes frame, "✦"
      refute_includes frame, "●"
      assert_includes frame, "Step 1 of 6"
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
