# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiWorkerGuidanceExternalEditorTest < Minitest::Test
  include TUISupport

  ENTER = "\r"
  TAB = "\t"
  WIDTH = 100
  HEIGHT = 32
  GUIDANCE_ID = "experiments.worker_spawning_guidance_prompt"

  class Editor
    attr_reader :texts

    def initialize(result)
      @result = result
      @texts = []
    end

    def edit_text(text:, extension:)
      @texts << [text, extension]
      @result.respond_to?(:call) ? @result.call(text) : @result
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("meringue-guidance-editor")
    path = File.join(@tmpdir, "config.toml")
    File.write(path, "[settings]\nschema_version = 2\n[experiments]\nagent_defaults_mode = \"guided\"\n")
    @config = Meringue::Config.load(path: path)
    @state = empty_state.merge("metadata" => { "active_harness" => "pi", "active_worker_harness" => "pi" })
    @editor = Editor.new(->(text) { { "status" => "edited", "text" => text + "\nupdated" } })
    @app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new, out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT),
      config: @config, workspace_controller: @editor, onboarding_enabled: true
    )
    @handler = ->(_text) { { "event" => "slash_command_applied", "command_results" => [] } }
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_guidance_is_a_clean_focusable_action_and_successful_edit_is_saved
    open_guidance
    frame = render
    assert_includes frame, "Guided selection prompt"
    assert_includes frame, "Enter"
    refute_includes frame, "Additional system-prompt"
    refute_includes frame, "Worker selection guidance"

    send_key(ENTER)
    assert_equal [[Meringue::Experiments::WorkerSpawningGuidance.default_text, ".md"]], @editor.texts
    assert_equal Meringue::Experiments::WorkerSpawningGuidance.default_text + "\nupdated",
                 @app.instance_variable_get(:@settings_draft).value(GUIDANCE_ID)
    assert_nil @app.instance_variable_get(:@settings_editor)
  end

  def test_failed_or_cancelled_edit_keeps_original_and_reports_error
    original = @app.instance_variable_get(:@settings_draft)&.value(GUIDANCE_ID)
    @editor = Editor.new("status" => "failed", "message" => "editor failed")
    @app.instance_variable_set(:@workspace_controller, @editor)
    open_guidance
    send_key(ENTER)
    draft = @app.instance_variable_get(:@settings_draft)
    assert_equal Meringue::Experiments::WorkerSpawningGuidance.default_text, draft.value(GUIDANCE_ID)
    assert_includes draft.global_error, "editor failed"

    @editor = Editor.new("status" => "cancelled", "message" => "cancelled")
    @app.instance_variable_set(:@workspace_controller, @editor)
    open_guidance
    send_key(ENTER)
    assert_equal Meringue::Experiments::WorkerSpawningGuidance.default_text, draft.value(GUIDANCE_ID)
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

  def send_key(key)
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    @app.send(:handle_key, key, "", 0, -1, @handler, compose)
  end

  def open_guidance
    @app.send(:open_settings, @state)
    2.times { send_key(TAB) }
    index = snapshot.fetch("rows").index { |row| row.fetch("id") == GUIDANCE_ID }
    @app.instance_variable_set(:@settings_row_index, index)
  end
end
