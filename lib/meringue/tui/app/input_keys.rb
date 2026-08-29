# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Key predicates, composer undo, slash-suggestion navigation, and pane focus.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def selection_edit_key?(key)
        keybinding?("delete_backward", key) || keybinding?("delete_forward", key)
      end

      def keybinding?(action, key)
        keybindings.match?(action, key)
      end

      def ctrl_c_key?(key)
        keybinding?("clear_or_quit", key)
      end

      def dashboard_chat_surface?
        !@agent_workspace_active || embedded_agent_workspace?
      end

      def dashboard_chat_undo_key?(key)
        return false unless keybinding?("undo", key) && @focused_pane == "chat"
        return false if @settings_active
        return false if @question_picker_active || @model_picker_active || @delivery_pr_picker_active

        true
      end

      def chat_undo_snapshot(input_buffer, input_cursor, slash_suggestion_index)
        selection = @selection_pane == "chat" && @chat_selection ? @chat_selection.dup : nil
        {
          buffer: input_buffer.to_s.dup,
          cursor: clamp_cursor(input_buffer, input_cursor),
          slash_suggestion_index: slash_suggestion_index.to_i,
          selection: selection,
          selection_anchor: selection ? @chat_selection_anchor.to_i : nil,
          pastes: @chat_pastes.snapshot
        }
      end

      def update_chat_undo_history(key, prior_buffer, result, snapshot, prior_history_index)
        return result unless snapshot && result.is_a?(Array)
        return result if keybinding?("undo", key)

        history_moved = (keybinding?("cursor_up", key) || keybinding?("cursor_down", key)) &&
                        prior_history_index != @chat_history_index
        if history_moved
          reset_chat_undo_history
          return result
        end
        return result if result.first.to_s == prior_buffer.to_s

        if ctrl_c_key?(key) || (keybinding?("submit", key) && result.first.to_s.empty?)
          reset_chat_undo_history
        else
          @chat_undo_history << snapshot
          @chat_undo_history.shift while @chat_undo_history.length > CHAT_UNDO_LIMIT
        end
        result
      end

      def undo_chat_edit(input_buffer, input_cursor, slash_suggestion_index)
        snapshot = @chat_undo_history.pop
        return [input_buffer, input_cursor, slash_suggestion_index] unless snapshot

        reset_chat_history_navigation
        @chat_pastes.restore!(snapshot.fetch(:pastes))
        clear_chat_selection
        if snapshot.fetch(:selection, nil)
          @selection_pane = "chat"
          @chat_selection_anchor = snapshot.fetch(:selection_anchor)
          @chat_selection = snapshot.fetch(:selection).dup
        end
        [
          snapshot.fetch(:buffer).dup,
          snapshot.fetch(:cursor),
          snapshot.fetch(:slash_suggestion_index)
        ]
      end

      def reset_chat_undo_history
        @chat_undo_history.clear
      end

      def slash_suggestion_key?(key)
        keybinding?("complete_suggestion", key)
      end

      def slash_suggestion_navigation_key?(key)
        keybinding?("complete_suggestion", key) || keybinding?("suggestion_previous", key) || keybinding?("suggestion_next", key)
      end

      def handle_slash_suggestion_navigation(key, input_buffer, slash_suggestion_index, state)
        records = slash_suggestion_records(input_buffer, state)
        return [input_buffer, NO_SLASH_SELECTION] if records.empty?

        if keybinding?("suggestion_previous", key)
          return [input_buffer, slash_selection?(slash_suggestion_index) ? (slash_suggestion_index - 1) % records.length : records.length - 1]
        end
        if keybinding?("suggestion_next", key)
          return [input_buffer, slash_selection?(slash_suggestion_index) ? (slash_suggestion_index + 1) % records.length : 0]
        end

        selected_index = slash_selection?(slash_suggestion_index) ? slash_suggestion_index.clamp(0, records.length - 1) : 0
        [slash_completion_for(records.fetch(selected_index)), NO_SLASH_SELECTION]
      end

      def slash_selection?(slash_suggestion_index)
        slash_suggestion_index.to_i >= 0
      end

      def handle_focus_key(key, input_buffer, input_cursor, slash_suggestion_index)
        return nil if slash_suggestions_active?(input_buffer) && slash_suggestion_key?(key)

        if keybinding?("focus_previous", key)
          cycle_focus(-1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("focus_next", key)
          cycle_focus(1)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        nil
      end

      def cycle_focus(delta = 1)
        current_index = FOCUS_ORDER.index(@focused_pane) || 0
        @focused_pane = FOCUS_ORDER[(current_index + delta) % FOCUS_ORDER.length]
        # The caret belongs to the logs pane, so moving focus away puts arrow keys
        # back to scrolling/composer duty while any highlight stays copyable.
        deactivate_logs_cursor_quietly unless @focused_pane == "logs"
      end

      def handle_focused_action_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless %w[agent_tree logs].include?(@focused_pane)

        if @focused_pane == "agent_tree" && keybinding?("rename_selected", key)
          return begin_selected_rename(state, input_buffer)
        end
        return nil unless keybinding?("submit", key)

        enter_agent_tree_navigation(state)
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def handle_focused_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless focused_scrollable?

        if mouse_wheel_up?(key)
          scroll_focused_pane(:up, steps: MOUSE_SCROLL_STEP * mouse_wheel_count(key), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if mouse_wheel_down?(key)
          scroll_focused_pane(:down, steps: MOUSE_SCROLL_STEP * mouse_wheel_count(key), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("scroll_up", key) || keybinding?("scroll_page_up", key)
          scroll_focused_pane(:up, steps: scroll_key_step(page: keybinding?("scroll_page_up", key)), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        if keybinding?("scroll_down", key) || keybinding?("scroll_page_down", key)
          scroll_focused_pane(:down, steps: scroll_key_step(page: keybinding?("scroll_page_down", key)), state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        edge = scroll_edge_for(key)
        if edge
          scroll_focused_pane_to(edge, state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        nil
      end

      # Jump mode owns the arrow keys for selection, so paging and top/bottom
      # keys stay available for scrolling the pane the selection lives in.
      def handle_navigation_scroll_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        return nil unless focused_scrollable?

        edge = scroll_edge_for(key)
        if edge
          scroll_focused_pane_to(edge, state: state)
          return [input_buffer, input_cursor, slash_suggestion_index]
        end

        page_up = keybinding?("scroll_page_up", key)
        return nil unless page_up || keybinding?("scroll_page_down", key)

        scroll_focused_pane(page_up ? :up : :down, steps: scroll_key_step(page: true), state: state)
        [input_buffer, input_cursor, slash_suggestion_index]
      end

      def scroll_edge_for(key)
        return :top if keybinding?("scroll_top", key)
        return :bottom if keybinding?("scroll_bottom", key)

        nil
      end

      def focused_scrollable?
        @focused_pane != "chat"
      end
    end
  end
end
