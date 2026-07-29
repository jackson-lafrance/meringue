# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "base64"
require "stringio"

class TuiSelectionAndClipboardTest < Minitest::Test
  include TUISupport

  Selection = Meringue::TUI::Selection
  Clipboard = Meringue::TUI::Clipboard

  def teardown
    Clipboard.reset_command_cache!
  end

  def test_points_are_clamped_to_non_negative_content_coordinates
    assert_equal({ "line" => 3, "column" => 7 }, Selection.point(3, 7))
    assert_equal({ "line" => 0, "column" => 0 }, Selection.point(-2, -9))
  end

  def test_normalize_orders_anchor_and_focus_and_records_the_pane
    forward = Selection.normalize("logs", Selection.point(1, 2), Selection.point(4, 0))
    backward = Selection.normalize("logs", Selection.point(4, 0), Selection.point(1, 2))

    assert_equal forward, backward
    assert_equal "logs", Selection.pane(forward)
    assert_equal Selection.point(1, 2), forward.fetch("start")
    assert_equal Selection.point(4, 0), forward.fetch("end")
    assert_nil Selection.normalize(nil, Selection.point(1, 2), Selection.point(4, 0))
    assert_nil Selection.normalize("logs", nil, Selection.point(4, 0))
  end

  def test_empty_selections_are_detected
    point = Selection.point(2, 2)

    assert Selection.empty?(Selection.normalize("logs", point, point.dup))
    assert Selection.empty?(nil)
    refute Selection.empty?(Selection.normalize("logs", point, Selection.point(2, 5)))
    assert_equal "", Selection.pane("not a selection")
  end

  def test_columns_for_covers_partial_first_and_last_lines
    selection = Selection.normalize("logs", Selection.point(1, 2), Selection.point(3, 4))

    assert_nil Selection.columns_for(selection, 0, 10)
    assert_equal (2...10), Selection.columns_for(selection, 1, 10)
    assert_equal (0...10), Selection.columns_for(selection, 2, 10)
    assert_equal (0...4), Selection.columns_for(selection, 3, 10)
    assert_nil Selection.columns_for(selection, 4, 10)
  end

  def test_columns_for_clamps_to_the_available_text_length
    selection = Selection.normalize("logs", Selection.point(0, 2), Selection.point(0, 99))

    assert_equal (2...5), Selection.columns_for(selection, 0, 5)
    assert_nil Selection.columns_for(selection, 0, 1)
    assert_nil Selection.columns_for(nil, 0, 5)
  end

  def test_text_for_joins_the_selected_substrings
    selection = Selection.normalize("logs", Selection.point(0, 6), Selection.point(2, 4))
    texts = { 0 => "hello world", 1 => "middle line", 2 => "final line" }

    assert_equal "world\nmiddle line\nfina", Selection.text_for(selection, texts)
    assert_equal "", Selection.text_for(nil, texts)
    assert_equal "", Selection.text_for(Selection.normalize("logs", Selection.point(0, 1), Selection.point(0, 1)), texts)
  end

  def test_text_for_tolerates_missing_lines
    selection = Selection.normalize("logs", Selection.point(0, 0), Selection.point(2, 3))

    assert_equal "abc\n\n", Selection.text_for(selection, { 0 => "abc" })
  end

  def test_clipboard_falls_back_to_osc52_when_no_command_is_available
    with_path("") do
      output = StringIO.new

      assert_equal "osc52", Clipboard.copy("hello", output: output)
      assert_equal "\e]52;c;#{Base64.strict_encode64("hello")}\a", output.string
    end
  end

  def test_clipboard_copy_reports_failure_without_a_command_or_output
    with_path("") do
      assert_nil Clipboard.copy("hello")
      assert_nil Clipboard.copy("")
      assert_nil Clipboard.copy("y" * (Clipboard::OSC52_LIMIT + 1), output: StringIO.new)
      assert_nil Clipboard.paste
    end
  end

  def test_osc52_sequence_is_base64_encoded
    assert_equal "\e]52;c;#{Base64.strict_encode64("payload")}\a", Clipboard.osc52_sequence("payload")
  end

  def test_clipboard_prefers_a_local_command_when_one_is_on_the_path
    Dir.mktmpdir do |dir|
      sink = File.join(dir, "copied.txt")
      write_script(File.join(dir, "pbcopy"), "cat > #{sink}")
      write_script(File.join(dir, "pbpaste"), "printf pasted")

      with_path("#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH", "")}") do
        assert_equal "command", Clipboard.copy("via command")
        assert_equal "via command", File.read(sink)
        assert_equal "pasted", Clipboard.paste
      end
    end
  end

  def test_available_command_lookup_is_cached_per_name
    Dir.mktmpdir do |dir|
      write_script(File.join(dir, "wl-copy"), "true")

      with_path(dir) do
        assert Clipboard.available?("wl-copy")
        File.delete(File.join(dir, "wl-copy"))
        assert Clipboard.available?("wl-copy"), "the lookup is cached until reset"

        Clipboard.reset_command_cache!
        refute Clipboard.available?("wl-copy")
      end
    end
  end

  private

  def with_path(value)
    with_env("PATH" => value) do
      Clipboard.reset_command_cache!
      yield
    end
  ensure
    Clipboard.reset_command_cache!
  end

  def write_script(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end
end
