# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Bounded replacement for scripts/benchmark_workspace_scroll.rb, which only
# printed timings. It keeps the two properties that made focused-workspace
# scrolling smooth:
#
#   * feeding a large, chunked, colorized PTY stream into the screen model and
#     re-rendering it many times stays cheap;
#   * an unchanged screen keeps its revision, which is the signal renderers use
#     to reuse cached rows instead of re-laying out every frame.
#
# The bounds are deliberately generous (measured well under a second on a
# development laptop) so the test cannot become flaky on slow CI.
class WorkspaceTerminalScrollPerformanceTest < Minitest::Test
  include WorkspaceSupport

  ROWS = 45
  COLUMNS = 140
  OUTPUT_LINES = 3_000
  RENDER_FRAMES = 200
  FEED_BUDGET_SECONDS = 10.0
  RENDER_BUDGET_SECONDS = 10.0

  def test_large_chunked_output_and_repeated_renders_stay_within_budget
    screen = Meringue::Workspace::TerminalScreen.new(rows: ROWS, columns: COLUMNS)
    stream = OUTPUT_LINES.times.map do |index|
      "\e[3#{index % 8}mline #{index}\e[0m " + ("wrapped transcript body text " * 4) + "\r\n"
    end

    feed_seconds = elapsed do
      stream.each_slice(50) { |chunk| screen.feed(chunk.join) }
    end
    render_seconds = elapsed do
      RENDER_FRAMES.times do
        screen.lines
        screen.styled_lines
      end
    end

    assert_operator feed_seconds, :<, FEED_BUDGET_SECONDS,
                    "feeding #{OUTPUT_LINES} colorized lines took #{format("%.1f", feed_seconds * 1000)}ms"
    assert_operator render_seconds, :<, RENDER_BUDGET_SECONDS,
                    "#{RENDER_FRAMES} render frames took #{format("%.1f", render_seconds * 1000)}ms"

    assert_equal ROWS, screen.lines.length
    assert_includes screen.lines.last(2).join, "line #{OUTPUT_LINES - 1}"
    assert screen.styled_lines.first.any? { |(_text, style)| style.to_s.start_with?("\e[") }
  end

  def test_renders_of_an_unchanged_screen_keep_the_cached_revision
    screen = Meringue::Workspace::TerminalScreen.new(rows: ROWS, columns: COLUMNS)
    500.times { |index| screen.feed("scrollback line #{index}\r\n") }
    revision = screen.revision

    50.times do
      screen.lines
      screen.styled_lines
    end

    assert_equal revision, screen.revision, "rendering must never invalidate the renderer's cache key"

    screen.feed("new output\r\n")
    assert_operator screen.revision, :>, revision
  end

  def test_resize_during_scrolling_stays_bounded
    screen = Meringue::Workspace::TerminalScreen.new(rows: ROWS, columns: COLUMNS)
    1_000.times { |index| screen.feed("line #{index} " + ("body " * 10) + "\r\n") }

    seconds = elapsed do
      60.times do |step|
        screen.resize(rows: 20 + (step % 25), columns: 80 + (step % 60))
        screen.lines
      end
    end

    assert_operator seconds, :<, FEED_BUDGET_SECONDS,
                    "60 resize+render steps took #{format("%.1f", seconds * 1000)}ms"
  end

  private

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end
