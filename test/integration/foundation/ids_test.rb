# frozen_string_literal: true

require "test_helper"

# Meringue::Ids is the one place that knows the canonical record-id shape, so this covers what it
# will and will not recase. Command-level behaviour lives in the kernel and input slices.
class FoundationIdsTest < Minitest::Test
  def test_record_id_shapes_are_recognized_in_any_case
    %w[P1 P12 P1-I23 P1-I23-W1 p1-i23-w1 P1-i23-W1 H83 h83 Q8 q8 L4].each do |id|
      assert Meringue::Ids.record_id?(id), "#{id.inspect} should look like a record id"
    end
  end

  def test_non_record_strings_are_not_record_ids
    ["", "  ", "nope", "h8x", "P", "P1-I", "P1-I1-W", "PI1", "main", "openai/gpt-5.6-sol",
     "/tmp/project", "meringue/fix-signup-a1b2", "@H1-C1", "P1 P2"].each do |value|
      refute Meringue::Ids.record_id?(value), "#{value.inspect} should not look like a record id"
    end
  end

  def test_canonical_only_upcases_record_shaped_strings
    assert_equal "P1-I23-W1", Meringue::Ids.canonical("p1-i23-w1")
    assert_equal "P1-I23-W1", Meringue::Ids.canonical("P1-i23-W1")
    assert_equal "H83", Meringue::Ids.canonical(" h83 ")
    assert_equal "Q8", Meringue::Ids.canonical("q8")

    # Anything that is not a record id keeps its exact text, including things that must stay
    # case-sensitive.
    ["nope", "h8x", "openai/gpt-5.6-sol", "meringue/fix-signup-a1b2", "/tmp/Project", "rose-pine"].each do |value|
      assert_equal value, Meringue::Ids.canonical(value)
    end
    assert_nil Meringue::Ids.canonical(nil)
    assert_equal 7, Meringue::Ids.canonical(7)
  end

  def test_same_compares_record_ids_without_case_but_never_widens_other_values
    assert Meringue::Ids.same?("h83", "H83")
    assert Meringue::Ids.same?("P1-i23-W1", "p1-I23-w1")
    refute Meringue::Ids.same?("H83", "H8")
    refute Meringue::Ids.same?("P1-I1", "P1-I1-W1")
    refute Meringue::Ids.same?("nope", "NOPE")
    refute Meringue::Ids.same?("", "")
  end

  def test_find_record_prefers_an_exact_match_before_falling_back_to_case
    records = [{ "id" => "P1-I1-W1" }, { "id" => "P1-I1-W2" }]

    assert_equal "P1-I1-W2", Meringue::Ids.find_record(records, "P1-I1-W2").fetch("id")
    assert_equal "P1-I1-W1", Meringue::Ids.find_record(records, "p1-i1-w1").fetch("id")
    assert_nil Meringue::Ids.find_record(records, "P1-I1-W9")
    assert_nil Meringue::Ids.find_record(records, "")
  end

  def test_payload_canonicalization_only_rewrites_ids_that_exist_in_state
    state = {
      "projects" => [{ "id" => "P1" }],
      "issues" => [{ "id" => "P1-I1" }],
      "agents" => [{ "id" => "P1-I1-W1" }, { "id" => "H83" }],
      "questions" => [{ "id" => "Q8" }]
    }
    payload = {
      "target_id" => "h83",
      "issue_id" => "p1-i1",
      "project_id" => "p1",
      "question_id" => "q8",
      "agent_id" => "P1-i1-W1",
      "head_id" => "h99",
      "prompt" => "look at h83",
      "path" => "/tmp/Mixed/Case",
      "model" => "openai/gpt-5.6-sol",
      "selected_target" => { "selected_id" => "p1-i1-w1" }
    }

    assert Meringue::Ids.payload_needs_canonicalization?(payload)
    canonicalized = Meringue::Ids.canonicalize_payload(payload, state)

    assert_equal "H83", canonicalized.fetch("target_id")
    assert_equal "P1-I1", canonicalized.fetch("issue_id")
    assert_equal "P1", canonicalized.fetch("project_id")
    assert_equal "Q8", canonicalized.fetch("question_id")
    assert_equal "P1-I1-W1", canonicalized.fetch("agent_id")
    assert_equal "P1-I1-W1", canonicalized.dig("selected_target", "selected_id")
    # No record matches h99, so it keeps what its author typed and is rejected downstream.
    assert_equal "h99", canonicalized.fetch("head_id")
    # Non-id payload values are never touched.
    assert_equal "look at h83", canonicalized.fetch("prompt")
    assert_equal "/tmp/Mixed/Case", canonicalized.fetch("path")
    assert_equal "openai/gpt-5.6-sol", canonicalized.fetch("model")
    # The caller's payload is left alone.
    assert_equal "h83", payload.fetch("target_id")
    assert_equal "p1-i1-w1", payload.dig("selected_target", "selected_id")
  end

  # Kernel payloads accept symbol keys too, so canonicalization must not skip them.
  def test_symbol_keyed_payloads_are_canonicalized_in_place
    state = { "agents" => [{ "id" => "H83" }], "issues" => [], "projects" => [], "questions" => [] }
    payload = { target_id: "h83", prompt: "leave me alone" }

    assert Meringue::Ids.payload_needs_canonicalization?(payload)
    canonicalized = Meringue::Ids.canonicalize_payload(payload, state)

    assert_equal "H83", canonicalized.fetch(:target_id)
    assert_equal "leave me alone", canonicalized.fetch(:prompt)
    refute canonicalized.key?("target_id"), "a symbol-keyed payload must not grow a string key"
  end

  def test_already_canonical_payloads_need_no_state_lookup
    refute Meringue::Ids.payload_needs_canonicalization?(
      "target_id" => "P1-I1-W1", "prompt" => "look at h83", "path" => "/tmp/lower/case"
    )
    refute Meringue::Ids.payload_needs_canonicalization?({})
    refute Meringue::Ids.payload_needs_canonicalization?(nil)
    # A batch reference is not a record id, so it is never canonicalized either.
    refute Meringue::Ids.payload_needs_canonicalization?("issue_id" => "@H1-C1")
  end
end
