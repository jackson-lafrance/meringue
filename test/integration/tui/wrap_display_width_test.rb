# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# The pane helpers that wrap, ellipsize, and pad text must budget by terminal
# cell, not by codepoint. A row of CJK text measured by String#length used to be
# handed to the canvas at twice the pane width, and the canvas clip then threw
# the second half of the text away instead of wrapping it onto the next row.
class TuiWrapDisplayWidthTest < Minitest::Test
  include TUISupport

  DisplayWidth = Meringue::TUI::DisplayWidth
  ChatPane = Meringue::TUI::Panes::ChatPane
  AgentTreePane = Meringue::TUI::Panes::AgentTreePane
  Markdown = Meringue::TUI::Markdown
  Style = Meringue::TUI::Style

  # Thirty two-cell characters: sixty cells, three full rows of a twenty-cell column.
  CJK_MESSAGE = "日本語のテキストを三十文字ぶん用意して折り返し処理を確かめる"
  CJK_TITLE = "日本語のタイトルがとても長くて三行を超えてしまう場合は省略記号で終わるべきです"
  CJK_PARAGRAPH = "日本語の段落です。これは二十セルで折り返されるはずです。"

  def setup
    @chat = ChatPane.new
    @tree = AgentTreePane.new
  end

  def test_fit_length_counts_characters_that_fit_in_the_cell_budget
    assert_equal 3, DisplayWidth.fit_length("abcdef", 3)
    assert_equal 6, DisplayWidth.fit_length("abcdef", 10)
    assert_equal 2, DisplayWidth.fit_length("日本語", 4)
    assert_equal 2, DisplayWidth.fit_length("日本語", 5), "the fifth cell would hold half of 語"
    assert_equal 2, DisplayWidth.fit_length("e\u0301x", 1), "a combining mark stays with its base"
    assert_equal 0, DisplayWidth.fit_length("日本", 1)
    assert_equal 1, DisplayWidth.fit_length("日本", 1, at_least_one: true), "a wrapper must always make progress"
    assert_equal 2, DisplayWidth.fit_length("日\uFE0F本", 1, at_least_one: true), "the forced glyph keeps its variation selector"
    assert_equal 0, DisplayWidth.fit_length("", 5, at_least_one: true)
    assert_equal 0, DisplayWidth.fit_length("abc", 0)
  end

  def test_slices_hard_wrap_without_splitting_a_character
    assert_equal %w[abc def g], DisplayWidth.slices("abcdefg", 3)
    assert_equal %w[日本 語で す], DisplayWidth.slices("日本語です", 4)
    assert_equal %w[日本 語で す], DisplayWidth.slices("日本語です", 5)
    assert_equal ["a日", "b"], DisplayWidth.slices("a日b", 3)
    assert_equal [], DisplayWidth.slices("", 3)
    assert_equal [1, 2, 0, 1], DisplayWidth.char_widths("a日\u0301b")
    assert_equal [1, 1, 1], DisplayWidth.char_widths("abc")
  end

  def test_chat_log_message_wraps_cjk_by_cells_without_losing_characters
    assert_equal 30, CJK_MESSAGE.length

    logs = [log_record("L1", "message" => CJK_MESSAGE)]
    rows = plain_lines(@chat.log_lines(composed_state(empty_state.merge("logs" => logs)), width: 22))
    body_rows = rows.select { |row| !row.strip.empty? && row.strip.each_char.all? { |char| CJK_MESSAGE.include?(char) } }

    rows.each { |row| assert_operator DisplayWidth.width(row), :<=, 22, row.inspect }
    assert_operator body_rows.length, :>=, 3, "sixty cells of text need at least three twenty-cell rows"
    body_rows.each do |row|
      assert row.start_with?(ChatPane::PLAIN_GUTTER), row.inspect
      assert_operator DisplayWidth.width(row.delete_prefix(ChatPane::PLAIN_GUTTER)), :<=, 20, row.inspect
    end
    assert_equal CJK_MESSAGE.delete(" "), body_rows.join.delete(" ")
  end

  def test_chat_header_segments_wrap_wide_characters_onto_the_next_row
    rows = @chat.send(:wrap_segments, [["ab", Style::TEXT], ["日本語", Style::ACCENT]], 5)

    assert_equal ["ab日", "本語"], plain_lines(rows), "語 does not fit in the one cell left and starts the next row"
    rows.each { |row| assert_operator DisplayWidth.width(plain_line(row)), :<=, 5 }
    assert_equal [Style::TEXT, Style::ACCENT], styles_in(rows.first)
  end

  def test_agent_tree_wraps_and_ellipsizes_cjk_titles_by_cells
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "title" => CJK_TITLE * 2)],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1"), agent_record("P1-I1-W2", "issue_id" => "P1-I1")]
    )

    [24, 34, 41].each do |width|
      lines = @tree.lines(state, width: width)
      ids = @tree.line_item_ids(state, width: width)
      issue_rows = lines.each_with_index.select { |_line, index| ids[index] == "P1-I1" }.map(&:first)
      plain_rows = plain_lines(issue_rows)

      lines.each { |line| assert_operator DisplayWidth.width(plain_line(line)), :<=, width, "width #{width}: #{plain_line(line).inspect}" }
      assert_operator issue_rows.length, :<=, AgentTreePane::MAX_ITEM_LINES, "width #{width}"
      assert_includes plain_rows.join, AgentTreePane::ELLIPSIS, "width #{width} must ellipsize a title this long"
      assert_equal "0/2", styled_text(issue_rows, Style::PR_MARKER), "width #{width}: the worker ratio chip keeps its accent"
      refute_match(/\A\s*\z/, plain_rows.first.split("I1").last.to_s, "width #{width}: the first row still carries title text")
    end
  end

  def test_agent_tree_ellipsis_fits_in_the_cell_budget
    (2..12).each do |width|
      ellipsized = @tree.send(:ellipsize, CJK_TITLE, width)

      assert ellipsized.end_with?(AgentTreePane::ELLIPSIS), "width #{width}"
      assert_operator DisplayWidth.width(ellipsized), :<=, width, "width #{width}: #{ellipsized.inspect}"
      assert_operator DisplayWidth.width(ellipsized), :>=, width - 1, "width #{width} left more than a wide character's spare cell"
    end
  end

  def test_agent_tree_selected_cjk_row_is_padded_to_exactly_the_pane_width
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "title" => "日本語のタイトル")],
      agents: [],
      selected_agent_id: "P1-I1",
      navigation_active: true
    )
    lines = @tree.lines(state, width: 40)
    issue_row = lines.find { |line| plain_line(line).include?("日本語") }

    assert_equal 40, DisplayWidth.width(plain_line(issue_row))
  end

  def test_markdown_wraps_cjk_paragraphs_by_cells_without_splitting_characters
    rows = plain_lines(Markdown.render(CJK_PARAGRAPH, width: 20, gutter: ["▌ ", Style::DIM], base_style: Style::TEXT, accent_style: Style::ACCENT))

    assert_operator rows.length, :>=, 3
    rows.each do |row|
      assert_operator DisplayWidth.width(row), :<=, 20, row.inspect
      assert_includes CJK_PARAGRAPH, row.delete_prefix("▌ "), "a row must never end inside a character"
    end
    assert_equal CJK_PARAGRAPH, rows.map { |row| row.delete_prefix("▌ ") }.join
  end

  def test_markdown_code_blocks_hard_wrap_cjk_by_cells
    rows = plain_lines(Markdown.render("```\n日本語のコードが二十セルを超える行\n```", width: 20, gutter: ["▌ ", Style::DIM], base_style: Style::TEXT, accent_style: Style::ACCENT))

    rows.each { |row| assert_operator DisplayWidth.width(row), :<=, 20, row.inspect }
    assert_equal "日本語のコードが二十セルを超える行", rows.grep(/│/).map { |row| row.delete_prefix("▌ │ ") }.join
  end

  def test_settings_and_workspace_wrappers_hard_wrap_cjk_by_cells
    settings = Meringue::TUI::Panes::SettingsPane.new.send(:wrap, "設定 日本語のとても長い単語がここにあります end", 12)
    workspace = Meringue::TUI::Panes::AgentWorkspacePane.new.send(:wrap_text, "日本語のお知らせです", 10)

    (settings + workspace).each { |row| assert_operator DisplayWidth.width(row), :<=, 12, row.inspect }
    assert_equal "日本語のお知らせです", workspace.join
    assert_equal "設定日本語のとても長い単語がここにありますend", settings.join
    assert_equal 7, Meringue::TUI::HintLine.width([["日本", Style::ACCENT], [" go", Style::MUTED]])
  end

  # Golden strings captured from the codepoint-counting wrappers: ASCII text takes the
  # same rows it always did.
  def test_ascii_wrapping_is_unchanged
    report = "The worker found the shared cursor bug and is preserving the complete report. " * 3
    logs = [
      log_record(
        "L1",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => report,
        "details" => { "kind" => "worker_progress", "progress_kind" => "assistant_text", "issue_id" => "P1-I1" }
      )
    ]
    chat_rows = plain_lines(@chat.log_lines(composed_state(empty_state.merge("logs" => logs, "agents" => [agent_record("P1-I1-W1")])), width: 50))
    assert_equal(
      [
        "▌ The worker found the shared cursor bug and is",
        "▌ preserving the complete report. The worker found",
        "▌ the shared cursor bug and is preserving the",
        "▌ complete report. The worker found the shared",
        "▌ cursor bug and is preserving the complete",
        "▌ report. "
      ],
      chat_rows.drop(1)
    )

    long_title = "Worker with an extremely long title that keeps going and going far past three wrapped rows of pane width"
    tree_state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => long_title })]
    )
    assert_equal(
      [
        "● P1  Project P1",
        "  └─ ● I1  Issue P1-I1 0/1",
        "    └─ ● W1  Worker with an",
        "             extremely long title",
        "             that keeps going and…"
      ],
      plain_lines(@tree.lines(tree_state, width: 34))
    )

    markdown = "A **bold** paragraph of markdown text that wraps at twenty columns.\n\n```\ncode line that is longer than twenty\n```\n- list item that also wraps around"
    assert_equal(
      [
        "▌ A bold paragraph", "▌ of markdown text", "▌ that wraps at", "▌ twenty columns.", "▌ ",
        "▌ ┌─ code", "▌ │ code line that i", "▌ │ s longer than tw", "▌ │ enty", "▌ └─",
        "▌ • list item that", "▌   also wraps", "▌   around"
      ],
      plain_lines(Markdown.render(markdown, width: 20, gutter: ["▌ ", Style::DIM], base_style: Style::TEXT, accent_style: Style::ACCENT))
    )

    settings = Meringue::TUI::Panes::SettingsPane.new.send(:wrap, "settings text that wraps at a narrow width supercalifragilisticexpialidocious end", 12)
    assert_equal %w[settings text\ that wraps\ at\ a narrow\ width supercalifra gilisticexpi alidocious end], settings
    workspace = Meringue::TUI::Panes::AgentWorkspacePane.new.send(:wrap_text, "workspace notice that is hard wrapped\nsecond", 10)
    assert_equal ["workspace ", "notice tha", "t is hard ", "wrapped", "second"], workspace
  end

  private

  def styled_text(rows, style)
    rows.flat_map { |row| Array(row).select { |segment| segment.is_a?(Array) && segment.fetch(1, nil).to_s == style.to_s } }
        .map { |segment| segment.fetch(0).to_s }
        .join
  end
end
