# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiLogsPaneTest < Minitest::Test
  include TUISupport

  class HashProbe < Hash
    def initialize(counter)
      super()
      @counter = counter
    end

    def hash
      @counter[:calls] += 1
      super
    end
  end

  Pane = Meringue::TUI::Panes::ChatPane
  Style = Meringue::TUI::Style
  Timestamps = Meringue::TUI::Timestamps

  def setup
    @pane = Pane.new
  end

  def test_empty_logs_show_the_placeholder
    assert_equal ["No logs yet. Type a prompt below and press Enter."],
                 plain_lines(@pane.log_lines(composed_state(empty_state), width: 60))
  end

  def test_render_matches_the_plain_text_of_the_log_lines
    state = composed_state(demo_state)

    assert_equal plain_lines(@pane.log_lines(state)).join("\n"), @pane.render(state)
    assert_equal @pane.log_lines(state, width: 60), @pane.lines(state, width: 60)
  end

  def test_role_lines_carry_timestamp_icon_participant_and_title
    lines = plain_lines(@pane.log_lines(mixed_state, width: 70))
    clock = Timestamps.format("2026-07-11T00:02:00Z", "%H:%M")

    assert_includes lines, "[#{Timestamps.format("2026-07-11T00:01:00Z", "%H:%M")}] ● you"
    assert_includes lines, "[#{clock}] ◆ H1 · Head title"
    assert_includes lines.join("\n"), "✓ P1-I1-W1 · Worker title · done"
  end

  def test_head_authored_kernel_commands_show_both_meringue_and_the_proposing_head
    logs = [
      log_record(
        "L1",
        "message" => "Created issue P1-I1.",
        "details" => {
          "command_author_type" => "head",
          "command_author_id" => "H127",
          "kind" => "kernel_command_applied",
          "presentation" => "cmd"
        }
      ),
      log_record("L2", "message" => "Reconciled sessions.")
    ]
    lines = @pane.log_lines(composed_state(empty_state.merge("logs" => logs)), width: 70)
    attributed = lines.find { |line| plain_line(line).include?("via H127") }
    generic = lines.find { |line| plain_line(line).include?("▪ meringue") && !plain_line(line).include?("via H127") }

    assert_includes plain_line(attributed), "▪ meringue · via H127 · cmd"
    assert_includes styles_in(attributed), Style::ACCENT_BOLD
    assert_includes styles_in(attributed), Style.agent_style("H127", kind: "head")
    assert_equal "[#{Timestamps.format("2026-07-11T00:00:00Z", "%H:%M")}] ▪ meringue", plain_line(generic)
  end

  def test_log_levels_render_status_labels_and_semantic_styles
    lines = @pane.log_lines(mixed_state, width: 70)

    warn_line = lines.find { |line| plain_line(line).include?("· warn") }
    error_line = lines.find { |line| plain_line(line).include?("· err") }
    command_line = lines.find { |line| plain_line(line).include?("· cmd") }
    result_line = lines.find { |line| plain_line(line).include?("· done") }

    assert_includes styles_in(warn_line), Style::LOG_WARNING
    assert_includes styles_in(error_line), Style::LOG_ERROR
    assert_includes styles_in(command_line), Style::LOG_COMMAND
    assert_includes styles_in(result_line), Style::SUCCESS
  end

  def test_info_level_logs_have_no_status_suffix
    state = composed_state(empty_state.merge("logs" => [log_record("L1", "message" => "plain info")]))
    lines = plain_lines(@pane.log_lines(state, width: 60))

    assert_equal 2, lines.length
    refute_includes lines.first, " · "
  end

  def test_icons_distinguish_users_heads_workers_results_and_problems
    lines = plain_lines(@pane.log_lines(mixed_state, width: 70)).select { |line| line.start_with?("[") }

    assert lines.any? { |line| line.include?(" ● you") }
    assert lines.any? { |line| line.include?(" ◆ H1") }
    assert lines.any? { |line| line.include?(" ✓ P1-I1-W1") }
    assert lines.any? { |line| line.include?(" ! ") }
    assert lines.any? { |line| line.include?(" ▪ meringue") }
  end

  def test_agent_bodies_use_the_agent_gutter_and_agent_palette_style
    lines = @pane.log_lines(mixed_state, width: 70)
    body = lines.find { |line| plain_line(line).start_with?("▌") }

    assert_includes styles_in(body), Style.agent_body_style("H1")

    kernel_body = lines.find { |line| plain_line(line) == "  boom" }
    assert_includes styles_in(kernel_body), Style::ERROR
  end

  def test_head_and_worker_headers_use_distinct_kind_styles
    lines = @pane.log_lines(mixed_state, width: 70)
    head_line = lines.find { |line| plain_line(line).include?("◆ H1") }
    worker_line = lines.find { |line| plain_line(line).include?("✓ P1-I1-W1") }

    assert_includes styles_in(head_line), Style.agent_style("H1", kind: "head")
    assert_includes styles_in(worker_line), Style.agent_style("P1-I1-W1", kind: "worker")
  end

  def test_worker_completion_renders_pr_link_and_normalized_output
    lines = plain_lines(@pane.log_lines(mixed_state, width: 70)).join("\n")

    assert_includes lines, "PR https://github.com/owner/repo/pull/42"
    assert_includes lines, "All done now"
    refute_includes lines, "P1-I1-W1 output:"
    refute_includes lines, "Worker P1-I1-W1 completed."
  end

  def test_worker_completion_without_output_falls_back_to_completed
    logs = [
      log_record(
        "L1",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => "Worker P1-I1-W1 completed.",
        "details" => {}
      )
    ]
    state = composed_state(empty_state.merge("logs" => logs, "agents" => [agent_record("P1-I1-W1")]))

    assert_includes plain_lines(@pane.log_lines(state, width: 60)).join("\n"), "Completed."
  end

  # Mid-work progress is a worker-authored line, so it must read as the worker talking (✦, the
  # worker's own gutter) and must stay visibly distinct from its final result (✓ … · done).
  def test_worker_progress_lines_are_attributed_to_the_worker_and_distinct_from_its_result
    logs = [
      log_record(
        "L1",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => "Rebasing onto origin/main before editing.",
        "timestamp" => "2026-07-11T00:01:00Z",
        "details" => { "kind" => "worker_progress", "progress_kind" => "assistant_text", "issue_id" => "P1-I1" }
      ),
      log_record(
        "L2",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => "Worker P1-I1-W1 completed.",
        "timestamp" => "2026-07-11T00:02:00Z",
        "details" => { "last_assistant_text" => "All done now" }
      )
    ]
    state = composed_state(
      empty_state.merge(
        "logs" => logs,
        "agents" => [agent_record("P1-I1-W1", "harness_metadata" => { "title" => "Worker title" })]
      )
    )
    lines = plain_lines(@pane.log_lines(state, width: 70))
    joined = lines.join("\n")

    assert_includes joined, "✦ P1-I1-W1 · Worker title"
    assert_includes joined, "Rebasing onto origin/main before editing."
    assert_includes joined, "✓ P1-I1-W1 · Worker title · done"
    progress_header = lines.find { |line| line.include?("✦ P1-I1-W1") }
    refute_includes progress_header, "· done", "progress must not be presented as a finished result"
    refute_includes progress_header, "· warn"
  end

  def test_long_worker_progress_reports_are_wrapped_without_cutting_their_content
    report = "The worker found the shared cursor bug and is preserving the complete report. " * 8
    logs = [
      log_record(
        "L1",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => report,
        "details" => { "kind" => "worker_progress", "progress_kind" => "assistant_text", "issue_id" => "P1-I1" }
      )
    ]
    state = composed_state(empty_state.merge("logs" => logs, "agents" => [agent_record("P1-I1-W1")]))
    lines = plain_lines(@pane.log_lines(state, width: 50))
    body = lines.select { |line| line.start_with?("▌ ") }.map { |line| line.delete_prefix("▌ ") }.join(" ")

    assert_operator body.length, :>, 240, "the rendered report must not fall back to the old headline limit"
    assert_includes body, "shared cursor bug"
    assert_includes body, "preserving the complete report"
    refute_includes body, "…"
  end

  def test_conversation_messages_and_durable_logs_interleave_by_instant
    logs = [
      log_record("L1", "message" => "utc entry", "timestamp" => "2026-07-11T12:00:00Z"),
      log_record("L2", "message" => "offset entry", "timestamp" => "2026-07-11T09:00:00-04:00")
    ]
    state = composed_state(empty_state.merge("logs" => logs))
    lines = plain_lines(@pane.log_lines(state, width: 60))

    assert_operator lines.index { |line| line.include?("utc entry") }, :<,
                    lines.index { |line| line.include?("offset entry") }
  end

  def test_unparseable_timestamps_render_a_placeholder_clock
    state = composed_state(empty_state.merge("logs" => [log_record("L1", "timestamp" => "not-a-time", "message" => "odd")]))

    assert_includes plain_lines(@pane.log_lines(state, width: 60)).first, "[--:--]"
  end

  def test_message_status_lines_follow_their_message
    state = composed_state(
      empty_state,
      chat: { "messages" => [{ "role" => "meringue", "text" => "queued", "status" => "working", "timestamp" => "2026-07-11T00:00:00Z" }] }
    )

    assert_equal ["[#{Timestamps.format("2026-07-11T00:00:00Z", "%H:%M")}] ▪ meringue", "  queued", "  working"],
                 plain_lines(@pane.log_lines(state, width: 60))
  end

  def test_hidden_and_blank_messages_are_not_rendered
    state = composed_state(
      empty_state,
      chat: {
        "messages" => [
          { "role" => "you", "text" => "   ", "timestamp" => "2026-07-11T00:01:00Z" },
          { "role" => "you", "text" => "hidden", "visible" => false, "timestamp" => "2026-07-11T00:01:00Z" },
          { "role" => "agent", "source_id" => "P1-I1-W1", "text" => "shown", "timestamp" => "2026-07-11T00:01:00Z" }
        ]
      }
    )
    lines = plain_lines(@pane.log_lines(state, width: 60))

    refute_includes lines.join("\n"), "hidden"
    assert_includes lines.join("\n"), "shown"
  end

  def test_message_duplicating_a_durable_log_is_dropped
    logs = [log_record("L1", "source_type" => "user", "message" => "same text", "timestamp" => "2026-07-11T00:01:00Z")]
    state = composed_state(
      empty_state.merge("logs" => logs),
      chat: { "messages" => [{ "role" => "you", "text" => "same text", "timestamp" => "2026-07-11T00:01:00Z" }] }
    )
    lines = plain_lines(@pane.log_lines(state, width: 60))

    assert_equal 1, lines.count { |line| line.include?("same text") }
  end

  def test_worker_completion_log_is_dropped_when_the_agent_message_is_present
    logs = [
      log_record("L1", "source_type" => "worker", "source_id" => "P1-I1-W1",
                       "message" => "Worker P1-I1-W1 completed.", "timestamp" => "2026-07-11T00:02:00Z")
    ]
    state = composed_state(
      empty_state.merge("logs" => logs, "agents" => [agent_record("P1-I1-W1")]),
      chat: { "messages" => [{ "role" => "agent", "source_id" => "P1-I1-W1", "text" => "final answer", "timestamp" => "2026-07-11T00:02:00Z" }] }
    )

    assert_equal ["[#{Timestamps.format("2026-07-11T00:02:00Z", "%H:%M")}] ✦ P1-I1-W1 · P1-I1-W1 session", "▌ final answer"],
                 plain_lines(@pane.log_lines(state, width: 60))
  end

  def test_log_lines_are_cached_until_presentation_state_changes
    state = composed_state(demo_state)
    first = @pane.log_lines(state, width: 60)

    assert_same first, @pane.log_lines(state, width: 60)
    refute_same first, @pane.log_lines(state, width: 61)

    updated = state.merge("logs" => state.fetch("logs") + [log_record("L99", "message" => "new event")])
    refreshed = @pane.log_lines(updated, width: 60)

    refute_same first, refreshed
    assert_includes plain_lines(refreshed).join("\n"), "new event"
  end

  def test_appending_one_log_reuses_wrapped_fragments_for_the_retained_history
    calls = Hash.new(0)
    pane = Class.new(Pane) do
      define_method(:body_lines) do |entry, **arguments|
        calls[entry.fetch("record_id", entry.fetch("text", nil))] += 1
        super(entry, **arguments)
      end
    end.new
    logs = 20.times.map do |index|
      log_record("L#{index + 1}", "message" => "## Result #{index + 1}\n\nMarkdown body")
    end
    state = composed_state(empty_state.merge("logs" => logs))

    pane.log_lines(state, width: 60)
    updated = state.merge("logs" => logs + [log_record("L21", "message" => "## New result\n\nMarkdown body")])
    pane.log_lines(updated, width: 60)

    assert_equal 1, calls.fetch("L1"), "an append must not lay out retained Markdown again"
    assert_equal 1, calls.fetch("L20")
    assert_equal 1, calls.fetch("L21")
  end

  def test_typing_does_not_invalidate_the_log_line_cache
    state = composed_state(demo_state)
    first = @pane.log_lines(state, width: 60)
    typed = composed_state(demo_state, chat: { "input_buffer" => "typing", "input_cursor" => 6 })

    assert_same first, @pane.log_lines(typed, width: 60)
  end

  def test_agent_timestamp_changes_do_not_invalidate_the_log_line_cache
    state = composed_state(demo_state)
    first = @pane.log_lines(state, width: 60)
    updated_agents = state.fetch("agents").map do |agent|
      agent.merge("updated_at" => "2026-07-11T00:10:00Z")
    end

    assert_same first, @pane.log_lines(state.merge("agents" => updated_agents), width: 60)
  end

  def test_a_same_length_log_rewrite_invalidates_the_log_line_cache
    state = composed_state(empty_state.merge("logs" => [log_record("L1", "message" => "before recount")]))
    first = @pane.log_lines(state, width: 60)
    rewritten_metadata = state.fetch("metadata").merge(
      "last_recount" => { "recounted_at" => "2026-07-11T00:10:00Z" }
    )
    rewritten = state.merge(
      "logs" => [log_record("L1", "message" => "after recount")],
      "metadata" => rewritten_metadata
    )
    refreshed = @pane.log_lines(rewritten, width: 60)

    refute_same first, refreshed
    assert_includes plain_lines(refreshed).join("\n"), "after recount"
  end

  def test_agent_title_changes_invalidate_the_log_line_cache
    state = composed_state(mixed_state)
    first = @pane.log_lines(state, width: 70)
    updated_agents = state.fetch("agents").map do |agent|
      next agent unless agent.fetch("id") == "H1"

      metadata = agent.fetch("harness_metadata").merge("title" => "Renamed head")
      agent.merge("harness_metadata" => metadata)
    end
    refreshed = @pane.log_lines(state.merge("agents" => updated_agents), width: 70)

    refute_same first, refreshed
    assert_includes plain_lines(refreshed).join("\n"), "Renamed head"
  end

  def test_log_cache_key_does_not_deep_hash_log_payloads
    hash_calls = { calls: 0 }
    details = HashProbe.new(hash_calls)
    details["last_assistant_text"] = "# Costly Markdown\n\nRendered once."
    log = log_record(
      "L1",
      "source_type" => "worker",
      "source_id" => "P1-I1-W1",
      "message" => "Worker P1-I1-W1 completed.",
      "details" => details
    )
    state = composed_state(empty_state.merge("logs" => [log], "agents" => [agent_record("P1-I1-W1")]))

    first = @pane.log_lines(state, width: 60)
    second = @pane.log_lines(state, width: 60)

    assert_same first, second
    assert_equal 0, hash_calls.fetch(:calls)
  end

  def test_selected_agent_highlight_is_reflected_in_log_titles
    state = composed_state(mixed_state, navigation: { "active" => true, "selected_agent_id" => "H1" })
    line = @pane.log_lines(state, width: 70).find { |candidate| plain_line(candidate).include?("◆ H1") }

    assert_includes styles_in(line), Style::AGENT_TREE_SELECTED
  end

  def test_log_bodies_wrap_to_the_pane_width
    long = "word " * 80
    state = composed_state(empty_state.merge("logs" => [log_record("L1", "message" => long)]))
    lines = plain_lines(@pane.log_lines(state, width: 40))

    assert_operator lines.length, :>, 3
    assert lines.all? { |line| line.length <= 40 }, "longest: #{lines.map(&:length).max}"
  end

  def test_long_log_headers_wrap_without_losing_the_agent_title_suffix
    state = composed_state(
      empty_state.merge(
        "agents" => [agent_record("P1-I1-W1", "harness_metadata" => { "title" => "A very long worker title with a visible suffix" })],
        "logs" => [log_record("L1", "source_type" => "worker", "source_id" => "P1-I1-W1", "message" => "working")]
      )
    )
    lines = plain_lines(@pane.log_lines(state, width: 20))

    assert lines.all? { |line| line.length <= 20 }, "longest: #{lines.map(&:length).max}"
    assert_includes lines.join(" ").gsub(/\s+/, " "), "visible suffix"
  end

  def test_untrusted_escape_sequences_never_reach_the_rendered_frame
    poisoned = "\e[31mred\e]0;title\a text \e[2J"
    logs = [
      log_record("L1", "source_type" => "worker", "source_id" => "P1-I1-W1",
                       "message" => "Worker P1-I1-W1 completed.",
                       "details" => { "last_assistant_text" => poisoned })
    ]
    state = composed_state(empty_state.merge("logs" => logs, "agents" => [agent_record("P1-I1-W1")]))
    frame = render_frame(state, width: 90, height: 26, color: false)

    refute_includes frame, "\e"
    assert_includes frame, "red"
  end

  def test_demo_fixture_renders_normalized_markdown_without_transcript_artifacts
    frame = render_frame(composed_state(demo_state), width: 100, height: 32)

    assert_includes frame, "# Vim explorer delivered"
    assert_includes frame, "• Preserved existing keybindings"
    assert_includes frame, "┌─ code · lua"
    assert_includes frame, "│ Restart Neovim to load the plugin."
    refute_includes frame, "P2-I1-W1 output:"
    refute_includes frame, "╭──────"
  end

  private

  def mixed_state
    logs = [
      log_record("L1", "source_type" => "user", "message" => "Fix the signup bug", "timestamp" => "2026-07-11T00:01:00Z"),
      log_record("L2", "source_type" => "head", "source_id" => "H1", "message" => "## Routed\n\n- created issue",
                       "details" => { "kind" => "head_summary" }, "timestamp" => "2026-07-11T00:02:00Z"),
      log_record("L3", "source_type" => "worker", "source_id" => "P1-I1-W1", "message" => "Worker P1-I1-W1 completed.",
                       "timestamp" => "2026-07-11T00:03:00Z",
                       "details" => {
                         "last_assistant_text" => "P1-I1-W1 output:\nAll done **now**",
                         "delivery_pull_request" => { "url" => "https://github.com/owner/repo/pull/42" }
                       }),
      log_record("L4", "source_type" => "harness", "source_id" => "P1-I1-W1", "level" => "warning",
                       "message" => "retrying", "timestamp" => "2026-07-11T00:04:00Z"),
      log_record("L5", "source_type" => "kernel", "level" => "error", "message" => "boom", "timestamp" => "2026-07-11T00:05:00Z"),
      log_record("L6", "source_type" => "kernel", "message" => "SpawnHead",
                       "details" => { "kind" => "kernel_command_applied" }, "timestamp" => "2026-07-11T00:06:00Z")
    ]
    agents = [
      agent_record("H1", "harness_metadata" => { "title" => "Head title" }),
      agent_record("P1-I1-W1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "Worker title" })
    ]
    composed_state(empty_state.merge("logs" => logs, "agents" => agents))
  end
end
