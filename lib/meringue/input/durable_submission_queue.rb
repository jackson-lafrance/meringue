# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "thread"
require "time"

module Meringue
  module Input
    # A tiny append-only write-ahead log for dashboard submissions. The composer is not cleared
    # until enqueue has fsynced the submitted record. Completion is another fsynced record, so a
    # process exit leaves an unambiguous pending entry for the next Meringue process to replay.
    class DurableSubmissionQueue
      attr_reader :path

      def initialize(state_path:)
        @path = "#{File.expand_path(state_path)}.submissions.jsonl"
        @mutex = Mutex.new
      end

      def enqueue(text:, selected_target: nil)
        record = {
          "event" => "submitted",
          "id" => "input-#{SecureRandom.uuid}",
          "text" => text.to_s,
          "selected_target" => selected_target,
          "submitted_at" => Time.now.utc.iso8601(6)
        }.compact
        append(record)
        record
      end

      def complete(id)
        append("event" => "completed", "id" => id.to_s, "completed_at" => Time.now.utc.iso8601(6))
      end

      def pending
        submitted = {}
        completed = {}
        records.each do |record|
          id = record["id"].to_s
          next if id.empty?

          case record["event"]
          when "submitted"
            submitted[id] = record
          when "completed"
            completed[id] = true
          end
        end
        submitted.reject { |id, _record| completed[id] }.values.sort_by { |record| record.fetch("submitted_at", "") }
      end

      private

      def append(record)
        @mutex.synchronize do
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
            file.flock(File::LOCK_EX)
            file.write(JSON.generate(record) + "\n")
            file.flush
            file.fsync
          end
        end
        record
      end

      def records
        @mutex.synchronize do
          return [] unless File.exist?(path)

          File.readlines(path, chomp: true).filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
      rescue SystemCallError
        []
      end
    end
  end
end
