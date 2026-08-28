# frozen_string_literal: true

require "open3"

module Meringue
  module Harness
    # Whether a backend's executable can be found on this machine, and whether it
    # actually runs.
    #
    # First-run setup used to offer all three providers as equally valid choices,
    # so a user could select a harness they had never installed and only discover
    # that mid-session, from a raw StartError several screens later. Resolution
    # here walks the same command argv and provider environment that
    # `Registry#build_client` hands to the launcher, so what setup reports and
    # what a worker will actually run cannot disagree.
    #
    # Locating is a filesystem walk with no subprocess, which is what makes it
    # safe to call from a render path. Probing runs the harness and is therefore
    # only ever reached from a control the user deliberately activates.
    module Availability
      class CommandTimeout < StandardError; end

      INSTALLED = "installed"
      MISSING = "missing"
      UNCONFIGURED = "unconfigured"
      RUNNABLE = "runnable"
      FAILED = "failed"
      TIMEOUT = "timeout"

      PROBE_TIMEOUT_SECONDS = 6
      TERMINATION_GRACE_SECONDS = 0.5
      # Every supported backend answers this, and none of them wait on input or a
      # network round trip to do it. It is the cheapest question that distinguishes
      # "a file exists at that path" from "that file starts and responds".
      VERSION_ARGUMENT = "--version"

      module_function

      # Filesystem-only resolution of the first argv entry. Never starts a process.
      def locate(argv, env: {}, base_environment: ENV.to_h)
        executable = Array(argv).map(&:to_s).reject(&:empty?).first.to_s
        return result(UNCONFIGURED, executable: executable, detail: "no command is configured") if executable.empty?

        path = resolve(executable, env: env, base_environment: base_environment)
        return result(MISSING, executable: executable, detail: "not found on PATH") if path.nil?

        result(INSTALLED, executable: executable, path: path)
      end

      # Bounded, user-triggered: resolve the executable, then ask it for its
      # version. A harness that cannot answer within the budget is reported as
      # such rather than being allowed to hold the setup card open.
      def probe(argv, env: {}, base_environment: ENV.to_h, timeout: PROBE_TIMEOUT_SECONDS)
        located = locate(argv, env: env, base_environment: base_environment)
        return located unless located.fetch("status") == INSTALLED

        command = Array(argv).map(&:to_s).reject(&:empty?)
        stdout, stderr, status = run(command + [VERSION_ARGUMENT], env: env, base_environment: base_environment, timeout: timeout)
        return located.merge("status" => FAILED, "detail" => failure_detail(stdout, stderr)) unless status&.success?

        located.merge("status" => RUNNABLE, "detail" => version_detail(stdout, stderr))
      rescue CommandTimeout
        located.merge("status" => TIMEOUT, "detail" => "did not answer #{VERSION_ARGUMENT} within #{timeout}s")
      rescue StandardError => e
        located.merge("status" => FAILED, "detail" => short(e.message))
      end

      def resolve(executable, env: {}, base_environment: ENV.to_h)
        return executable_at(File.expand_path(executable)) if executable.include?(File::SEPARATOR)

        search_paths(env: env, base_environment: base_environment).each do |directory|
          found = executable_at(File.join(directory, executable))
          return found if found
        end
        nil
      end

      def search_paths(env: {}, base_environment: ENV.to_h)
        # A provider's own `env` may set the PATH that its harness is launched
        # under, and that overlay is exactly what decides whether the executable
        # resolves. Reading it here is what keeps this honest for version-manager
        # and package-manager installations.
        raw = stringify(env)["PATH"] || base_environment.to_h["PATH"]
        raw.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
      end

      def executable_at(path)
        File.file?(path) && File.executable?(path) ? path : nil
      end

      def result(status, executable: "", path: nil, detail: nil)
        {
          "status" => status,
          "executable" => executable,
          "path" => path,
          "detail" => detail
        }.compact
      end

      # A short, human-facing summary of one located harness, for a row or a
      # picker entry. Deliberately never a bare "ok": the resolved path is the
      # part that answers "which one did you find?".
      def summary(located)
        case located.fetch("status", MISSING)
        when INSTALLED then "installed"
        when RUNNABLE then located.fetch("detail", "runs")
        when MISSING then "not found"
        when UNCONFIGURED then "no command set"
        when TIMEOUT then "timed out"
        else "found but did not run"
        end
      end

      def installed?(located)
        [INSTALLED, RUNNABLE].include?(located.fetch("status", MISSING))
      end

      def run(command, env:, base_environment:, timeout:)
        limit = Float(timeout)
        raise CommandTimeout, "timed out" unless limit.positive?

        environment = SubprocessEnvironment.clean(base_environment).merge(stringify(env))
        stdin = stdout = stderr = wait_thread = nil
        stdout_reader = stderr_reader = nil
        begin
          stdin, stdout, stderr, wait_thread = Open3.popen3(environment, *command, pgroup: true)
          stdin.close
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }
          unless wait_thread.join(limit)
            terminate(wait_thread)
            raise CommandTimeout, "timed out"
          end
          [stdout_reader.value, stderr_reader.value, wait_thread.value]
        ensure
          # Let the readers see EOF before their streams close; closing first can
          # make a still-scheduled reader raise IOError under a busy suite.
          [stdout_reader, stderr_reader].compact.each do |reader|
            reader.join(TERMINATION_GRACE_SECONDS)
            if reader.alive?
              reader.kill
              reader.join
            end
          end
          [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
        end
      end

      def terminate(wait_thread)
        signal("TERM", wait_thread.pid)
        return if wait_thread.join(TERMINATION_GRACE_SECONDS)

        signal("KILL", wait_thread.pid)
        wait_thread.join(TERMINATION_GRACE_SECONDS)
      end

      def signal(name, pid)
        Process.kill(name, -pid)
      rescue StandardError
        begin
          Process.kill(name, pid)
        rescue StandardError
          nil
        end
      end

      def version_detail(stdout, stderr)
        line = first_line(stdout) || first_line(stderr)
        line.to_s.empty? ? "runs" : short(line)
      end

      def failure_detail(stdout, stderr)
        line = first_line(stderr) || first_line(stdout)
        line.to_s.empty? ? "found but did not run" : short(line)
      end

      def first_line(text)
        text.to_s.lines.map(&:strip).find { |line| !line.empty? }
      end

      def short(text, limit: 80)
        value = text.to_s.strip.gsub(/\s+/, " ")
        value.length > limit ? "#{value[0, limit - 1]}…" : value
      end

      def stringify(env)
        return {} unless env.is_a?(Hash)

        env.to_h { |key, value| [key.to_s, value.to_s] }
      end
    end
  end
end
