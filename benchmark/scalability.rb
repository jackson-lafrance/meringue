#!/usr/bin/env ruby
# frozen_string_literal: true

# Hermetic process-level responsiveness benchmark. The parent generates an
# isolated state file and drives the real Meringue TUI loop in a child process.
# Every input is acknowledged only after the frame containing it is rendered,
# so samples include input transport, state composition, layout, and output.

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tempfile"
require "tmpdir"
require "time"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "meringue"

module ScalabilityBenchmark
  BASE_TIME = "2026-01-01T00:00:00Z"
  DEFAULT_LOADS = [25, 100, 250, 500, 1_000].freeze
  WIDTH = 140
  HEIGHT = 45

  module_function

  def generated_state(count:, logs:, payload_bytes:)
    state = Meringue::State::Models.empty_state(now: BASE_TIME)
    state["projects"] << {
      "id" => "P1", "name" => "Hermetic scale benchmark", "root_path" => "/tmp/hermetic",
      "status" => "working", "created_at" => BASE_TIME, "updated_at" => BASE_TIME
    }
    count.times do |index|
      number = index + 1
      issue_id = "P1-I#{number}"
      agent_id = "#{issue_id}-W1"
      active = index < [(count * 0.6).ceil, 1].max
      state["issues"] << {
        "id" => issue_id, "project_id" => "P1", "parent_issue_id" => nil,
        "title" => "Synthetic task #{number}", "description" => "x" * payload_bytes,
        "status" => active ? "working" : "completed", "agent_ids" => [agent_id],
        "created_at" => BASE_TIME, "updated_at" => BASE_TIME
      }
      state["agents"] << {
        "id" => agent_id, "type" => "worker", "project_id" => "P1", "issue_id" => issue_id,
        "status" => active ? "working" : "completed", "harness" => "fake", "pid" => nil,
        "harness_session_id" => "mock-session-#{number}", "is_streaming" => active,
        "harness_metadata" => { "kind" => "worker", "title" => "Mock worker #{number}", "synthetic_revision" => 0 },
        "created_at" => BASE_TIME, "updated_at" => BASE_TIME
      }
    end
    logs.times do |index|
      state["logs"] << {
        "id" => "L#{index + 1}", "timestamp" => BASE_TIME, "source_type" => "worker",
        "source_id" => "P1-I#{(index % count) + 1}-W1", "level" => "info",
        "message" => "Synthetic retained log #{index + 1}",
        "details" => { "summary" => "token-free mocked activity" }
      }
    end
    state["counters"]["logs"] = logs
    state["metadata"]["synthetic_tasks"] = count
    state
  end

  class ProtocolTerminal
    attr_reader :rendered_revisions, :rendered_scroll_markers

    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
      @sequence = nil
      @typed = +""
      @rendered_revisions = []
      @rendered_scroll_markers = []
    end

    def interactive? = true
    def dimensions = [WIDTH, HEIGHT]
    def with_screen = yield
    def raw = yield
    def invalidate_frame! = nil

    def read_key(timeout:)
      ready = IO.select([@input], nil, nil, timeout)
      return nil unless ready

      line = @input.gets
      return nil unless line

      request = JSON.parse(line)
      @sequence = request.fetch("sequence")
      key = request.fetch("key")
      @typed << key if key.is_a?(String) && key.match?(/\A[[:print:]]+\z/)
      key
    end

    def write_frame(frame)
      # These markers are extracted from the bytes the child actually handed to the
      # terminal. They are deliberately not read from Store, so visibility and scroll
      # assertions cannot pass merely because the disk state changed behind the TUI.
      revisions = frame.scan(/synthetic reconciliation (\d+)/).flatten.map(&:to_i)
      rendered_revision = revisions.max
      @rendered_revisions << rendered_revision if rendered_revision
      sidebar_width = [[(WIDTH * 0.34).floor, Meringue::TUI::Layout::SIDEBAR_MIN_WIDTH].max,
                       Meringue::TUI::Layout::SIDEBAR_MAX_WIDTH, WIDTH - 36].min
      scroll_frame = frame.lines.map { |line| line[sidebar_width..].to_s }.join("\n")
      scroll_marker = Digest::SHA256.hexdigest(scroll_frame)
      @rendered_scroll_markers << scroll_marker
      @output.puts(JSON.generate(
        "type" => "frame", "sequence" => @sequence, "bytes" => frame.bytesize,
        "digest" => Digest::SHA256.hexdigest(frame), "typed_visible" => frame.include?(@typed),
        "rendered_revision" => rendered_revision, "scroll_marker" => scroll_marker
      ))
      @output.flush
    end
  end

  class SyntheticReconciler
    attr_reader :updates

    def initialize(store)
      @store = store
      @updates = 0
      @fake = Meringue::Harness::FakeClient.new
    end

    def call
      state = @store.load
      @updates += 1
      active = state.fetch("agents").select { |agent| agent["status"] == "working" }
      active.each do |agent|
        # Exercise the generic harness boundary without opening a process or model turn.
        @fake.get_state("session_id" => agent.fetch("harness_session_id"), "is_streaming" => true)
        metadata = agent.fetch("harness_metadata")
        metadata["synthetic_revision"] = @updates
        metadata["last_event_at"] = @updates
      end
      log_number = state.fetch("counters").fetch("logs", 0).to_i + 1
      state["counters"]["logs"] = log_number
      state["logs"] << {
        "id" => "L#{log_number}", "timestamp" => BASE_TIME, "source_type" => "harness",
        "source_id" => active.first&.fetch("id", nil), "level" => "info",
        "message" => "synthetic reconciliation #{@updates}",
        "details" => { "event_id" => "synthetic-#{@updates}", "active_agents" => active.length }
      }
      state["metadata"]["synthetic_updates"] = @updates
      state["metadata"]["updated_at"] = "2026-01-01T00:00:#{format('%02d', @updates % 60)}Z"
      @store.save(state, preserve_log_buffer: false)
    end
  end

  def child(path:, interval:)
    store = Meringue::State::Store.new(path: path)
    reconciler = SyntheticReconciler.new(store)
    terminal = ProtocolTerminal.new
    tui = Meringue::TUI::App.new(terminal: terminal, out: $stdout, log_store: store)
    app_options = { state_path: path, state_store: store, tui_app: tui, reconciler: reconciler }
    supports_interval = Meringue::App.instance_method(:initialize).parameters.any? { |_kind, name| name == :reconcile_interval }
    if supports_interval
      app_options[:reconcile_interval] = interval
    else
      # Lets the same harness benchmark an older revision before the injectable
      # cadence existed; this process is isolated, so replacing the constant is local.
      Meringue::App.send(:remove_const, :RECONCILE_INTERVAL)
      Meringue::App.const_set(:RECONCILE_INTERVAL, interval)
    end
    app = Meringue::App.new(**app_options)
    exit_code = app.run
    final = store.load
    revisions = final.fetch("agents").select { |agent| agent["status"] == "working" }
      .map { |agent| agent.dig("harness_metadata", "synthetic_revision").to_i }
    events = final.fetch("logs").filter_map { |log| log.dig("details", "event_id") }
    expected_events = (1..reconciler.updates).map { |revision| "synthetic-#{revision}" }
      .last(Meringue::State::Models::LOG_RETENTION_LIMIT)
    rendered_revisions = terminal.rendered_revisions.compact
    $stderr.puts(JSON.generate(
      "type" => "summary", "updates" => reconciler.updates,
      "active_revisions" => revisions,
      "expected_retained_events" => expected_events,
      "retained_events" => events,
      "rendered_revisions" => rendered_revisions,
      "rendered_scroll_markers" => terminal.rendered_scroll_markers,
      "all_active_current" => revisions.all? { |revision| revision == reconciler.updates },
      "events_complete_exactly_once" => events == expected_events,
      "activity_rendered" => rendered_revisions.any?,
      "exit_code" => exit_code
    ))
  end

  def percentile(values, fraction)
    sorted = values.sort
    sorted[[(fraction * (sorted.length - 1)).ceil, sorted.length - 1].min]
  end

  def distribution(values)
    { "median_ms" => percentile(values, 0.50), "p95_ms" => percentile(values, 0.95),
      "p99_ms" => percentile(values, 0.99), "max_ms" => values.max }.transform_values { |value| value.round(2) }
  end

  def run_one(count:, samples:, interval:, payload_bytes:)
    Dir.mktmpdir("meringue-scale-") do |dir|
      path = File.join(dir, "state.json")
      # Keep even the structural CI load taller than the viewport so every wheel
      # acknowledgement can prove a real rendered scroll rather than a no-op.
      logs = [[count * 2, 50].max, Meringue::State::Models::LOG_RETENTION_LIMIT].min
      state = generated_state(count: count, logs: logs, payload_bytes: payload_bytes)
      File.write(path, JSON.pretty_generate(state) + "\n")
      command = [RbConfig.ruby, __FILE__, "--child", path, "--interval", interval.to_s]
      typing = []
      scrolling = []
      peak_rss_kb = 0
      summary = nil
      Open3.popen3({ "NO_COLOR" => "1" }, *command) do |stdin, stdout, stderr, wait|
        initial = JSON.parse(stdout.gets)
        raise "child did not render its initial frame" unless initial["type"] == "frame"
        # Let at least one reconciliation commit and the dashboard refresh window
        # elapse before measured inputs; warm-up is intentionally outside samples.
        sleep [interval * 2, 0.12].max
        sampler = Thread.new do
          while wait.alive?
            rss = `ps -o rss= -p #{wait.pid}`.to_i
            peak_rss_kb = [peak_rss_kb, rss].max
            sleep 0.01
          end
        end
        sequence = 0
        send_input = lambda do |key, bucket|
          sequence += 1
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          stdin.puts(JSON.generate("sequence" => sequence, "key" => key))
          stdin.flush
          begin
            response = JSON.parse(stdout.gets || raise("child exited before frame #{sequence}"))
          end until response["sequence"] == sequence
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
          raise "typed content was not rendered" if bucket.equal?(typing) && !response["typed_visible"]
          bucket << elapsed
          response
        end
        samples.times { send_input.call((sequence % 26 + 97).chr, typing) }
        previous_scroll_marker = initial.fetch("scroll_marker")
        samples.times do |index|
          # Logs are tail-oriented: wheel-up moves away from the newest entry and
          # wheel-down returns. The marker hashes only the rendered logs side.
          up = index.even?
          key = { "type" => "mouse", "kind" => up ? "wheel_up" : "wheel_down",
                  "button" => up ? 64 : 65, "x" => 90, "y" => 12, "pressed" => true, "count" => 1 }
          response = send_input.call(key, scrolling)
          marker = response.fetch("scroll_marker")
          raise "scroll input did not change rendered viewport" if marker.empty? || marker == previous_scroll_marker
          previous_scroll_marker = marker
        end
        sequence += 1
        stdin.puts(JSON.generate("sequence" => sequence, "key" => "\u0004"))
        stdin.flush
        stdin.close
        status = wait.value
        sampler.join
        summary = JSON.parse(stderr.read.lines.last || "{}")
        raise "child failed: #{status}" unless status.success?
        raise "synthetic activity never rendered" unless summary["activity_rendered"]
        raise "active revisions did not converge" unless summary["all_active_current"]
        raise "reconciliation event sequence was incomplete or duplicated" unless summary["events_complete_exactly_once"]
      end
      file_state = JSON.parse(File.read(path))
      {
        "issues" => count, "tasks" => count, "agents" => count,
        "active_agents" => (count * 0.6).ceil, "logs" => file_state.fetch("logs").length,
        "state_mb" => (File.size(path) / 1_048_576.0).round(2),
        "typing" => distribution(typing), "scrolling" => distribution(scrolling),
        "peak_rss_mb" => (peak_rss_kb / 1024.0).round(1),
        "synthetic_updates" => summary.fetch("updates"),
        "rendered_revisions" => summary.fetch("rendered_revisions"),
        "rendered_scroll_markers" => summary.fetch("rendered_scroll_markers"),
        "active_revisions" => summary.fetch("active_revisions"),
        "expected_retained_events" => summary.fetch("expected_retained_events"),
        "retained_events" => summary.fetch("retained_events"),
        "state_visibility" => summary.fetch("all_active_current") && summary.fetch("activity_rendered"),
        "exactly_once" => summary.fetch("events_complete_exactly_once"),
        "fast" => percentile(typing, 0.95) < 50 && percentile(scrolling, 0.95) < 50 &&
          [typing.max, scrolling.max].max < 100
      }
    end
  end

  def parent(options)
    results = []
    options.fetch(:loads).each do |count|
      result = run_one(count: count, samples: options.fetch(:samples), interval: options.fetch(:interval), payload_bytes: options.fetch(:payload_bytes))
      results << result
      warn format("%4d agents | type p95 %6.1fms | scroll p95 %6.1fms | max %6.1fms | %s",
                  count, result.dig("typing", "p95_ms"), result.dig("scrolling", "p95_ms"),
                  [result.dig("typing", "max_ms"), result.dig("scrolling", "max_ms")].max,
                  result["fast"] ? "FAST" : "LIMIT")
      break if !result["fast"] && options.fetch(:stop_at_limit)
    end
    output = {
      "methodology" => "separate process; input write to rendered-frame acknowledgement; fake harness; concurrent isolated-state reconciliation",
      "responsiveness_budget" => { "p95_ms" => 50, "max_ms" => 100 },
      "samples_per_interaction" => options.fetch(:samples), "reconcile_interval_ms" => (options.fetch(:interval) * 1_000).round,
      "results" => results, "largest_fast_workload" => results.select { |item| item["fast"] }.last
    }
    puts options.fetch(:pretty) ? JSON.pretty_generate(output) : JSON.generate(output)
  end
end

options = { loads: ScalabilityBenchmark::DEFAULT_LOADS, samples: 60, interval: 0.1,
            payload_bytes: 256, pretty: true, stop_at_limit: true }
child_path = nil
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby benchmark/scalability.rb [options]"
  opts.on("--loads LIST", "Comma-separated issue/agent counts") { |value| options[:loads] = value.split(",").map { |item| Integer(item) } }
  opts.on("--samples N", Integer, "Typing and scrolling samples per load") { |value| options[:samples] = value }
  opts.on("--interval SECONDS", Float, "Synthetic reconciliation cadence") { |value| options[:interval] = value }
  opts.on("--payload-bytes N", Integer, "Generated issue-description bytes") { |value| options[:payload_bytes] = value }
  opts.on("--[no-]stop-at-limit") { |value| options[:stop_at_limit] = value }
  opts.on("--json") { options[:pretty] = false }
  opts.on("--child PATH", "Internal child-process mode") { |value| child_path = value }
end
parser.parse!

if child_path
  ScalabilityBenchmark.child(path: File.expand_path(child_path), interval: options.fetch(:interval))
else
  ScalabilityBenchmark.parent(options)
end
