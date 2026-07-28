# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Meringue
  module Harness
    # Cross-process record of which Meringue instance owns a harness session's
    # RPC transport.
    #
    # A harness process only accepts commands from the process holding its pipes,
    # so two Meringue instances must never talk to one session at once. This is
    # the coordination point that keeps a single writer: a per-session advisory
    # file lock plus a small durable record of the owning instance. When the
    # previous owner is gone (or has settled), another instance can take the
    # session over deterministically instead of failing forever.
    class TransportOwnership
      DEFAULT_DIRECTORY = File.expand_path(
        ENV.fetch("MERINGUE_TRANSPORT_LOCK_DIR", "~/.meringue/transport-locks")
      )
      DEFAULT_LOCK_TIMEOUT = 10.0
      LOCK_POLL_INTERVAL = 0.05

      class LockTimeout < StandardError; end

      attr_reader :directory, :lock_timeout

      def initialize(directory: DEFAULT_DIRECTORY, lock_timeout: DEFAULT_LOCK_TIMEOUT, owner_pid: Process.pid)
        @directory = File.expand_path(directory.to_s)
        @lock_timeout = Float(lock_timeout)
        @owner_pid = Integer(owner_pid)
        @mutex = Mutex.new
      end

      attr_reader :owner_pid

      # Serializes transport takeover across Meringue instances. The block
      # receives a Lease for reading and updating the durable record.
      def with_lease(key, timeout: lock_timeout)
        path = path_for(key)
        FileUtils.mkdir_p(File.dirname(path))
        # The in-process mutex keeps threads of one instance from fighting over
        # the same advisory lock, which flock does not do per file description.
        @mutex.synchronize do
          File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
            acquire_lock!(file, key, timeout)
            lease = Lease.new(file: file, key: key.to_s, owner_pid: owner_pid, record: read_record(file))
            begin
              yield lease
            ensure
              lease.flush!
            end
          end
        end
      end

      # Best-effort read used for diagnostics and messaging. Never blocks.
      def record_for(key)
        path = path_for(key)
        return {} unless File.file?(path)

        File.open(path, File::RDONLY) { |file| read_record(file) }
      rescue SystemCallError, IOError
        {}
      end

      def claim(key, pid:, session_id: nil, note: nil)
        with_lease(key) do |lease|
          lease.claim!(pid: pid, session_id: session_id, note: note)
        end
      rescue LockTimeout
        false
      end

      def release(key, pid: nil)
        with_lease(key) do |lease|
          lease.release!(pid: pid)
        end
      rescue LockTimeout
        false
      end

      def path_for(key)
        File.join(directory, "#{sanitize(key)}.lock")
      end

      private

      def acquire_lock!(file, key, timeout)
        deadline = monotonic_time + [Float(timeout), 0.0].max
        loop do
          return true if file.flock(File::LOCK_EX | File::LOCK_NB)
          raise LockTimeout, "Timed out waiting for the #{key} harness transport lock" if monotonic_time >= deadline

          sleep LOCK_POLL_INTERVAL
        end
      end

      def read_record(file)
        file.rewind
        content = file.read.to_s
        return {} if content.strip.empty?

        parsed = JSON.parse(content)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, IOError, SystemCallError
        {}
      end

      def sanitize(key)
        text = key.to_s.strip
        text = "unknown" if text.empty?
        text.gsub(/[^A-Za-z0-9._-]+/, "-")[0, 120]
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Mutable view of one session's ownership record while its lock is held.
      class Lease
        def initialize(file:, key:, owner_pid:, record:)
          @file = file
          @key = key
          @owner_pid = owner_pid
          @record = record
          @dirty = false
        end

        attr_reader :key, :owner_pid, :record

        def harness_pid
          value = record["pid"]
          value.nil? ? nil : Integer(value)
        rescue ArgumentError, TypeError
          nil
        end

        def recorded_owner_pid
          value = record["owner_pid"]
          value.nil? ? nil : Integer(value)
        rescue ArgumentError, TypeError
          nil
        end

        def owned_by_this_instance?
          recorded_owner_pid == owner_pid
        end

        def claim!(pid:, session_id: nil, note: nil)
          @record = {
            "session_id" => session_id.nil? ? record["session_id"] : session_id.to_s,
            "pid" => pid.nil? ? nil : Integer(pid),
            "owner_pid" => owner_pid,
            "note" => note,
            "updated_at" => Time.now.utc.iso8601
          }.compact
          @dirty = true
          true
        end

        def release!(pid: nil)
          return false if pid && harness_pid && Integer(pid) != harness_pid

          @record = {
            "session_id" => record["session_id"],
            "released_by" => owner_pid,
            "updated_at" => Time.now.utc.iso8601
          }.compact
          @dirty = true
          true
        end

        def flush!
          return false unless @dirty

          @file.rewind
          @file.truncate(0)
          @file.write(JSON.generate(@record))
          @file.flush
          @dirty = false
          true
        rescue IOError, SystemCallError
          false
        end
      end
    end
  end
end
