# frozen_string_literal: true

module Meringue
  module Workspace
    # Adapter used by the focused agent workspace UI. It coordinates UI-owned
    # shell/editor processes and the native Pi PTY; the kernel service owns the
    # session handoff and transport state, not this renderer/controller.
    class Controller
      def self.from_config(config, env: ENV, focus_session_service: nil)
        new(
          terminal_manager: TerminalManager.from_config(config, env: env),
          editor_launcher: EditorLauncher.from_config(config, env: env),
          focus_session_service: focus_session_service
        )
      end

      def initialize(terminal_manager: TerminalManager.new, editor_launcher: EditorLauncher.new, focus_session_service: nil, interactive_session_factory: nil)
        @terminal_manager = terminal_manager
        @editor_launcher = editor_launcher
        @focus_session_service = focus_session_service
        @interactive_session_factory = interactive_session_factory || lambda { |command:, env:| TerminalSession.new(command: command, env: env || ENV) }
        @screens = {}
        @interactive_sessions = {}
        @interactive_screens = {}
        @mutex = Mutex.new
      end

      def open_workspace(agent:, state: nil, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS)
        resolution = PathResolver.resolve(agent)
        path = resolution.fetch("path", nil)
        return rejected(resolution.fetch("message", "Selected worker has no assigned workspace.")) unless path

        unless focus_session_service && agent.fetch("harness", nil).to_s == "pi"
          return { "status" => "opened", "message" => "Focused #{agent.fetch("id", "worker")} in #{path}." }
        end

        transition = focus_session_service.begin_agent_interactive_focus(agent.fetch("id"))
        return transition unless transition.fetch("status", nil) == "accepted"

        command = transition.dig("result", "interactive_argv")
        unless command.is_a?(Array) && command.any?
          rollback = focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return rollback if rollback && rollback.fetch("status", nil) != "accepted"

          return failed("The Pi interactive handoff did not return a launch command.")
        end

        session = interactive_session_factory.call(command: command, env: transition.dig("result", "interactive_env"))
        started = nil
        start_callback = lambda do |pid|
          started = focus_session_service.mark_agent_interactive_focus_started(agent.fetch("id"), pid: pid)
        rescue StandardError => e
          started = failed("Could not claim native Pi focus: #{e.message}")
        end
        result = session.start(workspace_path: path, rows: rows, columns: columns, on_started: start_callback)
        unless result.fetch("status", nil).to_s == "active"
          session.close
          rollback = focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return rollback if rollback && rollback.fetch("status", nil) != "accepted"

          return result
        end
        if started && started.fetch("status", nil) != "accepted"
          session.close
          rollback = focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return rollback if rollback && rollback.fetch("status", nil) != "accepted"

          return started
        end

        key = agent_key(agent)
        @mutex.synchronize do
          @interactive_sessions[key] = { "agent" => agent.dup, "session" => session }
          @interactive_screens[key] = TerminalScreen.new(rows: rows, columns: columns)
        end
        started ||= focus_session_service.mark_agent_interactive_focus_started(agent.fetch("id"), pid: result.fetch("pid", nil))
        unless started.fetch("status", nil) == "accepted"
          close_interactive(agent)
          rollback = focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return rollback if rollback && rollback.fetch("status", nil) != "accepted"

          return started
        end
        result.merge("interactive" => true, "message" => "Opened native Pi focus for #{agent.fetch("id", "worker")} in #{path}.")
      rescue StandardError => e
        begin
          session.close if defined?(session) && session
        rescue StandardError
          nil
        end
        rollback = focus_session_service&.end_agent_interactive_focus(agent.fetch("id")) if defined?(agent) && agent
        return rollback if rollback && rollback.fetch("status", nil) != "accepted"

        failed("Could not open native Pi focus: #{e.message}")
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

      def handle_agent_key(key:, agent:, state: nil)
        entry = interactive_entry(agent)
        return failed("Native Pi focus is not running for this worker.") unless entry
        return { "status" => "ignored" } unless entry.fetch("session").alive?

        bytes = terminal_key_bytes(key)
        return { "status" => "ignored" } if bytes.nil? || bytes.empty?

        entry.fetch("session").write(bytes)
      end

      def agent_snapshot(agent:, state: nil, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS)
        entry = interactive_entry(agent)
        return { "interactive" => false } unless entry

        session = entry.fetch("session")
        screen = interactive_screen(agent, rows: rows, columns: columns)
        screen.feed(session.drain_output)
        status = session.status
        {
          "interactive" => true,
          "lines" => screen.lines,
          "styled_lines" => screen.styled_lines,
          "cursor" => screen.cursor,
          "status" => status.fetch("state", nil),
          "pid" => status.fetch("pid", nil),
          "workspace_path" => status.fetch("workspace_path", nil),
          "revision" => screen.revision,
          "notice" => interactive_notice(status)
        }.compact
      end

      def resize_agent(agent:, rows:, columns:)
        entry = interactive_entry(agent)
        return failed("Native Pi focus is not running for this worker.") unless entry

        result = entry.fetch("session").resize(rows: rows, columns: columns)
        interactive_screen(agent, rows: rows, columns: columns).resize(rows: rows, columns: columns) unless failed_result?(result)
        result
      end

      def close_workspace(agent:)
        entry = interactive_entry(agent)
        agent_id = agent.is_a?(Hash) ? agent.fetch("id") : agent.to_s
        unless entry
          # The PTY is removed before dashboard reattachment. If that reattachment failed, a later
          # close/return action must still be able to retry the durable `resume_failed` handoff.
          resume = focus_session_service&.end_agent_interactive_focus(agent_id)
          return resume unless resume.nil? || resume.fetch("status", nil) == "accepted"

          return { "status" => "closed", "message" => resume ? "Resumed the dashboard session." : "No native Pi focus was running." }
        end

        result = close_interactive(agent)
        resume = focus_session_service&.end_agent_interactive_focus(agent_id)
        return result unless resume
        return resume unless resume.fetch("status", nil) == "accepted"

        result.merge("message" => "Closed native Pi focus and resumed the dashboard session.")
      end

      def agent_interactive?(agent:)
        !interactive_entry(agent).nil?
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
          "pid" => status.fetch("pid", nil),
          "workspace_path" => status.fetch("workspace_path", nil),
          # Renderers reuse cached terminal lines while this does not change.
          "revision" => screen.revision
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
        interactive_agents = @mutex.synchronize { @interactive_sessions.values.map { |entry| entry.fetch("agent") } }
        interactive_agents.each { |agent| close_workspace(agent: agent) }
        @mutex.synchronize do
          @screens.clear
          @interactive_screens.clear
          @interactive_sessions.clear
        end
        terminal_manager.close_all
      end
      alias shutdown close

      private

      attr_reader :terminal_manager, :editor_launcher, :focus_session_service, :interactive_session_factory

      def interactive_entry(agent)
        @mutex.synchronize { @interactive_sessions[agent_key(agent)] }
      end

      def interactive_screen(agent, rows: TerminalScreen::DEFAULT_ROWS, columns: TerminalScreen::DEFAULT_COLUMNS)
        key = agent_key(agent)
        @mutex.synchronize do
          screen = (@interactive_screens[key] ||= TerminalScreen.new(rows: rows, columns: columns))
          screen.resize(rows: rows, columns: columns)
          screen
        end
      end

      def close_interactive(agent)
        key = agent_key(agent)
        entry = @mutex.synchronize { @interactive_sessions.delete(key) }
        return { "status" => "closed", "message" => "Native Pi focus was already stopped." } unless entry

        @mutex.synchronize { @interactive_screens.delete(key) }
        session = entry.fetch("session")
        # Leaving focus is a handoff too: ask Pi to abort its current interactive turn before
        # terminating the PTY so the persisted session is settled before RPC reattaches.
        begin
          session.write("\u0003") if session.alive?
        rescue StandardError
          nil
        end
        session.close
      end

      def interactive_notice(status)
        return nil if status.fetch("alive", false)
        return "Pi interactive session exited. Returning to the dashboard will attempt session recovery." if status.fetch("state", nil) == "exited"

        nil
      end

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
        PathResolver.path_for(agent)
      end

      # Deliberately pass-through, including for large pastes. This is not a
      # Meringue composer: the bytes go to a child program in a PTY (a shell, or
      # Pi itself), and that program owns how it echoes, collapses, or submits a
      # paste. Substituting a "[paste #1 ...]" placeholder here would send the
      # placeholder text to the child instead of the pasted content, and the
      # rendering cost belongs to the child's screen, which the TerminalScreen
      # already bounds to its scrollback.
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
