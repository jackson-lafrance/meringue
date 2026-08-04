# frozen_string_literal: true

require "fileutils"
require "monitor"

module Meringue
  module State
    # Cross-process advisory lock for Meringue state read-modify-write sections.
    #
    # The state file is a shared single-writer resource: every kernel mutation is
    # a load -> mutate -> save cycle, and `Store#save` publishes a whole snapshot
    # with an atomic rename. That keeps readers safe, but it does not stop two
    # Meringue instances from interleaving their cycles and losing each other's
    # updates. A lost update is not just a stale field: it hides the head command
    # journal and the worker spawn reservation that make command application
    # exactly-once, which is how one logical command ends up applied twice.
    #
    # The lock is intentionally advisory and bounded. If it cannot be acquired
    # within the timeout, the critical section still runs so the TUI can never
    # hang behind another instance; the skipped acquisition is counted so
    # reconciliation and diagnostics can report contention.
    class FileLock
      DEFAULT_TIMEOUT = 5.0
      POLL_INTERVAL = 0.01

      def self.for_store(store, timeout: DEFAULT_TIMEOUT)
        return store.file_lock if store.respond_to?(:file_lock) && store.file_lock

        for_state_path(store.respond_to?(:path) ? store.path : nil, timeout: timeout)
      end

      def self.for_state_path(path, timeout: DEFAULT_TIMEOUT)
        return NullLock.new if path.nil? || path.to_s.strip.empty?

        new(path: "#{path}.lock", timeout: timeout)
      end

      attr_reader :path, :timeout

      def initialize(path:, timeout: DEFAULT_TIMEOUT)
        @path = File.expand_path(path.to_s)
        @timeout = Float(timeout)
        @monitor = Monitor.new
        @depth = 0
        @file = nil
        @timeout_count = 0
      end

      # Reentrant: nested kernel sections on the same thread share one lock hold.
      def synchronize
        @monitor.synchronize do
          acquire! if @depth.zero?
          @depth += 1
          begin
            yield
          ensure
            @depth -= 1
            release! if @depth.zero?
          end
        end
      end

      def held?
        @monitor.synchronize { @depth.positive? }
      end

      # Number of times the lock could not be acquired before its timeout.
      def timeout_count
        @monitor.synchronize { @timeout_count }
      end

      private

      def acquire!
        @file = open_lock_file
        return false unless @file

        deadline = monotonic_time + [timeout, 0.0].max
        loop do
          return true if @file.flock(File::LOCK_EX | File::LOCK_NB)

          if monotonic_time >= deadline
            @timeout_count += 1
            return false
          end

          sleep POLL_INTERVAL
        end
      rescue SystemCallError, IOError
        @timeout_count += 1
        false
      end

      def release!
        return false unless @file

        @file.flock(File::LOCK_UN)
        true
      rescue SystemCallError, IOError
        false
      ensure
        begin
          @file.close unless @file.closed?
        rescue SystemCallError, IOError
          nil
        end
        @file = nil
      end

      def open_lock_file
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o600)
      rescue SystemCallError, IOError
        nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # Used when no state file backs the store, such as in-memory test runs.
    class NullLock
      def synchronize
        yield
      end

      def held?
        false
      end

      def timeout_count
        0
      end
    end
  end
end
