# frozen_string_literal: true

require "test_helper"

class FoundationDeliveryArtifactPolicyTest < Minitest::Test
  Policy = Meringue::DeliveryArtifactPolicy

  def test_human_title_removes_every_internal_id_format_and_branding
    variants = [
      "P5-I2-W3 Fix checkout retries",
      "p5_i2_w3 Fix checkout retries",
      "P5/I2/W3 Fix checkout retries",
      "P5 I2 W3 Fix checkout retries",
      "Meringue/ H-7 Q#9 Fix checkout retries",
      "agent id: 481 session_id=992 Fix checkout retries",
      "AI confidence score: 0.97 Fix checkout retries"
    ]

    variants.each do |value|
      title = Policy.human_title(value)
      assert_includes title, "Fix checkout retries", value
      refute_match(/meringue|confidence|agent\s*id|session[_ ]*id|p\s*5|h\s*[-#]?\s*7|q\s*[-#]?\s*9/i, title, value)
    end
  end

  def test_slug_is_product_only_bounded_and_has_a_safe_empty_fallback
    assert_equal "fix-checkout-retries", Policy.slug("MERINGUE P6-I21-W4 Fix checkout retries")
    assert_equal "change", Policy.slug("Meringue P6/I21/W4 H2 Q3")
    assert_operator Policy.slug("A very long product task " * 10).length, :<=, 48
  end

  def test_delivery_text_drops_confidence_and_agent_attribution_lines
    supplied = <<~TEXT
      Prevent duplicate checkout retries.
      AI Confidence: 94%
      Worked on by agent P5-I2-W3 and session 818.
      Meringue P5/I2/W3 keeps the original branch safe.
      Agents involved: worker 8, worker 9
      Review the lifecycle behavior carefully.
    TEXT

    assert_equal(
      "Prevent duplicate checkout retries.\nkeeps the original branch safe.\nReview the lifecycle behavior carefully.",
      Policy.delivery_text(supplied)
    )
  end

  def test_managed_branch_accepts_current_names_only
    assert Policy.managed_branch?("fix-checkout-retries")
    assert Policy.managed_branch?("fix-checkout-retries-2")
    assert Policy.managed_branch?("fix-checkout-retries-3")
    refute Policy.managed_branch?("fix-checkout-retries-a1b2c3d4")
    refute Policy.managed_branch?("fix-checkout-retries-a1b2c3d4-2")
    refute Policy.managed_branch?("meringue/fix-checkout-retries-a1b2c3d4")
    refute Policy.managed_branch?("feature/fix-checkout-retries")
    refute Policy.managed_branch?("deadbeef")
    refute Policy.managed_branch?("0123456789012345678901234567890123456789")
    refute Policy.managed_branch?("P5-I2-W3")
  end
end
