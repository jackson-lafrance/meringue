# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiMarkdownTest < Minitest::Test
  include TUISupport

  Markdown = Meringue::TUI::Markdown
  Style = Meringue::TUI::Style
  GUTTER = ["▌ ", Style::DIM].freeze

  def test_headings_keep_their_level_marker_and_gain_emphasis
    lines = render("# Heading one\n## Heading two")

    assert_equal ["▌ # Heading one", "▌ ## Heading two"], plain_lines(lines)
    assert_includes styles_in(lines.first), Style::ACCENT
    assert_includes styles_in(lines.first), Style.with_codes(Style::ACCENT, 1)
  end

  def test_inline_emphasis_code_and_links_render_visibly
    lines = plain_lines(render("Paragraph with **bold**, *italic*, `code`, and a [link](https://example.com)."))

    assert_equal ["▌ Paragraph with bold, italic, `code`,", "▌ and a link (https://example.com)."], lines
  end

  def test_link_labels_are_underlined_and_targets_are_dimmed
    segments = render("see [docs](https://example.com/docs)").first

    assert_includes styles_in(segments), Style.with_codes(Style::TEXT, 4)
    assert_includes styles_in(segments), Style.with_codes(Style::TEXT, 2, 4)
  end

  def test_lists_use_stable_markers_with_aligned_continuations
    lines = plain_lines(render("- bullet one\n- bullet two that is long enough to wrap across the pane width nicely\n1. ordered\n- [x] done\n- [ ] open"))

    assert_equal "▌ • bullet one", lines[0]
    assert_equal "▌ • bullet two that is long enough to", lines[1]
    assert_equal "▌   wrap across the pane width nicely", lines[2]
    assert_equal "▌ 1. ordered", lines[3]
    assert_equal "▌ ☒ done", lines[4]
    assert_equal "▌ ☐ open", lines[5]
  end

  def test_blockquotes_use_a_bar_marker_and_reflow
    lines = plain_lines(render("> quoted text\n> continues here"))

    assert_equal ["▌ │ quoted text continues here"], lines
  end

  def test_horizontal_rules_fill_the_available_width
    lines = plain_lines(render("above\n\n---\n\nbelow"))
    rule = lines.find { |line| line.include?("──") }

    assert_equal 40, rule.length
    assert_includes lines, "▌ above"
    assert_includes lines, "▌ below"
  end

  def test_fenced_code_blocks_are_framed_labelled_and_preserve_whitespace
    lines = plain_lines(render("```ruby\ndef hi\n  :there\nend\n```"))

    assert_equal ["▌ ┌─ code · ruby", "▌ │ def hi", "▌ │   :there", "▌ │ end", "▌ └─"], lines
  end

  def test_indented_code_blocks_are_framed_without_a_language
    lines = plain_lines(render("    indented code"))

    assert_equal "▌ ┌─ code", lines.first
    assert_equal "▌ └─", lines.last
    assert_includes lines, "▌ │ indented code"
  end

  def test_unterminated_fence_still_renders_the_block
    lines = plain_lines(render("```\nunclosed code"))

    assert_equal ["▌ ┌─ code", "▌ │ unclosed code", "▌ └─"], lines
  end

  def test_images_and_autolinks_are_rendered_as_text
    lines = plain_lines(render("![alt](img.png) and <https://example.com/x>"))

    assert_includes lines.join(" "), "[image: alt] (img.png)"
    assert_includes lines.join(" "), "https://example.com/x"
  end

  def test_long_tokens_are_hard_wrapped_to_the_pane_width
    lines = plain_lines(render("a very long single token: #{"a" * 43}", width: 12))

    assert lines.all? { |line| line.length <= 12 }, "longest: #{lines.map(&:length).max}"
    assert_includes lines.join.gsub("▌ ", "").delete(" "), "a" * 43
  end

  def test_nil_width_keeps_everything_on_one_line
    assert_equal ["▌ hello world"], plain_lines(render("hello **world**", width: nil))
  end

  def test_escape_sequences_and_control_characters_are_stripped_before_parsing
    lines = plain_lines(render("\e[31mred\e]0;title\a text\u0007"))

    assert_equal ["▌ red text"], lines
    refute_includes lines.join, "\e"
  end

  def test_invalid_utf8_is_replaced_instead_of_raising
    invalid = "bad \xC3\x28 bytes".dup.force_encoding("UTF-8")

    assert_kind_of Array, Markdown.sanitized_lines(invalid)
    assert_kind_of Array, render(invalid)
  end

  # Recorded actual behavior: sanitized_lines rstrips every row before parsing,
  # so a two-space Markdown hard break is reflowed like a soft break. A trailing
  # backslash is preserved as a hard break. See test/findings/tui.md.
  def test_two_space_hard_break_is_currently_reflowed_but_backslash_breaks_split
    assert_equal ["▌ first line second line"], plain_lines(render("first line  \nsecond line"))
    assert_equal ["▌ first line", "▌ second line"], plain_lines(render("first line\\\nsecond line"))
  end

  def test_soft_line_breaks_are_reflowed_into_one_paragraph
    lines = plain_lines(render("first line\nsecond line"))

    assert_equal ["▌ first line second line"], lines
  end

  def test_blank_content_renders_nothing
    assert_equal [], render("")
    assert_equal [], render("   ")
  end

  def test_styles_are_data_not_embedded_escapes_in_the_text
    lines = render("# Heading with `code`")

    lines.each do |line|
      line.each do |segment|
        text = segment.is_a?(Array) ? segment.fetch(0, "") : segment.to_s
        refute_includes text, "\e", "rendered text must never carry escapes"
      end
    end
  end

  def test_wrapping_accounts_for_the_gutter_and_block_prefix
    wide_gutter = ["»»»» ", Style::DIM]
    lines = Markdown.render(
      "- a list item long enough to need wrapping in a narrow pane",
      width: 24,
      gutter: wide_gutter,
      base_style: Style::TEXT,
      accent_style: Style::ACCENT
    )

    assert plain_lines(lines).all? { |line| line.length <= 24 }, plain_lines(lines).inspect
    assert plain_lines(lines).all? { |line| line.start_with?("»»»» ") }
  end

  private

  def render(text, width: 40)
    Markdown.render(text, width: width, gutter: GUTTER, base_style: Style::TEXT, accent_style: Style::ACCENT)
  end
end
