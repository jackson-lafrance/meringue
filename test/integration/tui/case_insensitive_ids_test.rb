# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# The TUI is where ids are typed, so lowercase input must still resolve locally (`/jump h83`) and
# a highlighted id suggestion must insert the canonical id.
class TuiCaseInsensitiveIdsTest < Minitest::Test
  include TUISupport

  def setup
    @state = empty_state.merge(
      "projects" => [project_record("P1")],
      "issues" => [issue_record("P1-I1", "title" => "Fix retries", "agent_ids" => ["P1-I1-W1"])],
      "agents" => [
        agent_record("H83", "harness_metadata" => { "title" => "Pending head", "head_session_state" => "pending" }),
        agent_record(
          "P1-I1-W1",
          "project_id" => "P1",
          "issue_id" => "P1-I1",
          "harness_session_id" => "fake-session-1",
          "harness_metadata" => { "title" => "Inspect retries" }
        )
      ],
      "questions" => [
        {
          "id" => "Q8",
          "head_id" => "H83",
          "question" => "Which environment should I target?",
          "status" => "open",
          "created_at" => "2026-07-11T00:00:00Z",
          "updated_at" => "2026-07-11T00:00:00Z"
        }
      ]
    )
    @app = build_app
  end

  # `/jump <id>` is a local TUI command, so it resolves the id itself.
  def test_local_jump_resolves_lowercase_and_mixed_case_ids_to_the_canonical_worker
    assert_equal "P1-I1-W1", @app.send(:agent_workspace_agent_for_item, @state, "p1-i1-w1").fetch("id")
    assert_equal "P1-I1-W1", @app.send(:agent_workspace_agent_for_item, @state, "P1-i1-W1").fetch("id")
    # An issue id resolves to the issue's newest live worker, in any case.
    assert_equal "P1-I1-W1", @app.send(:agent_workspace_agent_for_item, @state, "p1-i1").fetch("id")
    # An id that names nothing is still unavailable.
    assert_nil @app.send(:agent_workspace_agent_for_item, @state, "p1-i9-w9")
    assert_nil @app.send(:agent_workspace_agent_for_item, @state, "nope")
  end

  def test_highlighted_id_suggestion_completes_a_lowercase_id_to_its_canonical_form
    {
      "/kill h83" => "/kill H83",
      "/kill p1-i1-w1" => "/kill P1-I1-W1",
      "/dismiss q8" => "/dismiss Q8",
      "/prompt p1-i1-w1" => "/prompt P1-I1-W1"
    }.each do |typed, expected|
      completion = @app.send(:safe_slash_completion, typed, 0, @state)

      assert_equal expected, completion.to_s.strip, "completion for #{typed.inspect}"
    end
  end

  # `/session-settings` was removed, so typing it completes nothing: it is unknown text rather
  # than a command with an agent-id argument.
  def test_the_removed_session_settings_command_does_not_complete_an_agent_id
    assert_nil @app.send(:safe_slash_completion, "/session-settings p1-i1-w1", 0, @state)
  end

  def test_an_exact_canonical_id_is_submitted_instead_of_being_recompleted
    assert_nil @app.send(:safe_slash_completion, "/kill H83", 0, @state)
  end
end
