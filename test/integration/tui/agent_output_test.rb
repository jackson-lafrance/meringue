# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiAgentOutputTest < Minitest::Test
  include TUISupport

  AgentOutput = Meringue::TUI::AgentOutput

  def test_terminal_sequences_are_removed
    assert_equal "hello", AgentOutput.normalize("\e[33mhello\e[0m")
    assert_equal "bold", AgentOutput.strip_terminal_sequences("\e[1mbold\e]0;title\a\eQ")
  end

  def test_control_characters_tabs_and_nbsp_are_normalized
    assert_equal "tab  herenull", AgentOutput.normalize("tab\there\u0000null")
    assert_equal "a b", AgentOutput.normalize("a\u00a0b")
    assert_equal "one\ntwo", AgentOutput.normalize("one\r\ntwo")
    assert_equal "one\ntwo", AgentOutput.normalize("one\rtwo")
  end

  def test_blank_lines_are_trimmed_and_collapsed
    assert_equal "a\n\nb", AgentOutput.normalize("a\n\n\n\n\nb")
    assert_equal "trailing spaces", AgentOutput.normalize("trailing spaces   \n\n")
    assert_equal "", AgentOutput.normalize(nil)
    assert_equal "", AgentOutput.normalize("   \n\n  ")
  end

  def test_rendered_headers_and_output_labels_are_dropped
    assert_equal "real text", AgentOutput.normalize("P1-I1-W1 output:\nreal text", source_id: "P1-I1-W1")
    assert_equal "body", AgentOutput.normalize("[00:05:00] ✦ agent P1-I1-W1 — Title\nbody", source_id: "P1-I1-W1")
    assert_equal "kept", AgentOutput.normalize("P9-I9-W9 output:\nkept", source_id: "P9-I9-W9")
  end

  def test_outer_boxes_are_unwrapped_and_hard_wrapping_is_reflowed
    boxed = <<~TEXT
      ╭──────── progress ────────╮
      │ # Result                 │
      │                          │
      │ Replaced mini with oil   │
      │ while keeping defaults.  │
      │                          │
      │ - one                    │
      │ - two                    │
      ╰──────────────────────────╯
    TEXT

    assert_equal "# Result\n\nReplaced mini with oil while keeping defaults.\n\n- one\n- two",
                 AgentOutput.normalize(boxed)
  end

  def test_box_border_detection
    assert AgentOutput.box_border_line?("╭──────────╮")
    assert AgentOutput.box_border_line?("─────")
    assert AgentOutput.box_border_line?("│")
    refute AgentOutput.box_border_line?("│ text │")
    refute AgentOutput.box_border_line?("")
  end

  def test_pr_urls_are_removed_from_the_body
    normalized = AgentOutput.normalize("see https://x/pull/1 now PR: \nhttps://x/pull/1", pr_urls: ["https://x/pull/1"])

    refute_includes normalized, "https://x/pull/1"
    assert_includes normalized, "see"
  end

  def test_markdown_structure_survives_normalization
    assert_equal "- item one\n- item two", AgentOutput.normalize("- item one\n- item two")
    assert_equal "# Heading\n\nBody text", AgentOutput.normalize("# Heading\n\nBody text")
    assert_equal "> quoted\n> more", AgentOutput.normalize("> quoted\n> more")
  end

  def test_fenced_code_keeps_indentation_and_blank_rows
    fenced = "```\ncode  here\n\n  indented\n```"

    assert_equal fenced, AgentOutput.normalize(fenced)
  end

  def test_dedent_trim_and_collapse_helpers
    assert_equal ["a", "  b"], AgentOutput.dedent(["    a", "      b"])
    assert_equal ["a"], AgentOutput.trim_blank_lines(["", " ", "a", "", ""])
    assert_equal ["a", "", "b"], AgentOutput.collapse_blank_lines(["a", "", "", "b"])
  end

  def test_prose_continuation_only_joins_unstructured_lines
    assert AgentOutput.prose_continuation?("start of a sentence", "that continues")
    refute AgentOutput.prose_continuation?("finished sentence.", "next sentence")
    refute AgentOutput.prose_continuation?("- list item", "continued")
    refute AgentOutput.prose_continuation?("prose", "  indented continuation")
  end

  # Recorded actual behavior, not desired behavior: invalid UTF-8 raises out of
  # normalize because the rescue only covers ArgumentError and then calls rstrip
  # on the same invalid bytes. See test/findings/tui.md.
  def test_invalid_utf8_currently_raises_instead_of_being_replaced
    invalid = "bad \xC3\x28 utf8".dup.force_encoding("UTF-8")

    assert_raises(Encoding::CompatibilityError) { AgentOutput.normalize(invalid) }
    # The Markdown renderer, by contrast, sanitizes the same bytes.
    assert_kind_of Array, Meringue::TUI::Markdown.sanitized_lines(invalid)
  end
end
