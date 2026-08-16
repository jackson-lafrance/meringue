# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiRecencyTimestampsTest < Minitest::Test
  include TUISupport

  Timestamps = Meringue::TUI::Timestamps

  def test_today_uses_local_hour_and_minute
    now = Time.new(2026, 8, 16, 14, 30, 0, "-04:00")

    assert_equal "[14:28]", Timestamps.display("2026-08-16T18:28:00Z", now: now)
  end

  def test_previous_dates_in_the_current_monday_based_week_use_lowercase_weekday
    now = Time.new(2026, 8, 16, 14, 30, 0, "-04:00") # Sunday

    assert_equal "[sat 19:32]", Timestamps.display("2026-08-15T19:32:00-04:00", now: now)
    assert_equal "[wed 14:28]", Timestamps.display("2026-08-12T14:28:00-04:00", now: now)
    assert_equal "[mon 09:05]", Timestamps.display("2026-08-10T09:05:00-04:00", now: now)
  end

  def test_sunday_and_monday_are_the_week_boundary
    sunday = Time.new(2026, 8, 16, 14, 30, 0, "-04:00")
    monday = Time.new(2026, 8, 17, 14, 30, 0, "-04:00")

    assert_equal "[mon 09:05]", Timestamps.display("2026-08-10T09:05:00-04:00", now: sunday)
    assert_equal "[09/08 19:32]", Timestamps.display("2026-08-09T19:32:00-04:00", now: sunday)
    assert_equal "[16/08 19:32]", Timestamps.display("2026-08-16T19:32:00-04:00", now: monday)
    assert_equal "[09/08 19:32]", Timestamps.display("2026-08-09T19:32:00-04:00", now: monday)
  end

  def test_older_dates_keep_day_month_and_time_across_month_and_year_boundaries
    august = Time.new(2026, 8, 16, 14, 30, 0, "-04:00")
    january = Time.new(2027, 1, 4, 14, 30, 0, "-05:00") # Monday

    assert_equal "[31/07 19:32]", Timestamps.display("2026-07-31T19:32:00-04:00", now: august)
    assert_equal "[31/12 19:32]", Timestamps.display("2026-12-31T19:32:00-05:00", now: january)
  end

  def test_aware_and_epoch_values_are_converted_to_the_users_local_timezone
    with_env("TZ" => "Etc/GMT+6") do
      now = Time.utc(2026, 1, 15, 1, 0, 0)
      instant = Time.utc(2026, 1, 15, 0, 30, 0)

      assert_equal "[18:30]", Timestamps.display("2026-01-15T00:30:00Z", now: now)
      assert_equal "[18:30]", Timestamps.display(instant.to_f * 1000, now: now)
    end
  end

  def test_explicit_machine_formatting_remains_available
    value = "2026-08-16T18:28:00Z"

    assert_equal "2026-08-16", Timestamps.format(value, "%Y-%m-%d")
  end
end
