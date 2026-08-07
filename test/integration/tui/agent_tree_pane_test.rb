# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiAgentTreePaneTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane
  Style = Meringue::TUI::Style

  def setup
    @pane = Pane.new
  end

  def test_empty_state_renders_a_single_placeholder_row
    lines = @pane.lines(composed_state(empty_state), width: 34)

    assert_equal ["No AgentTree data yet."], plain_lines(lines)
    assert_equal [nil], @pane.line_item_ids(composed_state(empty_state), width: 34)
  end

  # Every row reads as status, id, title; harness glyphs are intentionally not
  # rendered or reserved in the AgentTree.
  def test_demo_fixture_renders_a_filesystem_like_tree
    rendered = plain_lines(@pane.lines(composed_state(demo_state), width: 34))

    assert_equal "HEADS", rendered.first
    assert_includes rendered, "  ├─ ● H1  Plan TUI rendering"
    assert_includes rendered, "  └─ ✓ H2  Classify dotfiles"
    assert_includes rendered.join("\n"), "● P1  Meringue"
    assert_includes rendered.join("\n"), "  ├─ ● I1  Build fake TUI demo"
    assert_includes rendered.join("\n"), "    └─ ! W1  Wait for real"
    assert_includes rendered.join("\n"), "  │ ├─ ● W1  Draw three-pane"
    assert_includes rendered.join("\n"), "· P2  dotfiles"
  end

  # Regression: a project row read "Meringue working" because the pane joined the
  # project name to its lifecycle status. The status dot already carries the status,
  # exactly like issue and worker rows, so the label is only the product name.
  def test_project_rows_never_append_the_lifecycle_status_to_the_name
    state = tree_state(
      projects: [
        project_record("P1", "name" => "Meringue"),
        project_record("P2", "name" => "World", "status" => "idle")
      ]
    )

    rendered = plain_lines(@pane.lines(state, width: 40))

    assert_includes rendered, "● P1  Meringue"
    assert_includes rendered, "· P2  World"
    Pane::STATUS_DOTS.each_key do |status|
      refute_includes rendered.join("\n"), "Meringue #{status}"
      refute_includes rendered.join("\n"), "World #{status}"
    end
  end

  # A state file written before the kernel enforced the naming contract can still hold
  # a polluted name. The row shows the repaired product name rather than the bad label.
  def test_project_row_strips_a_status_word_left_in_a_stored_name
    state = tree_state(
      projects: [
        project_record("P1", "name" => "Meringue working"),
        project_record("P2", "name" => "World  working", "status" => "idle"),
        project_record("P3", "name" => "", "status" => "queued")
      ]
    )

    rendered = plain_lines(@pane.lines(state, width: 40))

    assert_includes rendered, "● P1  Meringue"
    assert_includes rendered, "· P2  World"
    assert_includes rendered, "○ P3  Untitled project"
  end

  # "Working Copy" is a product name, not a status. Only a trailing status word goes.
  def test_project_row_keeps_a_name_that_only_looks_like_a_status
    state = tree_state(projects: [project_record("P1", "name" => "Working Copy")])

    assert_includes plain_lines(@pane.lines(state, width: 40)), "● P1  Working Copy"
  end

  def test_render_matches_the_plain_text_of_the_segment_lines
    state = composed_state(demo_state)

    assert_equal plain_lines(@pane.lines(state, width: 34)).join("\n"), @pane.render(state, width: 34)
  end

  def test_status_glyphs_and_styles_cover_every_lifecycle_status
    agents = Pane::STATUS_DOTS.keys.each_with_index.map do |status, index|
      agent_record("P1-I1-W#{index + 1}", "issue_id" => "P1-I1", "status" => status, "harness_metadata" => { "title" => "#{status} worker" })
    end
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: agents
    )
    lines = @pane.lines(state, width: 60)

    Pane::STATUS_DOTS.each do |status, glyph|
      row = lines.find { |line| plain_line(line).include?("#{status} worker") }
      refute_nil row, "row for #{status}"
      assert_includes plain_line(row), glyph
      assert_includes styles_in(row), Pane::STATUS_STYLES.fetch(status)
    end
  end

  def test_unknown_status_falls_back_to_a_question_mark_glyph
    state = tree_state(
      projects: [project_record("P1", "status" => "surprising")],
      issues: [],
      agents: []
    )
    line = @pane.lines(state, width: 40).first

    # "?" for the status, then a single separator before the id.
    assert_includes plain_line(line), "? P1"
    assert_includes styles_in(line), Style::MUTED
  end

  def test_completed_records_use_the_muted_title_style
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness_metadata" => { "title" => "done work" }),
        agent_record("P1-I1-W2", "issue_id" => "P1-I1", "status" => "working", "harness_metadata" => { "title" => "live work" })
      ]
    )
    lines = @pane.lines(state, width: 60)
    done = lines.find { |line| plain_line(line).include?("done work") }
    live = lines.find { |line| plain_line(line).include?("live work") }

    assert_includes styles_in(done), Style::MUTED
    assert_includes styles_in(live), Style::TEXT
  end

  def test_relationship_labels_render_for_replacements_and_follow_ups
    rendered = plain_lines(@pane.lines(relationship_state, width: 60)).join("\n")

    assert_includes rendered, "replaces W2"
    assert_includes rendered, "after W1"
    assert_includes rendered, "replaced by W3"
  end

  def test_issue_progress_excludes_replaced_killed_workers
    rendered = plain_lines(@pane.lines(relationship_state, width: 60)).join("\n")

    # W1 completed of W1/W3/W4 visible; the replaced W2 is not counted.
    assert_includes rendered, "1/3"
  end

  # A worker queued behind another agent has not started yet. It must be obvious that it is waiting,
  # and on whom, so it is not mistaken for a worker whose session is still being provisioned.
  def test_a_worker_queued_behind_another_agent_shows_what_it_waits_on
    rendered = plain_lines(@pane.lines(deferred_state, width: 70)).join("\n")

    assert_includes rendered, "waiting on W1"
    assert_includes rendered, "starting after W1"
    # A predecessor on another issue needs its whole id to be identifiable.
    assert_includes rendered, "waiting on P1-I1-W1"
  end

  # A worker held by a script/command condition is not "waiting on W1"; it is waiting for that
  # condition, and the row has to say which one.
  def test_a_worker_queued_behind_a_command_shows_the_condition_it_waits_on
    rendered = plain_lines(@pane.lines(command_gated_state, width: 80)).join("\n")

    assert_includes rendered, "waiting on pair review"
    # The predecessor has already settled by the time a gate is armed, so the row names the gate.
    refute_includes rendered, "waiting on W1"
    # No label supplied: the command itself is shown, bounded like every other marker.
    assert_includes rendered, "waiting on gh pr view --json reviewDec…"
    # A gate that is not armed yet is still waiting on its predecessor.
    assert_includes rendered, "waiting on W2"
  end

  # Regression: a queued worker's "waiting on <label>" text is row status, so it carries the
  # marker accent exactly like "1/3" and "↗". A script gate's label is long enough to wrap at
  # real pane widths, and the wrapped suffix used to match no line end, so the whole marker
  # silently fell back to the plain title style. plain_line() cannot see that, which is why
  # these assertions read the styled segments instead.
  def test_a_command_gated_wait_marker_keeps_the_marker_style_at_every_width
    state = long_gate_state

    gate_marker_widths.each do |width|
      rows = item_rows(state, "P1-I1-W2", width: width)

      assert_equal LONG_GATE_MARKER, marker_text(rows, Style::PR_MARKER), "width #{width}"
      refute_includes styled_text(rows, Style::TEXT), "waiting on", "width #{width} left the marker unstyled"
    end
  end

  # The selected row re-styles the marker instead of dropping it: the accent keeps the
  # selection background, so the highlight covers the suffix like the rest of the row.
  def test_a_selected_command_gated_wait_marker_keeps_the_selected_marker_style
    state = long_gate_state(selected: true)

    gate_marker_widths.each do |width|
      rows = item_rows(state, "P1-I1-W2", width: width)

      assert_equal LONG_GATE_MARKER, marker_text(rows, Style::PR_MARKER_SELECTED), "width #{width}"
      refute_includes styled_text(rows, Style::AGENT_TREE_SELECTED), "waiting on", "width #{width}"
      refute_includes styles_in(rows.first), Style::PR_MARKER, "a selected row never uses the unselected accent"
    end
  end

  # Both verbs and both gate forms are the same marker, so they cannot style differently.
  def test_every_wait_marker_form_uses_the_same_marker_style
    [
      [deferred_state, "P1-I1-W2", "waiting on W1"],
      [deferred_state, "P1-I1-W3", "starting after W1"],
      [deferred_state, "P1-I2-W1", "waiting on P1-I1-W1"],
      [command_gated_state, "P1-I1-W3", "waiting on pair review"],
      [command_gated_state, "P1-I1-W4", "waiting on gh pr view --json reviewDec…"],
      [command_gated_state, "P1-I1-W5", "waiting on W2"]
    ].each do |state, id, marker|
      [34, 44, 80].each do |width|
        rows = item_rows(state, id, width: width)

        assert_equal marker, marker_text(rows, Style::PR_MARKER), "#{id} at width #{width}"
      end
    end
  end

  # A wrapped marker must not be re-styled by rebuilding the text: the styled segments still
  # have to join back to exactly the plain row, with no escape sequence smuggled into the
  # content and no row wider than the pane.
  def test_styling_the_wait_marker_never_leaks_escapes_or_changes_the_row_width
    [long_gate_state, long_gate_state(selected: true)].each do |state|
      (20..80).each do |width|
        @pane.lines(state, width: width).each do |line|
          text = plain_line(line)

          refute_includes text, "\e", "width #{width} leaked an escape sequence into the row text"
          assert_operator text.length, :<=, width, "width #{width} overflowed the pane"
          assert line.all? { |segment| segment.is_a?(Array) && segment.length == 2 }, "width #{width}"
        end
      end
    end
  end

  # The accent has to be a real accent in every bundled theme, not the body style under a
  # different name, and every theme has to keep the selected variant distinct too.
  def test_the_wait_marker_accent_is_distinct_in_every_bundled_colorscheme
    Style.colorschemes.each do |scheme|
      with_colorscheme(scheme) do
        rows = item_rows(long_gate_state, "P1-I1-W2", width: 40)
        selected_rows = item_rows(long_gate_state(selected: true), "P1-I1-W2", width: 40)

        assert_equal LONG_GATE_MARKER, marker_text(rows, Style::PR_MARKER), scheme
        assert_equal LONG_GATE_MARKER, marker_text(selected_rows, Style::PR_MARKER_SELECTED), scheme
        refute_equal Style::TEXT.to_s, Style::PR_MARKER.to_s, "#{scheme} renders the marker as body text"
        refute_equal Style::AGENT_TREE_SELECTED.to_s, Style::PR_MARKER_SELECTED.to_s, scheme
      end
    end
  end

  # The same positional styling has to keep multi-chip suffixes separated when they wrap: a
  # goal chip pushed onto a continuation line keeps its own color next to the PR marker.
  def test_a_wrapped_multi_chip_suffix_keeps_each_chip_in_its_own_style
    state = tree_state(
      projects: [project_record("P1")],
      issues: [
        issue_record(
          "P1-I1",
          "title" => "Keep the flake rate under control for the whole integration suite",
          "delivery_pull_request" => { "url" => "https://github.com/owner/repo/pull/12", "state" => "open" }
        )
      ],
      agents: []
    )
    state["goals"] = [{
      "id" => "G1",
      "issue_id" => "P1-I1",
      "current_iteration" => 2,
      "budget" => { "max_iterations" => 6 },
      "metric" => { "target" => 100, "comparator" => "gte" },
      "baseline_metric" => { "value" => 0 },
      "last_metric" => { "value" => 40 },
      "paused" => true,
      "stop_reason" => "probe_unavailable"
    }]

    # Widths chosen so the goal chip itself is split by the wrap, and one where the title is
    # elided to keep the chips on the row.
    [34, 40, 46, 50, 60].each do |width|
      rows = item_rows(state, "P1-I1", width: width)

      assert_equal "2/6 40% paused stopped: metric unreadable", marker_text(rows, Style::GOAL_MARKER), "width #{width}"
      assert_equal "↗", marker_text(rows, Style::PR_MARKER), "width #{width}"
    end
  end

  def test_a_queued_dependent_still_renders_with_the_queued_status_glyph
    row = @pane.lines(deferred_state, width: 70).find { |line| plain_line(line).include?("waiting on W1") }

    assert_includes plain_line(row), Pane::STATUS_DOTS.fetch("queued")
    assert_includes styles_in(row), Pane::STATUS_STYLES.fetch("queued")
  end

  # Regression: a dependent whose predecessor had settled kept "after W1" on its row for its whole
  # life, so a worker that had been running for minutes still read as queued behind finished work.
  # The queue marker is a pre-start answer only; once the worker starts, the row is live work.
  def test_a_deferred_worker_that_has_started_no_longer_renders_its_queue_marker
    row = @pane.lines(started_deferred_state, width: 70).find { |line| plain_line(line).include?("implement") }

    refute_includes plain_line(row), "after W1"
    refute_includes plain_line(row), "waiting on"
    refute_includes plain_line(row), "starting after"
    assert_includes plain_line(row), Pane::STATUS_DOTS.fetch("working")
  end

  # Dropping the stale marker must not drop the suffixes that share the row.
  def test_a_started_deferred_worker_keeps_its_status_and_pull_request_suffixes
    lines = @pane.lines(started_deferred_state, width: 70)
    worker_row = plain_line(lines.find { |line| plain_line(line).include?("implement") })
    issue_row = plain_line(lines.find { |line| plain_line(line).include?("I1") })

    assert_includes worker_row, "↗"
    refute_includes worker_row, Pane::ELLIPSIS
    assert worker_row.rstrip.end_with?("implement ↗"), worker_row.inspect
    # 1 of 3 workers completed; the queued dependent still counts.
    assert_includes issue_row, "1/3"
  end

  # The fix is narrow: a dependent that has not started yet still says what it is behind.
  def test_a_worker_still_queued_behind_a_running_predecessor_keeps_its_wait_marker
    rendered = plain_lines(@pane.lines(started_deferred_state, width: 70)).join("\n")

    assert_includes rendered, "waiting on W2"
  end

  def test_nested_child_issues_are_indented_under_their_parent
    state = tree_state(
      projects: [project_record("P1")],
      issues: [
        issue_record("P1-I1", "title" => "Parent issue"),
        issue_record("P1-I2", "title" => "Child issue", "parent_issue_id" => "P1-I1"),
        issue_record("P1-I3", "title" => "Grandchild issue", "parent_issue_id" => "P1-I2")
      ],
      agents: []
    )
    rendered = plain_lines(@pane.lines(state, width: 60))

    parent = rendered.index { |line| line.include?("Parent issue") }
    child = rendered.index { |line| line.include?("Child issue") }
    grandchild = rendered.index { |line| line.include?("Grandchild issue") }

    assert_operator parent, :<, child
    assert_operator child, :<, grandchild
    assert_operator indentation(rendered[parent]), :<, indentation(rendered[child])
    assert_operator indentation(rendered[child]), :<, indentation(rendered[grandchild])
  end

  def test_long_titles_wrap_then_truncate_with_an_ellipsis
    long_title = "Worker with an extremely long title that keeps going and going far past three wrapped rows of pane width"
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => long_title })]
    )
    lines = plain_lines(@pane.lines(state, width: 34))
    worker_rows = lines.select { |line| line.match?(/W1|^ {6,}\S/) && !line.include?("I1  ") }

    assert_equal Pane::MAX_ITEM_LINES, worker_rows.length
    assert worker_rows.last.rstrip.end_with?(Pane::ELLIPSIS)
    assert lines.all? { |line| line.length <= 34 }, "no row may exceed the pane content width"
  end

  def test_control_characters_and_whitespace_in_titles_are_normalized
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "title" => "Broken\ttitle\nwith\u0007noise   here")],
      agents: []
    )
    rendered = plain_lines(@pane.lines(state, width: 60)).join("\n")

    assert_includes rendered, "Broken title with noise here"
    refute_includes rendered, "\t"
    refute_includes rendered, "\u0007"
  end

  def test_open_pull_requests_are_marked_on_heads_issues_and_workers
    open_pr = { "url" => "https://github.com/owner/repo/pull/12", "state" => "open" }
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "delivery_pull_request" => open_pr)],
      agents: [
        agent_record("H1", "delivery_pull_request" => open_pr),
        agent_record("P1-I1-W1", "issue_id" => "P1-I1")
      ]
    )
    lines = @pane.lines(state, width: 60)
    head_row = lines.find { |line| plain_line(line).include?("H1") }
    issue_row = lines.find { |line| plain_line(line).include?("I1") }
    worker_row = lines.find { |line| plain_line(line).include?("W1") }

    assert_includes plain_line(head_row), "↗"
    assert_includes plain_line(issue_row), "↗"
    assert_includes plain_line(worker_row), "↗"
    assert_includes styles_in(worker_row), Style::PR_MARKER
  end

  # The PR marker is row status, not decoration, so a title long enough to fill the pane
  # is ellipsized until the marker fits instead of the marker being pushed off the row.
  def test_a_long_title_never_pushes_the_pull_request_marker_off_the_row
    open_pr = { "url" => "https://github.com/owner/repo/pull/12", "state" => "open" }
    long_title = "Rework the delivery pull request marker so it survives a title that fills the whole pane"
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "title" => long_title, "delivery_pull_request" => open_pr)],
      agents: []
    )

    [24, 30, 34, 40].each do |width|
      rendered = plain_lines(@pane.lines(state, width: width))

      assert_includes rendered.join("\n"), "↗", "width #{width} dropped the PR marker"
      assert_includes rendered.join("\n"), Pane::ELLIPSIS, "width #{width} should ellipsize the title instead"
      assert rendered.all? { |line| line.length <= width }, "no row may exceed the pane content width"
    end
  end

  def test_merged_pull_requests_are_not_marked_as_active
    merged_pr = { "url" => "https://github.com/owner/repo/pull/12", "state" => "merged" }
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "delivery_pull_request" => merged_pr)],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    )

    refute_includes plain_lines(@pane.lines(state, width: 60)).join("\n"), "↗"
  end

  def test_selected_row_is_marked_padded_and_styled
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "Selected worker" })],
      selected_agent_id: "P1-I1-W1",
      navigation_active: true
    )
    line = @pane.lines(state, width: 40).find { |candidate| plain_line(candidate).include?("Selected worker") }

    assert plain_line(line).start_with?("▸")
    assert_equal 40, plain_line(line).length, "selected rows pad to the pane width"
    assert_includes styles_in(line), Style::AGENT_TREE_SELECTED
    assert_includes styles_in(line), Style::AGENT_TREE_SELECTED_STATUS
    assert_includes styles_in(line), Style::AGENT_TREE_SELECTED_DIM
  end

  def test_selecting_a_row_does_not_reflow_other_rows
    base = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "First worker with a title long enough to wrap" }),
        agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "Second worker with a title long enough to wrap" })
      ]
    )
    selected = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "First worker with a title long enough to wrap" }),
        agent_record("P1-I1-W2", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "Second worker with a title long enough to wrap" })
      ],
      selected_agent_id: "P1-I1-W1"
    )

    assert_equal @pane.lines(base, width: 34).length, @pane.lines(selected, width: 34).length
    assert_equal @pane.line_item_ids(base, width: 34), @pane.line_item_ids(selected, width: 34)
  end

  def test_line_item_ids_align_with_every_rendered_row
    state = relationship_state
    lines = @pane.lines(state, width: 34)
    ids = @pane.line_item_ids(state, width: 34)

    assert_equal lines.length, ids.length
    assert_equal ids, @pane.line_worker_ids(state, width: 34)

    lines.each_with_index do |line, index|
      text = plain_line(line)
      id = ids[index]
      next if id.nil?

      short = id.to_s.split("-").last
      assert text.include?(short) || continuation_row?(lines, ids, index),
             "row #{index} (#{text.inspect}) should belong to #{id}"
    end
  end

  def test_killed_projects_and_issues_are_never_rendered
    state = tree_state(
      projects: [project_record("P1"), project_record("P2", "status" => "killed", "name" => "Killed project")],
      issues: [issue_record("P1-I1", "title" => "Live issue"), issue_record("P1-I2", "title" => "Killed issue", "status" => "killed")],
      agents: [agent_record("P1-I2-W1", "issue_id" => "P1-I2", "harness_metadata" => { "title" => "orphaned worker" })]
    )
    rendered = plain_lines(@pane.lines(state, width: 60)).join("\n")

    assert_includes rendered, "Live issue"
    refute_includes rendered, "Killed project"
    refute_includes rendered, "Killed issue"
    refute_includes rendered, "orphaned worker"
  end

  def test_records_are_ordered_by_numeric_id
    agents = [
      agent_record("H10", "harness_metadata" => { "title" => "tenth head" }),
      agent_record("H2", "harness_metadata" => { "title" => "second head" }),
      agent_record("H1", "harness_metadata" => { "title" => "first head" })
    ]
    rendered = plain_lines(@pane.lines(tree_state(agents: agents), width: 40))

    assert_operator rendered.index { |line| line.include?("first head") }, :<,
                    rendered.index { |line| line.include?("second head") }
    assert_operator rendered.index { |line| line.include?("second head") }, :<,
                    rendered.index { |line| line.include?("tenth head") }
  end

  def test_pane_lines_never_exceed_the_requested_width
    [20, 34, 42, 80].each do |width|
      lines = plain_lines(@pane.lines(composed_state(demo_state), width: width))

      assert lines.all? { |line| line.length <= width }, "width #{width}: #{lines.map(&:length).max}"
    end
  end

  private

  # The label from the reported row, bounded by Pane::GATE_LABEL_LIMIT.
  LONG_GATE_MARKER = "waiting on CI concluded on shop/world…"

  # Widths where the marker survives the row: below this the whole suffix is ellipsized away,
  # which is truncation behavior rather than styling and is unchanged by this fix.
  def gate_marker_widths
    (26..80).to_a
  end

  # The row the bug was reported on: a queued worker held by a live command gate whose label
  # is long enough to wrap at ordinary AgentTree widths.
  def long_gate_state(selected: false)
    tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness_metadata" => { "title" => "deliver" }),
        agent_record(
          "P1-I1-W2",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W1",
          "harness_metadata" => {
            "title" => "Merge if CI passed, fix it if not",
            "deferred_spawn" => {
              "state" => "waiting",
              "after_agent_id" => "P1-I1-W1",
              "command_gate" => {
                "state" => "pending",
                "armed_at" => "2026-01-01T00:00:00Z",
                "label" => "CI concluded on shop/world PR 953732",
                "command" => "gh pr view --json statusCheckRollup"
              }
            }
          }
        )
      ],
      selected_agent_id: selected ? "P1-I1-W2" : nil,
      navigation_active: selected
    )
  end

  # Every rendered row that belongs to one tree item, wrapped rows included.
  def item_rows(state, id, width:)
    lines = @pane.lines(state, width: width)
    ids = @pane.line_item_ids(state, width: width)

    assert_equal lines.length, ids.length
    lines.each_with_index.select { |_line, index| ids[index] == id }.map(&:first)
  end

  # The chip as the user reads it across a wrap: contiguous styled runs within a row join
  # directly, and the single space the wrap consumed between rows is restored.
  def marker_text(rows, style)
    # The space that separates two chips is styled with the chip that follows it, so a run is
    # stripped before the rows are rejoined.
    rows.map { |row| styled_text([row], style).strip }.reject(&:empty?).join(" ")
  end

  def styled_text(rows, style)
    rows.flat_map { |row| Array(row).select { |segment| segment.is_a?(Array) && segment.fetch(1, nil).to_s == style.to_s } }
        .map { |segment| segment.fetch(0).to_s }
        .join
  end

  def deferred_state
    tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1"), issue_record("P1-I2")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "working", "harness_metadata" => { "title" => "research" }),
        agent_record(
          "P1-I1-W2",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W1",
          "harness_metadata" => { "title" => "implement", "deferred_spawn" => { "state" => "waiting", "after_agent_id" => "P1-I1-W1" } }
        ),
        agent_record(
          "P1-I1-W3",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W1",
          "harness_metadata" => { "title" => "document", "deferred_spawn" => { "state" => "activating", "after_agent_id" => "P1-I1-W1" } }
        ),
        agent_record(
          "P1-I2-W1",
          "issue_id" => "P1-I2",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W1",
          "harness_metadata" => { "title" => "cross issue", "deferred_spawn" => { "state" => "waiting", "after_agent_id" => "P1-I1-W1" } }
        )
      ]
    )
  end

  def command_gated_state
    tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness_metadata" => { "title" => "deliver" }),
        agent_record("P1-I1-W2", "issue_id" => "P1-I1", "status" => "working", "harness_metadata" => { "title" => "still delivering" }),
        agent_record(
          "P1-I1-W3",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W1",
          "harness_metadata" => {
            "title" => "respond to review",
            "deferred_spawn" => {
              "state" => "waiting",
              "after_agent_id" => "P1-I1-W1",
              "command_gate" => {
                "state" => "pending",
                "armed_at" => "2026-01-01T00:00:00Z",
                "label" => "pair review",
                "command" => "gh pr view --json reviewDecision"
              }
            }
          }
        ),
        agent_record(
          "P1-I1-W4",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "harness_metadata" => {
            "title" => "unlabelled gate",
            "deferred_spawn" => {
              "state" => "waiting",
              "command_gate" => {
                "state" => "pending",
                "armed_at" => "2026-01-01T00:00:00Z",
                "command" => "gh pr view --json reviewDecision --jq .reviewDecision"
              }
            }
          }
        ),
        agent_record(
          "P1-I1-W5",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W2",
          "harness_metadata" => {
            "title" => "gate not armed yet",
            "deferred_spawn" => {
              "state" => "waiting",
              "after_agent_id" => "P1-I1-W2",
              "command_gate" => { "state" => "pending", "label" => "pair review", "command" => "gh pr view" }
            }
          }
        )
      ]
    )
  end

  # A follow-up worker that has already started is covered by
  # test_a_deferred_worker_that_has_started_no_longer_renders_its_queue_marker, so W4 here is the
  # not-yet-started follow-up whose lineage the row is supposed to show.
  def relationship_state
    tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed"),
        agent_record("P1-I1-W2", "issue_id" => "P1-I1", "status" => "killed", "replaced_by_agent_id" => "P1-I1-W3"),
        agent_record("P1-I1-W3", "issue_id" => "P1-I1", "status" => "working", "replaces_agent_id" => "P1-I1-W2"),
        agent_record("P1-I1-W4", "issue_id" => "P1-I1", "status" => "queued", "follow_up_of_agent_id" => "P1-I1-W1")
      ]
    )
  end

  # The shape the bug was reported on: W1 settled, W2 was activated behind it and is now running,
  # and W3 is still queued behind W2.
  def started_deferred_state
    tree_state(
      projects: [project_record("P1")],
      issues: [
        issue_record("P1-I1", "delivery_pull_request" => { "url" => "https://github.com/owner/repo/pull/12", "state" => "open" })
      ],
      agents: [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness_metadata" => { "title" => "research" }),
        agent_record(
          "P1-I1-W2",
          "issue_id" => "P1-I1",
          "status" => "working",
          "after_agent_id" => "P1-I1-W1",
          "follow_up_of_agent_id" => "P1-I1-W1",
          "harness_metadata" => {
            "title" => "implement",
            "deferred_spawn" => {
              "state" => "activated",
              "after_agent_id" => "P1-I1-W1",
              "started_at" => "2026-07-11T00:05:00Z"
            }
          }
        ),
        agent_record(
          "P1-I1-W3",
          "issue_id" => "P1-I1",
          "status" => "queued",
          "after_agent_id" => "P1-I1-W2",
          "follow_up_of_agent_id" => "P1-I1-W2",
          "harness_metadata" => { "title" => "document", "deferred_spawn" => { "state" => "waiting", "after_agent_id" => "P1-I1-W2" } }
        )
      ]
    )
  end

  def indentation(line)
    line[/\A[ ▸]*/].to_s.length
  end

  def continuation_row?(lines, ids, index)
    index.positive? && ids[index - 1] == ids[index]
  end
end
