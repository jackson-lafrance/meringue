# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The workspace snapshot the overlay renders from, and persisting the parts of it that\nsurvive a restart.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def complete_pending_workspace_closes
        results = @chat_mutex.synchronize do
          pending = @agent_workspace_close_results
          @agent_workspace_close_results = []
          pending
        end
        failed = results.reverse.find do |result|
          %w[failed rejected errored].include?(result.fetch("status", nil).to_s)
        end
        return unless failed

        set_selection_status(failed.fetch("message", "Could not restore dashboard session ownership."))
      end

      def complete_pending_workspace_open(state)
        pending = @chat_mutex.synchronize do
          result = @agent_workspace_open_result
          @agent_workspace_open_result = nil
          result
        end
        return unless pending

        open_generation, agent_id, result = pending
        return unless @agent_workspace_open_pending && open_generation == @agent_workspace_open_generation && agent_id == @agent_workspace_agent_id.to_s

        @agent_workspace_open_pending = false
        apply_workspace_controller_result(result)
        if %w[failed rejected errored cancelled].include?(result.fetch("status", nil).to_s)
          message = result.fetch("message", "Could not open focused workspace.").to_s
          set_selection_status(message)
          @agent_workspace_active = false
          @agent_workspace_interactive = false
          @focused_pane = @agent_workspace_return_pane
          @agent_tree_navigation_active = false
          @force_full_redraw = true
          persist_agent_workspace
          return
        end

        agent = agent_workspace_agent(state)
        unless agent
          @agent_workspace_active = false
          @focused_pane = @agent_workspace_return_pane
          @agent_tree_navigation_active = false
          @force_full_redraw = true
          persist_agent_workspace
          return
        end
        @agent_workspace_interactive = result.fetch("interactive", false)
        if @agent_workspace_interactive
          @focused_pane = "logs"
          @agent_tree_navigation_active = false
          @agent_workspace_terminal_size = nil
        else
          @focused_pane = "agent_tree"
          @agent_tree_navigation_active = true
        end
        open_agent_workspace_session(agent) unless @agent_workspace_interactive
        if @agent_workspace_view == "terminal"
          @agent_workspace_session.pause if !@agent_workspace_interactive && @agent_workspace_session&.respond_to?(:pause)
          prepare_workspace_terminal(state)
        end
        persist_agent_workspace
      end

      def agent_workspace_snapshot(state, input_buffer, input_cursor, slash_suggestion_index = NO_SLASH_SELECTION)
        expire_workspace_leader!
        complete_pending_workspace_open(state)
        snapshot = @chat_mutex.synchronize do
          {
            "active" => @agent_workspace_active,
            "agent_id" => @agent_workspace_agent_id,
            "interactive" => @agent_workspace_interactive,
            "embedded" => embedded_agent_workspace?,
            "opening" => @agent_workspace_open_pending,
            "view" => @agent_workspace_view,
            "filter" => @agent_workspace_filter,
            "input_buffer" => input_buffer,
            "input_cursor" => clamp_cursor(input_buffer, input_cursor || input_buffer.to_s.length),
            "pending_count" => @agent_workspace_pending_count,
            "leader_hint" => workspace_leader_help,
            "leader_label" => workspace_leader_label,
            "leader_commands" => workspace_leader_commands,
            "leader_pending" => @workspace_leader_pending,
            "slash_suggestion_index" => slash_suggestion_index.to_i,
            "slash_suggestions" => workspace_command_suggestion_records(input_buffer),
            "scroll_offset" => @agent_workspace_view == "terminal" ? @workspace_terminal_scroll_offset.to_i : @workspace_agent_scroll_offset.to_i,
            "messages" => @agent_workspace_messages[@agent_workspace_agent_id.to_s].map(&:dup),
            "notice" => @agent_workspace_notice,
            "error" => @agent_workspace_error,
            "persistence_error" => @workspace_persistence_error
          }.compact
        end
        if @agent_workspace_active
          terminal_view = @agent_workspace_view == "terminal"
          live = terminal_view ? terminal_workspace_snapshot(state) : live_agent_workspace_snapshot(state)
          snapshot[terminal_view ? "terminal" : "agent_session"] = live
          revision = workspace_content_revision(snapshot, live)
          snapshot["content_revision"] = revision if revision
          clamp_agent_workspace_scroll_snapshot!(state, snapshot)
        end
        snapshot
      end

      # Keep the durable workspace offset bounded against the same content and
      # viewport that Layout will draw. This preserves a user's position across
      # live updates while preventing a narrower resize from leaving a stale
      # offset that jumps back into view when more output arrives.
      def clamp_agent_workspace_scroll_snapshot!(state, snapshot)
        composed = state.merge("_agent_workspace" => snapshot)
        maximum = agent_workspace_scroll_max(composed)
        variable = @agent_workspace_view == "terminal" ? :@workspace_terminal_scroll_offset : :@workspace_agent_scroll_offset
        current = instance_variable_get(variable).to_i
        maximum = maximum.to_i if maximum.respond_to?(:finite?) && maximum.finite?
        offset = maximum.is_a?(Integer) ? current.clamp(0, maximum) : current
        instance_variable_set(variable, offset)
        snapshot["scroll_offset"] = offset
      rescue StandardError
        snapshot["scroll_offset"] = instance_variable_get(variable).to_i if variable
      end

      # Cheap signature of everything the focused workspace renders. Panes reuse
      # composed lines while it is unchanged, so scrolling never repeats a full
      # transcript or terminal re-layout.
      def workspace_content_revision(snapshot, live)
        return nil unless live.is_a?(Hash)

        revision = live.fetch("revision", nil)
        return nil if revision.nil?

        [
          revision,
          live.fetch("error", nil).to_s,
          live.fetch("notice", nil).to_s,
          live.fetch("warning", nil).to_s,
          live.fetch("availability", nil).to_s,
          live.fetch("session_state", nil).to_s,
          live.fetch("status", nil).to_s,
          @chat_mutex.synchronize { @agent_workspace_events_revision[@agent_workspace_agent_id.to_s] },
          Array(snapshot.fetch("messages", [])).length,
          snapshot.fetch("notice", nil).to_s,
          snapshot.fetch("error", nil).to_s,
          snapshot.fetch("persistence_error", nil).to_s
        ]
      end

      def persisted_agent_workspace_snapshot
        {
          "selected_agent_id" => @agent_workspace_agent_id,
          "view" => @agent_workspace_view,
          "filter" => @agent_workspace_filter,
          "draft" => @workspace_draft.to_s,
          "agent_scroll_offset" => @workspace_agent_scroll_offset.to_i,
          "terminal_scroll_offset" => @workspace_terminal_scroll_offset.to_i
        }
      end

      def remember_workspace_agent(state, agent_id)
        worker = Array(state.fetch("agents", [])).find do |agent|
          agent.is_a?(Hash) && agent["type"].to_s == "worker" && agent["id"].to_s == agent_id.to_s
        end
        return false unless worker
        return true if @agent_workspace_agent_id.to_s == worker.fetch("id").to_s

        @agent_workspace_agent_id = worker.fetch("id")
        @agent_workspace_view = "agent"
        @agent_workspace_filter = "all"
        @workspace_agent_scroll_offset = 0
        @workspace_terminal_scroll_offset = 0
        @workspace_draft = ""
        # AgentTree movement is a transient filtering gesture. Remember the worker
        # immediately in memory, but do not make the click wait for Store to load,
        # lock, and rewrite the complete orchestration snapshot.
        persist_agent_workspace(deferred: true)
        true
      end

      def reconcile_workspace_selection!(state)
        return if @agent_workspace_agent_id.to_s.empty?
        current = Array(state.fetch("agents", [])).find do |agent|
          agent.is_a?(Hash) && %w[worker head].include?(agent["type"].to_s) && agent["id"].to_s == @agent_workspace_agent_id.to_s
        end
        if current
          status = current.fetch("status", nil).to_s
          return unless %w[completed killed].include?(status)
          # A completed worker is already terminal when native focus begins. Keep its pending or
          # active harness PTY alive; treating that pre-existing status as a new settle cancels the
          # handoff on the next frame and immediately resumes the dashboard session.
          return if status == "completed" && embedded_agent_workspace?
        end

        was_embedded = embedded_agent_workspace?
        if @agent_workspace_open_pending && workspace_controller&.respond_to?(:cancel_workspace_open)
          workspace_controller.cancel_workspace_open(agent: @agent_workspace_agent_id)
        elsif @agent_workspace_interactive && workspace_controller
          # Reconciliation can remove the pane, but it must not settle an active focused turn.
          if workspace_controller.respond_to?(:detach_workspace)
            workspace_controller.detach_workspace(agent: @agent_workspace_agent_id)
          else
            close_interactive_agent_workspace(@agent_workspace_agent_id)
          end
        else
          close_agent_workspace_session
        end
        @chat_mutex.synchronize { @agent_workspace_open_result = nil }
        @agent_workspace_open_pending = false
        @agent_workspace_open_generation += 1
        @force_full_redraw = true if @agent_workspace_active
        @agent_workspace_interactive = false
        @agent_workspace_active = false
        @focused_pane = @agent_workspace_return_pane if was_embedded
        @agent_tree_navigation_active = false if was_embedded
        @agent_workspace_agent_id = nil
        @agent_workspace_view = "agent"
        @agent_workspace_filter = "all"
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @workspace_draft = ""
        persist_agent_workspace(deferred: true)
      end

      # Saving rewrites the whole state file, so high-frequency presentation
      # changes only mark the workspace dirty. The run loop flushes on a slow,
      # bounded cadence, while opening/closing a workspace and shutdown still
      # persist immediately.
      def persist_agent_workspace(deferred: false)
        return unless log_store&.respond_to?(:save_agent_workspace)

        if deferred
          # Start the bounded flush window with the first dirty change. Without
          # this, a process whose last write was long ago flushes immediately on
          # the next loop and merely moves the blocking rewrite one frame later.
          @workspace_persisted_at = monotonic_time unless @workspace_persist_dirty
          @workspace_persist_dirty = true
          return nil
        end

        @workspace_persist_dirty = false
        @workspace_persisted_at = monotonic_time
        persisted = log_store.save_agent_workspace(persisted_agent_workspace_snapshot)
        @workspace_persistence_error = nil
        persisted
      rescue StandardError => e
        @workspace_persistence_error = "Workspace selection could not be saved: #{e.message}"
        nil
      end

      def flush_deferred_agent_workspace_persistence
        return unless @workspace_persist_dirty
        return if monotonic_time - @workspace_persisted_at < WORKSPACE_PERSIST_INTERVAL

        persist_agent_workspace
      end

      def live_agent_workspace_snapshot(state)
        agent = agent_workspace_agent(state)
        return { "error" => "Selected worker is no longer available." } unless agent

        result = if @agent_workspace_interactive && workspace_controller&.respond_to?(:agent_snapshot)
                   resize_agent_workspace_interactive(agent, state)
                   rows, columns = agent_workspace_terminal_dimensions(state)
                   workspace_controller.agent_snapshot(agent: agent, state: state, rows: rows, columns: columns)
                 elsif @agent_workspace_session&.respond_to?(:snapshot)
                   snapshot = @agent_workspace_session.snapshot
                   polled = @agent_workspace_session.respond_to?(:poll_events) ? @agent_workspace_session.poll_events(limit: 200) : {}
                   reduce_agent_workspace_events(agent.fetch("id"), Array(polled["events"]))
                   snapshot.merge(
                     "events" => frozen_agent_workspace_events(agent.fetch("id")),
                     "event_gap" => !!polled["gap"],
                     "warning" => polled["gap"] ? "Some transient live events expired; the transcript was refreshed from the managed session." : snapshot["warning"]
                   ).compact
                 elsif workspace_controller&.respond_to?(:agent_snapshot)
                   workspace_controller.agent_snapshot(agent: agent, state: state)
                 elsif workspace_controller&.respond_to?(:snapshot)
                   workspace_controller.snapshot(agent: agent, state: state, view: "agent")
                 else
                   {}
                 end
        result.is_a?(Hash) ? stringify_workspace_snapshot(result) : {}
      rescue StandardError => e
        { "error" => "Could not read worker session: #{e.message}" }
      end

      # Renders from one frozen copy per change instead of duplicating every
      # retained event on every frame.
      def frozen_agent_workspace_events(agent_id)
        key = agent_id.to_s
        @chat_mutex.synchronize do
          revision = @agent_workspace_events_revision[key]
          cached = @agent_workspace_events_cache[key]
          return cached.fetch("events") if cached && cached.fetch("revision") == revision

          events = @agent_workspace_events[key].map { |event| deep_freeze_workspace_value(event) }.freeze
          @agent_workspace_events_cache[key] = { "revision" => revision, "events" => events }
          events
        end
      end

      def deep_freeze_workspace_value(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), copy| copy[key.to_s] = deep_freeze_workspace_value(child) }.freeze
        when Array
          value.map { |child| deep_freeze_workspace_value(child) }.freeze
        when String
          value.frozen? ? value : value.dup.freeze
        else
          value
        end
      end

      def reduce_agent_workspace_events(agent_id, events)
        return if events.empty?

        @chat_mutex.synchronize do
          @agent_workspace_events_revision[agent_id.to_s] += 1
          retained = @agent_workspace_events[agent_id.to_s]
          events.each do |event|
            next unless event.is_a?(Hash)

            identity = [event["kind"], event["id"] || event["tool_call_id"]]
            replace_at = identity.last && retained.index do |candidate|
              [candidate["kind"], candidate["id"] || candidate["tool_call_id"]] == identity
            end
            if replace_at
              retained[replace_at] = event
            else
              retained << event
            end
          end
          retained.shift(retained.length - 300) if retained.length > 300
        end
      end

      def terminal_workspace_snapshot(state)
        agent = agent_workspace_agent(state)
        return { "error" => "Selected worker is no longer available.", "lines" => [] } unless agent
        return { "error" => "The worktree terminal is unavailable.", "lines" => [] } unless workspace_controller

        resize_agent_workspace_terminal(agent, state)
        result = if workspace_controller.respond_to?(:terminal_snapshot)
                   workspace_controller.terminal_snapshot(agent: agent, state: state)
                 elsif workspace_controller.respond_to?(:snapshot)
                   workspace_controller.snapshot(agent: agent, state: state, view: "terminal")
                 else
                   { "error" => "The worktree terminal is unavailable.", "lines" => [] }
                 end
        result.is_a?(Hash) ? stringify_workspace_snapshot(result) : { "lines" => Array(result).map(&:to_s) }
      rescue StandardError => e
        { "error" => "Could not read terminal: #{e.message}", "lines" => [] }
      end

      # Frozen values already come from a normalized, string-keyed snapshot, so
      # they are shared instead of rebuilt. That keeps a long transcript off the
      # per-frame path while scrolling.
      def stringify_workspace_snapshot(value)
        return value if value.frozen? && (value.is_a?(Hash) || value.is_a?(Array))

        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[key.to_s] = stringify_workspace_snapshot(child) }
        when Array
          value.map { |child| stringify_workspace_snapshot(child) }
        else
          value
        end
      end

      # A pruned, killed, or renumbered node stops filtering instead of hiding
      # every log line.
      def reconcile_log_scope!(state)
        return unless log_scope_active?
        return if LogScope.selectable?(state, @log_scope_id)

        clear_log_scope
      end

      def agent_tree_navigation_snapshot
        focused_agent_id = embedded_agent_workspace? ? @agent_workspace_agent_id : nil
        selected_agent_id = focused_agent_id || (@agent_tree_navigation_active ? @selected_agent_id : nil)
        {
          "active" => @agent_tree_navigation_active,
          "mode" => @agent_tree_navigation_active ? @agent_tree_navigation_mode.to_s : nil,
          "selected_agent_id" => selected_agent_id
        }
      end

      def scroll_snapshot
        {
          "active_pane" => @focused_pane,
          "offsets" => @scroll_offsets.to_h
        }
      end
    end
  end
end
