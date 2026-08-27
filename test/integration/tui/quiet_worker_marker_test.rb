# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "time"

# The AgentTree chip and status-bar count that say how long a working agent has been silent.
#
# `● W1  Draw three-pane layout` looked the same two seconds into a turn and forty minutes into
# silence. These tests pin the chip, the threshold that gates it, the states it must stay out of,
# and the presentation cache - which has to re-render the chip when the minute it displays
# changes and on no other frame.
class TuiQuietWorkerMarkerTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane

  def setup
    @pane = Pane.new
  end

  def test_a_quiet_working_worker_is_marked_with_how_long_it_has_been_silent
    row = worker_row(quiet_for: 40 * 60)

    assert_includes row, "quiet 40m"
  end

  def test_a_worker_that_just_spoke_carries_no_marker
    refute_includes worker_row(quiet_for: 30), "quiet"
  end

  def test_the_marker_appears_only_once_the_threshold_is_crossed
    refute_includes worker_row(quiet_for: 899, threshold: 900), "quiet"
    assert_includes worker_row(quiet_for: 901, threshold: 900), "quiet"
  end

  def test_zero_turns_the_marker_off
    refute_includes worker_row(quiet_for: 3 * 3_600, threshold: 0), "quiet"
  end

  def test_durations_read_in_the_largest_useful_unit
    assert_includes worker_row(quiet_for: 90, threshold: 60), "quiet 1m"
    assert_includes worker_row(quiet_for: 3_600), "quiet 1h"
    assert_includes worker_row(quiet_for: 3_600 + (25 * 60)), "quiet 1h 25m"
  end

  # A worker that is not supposed to be producing anything is silent on purpose.
  def test_a_worker_that_is_not_working_is_never_quiet
    %w[queued idle paused blocked completed errored killed].each do |status|
      refute_includes worker_row(quiet_for: 3 * 3_600, status: status), "quiet", status
    end
  end

  def test_a_worker_still_waiting_on_its_worktree_is_never_quiet
    row = worker_row(quiet_for: 3 * 3_600, metadata: { "provisioning_state" => "allocating_workspace" })

    refute_includes row, "quiet"
    assert_includes row, "provisioning workspace"
  end

  # A record with no activity clock has not been watched yet - the kernel seeds one on its first
  # reconciliation pass. Falling back to `updated_at` here looked appealing, but routine
  # reconciliation bookkeeping moves that field, and a state file that had simply been sitting on
  # disk would light up every `working` row at once. Saying nothing is the honest answer.
  def test_a_worker_with_no_activity_clock_is_not_guessed_at
    moved = (Time.now.utc - (30 * 60)).iso8601
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "updated_at" => moved,
                                        "harness_metadata" => { "title" => "legacy worker" })]
    )
    state.fetch("metadata")["quiet_worker_warning_seconds"] = 900

    refute_includes row_for(state, "legacy worker"), "quiet"
  end

  # The chip is the one row value that changes with the clock rather than with state, so the
  # cache has to key on the number it shows: identical minute reuses the layout, next minute
  # does not.
  def test_the_row_cache_re_renders_exactly_when_the_displayed_minute_changes
    state = quiet_state(quiet_for: 20 * 60)
    first = @pane.lines(state, width: 60)

    assert_same first, @pane.lines(state, width: 60), "an unchanged minute must reuse the laid-out rows"

    later = quiet_state(quiet_for: 21 * 60)
    refute_same first, @pane.lines(later, width: 60)
    assert_includes plain_lines(@pane.lines(later, width: 60)).join("\n"), "quiet 21m"
  end

  # The chip changes how a row wraps, so the clickable-row map has to see the same chip the
  # renderer did or clicks land on the wrong worker.
  def test_the_clickable_row_map_stays_aligned_with_the_rendered_rows
    state = quiet_state(quiet_for: 40 * 60)

    [30, 44, 60, 100].each do |width|
      assert_equal @pane.lines(state, width: width).length,
                   @pane.line_item_ids(state, width: width).length,
                   "row map desynchronised at width #{width}"
    end
  end

  def test_the_status_bar_counts_quiet_workers_beside_the_working_ones
    state = quiet_state(quiet_for: 40 * 60)
    state.fetch("agents") << agent_record("P1-I1-W2", "issue_id" => "P1-I1",
                                                      "harness_metadata" => { "title" => "busy", "last_activity_at" => Time.now.utc.iso8601 })

    segments = Meringue::TUI::Panes::ChatPane.new.bottom_status_bar_components(state).fetch("workers")
    text = segments.map(&:first).join

    assert_includes text, "2 workers"
    assert_includes text, "1 quiet"
  end

  def test_the_status_bar_says_nothing_about_quiet_when_none_are
    state = quiet_state(quiet_for: 10)

    text = Meringue::TUI::Panes::ChatPane.new.bottom_status_bar_components(state).fetch("workers").map(&:first).join

    assert_includes text, "1 worker"
    refute_includes text, "quiet"
  end

  # The kernel publishes the threshold into state metadata. A dashboard that has not seen a
  # reconciliation pass yet must still behave, not treat "absent" as "off".
  def test_an_unpublished_threshold_falls_back_to_the_shipped_default
    assert_equal Meringue::TUI::Settings::DEFAULT_QUIET_WORKER_WARNING_SECONDS,
                 Meringue::TUI::Settings.quiet_worker_warning_seconds({})
    assert_equal Meringue::TUI::Settings::DEFAULT_QUIET_WORKER_WARNING_SECONDS,
                 Meringue::TUI::Settings.quiet_worker_warning_seconds("metadata" => { "quiet_worker_warning_seconds" => "nonsense" })
    assert_equal 0, Meringue::TUI::Settings.quiet_worker_warning_seconds("metadata" => { "quiet_worker_warning_seconds" => 0 })
  end

  def test_compact_duration_covers_the_units_it_renders
    compact = Meringue::TUI::Timestamps
    assert_equal "0s", compact.compact_duration(0)
    assert_equal "59s", compact.compact_duration(59)
    assert_equal "1m", compact.compact_duration(60)
    assert_equal "59m", compact.compact_duration(3_599)
    assert_equal "2h", compact.compact_duration(7_200)
    assert_equal "2h 1m", compact.compact_duration(7_260)
    assert_nil compact.compact_duration(-1)
  end

  private

  def quiet_state(quiet_for:, threshold: 900, status: "working", metadata: {})
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record(
        "P1-I1-W1",
        "issue_id" => "P1-I1",
        "status" => status,
        "harness_metadata" => {
          "title" => "draw the layout",
          "last_activity_at" => (Time.now.utc - quiet_for).iso8601
        }.merge(metadata)
      )]
    )
    state.fetch("metadata")["quiet_worker_warning_seconds"] = threshold
    state
  end

  def worker_row(**options)
    row_for(quiet_state(**options), "draw the layout")
  end

  # The chip can wrap onto its own line. Every fixture here renders exactly one worker, so the
  # whole tree is the row and the assertions cannot miss a chip that wrapped.
  def row_for(state, title)
    lines = plain_lines(@pane.lines(state, width: 60))
    assert lines.any? { |line| line.include?(title) }, "expected a row for #{title.inspect} in #{lines.inspect}"
    lines.join(" ")
  end
end
