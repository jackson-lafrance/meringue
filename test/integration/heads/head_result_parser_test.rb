# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

# Covers the HeadResult contract boundary: what raw assistant output the kernel
# accepts from a head, and what it rejects.
class HeadResultParserTest < Minitest::Test
  include HeadsSupport

  def test_parses_a_plain_head_result_object
    raw = JSON.generate(
      head_result(
        commands: [kernel_command("AnswerQuestion", "question_id" => "Q4", "answer" => "keep the branch")]
      )
    )

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_equal "Routed the request", result.fetch("title")
    assert_equal 1, result.fetch("commands").length
    assert_equal "AnswerQuestion", result.dig("commands", 0, "type")
    assert_equal "Q4", result.dig("commands", 0, "payload", "question_id")
    assert_empty result.fetch("questions")
  end

  def test_parses_json_wrapped_in_a_code_fence
    raw = <<~OUTPUT
      Here is my decision.

      ```json
      #{JSON.pretty_generate(head_result(commands: [kernel_command("CreateIssue", "project_id" => "P1", "title" => "Fix answering")]))}
      ```

      Let me know if that works.
    OUTPUT

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_equal "CreateIssue", result.dig("commands", 0, "type")
  end

  def test_parses_json_in_an_unlabelled_code_fence
    raw = "```\n#{JSON.generate(head_result)}\n```"

    assert_equal "Routed the request", Meringue::Heads::ResultParser.parse(raw).fetch("title")
  end

  def test_parses_json_embedded_in_prose_without_a_fence
    raw = "I looked at the state. #{JSON.generate(head_result)} That is the routing I chose."

    assert_equal "Routed the request", Meringue::Heads::ResultParser.parse(raw).fetch("title")
  end

  def test_extracts_the_object_even_when_strings_contain_braces_and_quotes
    payload = head_result(
      summary: 'the worker printed {"weird": "json"} and said \"done\"',
      commands: [kernel_command("PromptAgent", "agent_id" => "P1-I1-W1", "prompt" => "use {json} mode", "mode" => "follow_up")]
    )
    raw = "prose before #{JSON.generate(payload)} prose after"

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_equal payload.fetch("summary"), result.fetch("summary")
    assert_equal "follow_up", result.dig("commands", 0, "payload", "mode")
  end

  def test_questions_only_result_is_valid
    raw = JSON.generate(
      head_result(
        title: "Needs clarification",
        summary: "Two issues are plausible, so I asked instead of guessing.",
        commands: [],
        questions: [
          { "question" => "Did you mean P1-I1 or P1-I2?", "context" => "Both mention question answering." }
        ]
      )
    )

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_empty result.fetch("commands")
    assert_equal 1, result.fetch("questions").length
    assert_equal "Did you mean P1-I1 or P1-I2?", result.dig("questions", 0, "question")
  end

  def test_question_context_may_be_a_string_object_or_null
    raw = JSON.generate(
      head_result(
        questions: [
          { "question" => "String context?", "context" => "plain text" },
          { "question" => "Object context?", "context" => { "issue_id" => "P1-I1" } },
          { "question" => "No context?", "context" => nil },
          { "question" => "Missing context key?" }
        ]
      )
    )

    assert_equal 4, Meringue::Heads::ResultParser.parse(raw).fetch("questions").length
  end

  # The parser validates envelope shape only. Command-name validation belongs to
  # the kernel, which rejects unknown commands when it applies the batch.
  def test_unknown_command_types_pass_shape_validation
    raw = JSON.generate(head_result(commands: [kernel_command("DefinitelyNotAKernelCommand", "foo" => "bar")]))

    assert_equal "DefinitelyNotAKernelCommand", Meringue::Heads::ResultParser.parse(raw).dig("commands", 0, "type")
  end

  # AnswerQuestion alongside routing commands is the shape the head contract needs
  # for an answered question to keep flowing into real work.
  def test_answer_question_can_be_batched_with_routing_commands
    raw = JSON.generate(
      head_result(
        commands: [
          kernel_command("AnswerQuestion", "question_id" => "Q4", "answer" => "keep the existing branch"),
          kernel_command("PromptAgent", "agent_id" => "P1-I1-W1", "prompt" => "The user says: keep the existing branch", "mode" => "follow_up")
        ]
      )
    )

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_equal %w[AnswerQuestion PromptAgent], result.fetch("commands").map { |command| command.fetch("type") }
  end

  def test_duplicate_commands_are_preserved_verbatim
    command = kernel_command("AnswerQuestion", "question_id" => "Q4", "answer" => "yes")
    raw = JSON.generate(head_result(commands: [command, command]))

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_equal 2, result.fetch("commands").length
    assert_equal result.fetch("commands").first, result.fetch("commands").last
  end

  def test_large_command_batches_are_accepted_without_truncation
    commands = (1..250).map { |index| kernel_command("PromptAgent", "agent_id" => "P1-I1-W1", "prompt" => "step #{index}") }
    raw = JSON.generate(head_result(commands: commands))

    result = Meringue::Heads::ResultParser.parse(raw)

    assert_equal 250, result.fetch("commands").length
    assert_equal "step 250", result.fetch("commands").last.dig("payload", "prompt")
  end

  def test_extra_top_level_keys_are_allowed
    payload = head_result.merge("notes" => "extra field", "confidence" => 0.9)

    assert_equal "extra field", Meringue::Heads::ResultParser.parse(JSON.generate(payload)).fetch("notes")
  end

  def test_malformed_json_raises_invalid_head_result
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse('{"title": "broken", "summary":')
    end

    assert_equal ["assistant output was not parseable JSON"], error.validation_errors
    assert_includes error.message, "invalid HeadResult JSON"
    assert_equal '{"title": "broken", "summary":', error.raw_output
  end

  def test_prose_without_any_json_raises_invalid_head_result
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse("I could not decide, sorry.")
    end

    assert_equal ["assistant output was not parseable JSON"], error.validation_errors
  end

  def test_empty_and_nil_output_raise_invalid_head_result
    ["", "   ", nil].each do |raw|
      assert_raises(Meringue::Heads::InvalidHeadResultError) { Meringue::Heads::ResultParser.parse(raw) }
    end
  end

  def test_non_object_json_raises_with_shape_errors
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse("[1, 2, 3]")
    end

    assert_equal ["result must be a JSON object"], error.validation_errors
  end

  def test_missing_title_and_summary_are_reported_together
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse(JSON.generate("commands" => [], "questions" => []))
    end

    assert_equal ["title must be a string", "summary must be a string"], error.validation_errors
  end

  def test_non_string_title_is_rejected
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse(JSON.generate(head_result.merge("title" => 42)))
    end

    assert_equal ["title must be a string"], error.validation_errors
  end

  def test_non_array_commands_is_rejected
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse(JSON.generate(head_result.merge("commands" => { "type" => "AnswerQuestion" })))
    end

    assert_equal ["commands must be an array"], error.validation_errors
  end

  def test_missing_commands_and_questions_are_rejected
    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      Meringue::Heads::ResultParser.parse(JSON.generate("title" => "t", "summary" => "s"))
    end

    assert_equal ["commands must be an array", "questions must be an array"], error.validation_errors
  end

  def test_command_entry_shape_errors_are_indexed
    raw = JSON.generate(
      head_result(
        commands: [
          "AnswerQuestion",
          { "type" => 5, "payload" => [] },
          { "payload" => {} },
          { "type" => "AnswerQuestion" }
        ]
      )
    )

    error = assert_raises(Meringue::Heads::InvalidHeadResultError) { Meringue::Heads::ResultParser.parse(raw) }

    assert_equal [
      "commands[0] must be an object",
      "commands[1].type must be a string",
      "commands[1].payload must be an object",
      "commands[2].type must be a string",
      "commands[3].payload must be an object"
    ], error.validation_errors
  end

  def test_question_entry_shape_errors_are_indexed
    raw = JSON.generate(head_result(questions: ["just a string", { "context" => "no question key" }]))

    error = assert_raises(Meringue::Heads::InvalidHeadResultError) { Meringue::Heads::ResultParser.parse(raw) }

    assert_equal [
      "questions[0] must be an object",
      "questions[1].question must be a string"
    ], error.validation_errors
  end

  def test_json_schema_is_serialized_and_requires_the_envelope_fields
    schema = JSON.parse(Meringue::Heads::ResultParser.json_schema)

    assert_equal "object", schema.fetch("type")
    assert_equal %w[title summary commands questions], schema.fetch("required")
    assert_equal %w[type payload], schema.dig("properties", "commands", "items", "required")
    assert_equal ["question"], schema.dig("properties", "questions", "items", "required")
  end

  def test_parse_json_object_helpers_are_reusable
    assert_equal({ "a" => 1 }, Meringue::Heads::ResultParser.parse_json_object('noise {"a": 1} noise'))
    assert_equal '{"a": 1}', Meringue::Heads::ResultParser.first_fenced_json("```json\n{\"a\": 1}\n```")
    assert_equal '{"a": 1}', Meringue::Heads::ResultParser.first_json_object('x {"a": 1} y')
    assert_nil Meringue::Heads::ResultParser.first_json_object("no braces here")
    assert_nil Meringue::Heads::ResultParser.first_fenced_json("no fence here")
  end
end
