# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiStatusBarComposerTest < Minitest::Test
  include TUISupport

  ESC = "\e"
  ENTER = "\r"
  TAB = "\t"
  RIGHT = "\e[C"
  END_KEY = "\e[F"

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

  def test_default_bottom_bar_keeps_counts_harness_model_and_thinking_visible
    state = composed_state(runtime_state)
    left, right = Meringue::TUI::Layout.new.send(:dashboard_status_bar_lines, state)

    # Context leads the default left zone, so an idle dashboard still offers the
    # standing discovery hints ahead of the counts.
    assert_equal "Ctrl-C clear/quit · Tab focus · / commands · no open PRs · ● 1 worker · ● 1 head", plain(left)
    assert_equal "harness: Pi · model: openai/gpt-5.6-sol · thinking: high", plain(right)
    assert_nil Meringue::TUI::StatusBarLayout.from_state(state)
    assert_includes Meringue::TUI::Layout.new.render(state, width: 150, height: 30, color: false), "thinking: high"
  end

  # The composed bar replaced a hand-written hint line, so the affordances that
  # line carried have to survive as a component rather than disappear: the
  # gesture that clears a selected chat target, and that target's pull request.
  def test_context_component_carries_the_selection_gesture_and_omits_the_counts
    @state = runtime_state
    assert @app.send(:select_agent_tree_item, @state, "P1-I1-W1")
    @app.send(:exit_agent_tree_navigation)
    components = Meringue::TUI::Layout.new.send(:chat_pane).bottom_status_bar_components(compose)
    context = plain(components.fetch("context"))

    # Selecting a chat target must still offer the gesture that clears it: the
    # composed bar replaced the hand-written hint line that used to carry it.
    assert_includes context, "Esc clears"
    # The counts belong to the workers and heads components, so context does not
    # print them a second time when all three are placed.
    refute_includes context, "1 worker"
    assert_includes Meringue::TUI::StatusBarLayout::COMPONENT_IDS, "context"
    assert_includes Meringue::TUI::StatusBarLayout.default_items("left"), "context"
  end

  def test_invalid_and_legacy_documents_migrate_only_the_bottom_bar
    assert_nil Meringue::TUI::StatusBarLayout.normalize("not json")
    assert_nil Meringue::TUI::StatusBarLayout.normalize({ "version" => 99, "bottom" => {} })
    invalid = Meringue::TUI::StatusBarLayout.default_configuration
    invalid.fetch("bottom").fetch("left") << "unknown"
    assert_nil Meringue::TUI::StatusBarLayout.normalize(invalid)

    legacy = {
      "schema_version" => 1,
      "bottom_bar" => ["status", "hint"],
      "agent-info" => ["commands", "agent"],
      "focused-worker" => ["commands", "worker_status"]
    }
    normalized = Meringue::TUI::StatusBarLayout.normalize(legacy)

    assert_equal 2, normalized.fetch("version")
    assert_equal %w[harness model thinking], normalized.dig("bottom", "left")
    assert_equal %w[open_pull_requests workers heads], normalized.dig("bottom", "right")
    refute normalized.key?("agent_information")
    refute normalized.key?("focused_worker")
  end

  def test_store_persists_a_canonical_bottom_only_layout_and_keeps_invalid_file_safe
    layout = Meringue::TUI::StatusBarLayout.default_configuration
    layout.fetch("bottom").fetch("left").delete("heads")
    layout.fetch("bottom").fetch("right").unshift("heads")
    store = Meringue::Config::Store.new(path: @config_path)
    store.save(
      base_fingerprint: store.fingerprint,
      changes: { "appearance.status_bar_layout" => Meringue::TUI::StatusBarLayout.serialized(layout) }
    )

    loaded = Meringue::TUI::StatusBarLayout.from_config(Meringue::Config.load(path: @config_path))
    assert_equal %w[context open_pull_requests workers], loaded.dig("bottom", "left")
    assert_equal %w[heads harness model thinking], loaded.dig("bottom", "right")
    assert_equal %w[bottom version], loaded.keys.sort

    File.write(@config_path, "[tui]\nstatus_bar_layout = \"{not json}\"\n")
    refute Meringue::TUI::StatusBarLayout.from_config(Meringue::Config.load(path: @config_path))
  end

  def test_draft_moves_components_between_alignment_zones_reorders_and_resets
    draft = Meringue::TUI::StatusBarComposer::Draft.new(@config)
    draft.select_component_id("heads")
    assert draft.place("heads", "right", 1)
    assert_equal %w[context open_pull_requests workers], draft.layout.items("left")
    assert_equal %w[harness heads model thinking], draft.layout.items("right")

    draft.nudge_selected(1)
    assert_equal %w[harness model heads thinking], draft.layout.items("right")
    draft.remove
    refute draft.layout.items("right").include?("heads")
    assert draft.dirty?
    assert_equal "appearance.status_bar_layout", draft.changes.keys.first

    draft.reset!
    refute draft.dirty?
    assert_equal Meringue::TUI::StatusBarLayout.default_configuration, draft.layout.to_h
    assert_empty draft.changes
  end

  def test_direct_composer_has_a_centered_live_bar_palette_and_escape_never_writes
    assert @app.send(:handle_local_navigation_command, "/status-bar", @state)
    frame = @app.render(compose, width: 80, height: 20, color: false)
    assert_includes frame, "bottom status bar"
    assert_includes frame, "live bottom bar"
    assert_includes frame, "components · drag to place"
    assert_includes frame, "left aligned"
    assert_includes frame, "right aligned"

    send_key(RIGHT)
    assert_equal %w[open_pull_requests context workers heads], standalone_draft.layout.items("left")
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
    assert_equal %w[open_pull_requests context workers heads], Meringue::TUI::StatusBarLayout.normalize(value).dig("bottom", "left")
    assert @app.instance_variable_get(:@status_bar_composer_saving)
  end

  def test_setup_embeds_the_actual_composer_and_keeps_it_in_the_setup_transaction
    @app.send(:open_settings, @state, mode: "setup")
    show_setup_status_bar
    settings = @app.instance_variable_get(:@settings_draft)
    settings.set("agent.head_harness", "pi")
    settings.set("agent.worker_harness", "claude")
    settings.set("agent.head_model", "openai/gpt-5.6-sol")
    settings.set("agent.worker_model", "anthropic/claude-opus-5")
    settings.set("agent.head_thinking", "low")
    settings.set("agent.worker_thinking", "max")

    frame = @app.render(compose, width: 100, height: 32, color: false)
    assert_includes frame, "live bottom bar"
    composer = compose.dig("_settings", "status_bar_composer")
    assert_equal "head model: openai/gpt-5.6-sol · worker model: anthropic/claude-opus-5", plain(composer.dig("preview_components", "model"))
    assert_equal "head thinking: low · worker thinking: max", plain(composer.dig("preview_components", "thinking"))
    refute @app.instance_variable_get(:@status_bar_composer_active)
    assert composer.fetch("inline")

    send_key(END_KEY)
    value = settings.value("appearance.status_bar_layout")
    assert_equal %w[harness model thinking context], Meringue::TUI::StatusBarLayout.normalize(value).dig("bottom", "right")
    assert_empty submitted
    refute File.exist?(@config_path)

    send_key(TAB)
    assert_equal "Experiments", @app.send(:settings_category)
    send_key("\u0013")
    command = Meringue::Input::SlashCommandParser.new.parse(@submitted.pop)
    assert_equal "completed", command.payload.fetch("onboarding_outcome")
    saved = Meringue::TUI::StatusBarLayout.normalize(command.payload.fetch("changes").fetch("appearance.status_bar_layout"))
    assert_equal %w[open_pull_requests workers heads], saved.dig("bottom", "left")
    assert_equal %w[harness model thinking context], saved.dig("bottom", "right")
  end

  def test_inline_mouse_drag_reorders_components_and_resize_keeps_a_full_frame
    @app.send(:open_settings, @state, mode: "setup")
    show_setup_status_bar
    snapshot = compose
    view = @app.send(:layout).send(:settings_pane).setup_view(snapshot, width: 100, height: 32)
    bounds = view.fetch(:composer_bounds)
    pane = Meringue::TUI::StatusBarComposer::Pane.new
    geometry = pane.geometry(width: 100, height: 32, bounds: bounds)
    left = geometry.fetch(:left_zone)

    right = geometry.fetch(:right_zone)
    send_mouse("kind" => "button", "pressed" => true, "x" => left.fetch(:x) + 3, "y" => left.fetch(:y) + 3)
    send_mouse("kind" => "motion", "pressed" => true, "x" => right.fetch(:x) + 3, "y" => right.fetch(:y) + 2)
    send_mouse("kind" => "button", "pressed" => false, "x" => right.fetch(:x) + 3, "y" => right.fetch(:y) + 2)

    draft = @app.instance_variable_get(:@settings_status_bar_draft)
    assert_equal %w[context open_pull_requests heads], draft.layout.items("left")
    assert_equal %w[harness workers model thinking], draft.layout.items("right")

    send_mouse("kind" => "button", "pressed" => true, "x" => right.fetch(:x) + 3, "y" => right.fetch(:y) + 1)
    send_mouse("kind" => "motion", "pressed" => true, "x" => right.fetch(:x) + 3, "y" => right.fetch(:y) + 3)
    send_mouse("kind" => "button", "pressed" => false, "x" => right.fetch(:x) + 3, "y" => right.fetch(:y) + 3)
    assert_equal %w[workers model harness thinking], draft.layout.items("right")
    [[100, 32], [79, 24], [46, 18], [32, 10]].each do |width, height|
      frame = @app.render(compose, width: width, height: height, color: false)
      assert_equal height, frame.lines.length, "#{width}x#{height} should not clip its canvas"
    end
  end

  def test_custom_zones_render_shared_and_split_values_in_the_requested_order
    custom = Meringue::TUI::StatusBarLayout.default_configuration
    custom["bottom"] = {
      "left" => %w[heads workers open_pull_requests],
      "right" => %w[thinking model harness]
    }
    state = composed_state(split_runtime_state.merge("_status_bar_layout" => custom))
    left, right = Meringue::TUI::Layout.new.send(:dashboard_status_bar_lines, state)

    assert_equal "● 1 head · ● 1 worker · no open PRs", plain(left)
    assert_equal(
      "head thinking: low · worker thinking: max · head model: openai/gpt-5.6-sol · worker model: anthropic/claude-opus-5 · head: Pi · worker: Claude Code",
      plain(right)
    )
  end

  def test_bottom_layout_never_changes_the_two_focused_worker_bars
    custom = Meringue::TUI::StatusBarLayout.default_configuration
    custom["bottom"] = { "left" => %w[thinking], "right" => %w[heads] }
    base = focused_worker_state
    configured = Meringue::Config.deep_copy(base).merge("_status_bar_layout" => custom)
    pane = Meringue::TUI::Panes::AgentWorkspacePane.new

    assert_equal pane.top_status_layout(base, width: 70), pane.top_status_layout(configured, width: 70)
    layout = Meringue::TUI::Layout.new
    assert_equal layout.render(base, width: 80, height: 20, color: false),
                 layout.render(configured, width: 80, height: 20, color: false)
  end

  private

  def runtime_state
    empty_state.merge(
      "agents" => [
        agent_record("P1-I1-W1", "status" => "working", "type" => "worker"),
        agent_record("H1", "status" => "working", "type" => "head")
      ],
      "metadata" => {
        "active_harness" => "pi",
        "agent_session_defaults" => {
          "model" => "openai/gpt-5.6-sol",
          "thinking_level" => "high"
        }
      }
    )
  end

  def split_runtime_state
    runtime_state.merge(
      "metadata" => {
        "active_head_harness" => "pi",
        "active_worker_harness" => "claude",
        "agent_session_defaults" => {
          "roles" => {
            "head" => { "model" => "openai/gpt-5.6-sol", "thinking_level" => "low" },
            "worker" => { "model" => "anthropic/claude-opus-5", "thinking_level" => "max" }
          }
        }
      }
    )
  end

  def focused_worker_state
    composed_state(
      empty_state.merge("agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]),
      "_agent_workspace" => {
        "active" => true,
        "embedded" => false,
        "agent_id" => "P1-I1-W1",
        "view" => "agent",
        "input_buffer" => "",
        "input_cursor" => 0,
        "leader_label" => "Ctrl-Space",
        "leader_commands" => [{ "action" => "workspace_switch_view", "key" => "T" }]
      }
    )
  end

  def show_setup_status_bar
    steps = @app.send(:settings_categories)
    @app.instance_variable_set(:@settings_category_index, steps.index("Status bar"))
    assert_equal "Status bar", @app.send(:settings_category)
  end

  def composed_state(state, extras = {})
    TUISupport.composed_state(state).merge(extras)
  end

  def compose
    @app.send(:compose_state, -> { @state }, "", -1, 0)
  end

  def standalone_draft
    @app.instance_variable_get(:@status_bar_composer_draft)
  end

  def send_key(key)
    @app.instance_variable_set(:@last_render_width, 100)
    @app.instance_variable_set(:@last_render_height, 32)
    @app.send(:handle_chat_key, key, "", 0, -1, @handler, compose)
  end

  def send_mouse(event)
    send_key(event.merge("type" => "mouse", "x" => event.fetch("x") + 1, "y" => event.fetch("y") + 1))
  end

  def plain(segments)
    Array(segments).map { |segment| segment.fetch(0, "").to_s }.join
  end

  def submitted
    values = []
    values << @submitted.pop(true) while true
  rescue ThreadError
    values
  end
end
