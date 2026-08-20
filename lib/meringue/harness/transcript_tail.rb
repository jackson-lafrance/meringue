# frozen_string_literal: true

require "json"
require "thread"

module Meringue
  module Harness
    # Incremental reader for a harness's own durable JSONL transcript.
    #
    # An interactive agent CLI draws a TUI for humans and writes a structured transcript for
    # everything else. That transcript, not the screen, is what Meringue reads to decide whether a
    # turn is streaming, what the agent said, and whether the turn failed. Reading it this way also
    # means a session survives a Meringue restart: the file is still there, so the same decisions
    # can be made about a session this process did not start.
    #
    # Only bytes appended since the previous poll are parsed. A worker can run for an hour and
    # produce a multi-megabyte transcript; re-parsing all of it on every reconciliation tick would
    # make the poll cost grow with session age.
    class TranscriptTail
      # Bounds one poll, not the file. A very chatty turn still gets fully consumed, just across
      # several polls, which keeps any single reconciliation tick cheap.
      DEFAULT_MAX_POLL_BYTES = 4 * 1024 * 1024
      # A line longer than this is assumed to be a partial write that will never complete, rather
      # than an unbounded buffer to keep growing.
      MAX_PARTIAL_LINE_BYTES = 8 * 1024 * 1024

      attr_reader :path

      def initialize(path: nil, max_poll_bytes: DEFAULT_MAX_POLL_BYTES)
        @path = path && File.expand_path(path.to_s)
        @max_poll_bytes = [max_poll_bytes.to_i, 64 * 1024].max
        @offset = 0
        @partial = +"".b
        @inode = nil
        @mutex = Mutex.new
      end

      # Points the tail at a different file, which happens when a session is forked or replaced.
      # The cursor restarts because the new file's history is not a continuation of the old one.
      def rebind(path)
        expanded = path && File.expand_path(path.to_s)
        @mutex.synchronize do
          return false if expanded == @path

          @path = expanded
          @offset = 0
          @partial = +"".b
          @inode = nil
          true
        end
      end

      def exists?
        current = @mutex.synchronize { @path }
        !current.nil? && File.file?(current)
      end

      # New records only. Returns [] when the transcript has not appeared yet, which is normal:
      # some agent CLIs create the file lazily on the first prompt rather than at startup.
      def poll
        @mutex.synchronize do
          current = @path
          return [] unless current && File.file?(current)

          reset_if_replaced_unlocked(current)
          read_new_records_unlocked(current)
        end
      end

      # Everything currently on disk, for a caller that needs whole history rather than an update
      # (a transcript pane opening on an existing session). Independent of the poll cursor.
      def all_records(limit: nil)
        current = @mutex.synchronize { @path }
        return [] unless current && File.file?(current)

        records = []
        File.foreach(current) do |line|
          parsed = parse_line(line)
          next unless parsed

          records << parsed
          records.shift while limit && records.length > limit.to_i
        end
        records
      rescue SystemCallError
        []
      end

      # Drops the cursor to the current end of file without returning anything, so a caller that
      # has just adopted an existing session does not replay its whole history as new events.
      def seek_to_end
        @mutex.synchronize do
          current = @path
          next 0 unless current && File.file?(current)

          @offset = File.size(current)
          @partial = +"".b
          @inode = file_identity(current)
          @offset
        end
      rescue SystemCallError
        0
      end

      def cursor
        @mutex.synchronize { @offset }
      end

      private

      # A truncated or replaced file means the cursor no longer refers to the same bytes. Keeping
      # it would silently skip the new file's opening records.
      def reset_if_replaced_unlocked(current)
        identity = file_identity(current)
        size = File.size(current)
        if @inode && identity != @inode
          @offset = 0
          @partial = +"".b
        elsif size < @offset
          @offset = 0
          @partial = +"".b
        end
        @inode = identity
      end

      def read_new_records_unlocked(current)
        size = File.size(current)
        return [] if size <= @offset

        limit = [size - @offset, @max_poll_bytes].min
        chunk = File.open(current, "rb") do |file|
          file.seek(@offset)
          file.read(limit).to_s
        end
        return [] if chunk.empty?

        @offset += chunk.bytesize
        buffer = @partial + chunk.b
        @partial = +"".b
        records = []
        buffer.each_line do |line|
          if line.end_with?("\n")
            parsed = parse_line(line)
            records << parsed if parsed
          else
            @partial = line.bytesize > MAX_PARTIAL_LINE_BYTES ? +"".b : line
          end
        end
        records
      rescue SystemCallError
        []
      end

      def parse_line(line)
        text = line.to_s.strip
        return nil if text.empty?

        parsed = JSON.parse(text.force_encoding("UTF-8").scrub)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def file_identity(current)
        stat = File.stat(current)
        [stat.dev, stat.ino]
      rescue SystemCallError
        nil
      end
    end
  end
end
