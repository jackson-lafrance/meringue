# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# The setup *screen*: the full-screen takeover, the animation, and the rule that
# the mouse cannot drive the flow.
#
# Setup used to render in the shared popup slot over the dashboard, which meant a
# click on any row applied it and a click anywhere else dismissed the whole flow.
# One stray click during a first launch silently skipped onboarding. It now owns
# the terminal, is keyboard-only, and animates as a pure function of elapsed
# seconds so a dropped frame, a resize, or a full redraw all recompute the same
# picture.
#
# The flow itself (what each step submits, skip/back/resume, the theme preview,
# the degraded catalog paths) is covered in onboarding_test.rb.
class TuiOnboardingScreenTest < Minitest::Test
  include TUISupport

  Onboarding = Meringue::TUI::Onboarding
  Motion = Onboarding::Motion
  Pane = Meringue::TUI::Panes::OnboardingPane
  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT
  ENTER = "\r"
  ESC = "\e"
  DOWN = "\e[B"
  CTRL_R = "\u0012"

  def setup
    @submitted = []
    @layout = Meringue::TUI::Layout.new
    @pane = Pane.new
    @original_colorscheme = Meringue::TUI::Style.current_colorscheme
    @state = state_with_catalog
    @app = build_onboarding_app
  end

  def teardown
    wait_for_submissions(@submitted.length)
    Meringue::TUI::Style.configure!(@original_colorscheme)
  end

  # --- full-screen takeover ------------------------------------------------

  def test_setup_owns_the_whole_screen_and_no_dashboard_pane_is_drawn
    frame = render_frame(open_setup, width: WIDTH, height: HEIGHT)
    lines = frame.split("\n")

    assert_equal HEIGHT, lines.length
    assert_equal [WIDTH], lines.map(&:length).uniq, "the setup screen fills the terminal exactly"

    assert_includes frame, "meringue · first-run setup"
    assert_includes frame, "setup · welcome"
    ["agent tree", "logs", "conversation", "› "].each do |chrome|
      refute_includes frame, chrome, "the dashboard must not be drawn behind setup"
    end
  end

  def test_the_card_is_centered_and_capped_so_wide_terminals_do_not_stretch_it
    state = open_setup

    geometry = @layout.onboarding_geometry(state, width: 200, height: 60)
    assert_equal Onboarding::MAX_CARD_WIDTH, geometry.fetch(:card_width)
    left = geometry.fetch(:card_x)
    right = 200 - left - geometry.fetch(:card_width)
    assert_in_delta left, right, 1, "the card is horizontally centered"

    # Vertically centered too: the block of chrome plus card sits off the top edge.
    assert_operator geometry.fetch(:card_y), :>, 4
    assert_operator geometry.fetch(:hint_y), :>, geometry.fetch(:caption_y)
  end

  # Every dashboard gesture is dead while setup owns the screen, so nothing can
  # scroll, select, or focus a pane underneath it.
  def test_the_layout_reports_no_dashboard_targets_while_setup_is_up
    state = open_setup

    assert_equal "onboarding", @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: 1, y: 1)
    assert_equal "onboarding", @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: WIDTH - 2, y: HEIGHT - 2)
    assert_equal({ "agent_tree" => 0, "logs" => 0, "chat" => 0 }, @layout.scroll_limits(state, width: WIDTH, height: HEIGHT))
    assert_nil @layout.agent_tree_item_at(state, width: WIDTH, height: HEIGHT, x: 4, y: 4)
    assert_nil @layout.send(:agent_tree_content_dimensions, state, width: WIDTH, height: HEIGHT)
  end

  # --- the mouse cannot drive the flow -------------------------------------

  # The regression. Every mouse event the terminal can report is inert: no row is
  # applied, no step advances, setup is not dismissed, and the highlight does not
  # even move.
  def test_no_mouse_event_advances_selects_or_dismisses_setup
    open_setup
    send_key(ENTER)
    send_key(DOWN)

    before = @pane.snapshot(compose).reject { |key, _| %w[elapsed notice].include?(key) }

    mouse_events.each do |label, event|
      result = send_key(event)

      assert_equal ["", 0, -1], result, "#{label} must leave the composer alone"
      assert @pane.active?(compose), "#{label} must not dismiss setup"
      assert_equal "setup · 1/4 · harness", @pane.title(compose), "#{label} must not change step"
      assert_equal 1, @pane.index(compose), "#{label} must not move the highlight"
      assert_empty @submitted, "#{label} must not submit anything"
      assert_equal before, @pane.snapshot(compose).reject { |key, _| %w[elapsed notice].include?(key) },
                   "#{label} must not change setup state"
    end
  end

  # An ignored click is answered on screen, so it never looks like a freeze.
  def test_a_click_is_answered_with_a_visible_notice_naming_the_keys_that_work
    open_setup
    refute_includes render_frame(compose, width: WIDTH, height: HEIGHT), "Clicks do nothing"

    send_key(press_event("x" => 20, "y" => 12))
    frame = render_frame(compose, width: WIDTH, height: HEIGHT)

    assert_includes frame, "Clicks do nothing here"
    assert_includes frame, "Enter"
    assert_includes frame, "Esc"
  end

  # The notice is transient: it is not a permanent banner and it is not sticky
  # across steps.
  def test_the_click_notice_expires_and_does_not_survive_the_step
    open_setup
    send_key(press_event("x" => 20, "y" => 12))
    assert_equal Onboarding::NOTICE_MOUSE, @pane.notice_kind(compose)

    @app.instance_variable_set(:@onboarding_notice_at, @app.send(:monotonic_time) - Onboarding::NOTICE_SECONDS - 1)
    assert_equal "", @pane.notice_kind(compose)

    send_key(press_event("x" => 20, "y" => 12))
    send_key(ENTER)
    assert_equal "", @pane.notice_kind(compose), "advancing a step clears the answer to a stale click"
  end

  # Pasting is a mouse gesture in most terminals (middle click, Cmd-V). It may
  # filter the model list and nothing else; it must never advance the flow or land
  # in the composer hidden behind the screen.
  def test_a_paste_filters_the_model_step_and_is_swallowed_everywhere_else
    open_setup
    send_key(paste_event("opus"))

    assert @pane.active?(compose)
    assert_equal "setup · welcome", @pane.title(compose)
    assert_equal "", @pane.query(compose)

    2.times { send_key(ENTER) }
    wait_for_submissions(1)
    assert_equal "setup · 2/4 · model (pi)", @pane.title(compose)

    send_key(paste_event("opus"))
    assert_equal "opus", @pane.query(compose)
    assert_equal ["anthropic/claude-opus-5"], @pane.rows(compose).map { |row| row.fetch("value") }
    assert_equal ["/harness pi"], @submitted
  end

  # --- animation -----------------------------------------------------------

  # The reveal is a staggered cascade driven by elapsed seconds: nothing at the
  # start of the step, more rows each frame, everything settled after the reveal.
  def test_rows_reveal_progressively_and_settle
    counts = [0.0, 0.05, 0.12, 0.25, 1.0].map { |elapsed| visible_row_count(animated_state(elapsed: elapsed)) }

    assert_equal counts.sort, counts, "the reveal only ever adds rows"
    assert_operator counts.first, :<, counts.last
    assert_equal visible_row_count(animated_state(elapsed: 30.0)), counts.last, "the reveal settles and stays settled"
    assert_equal counts.last, visible_row_count(animated_state(elapsed: 1.0, animated: false)),
                 "the settled frame is exactly what a terminal that cannot animate renders"
  end

  def test_the_rule_sweeps_out_and_the_progress_bar_eases_to_its_step
    widths = [0.0, 0.08, 0.16, 0.31].map do |elapsed|
      plain_line(@pane.rule_segments(animated_state(elapsed: elapsed), width: 60)).length
    end

    assert_equal widths.sort, widths
    assert_equal 0, widths.first
    assert_equal 60, widths.last, "the sweep finishes inside RULE_DURATION"

    # Advancing eases from the fraction the previous step left, so the bar moves
    # instead of jumping.
    from = Onboarding.step_fraction(Onboarding::MODEL, Onboarding.plan("pi"))
    target = Onboarding.step_fraction(Onboarding::THINKING, Onboarding.plan("pi"))
    start = @pane.progress_fraction(animated_state(step: Onboarding::THINKING, elapsed: 0.0, progress_from: from))
    middle = @pane.progress_fraction(animated_state(step: Onboarding::THINKING, elapsed: 0.15, progress_from: from))
    settled = @pane.progress_fraction(animated_state(step: Onboarding::THINKING, elapsed: 5.0, progress_from: from))

    assert_in_delta from, start, 0.001
    assert_operator middle, :>, from
    assert_operator middle, :<, target + 0.001
    assert_in_delta target, settled, 0.001
  end

  # The selection marker breathes rather than blinks, and the highlight is a
  # background band so focus survives a terminal with no color.
  def test_the_selected_row_is_marked_and_the_marker_pulses
    on = row_line(animated_state(elapsed: 5.0), 0)
    off = row_line(animated_state(elapsed: 5.0 + (Motion::PULSE_PERIOD / 2)), 0)

    assert on.start_with?("▸ ") || on.start_with?("▹ "), on
    refute_equal on[0], off[0], "the marker alternates between two glyphs"
    refute_includes row_line(animated_state(elapsed: 5.0), 1), "▸", "only the highlighted row is marked"

    styles = styles_in(@pane.card_lines(
      animated_state(elapsed: 5.0),
      prose: [],
      visible: @pane.rows(animated_state).first(2),
      window_start: 0,
      width: 60
    ).first)
    assert_includes styles, Meringue::TUI::Style::AGENT_TREE_SELECTED
  end

  # Animation is only asked for while something is moving, so an idle setup screen
  # costs the same slow tick as the dashboard rather than 20fps forever.
  def test_animation_frames_are_only_requested_while_a_step_is_moving
    assert @pane.animating?(animated_state(elapsed: 0.05))
    refute @pane.animating?(animated_state(elapsed: 30.0))
    refute @pane.animating?(animated_state(elapsed: 0.05, animated: false))

    app = build_onboarding_app(terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT, interactive: true))
    app.instance_variable_set(:@last_render_width, WIDTH)
    app.instance_variable_set(:@last_render_height, HEIGHT)

    assert_equal Meringue::TUI::App::REFRESH_INTERVAL, app.send(:frame_refresh_interval, compose_app_state(app, @state))

    app.send(:open_onboarding, @state)
    assert_equal Motion::FRAME_INTERVAL, app.send(:frame_refresh_interval, compose_app_state(app, @state))

    app.instance_variable_set(:@onboarding_step_entered_at, app.send(:monotonic_time) - 30)
    assert_equal Motion::IDLE_INTERVAL, app.send(:frame_refresh_interval, compose_app_state(app, @state))
  end

  # --- degrading -----------------------------------------------------------

  # A non-interactive terminal (a pipe, a recorded frame, the test suite) never
  # animates: the first frame it renders is the settled one.
  def test_a_non_interactive_terminal_renders_the_settled_frame
    refute @pane.animated?(open_setup)
    refute @pane.animating?(compose)

    frame = render_frame(compose, width: WIDTH, height: HEIGHT)
    assert_equal frame, render_frame(compose, width: WIDTH, height: HEIGHT), "a settled frame does not depend on the clock"
  end

  def test_a_terminal_too_small_for_motion_renders_the_settled_frame
    app = build_onboarding_app(terminal: TUISupport::FakeTerminal.new(width: 50, height: 14, interactive: true))
    app.instance_variable_set(:@last_render_width, 50)
    app.instance_variable_set(:@last_render_height, 14)
    app.send(:open_onboarding, @state)

    refute Onboarding.animation_allowed?(width: 50, height: 14)
    refute @pane.animated?(compose_app_state(app, @state))
    # Still fits, so setup stays up rather than refusing to run.
    assert Onboarding.fits?(width: 50, height: 14)
    assert @pane.active?(compose_app_state(app, @state))
  end

  def test_motion_can_be_turned_off_by_env_or_config
    with_env("MERINGUE_NO_ANIMATION" => "1") do
      assert Onboarding.reduced_motion?
    end
    with_env("MERINGUE_NO_ANIMATION" => nil) do
      refute Onboarding.reduced_motion?
      assert Onboarding.reduced_motion?(config: config_with(tui: { "animations" => false }))
      refute Onboarding.reduced_motion?(config: config_with(tui: { "animations" => true }))
    end

    interactive = TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT, interactive: true)
    app = build_onboarding_app(terminal: interactive, config: config_with(tui: { "animations" => false }))
    app.instance_variable_set(:@last_render_width, WIDTH)
    app.instance_variable_set(:@last_render_height, HEIGHT)
    app.send(:open_onboarding, @state)

    refute @pane.animated?(compose_app_state(app, @state))
    assert_equal Meringue::TUI::App::REFRESH_INTERVAL, app.send(:frame_refresh_interval, compose_app_state(app, @state))
  end

  # A terminal that is not drawing UTF-8 gets the whole screen in ASCII rather
  # than a half-broken mix of box drawing and mojibake.
  def test_a_non_utf8_terminal_gets_an_ascii_screen
    assert Onboarding.ascii_only?(env: { "MERINGUE_ASCII_GLYPHS" => "1" })
    assert Onboarding.ascii_only?(env: { "LC_ALL" => "C" })
    refute Onboarding.ascii_only?(env: { "LC_ALL" => "en_US.UTF-8" })
    refute Onboarding.ascii_only?(env: {}), "UTF-8 stays the default assumption"

    state = animated_state(elapsed: 5.0, ascii: true)
    assert_equal Onboarding::ASCII_GLYPHS, @pane.glyphs(state)
    assert row_line(state, 0).start_with?(">", "-"), row_line(state, 0)
    bar = plain_line(@pane.progress_segments(animated_state(step: Onboarding::THEME, elapsed: 5.0, ascii: true), width: 60))
    assert_includes bar, "="
    assert_includes bar, "-"
    assert_equal ["MERINGUE"], @pane.prose_entries(welcome_state(ascii: true), width: 60).map(&:first).first(1)
    refute_match(/[^\x00-\x7F]/, plain_lines(@pane.rail_segments(state, width: 60)).join, "the rail stays ASCII")
  end

  # Setup is drawn from the viewport every frame, so a resize is a recompute:
  # chrome drops off in a fixed order and the card and exit hint are the last
  # things standing.
  def test_the_screen_recomputes_at_every_size_and_drops_chrome_in_order
    steps = [Onboarding::WELCOME, Onboarding::MODEL, Onboarding::THEME]
    sizes = [[200, 60], [120, 40], [100, 32], [80, 24], [64, 20], [50, 14], [46, 12]]

    sizes.each do |width, height|
      steps.each do |step|
        state = animated_state(step: step, elapsed: 5.0)
        lines = render_frame(state, width: width, height: height, layout: @layout).split("\n")

        assert_equal height, lines.length, "#{width}x#{height} #{step}"
        assert_equal [width], lines.map(&:length).uniq, "#{width}x#{height} #{step}"

        geometry = @layout.onboarding_geometry(state, width: width, height: height)
        assert geometry.key?(:card_y), "#{width}x#{height} always draws the card"
        assert geometry.key?(:hint_y), "#{width}x#{height} always draws the exit hint"
        assert_operator geometry.fetch(:card_x) + geometry.fetch(:card_width), :<=, width
        assert_operator geometry.fetch(:card_y) + geometry.fetch(:card_height), :<=, height
        assert_includes lines.join(" "), "Esc", "#{width}x#{height} #{step} must always name the exit"
      end
    end

    # The order chrome is given up in, largest first.
    assert @layout.onboarding_geometry(animated_state, width: 100, height: 32).key?(:rail_y)
    refute @layout.onboarding_geometry(animated_state, width: 46, height: 12).key?(:rail_y)
    refute @layout.onboarding_geometry(animated_state, width: 46, height: 12).key?(:header_y)
  end

  # Shrinking the terminal under setup closes it with an explanation instead of
  # drawing a modal with no visible box.
  def test_shrinking_below_the_minimum_closes_setup_with_an_explanation
    open_setup
    assert @pane.active?(compose)

    @app.instance_variable_set(:@last_render_height, Onboarding::MIN_TERMINAL_HEIGHT - 1)
    send_key(DOWN)

    refute @pane.active?(compose)
    assert_includes messages_text, "Setup needs a bigger terminal"
    assert_empty @submitted, "closing for size is not an outcome the kernel records"
  end

  # Quitting mid-flow must not leave a previewed theme on screen.
  def test_shutdown_closes_setup_and_restores_a_previewed_theme
    open_setup
    4.times { send_key(ENTER) }
    wait_for_submissions(3)
    send_key(DOWN)
    refute_equal @original_colorscheme, Meringue::TUI::Style.current_colorscheme

    @app.send(:shutdown_workspace_resources)

    refute @pane.active?(compose)
    assert_equal @original_colorscheme, Meringue::TUI::Style.current_colorscheme
  end

  # --- the one spinner ----------------------------------------------------

  # Ctrl-R is the only step that waits on something outside the flow, so it is the
  # only place with a spinner, and the spinner stops on evidence rather than on a
  # timer alone.
  def test_the_refresh_spinner_runs_while_the_catalog_is_stale_and_stops_when_it_changes
    open_setup
    2.times { send_key(ENTER) }
    wait_for_submissions(1)
    send_key(CTRL_R)
    wait_for_submissions(2)

    assert @pane.active?(compose)
    assert_includes card_text, "asking pi for its model list"

    # A different catalog snapshot is the evidence the refresh landed.
    @state = state_with_catalog(catalogs: { "pi" => refreshed_catalog_snapshot })
    refute_includes card_text, "asking pi for its model list"

    # And it gives up rather than spinning forever if nothing ever lands.
    @state = state_with_catalog
    assert_includes card_text, "asking pi for its model list"
    @app.instance_variable_set(:@onboarding_refresh_at, @app.send(:monotonic_time) - Onboarding::REFRESH_SPINNER_SECONDS - 1)
    refute_includes card_text, "asking pi for its model list"
  end

  private

  def build_onboarding_app(config: nil, terminal: nil)
    Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: terminal || TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: config || Meringue::Config.new({}, path: "/nonexistent/meringue-test-config.toml"),
      onboarding_enabled: true
    )
  end

  def config_with(sections)
    Meringue::Config.new(sections, path: "/nonexistent/meringue-test-config.toml", loaded: true)
  end

  def state_with_catalog(catalogs: nil)
    empty_state.merge(
      "metadata" => {
        "active_harness" => "pi",
        "pi_session_defaults" => { "model" => "openai/gpt-5.6-sol", "thinking_level" => "high" },
        "harness_model_catalogs" => catalogs || { "pi" => catalog_snapshot }
      }
    )
  end

  def catalog_snapshot
    Meringue::Harness::ModelCatalog.available(
      harness: "pi",
      models: [
        { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol", "thinking_levels" => %w[off low high] },
        { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5", "thinking_levels" => %w[xhigh max] }
      ],
      source: "test_catalog"
    ).to_h
  end

  # What the kernel writing a fresh catalog looks like from the flow's side.
  def refreshed_catalog_snapshot
    Meringue::Harness::ModelCatalog.available(
      harness: "pi",
      models: [
        { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol", "thinking_levels" => %w[off low high] },
        { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5", "thinking_levels" => %w[xhigh max] },
        { "provider" => "google", "id" => "gemini-4", "name" => "Gemini 4", "thinking_levels" => %w[low high] }
      ],
      source: "test_catalog"
    ).to_h
  end

  # A snapshot built by hand, so animation can be inspected at an exact instant
  # without a clock in the test.
  def animated_state(step: Onboarding::HARNESS, elapsed: 0.0, animated: true, ascii: false, progress_from: nil, index: 0, notice: nil)
    plan = Onboarding.plan("pi")
    snapshot = {
      "active" => true,
      "step" => step,
      "plan" => plan,
      "index" => index,
      "query" => "",
      "harness" => "pi",
      "theme" => "meringue",
      "applied" => { "harness" => "pi" },
      "animated" => animated,
      "ascii" => ascii,
      "elapsed" => elapsed,
      "progress_from" => progress_from || Onboarding.step_fraction(step, plan)
    }
    snapshot["notice"] = notice if notice
    @state.merge(Pane::STATE_KEY => snapshot)
  end

  def welcome_state(ascii: false)
    animated_state(step: Onboarding::WELCOME, elapsed: 5.0, ascii: ascii)
  end

  def visible_row_count(state)
    plain_lines(@layout.onboarding_geometry(state, width: WIDTH, height: HEIGHT).fetch(:card).fetch(:lines))
      .count { |line| !line.strip.empty? }
  end

  def row_line(state, position)
    entries = @pane.rows(state)
    plain_line(
      @pane.card_lines(state, prose: [], visible: entries, window_start: 0, width: 60)[position]
    ).strip
  end

  def card_text
    plain_lines(@layout.onboarding_geometry(compose, width: WIDTH, height: HEIGHT).fetch(:card).fetch(:lines)).join(" ")
  end

  def open_setup
    send_key(ENTER, input_buffer: "/setup")
    compose
  end

  def compose
    compose_app_state(@app, @state)
  end

  def send_key(key, input_buffer: "")
    @app.send(:handle_key, key, input_buffer, input_buffer.length, -1, prompt_handler, compose)
  end

  def prompt_handler
    @prompt_handler ||= lambda do |text, **_options|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
  end

  # Everything a terminal can report through the mouse, including the two events
  # that used to apply a row and dismiss the flow.
  def mouse_events
    position = { "x" => 20, "y" => 12 }
    {
      "a press on a row" => press_event(position),
      "a press on the chrome" => press_event("x" => 4, "y" => 3),
      "a press outside the card" => press_event("x" => 1, "y" => 1),
      "a release" => { "type" => "mouse", "kind" => "button", "pressed" => false, "button" => 0 }.merge(position),
      "a right click" => { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 2 }.merge(position),
      "a middle click" => { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 1 }.merge(position),
      "a drag" => { "type" => "mouse", "kind" => "motion", "pressed" => true, "button" => 32 }.merge(position),
      "a wheel up" => { "type" => "mouse", "kind" => "wheel_up", "pressed" => true, "button" => 64, "count" => 1 }.merge(position),
      "a wheel down" => { "type" => "mouse", "kind" => "wheel_down", "pressed" => true, "button" => 65, "count" => 1 }.merge(position),
      "a double click" => press_event(position),
      "a click on the exit hint" => press_event("x" => 4, "y" => HEIGHT)
    }
  end

  def press_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(stringify(position))
  end

  def paste_event(text)
    { "type" => "paste", "text" => text }
  end

  def messages_text
    @app.instance_variable_get(:@messages).map { |message| message.fetch("text", "") }.join("\n")
  end

  def wait_for_submissions(count)
    deadline = Time.now + 5
    sleep 0.01 while @submitted.length < count && Time.now < deadline
    assert_equal count, @submitted.length, "expected #{count} submitted command(s), got #{@submitted.inspect}"
    @submitted
  end
end
