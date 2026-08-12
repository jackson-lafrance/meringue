# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "fileutils"
require "stringio"
require "tmpdir"

# App#run hands the TUI `-> { state_store.load }` as its state provider. The dashboard keeps that
# large, read-only orchestration snapshot independent from transient composer state and refreshes
# it on a bounded cadence. `typing_throughput_test.rb` covers rendering against an in-memory
# provider; this covers the Store-facing half whose cost grows with accumulated state.
#
# The invariants here are structural rather than stopwatch-only: a typing burst must acquire and
# parse one base snapshot, while writes from this or another Meringue instance become visible by
# the next refresh and invalidate selections whose records were pruned or recounted.
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
    @clock = 0.0
    @provider_calls = 0
    @provider = lambda do
      @provider_calls += 1
      @store.load
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_repeated_typing_acquires_and_parses_one_base_state_within_the_refresh_window
    FRAMES.times { |index| typing_frame("typing #{index}") }

    assert_equal 1, @provider_calls,
                 "#{FRAMES} typing frames inside one refresh window must acquire one base snapshot"
    assert_equal 1, @store.snapshot_misses,
                 "#{FRAMES} frames over an unchanged state file must normalize it only once"
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

  def test_an_external_durable_change_is_visible_by_the_refresh_bound
    typing_frame("typing")

    marker = "a worker settled while the user was typing"
    other_store = Meringue::State::Store.new(path: @path)
    updated = other_store.load
    updated.fetch("logs") << log_record("L#{LOG_COUNT + 1}", "source_type" => "worker", "message" => marker)
    other_store.save(updated, preserve_log_buffer: false)

    refute typing_state("still responsive").fetch("logs").any? { |log| log.fetch("message", nil) == marker }
    advance_to_refresh_bound

    assert typing_state("still responsive").fetch("logs").any? { |log| log.fetch("message", nil) == marker }
    assert_equal 2, @provider_calls
  end

  def test_a_pruned_selection_is_cleared_when_the_base_state_refreshes
    assert @app.send(:select_agent_tree_item, @store.load, "P1-I1-W1")
    @app.send(:exit_agent_tree_navigation)
    typing_frame("typing")

    updated = @store.load
    updated.fetch("agents").reject! { |agent| agent.fetch("id") == "P1-I1-W1" }
    @store.save(updated, preserve_log_buffer: false)
    advance_to_refresh_bound

    composed = typing_state("after prune")
    assert_empty Meringue::TUI::LogScope.id(composed)
    assert_nil Meringue::TUI::LogScope.chat_target(composed)
  end

  def test_a_recounted_selection_is_cleared_when_its_old_id_disappears
    assert @app.send(:select_agent_tree_item, @store.load, "P1-I2-W1")
    @app.send(:exit_agent_tree_navigation)
    typing_frame("typing")

    updated = @store.load
    agent = updated.fetch("agents").find { |candidate| candidate.fetch("id") == "P1-I2-W1" }
    agent["id"] = "P1-I2-W9"
    @store.save(updated, preserve_log_buffer: false)
    advance_to_refresh_bound

    composed = typing_state("after recount")
    assert_empty Meringue::TUI::LogScope.id(composed)
    assert_nil Meringue::TUI::LogScope.chat_target(composed)
  end

  private

  def typing_frame(text)
    @app.render(typing_state(text), width: WIDTH, height: HEIGHT, color: true)
  end

  def typing_state(text)
    base_state = @app.send(:read_only_base_state, @provider, now: @clock)
    compose_app_state(@app, -> { base_state }, text, -1, text.length)
  end

  def advance_to_refresh_bound
    @clock += Meringue::TUI::App::REFRESH_INTERVAL
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
