# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiChatPaneTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::ChatPane
  Style = Meringue::TUI::Style

  def setup
    @pane = Pane.new
  end

  def test_empty_composer_shows_the_prompt_placeholder
    lines = @pane.composer_lines(chat_state(""), width: 40)

    assert_equal ["› enter a prompt"], plain_lines(lines)
    assert_equal [], @pane.composer_row_spans(chat_state(""), width: 40)
  end

  def test_composer_renders_the_cursor_marker_at_the_buffer_position
    assert_equal ["› hello_"], plain_lines(@pane.composer_lines(chat_state("hello"), width: 40))
    assert_equal ["› he_llo"], plain_lines(@pane.composer_lines(chat_state("hello", cursor: 2), width: 40))
    assert_equal ["› _hello"], plain_lines(@pane.composer_lines(chat_state("hello", cursor: 0), width: 40))
  end

  def test_cursor_is_clamped_into_the_buffer
    assert_equal ["› hi_"], plain_lines(@pane.composer_lines(chat_state("hi", cursor: 99), width: 40))
    assert_equal ["› _hi"], plain_lines(@pane.composer_lines(chat_state("hi", cursor: -5), width: 40))
  end

  def test_composer_wraps_long_input_and_auto_resizes_row_count
    buffer = "abcdefghijklmnopqrstuvwxyz0123456789"
    rows = plain_lines(@pane.composer_lines(chat_state(buffer), width: 20))

    assert_equal 2, rows.length
    assert_equal "› abcdefghijklmnopqr", rows.first
    assert rows.last.start_with?("  stuvwxyz")
    assert_equal [{ start: 0, length: 18 }, { start: 18, length: 18 }],
                 @pane.composer_row_spans(chat_state(buffer), width: 20)
  end

  def test_hard_newlines_produce_their_own_rows
    rows = plain_lines(@pane.composer_lines(chat_state("line1\nline2"), width: 40))

    assert_equal ["› line1", "  line2_"], rows
    assert_equal [{ start: 0, length: 5 }, { start: 6, length: 5 }],
                 @pane.composer_row_spans(chat_state("line1\nline2"), width: 40)
  end

  def test_trailing_newline_keeps_an_empty_continuation_row
    rows = plain_lines(@pane.composer_lines(chat_state("done\n"), width: 40))

    assert_equal ["› done", "  _"], rows
  end

  def test_composer_selection_is_highlighted_without_changing_the_text
    state = chat_state("select me", selection: { "start" => 2, "end" => 6 })
    line = @pane.composer_lines(state, width: 40).first

    assert_equal "› select me_", plain_line(line)
    assert_includes styles_in(line), Style::SELECTION
  end

  def test_empty_or_reversed_selection_is_ignored
    ["start" => 4, "end" => 4].each do |selection|
      line = @pane.composer_lines(chat_state("select me", selection: selection), width: 40).first

      refute_includes styles_in(line), Style::SELECTION
    end

    reversed = @pane.composer_lines(chat_state("select me", selection: { "start" => 6, "end" => 2 }), width: 40).first
    refute_includes styles_in(reversed), Style::SELECTION
  end

  def test_composer_char_index_maps_rows_and_columns_back_to_the_buffer
    buffer = "abcdefghijklmnopqrstuvwxyz"
    state = chat_state(buffer, cursor: 0)

    assert_equal 0, @pane.composer_char_index_at(state, row: 0, column: 0, width: 20)
    # Clicks to the right of the cursor marker land one column earlier in the
    # buffer, because the marker occupies a visual cell of its own.
    assert_equal 4, @pane.composer_char_index_at(state, row: 0, column: 5, width: 20)
    assert_equal 5, @pane.composer_char_index_at(chat_state(buffer), row: 0, column: 5, width: 20)
    assert_equal 21, @pane.composer_char_index_at(state, row: 1, column: 3, width: 20)
    # Out-of-range rows and columns clamp instead of raising.
    assert_equal 21, @pane.composer_char_index_at(state, row: 99, column: 3, width: 20)
    assert_equal 0, @pane.composer_char_index_at(chat_state(""), row: 0, column: 4, width: 20)
  end

  def test_bottom_hint_line_always_advertises_the_core_interactions
    text = plain_line(@pane.bottom_hint_line(composed_state(empty_state)))

    assert_includes text, "Enter send"
    assert_includes text, "Ctrl-C clear/quit"
    assert_includes text, "Tab focus"
    assert_includes text, "/ commands"
    assert_includes text, "/keybind keys"
  end

  def test_bottom_hint_line_reports_active_agents_open_questions_and_pending_prompts
    demo = plain_line(@pane.bottom_hint_line(composed_state(demo_state)))

    # The lit dot plus the counts carry the meaning; the word "active" did not.
    assert_includes demo, "● 1W 1H"
    refute_includes demo, "active"
    assert_includes demo, "? 1"

    pending = plain_line(@pane.bottom_hint_line(composed_state(empty_state, chat: { "pending_count" => 2 })))
    assert_includes pending, "2 prompts running"

    single = plain_line(@pane.bottom_hint_line(composed_state(empty_state, chat: { "pending_count" => 1 })))
    assert_includes single, "1 prompt running"
  end

  def test_answered_questions_are_not_counted_in_the_hint_line
    state = demo_state
    state["questions"].each { |question| question["status"] = "answered" }

    refute_includes plain_line(@pane.bottom_hint_line(composed_state(state))), "? "
  end

  def test_selection_hints_replace_each_other
    active = plain_line(@pane.bottom_hint_line(composed_state(empty_state, selection: { "active" => true })))
    assert_includes active, "⧉ selection"
    assert_includes active, "Ctrl-C copies"

    status = plain_line(@pane.bottom_hint_line(composed_state(empty_state, selection: { "status" => "copied 3 lines" })))
    assert_includes status, "⧉ copied 3 lines"
    refute_includes status, "Ctrl-C copies"
  end

  def test_delivery_pr_hint_appears_for_the_selected_agent
    issue = issue_record(
      "P1-I1",
      "delivery_pull_request" => {
        "url" => "https://github.com/owner/repo/pull/9",
        "state" => "open",
        "last_checked_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
    )
    state = composed_state(
      empty_state.merge("issues" => [issue], "agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]),
      navigation: { "active" => true, "selected_agent_id" => "P1-I1-W1" }
    )
    text = plain_line(@pane.bottom_hint_line(state))

    assert_includes text, "PR #9 open"
    # Ctrl-B is a documented keybinding, not an inline label repeated every frame.
    refute_includes text, "Ctrl-B"
  end

  def test_untracked_delivery_pr_reports_its_state_instead_of_an_open_hint
    state = composed_state(
      empty_state.merge("issues" => [issue_record("P1-I1")], "agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]),
      navigation: { "active" => true, "selected_agent_id" => "P1-I1-W1" }
    )
    text = plain_line(@pane.bottom_hint_line(state))

    # No verified delivery PR is tracked for the issue, so the hint says that in
    # plain words instead of reading like a failed lookup ("PR unavailable").
    assert_includes text, "no PR yet"
    refute_includes text, "Ctrl-B"
    assert_equal "not tracked", Meringue::TUI::DeliveryPullRequest.status_label(nil)
  end

  def test_bottom_right_status_shows_the_active_harness_label
    assert_equal [], @pane.bottom_right_status_line(composed_state(empty_state))

    state = composed_state(empty_state.merge("metadata" => { "active_harness" => "pi" }))
    assert_equal "harness: Pi", plain_line(@pane.bottom_right_status_line(state))

    labelled = composed_state(empty_state.merge("metadata" => { "active_harness_label" => "Custom Harness" }))
    assert_equal "harness: Custom Harness", plain_line(@pane.bottom_right_status_line(labelled))
  end

  def test_bottom_right_status_distinguishes_future_pi_defaults_from_the_active_harness
    state = composed_state(
      empty_state.merge(
        "metadata" => {
          "active_harness" => "pi",
          "pi_session_defaults" => {
            "model" => "openai/gpt-5.6-sol",
            "thinking_level" => "xhigh"
          }
        }
      )
    )

    text = plain_line(@pane.bottom_right_status_line(state))
    assert_equal "harness: Pi · Pi defaults: openai/gpt-5.6-sol · head xhigh · worker xhigh", text
  end

  def test_bottom_right_status_shows_distinct_role_thinking_defaults
    state = composed_state(
      empty_state.merge(
        "metadata" => {
          "active_harness" => "pi",
          "pi_session_defaults" => {
            "model" => "anthropic/claude-opus-5",
            "roles" => {
              "head" => { "thinking_level" => "low" },
              "worker" => { "thinking_level" => "max" }
            }
          }
        }
      )
    )

    text = plain_line(@pane.bottom_right_status_line(state))
    assert_equal "harness: Pi · Pi defaults: anthropic/claude-opus-5 · head low · worker max", text
  end

  def test_bottom_right_status_shows_distinct_role_model_defaults
    state = composed_state(
      empty_state.merge(
        "metadata" => {
          "active_harness" => "pi",
          "pi_session_defaults" => {
            "roles" => {
              "head" => { "model" => "openai/gpt-5.6-sol", "thinking_level" => "low" },
              "worker" => { "model" => "anthropic/claude-opus-5", "thinking_level" => "max" }
            }
          }
        }
      )
    )

    text = plain_line(@pane.bottom_right_status_line(state))
    assert_equal "harness: Pi · Pi defaults: head openai/gpt-5.6-sol · low · worker anthropic/claude-opus-5 · max", text
  end

  def test_slash_suggestions_only_activate_for_slash_prompts
    assert @pane.slash_prompt?("  /help")
    refute @pane.slash_prompt?("help")
    assert @pane.slash_suggestions?(chat_state("/"))
    refute @pane.slash_suggestions?(chat_state("hello"))
  end

  def test_slash_suggestion_lines_are_windowed_and_marked
    lines = @pane.slash_suggestion_lines(chat_state("/"))

    # Only commands live inside the box; the counter/scroll caption is a separate
    # line the layout draws under it.
    assert_operator lines.length, :<=, Pane::VISIBLE_SUGGESTION_LIMIT
    assert plain_lines(lines).all? { |line| line.include?(" — ") }
    refute plain_lines(lines).any? { |line| line.start_with?("›") }, "nothing is selected until the user navigates"

    selected = @pane.slash_suggestion_lines(composed_state(empty_state, chat: { "input_buffer" => "/", "slash_suggestion_index" => 0 }))
    assert plain_lines(selected).first.start_with?("› ")
    assert_includes styles_in(selected.first), Style::ACCENT_BOLD
  end

  # A three-row window over a long list must say how many entries exist, so a
  # harness catalog of a hundred models cannot look like a three-item list. That
  # caption is not a list row: it renders below the box (see the layout test).
  def test_a_long_suggestion_list_reports_its_size_and_how_to_scroll_below_the_list
    records = @pane.slash_suggestion_records(chat_state("/"))
    skip_unless_enough_commands(records)

    state = chat_state("/")
    caption = plain_line(@pane.popup_footer_line(state))

    assert_equal "1–#{Pane::VISIBLE_SUGGESTION_LIMIT} of #{records.length} commands", caption.split("  ·  ").first
    assert_includes caption, "↑↓ scroll"
    assert_includes caption, "keep typing to filter"
    # Dim/muted only: it is a caption, not an entry.
    assert_equal [Style::MUTED, Style::DIM], styles_in(@pane.popup_footer_line(state))
    # The list itself is commands only.
    refute plain_lines(@pane.popup_lines(state)).any? { |line| line.include?("of #{records.length}") }
    assert_equal Pane::VISIBLE_SUGGESTION_LIMIT, @pane.popup_lines(state).length

    # Scrolling moves the reported window, not just the highlight.
    scrolled = plain_line(
      @pane.popup_footer_line(
        composed_state(empty_state, chat: { "input_buffer" => "/", "slash_suggestion_index" => records.length - 1 })
      )
    )
    assert_includes scrolled, "of #{records.length} commands"
    assert_includes scrolled, "#{records.length - Pane::VISIBLE_SUGGESTION_LIMIT + 1}–#{records.length}"

    # A list that fits the window has nothing to caption.
    assert_empty @pane.popup_footer_line(chat_state("/recount"))
  end

  def test_slash_suggestion_window_follows_the_selection
    records = @pane.slash_suggestion_records(chat_state("/"))
    skip_unless_enough_commands(records)

    last_index = records.length - 1
    lines = plain_lines(
      @pane.slash_suggestion_lines(composed_state(empty_state, chat: { "input_buffer" => "/", "slash_suggestion_index" => last_index }))
    )

    assert_equal records.last.fetch("usage"), lines.last.sub("› ", "").split(" — ").first
  end

  # `/thinking` shows a seven-level ladder through a three-row window, so the
  # popup must lead with the level actually in force and caption how many more
  # exist. Before this, the window silently ended at the level the model catalog
  # happened to advertise and the saved default could be missing entirely.
  def test_thinking_popup_leads_with_the_current_default_and_captions_the_whole_ladder
    state = composed_state(
      empty_state.merge(
        "metadata" => {
          "active_harness" => "pi",
          "pi_session_defaults" => {
            "model" => "anthropic-250k-prefer-using-this-one/claude-opus-5",
            "thinking_level" => "max"
          },
          "harness_model_catalogs" => {
            "pi" => Meringue::Harness::ModelCatalog.available(
              harness: "pi",
              models: [{ "provider" => "anthropic-250k-prefer-using-this-one", "id" => "claude-opus-5",
                         "thinking_levels" => %w[off minimal low medium high xhigh], "reasoning" => true }],
              source: "test_catalog"
            ).to_h
          }
        }
      ),
      chat: { "input_buffer" => "/thinking ", "input_cursor" => "/thinking ".length }
    )

    records = @pane.slash_suggestion_records(state)
    assert_equal Meringue::Harness::PiClient::THINKING_LEVELS.length, records.length
    assert_includes records.map { |record| record.fetch("usage") }, "max"

    rows = plain_lines(@pane.slash_suggestion_lines(state))
    assert_equal Pane::VISIBLE_SUGGESTION_LIMIT, rows.length
    assert_includes rows.first, "max — current default"

    caption = plain_line(@pane.slash_suggestion_footer_line(state))
    assert_includes caption, "1–#{Pane::VISIBLE_SUGGESTION_LIMIT} of #{records.length} thinking levels"
    assert_includes caption, "↑↓ scroll"
  end

  def test_unmatched_slash_prompt_reports_no_matching_commands
    lines = plain_lines(@pane.slash_suggestion_lines(chat_state("/definitely-not-a-command")))

    assert_equal ["No matching slash commands."], lines
  end

  def test_composer_lines_never_exceed_the_pane_width_after_canvas_clipping
    buffer = "y" * 400
    state = chat_state(buffer)
    frame_lines = render_lines(composed_state(demo_state, chat: { "input_buffer" => buffer, "input_cursor" => buffer.length }), width: 100, height: 32)

    assert_equal [100], frame_lines.map(&:length).uniq
    assert_operator @pane.composer_row_spans(state, width: 96).length, :>, 1
  end

  private

  def chat_state(buffer, cursor: nil, selection: nil)
    chat = { "input_buffer" => buffer, "input_cursor" => cursor.nil? ? buffer.length : cursor }
    chat["selection"] = selection if selection
    composed_state(empty_state, chat: chat)
  end

  def plain_text_line(line)
    line.is_a?(Array) ? line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join : line.to_s
  end

  def skip_unless_enough_commands(records)
    return if records.length > Pane::VISIBLE_SUGGESTION_LIMIT

    flunk "expected more than #{Pane::VISIBLE_SUGGESTION_LIMIT} slash commands to exercise windowing"
  end
end
