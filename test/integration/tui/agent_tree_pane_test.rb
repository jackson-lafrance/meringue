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
