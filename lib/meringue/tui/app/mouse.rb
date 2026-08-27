# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Turning mouse reports into presses, drags, releases, wheel steps, and the pane and text\nposition under the pointer.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def handle_mouse_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit = nil)
        return nil unless mouse_event?(key)
        return handle_mouse_wheel_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_wheel?(key)
        return handle_mouse_right_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_right_button_press?(key)
        return handle_mouse_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit) if mouse_button_press?(key)
        return handle_mouse_drag_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_drag?(key)
        return handle_mouse_release_key(key, input_buffer, input_cursor, slash_suggestion_index, state) if mouse_button_release?(key)

        nil
      end

      # Right-click opens the menu for whatever it landed on. It used to be one
      # hard-coded action (open an issue's PR), which left workers, projects, and
      # empty space with no gesture at all; ContextMenu decides the entries and
      # this only owns where the box sits and what happens on activation.
      def handle_mouse_right_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        pane = pane_at_mouse_position(key, state)
        return nil unless pane == "agent_tree"

        item_id = agent_tree_item_at_mouse_position(key, state)
        open_context_menu(state, item_id, x: mouse_x(key) + 1, y: mouse_y(key))
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      # --- context menu -----------------------------------------------------------------

      # Shift-F10 is the platform convention for opening a context menu from the
      # keyboard; the Menu/Apps key sends the same thing on terminals that have
      # one. Both are literal sequences rather than a rebindable action so the
      # gesture matches what the rest of the desktop does.
      CONTEXT_MENU_KEYS = ["\e[21;2~", "\e[29~"].freeze

      def handle_mouse_press_key(key, input_buffer, input_cursor, slash_suggestion_index, state, on_submit = nil)
        if layout.open_pull_requests_summary_hit?(
          state,
          width: render_width,
          height: render_height,
          x: mouse_x(key),
          y: mouse_y(key)
        )
          # Crossing between the summary and another mouse surface must not join
          # two unrelated presses into that surface's double-click gesture.
          @last_worker_click = nil
          @last_text_click = nil
          open_delivery_pr_picker(state) if open_pull_requests_summary_double_click?(key)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end
        @last_open_pull_requests_summary_click = nil

        if embedded_agent_workspace?
          action = layout.agent_workspace_control_at(
            state,
            width: render_width,
            height: render_height,
            x: mouse_x(key),
            y: mouse_y(key)
          )
          if action
            cancel_workspace_leader!
            run_workspace_command(action, state)
            return [input_buffer, input_cursor, slash_suggestion_index]
          end
        end

        pane = pane_at_mouse_position(key, state)
        return [input_buffer, input_cursor, slash_suggestion_index] unless pane

        @focused_pane = pane
        case pane
        when "agent_tree"
          clear_selection
          # The AgentTree keeps its own double-click tracker, so a text click
          # before and after a tree click never pair up into a word selection.
          @last_text_click = nil
          item_id = agent_tree_item_at_mouse_position(key, state)
          # The focused Agent session owns the logs pane, but the AgentTree must
          # remain a way out of it. A click on another agent closes the current
          # session before applying the ordinary tree selection/double-click action.
          if embedded_agent_workspace? && item_id && item_id.to_s != @agent_workspace_agent_id.to_s
            close_agent_workspace(preserve_terminal: true)
          end
          opened = handle_agent_tree_item_click(item_id, key, state, on_submit)
          if opened
            return [input_buffer, input_cursor, NO_SLASH_SELECTION] if embedded_agent_workspace?

            draft = @workspace_draft.to_s.dup
            return [draft, draft.chars.length, NO_SLASH_SELECTION]
          end

          [input_buffer, input_cursor, slash_suggestion_index]
        when "logs"
          @last_worker_click = nil
          if embedded_agent_workspace?
            @last_text_click = nil
            @logs_worker_click_candidate = nil
            clear_selection
            return [input_buffer, input_cursor, slash_suggestion_index]
          end

          click_count = text_click_count(pane, key)
          clicked_worker_id = logs_worker_at(key, state)
          if click_count > 1 && clicked_worker_id && @logs_worker_click_rollback&.fetch(:worker_id, nil) == clicked_worker_id
            @log_scope_id = @logs_worker_click_rollback.fetch(:previous_scope, nil)
            @selected_agent_id = @logs_worker_click_rollback.fetch(:previous_selected_agent, nil) if @agent_tree_navigation_active
            @logs_worker_click_rollback = nil
          end
          @logs_worker_click_candidate = click_count == 1 ? clicked_worker_id : nil
          begin_logs_selection(key, state, click_count: click_count)
          [input_buffer, input_cursor, slash_suggestion_index]
        else
          @last_worker_click = nil
          exit_agent_tree_navigation if @agent_tree_navigation_active
          cursor = begin_chat_selection(key, state, input_buffer, input_cursor, click_count: text_click_count(pane, key))
          [input_buffer, cursor, slash_suggestion_index]
        end
      end

      # Drag reports are clamped inside the pane the press started in, so a
      # selection can never grow into the agent tree or the composer. At a logs
      # edge, the latest pointer position remains armed between mouse reports so
      # refresh ticks keep scrolling and extending while the button stays held.
      def handle_mouse_drag_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return [input_buffer, input_cursor, slash_suggestion_index] unless @selection_dragging

        @logs_worker_click_candidate = nil if @selection_pane == "logs"
        case @selection_pane
        when "logs"
          @logs_drag_pointer = key
          @logs_drag_autoscroll_direction = layout.logs_drag_scroll_direction(
            state,
            width: render_width,
            height: render_height,
            y: mouse_y(key)
          )
          if @logs_drag_autoscroll_direction
            continue_logs_drag_autoscroll(state)
          else
            position = logs_text_position(key, state)
            extend_logs_selection(state, position) if position
          end
          [input_buffer, input_cursor, slash_suggestion_index]
        when "chat"
          cursor = composer_text_index(key, state)
          return [input_buffer, input_cursor, slash_suggestion_index] unless cursor

          [input_buffer, extend_chat_selection(input_buffer, cursor), slash_suggestion_index]
        else
          [input_buffer, input_cursor, slash_suggestion_index]
        end
      end

      def continue_logs_drag_autoscroll(state)
        return false unless @selection_dragging && @selection_pane == "logs"
        return false unless @logs_drag_autoscroll_direction && @logs_drag_pointer

        scroll_pane(
          "logs",
          @logs_drag_autoscroll_direction,
          steps: DRAG_AUTOSCROLL_STEP,
          state: state
        )
        scrolled_state = state.merge("_scroll" => scroll_snapshot)
        position = logs_text_position(@logs_drag_pointer, scrolled_state)
        extend_logs_selection(scrolled_state, position) if position
        true
      end

      # Releasing the button finishes a mouse selection. A finished logs
      # highlight goes straight to the system clipboard, so a double-click is one
      # gesture end to end; Ctrl-C still copies later, and the composer stays
      # copy-on-demand so selecting text to retype it cannot clobber a clipboard.
      def handle_mouse_release_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        completed_drag = @selection_dragging
        worker_id = @logs_worker_click_candidate
        @logs_worker_click_candidate = nil
        @selection_dragging = false
        @logs_drag_autoscroll_direction = nil
        @logs_drag_pointer = nil
        if selection_active?
          copy_selection(state, input_buffer) if completed_drag && @selection_pane == "logs"
        elsif worker_id && logs_worker_at(key, state) == worker_id
          clear_selection
          select_worker_from_logs(state, worker_id)
        else
          clear_selection
        end
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      # The wheel scrolls whatever scrollable pane the pointer is over, so the
      # AgentTree and the logs pane behave the same and neither needs focus or a
      # jump-mode exit first. Hovering something that cannot scroll falls back to
      # the focused pane, which is the older behavior.
      def handle_mouse_wheel_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        if embedded_agent_workspace? && pane_at_mouse_position(key, state) == "logs"
          # A native harness owns its history. Scrolling Meringue's captured
          # viewport only moves old pixels and leaves Pi, Claude, or another
          # interactive backend unaware that the user asked to navigate. Route
          # the wheel through the harness PTY adapter instead; it translates the
          # event to portable page navigation. The separate worktree terminal
          # keeps its existing outer-viewport behavior.
          if @agent_workspace_view == "terminal" && agent_workspace_scroll_max(state).positive?
            scroll_agent_workspace(key, state)
          else
            # When the TUI has no retained rows of its own, let the focused harness keep
            # its native mouse behavior (for example, internal selection/list scrolling).
            event = layout.agent_workspace_mouse_event(
              state,
              width: render_width,
              height: render_height,
              x: mouse_x(key),
              y: mouse_y(key),
              event: key
            )
            forward_agent_workspace_interactive_key(event, state) if event && @agent_workspace_view != "terminal"
            forward_agent_workspace_terminal_key(event, state) if event && @agent_workspace_view == "terminal"
          end
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        # One limits lookup per wheel event keeps hover routing as cheap as the
        # previous focus-only path.
        limits = scroll_limits_for(state)
        pane = wheel_target_pane(key, state, limits)
        return nil unless pane

        scroll_pane(
          pane,
          mouse_wheel_up?(key) ? :up : :down,
          steps: MOUSE_SCROLL_STEP * mouse_wheel_count(key),
          state: state,
          max_offset: limits.fetch(pane, 0).to_i
        )
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def wheel_target_pane(key, state, limits)
        hovered = pane_at_mouse_position(key, state)
        return hovered if hovered && limits.fetch(hovered, 0).to_i.positive?

        focused_scrollable? ? @focused_pane.to_s : nil
      end

      def mouse_event?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse"
      end

      def mouse_button_press?(key)
        mouse_event?(key) &&
          key.fetch("kind", nil) == "button" && key.fetch("pressed", false) &&
          (key.fetch("button", 0).to_i & 3).zero?
      end

      def mouse_right_button_press?(key)
        mouse_event?(key) &&
          key.fetch("kind", nil) == "button" && key.fetch("pressed", false) &&
          (key.fetch("button", 0).to_i & 3) == 2
      end

      def mouse_drag?(key)
        mouse_event?(key) && key.fetch("kind", nil) == "motion"
      end

      def mouse_button_release?(key)
        mouse_event?(key) && key.fetch("kind", nil) == "button" && !key.fetch("pressed", false)
      end

      def pane_at_mouse_position(key, state)
        layout.pane_at(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def agent_tree_item_at_mouse_position(key, state)
        layout.agent_tree_item_at(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def render_width
        @last_render_width || DEFAULT_WIDTH
      end

      def render_height
        @last_render_height || DEFAULT_HEIGHT
      end

      def mouse_x(key)
        key.fetch("x", 1).to_i - 1
      end

      def mouse_y(key)
        key.fetch("y", 1).to_i - 1
      end

      def logs_text_position(key, state)
        layout.logs_text_position(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def logs_worker_at(key, state)
        layout.logs_worker_at(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end

      def composer_text_index(key, state)
        layout.composer_text_index(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
      end
    end
  end
end
