# frozen_string_literal: true

require "open3"
require "rbconfig"

module Meringue
  # Process lifecycle operations for the interactive dashboard. Updating the
  # source checkout is intentionally outside the kernel: it changes the
  # installed program rather than orchestration state.
  module Lifecycle
    class CommandRunner
      DEFAULT_TIMEOUT_SECONDS = 120.0
      TERMINATION_GRACE_SECONDS = 0.1

      def initialize(timeout: DEFAULT_TIMEOUT_SECONDS)
        @timeout = Float(timeout)
      end

      def call(command, chdir:)
        stdin = stdout = stderr = wait_thread = nil
        stdout_reader = stderr_reader = nil
        stdin, stdout, stderr, wait_thread = Open3.popen3(*Array(command), chdir: chdir, pgroup: true)
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }

        unless wait_thread.join(@timeout)
          terminate(wait_thread)
          return result(stdout_reader, stderr_reader, nil, timed_out: true)
        end

        result(stdout_reader, stderr_reader, wait_thread.value)
      rescue Errno::ENOENT => e
        {
          "stdout" => "",
          "stderr" => e.message,
          "status" => nil,
          "timed_out" => false,
          "error" => e.message
        }
      ensure
        [stdout_reader, stderr_reader].compact.each do |reader|
          reader.join(TERMINATION_GRACE_SECONDS)
          if reader.alive?
            reader.kill
            reader.join
          end
        end
        [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
      end

      private

      def result(stdout_reader, stderr_reader, status, timed_out: false)
        {
          "stdout" => stdout_reader&.value.to_s,
          "stderr" => stderr_reader&.value.to_s,
          "status" => status,
          "timed_out" => timed_out
        }
      end

      def terminate(wait_thread)
        signal("TERM", wait_thread.pid)
        return if wait_thread.join(TERMINATION_GRACE_SECONDS)

        signal("KILL", wait_thread.pid)
        wait_thread.join
      end

      def signal(name, pid)
        Process.kill(name, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(name, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end

    class Manager
      DEFAULT_TIMEOUT_SECONDS = CommandRunner::DEFAULT_TIMEOUT_SECONDS

      attr_reader :root, :command

      def initialize(root: Meringue.root_path, arguments: [], command: nil,
                     runner: nil, execer: nil, timeout: DEFAULT_TIMEOUT_SECONDS)
        @root = File.expand_path(root.to_s)
        @command = Array(command || self.class.default_command(arguments)).map(&:to_s).freeze
        @runner = runner || CommandRunner.new(timeout: timeout)
        @execer = execer || lambda { |argv, chdir:| Process.exec(*argv, chdir: chdir) }
        @timeout = timeout
      end

      # Replace this process after the caller has finished its normal shutdown
      # path. The default command starts the checked-in entrypoint with Ruby so
      # bundle-exec environment and the original CLI arguments survive reload.
      def reload
        return failure("Meringue cannot reload because its launch command is unavailable.") if command.empty?

        @execer.call(command, chdir: root)
        failure("Meringue reload did not replace the current process.")
      rescue StandardError => e
        failure("Could not reload Meringue: #{e.message}")
      end

      # Update only a clean Git source checkout. No reset, checkout, or force
      # operation is used: local edits and untracked files are preserved by
      # refusing the update instead of risking data loss.
      def update
        checkout_error = validate_checkout
        return failure(checkout_error) if checkout_error

        status = run_command(%w[git status --porcelain --untracked-files=all])
        return failure(command_failure_message("Could not inspect the Meringue checkout", status)) unless successful?(status)
        return failure("Cannot update Meringue while the installation has local changes. Commit or stash them first.") unless status.fetch("stdout", "").strip.empty?

        pull = run_command(%w[git pull --ff-only])
        return failure(command_failure_message("Could not update Meringue", pull)) unless successful?(pull)

        dependencies_installed = false
        if File.file?(File.join(root, "Gemfile"))
          bundle_check = run_command(%w[bundle check])
          if bundle_check.fetch("timed_out", false) || bundle_check.key?("error")
            return failure(command_failure_message("Could not check Meringue dependencies", bundle_check))
          end
          unless successful?(bundle_check)
            bundle_install = run_command(%w[bundle install])
            return failure(command_failure_message("Could not install Meringue dependencies", bundle_install)) unless successful?(bundle_install)

            dependencies_installed = true
          end
        end

        {
          "status" => "updated",
          "message" => "Meringue updated#{dependencies_installed ? " and dependencies installed" : ""}; reloading.",
          "dependencies_installed" => dependencies_installed
        }
      rescue StandardError => e
        failure("Could not update Meringue: #{e.message}")
      end

      def self.default_command(arguments)
        program = $PROGRAM_NAME.to_s
        program = File.expand_path(program, Dir.pwd) unless program.start_with?(File::SEPARATOR)
        [RbConfig.ruby, program, *Array(arguments)]
      end

      private

      def validate_checkout
        return "Meringue's installation directory does not exist: #{root}" unless File.directory?(root)
        return "Meringue can only update a Git source checkout. Update this installation manually: #{root}" unless git_metadata_present?

        nil
      end

      def git_metadata_present?
        File.exist?(File.join(root, ".git"))
      end

      def run_command(command)
        result = @runner.call(command, chdir: root)
        result.is_a?(Hash) ? result : { "status" => result }
      end

      def successful?(result)
        return false if result.fetch("timed_out", false)
        return result.fetch("success") if result.key?("success")

        status = result.fetch("status", nil)
        return false if status.nil?
        return status.success? if status.respond_to?(:success?)

        status.to_i.zero?
      end

      def command_failure_message(prefix, result)
        if result.fetch("timed_out", false)
          return "#{prefix}: command timed out after #{@timeout.to_f} seconds."
        end

        details = [result.fetch("stderr", nil), result.fetch("stdout", nil), result.fetch("error", nil)]
                  .map { |value| value.to_s.strip }
                  .find { |value| !value.empty? }
        details ? "#{prefix}: #{details}" : "#{prefix}."
      end

      def failure(message)
        { "status" => "failed", "message" => message }
      end
    end
  end
end
