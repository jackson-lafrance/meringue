# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Coverage for the background delivery-PR refresh that runs on every ~2s reconcile tick.
#
# The reported "Meringue is slow" freeze came from this step: it performed one blocking `gh pr
# view` per stale PR while holding the in-process state mutex *and* the cross-process state file
# lock. Every kernel command queued behind the whole burst. These tests pin the three properties
# that keep a background refresh background: it releases the lock during forge I/O, it is bounded
# per tick, and it does not re-synchronize every record onto one tick.
#
# Forge lookups are stubbed in-process against temporary state; no real state or network service
# is ever touched.
class KernelMaintenanceReconcileDeliveryPullRequestTest < Minitest::Test
  include KernelMaintenanceSupport

  # Blocks inside the first status lookup until a test releases it, so a test can observe what the
  # rest of Meringue can do while a forge call is in flight.
  class BlockingStatusForgeClient
    attr_reader :entered, :release, :status_calls

    def initialize
      @entered = Queue.new
      @release = Queue.new
      @status_calls = []
      @mutex = Mutex.new
    end

    def pull_request_status(url)
      first = @mutex.synchronize do
        @status_calls << url.to_s
        @status_calls.length == 1
      end
      if first
        entered << url.to_s
        release.pop
      end
      { "provider" => "github", "url" => url.to_s, "state" => "open", "raw_state" => "OPEN" }
    end

    def pull_request_urls_for_branch(repository:, branch:)
      []
    end
  end

  # Accepts the kernel's per-call timeout and burns it, which is how a slow or unreachable forge
  # behaves. Used to prove one tick honours a single shared budget.
  class SlowStatusForgeClient
    attr_reader :timeouts

    def initialize(delay:)
      @delay = delay
      @timeouts = []
    end

    def pull_request_status(url, timeout: nil)
      @timeouts << timeout
      sleep(@delay)
      { "provider" => "github", "url" => url.to_s, "state" => "open", "raw_state" => "OPEN" }
    end

    def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
      []
    end
  end

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_refreshing_a_delivery_pull_request_records_the_forge_state
    url = "https://github.com/acme/app/pull/11"
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_with_pull_request(id: "P1-I1", project_id: "P1", url: url)]
      )
    )
    forge = KernelMaintenanceSupport::StubForgeClient.new(
      statuses: { url => { "provider" => "github", "url" => url, "state" => "merged", "raw_state" => "MERGED" } }
    )

    result = build_engine(forge_client: forge).apply("type" => "ReconcileSessions", "payload" => {})
    refresh = result.dig("result", "delivery_pull_request_refreshes").first
    record = issue_by_id(read_state, "P1-I1").fetch("delivery_pull_requests").first

    assert_equal "accepted", result.fetch("status")
    assert_equal [url], forge.status_calls
    assert_equal "merged", refresh.fetch("state")
    assert_equal "merged", record.fetch("state")
    assert_equal "available", record.fetch("availability")
    refute_nil record.fetch("last_checked_at")
  end

  def test_an_unavailable_forge_never_overwrites_the_last_known_state
    url = "https://github.com/acme/app/pull/12"
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_with_pull_request(id: "P1-I1", project_id: "P1", url: url)]
      )
    )

    # The stub answers "unknown" for any URL it was not given a status for.
    build_engine.apply("type" => "ReconcileSessions", "payload" => {})
    record = issue_by_id(read_state, "P1-I1").fetch("delivery_pull_requests").first

    assert_equal "open", record.fetch("state"), "an unreachable forge must not erase the known state"
    assert_equal "unavailable", record.fetch("availability")
    refute_nil record.fetch("last_refresh_error")
  end

  def test_reconciliation_does_not_hold_the_state_lock_while_a_forge_lookup_blocks
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_with_pull_request(id: "P1-I1", project_id: "P1", url: "https://github.com/acme/app/pull/21")]
      )
    )
    forge = BlockingStatusForgeClient.new
    reconcile_engine = build_engine(forge_client: forge)
    other_engine = build_engine
    reconcile_thread = Thread.new { reconcile_engine.reconcile_sessions }

    forge.entered.pop
    # On the regression the whole burst ran inside `synchronized_state`, so both of these waited
    # for the forge. Release on a timer so the old implementation fails on latency instead of
    # deadlocking the suite.
    delayed_release = Thread.new do
      sleep 0.4
      forge.release << true
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    list_result = other_engine.apply("type" => "ListAll", "payload" => {})
    cross_instance_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    issue_result = other_engine.apply(
      "type" => "CreateIssue",
      "payload" => { "project_id" => "P1", "title" => "Typed while the forge was slow" }
    )
    command_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "accepted", list_result.fetch("status")
    assert_equal "accepted", issue_result.fetch("status")
    assert_operator cross_instance_elapsed, :<, 0.2, "background forge I/O must not hold the shared state lock"
    assert_operator command_elapsed, :<, 0.2, "a kernel command must not queue behind a background PR refresh"

    delayed_release.join
    assert_equal "accepted", reconcile_thread.value.fetch("status")
  ensure
    forge&.release&.push(true) if reconcile_thread&.alive?
    reconcile_thread&.join(1)
    reconcile_thread&.kill if reconcile_thread&.alive?
  end

  def test_one_tick_refreshes_at_most_the_batch_limit
    limit = Meringue::Kernel::Engine::DELIVERY_PULL_REQUEST_REFRESH_BATCH_LIMIT
    count = limit + 3
    issues = (1..count).map do |index|
      issue_with_pull_request(id: "P1-I#{index}", project_id: "P1", url: "https://github.com/acme/app/pull/#{index}")
    end
    write_state(state_fixture(projects: [project_record(id: "P1", status: "working")], issues: issues))
    forge = KernelMaintenanceSupport::StubForgeClient.new
    engine = build_engine(forge_client: forge)

    engine.apply("type" => "ReconcileSessions", "payload" => {})

    assert_equal limit, forge.status_calls.length,
                 "a backlog must cost many cheap ticks, not one long tick"

    engine.apply("type" => "ReconcileSessions", "payload" => {})

    assert_equal limit * 2, forge.status_calls.length, "the next tick must pick up where the last one stopped"
    assert_equal forge.status_calls.uniq, forge.status_calls, "a refreshed record must not be looked up again immediately"
  end

  def test_a_raising_lookup_does_not_starve_the_records_behind_it
    issues = (1..2).map do |index|
      issue_with_pull_request(id: "P1-I#{index}", project_id: "P1", url: "https://github.com/acme/app/pull/#{index}")
    end
    write_state(state_fixture(projects: [project_record(id: "P1", status: "working")], issues: issues))
    forge = Class.new do
      attr_reader :status_calls

      def initialize
        @status_calls = []
      end

      def pull_request_status(url)
        @status_calls << url.to_s
        raise "forge exploded for #{url}" if url.to_s.end_with?("/1")

        { "provider" => "github", "url" => url.to_s, "state" => "merged", "raw_state" => "MERGED" }
      end

      def pull_request_urls_for_branch(repository:, branch:)
        []
      end
    end.new

    result = build_engine(forge_client: forge).apply("type" => "ReconcileSessions", "payload" => {})
    state = read_state

    assert_equal "accepted", result.fetch("status")
    assert_equal 2, forge.status_calls.length, "one bad URL must not abort the batch"
    assert_equal "merged", issue_by_id(state, "P1-I2").fetch("delivery_pull_requests").first.fetch("state")
    broken = issue_by_id(state, "P1-I1").fetch("delivery_pull_requests").first
    assert_equal "open", broken.fetch("state"), "a raising lookup must not erase the known state"
    assert_equal "unavailable", broken.fetch("availability")
    refute_nil broken.fetch("last_checked_at"), "the failure must still be stamped so the URL stops hogging a batch slot"
  end

  def test_one_tick_stops_at_the_shared_forge_budget
    issues = (1..3).map do |index|
      issue_with_pull_request(id: "P1-I#{index}", project_id: "P1", url: "https://github.com/acme/app/pull/#{index}")
    end
    write_state(state_fixture(projects: [project_record(id: "P1", status: "working")], issues: issues))
    forge = SlowStatusForgeClient.new(delay: 0.15)
    engine = build_engine(forge_client: forge, delivery_pull_request_refresh_budget: 0.2)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = engine.apply("type" => "ReconcileSessions", "payload" => {})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "accepted", result.fetch("status")
    assert_operator forge.timeouts.length, :<, 3, "the shared budget must stop the batch early"
    assert_operator elapsed, :<, 1.0, "one tick must not spend a per-URL timeout on every URL"
    assert forge.timeouts.all? { |timeout| timeout&.positive? }, "each lookup must receive the remaining budget"
    assert_operator forge.timeouts.last, :<, forge.timeouts.first, "the budget must shrink across the batch"
  end

  def test_refresh_schedules_are_spread_so_records_do_not_all_fall_due_together
    interval = Meringue::Kernel::Engine::DELIVERY_PULL_REQUEST_REFRESH_INTERVAL_SECONDS
    spread = Meringue::Kernel::Engine::DELIVERY_PULL_REQUEST_REFRESH_SPREAD_SECONDS
    count = 12
    # Every record refreshed in one burst is stamped with the same `last_checked_at`, which is
    # exactly the state a fixed interval turns into one synchronized burst every interval.
    checked_at = (Time.now.utc - (interval + 10)).iso8601
    issues = (1..count).map do |index|
      issue = issue_with_pull_request(id: "P1-I#{index}", project_id: "P1", url: "https://github.com/acme/app/pull/#{index}")
      issue.fetch("delivery_pull_requests").each { |record| record["last_checked_at"] = checked_at }
      issue["delivery_pull_request"]["last_checked_at"] = checked_at
      issue
    end
    write_state(state_fixture(projects: [project_record(id: "P1", status: "working")], issues: issues))
    engine = build_engine

    # The scheduling decision itself, before the per-tick batch limit truncates it.
    just_past_interval = engine.send(:due_delivery_pull_request_urls)

    assert_operator just_past_interval.length, :<, count,
                    "a fixed interval re-synchronizes the whole herd onto one tick"

    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: issues.each do |issue|
          stale = (Time.now.utc - (interval + spread + 10)).iso8601
          issue.fetch("delivery_pull_requests").each { |record| record["last_checked_at"] = stale }
          issue["delivery_pull_request"]["last_checked_at"] = stale
        end
      )
    )

    assert_equal count, build_engine.send(:due_delivery_pull_request_urls).length,
                 "the spread must delay a refresh, never cancel one"
  end
end
