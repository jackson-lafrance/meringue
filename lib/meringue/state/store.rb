# frozen_string_literal: true

require "fileutils"
require "json"
require "thread"
require "time"

require_relative "compactor"
require_relative "file_lock"

module Meringue
  module State
    class Store
      DEFAULT_PATH = File.expand_path("~/.meringue/state.json")

      def self.default_path
        File.expand_path(ENV.fetch("MERINGUE_STATE_PATH", DEFAULT_PATH))
      end

      attr_reader :path, :file_lock

      # Diagnostic hook for the read-path tests: how many times `load` had to read and
      # normalize the file instead of reusing the cached snapshot.
      attr_reader :snapshot_misses

      # +file_lock+ is shared with the kernel so a load -> mutate -> save cycle in
      # this process cannot be interleaved with one in another Meringue instance.
      # It is always acquired outside the in-process mutex to keep a single lock
      # ordering everywhere.
      def initialize(path: self.class.default_path, file_lock: nil)
        @path = File.expand_path(path)
        @file_lock = file_lock || FileLock.for_state_path(@path)
        @mutex = Mutex.new
        @snapshot_mutex = Mutex.new
        @snapshot_fingerprint = nil
        @snapshot_json = nil
        @readonly_snapshot = nil
        @snapshot_misses = 0
      end

      # Saves publish a complete snapshot with an atomic rename, so readers can
      # safely observe either the previous or next snapshot without waiting for
      # serialization and disk I/O to finish. Keeping TUI reads off the writer
      # mutex is important because worker provisioning checkpoints state several
      # times while a completed head result is being applied.
      def load
        transaction = coalesced_save_transaction
        return deep_copy(transaction.fetch(:state)) if transaction && transaction[:state]

        load_unlocked
      end

      # Presentation code only reads orchestration state and overlays transient UI
      # fields with Hash#merge. Returning the frozen cached object avoids parsing a
      # multi-megabyte unchanged snapshot on every dashboard refresh while making
      # accidental mutation fail immediately. Kernel callers continue to use #load
      # and receive independent mutable copies.
      def load_readonly
        transaction = coalesced_save_transaction
        return deep_freeze(deep_copy(transaction.fetch(:state))) if transaction && transaction[:state]
        return Models.empty_state.freeze unless File.exist?(path)

        fingerprint = file_fingerprint
        if fingerprint
          cached = @snapshot_mutex.synchronize do
            @readonly_snapshot if @snapshot_fingerprint == fingerprint
          end
          return cached if cached
        end

        load_unlocked
        @snapshot_mutex.synchronize { @readonly_snapshot } || deep_freeze(load_unlocked)
      end

      # Coalesce a related sequence of whole-state saves on the current thread. Callers still see
      # each staged snapshot through +load+, but only the final snapshot is atomically published.
      # The kernel uses this while applying one reconciliation poll batch under its state lock.
      def coalesce_saves
        transactions = (Thread.current[:meringue_store_save_transactions] ||= {})
        existing = transactions[object_id]
        return yield if existing

        transaction = { state: nil, preserve_log_buffer: true }
        transactions[object_id] = transaction
        result = yield
        transactions.delete(object_id)
        if transaction[:state]
          exclusive do
            save_unlocked(
              transaction.fetch(:state),
              preserve_log_buffer: transaction.fetch(:preserve_log_buffer)
            )
          end
        end
        result
      ensure
        transactions&.delete(object_id) unless existing
        Thread.current[:meringue_store_save_transactions] = nil if transactions&.empty?
      end

      def compact!
        exclusive do
          return false unless File.exist?(path)

          state = JSON.parse(File.read(path))
          previous_log_count = Array(state["logs"]).length
          Models.ensure_state_shape!(state)
          changed = state.fetch("logs").length != previous_log_count
          changed = Compactor.compact!(state) || changed
          save_unlocked(state, preserve_log_buffer: false) if changed
          changed
        end
      end

      def save(state, preserve_log_buffer: true, preserve_conversation: nil)
        preserve_log_buffer = preserve_conversation unless preserve_conversation.nil?
        if (transaction = coalesced_save_transaction)
          transaction[:state] = deep_copy(state)
          transaction[:preserve_log_buffer] &&= preserve_log_buffer
          return state
        end

        exclusive do
          save_unlocked(state, preserve_log_buffer: preserve_log_buffer)
        end
      end

      # Persist only non-orchestration agent-workspace presentation state against the latest
      # state on disk. This avoids a stale TUI snapshot overwriting kernel reconciliation,
      # delivery-PR refreshes, or pruning performed on another thread.
      def save_agent_workspace(workspace)
        exclusive do
          state = load_unlocked
          Models.normalize_agent_workspace_state!(state, workspace: deep_copy(workspace || {}))
          state.fetch("ui").fetch("agent_workspace")["updated_at"] = Time.now.utc.iso8601
          state.fetch("metadata")["updated_at"] = Time.now.utc.iso8601
          save_unlocked(state, preserve_log_buffer: false)
          deep_copy(state.fetch("ui").fetch("agent_workspace"))
        end
      end

      def save_log_buffer(messages:, next_message_id: nil)
        exclusive do
          state = load_unlocked
          state["conversation"] = {
            "messages" => Array(messages).map { |message| deep_copy(message) },
            "next_message_id" => next_message_id ? next_message_id.to_i : 0
          }
          state["conversation"]["next_message_id"] = Models.max_log_message_id(state) if state["conversation"]["next_message_id"].zero?
          state.fetch("metadata")["updated_at"] = Time.now.utc.iso8601
          save_unlocked(state, preserve_log_buffer: false)
        end
      end
      alias save_conversation save_log_buffer

      private

      def coalesced_save_transaction
        Thread.current[:meringue_store_save_transactions]&.fetch(object_id, nil)
      end

      def exclusive(&block)
        file_lock.synchronize { @mutex.synchronize(&block) }
      end

      # The TUI reloads state on every rendered frame, and the kernel reloads it for
      # every command, so this is the hottest read in the app. Normalizing and deep
      # string-compacting a multi-megabyte snapshot that has not changed since the
      # last read is pure waste: `save_unlocked` already normalized and compacted
      # whatever is on disk. Reuse the normalized snapshot until the file identity
      # changes, and pay only for a parse to hand back an unshared, mutable copy.
      def load_unlocked
        return Models.empty_state unless File.exist?(path)

        cached = cached_snapshot_json
        return JSON.parse(cached) if cached

        read_state_unlocked
      end

      def read_state_unlocked
        @snapshot_mutex.synchronize { @snapshot_misses += 1 }
        fingerprint = file_fingerprint
        state = JSON.parse(File.read(path))
        # Normalize first so legacy oversized histories are pruned before the
        # deep string compactor visits entries that will not be retained.
        Models.ensure_state_shape!(state)
        Compactor.compact!(state)
        remember_snapshot(fingerprint, state)
        state
      end

      # Saves publish through an atomic rename of a fresh temp file, so a new
      # snapshot always has a different inode. Size and nanosecond mtime are kept
      # as well, so a writer that replaces the file in place still invalidates.
      # Reading the fingerprint *before* the file contents is what makes this safe:
      # a write that lands during the read produces a fingerprint mismatch on the
      # next call rather than a cached stale snapshot.
      def file_fingerprint
        stat = File.stat(path)
        [stat.dev, stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec]
      rescue SystemCallError
        nil
      end

      def cached_snapshot_json
        fingerprint = file_fingerprint
        return nil unless fingerprint

        @snapshot_mutex.synchronize do
          @snapshot_fingerprint == fingerprint ? @snapshot_json : nil
        end
      end

      def remember_snapshot(fingerprint, state)
        return unless fingerprint
        # The file changed while it was being read, so the parsed snapshot cannot be
        # attributed to either version. Cache nothing and re-read next time.
        return unless fingerprint == file_fingerprint

        json = JSON.generate(state)
        readonly_snapshot = deep_freeze(JSON.parse(json))
        @snapshot_mutex.synchronize do
          @snapshot_fingerprint = fingerprint
          @snapshot_json = json
          @readonly_snapshot = readonly_snapshot
        end
      end

      def save_unlocked(state, preserve_log_buffer: true)
        FileUtils.mkdir_p(File.dirname(path))
        temp_path = "#{path}.tmp.#{$$}"
        Models.ensure_state_shape!(state)
        Compactor.compact!(state)
        merge_persisted_log_buffer!(state) if preserve_log_buffer

        File.write(temp_path, JSON.pretty_generate(state) + "\n")
        File.rename(temp_path, path)
        # Seed the read cache from the snapshot this process just published, so the
        # next render or command reuses it instead of re-normalizing our own write.
        remember_snapshot(file_fingerprint, state)
        state
      ensure
        File.delete(temp_path) if temp_path && File.exist?(temp_path)
      end

      def merge_persisted_log_buffer!(state)
        return unless File.exist?(path)

        persisted = JSON.parse(File.read(path))
        Models.ensure_state_shape!(persisted)
        state["conversation"] = merge_log_buffer(
          state.fetch("conversation", {}),
          persisted.fetch("conversation", {})
        )
      rescue JSON::ParserError
        nil
      end

      def merge_log_buffer(incoming, persisted)
        incoming_messages = Array(incoming["messages"])
        persisted_messages = Array(persisted["messages"])
        messages_by_id = {}
        incoming_messages.each { |message| messages_by_id[message_id(message)] = message if message_id(message) }
        persisted_messages.each { |message| messages_by_id[message_id(message)] = message if message_id(message) }
        merged_messages = messages_by_id.values.sort_by { |message| message_id(message).to_i }
        {
          "messages" => merged_messages,
          "next_message_id" => [
            integer_value(incoming["next_message_id"]),
            integer_value(persisted["next_message_id"]),
            merged_messages.filter_map { |message| message_id(message)&.to_i }.max.to_i
          ].max
        }
      end

      def message_id(message)
        return nil unless message.is_a?(Hash)

        message["id"] || message[:id]
      end

      def integer_value(value)
        value ? value.to_i : 0
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| key.freeze; deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
