# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# First-run setup: a new user used to land on two empty boxes with `/harness`,
# `/model`, `/thinking` and `/theme` undiscoverable. The flow walks them through
# those four choices on a screen it owns outright.
#
# This file covers the flow itself: what each step submits, skip/back/resume, the
# theme-first preview, mouse clicks on options, and the degraded-catalog paths.
# The full-screen geometry, animation, and empty-space click behavior are covered
# in onboarding_screen_test.rb.
#
# The invariants pinned down here are the ones that make it safe: it applies
# every choice as the ordinary slash command for it (so the kernel stays the only
# writer), it is skippable at every step, it never dead-ends on a missing model
# catalog, and it never opens a second time once the marker is recorded.
class TuiOnboardingTest < Minitest::Test
  include TUISupport

  Onboarding = Meringue::TUI::Onboarding
  Pane = Meringue::TUI::Panes::OnboardingPane
  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT
  DOWN = "\e[B"
  UP = "\e[A"
  LEFT = "\e[D"
  ESC = "\e"
  ENTER = "\r"
  CTRL_R = "\u0012"

  def setup
    @submitted = []
    @layout = Meringue::TUI::Layout.new
    @original_colorscheme = Meringue::TUI::Style.current_colorscheme
    @app = build_onboarding_app
    @pane = Pane.new
    @state = state_with_catalog
  end

  def teardown
    wait_for_submissions(@submitted.length)
    Meringue::TUI::Style.configure!(@original_colorscheme)
  end

  # --- first-run detection ------------------------------------------------

  def test_a_first_run_opens_setup_and_a_recorded_marker_does_not
    assert @app.send(:onboarding_autostart?), "a config with no marker is a first run"

    completed = build_onboarding_app(config: config_with(onboarding: { "completed_version" => Meringue::Config::ONBOARDING_VERSION }))
    refute completed.send(:onboarding_autostart?), "a recorded marker must not re-onboard"

    skipped = build_onboarding_app(
      config: config_with(onboarding: { "completed_version" => Meringue::Config::ONBOARDING_VERSION, "outcome" => "skipped" })
    )
    refute skipped.send(:onboarding_autostart?), "skipping is also a recorded outcome"

    # A future revision of the flow can replay setup without a second key.
    older = build_onboarding_app(config: config_with(onboarding: { "completed_version" => 0 }))
    assert older.send(:onboarding_autostart?)
  end

  # A config file is not itself evidence of a returning user: README tells new
  # users to copy the example config before their first launch.
  def test_an_existing_config_without_the_marker_is_still_a_first_run
    app = build_onboarding_app(config: config_with(tui: { "colorscheme" => "gruvbox" }))

    assert app.send(:onboarding_autostart?)
  end

  # `meringue demo` has no kernel behind it, so no choice could be applied.
  def test_setup_never_opens_without_a_kernel
    demo = build_onboarding_app(onboarding_enabled: false)

    refute demo.send(:onboarding_autostart?)

    demo.send(:handle_key, ENTER, "/setup", 6, -1, prompt_handler, compose_app_state(demo, @state))
    refute @pane.active?(compose_app_state(demo, @state))
    assert_includes messages_text(demo), "Setup needs a live kernel"
  end

  def test_setup_does_not_auto_open_on_a_terminal_too_small_for_the_screen
    short = build_onboarding_app(terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: Onboarding::MIN_TERMINAL_HEIGHT - 1))

    refute short.send(:onboarding_autostart?)
    refute short.send(:maybe_open_onboarding, -> { @state })
    refute @pane.active?(compose_app_state(short, @state))

    narrow = build_onboarding_app(terminal: TUISupport::FakeTerminal.new(width: Onboarding::MIN_TERMINAL_WIDTH - 1, height: HEIGHT))

    refute narrow.send(:onboarding_autostart?)
  end

  # Launching is what opens setup on a first run; nothing else has to be typed.
  def test_launching_opens_setup_once_and_never_again_after_the_marker
    @app.send(:maybe_open_onboarding, -> { @state })

    assert @pane.active?(compose)
    assert_empty @submitted, "opening setup must not send anything to the kernel"

    completed = build_onboarding_app(config: config_with(onboarding: { "completed_version" => Meringue::Config::ONBOARDING_VERSION }))
    refute completed.send(:maybe_open_onboarding, -> { @state })
    refute @pane.active?(compose_app_state(completed, @state))
  end

  # A non-interactive stdin renders one frame and exits, so setup cannot open.
  def test_a_non_interactive_run_renders_once_without_setup
    out = StringIO.new
    app = Meringue::TUI::App.new(
      layout: @layout,
      out: out,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      onboarding_enabled: true
    )

    assert_equal 0, app.run(state: @state)
    refute_includes out.string, "setup · welcome"
  end

  # --- the flow -----------------------------------------------------------

  def test_the_welcome_screen_explains_the_product_and_names_the_exit
    state = open_setup

    assert @pane.active?(state)
    assert_equal "setup · welcome", @pane.title(state)
    body = card_lines(state).join(" ")
    assert_includes body, "many coding agents at once"
    assert_includes body, "4 quick choices"
    assert_includes body, "pick a theme first"
    assert_equal ["begin"], row_values

    line = caption(state)
    assert_includes line, "Enter/click begins"
    assert_includes line, "Esc skips setup (/setup reopens it)"

    frame = render_frame(state, width: WIDTH, height: HEIGHT)
    assert_includes frame, "setup · welcome"
    # Setup owns the screen: the dashboard behind it is not drawn at all.
    refute_includes frame, "agent tree"
  end

  def test_holding_enter_accepts_every_current_default_through_the_kernel_commands
    open_setup
    5.times { send_key(ENTER) }

    assert_equal(
      [
        "/theme meringue",
        "/harness pi",
        "/model openai/gpt-5.6-sol",
        "/thinking high",
        "/setup complete"
      ],
      wait_for_submissions(5)
    )
    refute @pane.active?(compose)
  end

  def test_each_step_applies_its_own_setting_and_advances
    open_setup
    send_key(ENTER)

    assert_equal "setup · 1/4 · theme", @pane.title(compose)
    assert_equal Meringue::TUI::Style.colorschemes, row_values
    send_key(ENTER)
    assert_equal ["/theme meringue"], wait_for_submissions(1)

    assert_equal "setup · 2/4 · harness", @pane.title(compose)
    assert_equal %w[pi claude antigravity], row_values
    send_key(ENTER)
    assert_equal ["/theme meringue", "/harness pi"], wait_for_submissions(2)

    assert_equal "setup · 3/4 · model (pi)", @pane.title(compose)
    send_key(DOWN)
    send_key(ENTER)
    assert_equal ["/theme meringue", "/harness pi", "/model anthropic/claude-opus-5"], wait_for_submissions(3)

    # Every level the kernel accepts is offered; the catalog labels them instead
    # of filtering the ladder.
    assert_equal "setup · 4/4 · thinking", @pane.title(compose)
    assert_equal Meringue::Harness::PiClient::THINKING_LEVELS.sort, row_values.sort
    send_key(ENTER)

    assert_equal(
      ["/theme meringue", "/harness pi", "/model anthropic/claude-opus-5", "/thinking high", "/setup complete"],
      wait_for_submissions(5)
    )
  end

  def test_choosing_a_non_pi_harness_drops_the_pi_only_steps_and_finishes_after_theme
    open_setup
    send_key(ENTER)
    send_key(ENTER)
    assert_equal "setup · 2/4 · harness", @pane.title(compose)

    send_key(DOWN)
    send_key(ENTER)

    assert_equal ["/theme meringue", "/harness claude", "/setup complete"], wait_for_submissions(3)
    refute @pane.active?(compose)
    assert_includes messages_text, "harness claude"
    assert_includes messages_text, "Model and thinking defaults apply to Pi sessions only today."
  end

  def test_the_finish_card_reports_the_settings_and_teaches_the_core_loop
    open_setup
    5.times { send_key(ENTER) }
    wait_for_submissions(5)

    card = messages_text
    assert_includes card, "✓ Setup complete."
    assert_includes card, "harness pi · model openai/gpt-5.6-sol · thinking high · theme meringue"
    assert_includes card, "plain English"
    assert_includes card, "AgentTree"
    assert_includes card, "/keybind"
    # Nothing in the flow may advertise a command that no longer exists.
    refute_includes card, "/rename"
    refute_includes card, "/session-settings"
  end

  # --- skip, back, resume -------------------------------------------------

  def test_escape_exits_at_every_step_keeping_what_was_already_applied
    applied = ["/theme meringue", "/harness pi", "/model openai/gpt-5.6-sol", "/thinking high"]
    Onboarding.plan("pi").each_with_index do |_step, index|
      restart_app
      open_setup
      # The first Enter leaves the welcome screen; every later one applies a step.
      index.times { send_key(ENTER) }
      send_key(ESC)

      refute @pane.active?(compose), "Esc must exit from step #{index}"
      expected = applied.first([index - 1, 0].max)
      assert_equal expected + ["/setup skip"], wait_for_submissions(expected.length + 1)
      assert_includes messages_text, "Setup skipped — run /setup any time."
    end
  end

  def test_back_returns_to_the_previous_step_without_un_applying_anything
    open_setup
    send_key(ENTER)
    send_key(ENTER)
    assert_equal "setup · 2/4 · harness", @pane.title(compose)

    send_key(LEFT)
    assert_equal "setup · 1/4 · theme", @pane.title(compose)
    # Back is not an undo: there is no inverse kernel command, and the finish card
    # reports what is really in effect.
    assert_equal ["/theme meringue"], wait_for_submissions(1)

    # Back on the first screen is a no-op rather than a way to fall out of setup.
    send_key(LEFT)
    send_key(LEFT)
    assert @pane.active?(compose)
    assert_equal "setup · welcome", @pane.title(compose)
  end

  def test_slash_setup_reopens_the_flow_from_the_first_step
    open_setup
    send_key(ESC)
    wait_for_submissions(1)
    refute @pane.active?(compose)

    state = open_setup
    assert @pane.active?(state)
    assert_equal "setup · welcome", @pane.title(state)
    # Reopening reads state only: nothing else was submitted.
    assert_equal ["/setup skip"], @submitted
  end

  def test_the_flow_is_advertised_as_a_command_and_never_needs_an_id
    usages = Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first)
    assert_includes usages, "/setup"
    assert_includes Meringue::Kernel::Engine::HELP_COMMANDS.map(&:first), "/setup"
    assert @app.send(:local_navigation_command_without_id?, "/setup")
  end

  # --- theme preview ------------------------------------------------------

  def test_moving_the_theme_highlight_previews_live_and_persists_nothing_until_enter
    open_setup
    send_key(ENTER)
    assert_equal "setup · 1/4 · theme", @pane.title(compose)
    assert_equal @original_colorscheme, Meringue::TUI::Style.current_colorscheme

    send_key(DOWN)
    previewed = Meringue::TUI::Style.current_colorscheme
    refute_equal @original_colorscheme, previewed
    # Previewing is a live repaint, not a write: no /theme was submitted yet.
    assert_empty @submitted

    send_key(ENTER)
    assert_equal ["/theme #{previewed}"], wait_for_submissions(1)
    assert_equal previewed, Meringue::TUI::Style.current_colorscheme,
                 "the rest of setup should render in the selected theme"
    assert_equal "setup · 2/4 · harness", @pane.title(compose)
  end

  def test_leaving_the_theme_step_restores_the_theme_that_was_saved
    open_setup
    send_key(ENTER)
    send_key(DOWN)
    refute_equal @original_colorscheme, Meringue::TUI::Style.current_colorscheme

    send_key(LEFT)
    assert_equal @original_colorscheme, Meringue::TUI::Style.current_colorscheme, "back must undo a preview"

    send_key(ENTER)
    send_key(DOWN)
    send_key(ESC)
    assert_equal @original_colorscheme, Meringue::TUI::Style.current_colorscheme, "Esc must undo a preview"
    assert_equal ["/setup skip"], wait_for_submissions(1)
  end

  # --- degraded model catalog ---------------------------------------------

  def test_a_missing_catalog_explains_itself_and_still_offers_a_row
    @state = state_with_catalog(catalogs: {})
    open_setup
    3.times { send_key(ENTER) }
    wait_for_submissions(2)

    lines = card_lines
    assert_includes lines.join(" "), "has not fetched pi's model list yet"
    # The sentinel names the default that stays in effect, so "keep" is never vague.
    assert_equal ["▸ keep the default  openai/gpt-5.6-sol · Ctrl-R asks pi for its model list"], lines.last(1)

    # Enter on the sentinel changes nothing and still moves the flow along, so a
    # slow catalog can never trap the user on this step.
    send_key(ENTER)
    assert_equal ["/theme meringue", "/harness pi"], @submitted
    assert_equal "setup · 4/4 · thinking", @pane.title(compose)
  end

  def test_an_unavailable_or_unsupported_catalog_says_why
    unavailable = Meringue::Harness::ModelCatalog.unavailable(harness: "pi", note: "pi rpc get_available_models timed out")
    @state = state_with_catalog(catalogs: { "pi" => unavailable.to_h })
    open_setup
    3.times { send_key(ENTER) }
    wait_for_submissions(2)

    assert_includes card_lines.join(" "), "pi model catalog unavailable"
    assert_includes card_lines.join(" "), "timed out"

    restart_app
    unsupported = Meringue::Harness::ModelCatalog.unsupported(harness: "pi").to_h
    @state = state_with_catalog(catalogs: { "pi" => unsupported })
    open_setup
    3.times { send_key(ENTER) }
    wait_for_submissions(2)

    assert_includes card_lines.join(" "), "does not expose a model catalog"
  end

  def test_a_stale_catalog_is_still_listed_in_full
    stale = Meringue::Harness::ModelCatalog.retained(
      previous: Meringue::Harness::ModelCatalog.from_h(catalog_snapshot),
      failure: Meringue::Harness::ModelCatalog.unavailable(harness: "pi", note: "refresh failed")
    )
    @state = state_with_catalog(catalogs: { "pi" => stale.to_h })
    open_setup
    3.times { send_key(ENTER) }
    wait_for_submissions(2)

    assert_equal %w[openai/gpt-5.6-sol anthropic/claude-opus-5], row_values
  end

  def test_typing_filters_the_model_step_and_ctrl_r_asks_the_kernel_to_refresh
    open_setup
    3.times { send_key(ENTER) }
    wait_for_submissions(2)

    "opus".each_char { |character| send_key(character) }
    assert_equal ["anthropic/claude-opus-5"], row_values
    assert_includes caption, "filter: opus"

    "zzz".each_char { |character| send_key(character) }
    assert_includes card_lines.join(" "), "No pi model matches"
    assert_equal ["keep the default"], row_labels

    send_key("\u0017")
    assert_equal 2, row_values.length

    # Refreshing stays a kernel command, and the flow stays open while it runs.
    send_key(CTRL_R)
    assert_equal ["/theme meringue", "/harness pi", "/models pi refresh"], wait_for_submissions(3)
    assert @pane.active?(compose)
  end

  # Reading the flow must never start a harness process or ask for a catalog.
  def test_stepping_through_the_flow_reads_state_only
    provider = TUISupport::RecordingStateProvider.new(@state)
    @app.send(:handle_key, ENTER, "/setup", 6, -1, prompt_handler, compose_app_state(@app, provider))
    4.times { @app.send(:handle_key, ENTER, "", 0, -1, prompt_handler, compose_app_state(@app, provider)) }

    submitted = wait_for_submissions(3)
    refute submitted.any? { |text| text.include?("refresh") }, submitted.inspect
    assert_equal provider.original_state, provider.call
  end

  # --- keys and mouse -----------------------------------------------------

  def test_typing_on_a_choice_step_does_not_leak_into_the_composer
    open_setup
    buffer, cursor, = @app.send(:handle_key, "x", "", 0, -1, prompt_handler, compose)

    assert_equal "", buffer
    assert_equal 0, cursor
    assert @pane.active?(compose)
  end

  # Ctrl-C must still clear/quit while a modal is up, so the flow is never a trap.
  def test_unowned_keys_pass_through_to_normal_handling
    open_setup
    result = @app.send(:handle_key, "\t", "", 0, -1, prompt_handler, compose)

    refute_nil result
    assert @pane.active?(compose), "an unowned key must not silently close setup"
  end

  # The regression this flow was reworked for: a click-away used to dismiss setup,
  # so one stray click during a first launch silently skipped onboarding. Now only
  # visible option rows are live, and clicking one applies exactly that option.
  def test_clicking_visible_rows_advances_and_applies_options
    open_setup

    send_key(press_event(onboarding_row_position(0)))
    assert @pane.active?(compose)
    assert_equal "setup · 1/4 · theme", @pane.title(compose)
    assert_empty @submitted, "the welcome row only begins the flow"

    selected_theme = row_values.fetch(1)
    send_key(press_event(onboarding_row_position(1)))
    assert_equal ["/theme #{selected_theme}"], wait_for_submissions(1)
    assert_equal selected_theme, Meringue::TUI::Style.current_colorscheme
    assert_equal "setup · 2/4 · harness", @pane.title(compose)

    send_key(press_event("x" => 3, "y" => 3))
    assert @pane.active?(compose)
    assert_equal "setup · 2/4 · harness", @pane.title(compose)
    assert_equal ["/theme #{selected_theme}"], @submitted, "empty-space clicks must not submit anything"
  end

  # --- view model ---------------------------------------------------------

  def test_the_view_model_falls_back_to_built_in_defaults_before_state_has_metadata
    fresh = empty_state

    assert_equal "pi", Onboarding.harness_for(fresh)
    assert_equal %w[welcome theme harness model thinking], Onboarding.plan(Onboarding.harness_for(fresh))
    assert_equal(
      Meringue::Harness::Registry::DEFAULT_PI_MODEL,
      Onboarding.rows(fresh, step: "model", harness: "pi").fetch(0).fetch("value")
    )
    assert_equal(
      Meringue::Harness::Registry::DEFAULT_PI_THINKING_LEVEL,
      Onboarding.rows(fresh, step: "thinking", harness: "pi").fetch(0).fetch("value")
    )
    # Each step starts on the value already in effect, which is what makes
    # "hold Enter" a safe way through the flow.
    Onboarding.choice_steps(Onboarding.plan("pi")).each do |step|
      rows = Onboarding.rows(fresh, step: step, harness: "pi", saved_theme: "meringue")
      assert rows.fetch(Onboarding.default_index(fresh, step: step, harness: "pi", saved_theme: "meringue")).fetch("current"),
             "#{step} must preselect the current value"
    end
  end

  private

  def build_onboarding_app(config: nil, onboarding_enabled: true, terminal: nil)
    Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: terminal || TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: config || Meringue::Config.new({}, path: "/nonexistent/meringue-test-config.toml"),
      onboarding_enabled: onboarding_enabled
    )
  end

  # In-memory config only: no test may read or write ~/.meringue.
  def config_with(sections)
    Meringue::Config.new(sections, path: "/nonexistent/meringue-test-config.toml", loaded: true)
  end

  def restart_app
    wait_for_submissions(@submitted.length)
    Meringue::TUI::Style.configure!(@original_colorscheme)
    @submitted = []
    @app = build_onboarding_app
  end

  def state_with_catalog(catalogs: nil, active_harness: "pi", default_model: "openai/gpt-5.6-sol")
    empty_state.merge(
      "metadata" => {
        "active_harness" => active_harness,
        "pi_session_defaults" => { "model" => default_model, "thinking_level" => "high" },
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

  def rows
    @pane.rows(compose)
  end

  def row_values
    rows.map { |row| row.fetch("value") }
  end

  def row_labels
    rows.map { |row| row.fetch("label") }
  end

  def messages_text(app = @app)
    app.instance_variable_get(:@messages).map { |message| message.fetch("text", "") }.join("\n")
  end

  # Slash submissions run on a background thread, exactly as typed ones do.
  def wait_for_submissions(count)
    deadline = Time.now + 5
    sleep 0.01 while @submitted.length < count && Time.now < deadline
    assert_equal count, @submitted.length, "expected #{count} submitted command(s), got #{@submitted.inspect}"
    @submitted
  end

  def press_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(stringify(position))
  end

  def onboarding_row_position(index, state = compose)
    view = geometry(state)
    card = view.fetch(:card)
    window = card.fetch(:window)
    x = view.fetch(:card_x) + 3
    y = view.fetch(:card_y) + 1 + card.fetch(:row_start) + index.to_i - window.fetch("start")
    { "x" => x + 1, "y" => y + 1 }
  end

  # The card as the layout really sizes it for this terminal, so the assertions
  # read the same rows the user would see.
  def geometry(state = compose, width: WIDTH, height: HEIGHT)
    @layout.onboarding_geometry(state, width: width, height: height)
  end

  def card_lines(state = compose)
    plain_lines(geometry(state).fetch(:card).fetch(:lines)).map(&:rstrip)
  end

  def caption(state = compose)
    view = geometry(state)
    plain_line(@pane.caption_segments(state, window: view.fetch(:card).fetch(:window), width: view.fetch(:card_width) - 2))
  end
end
