# frozen_string_literal: true

require "open3"
require "rbconfig"

require_relative "subprocess_environment"

module Meringue
  # Process lifecycle operations for the interactive dashboard. Updating the
  # source checkout is intentionally outside the kernel: it changes the
  # installed program rather than orchestration state.
  module Lifecycle
    class CommandRunner
      DEFAULT_TIMEOUT_SECONDS = 120.0
      OUTPUT_LIMIT_BYTES = 64 * 1024
      READ_CHUNK_BYTES = 16 * 1024
      TERMINATION_GRACE_SECONDS = 0.1

      def initialize(timeout: DEFAULT_TIMEOUT_SECONDS, output_limit: OUTPUT_LIMIT_BYTES)
        @timeout = Float(timeout)
        @output_limit = Integer(output_limit)
        raise ArgumentError, "Lifecycle command timeout must be positive and finite." unless @timeout.positive? && @timeout.finite?
        raise ArgumentError, "Lifecycle command output limit must be positive." unless @output_limit.positive?
      end

      def call(command, chdir:)
        stdin = stdout = stderr = wait_thread = nil
        stdout_reader = stderr_reader = nil
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          SubprocessEnvironment.clean,
          *Array(command),
          chdir: chdir,
          pgroup: true
        )
        stdin.close
        stdout_reader = Thread.new { read_output(stdout) }
        stderr_reader = Thread.new { read_output(stderr) }

        timed_out = false
        unless wait_thread.join(@timeout)
          timed_out = true
          terminate(wait_thread)
        end

        drain_readers([stdout_reader, stderr_reader], [stdout, stderr])
        result(stdout_reader, stderr_reader, wait_thread.value, timed_out: timed_out)
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

      def read_output(stream)
        captured = +""
        loop do
          chunk = stream.readpartial(READ_CHUNK_BYTES)
          remaining = @output_limit - captured.bytesize
          captured << chunk.byteslice(0, remaining) if remaining.positive?
        end
      rescue EOFError, IOError
        captured
      end

      def drain_readers(readers, streams)
        readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
        return unless readers.any?(&:alive?)

        streams.each { |stream| stream.close unless stream.closed? }
        readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
        readers.each do |reader|
          next unless reader.alive?

          reader.kill
          reader.join
        end
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
      DEFAULT_BRANCH = "main"

      attr_reader :root, :command, :branch

      def initialize(root: Meringue.root_path, arguments: [], command: nil,
                     runner: nil, execer: nil, timeout: DEFAULT_TIMEOUT_SECONDS,
                     working_directory: Dir.pwd, branch: nil)
        @root = File.expand_path(root.to_s)
        @working_directory = File.expand_path(working_directory.to_s)
        @command = Array(command || self.class.default_command(arguments)).map(&:to_s).freeze
        @branch = (branch || self.class.default_branch).to_s
        @timeout = Float(timeout)
        raise ArgumentError, "Lifecycle command timeout must be positive and finite." unless @timeout.positive? && @timeout.finite?

        @runner = runner || CommandRunner.new(timeout: @timeout)
        @execer = execer || lambda { |argv, chdir:| Process.exec(*argv, chdir: chdir) }
      end

      # Replace this process after the caller has finished its normal shutdown
      # path. The default command starts the checked-in entrypoint with Ruby so
      # bundle-exec environment and the original CLI arguments survive reload.
      def reload
        return failure("Meringue cannot reload because its launch command is unavailable.") if command.empty?

        @execer.call(command, chdir: @working_directory)
        failure("Meringue reload did not replace the current process.")
      rescue StandardError => e
        failure("Could not reload Meringue: #{e.message}")
      end

      # Update only a clean Git source checkout, onto the branch this
      # installation is meant to run (`main`, or MERINGUE_BRANCH) rather than
      # whatever branch happens to be checked out. Pulling the current branch
      # made `/update` a silent no-op for an installation parked on a stale
      # one: nothing fast-forwarded, yet it reported success and restarted into
      # the same code. No reset or force operation is used, and a checkout with
      # local changes is refused rather than risking data loss.
      def update
        checkout_error = validate_checkout
        return failure(checkout_error) if checkout_error

        status = run_command(%w[git status --porcelain --untracked-files=all])
        return failure(command_failure_message("Could not inspect the Meringue checkout", status)) unless successful?(status)
        return failure("Cannot update Meringue while the installation has local changes. Commit or stash them first.") unless status.fetch("stdout", "").strip.empty?

        fetch = run_command(["git", "fetch", "--quiet", "origin", branch])
        return failure(command_failure_message("Could not fetch the Meringue repository", fetch)) unless successful?(fetch)

        target = revision("origin/#{branch}")
        return failure("Meringue's repository has no #{branch} branch. Set MERINGUE_BRANCH to the branch this installation tracks.") unless target

        previous = revision("HEAD")

        unless current_branch == branch
          checkout = run_command(["git", "checkout", branch])
          return failure(command_failure_message("Could not switch the Meringue checkout to #{branch}", checkout)) unless successful?(checkout)
        end

        merge = run_command(["git", "merge", "--ff-only", "origin/#{branch}"])
        return failure(command_failure_message("Could not update Meringue", merge)) unless successful?(merge)

        dependencies_installed = install_dependencies
        return dependencies_installed if dependencies_installed.is_a?(Hash)

        # An unchanged checkout gets its own status so the dashboard says so
        # instead of restarting into identical code with nothing to show for
        # it. Only "updated" asks the caller to reload.
        if previous == target && !dependencies_installed
          return {
            "status" => "current",
            "message" => "Meringue is already up to date with origin/#{branch} at #{short_revision(target)}.",
            "dependencies_installed" => false
          }
        end

        {
          "status" => "updated",
          "message" => "Meringue updated to #{short_revision(target)} on #{branch}#{dependencies_installed ? " and dependencies installed" : ""}; reloading.",
          "dependencies_installed" => dependencies_installed
        }
      rescue StandardError => e
        failure("Could not update Meringue: #{e.message}")
      end

      # The branch an installation tracks, matching install.sh so re-running
      # the installer and running `/update` land on the same commit.
      def self.default_branch(environment = ENV)
        configured = environment["MERINGUE_BRANCH"].to_s.strip
        configured.empty? ? DEFAULT_BRANCH : configured
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

      # Whether gems were installed, or a failure hash for the caller to return
      # unchanged.
      def install_dependencies
        return false unless File.file?(File.join(root, "Gemfile"))

        check = run_command(%w[bundle check])
        if check.fetch("timed_out", false) || check.key?("error")
          return failure(command_failure_message("Could not check Meringue dependencies", check))
        end
        return false if successful?(check)

        install = run_command(%w[bundle install])
        return failure(command_failure_message("Could not install Meringue dependencies", install)) unless successful?(install)

        true
      end

      # nil rather than a failure: an unresolvable revision is a question about
      # the checkout, and this caller has a better message than git's stderr.
      def revision(name)
        result = run_command(["git", "rev-parse", "--verify", "#{name}^{commit}"])
        return nil unless successful?(result)

        value = result.fetch("stdout", "").strip
        value.empty? ? nil : value
      end

      def short_revision(sha)
        sha.to_s[0, 7]
      end

      # nil on a detached HEAD, which reads as "not the branch we want" and so
      # takes the same checkout path as being on the wrong branch.
      def current_branch
        result = run_command(%w[git rev-parse --abbrev-ref HEAD])
        return nil unless successful?(result)

        value = result.fetch("stdout", "").strip
        value.empty? || value == "HEAD" ? nil : value
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
