# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Rendering coverage for the chat composer's target cue.
#
# The composer border, pane title, prompt marker, and bottom chip are tinted
# with the *same* per-id color the logs pane already gives that agent/issue
# (Style::AGENT_PALETTE via Style.agent_palette_index), so the box a user types
# into matches the AgentTree row it will prompt. Every selection state is
# covered here, including the untinted ones that must not read as agent-scoped.
class TuiChatTargetComposerTest < Minitest::Test
  include TUISupport

  Style = Meringue::TUI::Style
  ChatTarget = Meringue::TUI::ChatTarget
  Pane = Meringue::TUI::Panes::ChatPane

  def setup
    @state = empty_state.merge(
      "projects" => [project_record("P1", "name" => "meringue")],
      "issues" => [
        issue_record("P1-I1", "title" => "Fix retries", "agent_ids" => ["P1-I1-W1"]),
        issue_record("P1-I2", "title" => "A deliberately long issue title that will not fit in one border row")
      ],
      "agents" => [
        agent_record("H83", "harness_metadata" => { "title" => "Pending head", "head_session_state" => "pending" }),
        agent_record(
          "P1-I1-W1",
          "project_id" => "P1",
          "issue_id" => "P1-I1",
          "harness_metadata" => { "title" => "Inspect retries" }
        )
      ]
    )
    @app = build_app
    @pane = Pane.new
  end

  def test_agent_selection_tints_the_composer_with_that_agents_own_log_color
    composed = select("P1-I1-W1")

    assert_equal "agent", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "P1-I1-W1", ChatTarget.presentation(composed).fetch("tint_id")
    assert_equal "chat → P1-I1-W1 · Fix retries", @pane.composer_pane_title(composed)

    # Exactly the color that worker's log gutter/body lines already use: one
    # palette, not two.
    assert_equal Style.agent_body_style("P1-I1-W1"), @pane.composer_border_style(composed, active: false)
    assert_equal Style.agent_style("P1-I1-W1", kind: "head"), @pane.composer_title_style(composed)
    # A focused composer keeps its focus cue by going bold in the same hue
    # instead of switching to an unrelated color.
    assert_equal Style.agent_chrome_style("P1-I1-W1", bold: true), @pane.composer_border_style(composed, active: true)
    refute_equal @pane.composer_border_style(composed, active: true), @pane.composer_border_style(composed, active: false)
  end

  def test_agent_selection_tints_the_prompt_marker_and_names_the_target_in_the_placeholder
    composed = select("P1-I1-W1")
    tint = Style.agent_chrome_style("P1-I1-W1", bold: true)

    empty_line = @pane.composer_lines(composed, width: 40).first
    assert_equal "› message P1-I1-W1", plain_line(empty_line)
    assert_equal tint, styles_in(empty_line).first
    assert_includes styles_in(empty_line), Style::MUTED

    typed_line = @pane.composer_lines(compose("P1-I1-W1", "check the retry backoff"), width: 40).first
    assert_equal tint, styles_in(typed_line).first
    # Typed text itself is never tinted, so contrast does not depend on which
    # palette slot the target hashed into.
    assert_includes styles_in(typed_line), Style::TEXT
  end

  def test_agent_chip_names_the_agent_the_resolved_issue_and_the_clear_gesture
    composed = select("P1-I1-W1")
    chip = ChatTarget.chip_segments(composed)

    assert_equal "⌖ target: P1-I1-W1 → P1-I1", plain_line([chip.first])
    assert_equal Style.agent_chrome_style("P1-I1-W1", bold: true), chip.first.fetch(1)
    hint = plain_line(@pane.bottom_hint_line(composed))
    assert_includes hint, "head routes"
    assert_includes hint, "Esc clears"
  end

  def test_issue_selection_tints_from_the_issue_id
    composed = select("P1-I1")

    assert_equal "issue", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat → P1-I1 · Fix retries", @pane.composer_pane_title(composed)
    assert_equal Style.agent_chrome_style("P1-I1", bold: true), @pane.composer_title_style(composed)
    assert_equal "⌖ target: P1-I1", plain_line([ChatTarget.chip_segments(composed).first])
    # An issue and a worker under it are different targets, so they must not be
    # indistinguishable in the composer.
    refute_equal @pane.composer_title_style(select("P1-I1-W1")), @pane.composer_title_style(composed)
  end

  def test_long_issue_titles_are_truncated_instead_of_pushing_the_border_open
    composed = select("P1-I2")
    title = @pane.composer_pane_title(composed)

    assert title.start_with?("chat → P1-I2 · A deliberately long issue")
    assert title.end_with?("…")
    assert_operator title.length, :<=, "chat → P1-I2 · ".length + ChatTarget::MAX_TITLE_LENGTH
  end

  def test_project_selection_is_log_only_and_never_reads_as_agent_scoped
    composed = select("P1")

    assert_equal "log_only", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · head routes · P1 logs only", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
    assert_nil @pane.composer_title_style(composed)
    assert_equal Style::ACCENT_BOLD, ChatTarget.prompt_style(composed)
    assert_equal "enter a prompt", ChatTarget.placeholder(composed)
    chip = plain_line(ChatTarget.chip_segments(composed))
    assert_includes chip, "⌖ logs: P1"
    assert_includes chip, "head routes"
    assert_includes chip, "Esc clears"
  end

  def test_unbound_head_selection_is_log_only_too
    composed = select("H83")

    assert_equal "log_only", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · head routes · H83 logs only", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
    assert_includes plain_line(ChatTarget.chip_segments(composed)), "⌖ logs: H83"
  end

  def test_no_selection_is_untinted_and_says_a_head_routes_the_message
    composed = compose_app_state(@app, @state)

    assert_equal "none", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · head routes", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
    assert_nil @pane.composer_title_style(composed)
    assert_equal [["⌖ no target", Style::DIM]], ChatTarget.chip_segments(composed)
    assert_equal ["› enter a prompt"], plain_lines(@pane.composer_lines(composed, width: 40))
  end

  # Regression for the nil selected-target crash class: an absent selection is
  # normalized to a Hash for renderers, so composing the composer chrome from it
  # must never raise, even when the whole scope key is missing or malformed.
  def test_missing_or_malformed_scope_snapshots_render_as_no_target
    [nil, {}, "nope", { "id" => "" }].each do |scope|
      state = composed_state(@state).merge(Meringue::TUI::LogScope::STATE_KEY => scope)

      assert_equal "none", ChatTarget.presentation(state).fetch("kind")
      assert_equal "chat · head routes", @pane.composer_pane_title(state)
      assert_nil @pane.composer_border_style(state, active: true)
      assert_equal ["› enter a prompt"], plain_lines(@pane.composer_lines(state, width: 40))
    end
  end

  # A pruned/killed/renumbered selection is dropped by reconciliation, so the
  # composer has to fall back to the plainly unscoped presentation rather than
  # keeping a tint for a node that no longer exists.
  def test_stale_selection_dropped_by_reconciliation_falls_back_to_no_target
    assert_equal "chat → P1-I1-W1 · Fix retries", @pane.composer_pane_title(select("P1-I1-W1"))

    pruned = @state.merge("agents" => @state.fetch("agents").reject { |agent| agent.fetch("id") == "P1-I1-W1" })
    composed = compose_app_state(@app, pruned)

    assert_equal "none", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · head routes", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
  end

  # Slash commands never inherit the selection, so the composer must stop
  # promising one the moment the buffer becomes a slash command.
  def test_slash_command_buffer_drops_the_tint_while_a_target_is_selected
    composed = compose("P1-I1-W1", "/prune")

    assert_equal "slash", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · slash command · P1-I1-W1 not targeted", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
    assert_nil @pane.composer_title_style(composed)
    chip = plain_line(ChatTarget.chip_segments(composed))
    assert_includes chip, "⌖ P1-I1-W1"
    assert_includes chip, "slash ignores target"
    # The selection itself is untouched: this is a rendering cue, not a routing
    # change.
    assert_equal "P1-I1-W1", Meringue::TUI::LogScope.chat_target(composed).fetch("selected_agent_id")
  end

  def test_slash_command_without_a_selection_stays_quiet
    composed = compose_app_state(@app, @state, "/help")

    assert_equal "chat · slash command", @pane.composer_pane_title(composed)
    assert_equal [["⌖ no target", Style::DIM]], ChatTarget.chip_segments(composed)
  end

  def test_rendered_frame_tints_the_composer_border_and_title_only
    composed = select("P1-I1-W1")
    frame = render_frame(composed, width: 100, height: 32, color: true)
    tint = Style.agent_chrome_style("P1-I1-W1", bold: true)

    composer_row = frame.split("\n", -1).find { |line| strip_ansi(line).include?("chat → P1-I1-W1") }
    refute_nil composer_row, "the composer title row should be rendered"
    assert_includes composer_row, tint
    refute_includes composer_row, Style::BORDER_ACTIVE

    logs_row = frame.split("\n", -1).find { |line| strip_ansi(line).include?("─ logs") }
    refute_includes logs_row, tint, "only the composer is tinted"
  end

  def test_the_cue_still_reads_without_color
    frame = render_frame(select("P1-I1-W1"), width: 100, height: 32, color: false)

    assert_includes frame, "chat → P1-I1-W1 · Fix retries"
    assert_includes frame, "⌖ target: P1-I1-W1 → P1-I1"
    refute_match TUISupport::ANSI_PATTERN, frame
  end

  def test_every_colorscheme_tints_from_its_own_palette_and_keeps_the_input_readable
    Style.colorschemes.each do |name|
      with_colorscheme(name) do
        composed = select("P1-I1-W1")
        tint = @pane.composer_title_style(composed)
        palette = Style::SCHEMES.fetch(name).fetch(Style::AGENT_PALETTE_KEY)
        expected_code = palette.fetch(Style.agent_palette_index("P1-I1-W1"))

        assert_equal Style.ansi(1, 38, 5, expected_code), tint, "#{name} composer tint"
        refute_equal Style::TEXT.to_s, tint, "#{name} tint must not collide with body text"
        refute_equal Style::MUTED.to_s, tint, "#{name} tint must not collide with the placeholder"

        typed = @pane.composer_lines(compose("P1-I1-W1", "hello"), width: 40).first
        assert_includes styles_in(typed), Style::TEXT, "#{name} keeps input text at full contrast"

        frame = render_frame(composed, width: 100, height: 32, color: true)
        assert_includes strip_ansi(frame), "chat → P1-I1-W1"
        assert_includes frame, tint, "#{name} draws the tint"
      end
    end
  end

  private

  # Click a row, then move focus back to the composer: the state a user actually
  # types their next prompt in.
  def select(item_id, input_buffer = "")
    assert @app.send(:select_agent_tree_item, @state, item_id)
    @app.send(:exit_agent_tree_navigation)
    compose_app_state(@app, @state, input_buffer)
  end

  def compose(item_id, input_buffer)
    select(item_id)
    compose_app_state(@app, @state, input_buffer)
  end
end
