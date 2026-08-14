# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"

# Replaces the assertions that used to live in scripts/benchmark_tui_typing.rb.
# The bounds are deliberately generous: this guards against a regression that
# makes every keystroke re-render the whole log history, not against small
# machine-to-machine timing differences.
class TuiTypingThroughputTest < Minitest::Test
  include TUISupport

  WIDTH = 140
  HEIGHT = 45
  LOG_COUNT = Meringue::State::Models::LOG_RETENTION_LIMIT
  WARM_FRAMES = 20
  # A typing frame that takes longer than this is broken, not merely slow.
  MAX_WARM_FRAME_SECONDS = 1.0
  MAX_WARM_AVERAGE_SECONDS = 0.25
  MAX_WARM_TOTAL_SECONDS = 5.0
  # Composing a warm frame must stay far cheaper than the first, fully
  # uncached frame.
  MAX_WARM_TO_COLD_RATIO = 5.0

  def setup
    @serialized_state = JSON.generate(history_state)
    @provider = -> { JSON.parse(@serialized_state) }
    @app = build_app(terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT))
    # App#run records these before composing each frame; the retired benchmark
    # set them the same way so scroll bounds match the render width.
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
  end

  def test_typing_frames_stay_cheap_after_the_first_render
    cold_seconds = measure { typing_frame("a") }
    warm_seconds = WARM_FRAMES.times.map { |index| measure { typing_frame("typing #{index}") } }
    warm_average = warm_seconds.sum / warm_seconds.length

    assert_operator warm_seconds.max, :<, MAX_WARM_FRAME_SECONDS, timing_message(cold_seconds, warm_seconds)
    assert_operator warm_average, :<, MAX_WARM_AVERAGE_SECONDS, timing_message(cold_seconds, warm_seconds)
    assert_operator warm_seconds.sum, :<, MAX_WARM_TOTAL_SECONDS, timing_message(cold_seconds, warm_seconds)
    assert_operator warm_average, :<, cold_seconds * MAX_WARM_TO_COLD_RATIO, timing_message(cold_seconds, warm_seconds)
  end

  def test_scrolling_frames_stay_cheap_with_a_full_retained_log_window
    cold_seconds = measure { scrolling_frame(1) }
    warm_seconds = WARM_FRAMES.times.map { |index| measure { scrolling_frame(index.even? ? 0 : 3) } }
    warm_average = warm_seconds.sum / warm_seconds.length

    assert_operator warm_seconds.max, :<, MAX_WARM_FRAME_SECONDS, timing_message(cold_seconds, warm_seconds)
    assert_operator warm_average, :<, MAX_WARM_AVERAGE_SECONDS, timing_message(cold_seconds, warm_seconds)
    assert_operator warm_seconds.sum, :<, MAX_WARM_TOTAL_SECONDS, timing_message(cold_seconds, warm_seconds)
  end

  def test_caching_never_hides_a_durable_state_update
    WARM_FRAMES.times { |index| typing_frame("typing #{index}") }

    marker = "new log invalidated the presentation cache"
    updated = history_state
    updated["logs"] << log_record("L#{LOG_COUNT + 1}", "source_type" => "system", "message" => marker)
    @serialized_state = JSON.generate(updated)

    assert_includes typing_frame("still responsive"), marker
  end

  def test_frequent_log_appends_do_not_relayout_the_retained_window
    state = history_state
    provider = -> { state }
    typing_frame_from(provider, "warm")
    layouts = 0
    pane = @app.instance_variable_get(:@layout).instance_variable_get(:@chat_pane)
    original = pane.method(:body_lines)
    pane.define_singleton_method(:body_lines) do |entry, **arguments|
      layouts += 1
      original.call(entry, **arguments)
    end

    10.times do |index|
      state = state.merge(
        "logs" => state.fetch("logs") + [log_record("L#{LOG_COUNT + index + 1}", "message" => "live update #{index}")]
      )
      typing_frame_from(provider, "typing #{index}")
    end

    assert_equal 10, layouts, "each append should lay out only its new log entry"
  end

  def test_a_keystroke_only_changes_the_composer_rows
    first = typing_frame("ab").split("\n", -1)
    second = typing_frame("abc").split("\n", -1)

    assert_equal first.length, second.length
    differing = first.each_index.reject { |index| first[index] == second[index] }

    refute_empty differing, "the typed text must be visible"
    assert differing.all? { |index| index >= first.length - 4 },
           "only the composer rows may change while typing, changed rows: #{differing.inspect}"
  end

  def test_typed_text_is_rendered_in_the_composer
    frame = typing_frame("hello kernel")

    assert_includes strip_ansi(frame), "hello kernel"
  end

  def test_wide_history_renders_within_the_requested_rectangle
    lines = typing_frame("x").split("\n", -1)

    assert_equal HEIGHT, lines.length
    assert_equal [WIDTH], lines.map { |line| strip_ansi(line).length }.uniq
  end

  private

  def typing_frame(text)
    typing_frame_from(@provider, text)
  end

  def scrolling_frame(offset)
    @app.instance_variable_get(:@scroll_offsets)["logs"] = offset
    typing_frame("scroll probe")
  end

  def typing_frame_from(provider, text)
    state = compose_app_state(@app, provider, text, -1, text.length)
    @app.render(state, width: WIDTH, height: HEIGHT, color: true)
  end

  def measure
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def timing_message(cold_seconds, warm_seconds)
    format(
      "cold %.1fms, warm avg %.1fms, warm max %.1fms over %d frames",
      cold_seconds * 1_000,
      (warm_seconds.sum / warm_seconds.length) * 1_000,
      warm_seconds.max * 1_000,
      warm_seconds.length
    )
  end

  def history_state
    state = empty_state
    state["agents"] << agent_record(
      "P1-I1-W1",
      "status" => "completed",
      "harness_metadata" => { "title" => "Typing latency probe" }
    )
    LOG_COUNT.times do |index|
      state["logs"] << log_record(
        "L#{index + 1}",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => "Worker P1-I1-W1 completed.",
        "details" => {
          "last_assistant_text" => <<~MARKDOWN.strip
            ## Result #{index + 1}

            - rendered Markdown output
            - enough text to wrap across the logs pane and reproduce history cost
          MARKDOWN
        }
      )
    end
    state
  end
end
