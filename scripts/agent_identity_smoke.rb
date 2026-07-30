#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage (and a visual demo) for agent identity in the AgentTree.
#
# Every agent row carries its harness logo and its identity color, in every
# lifecycle status: a worker that is working and one with a completion check
# mark are equally identifiable. The color is the same per-id assignment the logs
# pane and the chat composer use (Style::AGENT_PALETTE via
# Style.agent_palette_index), so one agent is one color everywhere.
#
# Usage:
#   ruby scripts/agent_identity_smoke.rb                        # checks + colored preview
#   NO_COLOR=1 ruby scripts/agent_identity_smoke.rb             # plain preview
#   MERINGUE_ASCII_GLYPHS=1 ruby scripts/agent_identity_smoke.rb # ASCII harness marks

require_relative "../lib/meringue"

FAILURES = []
COLOR = ENV.fetch("NO_COLOR", "").to_s.empty?
NOW = "2026-07-11T00:00:00Z"
TREE_WIDTH = 44

Style = Meringue::TUI::Style
Registry = Meringue::Harness::Registry
Pane = Meringue::TUI::Panes::AgentTreePane

def check(description)
  ok, detail = yield
  if ok
    puts "  ok   #{description}"
  else
    puts "  FAIL #{description}#{detail ? " (#{detail})" : ""}"
    FAILURES << description
  end
end

def agent(id, status, harness, title, type: "worker")
  {
    "id" => id,
    "type" => type,
    "status" => status,
    "project_id" => "P1",
    "issue_id" => type == "worker" ? "P1-I1" : nil,
    "harness" => harness,
    "harness_metadata" => { "title" => title },
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

# One row per lifecycle status, spread across every shipped harness plus an
# unknown one and a record with no harness at all.
ROWS = [
  ["working", "pi", "Add collision check"],
  ["completed", "pi", "Hide password field"],
  ["idle", "claude", "Check the migration"],
  ["queued", "claude", "Queued follow-up"],
  ["blocked", "antigravity", "Wait on review"],
  ["errored", "mystery", "Unknown harness"],
  ["killed", nil, "No harness recorded"]
].freeze

def fixture_state(selected: nil)
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [
    { "id" => "P1", "name" => "meringue", "root_path" => "/tmp/meringue", "status" => "working", "created_at" => NOW, "updated_at" => NOW }
  ]
  state["issues"] = [
    {
      "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Fix signup validation",
      "description" => "", "status" => "working", "agent_ids" => [], "created_at" => NOW, "updated_at" => NOW
    },
    {
      "id" => "P1-I2", "project_id" => "P1", "parent_issue_id" => "P1-I1", "title" => "Child issue beside a worker",
      "description" => "", "status" => "queued", "agent_ids" => [], "created_at" => NOW, "updated_at" => NOW
    }
  ]
  state["agents"] = [agent("H1", "working", "pi", "Route the request", type: "head")] +
                    ROWS.each_with_index.map { |(status, harness, title), index| agent("P1-I1-W#{index + 1}", status, harness, title) }
  state["_chat"] = { "messages" => [], "input_buffer" => "", "input_cursor" => 0, "pending_count" => 0, "slash_suggestion_index" => -1 }
  if selected
    state["_agent_tree_navigation"] = { "active" => true, "selected_agent_id" => selected }
    state[Meringue::TUI::LogScope::STATE_KEY] = Meringue::TUI::LogScope.snapshot(state, selected)
  end
  state
end

def plain(line)
  Array(line).map { |segment| segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s }.join
end

def styles(line)
  Array(line).filter_map { |segment| segment.is_a?(Array) ? segment.fetch(1, nil) : nil }
end

def rows(state)
  Pane.new.lines(state, width: TREE_WIDTH - 4)
end

def row_for(state, text)
  rows(state).find { |line| plain(line).include?(text) }
end

# Draw the pane through Canvas so the preview is what the dashboard actually
# emits, including style resets between segments.
def preview(state)
  lines = rows(state)
  canvas = Meringue::TUI::Canvas.new(width: TREE_WIDTH, height: lines.length)
  lines.each_with_index { |line, index| canvas.write_segments(2, index, line, max_width: TREE_WIDTH - 4, default_style: Style::TEXT) }
  canvas.render(color: COLOR)
end

state = fixture_state

puts "Scenario 1: every agent row carries its identity color and harness logo"
ROWS.each_with_index do |(status, harness, title), index|
  id = "P1-I1-W#{index + 1}"
  line = row_for(state, title)
  check("#{status.ljust(9)} row shows #{Registry.provider_glyph(harness).inspect} + its identity color") do
    text = plain(line)
    glyph = Registry.provider_glyph(harness)
    [text.include?("#{glyph} W#{index + 1}") && styles(line).include?(Style.agent_body_style(id)), text.strip]
  end
  check("#{status.ljust(9)} row keeps its status color, so color is additive") do
    [styles(line).include?(Pane::STATUS_STYLES.fetch(status)), status]
  end
end
check("a head row renders its logo bold, like its log header") do
  line = row_for(state, "Route the request")
  [styles(line).include?(Style.agent_style("H1", kind: "head")), plain(line).strip]
end
puts preview(state)
puts

puts "Scenario 2: the same agent is the same color in the tree, the logs, and the composer"
%w[P1-I1-W1 P1-I1-W2].each do |id|
  tree = styles(row_for(state, id.end_with?("W1") ? "Add collision" : "Hide password"))
  check("#{id} tree color == logs body color == composer tint") do
    logs = Style.agent_body_style(id)
    composer = Style.agent_chrome_style(id, bold: false)
    [tree.include?(logs) && logs == composer, "#{logs.inspect} vs #{composer.inspect}"]
  end
end
selected_state = fixture_state(selected: "P1-I1-W1")
check("selecting a row keeps its logo but hands contrast to the selection palette") do
  line = row_for(selected_state, "Add collision")
  [plain(line).include?("#{Registry.provider_glyph("pi")} W1") &&
    styles(line).include?(Style::AGENT_TREE_SELECTED_STATUS) &&
    !styles(line).include?(Style.agent_body_style("P1-I1-W1")), plain(line).strip]
end
check("the composer for that selection is tinted with the same agent color") do
  pane = Meringue::TUI::Panes::ChatPane.new
  [pane.composer_title_style(selected_state) == Style.agent_chrome_style("P1-I1-W1", bold: true),
   pane.composer_pane_title(selected_state)]
end
puts preview(selected_state)
puts

puts "Scenario 3: alignment and graceful degradation"
check("an unknown harness degrades to a one-cell ASCII initial") do
  [Registry.provider_glyph("mystery") == "m" && plain(row_for(state, "Unknown harness")).include?("m W6"), Registry.provider_glyph("mystery")]
end
check("a record with no harness degrades to \"?\" instead of the default provider") do
  [Registry.provider_glyph(nil) == "?" && plain(row_for(state, "No harness recorded")).include?("? W7"), Registry.provider_glyph(nil)]
end
check("a child issue and a worker at the same depth keep one id column") do
  worker = plain(row_for(state, "Add collision"))
  issue = plain(row_for(state, "Child issue beside"))
  [worker.index("W1") == issue.index("I2"), "#{worker.index("W1")} vs #{issue.index("I2")}"]
end
check("no rendered row exceeds the pane width at any size") do
  widths = [20, 24, 34, 44, 80].map do |width|
    Pane.new.lines(state, width: width).map { |line| plain(line).length }.max <= width
  end
  [widths.all?, widths.inspect]
end
check("MERINGUE_ASCII_GLYPHS swaps every logo for its ASCII twin") do
  previous = ENV.fetch("MERINGUE_ASCII_GLYPHS", nil)
  ENV["MERINGUE_ASCII_GLYPHS"] = "1"
  text = Pane.new.lines(state, width: 40).map { |line| plain(line) }.join("\n")
  ok = text.include?("p W1") && Registry::PROVIDER_GLYPHS.each_value.none? { |glyph| text.include?(glyph) }
  previous.nil? ? ENV.delete("MERINGUE_ASCII_GLYPHS") : ENV["MERINGUE_ASCII_GLYPHS"] = previous
  [ok, nil]
end
puts

puts "Scenario 4: every shipped colorscheme"
Style.colorschemes.each do |name|
  Style.configure!(name)
  check("#{name} colors agent rows from its own palette") do
    palette = Style::SCHEMES.fetch(name).fetch(Style::AGENT_PALETTE_KEY)
    ok = ROWS.each_with_index.all? do |(_status, _harness, title), index|
      id = "P1-I1-W#{index + 1}"
      expected = Style.ansi(38, 5, palette.fetch(Style.agent_palette_index(id)))
      styles(row_for(state, title)).include?(expected)
    end
    [ok, name]
  end
  puts preview(state)
end
Style.configure!(Style::DEFAULT_COLORSCHEME)
puts

if FAILURES.empty?
  puts "All agent identity checks passed."
else
  puts "#{FAILURES.length} check(s) failed:"
  FAILURES.each { |failure| puts "  - #{failure}" }
end

exit(FAILURES.empty? ? 0 : 1)
