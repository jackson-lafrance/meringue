# frozen_string_literal: true

require "fileutils"
require "json"
require "thread"

module Meringue
  module Harness
    # Pi stores project trust decisions by exact canonical directory. Meringue records only the
    # allocated worker directory, never its parent, so a worker cannot broaden Pi's trust boundary.
    module PiWorkspaceTrust
      TRUST_FILE = "trust.json"
      LOCK_TIMEOUT = 5
      @mutex = Mutex.new

      module_function

      def agent_dir
        configured = ENV["PI_CODING_AGENT_DIR"]
        return File.expand_path(configured) if configured && !configured.strip.empty?

        File.expand_path("~/.pi/agent")
      end

      def trust_path
        File.join(agent_dir, TRUST_FILE)
      end

      def trusted?(path, file: trust_path)
        read(file)[canonical_path(path)] == true
      end

      def trust!(path, file: trust_path)
        target = canonical_path(path)
        return false if target.empty?

        @mutex.synchronize do
          with_lock(file) do
            data = read(file)
            return true if data[target] == true

            write(file, data.merge(target => true))
          end
        end
        true
      rescue StandardError
        false
      end

      def canonical_path(path)
        return "" if path.to_s.strip.empty?

        File.realpath(File.expand_path(path.to_s))
      rescue SystemCallError
        File.expand_path(path.to_s)
      end

      def read(file)
        return {} unless File.file?(file)

        parsed = JSON.parse(File.read(file))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def write(file, data)
        FileUtils.mkdir_p(File.dirname(file))
        temporary = "#{file}.meringue-#{Process.pid}.tmp"
        File.write(temporary, JSON.pretty_generate(data))
        FileUtils.mv(temporary, file)
        true
      rescue SystemCallError
        false
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      def with_lock(file)
        lock_path = "#{file}.meringue.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_TIMEOUT
          acquired = false
          until acquired || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
            sleep 0.05 unless acquired
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
