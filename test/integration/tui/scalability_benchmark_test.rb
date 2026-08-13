# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"

# Structural guard for the process-level benchmark. It intentionally uses a
# tiny workload: the benchmark's machine-specific latency sweep is opt-in, while
# CI proves that isolation, mocked activity, rendering acknowledgements, state
# visibility, and exactly-once synthetic events remain wired end to end.
class TuiScalabilityBenchmarkTest < Minitest::Test
  def test_separate_process_benchmark_is_hermetic_and_observes_concurrent_updates
    script = File.expand_path("../../../benchmark/scalability.rb", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, script,
      "--loads", "12", "--samples", "20", "--interval", "0.01", "--json"
    )

    assert status.success?, stderr
    report = JSON.parse(stdout)
    result = report.fetch("results").fetch(0)

    assert_equal 12, result.fetch("issues")
    assert_equal 12, result.fetch("agents")
    assert_equal true, result.fetch("ansi_color"), "benchmark must cover the production ANSI typing path"
    assert_includes report.fetch("methodology"), "ANSI rendered-frame"
    updates = result.fetch("synthetic_updates")
    assert_operator updates, :>, 0
    assert_equal true, result.fetch("state_visibility")
    assert_equal true, result.fetch("exactly_once")
    assert_equal Array.new(8, updates), result.fetch("active_revisions")
    assert_equal result.fetch("expected_retained_events"), result.fetch("retained_events")
    assert_equal (1..updates).map { |revision| "synthetic-#{revision}" }, result.fetch("retained_events")
    refute_empty result.fetch("rendered_revisions"), "a committed reconciliation revision must appear in child-rendered bytes"
    assert_operator result.fetch("rendered_revisions").max, :<=, updates
    assert_operator result.fetch("rendered_scroll_markers").uniq.length, :>, 1,
      "wheel inputs must change the viewport bytes rendered by the child"
    %w[typing scrolling].each do |interaction|
      assert_equal %w[max_ms median_ms p95_ms p99_ms], result.fetch(interaction).keys.sort
      assert_operator result.dig(interaction, "max_ms"), :>, 0
    end
  end
end
