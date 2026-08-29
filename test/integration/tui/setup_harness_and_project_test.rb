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
    assert_includes frame, "Head harness  Claude Code · installed"
    refute_includes frame, "Head harness  claude "

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
    focus_setup_row("agent.worker_harness")
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

  def test_a_role_already_chosen_is_never_overwritten_by_the_other
    @app = build_app(availability: availability("claude" => :installed, "codex" => :installed, "pi" => :missing))
    open_setup
    draft = @app.instance_variable_get(:@settings_draft)
    draft.set("agent.worker_harness", "codex")

    send_key(ENTER)
    focus_setup_row("agent.head_harness")
    send_key(ENTER)
    choose_picker_entry("claude")

    assert_equal "claude", draft.value("agent.head_harness")
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

  # Model and reasoning have per-harness defaults that work, so they stay one
  # keystroke away instead of sitting between a new user and a working install.
  def test_model_and_reasoning_are_behind_one_reveal
    @app = build_app(availability: availability("claude" => :installed, "pi" => :missing, "codex" => :missing))
    open_setup
    send_key(ENTER)

    ids = snapshot.fetch("rows").map { |row| row.fetch("id") }
    refute_includes ids, "agent.head_model"
    assert_includes ids, "_show_advanced"

    focus_setup_row("_show_advanced")
    send_key(ENTER)
    revealed = snapshot.fetch("rows").map { |row| row.fetch("id") }
    assert_includes revealed, "agent.head_model"
    assert_includes revealed, "agent.worker_thinking"

    # Setup has no category rail to escape through, so the reveal has to stay on
    # the card — under the cursor that opened it — and the footer has to say so.
    assert_equal "_show_advanced", snapshot.fetch("rows").fetch(snapshot.fetch("row_index")).fetch("id")
    assert_includes render, "A hide advanced"
    send_key(ENTER)
    refute_includes snapshot.fetch("rows").map { |row| row.fetch("id") }, "agent.head_model"
    assert_equal "_show_advanced", snapshot.fetch("rows").fetch(snapshot.fetch("row_index")).fetch("id")

    # A reaches the same reveal from anywhere on the step.
    focus_setup_row("agent.head_harness")
    send_key("a")
    assert_includes snapshot.fetch("rows").map { |row| row.fetch("id") }, "agent.head_model"
    send_key("a")
    refute_includes snapshot.fetch("rows").map { |row| row.fetch("id") }, "agent.head_model"
    assert_includes render, "A advanced"
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
    assert_includes frame, "Harness: Claude Code for heads and workers"
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
