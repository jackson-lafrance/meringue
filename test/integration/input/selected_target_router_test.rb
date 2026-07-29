# frozen_string_literal: true

require "test_helper"

class InputSelectedTargetRouterTest < Minitest::Test
  def setup
    @router = Meringue::Input::Router.new
  end

  def test_selected_natural_language_still_spawns_a_head
    route = @router.route(
      "please also cover retries",
      selected_target: {
        "selected_id" => "P1-I2-W3",
        "issue_id" => "P9-I9", # The input layer must not trust this hint.
        "selected_agent_title" => "untrusted title"
      }
    )

    assert_equal "natural_language", route.fetch("kind")
    assert_equal ["SpawnHead"], route.fetch("commands").map { |command| command.fetch("type") }
    refute_includes route.fetch("commands").map { |command| command.fetch("type") }, "PromptAgent"
    assert_equal(
      {
        "user_message" => "please also cover retries",
        "selected_target" => { "selected_id" => "P1-I2-W3" }
      },
      route.fetch("commands").first.fetch("payload")
    )
  end

  def test_issue_id_can_be_supplied_as_the_selected_id
    payload = @router.route("continue", selected_target: "P1-I2")
                     .fetch("commands").first.fetch("payload")

    assert_equal({ "selected_id" => "P1-I2" }, payload.fetch("selected_target"))
  end

  def test_slash_commands_ignore_the_dashboard_target_and_bypass_the_head
    route = @router.route("/help", selected_target: { "selected_id" => "P1-I2-W3" })

    assert_equal "slash_command", route.fetch("kind")
    assert_equal ["Help"], route.fetch("commands").map { |command| command.fetch("type") }
    refute route.fetch("commands").first.fetch("payload").key?("selected_target")
  end
end
