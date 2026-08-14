# frozen_string_literal: true

require "test_helper"

# A HeadResult summary describes the routing decision. Only response is plain user-visible answer
# text, so the TUI must not hide a response-only result or mistake an empty routing result for one.
class TUIHeadResponseRenderingTest < Minitest::Test
  def setup
    @app = Meringue::TUI::App.allocate
  end

  def test_response_only_head_result_renders_the_plain_answer
    lines = user_lines(
      "title" => "Explain queued workers",
      "summary" => "Answered from stable Meringue behavior without orchestration.",
      "response" => "A queued worker starts after its predecessor settles.",
      "commands" => [],
      "questions" => []
    )

    assert_equal ["A queued worker starts after its predecessor settles."], lines
  end

  def test_routing_summary_is_not_rendered_as_a_direct_answer
    lines = user_lines(
      "title" => "Empty result",
      "summary" => "Nothing was routed.",
      "commands" => [],
      "questions" => []
    )

    assert_empty lines
  end

  def test_direct_response_remains_visible_when_the_result_also_routes_work
    lines = user_lines(
      "title" => "Answer and investigate",
      "summary" => "Answered the known part and routed the unknown part.",
      "response" => "The displayed label means those workers have an after-agent dependency.",
      "commands" => [{ "type" => "SpawnWorker", "payload" => { "issue_id" => "P6-I22", "prompt" => "Investigate why." } }],
      "questions" => []
    )

    assert_equal ["The displayed label means those workers have an after-agent dependency."], lines
  end

  private

  def user_lines(result)
    @app.send(:head_result_user_lines, result)
  end
end
