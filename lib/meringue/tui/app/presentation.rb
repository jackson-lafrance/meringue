# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Composing the state the panes render from.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def compose_state(state_provider, input_buffer, slash_suggestion_index = NO_SLASH_SELECTION, input_cursor = nil)
        @workspace_draft = input_buffer.to_s if @agent_workspace_active && !embedded_agent_workspace?
        state = state_provider.call || State::Models.empty_state
        sync_state_logs!(state)
        complete_pending_workspace_closes
        if @agent_tree_navigation_active
          ids = agent_tree_selectable_agent_ids(state)
          @selected_agent_id = ids.include?(@selected_agent_id) ? @selected_agent_id : ids.first
          @agent_tree_navigation_active = false if ids.empty?
        end
        reconcile_workspace_selection!(state)
        reconcile_log_scope!(state)
        composed_state = state.merge(
          "_chat" => chat_snapshot(input_buffer, slash_suggestion_index, input_cursor),
          Settings::STATE_KEY => settings_snapshot(state),
          StatusBarComposer::STATE_KEY => status_bar_composer_snapshot(state),
          "_status_bar_layout" => StatusBarLayout.from_config(config),
          "_capabilities" => { "github_support" => github_support_enabled?(state) },
          "_agent_tree_navigation" => agent_tree_navigation_snapshot,
          LogScope::STATE_KEY => LogScope.snapshot(state, @log_scope_id),
          "_agent_workspace" => agent_workspace_snapshot(state, input_buffer, input_cursor, slash_suggestion_index),
          "_scroll" => scroll_snapshot,
          "_selection" => selection_snapshot,
          Layout::CONTEXT_MENU_STATE_KEY => context_menu_snapshot(state)
        )
        clamp_scroll_offsets!(composed_state)
        # Reveal reads the offsets it is about to adjust, so it runs against the
        # clamped snapshot instead of the pre-clamp one.
        reveal_selected_agent_tree_item!(composed_state.merge("_scroll" => scroll_snapshot))
        composed_state.merge("_scroll" => scroll_snapshot)
      end

      # A newly selected AgentTree item scrolls into view by the minimum amount,
      # the same way the logs caret reveals its line. Reveal only runs when the
      # selection actually changed, so scrolling by hand is never yanked back.
      def reveal_selected_agent_tree_item!(state)
        selected_id = revealable_agent_tree_item_id
        if selected_id.to_s.empty?
          @revealed_agent_tree_item_id = nil
          return
        end
        return if @revealed_agent_tree_item_id.to_s == selected_id.to_s

        @revealed_agent_tree_item_id = selected_id
        reveal_agent_tree_item(state, selected_id)
      end

      # Whichever row is rendered as selected: the jump-mode cursor while it is
      # active, otherwise the sticky selection that scopes the logs pane. The
      # sticky row outlives jump mode, so it still deserves to be revealed.
      def revealable_agent_tree_item_id
        return @selected_agent_id if @agent_tree_navigation_active && !@selected_agent_id.to_s.empty?

        @log_scope_id
      end

      def reveal_agent_tree_item(state, item_id)
        range = layout.agent_tree_item_line_range(state, width: render_width, height: render_height, item_id: item_id)
        return unless range

        offset = layout.agent_tree_scroll_offset_for_line(
          state,
          width: render_width,
          height: render_height,
          line_index: range.first,
          last_line_index: range.last
        )
        @scroll_offsets["agent_tree"] = offset.to_i unless offset.nil?
      end
    end
  end
end
