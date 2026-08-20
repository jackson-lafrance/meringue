# frozen_string_literal: true

require "fileutils"
require "json"
require "thread"

module Meringue
  module Harness
    # Records that a workspace is trusted, so Claude Code reaches its prompt instead of stopping at
    # its first-run modal.
    #
    # Claude Code asks once per directory whether the folder is trusted, and it asks before it will
    # accept any input — including under --dangerously-skip-permissions, which governs tool
    # permissions rather than workspace trust. Every Meringue worker gets a brand new worktree
    # path, so without this every worker would start by blocking on a modal that no one is watching.
    #
    # This writes the same flag the modal writes when a user answers "yes". Meringue only ever sets
    # it for a directory it is about to run an agent in on the user's behalf, which is the
    # directory the user already pointed their project at.
    module ClaudeWorkspaceTrust
      TRUST_KEY = "hasTrustDialogAccepted"
      LOCK_TIMEOUT = 5

      @mutex = Mutex.new

      module_function

      def config_path(claude_home: nil)
        # Claude Code keeps per-project state next to the home directory, not inside CLAUDE_CONFIG_DIR.
        home = claude_home || ENV["CLAUDE_CONFIG_DIR"]
        return File.join(File.expand_path(home.to_s), ".claude.json") if home && !home.to_s.strip.empty?

        File.expand_path("~/.claude.json")
      end

      def trusted?(path, claude_home: nil)
        data = read_config(config_path(claude_home: claude_home))
        projects = data["projects"]
        return false unless projects.is_a?(Hash)

        entry = projects[canonical_path(path)]
        entry.is_a?(Hash) && entry[TRUST_KEY] == true
      end

      # Returns true when the workspace is trusted afterwards, false when it could not be recorded.
      # A false result is not fatal: the client still watches for the modal and answers it, so a
      # config file that is locked or unreadable degrades to the slower path instead of hanging.
      def trust!(path, claude_home: nil)
        target = canonical_path(path)
        return false if target.to_s.empty?

        file = config_path(claude_home: claude_home)
        @mutex.synchronize do
          with_config_lock(file) do
            data = read_config(file)
            projects = data["projects"].is_a?(Hash) ? data["projects"] : {}
            entry = projects[target].is_a?(Hash) ? projects[target] : {}
            return true if entry[TRUST_KEY] == true

            projects[target] = entry.merge(TRUST_KEY => true)
            data["projects"] = projects
            write_config(file, data)
          end
        end
        true
      rescue StandardError
        false
      end

      # Claude Code keys project state by the resolved path, so a symlinked workspace must be
      # recorded under the path the agent will actually report.
      def canonical_path(path)
        return "" if path.to_s.strip.empty?

        File.realpath(File.expand_path(path.to_s))
      rescue SystemCallError
        File.expand_path(path.to_s)
      end

      def read_config(file)
        return {} unless File.file?(file)

        parsed = JSON.parse(File.read(file))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      # Written through a temporary file in the same directory and renamed, so a crash or a
      # concurrent reader never observes a half-written config. The user's own Claude Code settings
      # live in this file; losing them to a partial write would be a real cost.
      def write_config(file, data)
        FileUtils.mkdir_p(File.dirname(file))
        temporary = "#{file}.meringue-#{Process.pid}.tmp"
        File.write(temporary, JSON.pretty_generate(data))
        FileUtils.mv(temporary, file)
        true
      ensure
        begin
          File.delete(temporary) if temporary && File.exist?(temporary)
        rescue SystemCallError
          nil
        end
      end

      # A separate lock file rather than locking the config itself: Claude Code opens the config
      # for its own writes and must not be blocked by, or block, Meringue's flag update.
      def with_config_lock(file)
        lock_path = "#{file}.meringue.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          acquired = false
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_TIMEOUT
          until acquired
            acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
            break if acquired
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.05
          end
          return yield unless acquired

          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      rescue SystemCallError
        yield
      end
    end
  end
end
