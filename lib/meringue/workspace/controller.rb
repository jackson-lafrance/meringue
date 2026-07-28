# frozen_string_literal: true

module Meringue
  module Workspace
    # Adapter used by the focused agent workspace UI. It coordinates UI-owned
    # shell/editor processes without mutating kernel state or touching the
    # selected worker's managed harness process.
    class Controller
      def self.from_config(config, env: ENV)
        new(
          terminal_manager: TerminalManager.from_config(config, env: env),
          editor_launcher: EditorLauncher.from_config(config, env: env)
        )
      end

      def initialize(terminal_manager: TerminalManager.new, editor_launcher: EditorLauncher.new)
        @terminal_manager = terminal_manager
        @editor_launcher = editor_launcher
        @screens = {}
        @mutex = Mutex.new
      end

      def open_workspace(agent:, state: nil)
        path = workspace_path_for(agent)
        return rejected("Selected worker has no assigned workspace.") unless path
        return rejected("Worker workspace is missing or is not a directory: #{path}") unless Dir.exist?(path)

        { "status" => "opened", "message" => "Focused #{agent.fetch("id", "worker")} in #{path}." }
      end

      def open_terminal(agent:, state: nil, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS)
        existing_session = terminal_manager.fetch(agent)
        restarting = existing_session && !existing_session.alive?
        result = terminal_manager.start(agent, rows: rows, columns: columns)
        unless failed_result?(result)
          @mutex.synchronize { @screens.delete(agent_key(agent)) } if restarting
          ensure_screen(agent, rows: rows, columns: columns).resize(rows: rows, columns: columns)
        end
        result
      end

      def handle_terminal_key(key:, agent:, state: nil)
        session = terminal_manager.fetch(agent)
        return failed("Workspace terminal is not running. Switch back to the terminal view to restart it.") unless session&.alive?

        bytes = terminal_key_bytes(key)
        return { "status" => "ignored" } if bytes.nil? || bytes.empty?

        session.write(bytes)
      end

      def terminal_snapshot(agent:, state: nil)
        session = terminal_manager.fetch(agent)
        return { "lines" => [], "error" => "Workspace terminal is not running. Switch views to restart it." } unless session

        screen = ensure_screen(agent)
        screen.feed(session.drain_output)
        status = session.status
        snapshot = {
          "lines" => screen.lines,
          "styled_lines" => screen.styled_lines,
          "cursor" => screen.cursor,
          "status" => status.fetch("state", nil),
          "pid" => status.fetch("pid", nil)
        }.compact
        if !status.fetch("alive", false) && status.fetch("state", nil) == "exited"
          exit_status = status.fetch("exit_status", {}) || {}
          detail = exit_status["exitstatus"] ? "status #{exit_status["exitstatus"]}" : "signal #{exit_status["termsig"]}"
          snapshot["notice"] = "Workspace shell exited with #{detail}. Switch views to start a new shell."
        end
        snapshot
      end

      def resize_terminal(agent:, rows:, columns:)
        session = terminal_manager.fetch(agent)
        return failed("Workspace terminal is not running, so it cannot be resized.") unless session

        result = session.resize(rows: rows, columns: columns)
        ensure_screen(agent, rows: rows, columns: columns).resize(rows: rows, columns: columns) unless failed_result?(result)
        result
      end

      def open_editor(agent:, state: nil)
        editor_launcher.open(agent)
      end

      def close_terminal(agent:)
        @mutex.synchronize { @screens.delete(agent_key(agent)) }
        terminal_manager.close(agent)
      end

      def close
        @mutex.synchronize { @screens.clear }
        terminal_manager.close_all
      end
      alias shutdown close

      private

      attr_reader :terminal_manager, :editor_launcher

      def ensure_screen(agent, rows: TerminalScreen::DEFAULT_ROWS, columns: TerminalScreen::DEFAULT_COLUMNS)
        key = agent_key(agent)
        @mutex.synchronize do
          @screens[key] ||= TerminalScreen.new(rows: rows, columns: columns)
        end
      end

      def agent_key(agent)
        agent.is_a?(Hash) ? agent.fetch("id", "worker").to_s : agent.to_s
      end

      def workspace_path_for(agent)
        return nil unless agent.is_a?(Hash)

        metadata = agent.fetch("harness_metadata", {}) || {}
        value = agent["workspace_path"] || metadata["cwd"]
        return nil if value.to_s.strip.empty?

        File.expand_path(value.to_s)
      end

      def terminal_key_bytes(key)
        if key.is_a?(Hash)
          return key.fetch("text", "").to_s.tr("\r", "\n") if key.fetch("type", nil) == "paste"

          return nil
        end
        key.is_a?(String) ? key : nil
      end

      def failed_result?(result)
        %w[failed rejected errored].include?(result.fetch("status", nil).to_s)
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
