# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Keyboard navigation of the AgentTree, and what Enter opens on the selected row.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def handle_agent_tree_navigation_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if keybinding?("cancel_navigation", key)
          # Esc cancels the innermost thing first: a text selection or logs caret,
          # then the AgentTree selection (with its logs filter) and jump mode.
          if selection_active? || @logs_cursor_active
            clear_selection
            return [input_buffer, input_cursor, slash_suggestion_index]
          end

          clear_log_scope
          exit_agent_tree_navigation("Agent tree navigation cancelled.")
          return [+"", 0, NO_SLASH_SELECTION]
        end

        scroll_result = handle_navigation_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return scroll_result if scroll_result

        if keybinding?("agent_select_previous", key)
          move_agent_tree_selection(state, -1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("agent_select_next", key)
          move_agent_tree_selection(state, 1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("rename_selected", key)
          return begin_selected_rename(state, input_buffer)
        end

        if agent_session_open_key?(key)
          opened = open_selected_agent(state)
          return [input_buffer, input_cursor, NO_SLASH_SELECTION] if opened && embedded_agent_workspace?

          draft = opened ? @workspace_draft.to_s.dup : ""
          return [draft, draft.chars.length, NO_SLASH_SELECTION]
        end

        if ENTER_KEYS.include?(key)
          open_selected_agent_pr(state)
          return [+"", 0, NO_SLASH_SELECTION]
        end

        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def agent_session_open_key?(key)
        keybinding?("open_agent_workspace", key)
      end

      # Quick rename reuses the normal composer and kernel command path. This keeps
      # the edit cancellable with Ctrl-C/Esc and means projects and issues get the
      # same validation and durable log entry as slash commands. The draft is the
      # namespaced command for the selected row kind (`/project rename` for a project,
      # `/issue rename` for an issue or the issue that owns the selected worker), so what
      # lands in the composer is exactly what the user could have typed themselves.
      def begin_selected_rename(state, input_buffer = "")
        kind, target_id = rename_target(state)
        unless target_id
          set_selection_status("Select a project or issue to rename")
          return [input_buffer, input_buffer.to_s.chars.length, NO_SLASH_SELECTION]
        end

        exit_agent_tree_navigation if @agent_tree_navigation_active
        draft = "/#{kind} rename #{target_id} "
        set_selection_status("Type a new name and press Enter")
        [draft, draft.chars.length, NO_SLASH_SELECTION]
      end

      # Returns ["project" | "issue", id] for the selected row, or nil when nothing
      # renameable is selected.
      def rename_target(state)
        candidate_ids = [@selected_agent_id, @log_scope_id].compact
        candidate_ids.each do |candidate_id|
          issue = Array(state.fetch("issues", [])).find { |record| record["id"].to_s == candidate_id.to_s }
          return ["issue", issue.fetch("id")] if issue

          project = Array(state.fetch("projects", [])).find { |record| record["id"].to_s == candidate_id.to_s }
          return ["project", project.fetch("id")] if project

          agent = Array(state.fetch("agents", [])).find { |record| record["id"].to_s == candidate_id.to_s }
          return ["issue", agent.fetch("issue_id")] if agent && agent["issue_id"]
        end
        nil
      end

      def enter_agent_tree_navigation(state)
        ids = agent_tree_selectable_agent_ids(state)
        if ids.empty?
          append_jump_response("No agents are available to jump into yet.")
          return
        end

        deactivate_logs_cursor_quietly
        @agent_tree_navigation_active = true
        @agent_tree_navigation_mode = :agent
        # Start on the sticky selection when it is a jump target, so entering jump
        # mode never argues with what the logs pane is already filtered by.
        # Entering jump mode by itself does not retarget the filter; moving the
        # cursor does.
        @selected_agent_id = [@log_scope_id, @selected_agent_id].find { |id| ids.include?(id) } || ids.first
        append_jump_response("Agent tree navigation active. #{keys_for("agent_select_previous")}/#{keys_for("agent_select_next")} selects issues and agents, filters their logs, and targets dashboard chat through a fresh head when an issue can be resolved (kernel events are skipped). Enter opens PRs, #{keys_for("open_agent_workspace")} opens a worker workspace or selected head session, and #{keys_for("cancel_navigation")} clears the selection.")
      end

      def exit_agent_tree_navigation(message = nil)
        @agent_tree_navigation_active = false
        @agent_tree_navigation_mode = :agent
        @selected_agent_id = nil
        append_jump_response(message) if message
      end

      def move_agent_tree_selection(state, delta)
        ids = agent_tree_selectable_agent_ids(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") if ids.empty?

        current_index = ids.index(@selected_agent_id) || 0
        @selected_agent_id = ids[(current_index + delta) % ids.length]
        # Moving the cursor is an explicit selection action, so the logs filter
        # follows it and the highlighted row always matches the filter.
        set_log_scope(@selected_agent_id)
        remember_workspace_agent(state, @selected_agent_id)
      end

      def open_selected_agent(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        selected_agent = Meringue::Ids.find_record(Array(state.fetch("agents", [])), selected_id)
        if selected_agent&.fetch("type", nil) == "head"
          open_head_session_for_debugging(selected_agent)
          return false
        end

        remember_workspace_agent(state, selected_id)
        open_agent_workspace_by_id(state, selected_id)
      end

      # Heads never gain a focused workspace or become chat targets. `a` is only
      # a debugging affordance over the persisted harness history. Expected
      # unavailability is transient dashboard feedback, not a durable log line.
      def open_head_session_for_debugging(head)
        result = external_agent_session_result(head)
        status = result.fetch("status", "failed").to_s
        message = result.fetch("message", nil).to_s.strip
        message = "Opened agent session for #{head.fetch("id")}." if status == "opened" && message.empty?
        message = "Agent session for #{head.fetch("id")} is unavailable." if message.empty?
        set_selection_status(message)
        status == "opened"
      end

      def open_selected_agent_pr(state)
        selected_id = normalized_selected_agent_id(state)
        return exit_agent_tree_navigation("No agents are available to jump into yet.") unless selected_id

        open_pr_by_agent_id(state, selected_id)
        exit_agent_tree_navigation
      end
    end
  end
end
