#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage for AgentTree-selection-scoped log filtering.
#
# A single left click on an AgentTree row (project, issue, head, or worker) selects
# that node and scopes the logs pane to its AgentTree subtree. The selection is
# sticky across pane focus changes and is cleared by clicking the selected row
# again, clicking empty space in the AgentTree, or pressing Esc.
#
# Usage:
#   ruby scripts/log_scope_smoke.rb

require_relative "../lib/meringue"

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

NOW = "2026-07-11T00:00:00Z"
WIDTH = 100
HEIGHT = 32

def project(id, name)
  { "id" => id, "name" => name, "root_path" => "/tmp/#{name}", "status" => "working", "created_at" => NOW, "updated_at" => NOW }
end

def issue(id, project_id, title, parent_issue_id: nil, agent_ids: [])
  {
    "id" => id,
    "project_id" => project_id,
    "parent_issue_id" => parent_issue_id,
    "title" => title,
    "description" => "",
    "status" => "working",
    "agent_ids" => agent_ids,
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

def worker(id, issue_id, project_id, title)
  {
    "id" => id,
    "type" => "worker",
    "status" => "working",
    "project_id" => project_id,
    "issue_id" => issue_id,
    "harness" => "fake",
    "harness_metadata" => { "title" => title },
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

def head(id, title, project_id: nil)
  {
    "id" => id,
    "type" => "head",
    "status" => "working",
    "project_id" => project_id,
    "harness" => "fake",
    "harness_metadata" => { "title" => title },
    "created_at" => NOW,
    "updated_at" => NOW
  }
end

def log(id, source_type, source_id, message, details = {})
  {
    "id" => id,
    "timestamp" => NOW,
    "source_type" => source_type,
    "source_id" => source_id,
    "level" => "info",
    "message" => message,
    "details" => details
  }
end

def fixture_state
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [project("P1", "meringue"), project("P2", "dotfiles")]
  state["issues"] = [
    issue("P1-I1", "P1", "Filter the logs pane", agent_ids: %w[P1-I1-W1 P1-I1-W2]),
    issue("P1-I2", "P1", "Child of the first issue", parent_issue_id: "P1-I1", agent_ids: %w[P1-I2-W1]),
    issue("P1-I3", "P1", "Unrelated issue", agent_ids: %w[P1-I3-W1]),
    issue("P2-I1", "P2", "Swap the file explorer", agent_ids: %w[P2-I1-W1])
  ]
  state["agents"] = [
    head("H1", "Route the logs filter request", project_id: "P1"),
    worker("P1-I1-W1", "P1-I1", "P1", "Add the log scope"),
    worker("P1-I1-W2", "P1-I1", "P1", "Render the filter chip"),
    worker("P1-I2-W1", "P1-I2", "P1", "Child issue worker"),
    worker("P1-I3-W1", "P1-I3", "P1", "Unrelated worker"),
    worker("P2-I1-W1", "P2-I1", "P2", "Update the vim config")
  ]
  state["logs"] = [
    log("L1", "user", nil, "Filter my logs by the clicked node.", { "head_id" => "H1" }),
    log("L2", "head", "H1", "Routed the request to P1-I1.", { "kind" => "head_summary" }),
    log("L3", "kernel", "P1-I1", "Created issue P1-I1: Filter the logs pane", { "project_id" => "P1" }),
    log("L4", "kernel", "P1-I1-W1", "Spawned worker P1-I1-W1.", { "issue_id" => "P1-I1", "project_id" => "P1", "agent_id" => "P1-I1-W1" }),
    log("L5", "worker", "P1-I1-W1", "Worker P1-I1-W1 reported progress.", {}),
    log("L6", "worker", "P1-I1-W2", "Worker P1-I1-W2 reported progress.", {}),
    log("L7", "worker", "P1-I2-W1", "Child issue worker reported progress.", {}),
    log("L8", "worker", "P1-I3-W1", "Unrelated worker reported progress.", {}),
    log("L9", "worker", "P2-I1-W1", "Vim worker reported progress.", {}),
    log("L10", "kernel", nil, "Recounted AgentTree IDs.", {}),
    log("L11", "harness", "P2-I1-W1", "Opened a session for P2-I1-W1.", { "project_id" => "P2", "issue_id" => "P2-I1" })
  ]
  state["counters"] = state.fetch("counters").merge("logs" => 11)
  state
end

def build_app
  Meringue::TUI::App.new(layout: Meringue::TUI::Layout.new)
end

def composed(app, state, input_buffer = "")
  app.send(:compose_state, -> { state }, input_buffer)
end

def press(app, state, x:, y:, pressed: true)
  key = { "type" => "mouse", "kind" => "button", "button" => 0, "pressed" => pressed, "x" => x, "y" => y }
  app.send(:handle_chat_key, key, "", 0, Meringue::TUI::App::NO_SLASH_SELECTION, nil, composed(app, state))
end

def wheel(app, state, kind, x:, y:, count: 1)
  key = { "type" => "mouse", "kind" => kind, "x" => x, "y" => y, "count" => count }
  app.send(:handle_chat_key, key, "", 0, Meringue::TUI::App::NO_SLASH_SELECTION, nil, composed(app, state))
end

def agent_tree_offset(app)
  app.instance_variable_get(:@scroll_offsets)["agent_tree"].to_i
end

# A tree tall enough to overflow the pane, so scrolled hit-testing and reveal are
# exercised against the real AgentTree scroll offset.
def tall_state(issue_count: 12, workers_per_issue: 2)
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [project("P1", "meringue")]
  issue_count.times do |issue_index|
    issue_id = "P1-I#{issue_index + 1}"
    worker_ids = (1..workers_per_issue).map { |worker_index| "#{issue_id}-W#{worker_index}" }
    state["issues"] << issue(issue_id, "P1", "Issue #{issue_index + 1}", agent_ids: worker_ids)
    worker_ids.each { |worker_id| state["agents"] << worker(worker_id, issue_id, "P1", "Worker #{worker_id}") }
  end
  state["logs"] = state.fetch("agents").each_with_index.map do |agent, index|
    log("L#{index + 1}", "worker", agent.fetch("id"), "#{agent.fetch("id")} reported progress.", {})
  end
  state
end

def send_key(app, state, key, input_buffer = "")
  app.send(
    :handle_chat_key,
    key,
    input_buffer,
    input_buffer.chars.length,
    Meringue::TUI::App::NO_SLASH_SELECTION,
    nil,
    composed(app, state)
  )
end

def logged_ids(app, state)
  snapshot = composed(app, state)
  entries = Meringue::TUI::Panes::ChatPane.new.send(:log_entries, snapshot)
  entries.map { |entry| entry.fetch("source_id", nil).to_s }.reject(&:empty?).uniq
end

def logs_title(app, state)
  Meringue::TUI::Panes::ChatPane.new.log_pane_title(composed(app, state))
end

def logs_text(app, state)
  pane = Meringue::TUI::Panes::ChatPane.new
  pane.log_lines(composed(app, state), width: 60).map { |line| pane.send(:plain_text, line) }.join("\n")
end

def scope_id(app, state)
  Meringue::TUI::LogScope.id(composed(app, state))
end

def highlighted_rows(app, state)
  snapshot = composed(app, state)
  pane = Meringue::TUI::Panes::AgentTreePane.new
  lines = pane.lines(snapshot, width: 34)
  ids = pane.line_item_ids(snapshot, width: 34)
  selected_styles = [
    Meringue::TUI::Style::AGENT_TREE_SELECTED,
    Meringue::TUI::Style::AGENT_TREE_SELECTED_DIM,
    Meringue::TUI::Style::AGENT_TREE_SELECTED_STATUS
  ]
  lines.each_with_index.filter_map do |line, index|
    next unless Array(line).any? { |segment| segment.is_a?(Array) && selected_styles.include?(segment[1]) }

    ids[index] || Meringue::TUI::Panes::AgentTreePane.new.send(:plain_text, line).strip
  end.uniq
end

# Row coordinates of an AgentTree item as the terminal reports them (1-based).
def row_for(app, state, item_id)
  snapshot = composed(app, state)
  layout = Meringue::TUI::Layout.new
  (0...HEIGHT).each do |y|
    (0...WIDTH).each do |x|
      found = layout.agent_tree_item_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y)
      return [x + 1, y + 1] if found.to_s == item_id.to_s
    end
  end
  nil
end

def blank_tree_row(app, state)
  snapshot = composed(app, state)
  layout = Meringue::TUI::Layout.new
  (0...HEIGHT).each do |y|
    (0...WIDTH).each do |x|
      next unless layout.pane_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y) == "agent_tree"
      next unless layout.agent_tree_item_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y).nil?

      return [x + 1, y + 1]
    end
  end
  nil
end

state = fixture_state

puts "Scenario 1: a single click selects the row and scopes the logs pane"
app = build_app
check("unfiltered logs show every source") do
  ids = logged_ids(app, state)
  [%w[H1 P1-I1 P1-I1-W1 P1-I1-W2 P1-I2-W1 P1-I3-W1 P2-I1-W1].all? { |id| ids.include?(id) }, ids.inspect]
end
check("unfiltered logs pane keeps its plain title") { [logs_title(app, state) == "logs", logs_title(app, state)] }

worker_x, worker_y = row_for(app, state, "P1-I1-W1")
check("a worker row is hit-testable") { [!worker_x.nil?, "row: #{worker_y.inspect}"] }
press(app, state, x: worker_x, y: worker_y)
check("clicking a worker selects it") { [scope_id(app, state) == "P1-I1-W1", scope_id(app, state)] }
check("worker scope shows only that worker's logs") do
  [logged_ids(app, state) == ["P1-I1-W1"], logged_ids(app, state).inspect]
end
check("the logs title names the active filter") do
  [logs_title(app, state) == "logs — P1-I1-W1", logs_title(app, state)]
end
check("the composer title names the filter and the bottom hint only offers the gesture") do
  pane = Meringue::TUI::Panes::ChatPane.new
  frame_state = composed(app, state)
  hint = pane.bottom_hint_line(frame_state).map { |segment| segment.is_a?(Array) ? segment.first : segment }.join
  title = pane.composer_pane_title(frame_state)
  [title.include?("P1-I1-W1") && hint.include?("Esc clears") && !hint.include?("P1-I1-W1"), "#{title} | #{hint}"]
end

app = build_app
worker_x, worker_y = row_for(app, state, "P1-I1-W1")
press(app, state, x: worker_x, y: worker_y)
press(app, state, x: worker_x, y: worker_y)
check("double-click still opens the focused workspace") do
  [app.instance_variable_get(:@agent_workspace_active) == true, app.instance_variable_get(:@agent_workspace_agent_id).inspect]
end
check("double-click keeps the clicked worker as the logs filter") do
  [app.instance_variable_get(:@log_scope_id) == "P1-I1-W1", app.instance_variable_get(:@log_scope_id).inspect]
end

puts "Scenario 2: scoping per node type follows the AgentTree hierarchy"
app = build_app
issue_x, issue_y = row_for(app, state, "P1-I1")
press(app, state, x: issue_x, y: issue_y)
check("an issue scope includes the issue, its workers, and its child issue subtree") do
  ids = logged_ids(app, state)
  expected = %w[P1-I1 P1-I1-W1 P1-I1-W2 P1-I2-W1]
  [ids.sort == expected.sort, ids.inspect]
end

app = build_app
project_x, project_y = row_for(app, state, "P1")
check("a project row is hit-testable") { [!project_x.nil?, "row: #{project_y.inspect}"] }
press(app, state, x: project_x, y: project_y)
check("a project scope covers its whole subtree and excludes other projects") do
  ids = logged_ids(app, state)
  [ids.include?("P1-I1") && ids.include?("P1-I2-W1") && ids.include?("P1-I3-W1") && !ids.include?("P2-I1-W1"), ids.inspect]
end
check("a project scope excludes top-level head logs") do
  [!logged_ids(app, state).include?("H1"), logged_ids(app, state).inspect]
end
check("selecting a project does not enter jump mode") do
  navigation = composed(app, state).fetch("_agent_tree_navigation", {})
  [navigation.fetch("selected_agent_id", nil).nil?, navigation.inspect]
end

app = build_app
head_x, head_y = row_for(app, state, "H1")
press(app, state, x: head_x, y: head_y)
check("a head scope includes its own logs and the user prompt it routed") do
  pane = Meringue::TUI::Panes::ChatPane.new
  entries = pane.send(:log_entries, composed(app, state))
  messages = entries.map { |entry| entry.fetch("message", entry.fetch("text", "")).to_s }
  [messages.any? { |text| text.include?("Filter my logs by the clicked node.") } && messages.any? { |text| text.include?("Routed the request") } && entries.length == 2, messages.inspect]
end

puts "Scenario 3: the selection is sticky across focus and navigation"
app = build_app
worker_x, worker_y = row_for(app, state, "P1-I2-W1")
press(app, state, x: worker_x, y: worker_y)
check("clicking a nested worker scopes to it") { [scope_id(app, state) == "P1-I2-W1", scope_id(app, state)] }

# Focus the logs pane the same way a click on it would.
logs_point = nil
snapshot = composed(app, state)
(0...HEIGHT).each do |y|
  (0...WIDTH).each do |x|
    next unless Meringue::TUI::Layout.new.pane_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y) == "logs"

    logs_point = [x + 1, y + 1]
    break
  end
  break if logs_point
end
press(app, state, x: logs_point.first, y: logs_point.last)
press(app, state, x: logs_point.first, y: logs_point.last, pressed: false)
check("clicking into the logs pane keeps the filter") { [scope_id(app, state) == "P1-I2-W1", scope_id(app, state)] }
check("the selected row stays highlighted while the logs pane is focused") do
  [highlighted_rows(app, state) == ["P1-I2-W1"], highlighted_rows(app, state).inspect]
end

send_key(app, state, "\t")
check("cycling focus keeps the filter") { [scope_id(app, state) == "P1-I2-W1", scope_id(app, state)] }
check("typing in the chat composer keeps the filter") do
  send_key(app, state, "h")
  [scope_id(app, state) == "P1-I2-W1", scope_id(app, state)]
end
check("the selected row stays highlighted with the chat pane focused") do
  [highlighted_rows(app, state) == ["P1-I2-W1"], highlighted_rows(app, state).inspect]
end
check("a chat-pane click keeps the filter") do
  chat_point = nil
  snapshot = composed(app, state)
  (0...HEIGHT).each do |y|
    (0...WIDTH).each do |x|
      next unless Meringue::TUI::Layout.new.pane_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y) == "chat"

      chat_point = [x + 1, y + 1]
      break
    end
    break if chat_point
  end
  press(app, state, x: chat_point.first, y: chat_point.last)
  press(app, state, x: chat_point.first, y: chat_point.last, pressed: false)
  [scope_id(app, state) == "P1-I2-W1", scope_id(app, state)]
end

puts "Scenario 4: clearing"
app = build_app
worker_x, worker_y = row_for(app, state, "P1-I1-W2")
press(app, state, x: worker_x, y: worker_y)
press(app, state, x: worker_x, y: worker_y + 100) # a stale coordinate is ignored, not a deselect
check("a click outside the AgentTree does not clear the filter") { [scope_id(app, state) == "P1-I1-W2", scope_id(app, state)] }
send_key(app, state, "\e")
check("Esc clears the filter") { [scope_id(app, state) == "", scope_id(app, state)] }
check("cleared logs show every source again") do
  [logged_ids(app, state).length > 5, logged_ids(app, state).inspect]
end

app = build_app
worker_x, worker_y = row_for(app, state, "P1-I1-W2")
press(app, state, x: worker_x, y: worker_y)
# A second click on the same row is only a deselect when it is not a double click.
app.instance_variable_set(:@last_worker_click, nil)
press(app, state, x: worker_x, y: worker_y)
check("clicking the selected row again deselects it") { [scope_id(app, state) == "", scope_id(app, state)] }

app = build_app
issue_x, issue_y = row_for(app, state, "P1-I3")
press(app, state, x: issue_x, y: issue_y)
blank_x, blank_y = blank_tree_row(app, state)
check("the AgentTree has clickable empty space") { [!blank_x.nil?, "point: #{[blank_x, blank_y].inspect}"] }
press(app, state, x: blank_x, y: blank_y)
check("clicking empty AgentTree space deselects") { [scope_id(app, state) == "", scope_id(app, state)] }

app = build_app
issue_x, issue_y = row_for(app, state, "P1-I3")
press(app, state, x: issue_x, y: issue_y)
worker_x, worker_y = row_for(app, state, "P2-I1-W1")
press(app, state, x: worker_x, y: worker_y)
check("clicking a different row retargets the filter") { [scope_id(app, state) == "P2-I1-W1", scope_id(app, state)] }
check("retargeted logs follow the new node") { [logged_ids(app, state) == ["P2-I1-W1"], logged_ids(app, state).inspect] }

puts "Scenario 5: filtered-empty logs explain themselves"
empty_state = fixture_state
empty_state["logs"] = empty_state.fetch("logs").reject { |entry| entry.fetch("source_id", nil).to_s == "P1-I3-W1" }
app = build_app
worker_x, worker_y = row_for(app, empty_state, "P1-I3-W1")
press(app, empty_state, x: worker_x, y: worker_y)
check("an empty filtered pane names the filter and how to clear it") do
  text = logs_text(app, empty_state)
  [text.include?("No logs for P1-I3-W1") && text.include?("Esc"), text]
end

puts "Scenario 6: keyboard jump-mode selection retargets the filter"
app = build_app
worker_x, worker_y = row_for(app, state, "P1-I1-W1")
press(app, state, x: worker_x, y: worker_y)
send_key(app, state, "\e[B")
check("jump-mode movement moves the filter with the cursor") do
  navigation = composed(app, state).fetch("_agent_tree_navigation", {})
  [scope_id(app, state) == navigation.fetch("selected_agent_id", nil).to_s && scope_id(app, state) != "P1-I1-W1", "#{scope_id(app, state)} vs #{navigation.inspect}"]
end
check("only one AgentTree row is highlighted while jump mode follows the filter") do
  [highlighted_rows(app, state).length == 1, highlighted_rows(app, state).inspect]
end

puts "Scenario 7: scrolled hit-testing and unaffected text selection"
app = build_app
app.instance_variable_get(:@scroll_offsets)["agent_tree"] = 3
scrolled_x, scrolled_y = row_for(app, state, "P1-I3-W1")
press(app, state, x: scrolled_x, y: scrolled_y)
check("a scrolled AgentTree still selects the clicked row") { [scope_id(app, state) == "P1-I3-W1", scope_id(app, state)] }

app = build_app
worker_x, worker_y = row_for(app, state, "P1-I1-W1")
press(app, state, x: worker_x, y: worker_y)
snapshot = composed(app, state)
logs_point = nil
(0...HEIGHT).each do |y|
  (0...WIDTH).each do |x|
    next unless Meringue::TUI::Layout.new.pane_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y) == "logs"

    logs_point = [x + 1, y + 1]
    break
  end
  break if logs_point
end
press(app, state, x: logs_point.first + 4, y: logs_point.last + 2)
drag = { "type" => "mouse", "kind" => "motion", "button" => 32, "pressed" => true, "x" => logs_point.first + 20, "y" => logs_point.last + 2 }
app.send(:handle_chat_key, drag, "", 0, Meringue::TUI::App::NO_SLASH_SELECTION, nil, composed(app, state))
check("a logs text selection still works while the filter is active") do
  selection = composed(app, state).fetch("_selection", {})
  [selection.fetch("pane", nil) == "logs" && scope_id(app, state) == "P1-I1-W1", selection.inspect]
end
check("Esc clears the text selection before the filter") do
  send_key(app, state, "\e")
  selection = composed(app, state).fetch("_selection", {})
  [!selection.fetch("active", false) && scope_id(app, state) == "P1-I1-W1", "#{selection.inspect} #{scope_id(app, state)}"]
end
check("a second Esc clears the filter") do
  send_key(app, state, "\e")
  [scope_id(app, state) == "", scope_id(app, state)]
end

puts "Scenario 8: a vanished selection stops filtering"
app = build_app
worker_x, worker_y = row_for(app, state, "P1-I3-W1")
press(app, state, x: worker_x, y: worker_y)
pruned_state = fixture_state
pruned_state["agents"] = pruned_state.fetch("agents").reject { |agent| agent.fetch("id") == "P1-I3-W1" }
check("a pruned selection is dropped instead of hiding every log") do
  [scope_id(app, pruned_state) == "", scope_id(app, pruned_state)]
end

puts "Scenario 9: the sticky selection and AgentTree scrolling stay coherent"
layout = Meringue::TUI::Layout.new
tall = tall_state
app = build_app
tall_limits = layout.scroll_limits(composed(app, tall), width: WIDTH, height: HEIGHT)
check("the tall fixture tree overflows the pane") { [tall_limits.fetch("agent_tree").positive?, tall_limits.inspect] }

tree_point = nil
snapshot = composed(app, tall)
(0...HEIGHT).each do |y|
  (0...WIDTH).each do |x|
    next unless layout.pane_at(snapshot, width: WIDTH, height: HEIGHT, x: x, y: y) == "agent_tree"

    tree_point = [x + 1, y + 1]
    break
  end
  break if tree_point
end
wheel(app, tall, "wheel_down", x: tree_point.first, y: tree_point.last, count: 3)
check("the wheel scrolls the hovered AgentTree") { [agent_tree_offset(app).positive?, agent_tree_offset(app).to_s] }

scrolled_ids = Meringue::TUI::Panes::AgentTreePane.new.line_item_ids(composed(app, tall), width: 34)
window = layout.agent_tree_visible_window(composed(app, tall), width: WIDTH, height: HEIGHT)
visible_worker = scrolled_ids[window.fetch("start_index")...window.fetch("finish_index")].compact.find { |id| id.to_s.include?("-W") }
target_x, target_y = row_for(app, tall, visible_worker)
press(app, tall, x: target_x, y: target_y)
check("clicking a row in a scrolled tree selects that row") { [scope_id(app, tall) == visible_worker.to_s, "#{scope_id(app, tall)} vs #{visible_worker}"] }
check("the scrolled selection filters the logs to that row") { [logged_ids(app, tall) == [visible_worker.to_s], logged_ids(app, tall).inspect] }

before_wheel = scope_id(app, tall)
wheel(app, tall, "wheel_up", x: tree_point.first, y: tree_point.last, count: 2)
check("scrolling the AgentTree never clears the sticky selection") { [scope_id(app, tall) == before_wheel, scope_id(app, tall)] }
check("the selected row is still rendered as selected after scrolling") do
  [highlighted_rows(app, tall) == [before_wheel], highlighted_rows(app, tall).inspect]
end

app = build_app
app.instance_variable_set(:@focused_pane, "agent_tree")
app.send(:scroll_focused_pane_to, :bottom, state: composed(app, tall))
bottom_offset = agent_tree_offset(app)
check("the tree can be scrolled to its last row") { [bottom_offset.positive?, bottom_offset.to_s] }
app.send(:select_agent_tree_item, composed(app, tall), "P1")
revealed = composed(app, tall)
reveal_window = layout.agent_tree_visible_window(revealed, width: WIDTH, height: HEIGHT)
project_range = layout.agent_tree_item_line_range(revealed, width: WIDTH, height: HEIGHT, item_id: "P1")
check("selecting an offscreen project scrolls it back into view") do
  [project_range && project_range.first >= reveal_window.fetch("start_index") && project_range.last < reveal_window.fetch("finish_index"),
   "range=#{project_range.inspect} window=#{reveal_window.inspect}"]
end
check("manual scrolling is not undone while the sticky selection is unchanged") do
  wheel(app, tall, "wheel_down", x: tree_point.first, y: tree_point.last, count: 2)
  moved = agent_tree_offset(app)
  composed(app, tall)
  [agent_tree_offset(app) == moved, "#{agent_tree_offset(app)} vs #{moved}"]
end
check("the AgentTree overflow title and the logs filter title coexist") do
  frame = layout.render(composed(app, tall), width: WIDTH, height: HEIGHT)
  [frame.include?("agent tree  \u2191") && frame.include?("logs \u2014 P1"), frame.lines.first.to_s.strip]
end

puts
if FAILURES.empty?
  puts "All log scope checks passed."
else
  puts "#{FAILURES.length} check(s) failed:"
  FAILURES.each { |failure| puts "  - #{failure}" }
end

exit(FAILURES.empty? ? 0 : 1)
