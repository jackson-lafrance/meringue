# frozen_string_literal: true

module Meringue
  module Workspace
    # Adapter used by the focused agent workspace UI. It coordinates UI-owned
    # shell, editor, and focused harness processes; the kernel service owns the
    # session handoff and transport state, not this renderer/controller.
    class Controller
      def self.from_config(config, env: ENV, focus_session_service: nil, session_environment_patterns: [])
        new(
          terminal_manager: TerminalManager.from_config(
            config,
            env: env,
            session_environment_patterns: session_environment_patterns
          ),
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
        @pending_interactive_opens = {}
        @pending_interactive_closes = {}
        @mutex = Mutex.new
      end

      # Starts a workspace transition without making the TUI input/render thread wait for a
      # harness handoff. An agent session may need to abort an active turn and wait for its
      # transport, so that work belongs on a controller-owned thread.
      def open_workspace_async(agent:, state: nil, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS, &callback)
        key = agent_key(agent)
        operation = { "cancelled" => false }
        @mutex.synchronize { @pending_interactive_opens[key] = operation }
        Thread.new do
          result = open_workspace(
            agent: agent,
            state: state,
            rows: rows,
            columns: columns,
            cancellation: -> { @mutex.synchronize { operation.fetch("cancelled") } }
          )
          callback.call(result) if callback
        ensure
          @mutex.synchronize do
            @pending_interactive_opens.delete(key) if @pending_interactive_opens[key].equal?(operation)
          end
        end
        {
          "status" => "pending",
          "message" => "Preparing focused workspace for #{agent.fetch("id", "worker")}…",
          "pending" => true
        }
      end

      # Returning ownership can wait for the focused harness process to settle, stop its PTY, and
      # restore dashboard transport. Keep that bounded work off the TUI input/render thread while
      # the durable kernel handoff marker continues enforcing one writer.
      def close_workspace_async(agent:, &callback)
        key = agent_key(agent)
        operation = nil
        start_operation = false
        @mutex.synchronize do
          operation = @pending_interactive_closes[key]
          if operation
            operation.fetch("callbacks") << callback if callback
          else
            operation = { "callbacks" => callback ? [callback] : [], "thread" => nil }
            @pending_interactive_closes[key] = operation
            start_operation = true
          end
        end
        return pending_workspace_close(agent) unless start_operation

        @mutex.synchronize do
          # Creating and registering the thread under the same lock means shutdown can never see a
          # close reservation without the thread it must join. The thread blocks on this mutex when
          # it first looks up the interactive entry, so it cannot finish before registration.
          thread = Thread.new do
            Thread.current.name = "meringue-interactive-focus-close" if Thread.current.respond_to?(:name=)
            result = begin
              close_workspace(agent: agent)
            rescue StandardError => e
              failed("Could not close the focused agent session: #{e.message}")
            end
            callbacks = @mutex.synchronize do
              @pending_interactive_closes.delete(key) if @pending_interactive_closes[key].equal?(operation)
              operation.fetch("callbacks").dup
            end
            callbacks.each do |registered|
              registered.call(result)
            rescue StandardError
              nil
            end
          end
          operation["thread"] = thread
        end
        pending_workspace_close(agent)
      end

      def interactive_close_pending?(agent:)
        @mutex.synchronize { @pending_interactive_closes.key?(agent_key(agent)) }
      end

      def cancel_workspace_open(agent:)
        key = agent_key(agent)
        pending = @mutex.synchronize { @pending_interactive_opens[key] }
        return { "status" => "closed", "message" => "No workspace opening was pending." } unless pending

        @mutex.synchronize { pending["cancelled"] = true }
        { "status" => "cancelled", "message" => "Cancelled focused workspace opening." }
      end

      # How the selected worker's backend can be focused. The pane asks this instead of checking
      # which harness the worker runs on, so a new backend needs no UI change.
      def focus_mode(agent:)
        return "none" unless focus_session_service && agent.is_a?(Hash)
        # A focus service that predates the capability question can still hand off, which is the
        # only thing it ever could do. Treating it as "no focus" would silently disable the
        # feature instead of surfacing the mismatch.
        return "handoff" unless focus_session_service.respond_to?(:agent_focus_mode)

        focus_session_service.agent_focus_mode(agent.fetch("id", nil)).to_s
      rescue StandardError
        "none"
      end

      def open_workspace(agent:, state: nil, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS, cancellation: nil)
        resolution = PathResolver.resolve(agent)
        path = resolution.fetch("path", nil)
        return rejected(resolution.fetch("message", "Selected worker has no assigned workspace.")) unless path
        return { "status" => "opened", "message" => "Focused #{agent.fetch("id", "worker")} in #{path}." } unless focus_session_service

        case focus_mode(agent: agent)
        when "live_terminal"
          open_live_terminal(agent: agent, path: path, rows: rows, columns: columns, cancellation: cancellation)
        when "handoff"
          open_handoff_workspace(agent: agent, path: path, rows: rows, columns: columns, cancellation: cancellation)
        else
          { "status" => "opened", "message" => "Focused #{agent.fetch("id", "worker")} in #{path}." }
        end
      end

      # Attaching to a session that is already running interactively. There is no transport to
      # settle and no process to launch, so there is also nothing to roll back: if the attach is
      # cancelled or refused, the worker is left exactly as it was, still working.
      def open_live_terminal(agent:, path:, rows:, columns:, cancellation: nil)
        return cancelled_workspace if cancellation_requested?(cancellation)

        attach = focus_session_service.attach_agent_live_terminal(agent.fetch("id"), rows: rows, columns: columns)
        return attach unless attach.fetch("status", nil) == "accepted"

        terminal = attach.dig("result", "terminal")
        unless terminal
          detach_live_terminal(agent.fetch("id"))
          return failed("The agent backend reported a live session but did not return a terminal to attach to.")
        end

        if cancellation_requested?(cancellation)
          detach_live_terminal(agent.fetch("id"))
          return cancelled_workspace
        end

        key = agent_key(agent)
        @mutex.synchronize do
          @interactive_sessions[key] = { "agent" => agent.dup, "session" => terminal, "mode" => "live_terminal" }
        end
        {
          "status" => "active",
          "interactive" => true,
          "pid" => terminal.respond_to?(:pid) ? terminal.pid : nil,
          "workspace_path" => path,
          "message" => "Opened the live agent session for #{agent.fetch("id", "worker")} in #{path}."
        }.compact
      rescue StandardError => e
        begin
          detach_live_terminal(agent.fetch("id"))
        rescue StandardError
          nil
        end
        failed("Could not attach to the live agent session: #{e.message}")
      end

      def open_handoff_workspace(agent:, path:, rows:, columns:, cancellation: nil)
        return cancelled_workspace if cancellation_requested?(cancellation)

        transition = focus_session_service.begin_agent_interactive_focus(agent.fetch("id"))
        return transition unless transition.fetch("status", nil) == "accepted"
        if cancellation_requested?(cancellation)
          focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return cancelled_workspace
        end

        command = transition.dig("result", "interactive_argv")
        unless command.is_a?(Array) && command.any?
          rollback = focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return rollback if rollback && rollback.fetch("status", nil) != "accepted"

          return failed("The Agent session handoff did not return a launch command.")
        end
        # Harnesses may resolve their executable using provider-specific install
        # knowledge (for example a package-manager bin directory that is absent
        # from a GUI-launched app's PATH). Keep the argv contract for older
        # integrations, but replace only the executable when the backend supplies
        # that authoritative path. [workspace] shell_command remains exclusively
        # the worktree-terminal override.
        executable = transition.dig("result", "interactive_executable")
        command = [executable.to_s, *command.drop(1)] if executable && !executable.to_s.empty?

        session = interactive_session_factory.call(command: command, env: transition.dig("result", "interactive_env"))
        started = nil
        start_callback = lambda do |pid|
          started = focus_session_service.mark_agent_interactive_focus_started(agent.fetch("id"), pid: pid)
        rescue StandardError => e
          started = failed("Could not claim the Agent session: #{e.message}")
        end
        result = session.start(workspace_path: path, rows: rows, columns: columns, on_started: start_callback)
        if cancellation_requested?(cancellation)
          session.close
          focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return cancelled_workspace
        end
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
          @interactive_sessions[key] = {
            "agent" => agent.dup,
            "session" => session,
            "mode" => "handoff",
            "shutdown_input" => transition.dig("result", "interactive_shutdown_input")
          }.compact
          @interactive_screens[key] = TerminalScreen.new(rows: rows, columns: columns)
        end
        if cancellation_requested?(cancellation)
          close_interactive(agent)
          focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return cancelled_workspace
        end
        started ||= focus_session_service.mark_agent_interactive_focus_started(agent.fetch("id"), pid: result.fetch("pid", nil))
        unless started.fetch("status", nil) == "accepted"
          close_interactive(agent)
          rollback = focus_session_service.end_agent_interactive_focus(agent.fetch("id"))
          return rollback if rollback && rollback.fetch("status", nil) != "accepted"

          return started
        end
        result.merge("interactive" => true, "message" => "Opened Agent session for #{agent.fetch("id", "worker")} in #{path}.")
      rescue StandardError => e
        begin
          session.close if defined?(session) && session
        rescue StandardError
          nil
        end
        rollback = focus_session_service&.end_agent_interactive_focus(agent.fetch("id")) if defined?(agent) && agent
        return rollback if rollback && rollback.fetch("status", nil) != "accepted"

        failed("Could not open Agent session: #{e.message}")
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
        return failed("Agent session is not running for this worker.") unless entry
        return { "status" => "ignored" } unless entry.fetch("session").alive?

        bytes = agent_key_bytes(key)
        return { "status" => "ignored" } if bytes.nil? || bytes.empty?

        result = entry.fetch("session").write(bytes)
        if prompt_submission_bytes?(bytes) && focus_session_service.respond_to?(:note_agent_interactive_prompt) && !failed_result?(result)
          begin
            focus_session_service.note_agent_interactive_prompt(agent.fetch("id"))
          rescue StandardError
            # The provider already received the key. A notification failure must not turn valid
            # focused input into a terminal error; reconciliation remains the durable fallback.
            nil
          end
        end
        result
      end

      # Releasing a viewer claim is only meaningful for a service that hands them out.
      def detach_live_terminal(agent_id)
        return nil unless focus_session_service.respond_to?(:detach_agent_live_terminal)

        result = focus_session_service.detach_agent_live_terminal(agent_id)
        result if result.is_a?(Hash) && result.fetch("status", nil) == "accepted"
      end

      def live_terminal_entry?(entry)
        entry.is_a?(Hash) && entry.fetch("mode", nil) == "live_terminal"
      end

      def agent_snapshot(agent:, state: nil, rows: TerminalSession::DEFAULT_ROWS, columns: TerminalSession::DEFAULT_COLUMNS)
        entry = interactive_entry(agent)
        return { "interactive" => false } unless entry
        return live_terminal_snapshot(entry, rows: rows, columns: columns) if live_terminal_entry?(entry)

        session = entry.fetch("session")
        screen = interactive_screen(agent, rows: rows, columns: columns)
        screen.feed(session.drain_output)
        status = session.status
        rendered = screen.render_snapshot
        {
          "interactive" => true,
          "lines" => rendered.fetch("lines"),
          "styled_lines" => rendered.fetch("styled_lines"),
          "cursor" => rendered.fetch("cursor"),
          "status" => status.fetch("state", nil),
          "pid" => status.fetch("pid", nil),
          "workspace_path" => status.fetch("workspace_path", nil),
          "revision" => rendered.fetch("revision"),
          "notice" => interactive_notice(status)
        }.compact
      end

      # The backend keeps this session's screen current whether or not anyone is watching, so
      # attaching renders the agent's real current state immediately rather than an empty pane that
      # fills in as new output happens to arrive.
      def live_terminal_snapshot(entry, rows:, columns:)
        snapshot = entry.fetch("session").snapshot(rows: rows, columns: columns)
        {
          "interactive" => true,
          "lines" => snapshot.fetch("lines", []),
          "styled_lines" => snapshot.fetch("styled_lines", nil),
          "cursor" => snapshot.fetch("cursor", nil),
          "status" => snapshot.fetch("state", nil),
          "pid" => snapshot.fetch("pid", nil),
          "workspace_path" => snapshot.fetch("workspace_path", nil),
          "revision" => snapshot.fetch("revision", nil),
          "notice" => live_terminal_notice(snapshot)
        }.compact
      end

      def live_terminal_notice(snapshot)
        return nil if snapshot.fetch("alive", false)

        "The agent session process has exited. Returning to the dashboard will attempt to resume it."
      end

      def resize_agent(agent:, rows:, columns:)
        entry = interactive_entry(agent)
        return failed("Agent session is not running for this worker.") unless entry

        result = entry.fetch("session").resize(rows: rows, columns: columns)
        # A live session owns its own screen, so there is no controller-side screen to keep in step.
        return result if live_terminal_entry?(entry)

        interactive_screen(agent, rows: rows, columns: columns).resize(rows: rows, columns: columns) unless failed_result?(result)
        result
      end

      def close_workspace(agent:)
        entry = interactive_entry(agent)
        agent_id = agent.is_a?(Hash) ? agent.fetch("id") : agent.to_s
        live = live_terminal_entry?(entry)
        unless entry
          return cancel_workspace_open(agent: agent) if pending_interactive_open?(agent)

          # The PTY is removed before dashboard reattachment. If that reattachment failed, a later
          # close/return action must still be able to retry the durable `resume_failed` handoff.
          detached = detach_live_terminal(agent_id)
          return detached if detached && detached.fetch("target_id", nil)

          resume = focus_session_service&.end_agent_interactive_focus(agent_id)
          return resume unless resume.nil? || resume.fetch("status", nil) == "accepted"

          return { "status" => "closed", "message" => resume ? "Resumed the dashboard session." : "No Agent session was running." }
        end

        result = close_interactive(agent)
        # Returning from a live session only releases the viewer's claim. There is no transport to
        # restart, which is why this path cannot leave a worker stranded the way a handoff can.
        if live
          detach_live_terminal(agent_id)
          return result
        end

        resume = focus_session_service&.end_agent_interactive_focus(agent_id)
        return result unless resume
        return resume unless resume.fetch("status", nil) == "accepted"

        result.merge("message" => "Closed Agent session and resumed the dashboard session.")
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
        rendered = screen.render_snapshot
        snapshot = {
          "lines" => rendered.fetch("lines"),
          "styled_lines" => rendered.fetch("styled_lines"),
          "cursor" => rendered.fetch("cursor"),
          "status" => status.fetch("state", nil),
          "pid" => status.fetch("pid", nil),
          "workspace_path" => status.fetch("workspace_path", nil),
          # Renderers reuse cached terminal lines while this does not change.
          "revision" => rendered.fetch("revision")
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

      def edit_text(text:, extension: ".txt")
        editor_launcher.edit_text(text, extension: extension)
      end

      def close_terminal(agent:)
        @mutex.synchronize { @screens.delete(agent_key(agent)) }
        terminal_manager.close(agent)
      end

      def close
        close_threads = @mutex.synchronize do
          @pending_interactive_opens.each_value { |operation| operation["cancelled"] = true }
          @pending_interactive_opens.clear
          @pending_interactive_closes.values.map { |operation| operation.fetch("thread") }
        end
        # A pending return already owns closure for its worker. Join it before enumerating active
        # entries so shutdown cannot race a second PTY close or dashboard reattachment against it.
        close_threads.each { |thread| thread.join unless thread == Thread.current }
        active_agents = @mutex.synchronize do
          @interactive_sessions.values.map { |entry| entry.fetch("agent") }
        end
        active_agents.each { |agent| close_workspace(agent: agent) }
        @mutex.synchronize do
          @screens.clear
          @interactive_screens.clear
          @interactive_sessions.clear
          @pending_interactive_closes.clear
        end
        terminal_manager.close_all
      end
      alias shutdown close

      private

      attr_reader :terminal_manager, :editor_launcher, :focus_session_service, :interactive_session_factory

      def interactive_entry(agent)
        @mutex.synchronize { @interactive_sessions[agent_key(agent)] }
      end

      def pending_interactive_open?(agent)
        @mutex.synchronize { @pending_interactive_opens.key?(agent_key(agent)) }
      end

      def cancellation_requested?(cancellation)
        cancellation && cancellation.call
      end

      def cancelled_workspace
        { "status" => "cancelled", "message" => "Focused workspace opening was cancelled." }
      end

      def pending_workspace_close(agent)
        {
          "status" => "pending",
          "message" => "Returning #{agent_key(agent)} to dashboard ownership…",
          "pending" => true
        }
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
        return { "status" => "closed", "message" => "Agent session was already stopped." } unless entry

        @mutex.synchronize { @interactive_screens.delete(key) }
        # A live session is the worker itself, not a viewer-owned process. Leaving focus drops the
        # view and nothing else: no interrupt, no signal, no close. The worker keeps working.
        if live_terminal_entry?(entry)
          return { "status" => "closed", "message" => "Detached from the live agent session; it is still running." }
        end

        session = entry.fetch("session")
        shutdown_input = entry.fetch("shutdown_input", nil)
        begin
          session.write(shutdown_input) if shutdown_input && session.alive?
        rescue StandardError
          nil
        end
        session.close
      end

      def interactive_notice(status)
        return nil if status.fetch("alive", false)
        return "Agent session exited. Returning to the dashboard will attempt session recovery." if status.fetch("state", nil) == "exited"

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
      # Meringue composer: the bytes go to a child program in a PTY (a shell or
      # focused harness), and that program owns how it echoes, collapses, or submits a
      # paste. Substituting a "[paste #1 ...]" placeholder here would send the
      # placeholder text to the child instead of the pasted content, and the
      # rendering cost belongs to the child's screen, which the TerminalScreen
      # already bounds to its scrollback.
      def prompt_submission_bytes?(bytes)
        bytes == "\r" || bytes == "\n"
      end

      def terminal_key_bytes(key)
        if key.is_a?(Hash)
          return key.fetch("text", "").to_s.tr("\r", "\n") if key.fetch("type", nil) == "paste"
          return mouse_event_bytes(key) if key.fetch("type", nil) == "mouse"

          return nil
        end
        key.is_a?(String) ? key : nil
      end

      # Pi and Claude currently expose page navigation but do not request mouse
      # reporting from their PTYs. Sending a raw SGR report can therefore be
      # ignored or leak into an editor. Translate a coalesced wheel burst to the
      # same PageUp/PageDown bytes as the corresponding keyboard action. Other
      # keys and pastes keep the terminal pass-through contract.
      def agent_key_bytes(key)
        return terminal_key_bytes(key) unless key.is_a?(Hash) && key.fetch("type", nil) == "mouse"

        kind = key.fetch("kind", nil).to_s
        return nil unless %w[wheel_up wheel_down].include?(kind)

        page = kind == "wheel_up" ? "\e[5~" : "\e[6~"
        page * [key.fetch("count", 1).to_i, 1].max
      end

      # The dashboard parser already normalizes mouse input. Re-encode it as
      # SGR mouse input in the embedded PTY's local coordinate system.
      def mouse_event_bytes(event)
        kind = event.fetch("kind", nil).to_s
        return nil unless %w[wheel_up wheel_down].include?(kind)

        button = 64 + (kind == "wheel_down" ? 1 : 0)
        button += 4 if event.fetch("shift", false)
        button += 8 if event.fetch("alt", false)
        button += 16 if event.fetch("ctrl", false)
        count = [event.fetch("count", 1).to_i, 1].max
        x = [event.fetch("x", 1).to_i, 1].max
        y = [event.fetch("y", 1).to_i, 1].max
        sequence = "\e[<#{button};#{x};#{y}M"
        sequence * count
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
