# frozen_string_literal: true

module Meringue
  module TUI
    # Large pastes never enter the composer buffer.
    #
    # A paste over the threshold is parked here and the buffer receives a compact
    # Pi-style marker instead ("[paste #1 +3000 lines]"). Everything the TUI does
    # per keystroke — wrapping, cursor math, slash completion, composer height,
    # frame diffing — then runs over ~22 characters instead of a quarter megabyte,
    # and the body is spliced back in exactly once, when the message is submitted.
    #
    # One registry belongs to one composer surface, so the dashboard composer and
    # the focused-workspace composer number and clear their pastes independently.
    class PasteRegistry
      # Pi's own thresholds (packages/tui/src/components/editor.ts): a paste is
      # "large" past 10 lines or 1000 characters. Below that the text is short
      # enough to read in the composer and cheap enough to wrap every frame.
      LINE_THRESHOLD = 10
      CHARACTER_THRESHOLD = 1_000

      MARKER_PREFIX = "[paste #"
      # Matches the markers this class writes: "[paste #1 +3000 lines]" and
      # "[paste #2 4110 chars]".
      MARKER_PATTERN = /\[paste \#(\d+)(?: (?:\+\d+ lines|\d+ chars))?\]/.freeze

      def self.marker?(text)
        /\A#{MARKER_PATTERN}\z/.match?(text.to_s)
      end

      # Character ranges of every marker-shaped run in the text, whether or not a
      # registry still holds its content. Rendering uses this to tint a marker as
      # one chunk without knowing which surface owns it.
      def self.marker_ranges_in(text)
        value = text.to_s
        return [] unless value.include?(MARKER_PREFIX)

        ranges = []
        offset = 0
        while (match = MARKER_PATTERN.match(value, offset))
          ranges << (match.begin(0)...match.end(0))
          offset = match.end(0)
        end
        ranges
      end

      # A restored draft can still contain markers whose content died with the
      # previous process. Expanding is impossible, so drop them rather than let
      # the user unknowingly send a meaningless token to a worker.
      def self.strip_markers(text)
        value = text.to_s
        return value unless value.include?(MARKER_PREFIX)

        value.gsub(MARKER_PATTERN, "")
      end

      def initialize(line_threshold: LINE_THRESHOLD, character_threshold: CHARACTER_THRESHOLD)
        @line_threshold = line_threshold
        @character_threshold = character_threshold
        @entries = {}
        @counter = 0
      end

      def empty?
        @entries.empty?
      end

      def size
        @entries.size
      end

      def content(id)
        @entries[id.to_i]
      end

      def large?(text)
        value = text.to_s
        return false if value.empty?

        value.length > @character_threshold || line_count(value) > @line_threshold
      end

      # Returns what the buffer should actually receive: the text itself when it
      # is small, or a marker standing in for it when it is not.
      def collapse(text)
        value = text.to_s
        return value unless large?(value)

        @counter += 1
        @entries[@counter] = value
        marker_for(@counter, value)
      end

      # Splices every live marker back into the text. Unknown markers are left
      # alone: another surface may own them, and inventing content is worse than
      # echoing what the user can see.
      def expand(buffer)
        value = buffer.to_s
        return value if @entries.empty?
        return value unless value.include?(MARKER_PREFIX)

        value.gsub(MARKER_PATTERN) do
          match = Regexp.last_match
          @entries.fetch(match[1].to_i, match[0])
        end
      end

      # Character ranges of the markers this registry can still expand.
      def marker_ranges(buffer)
        return [] if @entries.empty?

        value = buffer.to_s
        self.class.marker_ranges_in(value).select do |range|
          id = MARKER_PATTERN.match(value[range])&.[](1).to_i
          @entries.key?(id)
        end
      end

      # The marker range strictly containing this index, if any. Boundaries are
      # excluded so a cursor parked either side of a marker is "outside" it.
      def enclosing_range(buffer, index)
        marker_ranges(buffer).find { |range| index > range.first && index < range.last }
      end

      # A marker is one unit for cursor movement: a step that would land inside
      # one continues to its far edge in the direction of travel.
      def snap_cursor(buffer, from, to)
        return to if from == to

        range = enclosing_range(buffer, to)
        return to unless range

        to > from ? range.last : range.first
      end

      # Deletions never cut a marker in half: a range that touches part of one
      # swallows the whole thing, so the buffer can never hold a fragment that no
      # longer expands.
      def expand_range(buffer, range)
        return range if range.first >= range.last

        touched = marker_ranges(buffer).select { |marker| marker.first < range.last && marker.last > range.first }
        return range if touched.empty?

        start_index = [range.first, touched.map(&:first).min].min
        finish_index = [range.last, touched.map(&:last).max].max
        (start_index...finish_index)
      end

      # Forget content whose marker the user deleted, so a long editing session
      # never holds every paste it has ever seen.
      def sync!(buffer)
        return self if @entries.empty?

        value = buffer.to_s
        live = value.include?(MARKER_PREFIX) ? value.scan(MARKER_PATTERN).map { |captures| captures.first.to_i } : []
        @entries.keep_if { |id, _| live.include?(id) }
        @counter = 0 if @entries.empty?
        self
      end

      def clear!
        @entries.clear
        @counter = 0
        self
      end

      private

      def marker_for(id, text)
        lines = line_count(text)
        return "#{MARKER_PREFIX}#{id} +#{lines} lines]" if lines > @line_threshold

        "#{MARKER_PREFIX}#{id} #{text.length} chars]"
      end

      def line_count(text)
        text.split("\n").length
      end
    end
  end
end
