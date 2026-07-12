# frozen_string_literal: true

require "shellwords"

module Meringue
  module Harness
    class TerminalSessionOpener
      DEFAULT_COMMANDS = {
        "pi" => "pi",
        "claude" => "claude",
        "gemini" => "gemini"
      }.freeze
      DEFAULT_ALACRITTY_COMMAND = "alacritty"
      DEFAULT_PI_SESSION_DIR = File.expand_path(ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
      MACOS_ALACRITTY_PATHS = [
        "/Applications/Alacritty.app/Contents/MacOS/alacritty",
        File.expand_path("~/Applications/Alacritty.app/Contents/MacOS/alacritty")
      ].freeze

      def initialize(pi_command: nil, pi_session_dir: DEFAULT_PI_SESSION_DIR, alacritty_command: ENV["MERINGUE_ALACRITTY_COMMAND"], commands: {}, gemini_resume_flag: "--resume")
        configured_commands = DEFAULT_COMMANDS.merge(stringify_keys(commands || {}))
        configured_commands["pi"] = pi_command if present?(pi_command)
        @commands = configured_commands
        @pi_session_dir = pi_session_dir
        @gemini_resume_flag = gemini_resume_flag.to_s
        @custom_alacritty_command = present?(alacritty_command)
        @alacritty_command = @custom_alacritty_command ? alacritty_command : DEFAULT_ALACRITTY_COMMAND
      end

      def open(agent)
        return rejected("Agent was not found.") unless agent

        harness = agent.fetch("harness", nil).to_s
        return rejected("Agent #{agent_id(agent)} has no harness to open.") if harness.empty?

        command_argv = harness_argv(harness, agent)
        return rejected("Opening #{harness.inspect} sessions is not supported yet.") unless command_argv

        open_agent_terminal(agent, command_argv)
      rescue StandardError => e
        failed("Could not open agent #{agent_id(agent)}: #{e.class}: #{e.message}")
      end

      private

      attr_reader :commands, :pi_session_dir, :alacritty_command, :gemini_resume_flag

      def custom_alacritty_command?
        @custom_alacritty_command
      end

      def open_agent_terminal(agent, command_argv)
        cwd = agent_cwd(agent)
        return rejected("Agent #{agent_id(agent)} workspace is missing: #{cwd}") unless Dir.exist?(cwd)

        alacritty = alacritty_argv
        unless alacritty
          return failed("Could not open #{agent_id(agent)} in Alacritty because the alacritty executable was not found or is not executable. Install Alacritty or set MERINGUE_ALACRITTY_COMMAND to its executable path.")
        end

        result = open_alacritty(alacritty, cwd, command_argv)
        return opened("Opened #{agent_id(agent)} in Alacritty.") if result.fetch("opened")

        failed("Could not open #{agent_id(agent)} in Alacritty: #{result.fetch("error")}")
      end

      def harness_argv(harness, agent)
        case harness
        when "pi"
          pi_argv(agent)
        when "claude"
          claude_argv(agent)
        when "gemini"
          gemini_argv(agent)
        end
      end

      def pi_argv(agent)
        session = pi_session_argument(agent)
        return nil unless present?(session)

        argv = command_parts("pi")
        argv += ["--session-dir", pi_session_dir] if present?(pi_session_dir)
        argv + ["--session", session]
      end

      def claude_argv(agent)
        session_id = agent.fetch("harness_session_id", nil)
        return nil unless present?(session_id)

        command_parts("claude") + ["--resume", session_id]
      end

      def gemini_argv(agent)
        session_id = agent.fetch("harness_session_id", nil)
        return nil unless present?(session_id)

        argv = command_parts("gemini")
        argv << gemini_resume_flag if present?(gemini_resume_flag)
        argv << session_id
        argv
      end

      def pi_session_argument(agent)
        session_file = agent.fetch("harness_session_file", nil)
        return File.expand_path(session_file) if present?(session_file) && File.file?(File.expand_path(session_file))

        session_id = agent.fetch("harness_session_id", nil)
        return session_id if present?(session_id)

        nil
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

      def command_parts(harness)
        Shellwords.split(commands.fetch(harness).to_s)
      rescue ArgumentError
        [commands.fetch(harness).to_s]
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

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
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
