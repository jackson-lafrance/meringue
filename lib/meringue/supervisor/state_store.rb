# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "../state/file_lock"

module Meringue
  module Supervisor
    # Durable, cross-process record of the supervisor's per-session state.
    #
    # The transport-ownership lease names the process holding a session's pipes;
    # this store names the supervision lifecycle that lease belongs to. It is
    # what survives a dashboard exit, restart, or upgrade: a fresh supervisor
    # process loads it, sees which sessions were `supervision_lost`, and resumes
    # them without re-prompting turns that are still alive.
    #
    # One record per session, keyed by the harness-agnostic transport key. The
    # store is single-writer across processes: every read-modify-write runs
    # under a `State::FileLock` and publishes a whole snapshot atomically, the
    # same invariant the kernel state store uses for exactly-once command
    # application.
    class StateStore
      DEFAULT_DIRECTORY = File.expand_path(
        ENV.fetch("MERINGUE_SUPERVISOR_STATE_DIR", "~/.meringue/supervisor-state")
      )
      SCHEMA_VERSION = 1
      STATES = %w[active supervision_lost recovered].freeze
      HANDOFF_STATES = %w[none preparing relinquished adopting].freeze

      attr_reader :directory, :path, :lock

      def initialize(directory: DEFAULT_DIRECTORY, path: nil, lock: nil)
        @directory = File.expand_path(directory.to_s)
        @path = File.expand_path(path || File.join(@directory, "supervisor-state.json"))
        @lock = lock || State::FileLock.new(path: "#{@path}.lock")
        @mutex = Mutex.new
        FileUtils.mkdir_p(@directory) unless @directory.empty?
      end

      # Load the whole snapshot. Returns {} when no state file exists.
      def load
        return {} unless File.file?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, IOError, SystemCallError
        {}
      end

      # All per-session records (the `sessions` map values).
      def all
        sessions = load.fetch("sessions", {})
        sessions.is_a?(Hash) ? sessions : {}
      end

      # One record by transport key, or nil.
      def read(key)
        all[key.to_s]
      end

      # Replace one record. Writes the whole snapshot atomically.
      def save(record)
        key = record.fetch("transport_key").to_s
        synchronized do |state|
          sessions = state.fetch("sessions", {})
          sessions = {} unless sessions.is_a?(Hash)
          sessions[key] = record
          state["sessions"] = sessions
          publish!(state)
        end
        record
      end

      # Atomic read-modify-write for one record. The block receives the current
      # record (or a fresh blank one) and returns the new record to persist.
      def update(key)
        synchronized do |state|
          sessions = state.fetch("sessions", {})
          sessions = {} unless sessions.is_a?(Hash)
          current = sessions[key.to_s] || blank_record(key.to_s)
          updated = yield current
          sessions[key.to_s] = updated
          state["sessions"] = sessions
          publish!(state)
          updated
        end
      end

      def delete(key)
        synchronized do |state|
          sessions = state.fetch("sessions", {})
          sessions = {} unless sessions.is_a?(Hash)
          sessions.delete(key.to_s)
          state["sessions"] = sessions
          publish!(state)
        end
        true
      end

      def blank_record(key)
        {
          "transport_key" => key.to_s,
          "session_id" => nil,
          "harness" => nil,
          "state" => "active",
          "handoff_state" => "none",
          "owner_pid" => nil,
          "owner_started_at" => nil,
          "harness_pid" => nil,
          "harness_started_at" => nil,
          "episode_id" => nil,
          "lost_at" => nil,
          "recovered_at" => nil,
          "downtime_seconds" => 0.0,
          "prompted_on_recovery" => false,
          "updated_at" => timestamp
        }
      end

      private

      def synchronized
        @mutex.synchronize do
          lock.synchronize do
            state = normalized(load)
            result = yield state
            result
          end
        end
      end

      def normalized(state)
        state["schema_version"] ||= SCHEMA_VERSION
        state["sessions"] = {} unless state["sessions"].is_a?(Hash)
        state
      end

      def publish!(state)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.write(tmp, JSON.generate(state))
        File.rename(tmp, path)
      rescue IOError, SystemCallError
        FileUtils.rm_f(tmp) if tmp
        raise
      end

      def timestamp
        Time.now.utc.iso8601(6)
      end
    end
  end
end
