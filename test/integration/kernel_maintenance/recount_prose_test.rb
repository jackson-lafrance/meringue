# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Id-shaped tokens in prose are not always ids. `Prepare Q3 revenue report` and `the G2 Crowd
# review` are the user's words, and a recount that renamed nothing must not edit them into
# `Q3 (old id)`. The line between prose and reference is drawn by the pass itself: a token is
# marked only when the recount hands that exact spelling to a surviving record, because that is the
# one case where leaving it bare would make it read as that record's history.
class KernelMaintenanceRecountProseTest < Minitest::Test
  include KernelMaintenanceSupport

  TITLE = "Prepare Q3 revenue report"
  DESCRIPTION = "Treat as P1 priority; see the G2 Crowd review."

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  # One project, one issue, no questions, no goals: nothing in the tree is named Q3 or G2 before or
  # after the pass, and P1 keeps its own id.
  def prose_only_state
    state_fixture(
      projects: [project_record(id: "P1", name: "Reports", status: "working")],
      issues: [issue_record(id: "P1-I1", project_id: "P1", title: TITLE, status: "working",
                            extra: { "description" => DESCRIPTION })]
    )
  end

  # The same text, but the compaction gives `Q3` and `G2` to surviving records: questions
  # Q2/Q4/Q7 become Q1/Q2/Q3 and goals G4/G5 become G1/G2. Neither `Q3` nor `G2` named anything
  # before the pass, so a bare token would now read as the renumbered record's history.
  def reused_spelling_state
    state = state_fixture(
      projects: [project_record(id: "P1", name: "Reports", status: "working")],
      issues: [issue_record(id: "P1-I1", project_id: "P1", title: TITLE, status: "working",
                            extra: { "description" => DESCRIPTION })],
      questions: [
        question_record(id: "Q2", project_id: "P1", issue_id: "P1-I1", status: "answered"),
        question_record(id: "Q4", project_id: "P1", issue_id: "P1-I1", status: "dismissed"),
        question_record(id: "Q7", project_id: "P1", issue_id: "P1-I1", status: "open")
      ]
    )
    state["goals"] = %w[G4 G5].map do |goal_id|
      {
        "id" => goal_id,
        "issue_id" => "P1-I1",
        "project_id" => "P1",
        "status" => "paused",
        "success_criteria" => "Report renders.",
        "created_at" => BASE_TIME,
        "updated_at" => BASE_TIME
      }
    end
    state["counters"]["goals"] = 5
    state
  end

  def test_prose_that_names_no_record_survives_a_recount_byte_for_byte
    write_state(prose_only_state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    assert_equal 0, result.dig("result", "changed_id_count")
    issue = issue_by_id(read_state, "P1-I1")
    assert_equal TITLE, issue.fetch("title")
    assert_equal DESCRIPTION, issue.fetch("description")
  end

  def test_prose_is_marked_when_the_pass_gives_its_spelling_to_a_surviving_record
    write_state(reused_spelling_state)
    engine = build_engine

    result = apply_command(engine, "Recount", {})

    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    state = read_state
    assert_equal %w[Q1 Q2 Q3], ids(state.fetch("questions"))
    assert_equal %w[G1 G2], ids(state.fetch("goals"))
    issue = issue_by_id(state, "P1-I1")
    assert_equal "Prepare Q3 (old id) revenue report", issue.fetch("title")
    # `P1` still names the same project, so it is rewritten to itself rather than marked.
    assert_equal "Treat as P1 priority; see the G2 (old id) Crowd review.", issue.fetch("description")
  end

  def test_a_second_pass_leaves_untouched_prose_untouched
    write_state(prose_only_state)
    engine = build_engine
    apply_command(engine, "Recount", {})

    assert_equal "accepted", apply_command(engine, "Recount", {}).fetch("status")

    issue = issue_by_id(read_state, "P1-I1")
    assert_equal TITLE, issue.fetch("title")
    assert_equal DESCRIPTION, issue.fetch("description")
  end

  def test_a_second_pass_neither_re_marks_nor_unmarks_reused_prose
    write_state(reused_spelling_state)
    engine = build_engine
    apply_command(engine, "Recount", {})
    first = issue_by_id(read_state, "P1-I1")

    second_result = apply_command(engine, "Recount", {})

    assert_equal "accepted", second_result.fetch("status"), second_result.fetch("message")
    assert_equal 0, second_result.dig("result", "changed_id_count")
    second = issue_by_id(read_state, "P1-I1")
    assert_equal first.fetch("title"), second.fetch("title")
    assert_equal first.fetch("description"), second.fetch("description")
    refute_includes second.fetch("title"), "(old id) (old id)"
  end

  # The audit no longer treats every bare prose token as a reference, but it still catches the one
  # prose failure that can be proven after the fact: a spelling this pass renamed away and gave to
  # no record. Nothing legitimate can write that token, so its presence means the rewrite missed it.
  def test_the_audit_still_fails_prose_that_spells_an_id_the_pass_renamed_away
    state = Meringue::State::Models.ensure_state_shape!(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working",
                              extra: { "description" => "Superseded by P4 work." })]
      )
    )

    error = assert_raises(ArgumentError) do
      Meringue::State::Recounter.validate_resolved_ids!(state, { "P4" => true })
    end

    assert_match(/name no record/, error.message)
    assert_match(/P4 \(.*description\)/, error.message)
    # The same text passes when nothing was renamed away: `P4` is then ordinary prose.
    assert Meringue::State::Recounter.validate_resolved_ids!(state, {})
  end
end
