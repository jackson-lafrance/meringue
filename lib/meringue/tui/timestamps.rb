# frozen_string_literal: true

require "date"
require "time"

module Meringue
  module TUI
    # Timestamps reach the TUI from several writers. The kernel prefers local
    # ISO8601, while harness clients and the state layer store UTC ISO8601.
    # Rendering must always show the user's local wall clock, and ordering must
    # compare absolute instants instead of raw strings so mixed offsets sort
    # correctly.
    module Timestamps
      # Sorts unparseable or missing timestamps last, matching the previous
      # far-future sentinel behaviour.
      UNKNOWN_SORT_KEY = Float::INFINITY
      WEEKDAY_NAMES = %w[mon tue wed thu fri sat sun].freeze

      module_function

      # Normalize every timestamp to the user's local wall clock. Numeric values
      # are accepted for harness transcript epochs (milliseconds when they look
      # like Unix milliseconds, seconds otherwise); persisted timestamps remain
      # strings and are never rewritten by this presentation helper.
      def parse(value)
        if value.is_a?(Numeric)
          seconds = value.to_f
          seconds /= 1_000 if seconds.abs > 10_000_000_000
          return Time.at(seconds).getlocal
        end
        return value.getlocal if value.is_a?(Time)

        text = value.to_s.strip
        return nil if text.empty?

        begin
          Time.iso8601(text).getlocal
        rescue ArgumentError, TypeError
          begin
            Time.parse(text).getlocal
          rescue ArgumentError, RangeError, TypeError
            nil
          end
        end
      rescue ArgumentError, RangeError, TypeError
        nil
      end

      # Keep explicit strftime formatting available for intentional non-display
      # formats and existing callers. With no pattern, format the value using
      # the recency-aware display rules below.
      def format(value, pattern = nil, now: Time.now)
        return format_recency(value, now: now) if pattern.nil?

        parse(value)&.strftime(pattern)
      end

      # Return the compact timestamp body without brackets:
      #   today       HH:MM
      #   this week   mon HH:MM
      #   older       DD/MM HH:MM
      # Calendar comparisons use local dates, not the source timestamp's offset.
      def format_recency(value, now: Time.now)
        timestamp = parse(value)
        reference = parse(now) || Time.now.getlocal
        return nil unless timestamp

        timestamp_date = timestamp.to_date
        reference_date = reference.to_date
        if timestamp_date == reference_date
          timestamp.strftime("%H:%M")
        elsif timestamp_date >= week_start(reference_date) && timestamp_date < reference_date
          "#{WEEKDAY_NAMES.fetch(timestamp_date.cwday - 1)} #{timestamp.strftime("%H:%M")}"
        else
          timestamp.strftime("%d/%m %H:%M")
        end
      end

      # The standard user-facing form for every timestamp surface.
      def display(value, now: Time.now)
        formatted = format_recency(value, now: now)
        formatted && "[#{formatted}]"
      end

      # Presentation caches need to be invalidated when midnight changes a
      # timestamp's category, even though the underlying state is unchanged.
      def context_key(now: Time.now)
        (parse(now) || Time.now.getlocal).to_date
      end

      # An elapsed span in the shortest form that still reads unambiguously, for a row chip that
      # has to share its line with a title: `45s`, `12m`, `3h`, `2h 5m`. Deliberately coarse
      # above an hour - by then the exact minute is not what the reader is deciding on.
      def compact_duration(seconds)
        total = seconds.to_i
        return nil if total.negative?
        return "#{total}s" if total < 60

        minutes = total / 60
        return "#{minutes}m" if minutes < 60

        hours = minutes / 60
        remainder = minutes % 60
        remainder.zero? ? "#{hours}h" : "#{hours}h #{remainder}m"
      end

      # Whole elapsed minutes, for a presentation cache key. A chip that reads `12m` must
      # re-render when it becomes `13m` and at no other time, so the cache is keyed on the
      # number the chip shows rather than on the clock.
      def elapsed_minutes(value, now: Time.now)
        from = parse(value)
        return nil unless from

        current = parse(now) || Time.now.getlocal
        elapsed = ((current - from) / 60).floor
        elapsed.negative? ? 0 : elapsed
      end

      def sort_key(value)
        parse(value)&.to_f || UNKNOWN_SORT_KEY
      end

      def week_start(date)
        date - (date.cwday - 1)
      end
    end
  end
end
