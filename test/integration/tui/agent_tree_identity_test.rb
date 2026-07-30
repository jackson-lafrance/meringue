# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Rendering coverage for agent identity in the AgentTree.
#
# Every agent row shows its harness logo and its identity color, in every
# lifecycle status: a working agent and one with a completion check mark are
# equally identifiable. The color is the same per-id assignment the logs pane
# and the chat composer use (Style::AGENT_PALETTE via Style.agent_palette_index),
# so one agent is one color everywhere. Status stays legible next to it, and the
# logo column is exactly one cell wide for every harness, known or not.
class TuiAgentTreeIdentityTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane
  Style = Meringue::TUI::Style
  Registry = Meringue::Harness::Registry

  ALL_STATUSES = Pane::STATUS_DOTS.keys.freeze

  def setup
    @pane = Pane.new
  end

  def test_working_and_completed_agents_both_carry_their_color_and_logo
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "working", "harness" => "pi",
                               "harness_metadata" => { "title" => "live work" }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "status" => "completed", "harness" => "pi",
                               "harness_metadata" => { "title" => "done work" })
    )
    live = row(state, "live work")
    done = row(state, "done work")

    assert_includes plain_line(live), "● π W1"
    assert_includes plain_line(done), "✓ π W2"
    # Identity color on the logo and the id, for both statuses.
    assert_includes styles_in(live), Style.agent_body_style("P1-I1-W1")
    assert_includes styles_in(done), Style.agent_body_style("P1-I1-W2")
    refute_equal Style.agent_body_style("P1-I1-W1"), Style.agent_body_style("P1-I1-W2")
    # Status is still readable: its own semantic color on the glyph, plus the
    # muted title that already marks a completed row.
    assert_includes styles_in(live), Pane::STATUS_STYLES.fetch("working")
    assert_includes styles_in(done), Pane::STATUS_STYLES.fetch("completed")
    assert_includes styles_in(live), Style::TEXT
    assert_includes styles_in(done), Style::MUTED
  end

  def test_every_lifecycle_status_keeps_the_identity_color_and_logo
    agents = ALL_STATUSES.each_with_index.map do |status, index|
      agent_record(
        "P1-I1-W#{index + 1}",
        "issue_id" => "P1-I1",
        "status" => status,
        "harness" => "pi",
        "harness_metadata" => { "title" => "#{status} worker" }
      )
    end
    state = agent_tree(*agents)

    ALL_STATUSES.each_with_index do |status, index|
      id = "P1-I1-W#{index + 1}"
      line = row(state, "#{status} worker")
      text = plain_line(line)

      assert_includes text, "#{Pane::STATUS_DOTS.fetch(status)} π W#{index + 1}", "#{status} row layout"
      assert_includes styles_in(line), Style.agent_body_style(id), "#{status} row identity color"
      assert_includes styles_in(line), Pane::STATUS_STYLES.fetch(status), "#{status} row status color"
    end
  end

  def test_heads_carry_their_identity_color_and_render_their_logo_bold
    state = agent_tree(
      agent_record("H1", "status" => "working", "harness" => "pi", "harness_metadata" => { "title" => "routing head" }),
      agent_record("H2", "status" => "completed", "harness" => "pi", "harness_metadata" => { "title" => "settled head" })
    )

    %w[H1 H2].each_with_index do |id, index|
      line = row(state, index.zero? ? "routing head" : "settled head")

      assert_includes plain_line(line), "π #{id}"
      # Bold logo like the head's log header, plain id in the same hue.
      assert_includes styles_in(line), Style.agent_style(id, kind: "head")
      assert_includes styles_in(line), Style.agent_body_style(id)
    end
  end

  def test_the_tree_color_matches_the_logs_and_the_composer_for_the_same_agent
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness" => "pi",
                               "harness_metadata" => { "title" => "shared color" })
    )
    tree_styles = styles_in(row(state, "shared color"))

    # Logs gutter/body color, tree color, and composer tint are one assignment.
    assert_includes tree_styles, Style.agent_body_style("P1-I1-W1")
    assert_includes tree_styles, Style.agent_chrome_style("P1-I1-W1", bold: false)
  end

  # The same assignment reaches every surface that is about one agent: the tree
  # row, its log rows, the filtered logs pane title, the composer that prompts
  # it, and the focused workspace title.
  def test_identity_color_reaches_the_logs_title_and_the_focused_workspace_title
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness" => "pi",
                               "harness_metadata" => { "title" => "settled work" })
    )
    chat = Meringue::TUI::Panes::ChatPane.new
    scoped = state.merge(
      Meringue::TUI::LogScope::STATE_KEY => Meringue::TUI::LogScope.snapshot(state, "P1-I1-W1")
    )
    expected = Style.agent_chrome_style("P1-I1-W1", bold: true)

    assert_equal "logs — P1-I1-W1", chat.log_pane_title(scoped)
    assert_equal expected, chat.log_pane_title_style(scoped)
    assert_equal expected, chat.composer_title_style(scoped)
    # An issue filter uses the issue's color; an unfiltered or project-filtered
    # pane has no single agent, so it keeps the theme's panel title.
    issue_scope = state.merge(Meringue::TUI::LogScope::STATE_KEY => Meringue::TUI::LogScope.snapshot(state, "P1-I1"))
    assert_equal Style.agent_chrome_style("P1-I1", bold: true), chat.log_pane_title_style(issue_scope)
    assert_nil chat.log_pane_title_style(state.merge(Meringue::TUI::LogScope::STATE_KEY => Meringue::TUI::LogScope.snapshot(state, "P1")))
    assert_nil chat.log_pane_title_style(state)

    workspace_pane = Meringue::TUI::Panes::AgentWorkspacePane.new
    workspace = composed_state(
      empty_state.merge("agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi")]),
      workspace: { "active" => true, "agent_id" => "P1-I1-W1", "view" => "agent", "filter" => "all", "messages" => [] }
    )

    assert_equal "focused worker · P1-I1-W1", workspace_pane.title(workspace)
    assert_equal expected, workspace_pane.title_style(workspace)
    assert_nil workspace_pane.title_style(composed_state(empty_state))
  end

  def test_each_shipped_harness_has_its_own_single_cell_logo
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi", "harness_metadata" => { "title" => "pi work" }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness" => "claude", "harness_metadata" => { "title" => "claude work" }),
      agent_record("P1-I1-W3", "issue_id" => "P1-I1", "harness" => "cc", "harness_metadata" => { "title" => "aliased work" }),
      agent_record("P1-I1-W4", "issue_id" => "P1-I1", "harness" => "antigravity", "harness_metadata" => { "title" => "antigravity work" })
    )

    assert_includes plain_line(row(state, "pi work")), "π W1"
    assert_includes plain_line(row(state, "claude work")), "✳ W2"
    # Provider aliases resolve to the same logo as their canonical name.
    assert_includes plain_line(row(state, "aliased work")), "✳ W3"
    assert_includes plain_line(row(state, "antigravity work")), "↑ W4"
    Registry::PROVIDER_GLYPHS.each_value { |glyph| assert_equal 1, glyph.length }
    Registry::PROVIDER_ASCII_GLYPHS.each_value { |glyph| assert_equal 1, glyph.length }
  end

  # An unknown or missing harness must never widen the column or claim to be a
  # shipped backend.
  def test_unknown_and_missing_harnesses_fall_back_to_plain_ascii
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "mystery", "harness_metadata" => { "title" => "unknown harness" }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness" => nil, "harness_metadata" => { "title" => "no harness" }),
      agent_record("P1-I1-W3", "issue_id" => "P1-I1", "harness" => "   ", "harness_metadata" => { "title" => "blank harness" }),
      agent_record("P1-I1-W4", "issue_id" => "P1-I1", "harness" => "!!", "harness_metadata" => { "title" => "junk harness" })
    )

    assert_includes plain_line(row(state, "unknown harness")), "m W1"
    assert_includes plain_line(row(state, "no harness")), "? W2"
    assert_includes plain_line(row(state, "blank harness")), "? W3"
    assert_includes plain_line(row(state, "junk harness")), "? W4"
    assert_equal "?", Registry.provider_glyph(nil)
    assert_equal "?", Registry.provider_glyph("")
    # A blank harness must not inherit the default provider's logo.
    refute_equal Registry::PROVIDER_GLYPHS.fetch("pi"), Registry.provider_glyph("")
    # An unknown harness still keeps its identity color.
    assert_includes styles_in(row(state, "unknown harness")), Style.agent_body_style("P1-I1-W1")
  end

  def test_ascii_glyph_mode_swaps_every_logo_for_its_ascii_twin
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi", "harness_metadata" => { "title" => "pi work" }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness" => "claude", "harness_metadata" => { "title" => "claude work" }),
      agent_record("P1-I1-W3", "issue_id" => "P1-I1", "harness" => "antigravity", "harness_metadata" => { "title" => "antigravity work" })
    )

    with_env("MERINGUE_ASCII_GLYPHS" => "1") do
      assert_includes plain_line(row(state, "pi work")), "p W1"
      assert_includes plain_line(row(state, "claude work")), "c W2"
      assert_includes plain_line(row(state, "antigravity work")), "a W3"
      rendered = plain_lines(@pane.lines(state, width: 60)).join("\n")
      Registry::PROVIDER_GLYPHS.each_value { |glyph| refute_includes rendered, glyph }
    end

    assert_includes plain_line(row(state, "pi work")), "π W1"
  end

  # Issue and project rows have no harness of their own, so they reserve the
  # logo cell instead. Ids therefore stay in one column even when a child issue
  # and a worker are siblings at the same depth.
  def test_issue_and_project_rows_reserve_the_logo_cell_so_ids_stay_aligned
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi", "harness_metadata" => { "title" => "sibling worker" }),
      issues: [
        issue_record("P1-I1", "title" => "parent issue"),
        issue_record("P1-I2", "title" => "sibling issue", "parent_issue_id" => "P1-I1")
      ]
    )
    worker = plain_line(row(state, "sibling worker"))
    child_issue = plain_line(row(state, "sibling issue"))

    assert_equal worker.index("W1"), child_issue.index("I2"), "sibling ids share one column"
    assert_includes plain_line(row(state, "Project P1")), "●   P1"
    assert_includes child_issue, "●   I2"
  end

  def test_selected_rows_keep_their_high_contrast_selection_styling
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi", "harness_metadata" => { "title" => "picked worker" }),
      selected_agent_id: "P1-I1-W1"
    )
    line = row(state, "picked worker")

    # The logo survives selection, but the identity foreground gives way to the
    # selection palette so contrast on the highlight is guaranteed.
    assert_includes plain_line(line), "π W1"
    assert_includes styles_in(line), Style::AGENT_TREE_SELECTED_STATUS
    refute_includes styles_in(line), Style.agent_body_style("P1-I1-W1")
  end

  def test_selecting_a_row_never_reflows_the_tree
    agents = [
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi",
                               "harness_metadata" => { "title" => "First worker with a title long enough to wrap twice" }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness" => "claude",
                               "harness_metadata" => { "title" => "Second worker with a title long enough to wrap twice" })
    ]
    base = agent_tree(*agents)
    selected = agent_tree(*agents, selected_agent_id: "P1-I1-W1")

    assert_equal @pane.lines(base, width: 34).length, @pane.lines(selected, width: 34).length
    assert_equal @pane.line_item_ids(base, width: 34), @pane.line_item_ids(selected, width: 34)
  end

  # Wrapped rows hang under the id, so the reserved logo cell has to be part of
  # the continuation indent too.
  def test_wrapped_agent_rows_stay_aligned_under_their_id
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi",
                               "harness_metadata" => { "title" => "A worker title long enough to wrap onto another row" })
    )
    lines = plain_lines(@pane.lines(state, width: 34))
    first_index = lines.index { |line| line.include?("W1") }
    first = lines.fetch(first_index)
    continuation = lines.fetch(first_index + 1)

    assert_operator continuation.strip.length, :>, 0
    assert_equal first.index("A worker"), continuation.index(/\S/), "continuation aligns with the title column"
  end

  def test_every_colorscheme_colors_agent_rows_from_its_own_palette
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "working", "harness" => "pi",
                               "harness_metadata" => { "title" => "live work" }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "status" => "completed", "harness" => "claude",
                               "harness_metadata" => { "title" => "done work" })
    )

    Style.colorschemes.each do |name|
      with_colorscheme(name) do
        palette = Style::SCHEMES.fetch(name).fetch(Style::AGENT_PALETTE_KEY)

        %w[live done].each do |kind|
          id = kind == "live" ? "P1-I1-W1" : "P1-I1-W2"
          line = row(state, "#{kind} work")
          expected = Style.ansi(38, 5, palette.fetch(Style.agent_palette_index(id)))

          assert_includes styles_in(line), expected, "#{name} #{kind} identity color"
          refute_equal Style::DIM.to_s, expected, "#{name} identity color must not be the dim chrome color"
          refute_equal Style::BORDER.to_s, expected, "#{name} identity color must not be the border color"
        end
      end
    end
  end

  def test_pane_rows_never_exceed_the_requested_width_with_logos
    state = agent_tree(
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness" => "pi", "harness_metadata" => { "title" => "a" * 120 }),
      agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness" => "mystery", "harness_metadata" => { "title" => "b" * 120 })
    )

    [20, 24, 34, 42, 80].each do |width|
      lines = plain_lines(@pane.lines(state, width: width))

      assert lines.all? { |line| line.length <= width }, "width #{width}: #{lines.map(&:length).max}"
    end
  end

  private

  def agent_tree(*agents, issues: nil, selected_agent_id: nil)
    tree_state(
      projects: [project_record("P1")],
      issues: issues || [issue_record("P1-I1")],
      agents: agents,
      selected_agent_id: selected_agent_id,
      navigation_active: !selected_agent_id.nil?
    )
  end

  def row(state, text)
    line = @pane.lines(state, width: 60).find { |candidate| plain_line(candidate).include?(text) }
    refute_nil line, "no rendered row contains #{text.inspect}"
    line
  end
end
