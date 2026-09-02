# frozen_string_literal: true

require "test_helper"

class TuiDisplayWidthTest < Minitest::Test
  DisplayWidth = Meringue::TUI::DisplayWidth

  def test_ascii_is_one_cell_per_character
    assert_equal 0, DisplayWidth.width("")
    assert_equal 11, DisplayWidth.width("hello world")
    assert_equal 1, DisplayWidth.char_width("a")
  end

  def test_cjk_hangul_and_fullwidth_forms_are_two_cells
    assert_equal 6, DisplayWidth.width("日本語")
    assert_equal 26, DisplayWidth.width("日本語のタイトルを修正する")
    assert_equal 6, DisplayWidth.width("한국어")
    assert_equal 2, DisplayWidth.char_width("ᄀ"), "Hangul Jamo initial consonant"
    assert_equal 4, DisplayWidth.width("ＡＢ"), "fullwidth Latin"
    assert_equal 2, DisplayWidth.width("￥"), "fullwidth sign"
    assert_equal 2, DisplayWidth.width("\u{20000}"), "CJK extension B"
  end

  def test_emoji_are_two_cells_including_the_check_mark_button
    assert_equal 2, DisplayWidth.width("✅")
    assert_equal 2, DisplayWidth.width("😀")
    assert_equal 2, DisplayWidth.width("🎉")
    assert_equal 2, DisplayWidth.width("🚀")
    assert_equal 2, DisplayWidth.width("🧪")
    assert_equal 2, DisplayWidth.width("🪄")
    assert_equal 2, DisplayWidth.width("❌")
    assert_equal 2, DisplayWidth.width("⭐")
    assert_equal 2, DisplayWidth.width("⌛")
    assert_equal 4, DisplayWidth.width("😀🎉")
  end

  def test_zwj_sequences_and_modifiers_collapse_onto_the_base_emoji
    assert_equal 2, DisplayWidth.width("👨‍👩‍👧‍👦"), "ZWJ family sequence"
    assert_equal 2, DisplayWidth.width("👍🏽"), "skin tone modifier"
    assert_equal 2, DisplayWidth.width("✅\uFE0F"), "a variation selector adds nothing"
  end

  def test_combining_marks_and_zero_width_characters_take_no_cells
    assert_equal 1, DisplayWidth.width("e\u0301")
    assert_equal 0, DisplayWidth.width("\u200B")
    assert_equal 0, DisplayWidth.char_width("\u200D")
    assert_equal 0, DisplayWidth.char_width("\uFEFF")
    assert_equal 0, DisplayWidth.char_width("")
    assert_equal 0, DisplayWidth.char_width("\t"), "control characters are sanitized before drawing"
    assert_equal 4, DisplayWidth.width("ca\u0327fe\u0301")
  end

  def test_narrow_symbols_that_terminals_draw_in_one_cell_stay_one_cell
    assert_equal 1, DisplayWidth.width("✓")
    assert_equal 1, DisplayWidth.width("│")
    assert_equal 1, DisplayWidth.width("▌")
    assert_equal 1, DisplayWidth.width("…")
    assert_equal 1, DisplayWidth.width("é")
  end

  def test_cells_marks_the_continuation_of_a_wide_character_with_an_empty_string
    assert_equal ["a", "b"], DisplayWidth.cells("ab")
    assert_equal ["日", "", "本", ""], DisplayWidth.cells("日本")
    assert_equal ["a", "日", "", "b"], DisplayWidth.cells("a日b")
    assert_equal ["e\u0301", "x"], DisplayWidth.cells("e\u0301x")
    assert_equal ["👨‍👩‍👧‍👦", ""], DisplayWidth.cells("👨‍👩‍👧‍👦")
    assert_equal ["x"], DisplayWidth.cells("\u0301x"), "a leading combining mark has nothing to attach to"
  end

  def test_cells_length_matches_width
    ["", "abc", "日本語", "a日b", "e\u0301", "👨‍👩‍👧‍👦 ok ✅", "\u200Bx", "🎉🎉a"].each do |text|
      assert_equal DisplayWidth.width(text), DisplayWidth.cells(text).length, text.inspect
    end
  end

  def test_truncate_never_splits_a_wide_character
    assert_equal "abc", DisplayWidth.truncate("abcdef", 3)
    assert_equal "abcdef", DisplayWidth.truncate("abcdef", 10)
    assert_equal "日本", DisplayWidth.truncate("日本語", 4)
    assert_equal "日本", DisplayWidth.truncate("日本語", 5), "the fifth cell would hold half of 語"
    assert_equal "日本語", DisplayWidth.truncate("日本語", 6)
    assert_equal "", DisplayWidth.truncate("日本語", 1)
    assert_equal "", DisplayWidth.truncate("abc", 0)
    assert_equal "e\u0301", DisplayWidth.truncate("e\u0301x", 1), "combining marks stay with their base"
  end

  def test_ljust_pads_or_truncates_to_the_exact_cell_count
    assert_equal "ab   ", DisplayWidth.ljust("ab", 5)
    assert_equal "日本  ", DisplayWidth.ljust("日本", 6)
    assert_equal "日本 ", DisplayWidth.ljust("日本語", 5)
    assert_equal "ab...", DisplayWidth.ljust("ab", 5, ".")
    assert_equal 5, DisplayWidth.width(DisplayWidth.ljust("✅ ok", 5))
  end

  def test_char_index_at_maps_a_cell_column_back_to_whole_characters
    assert_equal 2, DisplayWidth.char_index_at("abc", 2)
    assert_equal 3, DisplayWidth.char_index_at("abc", 9)
    assert_equal 0, DisplayWidth.char_index_at("日本語", 0)
    assert_equal 0, DisplayWidth.char_index_at("日本語", 1), "the second half of 日 still resolves before it"
    assert_equal 1, DisplayWidth.char_index_at("日本語", 2)
    assert_equal 3, DisplayWidth.char_index_at("日本語", 6)
    assert_equal 2, DisplayWidth.char_index_at("e\u0301x", 1), "the mark travels with its base"
  end
end
