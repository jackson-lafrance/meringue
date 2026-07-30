# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Rendering coverage for the chat composer's target cue.
#
# The composer border, pane title, and prompt marker are tinted with the *same*
# per-id color the logs pane already gives that agent/issue
# (Style::AGENT_PALETTE via Style.agent_palette_index), so the box a user types
# into matches the AgentTree row it will prompt. Every selection state is
# covered here, including the untinted ones that must not read as agent-scoped.
#
# The destination is named exactly once, in the composer pane title above the
# chat bar. The bottom hint line under it carries gestures only (`head routes ·
# Esc clears`, `slash ignores target · Esc clears`, or nothing at all), so the
# same id is never printed twice one row apart.
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

  # The title one row above already reads `chat → P1-I1-W1 · Fix retries`, so the
  # bottom line only owes the user the facts the title cannot carry: a fresh head
  # (not the worker) receives the message, and Esc drops the selection.
  def test_agent_selection_leaves_only_gestures_on_the_bottom_line
    composed = select("P1-I1-W1")

    assert_equal [["head routes · Esc clears", Style::MUTED]], ChatTarget.hint_segments(composed)

    hint = plain_line(@pane.bottom_hint_line(composed))
    assert_includes hint, "head routes"
    assert_includes hint, "Esc clears"
    # The composer title is the single place the target is named.
    assert_includes @pane.composer_pane_title(composed), "P1-I1-W1"
    refute_includes hint, "P1-I1-W1"
    refute_includes hint, "target:"
  end

  # A worker id contains its issue id, so the title resolves the destination on
  # its own. An agent whose id does not encode the issue (a head bound to one)
  # would otherwise lose the resolved issue now that the bottom line drops it.
  def test_an_agent_whose_id_does_not_encode_its_issue_still_names_the_resolved_issue
    @state["agents"] << agent_record("H84", "project_id" => "P1", "issue_id" => "P1-I1")
    composed = select("H84")

    assert_equal "agent", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat → H84 → P1-I1 · Fix retries", @pane.composer_pane_title(composed)
    assert_equal [["head routes · Esc clears", Style::MUTED]], ChatTarget.hint_segments(composed)
    # A worker id already carries its issue, so it is not repeated there.
    assert_equal "chat → P1-I1-W1 · Fix retries", @pane.composer_pane_title(select("P1-I1-W1"))
  end

  # One assertion for the whole contract: whatever a state names in the title, the
  # bottom line must not name again.
  def test_no_selection_state_prints_its_target_id_twice
    [["P1-I1-W1", ""], ["P1-I1", ""], ["P1", ""], ["H83", ""], ["P1-I1-W1", "/prune"], [nil, ""], [nil, "/help"]].each do |item_id, buffer|
      @app.send(:deselect_agent_tree_item) if item_id.nil?
      composed = item_id ? compose(item_id, buffer) : compose_app_state(@app, @state, buffer)
      hint = plain_line(ChatTarget.hint_segments(composed))
      state_name = "#{item_id.inspect} #{buffer.inspect}"

      %w[P1-I1-W1 P1-I1 P1 H83].each do |id|
        refute_includes hint, id, "#{state_name} must not repeat #{id} below the chat bar"
      end
      assert_includes hint, "Esc clears", "#{state_name} keeps the clear gesture" unless item_id.nil?
      assert_empty hint, "#{state_name} has nothing to explain or clear" if item_id.nil?
    end
  end

  def test_issue_selection_tints_from_the_issue_id
    composed = select("P1-I1")

    assert_equal "issue", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat → P1-I1 · Fix retries", @pane.composer_pane_title(composed)
    assert_equal Style.agent_chrome_style("P1-I1", bold: true), @pane.composer_title_style(composed)
    assert_equal [["head routes · Esc clears", Style::MUTED]], ChatTarget.hint_segments(composed)
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
    # The title carries the log-only label (`P1 logs only`) and the logs pane
    # title repeats it, so the bottom line keeps only the gestures.
    assert_equal [["head routes · Esc clears", Style::MUTED]], ChatTarget.hint_segments(composed)
    assert_equal "logs — P1", @pane.log_pane_title(composed)
  end

  def test_unbound_head_selection_is_log_only_too
    composed = select("H83")

    assert_equal "log_only", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · head routes · H83 logs only", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
    assert_equal [["head routes · Esc clears", Style::MUTED]], ChatTarget.hint_segments(composed)
  end

  def test_no_selection_is_untinted_and_says_a_head_routes_the_message
    composed = compose_app_state(@app, @state)

    assert_equal "none", ChatTarget.presentation(composed).fetch("kind")
    assert_equal "chat · head routes", @pane.composer_pane_title(composed)
    assert_nil @pane.composer_border_style(composed, active: true)
    assert_nil @pane.composer_title_style(composed)
    # Nothing is selected, so there is no destination to explain and nothing to
    # clear: the bottom line drops straight to the status/interaction hints.
    assert_empty ChatTarget.hint_segments(composed)
    refute_includes plain_line(@pane.bottom_hint_line(composed)), "Esc clears"
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
    # The title says which selection is being ignored, so the hint only warns.
    assert_equal [["slash ignores target · Esc clears", Style::MUTED]], ChatTarget.hint_segments(composed)
    # The selection itself is untouched: this is a rendering cue, not a routing
    # change.
    assert_equal "P1-I1-W1", Meringue::TUI::LogScope.chat_target(composed).fetch("selected_agent_id")
  end

  def test_slash_command_without_a_selection_stays_quiet
    composed = compose_app_state(@app, @state, "/help")

    assert_equal "chat · slash command", @pane.composer_pane_title(composed)
    assert_empty ChatTarget.hint_segments(composed)
  end

  def test_rendered_frame_tints_the_composer_box_and_the_filtered_logs_title
    composed = select("P1-I1-W1")
    frame = render_frame(composed, width: 100, height: 32, color: true)
    tint = Style.agent_chrome_style("P1-I1-W1", bold: true)

    composer_row = frame.split("\n", -1).find { |line| strip_ansi(line).include?("chat → P1-I1-W1") }
    refute_nil composer_row, "the composer title row should be rendered"
    assert_includes composer_row, tint
    # The tint replaces the focus border color on the composer box.
    refute_includes composer_row, Style::BORDER_ACTIVE

    # The filtered logs pane shares the same identity color on its title only;
    # its box keeps the theme border, so the tint still reads as "this is that
    # agent" rather than as a second focused pane.
    logs_row = frame.split("\n", -1).find { |line| strip_ansi(line).include?("─ logs") }
    assert_includes logs_row, tint
    assert_includes logs_row, Style::BORDER
    assert_includes logs_row, "#{tint} logs — P1-I1-W1 "
    # The AgentTree pane is not about one agent, so its title stays neutral.
    # (It shares this physical row with the logs pane title.)
    assert_includes logs_row, "#{Style::PANEL_TITLE} agent tree "
  end

  def test_the_cue_still_reads_without_color
    frame = render_frame(select("P1-I1-W1"), width: 100, height: 32, color: false)
    hint_row = frame.split("\n", -1).last

    assert_includes frame, "chat → P1-I1-W1 · Fix retries"
    # Identity above the chat bar, gestures below it, and never both.
    assert_includes hint_row, "head routes · Esc clears"
    refute_includes hint_row, "P1-I1-W1"
    refute_match TUISupport::ANSI_PATTERN, frame
  end

  # The hint line is drawn left to right and truncated at the terminal width, so
  # a duplicated target id used to eat the affordances that only live down there.
  # At the minimum supported width the gestures, the delivery-PR indicator, and
  # the first interaction hint all have to survive.
  def test_the_narrow_terminal_hint_line_keeps_the_gestures_and_the_pr_indicator
    # Idle agents so the row carries no "● active" group: the point is the width
    # the target id used to take, not how many workers happen to be running.
    @state["agents"] = @state.fetch("agents").map { |agent| agent.merge("status" => "idle") }
    row = render_frame(select("P1-I1-W1"), width: Meringue::TUI::Layout::MIN_WIDTH, height: 18, color: false).split("\n", -1).last

    assert_includes row, "head routes · Esc clears"
    assert_includes row, "no PR yet"
    assert_includes row, "Enter send"
    refute_includes row, "P1-I1-W1"
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
