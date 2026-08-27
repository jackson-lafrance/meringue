# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Opening, restoring, and closing a worker's focused workspace and its harness session.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def open_agent_workspace_by_id(state, item_id)
        return_pane = @focused_pane
        agent = agent_workspace_agent_for_item(state, item_id)
        unless agent
          # Unavailable is an expected state for pending heads and issues that do
          # not have a worker yet. Keep it out of durable/visible logs; an
          # explicit keyboard or /jump attempt gets a short-lived hint instead.
          set_selection_status("#{item_id} has no focused workspace yet")
          return false
        end

        if @agent_workspace_active && @agent_workspace_agent_id.to_s != agent.fetch("id").to_s
          close_agent_workspace
        elsif @agent_workspace_active
          return true
        end

        # Whether this worker's backend has a session to embed is the backend's answer, not a
        # harness name the UI keeps a list of.
        focus_mode = agent_workspace_focus_mode(agent)
        native_focus = focus_mode != "none" && workspace_controller&.respond_to?(:open_workspace)
        restored_view = if native_focus
                          "agent"
                        elsif @agent_workspace_agent_id.to_s == agent.fetch("id").to_s
                          @agent_workspace_view
                        else
                          "agent"
                        end
        # The logs caret belongs to the dashboard logs pane, so opening the
        # focused workspace disarms it instead of leaving Ctrl-C bound to copy.
        deactivate_logs_cursor_quietly
        # The picker overlays are dashboard chrome, so they must not survive
        # into the focused workspace and reappear on return.
        close_delivery_pr_picker
        close_model_picker
        close_question_picker
        @agent_workspace_active = true
        @agent_workspace_interactive = false
        @force_full_redraw = true
        @agent_workspace_agent_id = agent.fetch("id")
        @agent_workspace_return_pane = return_pane
        @agent_workspace_view = restored_view
        @agent_workspace_terminal_size = nil
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @agent_workspace_notice = nil
        @agent_workspace_error = nil
        @agent_workspace_open_generation += 1
        open_generation = @agent_workspace_open_generation
        @chat_mutex.synchronize do
          event_key = agent.fetch("id").to_s
          @agent_workspace_events[event_key] = []
          # A reopened view has a fresh journal cursor and will replay the managed
          # session's retained events. Invalidate the old frozen presentation too;
          # otherwise a worker with no new events can briefly render fragments from
          # the previous focus session instead of the fresh replay.
          @agent_workspace_events_revision[event_key] += 1
          @agent_workspace_events_cache.delete(event_key)
        end
        @selected_agent_id = agent.fetch("id")
        @agent_tree_navigation_active = !native_focus
        @focused_pane = native_focus ? "logs" : "agent_tree"
        if workspace_controller&.respond_to?(:open_workspace)
          rows, columns = agent_workspace_terminal_dimensions(state, embedded: native_focus)
          workspace_result = begin
            if workspace_controller.respond_to?(:open_workspace_async) && focus_mode != "none"
              @agent_workspace_open_pending = true
              @chat_mutex.synchronize { @agent_workspace_open_result = nil }
              workspace_controller.open_workspace_async(
                agent: agent,
                state: state,
                rows: rows,
                columns: columns
              ) do |result|
                @chat_mutex.synchronize do
                  @agent_workspace_open_result = [open_generation, agent.fetch("id").to_s, result]
                end
              end
            else
              workspace_controller.open_workspace(
                agent: agent,
                state: state,
                rows: rows,
                columns: columns
              )
            end
          rescue ArgumentError
            workspace_controller.open_workspace(agent: agent, state: state)
          end
          apply_workspace_controller_result(workspace_result)
          if %w[failed rejected errored].include?(workspace_result.fetch("status", nil).to_s)
            @agent_workspace_open_pending = false
            # The focused pane is about to disappear, so keep its actionable failure visible on the
            # restored dashboard instead of stranding it in @agent_workspace_error.
            message = workspace_result.fetch("message", "Could not open focused workspace.").to_s
            set_selection_status(message)
            @agent_workspace_active = false
            @focused_pane = @agent_workspace_return_pane
            @agent_tree_navigation_active = false
            @force_full_redraw = true
            return false
          end
          if workspace_result.fetch("status", nil).to_s == "pending"
            @agent_workspace_notice = workspace_result.fetch("message", "Preparing focused workspace…")
            persist_agent_workspace
            return true
          end
          @agent_workspace_open_pending = false
          @agent_workspace_interactive = workspace_result.fetch("interactive", false)
          unless @agent_workspace_interactive
            @focused_pane = "agent_tree"
            @agent_tree_navigation_active = true
          end
        end
        open_agent_workspace_session(agent) unless @agent_workspace_interactive
        if @agent_workspace_view == "terminal"
          @agent_workspace_session.pause if !@agent_workspace_interactive && @agent_workspace_session&.respond_to?(:pause)
          prepare_workspace_terminal(state)
        end
        persist_agent_workspace
        true
      rescue StandardError => e
        close_agent_workspace_session
        @agent_workspace_active = false
        @focused_pane = @agent_workspace_return_pane
        @agent_tree_navigation_active = false
        append_jump_response("Could not open focused workspace for #{item_id}: #{e.message}")
        false
      end

      def open_agent_workspace_session(agent)
        close_agent_workspace_session
        return unless agent_session_service&.respond_to?(:open)

        @agent_workspace_session = agent_session_service.open(agent.fetch("id"))
      rescue StandardError => e
        @agent_workspace_session = nil
        @agent_workspace_error = "Could not open the live worker session: #{e.message}"
      end

      def close_agent_workspace_session
        session = @agent_workspace_session
        @agent_workspace_session = nil
        session.close if session&.respond_to?(:close)
      rescue StandardError
        nil
      end

      def close_agent_workspace(preserve_terminal: false, async_interactive: true)
        was_embedded = embedded_agent_workspace?
        return_pane = @agent_workspace_return_pane.to_s
        return_pane = "chat" unless FOCUS_ORDER.include?(return_pane)
        if @agent_workspace_open_pending && workspace_controller&.respond_to?(:cancel_workspace_open)
          workspace_controller.cancel_workspace_open(agent: @agent_workspace_agent_id)
        end
        @agent_workspace_open_pending = false
        @agent_workspace_open_generation += 1
        @chat_mutex.synchronize { @agent_workspace_open_result = nil }
        close_agent_workspace_session
        if @agent_workspace_interactive && workspace_controller&.respond_to?(:close_workspace)
          close_interactive_agent_workspace(@agent_workspace_agent_id, asynchronous: async_interactive)
        elsif !preserve_terminal && workspace_controller&.respond_to?(:close_terminal)
          workspace_controller.close_terminal(agent: @agent_workspace_agent_id)
        end
        @agent_workspace_interactive = false
        @agent_workspace_open_pending = false
        @agent_workspace_active = false
        @agent_workspace_view = "agent"
        @force_full_redraw = true
        @agent_workspace_terminal_size = nil
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @agent_workspace_notice = nil
        @agent_workspace_error = nil
        @focused_pane = was_embedded ? return_pane : "agent_tree"
        @agent_tree_navigation_active = !was_embedded && !@agent_workspace_agent_id.to_s.empty?
        @selected_agent_id = @agent_workspace_agent_id if @agent_tree_navigation_active
        persist_agent_workspace
      end

      def close_interactive_agent_workspace(agent_id, asynchronous: true)
        if asynchronous && workspace_controller.respond_to?(:close_workspace_async)
          result = workspace_controller.close_workspace_async(agent: agent_id) do |completion|
            @chat_mutex.synchronize { @agent_workspace_close_results << completion }
          end
          @chat_mutex.synchronize { @agent_workspace_close_results << result } unless result.fetch("status", nil).to_s == "pending"
        else
          apply_workspace_controller_result(workspace_controller.close_workspace(agent: agent_id))
        end
      end

      # `item_id` can come from a typed `/jump <id>`, so it is matched case-insensitively against
      # canonical Meringue ids. Everything downstream uses the resolved record's canonical id.
      def agent_workspace_agent_for_item(state, item_id)
        agents = Array(state.fetch("agents", []))
        direct = Meringue::Ids.find_record(
          agents.select { |agent| agent.fetch("type", nil) == "worker" },
          item_id
        )
        return direct if direct

        issue = Meringue::Ids.find_record(Array(state.fetch("issues", [])), item_id)
        return nil unless issue

        agents.select { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil).to_s == issue.fetch("id").to_s }
              .reject { |agent| agent.fetch("status", nil) == "killed" }
              .max_by { |agent| AgentTreeNavigation.sort_key(agent.fetch("id", "")) }
      end

      def agent_workspace_agent(state)
        Array(state.fetch("agents", [])).find do |agent|
          agent.fetch("id", nil).to_s == @agent_workspace_agent_id.to_s
        end
      end

      # Ctrl-B has two honest meanings. With one node in view it opens that node's
      # delivery PR. Unscoped, there is no single PR to mean, so it opens the picker
      # over every PR that is still open instead of guessing.
      def open_workspace_delivery_pr(state)
        unless github_support_enabled?(state)
          set_selection_status(github_support_disabled_message)
          return false
        end

        return open_delivery_pr_for_id(state, @agent_workspace_agent_id) if @agent_workspace_active
        return open_delivery_pr_for_id(state, normalized_selected_agent_id(state)) if @agent_tree_navigation_active

        scoped_id = DeliveryPullRequest.scoped_id(state)
        return open_delivery_pr_for_id(state, scoped_id) unless scoped_id.empty?

        open_delivery_pr_picker(state)
      end

      def open_delivery_pr_for_id(state, agent_id)
        unless github_support_enabled?(state)
          append_jump_response(github_support_disabled_message)
          return false
        end
        if agent_id.to_s.empty?
          append_jump_response("Select a worker before opening its delivery pull request.")
          return false
        end

        presentation = DeliveryPullRequest.for_id(state, agent_id)
        unless DeliveryPullRequest.openable?(presentation)
          append_jump_response("Delivery PR for #{agent_id} is unavailable: #{presentation.fetch("message")}")
          return false
        end

        result = pull_request_opener.open(presentation.fetch("url"))
        opened = result.fetch("status", nil) == "opened" || !%w[failed rejected].include?(result.fetch("status", nil).to_s)
        append_jump_response(result.fetch("message", "Could not open delivery pull request for #{agent_id}.")) unless opened
        opened
      rescue StandardError => e
        append_jump_response("Could not open delivery pull request for #{agent_id}: #{e.message}")
        false
      end

      def delivery_pr_picker_snapshot
        return nil unless @delivery_pr_picker_active

        { "active" => true, "index" => @delivery_pr_picker_index }
      end

      def question_picker_snapshot
        return nil unless @question_picker_active

        { "active" => true, "index" => @question_picker_index }
      end

      # --- status-bar composer ---------------------------------------------
    end
  end
end
