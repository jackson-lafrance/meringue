# frozen_string_literal: true

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

      module_function

      def parse(value)
        return value.getlocal if value.is_a?(Time)

        text = value.to_s.strip
        return nil if text.empty?

        begin
          Time.iso8601(text).getlocal
        rescue ArgumentError, TypeError
          begin
            Time.parse(text).getlocal
          rescue ArgumentError, TypeError
            nil
          end
        end
      end

      def format(value, format)
        parse(value)&.strftime(format)
      end

      def sort_key(value)
        parse(value)&.to_f || UNKNOWN_SORT_KEY
      end
    end
  end
end
