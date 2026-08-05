# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "fileutils"
require "stringio"
require "tmpdir"

# App#run hands the TUI `-> { state_store.load }` as its state provider, so this runs for every
# rendered frame and every keystroke. `typing_throughput_test.rb` covers the render half of a
# frame against an in-memory provider; this covers the half that touches disk, which is the half
# whose cost grows with how much work the user has accumulated.
#
# The reported slowdown had this as its steady drag: a 1 MB state file was re-read, re-normalized,
# and deep string-compacted on every frame even though nothing had changed. The invariant pinned
# here is structural rather than a stopwatch: an idle Meringue must normalize state once, not once
# per frame, so per-keystroke cost stops scaling with total state size.
class TuiStateReloadCostTest < Minitest::Test
  include TUISupport

  WIDTH = 140
  HEIGHT = 45
  FRAMES = 30
  # Big enough that re-normalizing per frame is clearly visible, small enough to stay fast.
  ISSUE_COUNT = 120
  AGENT_COUNT = 120
  LOG_COUNT = 200
  # A frame that takes longer than this is broken, not merely slow. Deliberately generous: this
  # guards against per-frame O(state) work, not against machine-to-machine timing differences.
  MAX_WARM_AVERAGE_SECONDS = 0.25

  def setup
    @dir = Dir.mktmpdir("meringue-tui-state-reload-")
    @path = File.join(@dir, "state.json")
    File.write(@path, JSON.pretty_generate(large_state) + "\n")
    @store = Meringue::State::Store.new(path: @path)
    @app = build_app(terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT))
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_an_idle_dashboard_normalizes_state_once_no_matter_how_many_frames_it_renders
    FRAMES.times { |index| typing_frame("typing #{index}") }

    assert_equal 1, @store.snapshot_misses,
                 "#{FRAMES} frames over an unchanged state file must not re-normalize it #{FRAMES} times"
  end

  def test_frames_over_a_large_state_file_stay_cheap
    typing_frame("warm")
    seconds = FRAMES.times.map do |index|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      typing_frame("typing #{index}")
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
    average = seconds.sum / seconds.length

    assert_operator average, :<, MAX_WARM_AVERAGE_SECONDS,
                    format("warm avg %.1fms over %d frames", average * 1_000, seconds.length)
  end

  def test_a_durable_state_change_is_still_visible_on_the_next_frame
    FRAMES.times { |index| typing_frame("typing #{index}") }

    marker = "a worker settled while the user was typing"
    updated = @store.load
    updated.fetch("logs") << log_record("L#{LOG_COUNT + 1}", "source_type" => "worker", "message" => marker)
    @store.save(updated, preserve_log_buffer: false)

    assert_includes strip_ansi(typing_frame("still responsive")), marker
  end

  private

  def typing_frame(text)
    state = compose_app_state(@app, -> { @store.load }, text, -1, text.length)
    @app.render(state, width: WIDTH, height: HEIGHT, color: true)
  end

  def large_state
    state = empty_state
    state["projects"] << project_record("P1")
    ISSUE_COUNT.times do |index|
      state["issues"] << issue_record("P1-I#{index + 1}", "description" => "Seeded issue body. " * 40)
    end
    AGENT_COUNT.times do |index|
      state["agents"] << agent_record(
        "P1-I#{index + 1}-W1",
        "status" => "completed",
        "issue_id" => "P1-I#{index + 1}",
        "project_id" => "P1",
        "harness_metadata" => {
          "title" => "Worker #{index + 1}",
          "last_assistant_text" => "Reported result text. " * 100
        }
      )
    end
    LOG_COUNT.times do |index|
      state["logs"] << log_record(
        "L#{index + 1}",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "message" => "Worker P1-I1-W1 completed.",
        "details" => { "last_assistant_text" => "Durable log detail. " * 50 }
      )
    end
    state
  end
end
