# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

# Setup must be able to finish without registering a project. Project discovery
# and registration remain available after setup through the normal goal flow.
class TuiSetupHarnessAndProjectTest < Minitest::Test
  include TUISupport

  WIDTH = 100
  HEIGHT = 32
  ENTER = "\r"
  TAB = "\t"
  DOWN = "\e[B"
  UP = "\e[A"
  BACKSPACE = "\u007F"

  def setup
    @tmpdir = Dir.mktmpdir("meringue-setup-harness")
    @config_path = File.join(@tmpdir, "config.toml")
    @config = Meringue::Config.load(path: @config_path)
    @state = empty_state
    @layout = Meringue::TUI::Layout.new
    @submitted = Queue.new
    @handler = lambda do |text|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  # One installed harness is not a choice, it is an answer, so setup fills it in
  # and the step becomes a confirmation.
  def test_a_single_installed_harness_is_preselected_for_both_roles
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup

    draft = @app.instance_variable_get(:@settings_draft)
    assert_equal "claude", draft.value("agent.head_harness")
    assert_equal "claude", draft.value("agent.worker_harness")
  end

  # Several installed backends leave a real decision, and guessing which one
  # someone meant is exactly what the registry refuses to do.
  def test_several_installed_harnesses_are_not_guessed_between
    @app = build_app(availability: availability("claude" => :installed, "codex" => :installed, "pi" => :missing))
    open_setup

    draft = @app.instance_variable_get(:@settings_draft)
    assert_equal "", draft.value("agent.head_harness").to_s
    assert_equal "", draft.value("agent.worker_harness").to_s
  end

  def test_no_installed_harness_still_asks_rather_than_picking_one
    @app = build_app(availability: availability("claude" => :missing, "codex" => :missing, "pi" => :missing))
    open_setup

    assert_equal "", @app.instance_variable_get(:@settings_draft).value("agent.head_harness").to_s
  end

  # The picker used to render the stored id twice ("pi  pi") and say nothing
  # about whether the machine could run it.
  def test_the_harness_picker_names_products_and_reports_what_is_installed
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER) # Welcome -> Harness

    # The step reports what is selected; the picker is where the alternatives
    # and their availability are listed.
    frame = render
    assert_includes frame, "Harness  Claude Code · installed"
    refute_includes frame, "Harness  claude "
    refute_includes frame, "Head harness", "setup asks once, so the row does not carry a role"
    refute_includes frame, "Worker harness"

    focus_setup_row("agent.head_harness")
    send_key(ENTER)
    names = snapshot.fetch("picker").fetch("options").map { |option| option.fetch("name") }
    assert_includes names, "Claude Code · installed"
    assert_includes names, "Codex CLI · not found"
    # A required field must not offer "nothing chosen" as its first row.
    refute_includes names, ""
    assert_equal Meringue::Harness::Registry::PROVIDERS.length, names.length
  end

  # An unavailable backend is never hidden: someone may be configuring a machine
  # they are about to install it on.
  def test_an_uninstalled_harness_stays_selectable
    @app = build_app(availability: availability("claude" => :installed, "codex" => :missing, "pi" => :missing))
    open_setup
    send_key(ENTER)
    focus_setup_row("agent.head_harness")
    send_key(ENTER)

    picker = snapshot.fetch("picker")
    index = picker.fetch("options").index { |option| option.fetch("reference") == "codex" }
    refute_nil index
    @app.instance_variable_get(:@settings_picker)["index"] = index
    send_key(ENTER)

    assert_equal "codex", @app.instance_variable_get(:@settings_draft).value("agent.worker_harness")
  end

  # Choosing a harness means "run Meringue on this", not "run heads on this".
  def test_choosing_one_role_fills_the_other_while_it_is_still_unset
    @app = build_app(availability: availability("claude" => :installed, "codex" => :installed, "pi" => :missing))
    open_setup
    send_key(ENTER)
    focus_setup_row("agent.head_harness")
    send_key(ENTER)
    send_key(ENTER) # take the first entry

    draft = @app.instance_variable_get(:@settings_draft)
    chosen = draft.value("agent.head_harness")
    refute_empty chosen.to_s
    assert_equal chosen, draft.value("agent.worker_harness")
  end

  # Setup shows one row, so a partner left behind at an older value would be a
  # split nobody asked for and cannot see. /config is where roles are split.
  def test_one_choice_sets_both_roles_even_when_one_already_had_a_value
    @app = build_app(availability: availability("claude" => :installed, "codex" => :installed, "pi" => :missing))
    open_setup
    draft = @app.instance_variable_get(:@settings_draft)
    draft.set("agent.worker_harness", "codex")

    send_key(ENTER)
    focus_setup_row("agent.head_harness")
    send_key(ENTER)
    choose_picker_entry("claude")

    assert_equal "claude", draft.value("agent.head_harness")
    assert_equal "claude", draft.value("agent.worker_harness")
  end

  # Clicking an option used to take a shorter path than pressing Enter on it and
  # skipped the harness mirror, so a first run driven by the mouse set one role
  # and left the other empty.
  def test_clicking_a_harness_sets_both_roles_the_way_the_key_does
    @app = build_app(availability: availability("claude" => :installed, "codex" => :installed, "pi" => :missing))
    open_setup
    send_key(ENTER)
    focus_setup_row("agent.head_harness")
    send_key(ENTER)
    draft = @app.instance_variable_get(:@settings_draft)
    options = @app.send(:settings_picker_options)
    wanted = options.index { |option| option.fetch("reference") == "codex" }
    refute_nil wanted

    click_settings_hit([:picker, wanted])

    assert_equal "codex", draft.value("agent.head_harness")
    assert_equal "codex", draft.value("agent.worker_harness")
  end

  # Locating an executable and running it are different questions.
  def test_the_harness_check_reports_what_the_probe_answered
    probes = { "claude" => { "status" => "runnable", "detail" => "claude 1.2.3" } }
    @app = build_app(
      availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing),
      probe: ->(provider) { probes.fetch(provider) }
    )
    open_setup
    send_key(ENTER)
    focus_setup_row("setup.check_harness")
    send_key(ENTER)

    row = snapshot.fetch("rows").find { |candidate| candidate.fetch("id") == "setup.check_harness" }
    assert_equal "ready", row.fetch("display_value")
    assert_includes row.fetch("description"), "claude 1.2.3"
    assert_includes render, "ready"
  end

  def test_a_harness_that_does_not_run_is_reported_as_not_ready
    @app = build_app(
      availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing),
      probe: ->(_provider) { { "status" => "failed", "detail" => "not authenticated" } }
    )
    open_setup
    send_key(ENTER)
    focus_setup_row("setup.check_harness")
    send_key(ENTER)

    row = snapshot.fetch("rows").find { |candidate| candidate.fetch("id") == "setup.check_harness" }
    assert_equal "not ready", row.fetch("display_value")
    assert_includes row.fetch("description"), "not authenticated"
  end

  def test_the_check_asks_for_a_harness_before_running_anything
    ran = []
    @app = build_app(
      availability: availability("claude" => :installed, "codex" => :installed, "pi" => :missing),
      probe: ->(provider) { ran << provider; { "status" => "runnable", "detail" => "ok" } }
    )
    open_setup
    send_key(ENTER)
    focus_setup_row("setup.check_harness")
    send_key(ENTER)

    assert_empty ran
    row = snapshot.fetch("rows").find { |candidate| candidate.fetch("id") == "setup.check_harness" }
    assert_equal "pick one first", row.fetch("display_value")
  end

  # The model picker cannot be answered during a first run anyway: its list comes
  # from a catalog the harness reports once a session has run, so on a fresh
  # install it is empty by construction and the only entry is the default that
  # was already selected. Both settings live in /config, where the catalog is.
  def test_model_and_reasoning_are_not_part_of_setup
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER)

    ids = snapshot.fetch("rows").map { |row| row.fetch("id") }
    assert_equal %w[agent.head_harness workspace.editor setup.check_harness], ids
    refute_includes ids, "_show_advanced"
  end

  # The role suffix was stripped with /_model\\z/ — a literal backslash and a z
  # rather than the end anchor — so the head model row resolved its catalog
  # through the worker harness.
  def test_the_model_row_resolves_its_catalog_through_its_own_role
    @app = build_app(availability: availability("claude" => :installed, "pi" => :installed, "codex" => :missing))
    @app.send(:open_settings, @state)
    draft = @app.instance_variable_get(:@settings_draft)
    draft.set("agent.head_harness", "claude")
    draft.set("agent.worker_harness", "pi")

    assert_equal "claude", @app.send(:settings_model_harness, @state, role: "head")
    assert_equal "pi", @app.send(:settings_model_harness, @state, role: "worker")
  end

  # Going back to re-read something is not a way to dodge the requirement, so it
  # is never gated.
  def test_the_gate_does_not_block_going_backwards
    @app = build_app(availability: availability("claude" => :installed, "codex" => :installed, "pi" => :installed))
    open_setup
    send_key(ENTER)
    assert_equal "Harness", snapshot.fetch("category")

    send_key(TAB)
    assert_equal "Harness", snapshot.fetch("category"), "forward is refused without a harness"

    send_key(BACKSPACE)
    assert_equal "Welcome", snapshot.fetch("category")
  end

  # Setup completes with no registered project; discovery and registration happen
  # later when the first goal is routed.
  def test_finishing_setup_saves_once_without_registering_a_project
    @app = build_app(
      availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing),
      handler: accepting_handler
    )
    open_setup
    complete_setup

    commands = drain_submitted
    assert_equal 1, commands.length, commands.inspect
    assert commands.first.start_with?("/config save "), commands.first
    assert_empty @state.fetch("projects")
  end

  # The last card is what makes Complete checkable rather than hopeful.
  def test_the_final_card_states_that_projects_can_be_added_later
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER)
    4.times { send_key(TAB) }
    assert_equal "Done", snapshot.fetch("category")

    frame = render
    assert_includes frame, "Harness: Claude Code"
    refute_includes frame, "for heads and workers", "setup asks once, so the summary does not split roles"
    assert_includes frame, "Xtras: all off"
    assert_includes frame, "[ Complete ]"
  end

  def test_project_prompt_guidance_wraps_at_supported_terminal_widths
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER)
    4.times { send_key(TAB) }

    [100, 79, 46, 32].each do |width|
      frame = render(width: width, height: 24)
      assert_includes frame, "Send a prompt"
      normalized = frame.gsub("│", " ").gsub(/\s+/, " ")
      assert_includes normalized, Meringue::TUI::Onboarding::PROMPT_GUIDANCE
      frame.lines.each { |line| assert_operator line.chomp.length, :<=, width, "#{width}: #{line.inspect}" }
    end
  end

  # PR #306 squash-merged from a branch state that predated its last commit, so
  # main shipped a navigation action that never showed when it had focus.
  def test_the_navigation_action_shows_when_it_is_focused
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup

    focused = @layout.send(:settings_pane).action_segments(compose)
    assert_equal ["› [ Begin ] ‹"], focused.map(&:first), "Welcome has no rows, so its action is focused"
    assert_includes render, "› [ Begin ] ‹"

    send_key(ENTER) # Harness, which does have rows
    unfocused = @layout.send(:settings_pane).action_segments(compose)
    assert_equal ["[ Next ]"], unfocused.map(&:first)

    snapshot.fetch("rows").length.times { send_key(DOWN) }
    assert snapshot.fetch("footer_focus")
    assert_equal ["› [ Next ] ‹"], @layout.send(:settings_pane).action_segments(compose).map(&:first)
  end

  # Two things reading as selected at once left it ambiguous what Enter would do,
  # because the row index is deliberately kept so arrowing back returns to it.
  def test_focusing_the_action_deselects_the_list
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER) # Harness
    focus_setup_row("agent.head_harness")

    assert_equal 1, render.scan("\u203a").length, "the selected row carries the only marker"
    assert_includes render, "\u00b7 Enter open picker"

    snapshot.fetch("rows").length.times { send_key(DOWN) }
    assert snapshot.fetch("footer_focus")
    focused = render
    assert_equal 1, focused.scan("\u203a").length, "the action carries the only marker"
    assert_includes focused, "\u203a [ Next ] \u2039"
    refute_includes focused, "\u00b7 Enter open picker", "no row offers its control while the action has focus"
  end

  # Deselecting the list must not lose the place in it.
  def test_arrowing_back_off_the_action_returns_to_the_row_it_left
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER)
    last = snapshot.fetch("rows").length - 1
    snapshot.fetch("rows").length.times { send_key(DOWN) }
    assert snapshot.fetch("footer_focus")

    send_key(UP)
    refute snapshot.fetch("footer_focus")
    assert_equal last, @app.instance_variable_get(:@settings_row_index)
  end

  # The slot that describes the selected row cannot go on describing one once
  # nothing is selected, and emptying it would reflow the card as focus lands.
  def test_the_description_follows_focus_onto_the_action
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER)
    focus_setup_row("agent.head_harness")
    before = render.lines.length

    snapshot.fetch("rows").length.times { send_key(DOWN) }

    assert_includes render, "Next: #{Meringue::TUI::Settings::SetupFlow::THEME}."
    assert_equal before, render.lines.length, "the card must not reflow as focus lands on the action"
  end

  # The markers carry the state when color is off, and stay ASCII-safe.
  def test_the_focused_action_survives_ascii_glyph_mode
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup

    with_env("MERINGUE_ASCII_GLYPHS" => "1") do
      assert_equal ["> [ Begin ] <"], @layout.send(:settings_pane).action_segments(compose).map(&:first)
    end
  end

  # The app turns on kitty CSI-u and xterm modifyOtherKeys at startup, and the
  # point of both is that Escape stops arriving as a bare \e. Binding only the
  # bare byte left it dead: a picker could be opened and not closed.
  def test_escape_closes_a_picker_in_every_encoding_a_terminal_may_send
    ["\e", "\e[27u", "\e[27;1u", "\e[27;1~", "\e[27;1;27~"].each do |encoding|
      @app = build_app(availability: availability("claude" => :installed, "pi" => :installed, "codex" => :missing))
      open_setup
      send_key(ENTER)
      focus_setup_row("agent.head_harness")
      send_key(ENTER)
      refute_nil @app.instance_variable_get(:@settings_picker), "picker did not open"

      send_key(encoding)

      assert_nil @app.instance_variable_get(:@settings_picker), "#{encoding.inspect} did not close the picker"
    end
  end

  private

  def availability(statuses)
    statuses.to_h do |provider, kind|
      status = kind == :installed ? Meringue::Harness::Availability::INSTALLED : Meringue::Harness::Availability::MISSING
      [provider, { "status" => status, "executable" => provider }]
    end
  end

  def build_app(availability:, probe: nil, handler: nil)
    @handler = handler if handler
    Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: @config,
      onboarding_enabled: true,
      harness_availability_provider: -> { availability },
      harness_probe: probe
    )
  end

  def accepting_handler
    lambda do |text|
      @submitted << text
      {
        "event" => "slash_command_applied",
        "command_results" => [{
          "command_type" => text.start_with?("/config save") ? "SaveConfiguration" : "AddProject",
          "status" => "accepted",
          "message" => "ok",
          "result" => { "onboarding_outcome" => "completed" }
        }]
      }
    end
  end

  def rejecting_handler
    lambda do |text|
      @submitted << text
      {
        "event" => "slash_command_applied",
        "command_results" => [{
          "command_type" => "SaveConfiguration",
          "status" => "rejected",
          "message" => "Configuration changed on disk after Settings opened.",
          "result" => { "field_errors" => { "_stale" => "Reopen setup." } }
        }]
      }
    end
  end

  # A real checkout, so the candidate comes from the same git-root walk the
  # heads use rather than a stub.
  def in_repository
    Dir.mktmpdir("meringue-setup-repo") do |dir|
      root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(root, ".git"))
      File.write(File.join(root, "README.md"), "# Sample Product\n\nA fixture.\n")
      Dir.chdir(root) { yield root, "Sample Product" }
    end
  end

  # A rejected save deliberately keeps setup open, so completion is "the save
  # finished", not "the overlay closed".
  def complete_setup
    send_key(ENTER) # Welcome -> Harness
    4.times { send_key(TAB) }
    assert_equal "Done", snapshot.fetch("category")
    send_key(ENTER)
    wait_until { !@app.instance_variable_get(:@settings_saving) }
  end

  def open_setup
    send_key(ENTER, input_buffer: "/setup")
    assert_equal "setup", snapshot.fetch("mode")
  end

  def focus_setup_row(id)
    index = snapshot.fetch("rows").index { |row| row.fetch("id") == id }
    refute_nil index, "no #{id} row in #{snapshot.fetch("rows").map { |row| row.fetch("id") }.inspect}"
    @app.instance_variable_set(:@settings_row_index, index)
    @app.instance_variable_set(:@settings_footer_focus, false)
  end

  # Drives a real click through the same hit testing the app uses, so the test
  # exercises the mouse path rather than the method behind it.
  def click_settings_hit(target)
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        next unless @app.send(:layout).settings_hit(compose, width: WIDTH, height: HEIGHT, x: x, y: y) == target

        return send_key({ "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0, "x" => x + 1, "y" => y + 1 })
      end
    end
    flunk("no cell resolved to #{target.inspect}")
  end

  def choose_picker_entry(reference)
    picker = @app.instance_variable_get(:@settings_picker)
    index = snapshot.fetch("picker").fetch("options").index { |option| option.fetch("reference") == reference }
    refute_nil index
    picker["index"] = index
    send_key(ENTER)
  end

  def send_key(key, input_buffer: "")
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    @app.send(:handle_key, key, input_buffer, input_buffer.length, -1, @handler, compose)
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

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(0.01) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, "condition was not met within #{timeout}s"
  end

  def drain_submitted
    values = []
    values << @submitted.pop(true) while true
  rescue ThreadError
    values
  end
end
