# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "tempfile"
require "time"

module Meringue
  class Config
    # Single-writer, optimistic config transaction. It patches schema-owned
    # settings and optional onboarding lifecycle metadata into the latest parsed
    # document, preserving unknown tables and keys.
    class Store
      LOCK_SUFFIX = ".lock"

      attr_reader :path

      def initialize(path: Config::DEFAULT_PATH)
        @path = File.expand_path(path.to_s)
      end

      def fingerprint
        self.class.fingerprint(path)
      end

      def self.fingerprint(path)
        expanded = File.expand_path(path.to_s)
        return Digest::SHA256.hexdigest("missing\0#{expanded}") unless File.file?(expanded)

        Digest::SHA256.hexdigest("file\0#{File.binread(expanded)}")
      end

      def save(base_fingerprint:, changes:, onboarding_outcome: nil, completed_at: nil)
        outcome = onboarding_outcome.nil? ? nil : onboarding_outcome.to_s
        if outcome && !Config::ONBOARDING_OUTCOMES.include?(outcome)
          raise ValidationError, "setup.outcome" => "must be one of: #{Config::ONBOARDING_OUTCOMES.join(", ")}"
        end

        with_lock do
          current = Config.load(path: path)
          current_fingerprint = fingerprint
          if base_fingerprint.to_s != current_fingerprint
            raise StaleRevisionError,
                  "Configuration changed on disk after Settings opened. Reopen Settings to review the newer file."
          end

          normalized = Schema.validate_changes(changes, config: current)
          data = current.to_file_h
          normalized.each do |id, value|
            definition = Schema.fetch(id)
            set_path!(data, definition.path, serialized_value(definition, value))
            definition.aliases.each { |alias_path| delete_path!(data, alias_path) }
          end
          validate_cross_fields!(data, changed_ids: normalized.keys)
          if outcome
            set_path!(data, %w[onboarding completed_version], Config::ONBOARDING_VERSION)
            set_path!(data, %w[onboarding completed_at], (completed_at || Time.now.utc.iso8601).to_s)
            set_path!(data, %w[onboarding outcome], outcome)
          end
          publish!(data)

          saved = Config.new(data, path: path, loaded: true, file_data: data)
          {
            "config" => saved,
            "changed_ids" => normalized.keys.sort,
            "restart_required" => Schema.restart_required_ids(normalized.keys).sort,
            "live_applied" => Schema.live_ids(normalized.keys).sort,
            "fingerprint" => fingerprint,
            "onboarding_outcome" => outcome,
            "onboarding_version" => (Config::ONBOARDING_VERSION if outcome)
          }.compact
        end
      rescue StaleRevisionError, ValidationError, LockError
        raise
      rescue SystemCallError, IOError => e
        raise PersistenceError, "Could not publish configuration #{path}: #{e.message}"
      end

      # Compatibility writers and startup migration use schema-owned paths but
      # not ordinary editable rows (for example onboarding lifecycle metadata).
      # This still receives the same lock, stale check, atomic write, and unknown
      # key preservation as an interactive transaction.
      def patch_paths(base_fingerprint: fingerprint, patches: {})
        with_lock do
          current = Config.load(path: path)
          if base_fingerprint.to_s != fingerprint
            raise StaleRevisionError, "Configuration changed on disk before it could be saved."
          end
          data = current.to_file_h
          Config.deep_stringify(patches || {}).each do |dotted_path, value|
            path_parts = dotted_path.to_s.split(".")
            value.nil? ? delete_path!(data, path_parts) : set_path!(data, path_parts, value)
          end
          publish!(data)
          Config.new(data, path: path, loaded: true, file_data: data)
        end
      end

      private

      def with_lock
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        file = begin
          File.open("#{path}#{LOCK_SUFFIX}", File::RDWR | File::CREAT, 0o600)
        rescue SystemCallError, IOError => e
          raise LockError, "Could not open configuration lock for #{path}: #{e.message}"
        end
        begin
          acquired = begin
            file.flock(File::LOCK_EX)
          rescue SystemCallError, IOError => e
            raise LockError, "Could not lock configuration #{path}: #{e.message}"
          end
          raise LockError, "Could not acquire configuration lock #{file.path}" unless acquired

          yield
        ensure
          begin
            file.flock(File::LOCK_UN)
          rescue SystemCallError, IOError
            nil
          end
          file.close unless file.closed?
        end
      end

      def publish!(data)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        mode = File.file?(path) ? (File.stat(path).mode & 0o777) : 0o600
        mode = 0o600 if mode.zero?
        temp_path = File.join(directory, ".#{File.basename(path)}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
        begin
          File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
            file.chmod(mode)
            file.write(Config::TomlWriter.new(data).to_s)
            file.flush
            file.fsync
          end
          File.rename(temp_path, path)
          fsync_directory(directory)
        ensure
          File.delete(temp_path) if temp_path && File.exist?(temp_path)
        end
      end

      def fsync_directory(directory)
        File.open(directory, File::RDONLY) { |file| file.fsync }
      rescue SystemCallError, IOError, Errno::EISDIR, Errno::EINVAL
        nil
      end

      def serialized_value(definition, value)
        return definition.serialize.call(value) if definition.serialize.respond_to?(:call)

        Config.deep_copy(value)
      end

      def set_path!(data, path_parts, value)
        raise ArgumentError, "setting path is missing" if Array(path_parts).empty?

        parent = Array(path_parts)[0...-1].reduce(data) do |current, part|
          current[part.to_s] = {} unless current[part.to_s].is_a?(Hash)
          current.fetch(part.to_s)
        end
        parent[Array(path_parts).last.to_s] = Config.deep_copy(value)
      end

      def delete_path!(data, path_parts)
        return if Array(path_parts).empty?

        parents = []
        current = data
        Array(path_parts)[0...-1].each do |part|
          return unless current.is_a?(Hash) && current[part.to_s].is_a?(Hash)

          parents << [current, part.to_s]
          current = current.fetch(part.to_s)
        end
        current.delete(Array(path_parts).last.to_s) if current.is_a?(Hash)
        parents.reverse_each do |parent, key|
          parent.delete(key) if parent[key].is_a?(Hash) && parent[key].empty?
        end
      end

      def validate_cross_fields!(data, changed_ids:)
        config = Config.new(data, path: path, loaded: true, file_data: data)
        errors = {}
        if (changed_ids & %w[safety.worker_blacklist agent.worker_harness]).any?
          patterns = Schema.fetch("safety.worker_blacklist").effective_value(config, env: {})
          worker = Schema.fetch("agent.worker_harness").effective_value(config, env: {})
          if Array(patterns).any? && worker.to_s != "pi"
            errors["safety.worker_blacklist"] = "can only be enforced when the worker harness is pi"
          end
        end

        timeout_ids = %w[workspace.worktree_stall_timeout workspace.worktree_checkout_timeout]
        if (changed_ids & timeout_ids).any?
          stall = Schema.fetch(timeout_ids[0]).effective_value(config, env: {}).to_i
          ceiling = Schema.fetch(timeout_ids[1]).effective_value(config, env: {}).to_i
          if stall > ceiling
            errors[timeout_ids[0]] = "must not exceed the checkout ceiling (#{ceiling} seconds)"
          end
        end
        raise ValidationError, errors unless errors.empty?
      end
    end
  end
end
