# frozen_string_literal: true

require "shellwords"

module Meringue
  module Harness
    class TerminalSessionOpener
      DEFAULT_PI_COMMAND = "pi"
      DEFAULT_ALACRITTY_COMMAND = "alacritty"
      DEFAULT_PI_SESSION_DIR = File.expand_path(ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
      MACOS_ALACRITTY_PATHS = [
        "/Applications/Alacritty.app/Contents/MacOS/alacritty",
        File.expand_path("~/Applications/Alacritty.app/Contents/MacOS/alacritty")
      ].freeze

      def initialize(pi_command: DEFAULT_PI_COMMAND, pi_session_dir: DEFAULT_PI_SESSION_DIR, alacritty_command: ENV["MERINGUE_ALACRITTY_COMMAND"])
        @pi_command = pi_command
        @pi_session_dir = pi_session_dir
        @custom_alacritty_command = present?(alacritty_command)
        @alacritty_command = @custom_alacritty_command ? alacritty_command : DEFAULT_ALACRITTY_COMMAND
      end

      def open(agent)
        return rejected("Agent was not found.") unless agent

        harness = agent.fetch("harness", nil).to_s
        return rejected("Agent #{agent_id(agent)} has no harness to open.") if harness.empty?
        return rejected("Opening #{harness.inspect} sessions is not supported yet.") unless harness == "pi"

        open_pi_agent(agent)
      rescue StandardError => e
        failed("Could not open agent #{agent_id(agent)}: #{e.class}: #{e.message}")
      end

      private

      attr_reader :pi_command, :pi_session_dir, :alacritty_command

      def custom_alacritty_command?
        @custom_alacritty_command
      end

      def open_pi_agent(agent)
        session = pi_session_argument(agent)
        return rejected("Agent #{agent_id(agent)} has no Pi session id or session file.") unless present?(session)

        cwd = agent_cwd(agent)
        return rejected("Agent #{agent_id(agent)} workspace is missing: #{cwd}") unless Dir.exist?(cwd)

        alacritty = alacritty_argv
        unless alacritty
          return failed("Could not open #{agent_id(agent)} in Alacritty because the alacritty executable was not found or is not executable. Install Alacritty or set MERINGUE_ALACRITTY_COMMAND to its executable path.")
        end

        result = open_alacritty(alacritty, cwd, pi_argv(session))
        return opened("Opened #{agent_id(agent)} in Alacritty.") if result.fetch("opened")

        failed("Could not open #{agent_id(agent)} in Alacritty: #{result.fetch("error")}")
      end

      def pi_session_argument(agent)
        session_file = agent.fetch("harness_session_file", nil)
        return File.expand_path(session_file) if present?(session_file) && File.file?(File.expand_path(session_file))

        session_id = agent.fetch("harness_session_id", nil)
        return session_id if present?(session_id)

        nil
      end

      def pi_argv(session)
        argv = [pi_command]
        argv += ["--session-dir", pi_session_dir] if present?(pi_session_dir)
        argv + ["--session", session]
      end

      def open_alacritty(alacritty, cwd, command_argv)
        argv = alacritty + ["--working-directory", cwd, "-e"] + command_argv
        pid = Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL)
        status = wait_for_immediate_exit(pid)
        if status
          return { "opened" => true } if status.success?

          return { "opened" => false, "error" => "process exited with status #{status.exitstatus || status.termsig}" }
        end

        Process.detach(pid)
        { "opened" => true }
      rescue Errno::ENOENT
        { "opened" => false, "error" => "alacritty executable was not found or is not executable" }
      rescue SystemCallError => e
        { "opened" => false, "error" => e.message }
      end

      def wait_for_immediate_exit(pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
        loop do
          return $? if Process.waitpid(pid, Process::WNOHANG)
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.05
        end
      rescue Errno::ECHILD
        nil
      end

      def alacritty_argv
        argv = configured_alacritty_argv
        return argv if argv.any? && executable?(argv.first)
        return nil if custom_alacritty_command?

        MACOS_ALACRITTY_PATHS.each do |path|
          return [path] if executable?(path)
        end

        nil
      end

      def configured_alacritty_argv
        Shellwords.split(alacritty_command.to_s)
      rescue ArgumentError
        [alacritty_command.to_s]
      end

      def executable?(name)
        return false unless present?(name)
        return File.file?(name) && File.executable?(name) if name.include?(File::SEPARATOR)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, name)
          File.file?(path) && File.executable?(path)
        end
      end

      def agent_cwd(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        File.expand_path(metadata["cwd"] || agent["workspace_path"] || Dir.pwd)
      end

      def agent_id(agent)
        agent&.fetch("id", "unknown") || "unknown"
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      def opened(message)
        { "status" => "opened", "message" => message }
      end

      def rejected(message)
        { "status" => "rejected", "message" => message }
      end

      def failed(message)
        { "status" => "failed", "message" => message }
      end
    end
  end
end
