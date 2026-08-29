# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiWorkerGuidanceEditorTest < Minitest::Test
  include TUISupport

  ENTER = "\r"
  ESC = "\e"
  TAB = "\t"
  DOWN = "\e[B"
  UP = "\e[A"
  HOME = "\e[H"
  SHIFT_ENTER = "\e[13;2u"
  SHIFT_ALT_LEFT = "\e[1;4D"
  WIDTH = 100
  HEIGHT = 32
  GUIDANCE_ID = "experiments.worker_spawning_guidance_prompt"

  def setup
    @tmpdir = Dir.mktmpdir("meringue-worker-guidance-editor")
    @config_path = File.join(@tmpdir, "config.toml")
    File.write(@config_path, <<~TOML)
      [settings]
      schema_version = 2
      [experiments]
      agent_defaults_mode = "guided"
    TOML
    @config = Meringue::Config.load(path: @config_path)
    @state = empty_state.merge(
      "metadata" => {
        "active_harness" => "pi",
        "active_worker_harness" => "pi",
        "harness_model_catalogs" => {
          "pi" => Meringue::Harness::ModelCatalog.available(
            harness: "pi",
            models: [
              { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT Sol" },
              { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus" }
            ]
          ).to_h
        }
      }
    )
    @app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: @config,
      onboarding_enabled: true
    )
    @handler = ->(_text) { { "event" => "slash_command_applied", "command_results" => [] } }
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_config_keeps_the_multiline_editor_inline_and_reuses_composer_editing
    @app.send(:open_settings, @state)
    2.times { send_key(TAB) }
    select_guidance_row

    before = render
    assert_includes before, "Model and reasoning defaults"
    assert_includes before, "Worker selection guidance — Enter to edit"

    send_key(ENTER)
    frame = render
    assert_equal "settings", snapshot.fetch("mode")
    assert_equal "Experiments", snapshot.fetch("category")
    assert_equal GUIDANCE_ID, snapshot.dig("editor", "id")
    assert_includes frame, "Model and reasoning defaults"
    assert_includes frame, "Worker selection guidance — editing"
    refute_includes frame, "Edit Guided selection prompt"

    set_editor("x" * 140, cursor: 110)
    send_key(UP)
    moved_up = editor.fetch("cursor")
    assert_operator moved_up, :<, 110
    send_key(DOWN)
    assert_equal 110, editor.fetch("cursor"), "vertical movement should follow the same soft wraps as chat input"

    set_editor("alpha beta", cursor: 10)
    send_key(SHIFT_ALT_LEFT)
    assert_equal({ "start" => 6, "end" => 10 }, editor.fetch("selection"))
    send_key("X")
    assert_equal "alpha X", editor.fetch("buffer")
    assert_equal 7, editor.fetch("cursor")
    refute editor.key?("selection")

    send_key(SHIFT_ENTER)
    send_key({ "type" => "paste", "text" => "one\r\ntwo" })
    assert_equal "alpha X\none\ntwo", editor.fetch("buffer")
    send_key(HOME)
    assert_equal "alpha X\none\n".length, editor.fetch("cursor")

    send_key(ENTER)
    assert_nil snapshot["editor"]
    assert_equal "alpha X\none\ntwo", @app.instance_variable_get(:@settings_draft).value(GUIDANCE_ID)
  end

  def test_guidance_completion_replaces_the_token_before_the_cursor_without_losing_suffix_text
    @app.send(:open_settings, @state)
    2.times { send_key(TAB) }
    select_guidance_row
    send_key(ENTER)
    text = "Use @sol then keep this suffix"
    set_editor(text, cursor: "Use @sol".length)

    send_key(TAB)

    assert_equal "Use @openai/gpt-5.6-sol then keep this suffix", editor.fetch("buffer")
    assert_equal "Use @openai/gpt-5.6-sol".length, editor.fetch("cursor")
  end

  def test_setup_embeds_the_same_editor_on_the_experiments_step
    File.write(@config_path, "[settings]\nschema_version = 2\n[experiments]\nagent_defaults_mode = \"role-specific\"\n")
    @config = Meringue::Config.load(path: @config_path)
    @app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: @config,
      onboarding_enabled: true
    )

    send_key(ENTER, input_buffer: "/setup")
    send_key(ENTER) # Welcome -> Theme
    3.times { send_key(TAB) }
    assert_equal "Experiments", snapshot.fetch("category")

    # Guided is the third mode of the defaults selector, so reaching the prompt
    # means cycling that row to "guided" rather than flipping a toggle.
    mode_row = snapshot.fetch("rows").index { |row| row.fetch("id") == "experiments.agent_defaults_mode" }
    @app.instance_variable_set(:@settings_row_index, mode_row)
    @app.instance_variable_get(:@settings_draft).set("experiments.agent_defaults_mode", "guided")
    assert_includes snapshot.fetch("rows").map { |row| row.fetch("id") }, GUIDANCE_ID
    assert_includes render, "Worker selection guidance — Enter to edit"

    select_guidance_row
    send_key(ENTER)
    frame = render
    assert_includes frame, "Meringue Xtras"
    assert_includes frame, "Model and reasoning defaults"
    assert_includes frame, "Worker selection guidance — editing"
    refute_includes frame, "Edit Guided selection prompt"

    set_editor("Routine tasks use a light model.", cursor: 32)
    send_key(SHIFT_ENTER)
    send_key("Complex tasks use deeper reasoning.")
    send_key(ENTER)
    assert_equal "Routine tasks use a light model.\nComplex tasks use deeper reasoning.",
                 @app.instance_variable_get(:@settings_draft).value(GUIDANCE_ID)
  end

  private

  def compose
    @app.send(:compose_state, -> { @state }, "", -1, 0)
  end

  def snapshot
    Meringue::TUI::Settings.snapshot(compose)
  end

  def render
    @app.render(compose, width: WIDTH, height: HEIGHT, color: false)
  end

  def send_key(key, input_buffer: "")
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    @app.send(:handle_key, key, input_buffer, input_buffer.length, -1, @handler, compose)
  end

  def select_guidance_row
    index = snapshot.fetch("rows").index { |row| row.fetch("id") == GUIDANCE_ID }
    refute_nil index
    @app.instance_variable_set(:@settings_row_index, index)
  end

  def editor
    @app.instance_variable_get(:@settings_editor)
  end

  def set_editor(text, cursor: text.length)
    editor["buffer"] = text
    editor["cursor"] = cursor
    editor.delete("selection")
    editor.delete("selection_anchor")
  end
end
