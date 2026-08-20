# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiThemePickerTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::ChatPane
  Style = Meringue::TUI::Style
  ThemePicker = Meringue::TUI::ThemePicker
  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT

  def setup
    @original_theme = Style.current_colorscheme
    Style.configure!("meringue")
    @submitted = []
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    )
    @pane = Pane.new
    @state = empty_state
  end

  def teardown
    wait_for_submissions(@submitted.length)
    Style.configure!(@original_theme)
  end

  def test_bare_theme_and_themes_open_the_same_picker
    picker = open_picker("/theme")

    assert @pane.theme_picker?(picker)
    assert_equal "themes", @pane.popup_pane_title(picker)
    assert_equal ThemePicker.names, plain_lines(@pane.popup_lines(picker)).map { |line| line.sub(/\A› /, "").sub(/\A  /, "").split("  ").first }
    assert_empty @submitted

    send_key("\e")
    picker = open_picker("/themes")
    assert @pane.theme_picker?(picker)
    assert_equal ThemePicker.names, plain_lines(@pane.popup_lines(picker)).map { |line| line.sub(/\A› /, "").sub(/\A  /, "").split("  ").first }
  end

  def test_highlighting_a_theme_previews_it_live
    picker = open_picker
    original_accent = Style::ACCENT.dup
    send_key("\e[B")

    preview = compose
    selected = ThemePicker.names.fetch(@pane.theme_picker_index(preview))
    assert_equal selected, Style.current_colorscheme
    refute_equal original_accent, Style::ACCENT
    assert_includes plain_lines(@pane.popup_lines(preview)), "› #{selected}  preview"
  end

  def test_enter_persists_the_highlighted_theme_through_the_existing_command
    open_picker
    send_key("\e[B")
    selected = Style.current_colorscheme

    send_key("\r")

    assert_equal ["/theme #{selected}"], wait_for_submissions(1)
    refute @pane.theme_picker?(compose)
    assert_equal selected, Style.current_colorscheme
  end

  def test_escape_restores_the_original_theme_without_submitting
    open_picker
    send_key("\e[B")
    refute_equal "meringue", Style.current_colorscheme

    send_key("\e")

    refute @pane.theme_picker?(compose)
    assert_equal "meringue", Style.current_colorscheme
    assert_empty @submitted
  end

  def test_clicking_away_cancels_and_clicking_a_row_saves
    open_picker
    send_key(press_event("x" => 3, "y" => 3))
    refute @pane.theme_picker?(compose)
    assert_equal "meringue", Style.current_colorscheme

    picker = open_picker
    row = screen_position_for_row(picker, 0)
    send_key(press_event(row))

    assert_equal ["/theme catppuccin"], wait_for_submissions(1)
    refute @pane.theme_picker?(compose)
    assert_equal "catppuccin", Style.current_colorscheme
  end

  def test_unhandled_typing_cancels_preview_and_reaches_the_composer
    open_picker
    send_key("\e[B")

    result = @app.send(:handle_key, "x", "", 0, -1, prompt_handler, compose)

    assert_equal ["x", 1, -1], result
    assert_equal "meringue", Style.current_colorscheme
    refute @pane.theme_picker?(compose)
  end

  def test_theme_with_a_name_keeps_the_existing_slash_command_behavior
    result = @app.send(:handle_key, "\r", "/theme gruvbox", "/theme gruvbox".length, -1, prompt_handler, compose)

    assert_equal ["", 0, -1], result
    assert_equal ["/theme gruvbox"], wait_for_submissions(1)
    refute @pane.theme_picker?(compose)
    assert_equal "gruvbox", Style.current_colorscheme
  end

  def test_picker_footer_explains_preview_save_and_cancel_keys
    footer = plain_line(@pane.popup_footer_line(open_picker))

    assert_equal "6 themes", footer.split("  ·  ").first
    assert_includes footer, "↑↓ preview"
    assert_includes footer, "Enter save"
    assert_includes footer, "Esc cancel"
  end

  private

  def open_picker(text = "/theme")
    send_key("\r", input_buffer: text)
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
      theme = text.split(" ", 2).last
      {
        "event" => "slash_command_applied",
        "command_results" => [{
          "command_type" => "SetTheme",
          "status" => "accepted",
          "result" => { "theme" => theme }
        }]
      }
    end
  end

  def wait_for_submissions(count)
    deadline = Time.now + 5
    sleep 0.01 while @submitted.length < count && Time.now < deadline
    assert_equal count, @submitted.length, "expected #{count} submitted command(s), got #{@submitted.inspect}"
    @submitted
  end

  def press_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(position)
  end

  def screen_position_for_row(state, index)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        hit = @layout.theme_picker_hit(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        return { "x" => x + 1, "y" => y + 1 } if hit == index
      end
    end
    flunk "no screen position maps to theme row #{index}"
  end
end
