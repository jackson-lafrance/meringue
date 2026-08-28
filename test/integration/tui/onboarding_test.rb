# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiTransactionalSetupTest < Minitest::Test
  include TUISupport

  ENTER = "\r"
  ESC = "\e"
  RIGHT = "\e[C"
  DOWN = "\e[B"
  TAB = "\t"
  SHIFT_TAB = "\e[Z"
  CTRL_S = "\u0013"
  WIDTH = 100
  HEIGHT = 32

  def setup
    @original_theme = Meringue::TUI::Style.current_colorscheme
    @tmpdir = Dir.mktmpdir("meringue-transactional-setup")
    @config_path = File.join(@tmpdir, "config.toml")
    File.write(@config_path, "[settings]\nschema_version = 1\n")
    @config = Meringue::Config.load(path: @config_path)
    @state = state_with_catalog
    @submitted = Queue.new
    @handler = lambda do |text|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
    @app = build_app
  end

  def teardown
    Meringue::TUI::Style.configure!(@original_theme)
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_first_run_opens_the_curated_settings_mode_and_a_marker_suppresses_it
    assert @app.send(:onboarding_autostart?)
    assert @app.send(:maybe_open_onboarding, -> { @state })

    snap = setup_snapshot
    assert_equal "setup", snap.fetch("mode")
    assert_equal Meringue::TUI::Settings::SetupFlow.steps, snap.fetch("categories")
    assert_equal "Welcome", snap.fetch("category")
    assert snap.fetch("setup_auto")
    assert_empty submitted

    marked = Meringue::Config.new(
      { "onboarding" => { "completed_version" => Meringue::Config::ONBOARDING_VERSION } },
      path: @config_path,
      loaded: true
    )
    app = build_app(config: marked)
    refute app.send(:onboarding_autostart?)
  end

  def test_setup_is_disabled_without_a_live_kernel_and_noninteractive_runs_do_not_open_it
    demo = build_app(onboarding_enabled: false)
    demo.send(:handle_key, ENTER, "/setup", 6, -1, @handler, compose(demo))
    refute Meringue::TUI::Settings.enabled?(compose(demo))
    assert_includes messages_text(demo), "live kernel"

    out = StringIO.new
    noninteractive = build_app(
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      out: out
    )
    assert_equal 0, noninteractive.run(state: @state)
    refute_includes out.string, "meringue · setup"
  end

  def test_theme_roles_and_experiments_remain_draft_only_until_one_finish_command
    open_manual_setup
    send_key(ENTER) # Welcome -> Harness
    assert_equal "Harness", setup_snapshot.fetch("category")

    send_key(RIGHT)
    assert_equal "Harness", setup_snapshot.fetch("category")
    refute setup_snapshot.fetch("dirty")
    send_key(ENTER) # head harness opens its picker
    send_key(DOWN)
    send_key(ENTER)
    head_harness = @app.instance_variable_get(:@settings_draft).value("agent.head_harness")
    assert_includes Meringue::Harness::Registry.supported_provider_names, head_harness
    # One harness decision covers both roles while the other is still unset.
    assert_equal head_harness, @app.instance_variable_get(:@settings_draft).value("agent.worker_harness")

    send_key(TAB) # Project
    assert_equal "Project", setup_snapshot.fetch("category")
    send_key(TAB) # Theme
    assert_equal "Theme", setup_snapshot.fetch("category")
    send_key(ENTER) # Theme opens its picker
    assert setup_snapshot.fetch("picker")
    send_key(DOWN)
    send_key(ENTER)
    preview = Meringue::TUI::Style.current_colorscheme
    refute_equal @original_theme, preview
    assert_equal preview, @app.instance_variable_get(:@settings_draft).value("appearance.theme")
    assert_equal "[settings]\nschema_version = 1\n", File.read(@config_path)
    assert_empty submitted

    send_key(TAB) # Status bar
    send_key(TAB) # Experiments
    assert_equal "Experiments", setup_snapshot.fetch("category")
    assert_equal Meringue::Experiments::Registry.ids.map { |id| "experiments.#{id}" }, setup_rows.map { |row| row.fetch("id") }
    send_key(ENTER) # checkbox-style controls use Enter
    assert @app.instance_variable_get(:@settings_draft).value("experiments.github_support")

    send_key(TAB) # Done
    assert_equal "Done", setup_snapshot.fetch("category")
    send_key(CTRL_S) # the final step completes directly
    send_key(ENTER) unless @app.instance_variable_get(:@settings_saving)

    command = wait_for_command
    assert_equal "SaveConfiguration", command.type
    assert_equal "completed", command.payload.fetch("onboarding_outcome")
    changes = command.payload.fetch("changes")
    assert_equal preview, changes.fetch("appearance.theme")
    assert_equal head_harness, changes.fetch("agent.head_harness")
    assert_equal head_harness, changes.fetch("agent.worker_harness")
    assert_equal true, changes.fetch("experiments.github_support")
    assert @app.instance_variable_get(:@settings_saving)
  end

  # Holding Tab used to walk past every card and only refuse at the very end,
  # which taught someone five screens too late that the second one mattered.
  def test_the_harness_step_cannot_be_walked_past
    open_manual_setup
    send_key(ENTER)
    assert_equal "Harness", setup_snapshot.fetch("category")

    5.times { send_key(TAB) }

    assert_equal "Harness", setup_snapshot.fetch("category"), "Tab must not escape the step"
    assert_includes setup_snapshot.fetch("rows").map { |row| row.fetch("error", "") }.join(" "), "required"
    assert_includes render, "required"
    assert_empty submitted
  end

  # The refusal puts the cursor on the control that is missing, not on the
  # action it just declined.
  def test_a_refused_advance_focuses_the_setting_it_needs
    open_manual_setup
    send_key(ENTER)
    snapshot_rows = setup_snapshot.fetch("rows")
    snapshot_rows.length.times { send_key(DOWN) } # onto the navigation action
    assert setup_snapshot.fetch("footer_focus")

    send_key(ENTER)

    refute setup_snapshot.fetch("footer_focus"), "focus should move off the refused action"
    assert_equal "agent.head_harness", setup_snapshot.fetch("rows").fetch(setup_snapshot.fetch("row_index")).fetch("id")
  end

  # Choosing one satisfies both roles, so the step opens up immediately.
  def test_choosing_a_harness_unblocks_the_step
    open_manual_setup
    send_key(ENTER)
    send_key(TAB)
    assert_equal "Harness", setup_snapshot.fetch("category")

    choose_first_harness
    send_key(TAB)

    assert_equal "Project", setup_snapshot.fetch("category")
  end

  # The step gate makes Done unreachable without a harness, so this covers the
  # backstop behind it: validation normally runs only over settings the user
  # changed, and an untouched required field has to be checked anyway.
  def test_completion_validation_checks_required_settings_that_were_never_touched
    draft = Meringue::TUI::Settings::Draft.new(@config, env: {})
    assert_empty draft.changes, "nothing has been edited"

    refute draft.validate(required_ids: %w[agent.head_harness])
    assert_includes draft.errors.fetch("agent.head_harness"), "required"

    # Without the requirement it passes, which is what /config relies on.
    assert draft.validate
    assert_empty draft.errors
  end

  def test_back_revisits_a_step_without_losing_edits_and_manual_cancel_discards_everything
    open_manual_setup
    send_key(ENTER)
    choose_first_harness
    2.times { send_key(TAB) } # Harness -> Project -> Theme
    send_key(ENTER)
    send_key(DOWN)
    send_key(ENTER)
    preview = Meringue::TUI::Style.current_colorscheme
    send_key(TAB)
    send_key(SHIFT_TAB)

    assert_equal "Theme", setup_snapshot.fetch("category")
    assert_equal preview, @app.instance_variable_get(:@settings_draft).value("appearance.theme")

    send_key(ESC)
    assert_equal "discard", setup_snapshot.fetch("confirmation")
    send_key(ENTER)
    refute @app.instance_variable_get(:@settings_active)
    assert_equal @original_theme, Meringue::TUI::Style.current_colorscheme
    assert_empty submitted
    assert_equal 0, Meringue::Config.load(path: @config_path).onboarding_version
  end

  def test_manual_rerun_cancel_preserves_an_existing_completed_marker
    Meringue::Config.save_onboarding!(outcome: "completed", completed_at: "2026-08-16T10:00:00Z", path: @config_path)
    @config = Meringue::Config.load(path: @config_path)
    @app = build_app

    open_manual_setup
    send_key(ESC)

    refute @app.instance_variable_get(:@settings_active)
    saved = Meringue::Config.load(path: @config_path)
    assert_equal "completed", saved.onboarding_outcome
    assert_equal "2026-08-16T10:00:00Z", saved.value("onboarding", "completed_at")
    assert_empty submitted
  end

  def test_first_run_escape_requires_confirmation_and_skip_excludes_draft_changes
    @app.send(:maybe_open_onboarding, -> { @state })
    send_key(ENTER)
    choose_first_harness
    2.times { send_key(TAB) } # Harness -> Project -> Theme
    send_key(ENTER)
    send_key(DOWN)
    send_key(ENTER)
    refute_equal @original_theme, Meringue::TUI::Style.current_colorscheme

    send_key(ESC)
    snap = setup_snapshot
    assert_equal "skip", snap.fetch("confirmation")
    assert_includes render, "Skip first-run setup?"
    send_key(ESC)
    assert_nil setup_snapshot["confirmation"]

    send_key(ESC)
    send_key(ENTER)
    command = wait_for_command
    assert_equal "skipped", command.payload.fetch("onboarding_outcome")
    assert_equal(
      {
        "experiments.github_support" => false,
        "experiments.agent_defaults_mode" => "role-specific",
        "experiments.self_fixing_workers" => false
      },
      command.payload.fetch("changes")
    )
    refute command.payload.fetch("changes").key?("appearance.theme")
  end

  def test_successful_finish_persists_marker_and_role_defaults_then_closes_with_summary
    @handler = saving_handler
    open_manual_setup
    send_key(ENTER)
    choose_first_harness
    5.times { send_key(TAB) } # Done is final
    assert_equal "Done", setup_snapshot.fetch("category")
    send_key(CTRL_S)
    wait_until { !@app.instance_variable_get(:@settings_active) }

    saved = Meringue::Config.load(path: @config_path)
    assert_equal Meringue::Config::ONBOARDING_VERSION, saved.onboarding_version
    assert_equal "completed", saved.onboarding_outcome
    assert_equal false, saved.value("experiments", "github_support")
    assert_includes messages_text, "Setup complete"
    assert_includes messages_text, "Head:"
    assert_includes messages_text, "Worker:"
  end

  def test_rejected_save_keeps_setup_open_with_actionable_error
    @handler = lambda do |text|
      @submitted << text
      {
        "event" => "slash_command_applied",
        "command_results" => [{
          "command_type" => "SaveConfiguration",
          "status" => "rejected",
          "message" => "Configuration changed on disk after Settings opened.",
          "result" => { "field_errors" => { "_stale" => "Reopen setup to review the newer file." } }
        }]
      }
    end
    open_manual_setup
    send_key(ENTER)
    choose_first_harness
    5.times { send_key(TAB) }
    assert_equal "Done", setup_snapshot.fetch("category")
    send_key(CTRL_S)
    wait_until { !@app.instance_variable_get(:@settings_saving) }

    assert @app.instance_variable_get(:@settings_active)
    assert_includes setup_snapshot.fetch("global_error"), "changed on disk"
    assert_includes render, "changed on disk"
  end

  def test_setup_compatibility_commands_remain_parseable
    parser = Meringue::Input::SlashCommandParser.new
    assert_equal "CompleteOnboarding", parser.parse("/setup complete").type
    assert_equal "completed", parser.parse("/setup complete").payload.fetch("outcome")
    assert_equal "skipped", parser.parse("/setup skip").payload.fetch("outcome")
  end

  private

  # Setup will not finish without a harness, so every completion path picks one.
  def choose_first_harness
    assert_equal "Harness", setup_snapshot.fetch("category")
    send_key(ENTER)
    send_key(DOWN)
    send_key(ENTER)
    refute_empty @app.instance_variable_get(:@settings_draft).value("agent.head_harness").to_s
  end

  def build_app(config: @config, onboarding_enabled: true, terminal: nil, out: StringIO.new)
    Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      out: out,
      terminal: terminal || TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: config,
      onboarding_enabled: onboarding_enabled
    )
  end

  def state_with_catalog
    TUISupport.empty_state.merge(
      "metadata" => {
        "harness_model_catalogs" => {
          "pi" => Meringue::Harness::ModelCatalog.available(
            harness: "pi",
            models: [
              { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5" },
              { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol" }
            ],
            source: "test"
          ).to_h
        }
      }
    )
  end

  def saving_handler
    lambda do |text|
      @submitted << text
      command = Meringue::Input::SlashCommandParser.new.parse(text)
      transaction = Meringue::Config::Store.new(path: @config_path).save(
        base_fingerprint: command.payload.fetch("base_fingerprint"),
        changes: command.payload.fetch("changes"),
        onboarding_outcome: command.payload["onboarding_outcome"]
      )
      {
        "event" => "slash_command_applied",
        "command_results" => [{
          "command_type" => "SaveConfiguration",
          "status" => "accepted",
          "result" => {
            "onboarding_outcome" => transaction["onboarding_outcome"],
            "onboarding_version" => transaction["onboarding_version"]
          }.compact
        }]
      }
    end
  end

  def open_manual_setup
    send_key(ENTER, input_buffer: "/setup")
    assert_equal "setup", setup_snapshot.fetch("mode")
  end

  def send_key(key, input_buffer: "")
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    @app.send(:handle_key, key, input_buffer, input_buffer.length, -1, @handler, compose)
  end

  def compose(app = @app)
    app.send(:compose_state, -> { @state }, "", -1, 0)
  end

  def setup_snapshot
    Meringue::TUI::Settings.snapshot(compose)
  end

  def setup_rows
    setup_snapshot.fetch("rows")
  end

  def render
    @app.render(compose, width: WIDTH, height: HEIGHT, color: false)
  end

  def submitted
    items = []
    items << @submitted.pop(true) while true
  rescue ThreadError
    items
  end

  def wait_for_command
    text = nil
    wait_until do
      begin
        text = @submitted.pop(true)
      rescue ThreadError
        nil
      end
      !text.nil?
    end
    Meringue::Input::SlashCommandParser.new.parse(text)
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def messages_text(app = @app)
    app.instance_variable_get(:@messages).map { |message| message.fetch("text", "") }.join("\n")
  end
end
