# frozen_string_literal: true

require "rbconfig"
require "shellwords"

module Meringue
  module Harness
    class TerminalSessionOpener
      DEFAULT_PI_COMMAND = "pi"
      DEFAULT_PI_SESSION_DIR = File.expand_path(ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))

      def initialize(pi_command: DEFAULT_PI_COMMAND, pi_session_dir: DEFAULT_PI_SESSION_DIR, terminal_command: ENV["MERINGUE_JUMP_TERMINAL"])
        @pi_command = pi_command
        @pi_session_dir = pi_session_dir
        @terminal_command = terminal_command
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

      attr_reader :pi_command, :pi_session_dir, :terminal_command

      def open_pi_agent(agent)
        session = pi_session_argument(agent)
        return rejected("Agent #{agent_id(agent)} has no Pi session id or session file.") unless present?(session)

        cwd = agent_cwd(agent)
        return rejected("Agent #{agent_id(agent)} workspace is missing: #{cwd}") unless Dir.exist?(cwd)

        shell_command = [
          "cd #{Shellwords.escape(cwd)}",
          pi_argv(session).shelljoin
        ].join(" && ")

        return opened("Opened #{agent_id(agent)} in a new terminal.") if open_terminal(shell_command)

        failed("Could not open a new terminal for #{agent_id(agent)}. Set MERINGUE_JUMP_TERMINAL to a terminal command template if your terminal is unsupported.")
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

      def open_terminal(shell_command)
        return open_with_template(shell_command) if present?(terminal_command)
        return open_macos_terminal(shell_command) if RbConfig::CONFIG.fetch("host_os", "") =~ /darwin/i

        open_unix_terminal(shell_command)
      end

      def open_with_template(shell_command)
        command = terminal_command.gsub("{command}", shell_command).gsub("{command_escaped}", Shellwords.escape(shell_command))
        system(command, out: File::NULL, err: File::NULL)
      end

      def open_macos_terminal(shell_command)
        script = <<~APPLESCRIPT
          tell application "Terminal"
            do script #{shell_command.inspect}
          end tell
        APPLESCRIPT
        system("osascript", "-e", script, out: File::NULL, err: File::NULL)
      end

      def open_unix_terminal(shell_command)
        terminal_commands.find do |argv|
          next false unless executable?(argv.first)

          system(*argv, "bash", "-lc", shell_command, out: File::NULL, err: File::NULL)
        end
      end

      def terminal_commands
        [
          ["x-terminal-emulator", "-e"],
          ["gnome-terminal", "--"],
          ["konsole", "-e"],
          ["xfce4-terminal", "-e"],
          ["xterm", "-e"]
        ]
      end

      def executable?(name)
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
