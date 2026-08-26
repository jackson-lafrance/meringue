# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"
require "timeout"

class TuiAppWiringTest < Minitest::Test
  include TUISupport

  App = Meringue::TUI::App
  Models = Meringue::State::Models

  class DurableBlockingHandler
    attr_reader :enqueued, :delivered, :release

    def initialize
      @enqueued = Queue.new
      @delivered = Queue.new
      @release = Queue.new
    end

    def enqueue_submission(text, selected_target: nil)
      { "id" => "input-1", "text" => text, "selected_target" => selected_target }.tap { |record| enqueued << record }
    end

    def deliver_submission(record)
      delivered << record
      release.pop
      { "summary" => "routed" }
    end
  end

  class MouseFailureApp < App
    private

    def handle_mouse_key(key, *)
      raise "agent tree click failed" if key.is_a?(Hash) && key["type"] == "mouse"

      super
    end
  end

  class BlockingLogStore
    attr_reader :write_started, :write_finished

    def initialize
      @write_started = Queue.new
      @write_finished = Queue.new
      @release_write = Queue.new
      @mutex = Mutex.new
      @write_count = 0
    end

    def save_log_buffer(messages:, next_message_id:)
      first_write = @mutex.synchronize do
        @write_count += 1
        @write_count == 1
      end
      return unless first_write

      write_started << { "messages" => messages, "next_message_id" => next_message_id }
      @release_write.pop
      write_finished << true
    end

    def release_first_write
      @release_write << true
    end
  end

  def setup
    @out = StringIO.new
    @terminal = TUISupport::FakeTerminal.new
    @app = App.new(layout: Meringue::TUI::Layout.new, out: @out, terminal: @terminal)
  end

  def test_render_delegates_to_the_layout_at_the_requested_size
    frame = @app.render(composed_state(demo_state), width: 80, height: 20)
    lines = frame.split("\n", -1)

    assert_equal 20, lines.length
    assert_equal [80], lines.map(&:length).uniq
  end

  def test_non_interactive_run_renders_one_frame_and_exits_cleanly
    provider = TUISupport::RecordingStateProvider.new(demo_state)

    assert_equal 0, @app.run(state_provider: provider.to_proc)
    assert_equal 1, provider.calls
    assert_empty @terminal.frames, "a non-interactive run never writes terminal frames"

    lines = @out.string.split("\n")
    assert_equal App::DEFAULT_HEIGHT, lines.length
    assert_equal [App::DEFAULT_WIDTH], lines.map(&:length).uniq
    assert_includes @out.string, "─ agent tree "
  end

  def test_run_without_a_state_falls_back_to_an_empty_state
    assert_equal 0, @app.run
    assert_includes @out.string, "No AgentTree data yet."
  end

  def test_mouse_input_failure_keeps_the_interactive_app_running_and_reports_the_error
    output = StringIO.new
    terminal = TUISupport::FakeTerminal.new(
      interactive: true,
      output:,
      keys: [
        "keep this draft",
        { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0, "x" => 4, "y" => 4 },
        nil,
        "\u0004"
      ]
    )
    app = MouseFailureApp.new(layout: Meringue::TUI::Layout.new, out: output, terminal:)

    assert_equal 0, app.run(state: demo_state)
    assert_operator terminal.frames.length, :>=, 2
    rendered_output = TUISupport.strip_ansi(output.string).gsub(/\s+/, " ")
    assert_includes rendered_output, "Could not handle mouse input: RuntimeError: agent tree"
    assert_includes rendered_output, "click failed"
    assert_includes rendered_output, "keep this draft"
  end

  def test_compose_state_only_adds_presentation_keys
    provider = TUISupport::RecordingStateProvider.new(demo_state)
    composed = compose_app_state(@app, provider.to_proc, "typed")

    assert_equal(
      %w[_agent_tree_navigation _agent_workspace _capabilities _chat _context_menu _log_scope _scroll _selection _settings _status_bar_composer _status_bar_layout],
      (composed.keys - demo_state.keys).sort
    )
    # Settings is nil unless /config or the shared first-run Setup mode is active.
    assert_nil composed.fetch("_settings")
    assert_nil composed.fetch("_status_bar_composer")
    assert_nil composed.fetch("_status_bar_layout")
    assert composed.fetch("_capabilities").key?("github_support")
    demo_state.each_key { |key| assert composed.key?(key), "kernel key #{key} must survive composition" }
    assert_equal demo_state.fetch("agents"), composed.fetch("agents")
    assert_equal demo_state.fetch("questions"), composed.fetch("questions")
  end

  def test_compose_state_does_not_mutate_the_kernel_snapshot
    shared = demo_state
    before = JSON.parse(JSON.generate(shared))

    compose_app_state(@app, -> { shared }, "typed")

    assert_equal before, shared
  end

  def test_composed_presentation_state_matches_the_documented_shape
    composed = compose_app_state(@app, -> { demo_state }, "typed")

    assert_equal "typed", composed.dig("_chat", "input_buffer")
    assert_equal 5, composed.dig("_chat", "input_cursor")
    assert_equal 0, composed.dig("_chat", "pending_count")
    assert_equal "chat", composed.dig("_scroll", "active_pane")
    assert_equal({ "agent_tree" => 0, "logs" => 0, "chat" => 0 }, composed.dig("_scroll", "offsets"))
    refute composed.dig("_selection", "active")
    refute composed.dig("_agent_workspace", "active")
  end

  def test_restore_logs_reads_the_persisted_conversation_without_mutating_state
    state = empty_state
    state["conversation"] = {
      "messages" => [{ "id" => 4, "role" => "you", "text" => "persisted prompt", "timestamp" => "2026-07-11T00:00:00Z" }],
      "next_message_id" => 5
    }
    before = JSON.parse(JSON.generate(state))

    @app.restore_logs!(state)
    composed = compose_app_state(@app, -> { state }, "")

    assert_equal before, state
    assert_includes plain_lines(Meringue::TUI::Panes::ChatPane.new.log_lines(composed, width: 60)).join("\n"), "persisted prompt"
  end

  def test_restore_agent_workspace_reads_persisted_ui_selection
    state = empty_state
    # The kernel prunes selections for unknown workers, so the worker has to
    # exist in the snapshot for its persisted workspace state to survive.
    state["agents"] = [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    state["ui"] = {
      "agent_workspace" => {
        "selected_agent_id" => "P1-I1-W1",
        "view" => "terminal",
        "filter" => "tools",
        "draft" => "half typed",
        "agent_scroll_offset" => 3,
        "terminal_scroll_offset" => 1
      }
    }

    workspace = @app.restore_agent_workspace!(state)

    assert_equal "P1-I1-W1", workspace.fetch("selected_agent_id")
    assert_equal "terminal", workspace.fetch("view")
    assert_equal "tools", workspace.fetch("filter")
    assert_equal "half typed", workspace.fetch("draft")
    assert_equal 3, workspace.fetch("agent_scroll_offset")
    assert_includes Models::AGENT_WORKSPACE_FILTERS, workspace.fetch("filter")
  end

  def test_restore_agent_workspace_drops_selections_for_unknown_workers
    state = empty_state
    state["ui"] = { "agent_workspace" => { "selected_agent_id" => "P9-I9-W9", "view" => "terminal", "draft" => "dropped" } }

    workspace = @app.restore_agent_workspace!(state)

    # Nil values are compacted out of the normalized workspace snapshot.
    assert_nil workspace.fetch("selected_agent_id", nil)
    assert_equal "", workspace.fetch("draft")
    assert_equal "terminal", workspace.fetch("view")
  end

  def test_remember_existing_log_events_does_not_mutate_state
    state = demo_state
    before = JSON.parse(JSON.generate(state))

    @app.remember_existing_log_events!(state)

    assert_equal before, state
  end

  def test_typing_editing_and_navigation_keys_only_change_the_composer
    state = composed_state(empty_state)

    assert_equal ["h", 1, -1], @app.send(:handle_key, "h", "", 0, -1, nil, state)
    assert_equal ["h", 1, -1], @app.send(:handle_key, "\u007f", "hi", 2, -1, nil, state)
    assert_equal ["abc", 2, -1], @app.send(:handle_key, "\e[D", "abc", 3, -1, nil, state)
    assert_equal ["pasted", 6, -1], @app.send(:handle_key, { "type" => "paste", "text" => "pasted" }, "", 0, -1, nil, state)
    assert_equal ["", 0, -1], @app.send(:handle_key, "\u0003", "clear me", 8, -1, nil, state)
    assert_equal ["/help", 5, -1], @app.send(:handle_key, "\t", "/hel", 4, -1, nil, state)
    assert_equal ["a\nb", 2, -1], @app.send(:handle_key, "\e[13;2u", "ab", 1, -1, nil, state)
  end

  def test_agent_tree_rename_key_prefills_the_selected_project
    state = composed_state(empty_state.merge("projects" => [project_record("P1", "name" => "Old app")]))
    assert @app.send(:select_agent_tree_item, state, "P1")
    @app.instance_variable_set(:@focused_pane, "agent_tree")

    result = @app.send(:handle_key, "r", "", 0, -1, nil, state)

    assert_equal ["/project rename P1 ", "/project rename P1 ".length, -1], result
  end

  def test_agent_tree_rename_key_resolves_a_worker_to_its_issue
    state = composed_state(
      empty_state.merge(
        "projects" => [project_record("P1")],
        "issues" => [issue_record("P1-I1", "title" => "Old issue")],
        "agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
      )
    )
    assert @app.send(:select_agent_tree_item, state, "P1-I1-W1")
    @app.instance_variable_set(:@focused_pane, "agent_tree")

    result = @app.send(:handle_key, "r", "", 0, -1, nil, state)

    assert_equal "/issue rename P1-I1 ", result.first
  end

  # The quick-rename draft must be a command the parser still accepts, so the prefilled
  # text is checked against the real parser rather than only against a literal string.
  def test_agent_tree_rename_key_prefills_a_command_the_parser_still_accepts
    state = composed_state(
      empty_state.merge(
        "projects" => [project_record("P1", "name" => "Old app")],
        "issues" => [issue_record("P1-I1", "title" => "Old issue")]
      )
    )
    @app.instance_variable_set(:@focused_pane, "agent_tree")
    parser = Meringue::Input::SlashCommandParser.new

    assert @app.send(:select_agent_tree_item, state, "P1")
    project_draft = @app.send(:handle_key, "r", "", 0, -1, nil, state).first
    assert_equal "ModifyProject", parser.parse("#{project_draft}Renamed app").to_h.fetch("type")

    assert @app.send(:select_agent_tree_item, state, "P1-I1")
    issue_draft = @app.send(:handle_key, "r", "", 0, -1, nil, state).first
    assert_equal "ModifyIssue", parser.parse("#{issue_draft}Renamed issue").to_h.fetch("type")
  end

  def test_composer_is_not_cleared_until_submission_is_durably_enqueued
    state = composed_state(empty_state)
    handler = DurableBlockingHandler.new

    result = @app.send(:handle_key, "\r", "survive restart", 15, -1, handler, state)

    assert_equal ["", 0, -1], result
    submission = Timeout.timeout(2) { handler.enqueued.pop }
    assert_equal "survive restart", submission.fetch("text")
    assert_equal submission, Timeout.timeout(2) { handler.delivered.pop }
  ensure
    handler&.release&.push(true)
  end

  def test_submitting_a_prompt_hands_the_text_to_the_kernel_callback
    state = composed_state(empty_state)
    submitted = Queue.new
    handler = lambda do |text|
      submitted << text
      { "summary" => "routed the prompt" }
    end

    assert_equal ["", 0, -1], @app.send(:handle_key, "\r", "do it", 5, -1, handler, state)
    assert_equal "do it", Timeout.timeout(5) { submitted.pop }
  end

  def test_submitting_a_prompt_stays_responsive_while_conversation_persistence_is_blocked
    store = BlockingLogStore.new
    prompt = "retry all failed heads and workers"
    terminal = TUISupport::FakeTerminal.new(keys: prompt.chars + ["\r"] + "/quit".chars + ["\r"], interactive: true)
    app = App.new(layout: Meringue::TUI::Layout.new, out: StringIO.new, terminal: terminal, log_store: store)
    submitted = Queue.new
    handler = lambda do |text|
      submitted << text
      { "summary" => "routed" }
    end
    run_result = Queue.new
    run_thread = Thread.new do
      run_result << app.run(state_provider: -> { empty_state }, on_submit: handler)
    end

    persisted = Timeout.timeout(2) { store.write_started.pop }
    write_blocked = true

    assert_equal prompt, Timeout.timeout(2) { submitted.pop }
    assert_equal 0, Timeout.timeout(2) { run_result.pop }
    assert_equal ["routed"], persisted.fetch("messages").map { |message| message.fetch("text") }
  ensure
    if write_blocked
      store.release_first_write
      Timeout.timeout(2) { store.write_finished.pop }
    end
    run_thread&.join(2)
  end

  def test_config_overview_includes_supported_settings_and_active_keybindings
    config = Meringue::Config.new(
      {
        "tui" => { "colorscheme" => "gruvbox" },
        "harness" => { "provider" => "claude", "pi" => {
          "model" => "openai/gpt-5.6-sol", "thinking_level" => "high",
          "head_thinking_level" => "low", "worker_thinking_level" => "xhigh"
        } },
        "conflicts" => { "predecessor_failure" => "run" },
        "commands" => { "worker_blacklist" => ["*gh pr comment *"] },
        "workspace" => { "editor_command" => ["code", "--reuse-window"] }
      },
      path: "/tmp/meringue-test-config.toml",
      loaded: true
    )
    app = App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      keybindings: Meringue::TUI::Keybindings.from_config({ "submit" => ["ctrl-x"] }),
      config: config
    )

    overview = app.send(:configuration_help_text)

    assert_includes overview, "file: /tmp/meringue-test-config.toml (loaded)"
    assert_includes overview, "harness: claude"
    assert_includes overview, "head model: anthropic/claude-opus-5"
    assert_includes overview, "worker model: anthropic/claude-opus-5"
    assert_includes overview, "head reasoning: max"
    assert_includes overview, "worker reasoning: max"
    assert_includes overview, "conflict policy (predecessor failure): run"
    assert_includes overview, "worker command blacklist: *gh pr comment *"
    assert_includes overview, "Submit / open selected item [submit]: ctrl-x"
    assert_includes overview, "Keybindings (action: configured keys"
  end

  def test_quit_keys_follow_the_injected_keybindings
    assert @app.send(:quit_key?, "\u0004", "")
    assert @app.send(:quit_key?, "\u0003", "")
    refute @app.send(:quit_key?, "\u0003", "text")
    refute @app.send(:quit_key?, nil, "")

    custom = App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      keybindings: Meringue::TUI::Keybindings.from_config({ "quit" => ["ctrl-q"] })
    )

    assert custom.send(:quit_key?, "\u0011", "")
    refute custom.send(:quit_key?, "\u0004", "")
  end

  def test_tui_never_invents_lifecycle_statuses
    assert_equal Models::LIFECYCLE_STATUSES.sort, Meringue::TUI::Panes::AgentTreePane::STATUS_DOTS.keys.sort
    assert_equal Models::LIFECYCLE_STATUSES.sort, Meringue::TUI::Panes::AgentTreePane::STATUS_STYLES.keys.sort
  end

  def test_tui_never_invents_log_levels
    level_styles = Meringue::TUI::Style::STYLE_NAMES.grep(/\ALOG_/).map { |name| name.to_s.sub("LOG_", "").downcase }

    assert_equal (Models::LOG_LEVELS + ["command"]).sort, level_styles.sort
    Models::LOG_LEVELS.each do |level|
      state = composed_state(empty_state.merge("logs" => [log_record("L1", "level" => level, "message" => "#{level} entry")]))
      assert_includes render_frame(state, width: 80, height: 20), "#{level} entry"
    end
  end

  def test_agent_workspace_filters_come_from_the_state_models
    assert_equal Models::AGENT_WORKSPACE_FILTERS, App::WORKSPACE_FILTERS
  end

  def test_no_color_environment_disables_color_output
    with_env("NO_COLOR" => "1") { refute @app.send(:color_output?) }
    with_env("NO_COLOR" => nil) { assert @app.send(:color_output?) }
  end

  def test_focus_order_covers_the_three_dashboard_panes
    assert_equal %w[agent_tree chat logs], App::FOCUS_ORDER.sort
  end
end
