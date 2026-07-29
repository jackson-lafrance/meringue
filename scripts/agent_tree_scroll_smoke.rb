#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage for AgentTree pane scrolling.
#
# Checks the whole path a user touches: keyboard line/page/top/bottom scrolling
# while the AgentTree is focused, mouse wheel scrolling while the pointer is over
# the pane (including during jump mode), clamping at both ends, re-clamping when
# the terminal shrinks or the tree shrinks, minimum-movement reveal of the
# selected item, and the pane-title overflow indicator.
#
# Usage:
#   ruby scripts/agent_tree_scroll_smoke.rb

require "json"
require "stringio"
require_relative "../lib/meringue"

WIDTH = 120
HEIGHT = 30

FAILURES = []

def check(description)
  ok, detail = yield
  if ok
    puts "  ok   #{description}"
  else
    puts "  FAIL #{description}#{detail ? " (#{detail})" : ""}"
    FAILURES << description
  end
end

def build_state(issue_count: 20, workers_per_issue: 2)
  now = Time.now.utc.iso8601
  state = Meringue::State::Models.empty_state(now: now)
  state["projects"] << {
    "id" => "P1", "name" => "meringue", "root_path" => Dir.pwd, "status" => "working",
    "issue_ids" => [], "created_at" => now, "updated_at" => now
  }
  issue_count.times do |issue_index|
    issue_id = "P1-I#{issue_index + 1}"
    state["projects"].first["issue_ids"] << issue_id
    state["issues"] << {
      "id" => issue_id, "project_id" => "P1", "parent_issue_id" => nil,
      "title" => "Issue #{issue_index + 1}", "description" => "", "status" => "working",
      "agent_ids" => [], "created_at" => now, "updated_at" => now
    }
    workers_per_issue.times do |worker_index|
      worker_id = "#{issue_id}-W#{worker_index + 1}"
      state["issues"].last["agent_ids"] << worker_id
      state["agents"] << {
        "id" => worker_id, "type" => "worker", "status" => "working", "project_id" => "P1",
        "issue_id" => issue_id, "title" => "Worker #{worker_index + 1}",
        "created_at" => now, "updated_at" => now
      }
    end
  end
  state
end

def app_with_state(state, width: WIDTH, height: HEIGHT)
  app = Meringue::TUI::App.new(input: StringIO.new, out: StringIO.new)
  app.instance_variable_set(:@last_render_width, width)
  app.instance_variable_set(:@last_render_height, height)
  [app, -> { Marshal.load(Marshal.dump(state)) }]
end

def compose(app, provider)
  app.send(:compose_state, provider, "")
end

def press(app, key, state)
  app.send(:handle_chat_key, key, +"", 0, -1, nil, state)
end

def offset(app)
  app.instance_variable_get(:@scroll_offsets)["agent_tree"].to_i
end

def wheel(kind, x:, y:, count: 1)
  { "type" => "mouse", "kind" => kind, "x" => x, "y" => y, "count" => count }
end

layout = Meringue::TUI::Layout.new
state = build_state
app, provider = app_with_state(state)
app.instance_variable_set(:@focused_pane, "agent_tree")

composed = compose(app, provider)
limits = layout.scroll_limits(composed, width: WIDTH, height: HEIGHT)
window = layout.agent_tree_visible_window(composed, width: WIDTH, height: HEIGHT)

puts "AgentTree scroll geometry"
check("tree overflows the pane") { [limits.fetch("agent_tree").positive?, "max=#{limits.fetch("agent_tree")}"] }
check("visible window reports hidden rows below") { [window.fetch("hidden_below").positive?, window.inspect] }

puts "Keyboard scrolling"
press(app, "\e[B", composed)
check("scroll_down moves one line") { [offset(app) == 1, offset(app).to_s] }
press(app, "\e[A", composed)
check("scroll_up returns to the top") { [offset(app).zero?, offset(app).to_s] }
press(app, "\e[A", composed)
check("scroll_up clamps at the first line") { [offset(app).zero?, offset(app).to_s] }
press(app, "\e[6~", composed)
check("scroll_page_down pages") { [offset(app) == Meringue::TUI::App::PAGE_SCROLL_STEP, offset(app).to_s] }
press(app, "\e[F", composed)
check("scroll_bottom jumps to the last line") { [offset(app) == limits.fetch("agent_tree"), offset(app).to_s] }
20.times { press(app, "\e[6~", composed) }
check("scroll_page_down clamps at the last line") { [offset(app) == limits.fetch("agent_tree"), offset(app).to_s] }
press(app, "\e[H", composed)
check("scroll_top jumps back to the first line") { [offset(app).zero?, offset(app).to_s] }

puts "Rendering"
press(app, "\e[6~", composed)
composed = compose(app, provider)
frame = layout.render(composed, width: WIDTH, height: HEIGHT)
check("pane title shows the overflow indicator") { [frame.include?("agent tree  \u2191"), frame.lines.first.to_s.strip] }
scrolled_window = layout.agent_tree_visible_window(composed, width: WIDTH, height: HEIGHT)
check("scrolled window hides rows above") { [scrolled_window.fetch("hidden_above").positive?, scrolled_window.inspect] }
first_visible = layout.send(:agent_tree_content_dimensions, composed, width: WIDTH, height: HEIGHT)
             .fetch(:lines)[scrolled_window.fetch("start_index")]
first_text = Array(first_visible).map { |segment| segment.is_a?(Array) ? segment.first : segment }.join
check("first drawn row matches the scroll offset") { [frame.include?(first_text.strip), first_text.strip] }

puts "Mouse wheel over the pane"
app, provider = app_with_state(state)
app.instance_variable_set(:@focused_pane, "chat")
composed = compose(app, provider)
press(app, wheel("wheel_down", x: 6, y: 6, count: 2), composed)
check("wheel scrolls the hovered tree without focusing it") { [offset(app).positive?, offset(app).to_s] }
check("focus is unchanged by the wheel") do
  pane = app.instance_variable_get(:@focused_pane)
  [pane == "chat", pane.to_s]
end
before_logs_wheel = offset(app)
press(app, wheel("wheel_down", x: WIDTH - 10, y: 6), composed)
check("wheel over the logs pane leaves the tree offset alone") { [offset(app) == before_logs_wheel, offset(app).to_s] }

puts "Jump mode"
app, provider = app_with_state(state)
app.instance_variable_set(:@focused_pane, "agent_tree")
composed = compose(app, provider)
app.send(:enter_agent_tree_navigation, composed)
composed = compose(app, provider)
press(app, "\e[6~", composed)
check("page keys scroll while jump mode is active") { [offset(app).positive?, offset(app).to_s] }
press(app, wheel("wheel_down", x: 6, y: 6), composed)
check("wheel scrolls while jump mode is active") { [offset(app) > Meringue::TUI::App::PAGE_SCROLL_STEP, offset(app).to_s] }
press(app, "\e[H", composed)
check("scroll_top works while jump mode is active") { [offset(app).zero?, offset(app).to_s] }

puts "Selection reveal"
last_worker = state["agents"].last.fetch("id")
app.instance_variable_set(:@selected_agent_id, last_worker)
composed = compose(app, provider)
revealed_offset = offset(app)
range = layout.agent_tree_item_line_range(composed, width: WIDTH, height: HEIGHT, item_id: last_worker)
reveal_window = layout.agent_tree_visible_window(composed, width: WIDTH, height: HEIGHT)
check("selecting an offscreen item scrolls it into view") do
  [range && range.first >= reveal_window.fetch("start_index") && range.last < reveal_window.fetch("finish_index"),
   "range=#{range.inspect} window=#{reveal_window.inspect}"]
end
check("reveal moves the minimum amount") do
  [revealed_offset == range.last - reveal_window.fetch("capacity") + 1, "offset=#{revealed_offset} range=#{range.inspect}"]
end
press(app, "\e[5~", composed)
scrolled_away = offset(app)
composed = compose(app, provider)
check("manual scrolling is not undone while the selection is unchanged") do
  [scrolled_away < revealed_offset && offset(app) == scrolled_away,
   "offset=#{offset(app)} scrolled_away=#{scrolled_away} revealed=#{revealed_offset}"]
end

first_head_item = state["issues"].first.fetch("id")
app.instance_variable_set(:@selected_agent_id, first_head_item)
composed = compose(app, provider)
check("selecting an item above the viewport scrolls up to it") do
  window = layout.agent_tree_visible_window(composed, width: WIDTH, height: HEIGHT)
  range = layout.agent_tree_item_line_range(composed, width: WIDTH, height: HEIGHT, item_id: first_head_item)
  [range && range.first >= window.fetch("start_index") && range.last < window.fetch("finish_index"),
   "range=#{range.inspect} window=#{window.inspect}"]
end

puts "Clamping on resize and shrink"
app, provider = app_with_state(state)
app.instance_variable_set(:@focused_pane, "agent_tree")
composed = compose(app, provider)
app.send(:scroll_focused_pane_to, :bottom, state: composed)
bottom_offset = offset(app)
app.instance_variable_set(:@last_render_height, 60)
composed = compose(app, provider)
check("growing the terminal re-clamps the offset") do
  max_offset = layout.scroll_limits(composed, width: WIDTH, height: 60).fetch("agent_tree")
  [offset(app) <= max_offset && offset(app) < bottom_offset, "offset=#{offset(app)} max=#{max_offset}"]
end

app.instance_variable_set(:@last_render_height, HEIGHT)
composed = compose(app, provider)
app.send(:scroll_focused_pane_to, :bottom, state: composed)
small_state = build_state(issue_count: 3, workers_per_issue: 1)
small_provider = -> { Marshal.load(Marshal.dump(small_state)) }
composed = compose(app, small_provider)
check("pruning the tree re-clamps the offset") do
  max_offset = layout.scroll_limits(composed, width: WIDTH, height: HEIGHT).fetch("agent_tree")
  [offset(app) == max_offset, "offset=#{offset(app)} max=#{max_offset}"]
end
check("a tree that fits shows no overflow indicator") do
  frame = layout.render(composed, width: WIDTH, height: HEIGHT)
  [!frame.include?("agent tree  \u2191"), frame.lines.first.to_s.strip]
end

puts
if FAILURES.empty?
  puts "AgentTree scroll smoke passed"
  exit 0
end

puts "AgentTree scroll smoke failed: #{FAILURES.length} check(s)"
FAILURES.each { |failure| puts "  - #{failure}" }
exit 1
