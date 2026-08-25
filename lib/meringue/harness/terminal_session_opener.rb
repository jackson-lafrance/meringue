# frozen_string_literal: true

require "json"
require "shellwords"

module Meringue
  module Harness
    class TerminalSessionOpener
      DEFAULT_COMMANDS = {
        "pi" => "pi",
        "claude" => "claude"
      }.freeze
      DEFAULT_ALACRITTY_COMMAND = "alacritty"
      DEFAULT_SESSION_DIRECTORIES = {
        "pi" => File.expand_path(
          ENV.fetch("MERINGUE_AGENT_SESSION_DIR", ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
        )
      }.freeze
      # Backward-compatible constant for callers that predate provider-keyed configuration.
      DEFAULT_SESSION_DIR = DEFAULT_SESSION_DIRECTORIES.fetch("pi")
      MACOS_ALACRITTY_PATHS = [
        "/Applications/Alacritty.app/Contents/MacOS/alacritty",
        File.expand_path("~/Applications/Alacritty.app/Contents/MacOS/alacritty")
      ].freeze

      def initialize(alacritty_command: ENV["MERINGUE_ALACRITTY_COMMAND"], commands: {}, session_directories: {},
                     pi_command: nil, session_dir: nil)
        @commands = DEFAULT_COMMANDS.merge(stringify_keys(commands || {}))
        @session_directories = DEFAULT_SESSION_DIRECTORIES.merge(stringify_keys(session_directories || {}))
        # Preserve the pre-registry constructor for external callers while all generic call sites
        # use provider-keyed maps. These compatibility keywords configure the Pi launcher only.
        @commands["pi"] = pi_command if present?(pi_command)
        @session_directories["pi"] = session_dir if present?(session_dir)
        @custom_alacritty_command = present?(alacritty_command)
        @alacritty_command = @custom_alacritty_command ? alacritty_command : DEFAULT_ALACRITTY_COMMAND
      end

      def open(agent)
        return rejected("Agent was not found.") unless agent

        harness = agent.fetch("harness", nil).to_s
        return rejected("Agent #{agent_id(agent)} has no agent session to open.") if harness.empty?

        launch = harness_launch(harness, agent)
        return rejected("Opening this agent session in a terminal is not supported yet.") unless launch
        return rejected(launch.fetch("error")) if launch["error"]

        open_agent_terminal(agent, launch.fetch("argv"))
      rescue StandardError => e
        failed("Could not open agent #{agent_id(agent)}: #{e.class}: #{e.message}")
      end

      private

      attr_reader :commands, :session_directories, :alacritty_command

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
        return opened if result.fetch("opened")

        failed("Could not open #{agent_id(agent)} in Alacritty: #{result.fetch("error")}")
      end

      def harness_launch(harness, agent)
        case harness
        when "pi"
          pi_launch(agent)
        when "claude"
          argv = claude_argv(agent)
          argv ? { "argv" => argv } : { "error" => "Agent #{agent_id(agent)} has no saved Claude session to open." }
        end
      end

      def pi_launch(agent)
        session_dir = provider_session_directory("pi")
        session_file, error = available_pi_session_file(agent, session_dir: session_dir)
        return { "error" => "#{error} #{preserved_record_note}" } if error

        argv = command_parts("pi")
        argv += ["--session-dir", session_dir] if present?(session_dir)
        { "argv" => argv + ["--session", session_file] }
      end

      def claude_argv(agent)
        session_id = agent.fetch("harness_session_id", nil)
        return nil unless present?(session_id)

        command_parts("claude") + ["--resume", session_id]
      end

      def available_pi_session_file(agent, session_dir:)
        configured_file = expanded_session_file(agent)
        session_id = agent.fetch("harness_session_id", nil)

        if configured_file && File.file?(configured_file)
          error = pi_session_file_error(configured_file, expected_session_id: session_id)
          return error ? [nil, unavailable_pi_session_message(agent, configured_file, error)] : [configured_file, nil]
        end

        discovered_file, discovery_error = discover_pi_session_file(session_id, session_dir: session_dir)
        return [discovered_file, nil] if discovered_file

        if configured_file
          message = "Agent session history for #{agent_id(agent)} is unavailable because its saved session file is missing: #{configured_file}."
          message += " #{discovery_error}" if discovery_error
          return [nil, message]
        end

        unless present?(session_id)
          return [nil, "Agent #{agent_id(agent)} has no saved agent session file or session id to open."]
        end

        message = "Agent session history for #{agent_id(agent)} is unavailable because no saved session file matches #{session_id.inspect}"
        message += present?(session_dir) ? " in #{File.expand_path(session_dir)}." : "."
        message += " #{discovery_error}" if discovery_error
        [nil, message]
      end

      def expanded_session_file(agent)
        session_file = agent.fetch("harness_session_file", nil)
        File.expand_path(session_file) if present?(session_file)
      end

      def discover_pi_session_file(session_id, session_dir:)
        return [nil, nil] unless present?(session_id) && present?(session_dir)

        directory = File.expand_path(session_dir)
        return [nil, "The configured agent session directory is missing."] unless Dir.exist?(directory)

        candidates = Dir.children(directory).select do |name|
          name.end_with?(".jsonl") && name.include?(session_id.to_s)
        end.sort.map { |name| File.join(directory, name) }
        first_error = nil
        candidates.each do |path|
          error = pi_session_file_error(path, expected_session_id: session_id)
          return [path, nil] unless error

          first_error ||= "A matching file could not be opened: #{error}"
        end
        [nil, first_error]
      rescue SystemCallError => e
        [nil, "The configured agent session directory could not be read: #{e.message}"]
      end

      def pi_session_file_error(path, expected_session_id: nil)
        header = nil
        record_count = 0

        File.foreach(path).with_index(1) do |line, line_number|
          next if line.strip.empty?

          record = JSON.parse(line)
          return "line #{line_number} is not a JSON object" unless record.is_a?(Hash)

          header ||= record
          record_count += 1
        rescue JSON::ParserError => e
          return "line #{line_number} is invalid JSON (#{e.message})"
        end

        return "the file is empty" if record_count.zero?
        return "the first record is not an agent session header" unless header["type"] == "session"
        return "the session header has no id" unless present?(header["id"])
        if present?(expected_session_id) && header["id"].to_s != expected_session_id.to_s
          return "the session header id #{header["id"].inspect} does not match #{expected_session_id.inspect}"
        end

        nil
      rescue SystemCallError => e
        "the file could not be read (#{e.message})"
      end

      def unavailable_pi_session_message(agent, path, error)
        "Agent session history for #{agent_id(agent)} is unavailable because its saved session file is malformed: #{path} (#{error})."
      end

      def provider_session_directory(harness)
        directory = session_directories[harness.to_s]
        File.expand_path(directory) if present?(directory)
      end

      def preserved_record_note
        "The saved Meringue agent record, logs, and any captured agent output remain unchanged."
      end

      def open_alacritty(alacritty, cwd, command_argv)
        argv = alacritty + ["--working-directory", cwd, "-e"] + command_argv
        base_environment = SubprocessEnvironment.clean
        environment = base_environment.merge(
          Git::CommitIdentity.environment(cwd: cwd, base_environment: base_environment)
        )
        pid = Process.spawn(environment, *argv, in: File::NULL, out: File::NULL, err: File::NULL)
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

      # Never fall back to the Meringue process cwd: it can already be inside a
      # workspace, which is how nested workspace paths get produced.
      def agent_cwd(agent)
        resolution = Workspace::PathResolver.resolve(agent)
        resolution.fetch("path", nil) || resolution.fetch("expected_path", nil) || Dir.home
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

      # Successful opens are transient UI feedback, so they carry no user-visible message.
      def opened
        { "status" => "opened" }
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
