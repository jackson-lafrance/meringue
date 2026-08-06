# frozen_string_literal: true

require "test_helper"

# The reviewer's half of the reviewer-judged goal contract.
#
# The kernel has to act on a reviewer's answer without a human in the middle, so parsing is
# deliberately tolerant about where the JSON object is and strict about what counts as a
# verdict. Anything the kernel cannot act on is `unusable` — a broken probe — rather than
# silently read as "not approved", which would burn an iteration on invented critique.
class KernelGoalsReviewVerdictTest < Minitest::Test
  Verdict = Meringue::Goals::ReviewVerdict

  def test_a_fenced_verdict_is_read_with_its_rationale_and_critique
    review = Verdict.parse(<<~TEXT)
      I read the diff on this branch and the onboarding copy.

      ```json
      {
        "approved": false,
        "rationale": "The three commands are still buried in the third paragraph.",
        "critique": ["Name /goal, /kill and /prune in the first screen", "Delete the duplicated welcome line"]
      }
      ```
    TEXT

    assert review.fetch("usable")
    refute review.fetch("approved")
    assert_includes review.fetch("rationale"), "still buried"
    assert_equal 2, review.fetch("critique").length
    assert_equal "Delete the duplicated welcome line", review.fetch("critique").last
  end

  def test_a_bare_or_trailing_json_object_is_still_a_verdict
    bare = Verdict.parse('{"approved": true, "rationale": "reads well", "critique": []}')
    assert bare.fetch("usable")
    assert bare.fetch("approved")

    trailing = Verdict.parse("Everything checks out.\n{\"approved\": true, \"rationale\": \"good\"}")
    assert trailing.fetch("approved")
  end

  def test_the_last_verdict_shaped_object_wins_over_a_quoted_example
    review = Verdict.parse(<<~TEXT)
      The contract asks me for {"approved": true, "rationale": "example"}, so here is my answer:

      ```json
      {"approved": false, "rationale": "not yet", "critique": ["fix the heading"]}
      ```
    TEXT

    refute review.fetch("approved")
    assert_equal ["fix the heading"], review.fetch("critique")
  end

  def test_common_reviewer_spellings_of_the_decision_are_accepted
    assert Verdict.parse('{"approved": "yes", "rationale": "good"}').fetch("approved")
    assert Verdict.parse('{"verdict": "approved", "rationale": "good"}').fetch("approved")
    refute Verdict.parse('{"approved": "no", "critique": ["do the thing"]}').fetch("approved")
    refute Verdict.parse('{"decision": "changes_requested", "critique": ["do the thing"]}').fetch("approved")
  end

  def test_critique_survives_bullets_objects_and_a_single_string
    from_string = Verdict.parse('{"approved": false, "critique": "- first thing\n- second thing"}')
    assert_equal ["first thing", "second thing"], from_string.fetch("critique")

    from_objects = Verdict.parse('{"approved": false, "required_changes": [{"item": "rename the flag"}]}')
    assert_equal ["rename the flag"], from_objects.fetch("critique")
  end

  def test_prose_with_no_json_is_unusable_rather_than_a_guess
    review = Verdict.parse("Looks pretty good to me, ship it!")

    refute review.fetch("usable")
    refute review.fetch("approved")
    assert_includes review.fetch("error"), "did not end its turn with a JSON verdict object"
    assert_includes review.fetch("raw_tail"), "ship it"
  end

  def test_json_without_a_decision_and_a_rejection_with_no_reason_are_both_unusable
    no_decision = Verdict.parse('{"notes": "it is fine"}')
    refute no_decision.fetch("usable")
    assert_includes no_decision.fetch("error"), "no true/false \"approved\" field"

    empty_rejection = Verdict.parse('{"approved": false}')
    refute empty_rejection.fetch("usable")
    assert_includes empty_rejection.fetch("error"), "without a rationale or any actionable critique"

    assert Verdict.parse('{"approved": true}').fetch("usable"), "an approval needs no critique"
  end

  def test_an_empty_or_missing_turn_is_unusable
    [nil, "", "   "].each do |text|
      refute Verdict.parse(text).fetch("usable"), text.inspect
    end
  end

  def test_oversized_verdicts_are_truncated_so_one_reviewer_cannot_bloat_state
    review = Verdict.parse(JSON.generate("approved" => false, "rationale" => "x" * 5_000, "critique" => Array.new(20) { |index| "#{index} #{"y" * 900}" }))

    assert_equal Verdict::MAX_CRITIQUE_ITEMS, review.fetch("critique").length
    assert_operator review.fetch("rationale").length, :<=, Verdict::RATIONALE_LIMIT
    review.fetch("critique").each { |item| assert_operator item.length, :<=, Verdict::CRITIQUE_ITEM_LIMIT }
  end

  def test_the_critique_fingerprint_ignores_case_punctuation_and_order
    first = Verdict.parse('{"approved": false, "critique": ["Name the three commands.", "Cut the second screen"]}')
    reordered = Verdict.parse('{"approved": false, "critique": ["cut the second screen!", "  name the three commands  "]}')
    different = Verdict.parse('{"approved": false, "critique": ["Name the three commands."]}')

    assert_equal Verdict.critique_fingerprint(first), Verdict.critique_fingerprint(reordered)
    refute_equal Verdict.critique_fingerprint(first), Verdict.critique_fingerprint(different)
    assert_nil Verdict.critique_fingerprint(Verdict.unusable("no verdict")), "an unusable verdict is not a repeat of anything"
  end

  def test_a_verdict_read_back_from_state_keeps_its_shape
    normalized = Verdict.normalize("usable" => true, "approved" => "true", "critique" => [nil, "do the thing", ""], "rationale" => nil)

    assert_equal true, normalized.fetch("approved")
    assert_equal ["do the thing"], normalized.fetch("critique")
    refute normalized.key?("rationale")
    assert_nil Verdict.normalize("not a hash")
  end
end
