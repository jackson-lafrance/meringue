# frozen_string_literal: true

# Measures focused-workspace scroll cost: how long one wheel step plus its
# frame takes with a large worker transcript. Run before/after rendering changes
# to confirm scrolling stays smooth.
#
#   ruby scripts/benchmark_workspace_scroll.rb

require "benchmark"
require "json"
require_relative "../lib/meringue"

WIDTH = Integer(ENV.fetch("COLUMNS", "140"), 10)
HEIGHT = Integer(ENV.fetch("LINES", "45"), 10)
ENTRY_COUNT = Integer(ENV.fetch("MERINGUE_BENCHMARK_ENTRIES", "400"), 10)
SCROLL_STEPS = Integer(ENV.fetch("MERINGUE_BENCHMARK_SCROLL_STEPS", "60"), 10)

def build_state
  now = Time.now.utc.iso8601
  state = Meringue::State::Models.empty_state(now: now)
  state["projects"] << {
    "id" => "P1", "name" => "meringue", "root_path" => Dir.pwd, "status" => "working",
    "issue_ids" => ["P1-I1"], "created_at" => now, "updated_at" => now
  }
  state["issues"] << {
    "id" => "P1-I1", "project_id" => "P1", "title" => "Scroll benchmark", "status" => "working",
    "agent_ids" => ["P1-I1-W1"], "created_at" => now, "updated_at" => now
  }
  state["agents"] << {
    "id" => "P1-I1-W1", "type" => "worker", "status" => "completed", "project_id" => "P1",
    "issue_id" => "P1-I1", "harness" => "pi", "workspace_path" => Dir.pwd,
    "harness_metadata" => { "title" => "Scroll latency probe", "cwd" => Dir.pwd },
    "created_at" => now, "updated_at" => now
  }
  state
end

# Stands in for Sessions::WorkerSessionService: a stable, deeply frozen snapshot
# with a revision, exactly like the real service hands to the renderer.
class StubSession
  def initialize(entry_count)
    now = Time.now.utc
    items = entry_count.times.map do |index|
      {
        "role" => index.even? ? "assistant" : "user",
        "content" => "Transcript entry #{index}: " + ("wrapped transcript body text " * 6),
        "timestamp" => (now + index).iso8601,
        "id" => "item-#{index}",
        "phase" => "complete",
        "stop_reason" => "endTurn"
      }
    end
    @snapshot = deep_freeze(
      "harness" => "pi", "availability" => "live", "session_state" => "idle", "items" => items
    )
  end

  def snapshot
    @snapshot.merge("revision" => 1)
  end

  def poll_events(limit: nil) = { "events" => [], "gap" => false }
  def pause = true
  def resume = true
  def close = true

  private

  def deep_freeze(value)
    case value
    when Hash then value.each_with_object({}) { |(k, v), c| c[k.to_s] = deep_freeze(v) }.freeze
    when Array then value.map { |v| deep_freeze(v) }.freeze
    when String then value.frozen? ? value : value.dup.freeze
    else value
    end
  end
end

class StubSessionService
  def initialize(entry_count)
    @session = StubSession.new(entry_count)
  end

  def open(_agent_id) = @session
end

state = build_state
serialized_state = JSON.generate(state)
provider = -> { JSON.parse(serialized_state) }
app = Meringue::TUI::App.new(agent_session_service: StubSessionService.new(ENTRY_COUNT))
app.instance_variable_set(:@last_render_width, WIDTH)
app.instance_variable_set(:@last_render_height, HEIGHT)
app.send(:open_agent_workspace_by_id, provider.call, "P1-I1-W1")

wheel_up = { "type" => "mouse", "kind" => "wheel_up", "button" => 64, "x" => 10, "y" => 10, "pressed" => true }

def scroll_frame(app, provider, key)
  state = app.send(:compose_state, provider, "", -1, 0)
  app.send(:handle_key, key, "", 0, -1, nil, state)
  state = app.send(:compose_state, provider, "", -1, 0)
  app.render(state, width: WIDTH, height: HEIGHT, color: true)
end

cold_seconds = Benchmark.realtime { scroll_frame(app, provider, wheel_up) }
samples = SCROLL_STEPS.times.map { Benchmark.realtime { scroll_frame(app, provider, wheel_up) } }
average = samples.sum / samples.length

puts "workspace transcript entries: #{ENTRY_COUNT}"
puts "viewport: #{WIDTH}x#{HEIGHT}"
puts format("cold scroll frame: %.2f ms", cold_seconds * 1000)
puts format("warm scroll frame average: %.2f ms", average * 1000)
puts format("warm scroll frame maximum: %.2f ms", samples.max * 1000)
puts format("warm scroll frame minimum: %.2f ms", samples.min * 1000)
