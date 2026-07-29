# frozen_string_literal: true

require "test_helper"
require "support/input_support"

# Contract tests for Meringue::Input::Router: what each kind of user input turns
# into before the kernel sees it.
class InputRouterTest < Minitest::Test
  include InputSupport

  def setup
    @router = Meringue::Input::Router.new
  end

  def test_leading_slash_bypasses_the_head
    route = @router.route('/answer Q1 "use staging"')

    assert_equal "slash_command", route.fetch("kind")
    assert_equal '/answer Q1 "use staging"', route.fetch("input")
    assert_equal ["AnswerQuestion"], route.fetch("commands").map { |command| command.fetch("type") }
    refute_includes route.fetch("commands").map { |command| command.fetch("type") }, "SpawnHead"
  end

  def test_slash_command_route_records_the_stripped_input_for_the_kernel_log
    route = @router.route("   /questions   ")

    assert_equal "slash_command", route.fetch("kind")
    assert_equal "/questions", route.fetch("input")
    assert_equal "ListQuestions", route.fetch("commands").first.fetch("type")
  end

  def test_invalid_slash_command_still_bypasses_the_head
    route = @router.route("/bogus")

    assert_equal "slash_command", route.fetch("kind")
    assert_equal "InvalidSlashCommand", route.fetch("commands").first.fetch("type")
  end

  def test_plain_natural_language_spawns_a_stateless_head
    route = @router.route("add caching to the api layer")

    assert_equal "natural_language", route.fetch("kind")
    assert_equal 1, route.fetch("commands").length
    command = route.fetch("commands").first
    assert_equal "SpawnHead", command.fetch("type")
    assert_equal({ "user_message" => "add caching to the api layer" }, command.fetch("payload"))
  end

  def test_natural_language_route_preserves_raw_text_including_newlines
    route = @router.route("first line\nsecond line")

    assert_equal "natural_language", route.fetch("kind")
    assert_equal "first line\nsecond line", route.fetch("commands").first.fetch("payload").fetch("user_message")
  end

  def test_empty_and_whitespace_input_routes_to_a_head_that_the_kernel_rejects
    ["", "   ", nil].each do |input|
      route = @router.route(input)

      assert_equal "natural_language", route.fetch("kind"), "kind for #{input.inspect}"
      assert_equal "SpawnHead", route.fetch("commands").first.fetch("type")
    end

    assert_equal "", @router.route(nil).fetch("commands").first.fetch("payload").fetch("user_message")
    assert_equal "   ", @router.route("   ").fetch("commands").first.fetch("payload").fetch("user_message")

    input_sandbox do |sandbox|
      result = sandbox.apply("SpawnHead", "user_message" => "   ")

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("errors"), "user_message is required"
      assert_empty sandbox.agents
    end
  end

  # The router is stateless: it cannot see open questions, so merely mentioning a
  # question id is never treated as an answer. Inferring an implicit answer is a
  # head responsibility (see test/findings/input.md).
  def test_mentioning_a_question_id_is_not_assumed_to_be_an_answer
    ["what about Q1?", "ANSWERING Q4 I meant the text snippet", "Q1 is still confusing"].each do |input|
      route = @router.route(input)

      assert_equal "natural_language", route.fetch("kind"), "kind for #{input.inspect}"
      command = route.fetch("commands").first
      assert_equal "SpawnHead", command.fetch("type")
      assert_equal({ "user_message" => input }, command.fetch("payload"))
      refute command.fetch("payload").key?("question_id"), "#{input.inspect} must not fabricate a question_id"
    end
  end

  # The router accepts an injected parser, which is how the TUI and the prompt
  # loop share one slash-command contract.
  def test_router_uses_the_injected_slash_command_parser
    fake_parser = Class.new do
      def parse(_input)
        Meringue::Kernel::Command.new(type: "Help", payload: { "injected" => true })
      end
    end.new

    route = Meringue::Input::Router.new(slash_command_parser: fake_parser).route("/anything")

    assert_equal "slash_command", route.fetch("kind")
    assert_equal({ "type" => "Help", "payload" => { "injected" => true } }, route.fetch("commands").first)
  end

  def test_every_routed_command_is_a_validated_kernel_command_shape
    ["/help", "/answer Q1 yes", "plain english request", ""].each do |input|
      route = @router.route(input)

      route.fetch("commands").each do |command|
        assert_equal %w[type payload], command.keys, "keys for #{input.inspect}"
        assert_kind_of String, command.fetch("type")
        assert_kind_of Hash, command.fetch("payload")
      end
    end
  end
end
