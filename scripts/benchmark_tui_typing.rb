# frozen_string_literal: true

require "benchmark"
require "json"
require_relative "../lib/meringue"

WIDTH = Integer(ENV.fetch("COLUMNS", "140"), 10)
HEIGHT = Integer(ENV.fetch("LINES", "45"), 10)
LOG_COUNT = Integer(ENV.fetch("MERINGUE_BENCHMARK_LOGS", "250"), 10)
FRAME_COUNT = Integer(ENV.fetch("MERINGUE_BENCHMARK_FRAMES", "30"), 10)

def build_state
  now = Time.now.utc.iso8601
  state = Meringue::State::Models.empty_state(now: now)
  state["agents"] << {
    "id" => "P1-I1-W1",
    "type" => "worker",
    "status" => "completed",
    "harness_metadata" => { "title" => "Typing latency probe" }
  }
  LOG_COUNT.times do |index|
    state["logs"] << {
      "id" => "L#{index + 1}",
      "timestamp" => now,
      "source_type" => "worker",
      "source_id" => "P1-I1-W1",
      "level" => "info",
      "message" => "Worker P1-I1-W1 completed.",
      "details" => {
        "last_assistant_text" => <<~MARKDOWN.strip
          ## Result #{index + 1}

          - rendered Markdown output
          - enough text to wrap across the logs pane and reproduce history cost
        MARKDOWN
      }
    }
  end
  state
end

def render_typing_frame(app, provider, text)
  state = app.send(:compose_state, provider, text, -1, text.length)
  app.render(state, width: WIDTH, height: HEIGHT, color: true)
end

state = build_state
serialized_state = JSON.generate(state)
provider = -> { JSON.parse(serialized_state) }
app = Meringue::TUI::App.new
# App#run records these before composing each frame. Set them here so this
# benchmark exercises the same scroll-bound and render widths as the TUI.
app.instance_variable_set(:@last_render_width, WIDTH)
app.instance_variable_set(:@last_render_height, HEIGHT)

cold_seconds = Benchmark.realtime { render_typing_frame(app, provider, "a") }
warm_seconds = FRAME_COUNT.times.map do |index|
  Benchmark.realtime { render_typing_frame(app, provider, "typing #{index}") }
end
warm_average = warm_seconds.sum / warm_seconds.length
warm_maximum = warm_seconds.max
ratio = warm_average / cold_seconds

# Confirm that caching never hides a durable state update.
marker = "new log invalidated the presentation cache"
state["logs"] << {
  "id" => "L#{LOG_COUNT + 1}",
  "timestamp" => Time.now.utc.iso8601,
  "source_type" => "system",
  "level" => "info",
  "message" => marker
}
serialized_state = JSON.generate(state)
updated_frame = render_typing_frame(app, provider, "still responsive")
state_update_visible = updated_frame.include?(marker)

puts format("cold frame: %.2f ms", cold_seconds * 1_000)
puts format("typing frame average: %.2f ms", warm_average * 1_000)
puts format("typing frame max: %.2f ms", warm_maximum * 1_000)
puts format("warm/cold ratio: %.3f", ratio)
puts "state update visible after warm frames: #{state_update_visible ? "yes" : "no"}"
