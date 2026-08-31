# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The one place that decides what `<provider>/<model-id>` means.
#
# Reported bug: `/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`
# was rejected by two separate "exactly one slash" rules (a kernel regex and a
# three-way split in the Pi client), even though Pi lists that model, accepts it
# on `--model`, and reports it back from `get_state`. The grammar here is Pi's
# own: split on the FIRST slash.
class HarnessModelReferenceTest < HarnessIntegrationTest
  Reference = Meringue::Harness::ModelReference

  MULTI_SEGMENT = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
  GLM_5P3 = "fireworks/fireworks:accounts/fireworks/models/glm-5p3"

  def test_a_model_id_may_contain_slashes_and_colons
    parsed = Reference.parse(MULTI_SEGMENT)

    assert_equal "fireworks", parsed.fetch("provider")
    assert_equal "fireworks:accounts/fireworks/routers/glm-5p2-fast", parsed.fetch("id")
    assert_equal MULTI_SEGMENT, parsed.fetch("reference")
    assert_nil Reference.rejection_reason(MULTI_SEGMENT)
  end

  def test_format_round_trips_ordinary_and_colon_slash_ids
    ["openai/gpt-5.6-sol", GLM_5P3].each do |reference|
      provider, id = Reference.split(reference)

      assert_equal reference, Reference.format(provider: provider, id: id)
    end
  end

  def test_ordinary_references_still_parse_and_surrounding_space_is_trimmed
    parsed = Reference.parse("  openai/gpt-5.6-sol  ")

    assert_equal %w[openai gpt-5.6-sol], [parsed.fetch("provider"), parsed.fetch("id")]
    assert_equal "openai/gpt-5.6-sol", parsed.fetch("reference")
    assert Reference.valid?("anthropic/claude-opus-5")
    assert Reference.valid?("fireworks-300k/fireworks:accounts/fireworks/models/kimi-k3")
    assert Reference.valid?("openrouter/z-ai/glm-5.2")
  end

  # Still rejected, so a typo or a shell-mangled argument cannot silently become
  # the default model. Each reason is phrased for the user-visible log line.
  def test_shapes_that_cannot_be_a_reference_are_rejected_with_a_reason
    {
      nil => "a model id is required",
      "" => "a model id is required",
      "   " => "a model id is required",
      "gpt-5.6-sol" => "has no provider prefix",
      "openai/gpt 5.6" => "contains whitespace",
      "openai model" => "contains whitespace",
      "/gpt-5.6-sol" => "has an empty provider",
      "openai/" => "has an empty model id",
      "--model" => "looks like a command-line flag",
      "./models/foo" => "looks like a filesystem path",
      "../models/foo" => "looks like a filesystem path",
      "openai/gpt\u0007sol" => "contains control characters"
    }.each do |value, expected|
      reason = Reference.rejection_reason(value)

      refute_nil reason, "expected #{value.inspect} to be rejected"
      assert_includes reason, expected, "reason for #{value.inspect}"
      assert_nil Reference.parse(value), "#{value.inspect} must not parse"
    end
  end

  def test_the_format_hint_shows_both_an_ordinary_and_a_multi_segment_id
    assert_includes Reference::FORMAT_HINT, "openai/gpt-5.6-sol"
    assert_includes Reference::FORMAT_HINT, MULTI_SEGMENT
  end

  # The catalog builds its `reference` the same way, so a snapshot entry for a
  # multi-segment id round-trips through provider/id and back.
  def test_the_catalog_splits_a_reference_the_same_way
    entry = Meringue::Harness::ModelCatalog.normalize_entry("reference" => MULTI_SEGMENT)

    assert_equal "fireworks", entry.fetch("provider")
    assert_equal "fireworks:accounts/fireworks/routers/glm-5p2-fast", entry.fetch("id")
    assert_equal MULTI_SEGMENT, entry.fetch("reference")

    catalog = Meringue::Harness::ModelCatalog.available(
      harness: "pi",
      models: [{ "provider" => "fireworks", "id" => "fireworks:accounts/fireworks/routers/glm-5p2-fast" }],
      source: "test_catalog"
    )
    refute_nil catalog.entry_for(MULTI_SEGMENT)
  end
end
