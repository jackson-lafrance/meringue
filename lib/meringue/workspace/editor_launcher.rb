# frozen_string_literal: true

module Meringue
  module Workspace
    # Launches the user's editor as a separate process rooted in a worker's
    # workspace. Commands are always spawned as argv; no user value is passed to
    # a shell. Long-running GUI/editor processes are detached from Meringue,
    # while immediate failures are reported to the workspace UI.
    class EditorLauncher
      IMMEDIATE_EXIT_TIMEOUT = 0.5
      POLL_INTERVAL = 0.025
      DEFAULT_WORKSPACE_ARGUMENTS = ["."].freeze

      def self.from_config(config, env: ENV)
        section = config.respond_to?(:section) ? config.section("workspace") : {}
        section = {} unless section.is_a?(Hash)
        new(
          command: section["editor_command"],
          arguments: section.fetch("editor_args", DEFAULT_WORKSPACE_ARGUMENTS),
          env: env
        )
      end

      def initialize(command: nil, arguments: DEFAULT_WORKSPACE_ARGUMENTS, env: ENV, spawn: Process.method(:spawn))
        @env = stringify_environment(env)
        @spawn = spawn
        @configuration_error = nil
        @command = LaunchCommand.parse(command, default: default_editor_command(@env), label: "workspace editor_command")
        @arguments = normalize_arguments(arguments)
      rescue ArgumentError => e
        @configuration_error = e.message
        @command = nil
        @arguments = []
      end

      def open(agent_or_path)
        return rejected("Editor configuration is invalid: #{configuration_error}. Update [workspace] editor_command/editor_args in ~/.meringue/config.toml.") if configuration_error

        workspace_path = workspace_path_for(agent_or_path)
        return rejected("This worker has no assigned workspace to open in the editor.") if workspace_path.nil?
        return rejected("Worker workspace is missing or is not a directory: #{workspace_path}") unless Dir.exist?(workspace_path)

        executable = command.executable_path(cwd: workspace_path, path: env.fetch("PATH", ""))
        unless executable
          return failed("Could not open the editor because #{command.executable.inspect} was not found or is not executable. Set [workspace] editor_command to an installed editor CLI (for example [\"code\"] or [\"nvim\"]).")
        end

        argv = [executable] + command.argv.drop(1) + arguments
        pid = spawn_process(argv, workspace_path)
        status = wait_for_immediate_exit(pid)
        if status
          return opened("Opened #{workspace_label(agent_or_path)} in the editor.") if status.success?

          detail = status.signaled? ? "signal #{status.termsig}" : "status #{status.exitstatus}"
          return failed("Editor command #{command.display} exited immediately with #{detail}. Check [workspace] editor_command/editor_args and try it from #{workspace_path}.")
        end

        Process.detach(pid)
        opened("Opened #{workspace_label(agent_or_path)} in the editor (#{command.executable}).")
      rescue Errno::ENOENT
        failed("Could not open the editor because #{command&.executable.inspect} was not found. Check [workspace] editor_command.")
      rescue Errno::EACCES
        failed("Could not open the editor because #{command&.executable.inspect} is not executable. Check its permissions or [workspace] editor_command.")
      rescue SystemCallError => e
        failed("Could not open the editor in #{workspace_path || "the worker workspace"}: #{e.message}")
      rescue StandardError => e
        failed("Could not open the editor: #{e.class}: #{e.message}")
      end

      attr_reader :configuration_error

      private

      attr_reader :command, :arguments, :env, :spawn

      def default_editor_command(environment)
        environment["MERINGUE_EDITOR"] || environment["VISUAL"] || environment["EDITOR"] || "code"
      end

      def normalize_arguments(value)
        values = value.nil? ? DEFAULT_WORKSPACE_ARGUMENTS : value
        values = [values] if values.is_a?(String)
        unless values.is_a?(Array) && values.all? { |argument| argument.is_a?(String) }
          raise ArgumentError, "workspace editor_args must be a string or an array of strings"
        end
        raise ArgumentError, "workspace editor_args cannot contain null bytes" if values.any? { |argument| argument.include?("\0") }

        values.dup.freeze
      end

      def stringify_environment(value)
        value.to_h.each_with_object({}) do |(key, child), result|
          result[key.to_s] = child.to_s
        end
      end

      def workspace_path_for(agent_or_path)
        raw_path = if agent_or_path.is_a?(Hash)
                     metadata = agent_or_path.fetch("harness_metadata", {}) || {}
                     agent_or_path["workspace_path"] || metadata["cwd"]
                   else
                     agent_or_path
                   end
        return nil if raw_path.to_s.strip.empty?

        File.expand_path(raw_path.to_s)
      end

      def workspace_label(agent_or_path)
        if agent_or_path.is_a?(Hash) && !agent_or_path.fetch("id", nil).to_s.empty?
          agent_or_path.fetch("id").to_s
        else
          "worker workspace"
        end
      end

      def spawn_process(argv, workspace_path)
        spawn.call(
          env,
          *argv,
          chdir: workspace_path,
          in: File::NULL,
          out: File::NULL,
          err: File::NULL,
          pgroup: true
        )
      end

      def wait_for_immediate_exit(pid)
        deadline = monotonic_time + IMMEDIATE_EXIT_TIMEOUT
        loop do
          waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
          return status if waited_pid
          return nil if monotonic_time >= deadline

          sleep POLL_INTERVAL
        end
      rescue Errno::ECHILD
        nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
