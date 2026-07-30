#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke coverage (and a visual demo) for the delivery-PR affordances on the
# dashboard's bottom hint line.
#
# Two questions share one slot:
#
#   - one node in view (selected worker/issue) -> that node's own PR
#   - unscoped "all chat"                      -> how many PRs are open, and
#                                                 Ctrl-B opens a picker over them
#
# Everything is read from persisted state (`delivery_pull_requests` on each
# issue), so no `gh` call happens on the render path.
#
# Usage:
#   ruby scripts/delivery_pr_smoke.rb            # checks + colored preview
#   NO_COLOR=1 ruby scripts/delivery_pr_smoke.rb # checks + plain preview

require "stringio"
require_relative "../lib/meringue"

FAILURES = []
COLOR = ENV.fetch("NO_COLOR", "").to_s.empty?
NOW = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
WIDTH = 100
HEIGHT = 26

Delivery = Meringue::TUI::DeliveryPullRequest
OpenPullRequests = Meringue::TUI::OpenPullRequests
Pane = Meringue::TUI::Panes::ChatPane

# Opening a PR must not launch a browser during a smoke run.
class RecordingOpener
  attr_reader :opened

  def initialize
    @opened = []
  end

  def open(url)
    @opened << url
    { "status" => "opened" }
  end
end

def check(description)
  ok, detail = yield
  if ok
    puts "  ok   #{description}"
  else
    puts "  FAIL #{description}#{detail ? " (#{detail})" : ""}"
    FAILURES << description
  end
end

def pull_request(number, overrides = {})
  { "url" => "https://github.com/o/r/pull/#{number}", "last_checked_at" => NOW }.merge(overrides)
end

def fixture_state
  state = Meringue::State::Models.empty_state(now: NOW)
  state["projects"] = [
    { "id" => "P1", "name" => "meringue", "root_path" => "/tmp/meringue", "status" => "working", "created_at" => NOW, "updated_at" => NOW }
  ]
  state["issues"] = [
    {
      "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Fix signup validation", "description" => "",
      "status" => "working", "agent_ids" => %w[P1-I1-W1 P1-I1-W2], "created_at" => NOW, "updated_at" => NOW,
      # Oldest first, the way the state layer stores them.
      "delivery_pull_requests" => [
        pull_request("130", "state" => "merged", "head_branch" => "meringue/first-pass-a1"),
        pull_request("145", "state" => "open", "head_branch" => "meringue/second-pass-b2")
      ]
    },
    {
      "id" => "P1-I2", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Add the open PR picker", "description" => "",
      "status" => "working", "agent_ids" => ["P1-I2-W1"], "created_at" => NOW, "updated_at" => NOW,
      "delivery_pull_request" => pull_request("151")
    }
  ]
  state["agents"] = [
    {
      "id" => "P1-I1-W1", "type" => "worker", "status" => "idle", "project_id" => "P1", "issue_id" => "P1-I1", "harness" => "fake",
      "workspace_branch" => "meringue/first-pass-a1", "harness_metadata" => { "title" => "First pass" }, "created_at" => NOW, "updated_at" => NOW
    },
    {
      "id" => "P1-I1-W2", "type" => "worker", "status" => "idle", "project_id" => "P1", "issue_id" => "P1-I1", "harness" => "fake",
      "workspace_branch" => "meringue/second-pass-b2", "harness_metadata" => { "title" => "Second pass" }, "created_at" => NOW, "updated_at" => NOW
    },
    {
      "id" => "P1-I2-W1", "type" => "worker", "status" => "idle", "project_id" => "P1", "issue_id" => "P1-I2", "harness" => "fake",
      "harness_metadata" => { "title" => "Picker" }, "created_at" => NOW, "updated_at" => NOW
    }
  ]
  state
end

def plain(segments)
  Array(segments).map { |segment| segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s }.join
end

def strip_ansi(text)
  text.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
end

def build_app(opener)
  Meringue::TUI::App.new(layout: Meringue::TUI::Layout.new, out: StringIO.new, pull_request_opener: opener)
end

state = fixture_state
pane = Pane.new

puts "Scenario: each worker gets the PR that belongs to its own branch"
check("the first worker keeps its merged PR #130") { [Delivery.for_id(state, "P1-I1-W1").fetch("number") == "130", Delivery.for_id(state, "P1-I1-W1").fetch("number")] }
check("the second worker shows its own PR #145") { [Delivery.for_id(state, "P1-I1-W2").fetch("number") == "145", Delivery.for_id(state, "P1-I1-W2").fetch("number")] }
check("the issue shows the newest PR that is still live") { [Delivery.for_id(state, "P1-I1").fetch("number") == "145", Delivery.for_id(state, "P1-I1").fetch("number")] }
puts

puts "Scenario: bottom hint line, scoped to one worker"
opener = RecordingOpener.new
app = build_app(opener)
app.send(:select_agent_tree_item, state, "P1-I1-W2")
app.send(:exit_agent_tree_navigation)
scoped = app.send(:compose_state, -> { state }, "")
scoped_hint = plain(pane.bottom_hint_line(scoped))
check("names that worker's PR and status") { [scoped_hint.include?("PR #145 open"), scoped_hint] }
check("does not advertise Ctrl-B inline") { [!scoped_hint.include?("Ctrl-B"), scoped_hint] }
check("Ctrl-B opens that worker's PR") do
  app.send(:handle_key, "\u0002", "", 0, -1, nil, scoped)
  [opener.opened == ["https://github.com/o/r/pull/145"], opener.opened.inspect]
end
puts "       #{strip_ansi(Meringue::TUI::Layout.new.render(scoped, width: WIDTH, height: HEIGHT, color: false).split("\n", -1).last)}"
puts

puts "Scenario: bottom hint line, unscoped all chat"
opener = RecordingOpener.new
app = build_app(opener)
unscoped = app.send(:compose_state, -> { state }, "")
unscoped_hint = plain(pane.bottom_hint_line(unscoped))
check("counts open PRs instead of pinning one") { [unscoped_hint.include?("2 open PRs"), unscoped_hint] }
check("no specific PR number is shown") { [!unscoped_hint.include?("PR #"), unscoped_hint] }
check("a settled-only tree reads as none open") do
  settled = fixture_state
  settled["issues"] = [settled.fetch("issues").first.merge("delivery_pull_requests" => [pull_request("130", "state" => "merged")], "delivery_pull_request" => pull_request("130", "state" => "merged"))]
  [OpenPullRequests.summary_label(settled) == "no open PRs", OpenPullRequests.summary_label(settled)]
end
check("a tree with no PRs at all says nothing") do
  bare = Meringue::State::Models.empty_state(now: NOW)
  [pane.bottom_hint_line(app.send(:compose_state, -> { bare }, "")).none? { |segment| plain([segment]).include?("PR") }, "tracked=#{OpenPullRequests.tracked?(bare)}"]
end
puts "       #{strip_ansi(Meringue::TUI::Layout.new.render(unscoped, width: WIDTH, height: HEIGHT, color: false).split("\n", -1).last)}"
puts

puts "Scenario: Ctrl-B opens the open-PR picker"
app.send(:handle_key, "\u0002", "", 0, -1, nil, unscoped)
picker = app.send(:compose_state, -> { state }, "")
check("the picker is up in the popup slot") { [pane.delivery_pr_picker?(picker) && pane.popup_pane_title(picker) == "open pull requests", pane.popup_pane_title(picker)] }
check("every open PR is listed with its number and title") do
  rows = pane.popup_lines(picker).map { |line| plain(line) }
  [rows.length == 2 && rows.first.include?("#151") && rows.first.include?("Add the open PR picker") && rows[1].include?("#145"), rows.inspect]
end
check("the count and keys are captioned below the list, not inside it") do
  caption = plain(pane.popup_footer_line(picker))
  rows = pane.popup_lines(picker).map { |line| plain(line) }
  [caption.include?("2 open PRs") && caption.include?("Enter opens · Esc closes") && rows.none? { |row| row.include?("Esc closes") }, caption]
end
frame = Meringue::TUI::Layout.new.render(picker, width: WIDTH, height: HEIGHT, color: COLOR)
puts frame.split("\n", -1).last(9).map { |line| "       #{line}" }.join("\n")
check("arrow keys move the highlight") do
  app.send(:handle_key, "\e[B", "", 0, -1, nil, picker)
  moved = app.send(:compose_state, -> { state }, "")
  [pane.delivery_pr_picker_index(moved) == 1, pane.delivery_pr_picker_index(moved)]
end
check("Enter opens the highlighted PR and closes the picker") do
  app.send(:handle_key, "\r", "", 0, -1, nil, app.send(:compose_state, -> { state }, ""))
  closed = app.send(:compose_state, -> { state }, "")
  [opener.opened == ["https://github.com/o/r/pull/145"] && !pane.delivery_pr_picker?(closed), opener.opened.inspect]
end
check("Esc closes it without opening anything") do
  app.send(:handle_key, "\u0002", "", 0, -1, nil, app.send(:compose_state, -> { state }, ""))
  app.send(:handle_key, "\e", "", 0, -1, nil, app.send(:compose_state, -> { state }, ""))
  [!pane.delivery_pr_picker?(app.send(:compose_state, -> { state }, "")) && opener.opened.length == 1, opener.opened.inspect]
end
check("typing closes it and still reaches the composer") do
  app.send(:handle_key, "\u0002", "", 0, -1, nil, app.send(:compose_state, -> { state }, ""))
  buffer, = app.send(:handle_key, "h", "", 0, -1, nil, app.send(:compose_state, -> { state }, ""))
  [buffer == "h" && !pane.delivery_pr_picker?(app.send(:compose_state, -> { state }, "")), buffer.inspect]
end
puts

if FAILURES.empty?
  puts "All delivery PR checks passed."
else
  puts "#{FAILURES.length} check(s) failed:"
  FAILURES.each { |failure| puts "  - #{failure}" }
end

exit(FAILURES.empty? ? 0 : 1)
