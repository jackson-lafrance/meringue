#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage (and a visual demo) for the chat composer's target cue.
#
# The composer border, title, and prompt marker are tinted with the same per-id
# color the logs pane already assigns that agent/issue, so the box you type into
# matches the AgentTree row it will prompt. Everything that is not an issue/agent
# chat target (a project or unbound head, no selection at all, or a slash command
# that bypasses the selection) stays deliberately untinted.
#
# The target is named once, in the composer title above the chat bar. The bottom
# hint line carries gestures only, so these checks assert it never repeats the id.
#
# Usage:
#   ruby scripts/chat_target_smoke.rb            # checks + colored preview
#   NO_COLOR=1 ruby scripts/chat_target_smoke.rb # checks + plain preview

require_relative "../lib/meringue"

FAILURES = []
COLOR = ENV.fetch("NO_COLOR", "").to_s.empty?
NOW = "2026-07-11T00:00:00Z"
WIDTH = 100
HEIGHT = 30

Style = Meringue::TUI::Style
ChatTarget = Meringue::TUI::ChatTarget
Pane = Meringue::TUI::Panes::ChatPane

def check(description)
  ok, detail = yield
  if ok
    puts "  ok   #{description}"
  else
    puts "  FAIL #{description}#{detail ? " (#{detail})" : ""}"
    FAILURES << description
  end
end

def fixture_state
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [
    { "id" => "P1", "name" => "meringue", "root_path" => "/tmp/meringue", "status" => "working", "created_at" => NOW, "updated_at" => NOW }
  ]
  state["issues"] = [
    {
      "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Fix signup validation",
      "description" => "", "status" => "working", "agent_ids" => %w[P1-I1-W1 P1-I1-W2], "created_at" => NOW, "updated_at" => NOW
    }
  ]
  state["agents"] = [
    {
      "id" => "H7", "type" => "head", "status" => "working", "harness" => "fake",
      "harness_metadata" => { "title" => "Route the request", "head_session_state" => "pending" },
      "created_at" => NOW, "updated_at" => NOW
    },
    {
      "id" => "P1-I1-W1", "type" => "worker", "status" => "working", "project_id" => "P1", "issue_id" => "P1-I1",
      "harness" => "fake", "harness_metadata" => { "title" => "Add the email collision check" }, "created_at" => NOW, "updated_at" => NOW
    },
    {
      "id" => "P1-I1-W2", "type" => "worker", "status" => "idle", "project_id" => "P1", "issue_id" => "P1-I1",
      "harness" => "fake", "harness_metadata" => { "title" => "Hide the password field" }, "created_at" => NOW, "updated_at" => NOW
    }
  ]
  state
end

def composed(selection, buffer = "")
  state = fixture_state
  app = Meringue::TUI::App.new(layout: Meringue::TUI::Layout.new)
  app.send(:select_agent_tree_item, state, selection) if selection
  app.send(:exit_agent_tree_navigation)
  app.send(:compose_state, -> { state }, buffer)
end

# The composer occupies the last three rows above the bottom hint line, so the
# preview shows exactly what a user sees while typing.
def composer_preview(state)
  frame = Meringue::TUI::Layout.new.render(state, width: WIDTH, height: HEIGHT, color: COLOR)
  frame.split("\n", -1).last(4)
end

def plain(segments)
  Array(segments).map { |segment| segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s }.join
end

def strip_ansi(text)
  text.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
end

pane = Pane.new

SCENARIOS = [
  ["a selected worker", "P1-I1-W1", "", "agent"],
  ["a selected issue", "P1-I1", "", "issue"],
  ["a selected project (log-only)", "P1", "", "log_only"],
  ["a selected unbound head (log-only)", "H7", "", "log_only"],
  ["nothing selected", nil, "", "none"],
  ["a slash command with a worker selected", "P1-I1-W1", "/prune", "slash"]
].freeze

SCENARIOS.each do |label, selection, buffer, expected_kind|
  state = composed(selection, buffer)
  puts "Scenario: #{label}"
  check("kind is #{expected_kind}") do
    kind = ChatTarget.presentation(state).fetch("kind")
    [kind == expected_kind, kind]
  end
  title = pane.composer_pane_title(state)
  hint = plain(ChatTarget.hint_segments(state))
  bottom_line = plain(pane.bottom_hint_line(state))
  tinted = !pane.composer_border_style(state, active: true).nil?
  check("composer title names the destination") { [!title.empty?, title] }
  check("the bottom line never repeats the target id") do
    ids = %w[P1-I1-W1 P1-I1 H7 P1].select { |id| title.include?(id) }
    [ids.none? { |id| bottom_line.include?(id) }, "#{ids.inspect} | #{bottom_line}"]
  end
  if selection
    check("the bottom line keeps the clear gesture") { [hint.include?("Esc clears"), hint] }
  else
    check("nothing selected contributes nothing to the bottom line") { [hint.empty?, hint] }
  end
  if expected_kind == "agent" || expected_kind == "issue"
    tint_id = ChatTarget.presentation(state).fetch("tint_id")
    check("border/title are tinted from the target's own log color") do
      border = pane.composer_border_style(state, active: false)
      [border == Style.agent_body_style(tint_id) &&
        pane.composer_title_style(state) == Style.agent_chrome_style(tint_id, bold: true), tint_id]
    end
    check("the rendered composer row carries the tint") do
      row = composer_preview(state).find { |line| strip_ansi(line).include?("chat →") }
      [row && (!COLOR || row.include?(Style.agent_chrome_style(tint_id, bold: true))), strip_ansi(row.to_s).strip]
    end
    check("the bottom line says a head still routes the message") { [hint.include?("head routes"), hint] }
  else
    check("composer stays untinted") { [!tinted, "tinted=#{tinted}"] }
    check("composer says a head routes the message or that slash bypasses it") do
      [title.include?("head routes") || title.include?("slash command"), title]
    end
  end
  puts composer_preview(state).map { |line| "       #{line}" }.join("\n")
  puts
end

puts "Scenario: routing semantics are unchanged"
selected = composed("P1-I1-W1")
check("a selected worker still resolves chat to its owning issue") do
  target = Meringue::TUI::LogScope.chat_target(selected)
  [target && target.fetch("issue_id") == "P1-I1" && target.fetch("selected_agent_id") == "P1-I1-W1", target.inspect]
end
check("a slash buffer keeps the selection intact for the next plain prompt") do
  target = Meringue::TUI::LogScope.chat_target(composed("P1-I1-W1", "/prune"))
  [target && target.fetch("issue_id") == "P1-I1", target.inspect]
end
check("a log-only selection carries no chat target") do
  [Meringue::TUI::LogScope.chat_target(composed("P1")).nil?, Meringue::TUI::LogScope.chat_target(composed("P1")).inspect]
end
check("a stale selection stops tinting the composer") do
  state = fixture_state
  app = Meringue::TUI::App.new(layout: Meringue::TUI::Layout.new)
  app.send(:select_agent_tree_item, state, "P1-I1-W2")
  pruned = fixture_state
  pruned["agents"] = pruned.fetch("agents").reject { |agent| agent.fetch("id") == "P1-I1-W2" }
  frame_state = app.send(:compose_state, -> { pruned }, "")
  [pane.composer_border_style(frame_state, active: true).nil? &&
    pane.composer_pane_title(frame_state) == "chat · head routes", pane.composer_pane_title(frame_state)]
end
puts

puts "Scenario: every shipped colorscheme"
Style.colorschemes.each do |name|
  Style.configure!(name)
  state = composed("P1-I1-W1")
  tint = pane.composer_title_style(state)
  expected = Style.ansi(1, 38, 5, Style::SCHEMES.fetch(name).fetch(Style::AGENT_PALETTE_KEY).fetch(Style.agent_palette_index("P1-I1-W1")))
  check("#{name} tints from its own agent palette") { [tint == expected, tint.inspect] }
  check("#{name} keeps the tint distinct from body text and the placeholder") do
    [tint != Style::TEXT.to_s && tint != Style::MUTED.to_s, tint.inspect]
  end
  row = composer_preview(state).find { |line| strip_ansi(line).include?("chat →") }
  puts "       #{row}"
end
Style.configure!(Style::DEFAULT_COLORSCHEME)
puts

if FAILURES.empty?
  puts "All chat target checks passed."
else
  puts "#{FAILURES.length} check(s) failed:"
  FAILURES.each { |failure| puts "  - #{failure}" }
end

exit(FAILURES.empty? ? 0 : 1)
