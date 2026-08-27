# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Clicking the AgentTree: selecting a row, scoping the logs to it, and what a double click\nopens.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # A single left click selects the clicked AgentTree row and scopes the logs
      # pane to it. Clicking the already-selected row, or empty space inside the
      # tree, is the explicit deselect gesture. A double-click is node-specific:
      # issues open their delivery PR, workers open their focused workspace, and
      # retryable heads submit an explicit retry command.
      def handle_agent_tree_item_click(item_id, key, state, on_submit = nil)
        if item_id.to_s.empty?
          @last_worker_click = nil
          deselect_agent_tree_item
          return false
        end

        record = agent_tree_record(state, item_id)
        return false unless record

        action = agent_tree_double_click_action(record, item_id, key, state)
        double_click = action.fetch(:double_click)
        @last_worker_click = nil unless action.fetch(:track_click)
        if !double_click && @log_scope_id.to_s == item_id.to_s
          deselect_agent_tree_item
          return false
        end

        select_agent_tree_item(state, item_id)
        case action.fetch(:kind)
        when :pull_request
          double_click && open_pr_by_agent_id(state, item_id)
        when :workspace
          double_click && open_agent_workspace_by_id(state, item_id)
        when :retry
          double_click && submit_head_retry_from_tree(item_id, on_submit, state)
        else
          false
        end
      end

      def agent_tree_double_click_action(record, item_id, key, state)
        if issue_tree_record?(record)
          { kind: :pull_request, track_click: true, double_click: worker_double_click?(item_id, key) }
        elsif record["type"].to_s == "worker"
          workspace_openable = worker_workspace_available?(record)
          {
            kind: :workspace,
            track_click: workspace_openable,
            double_click: workspace_openable && worker_double_click?(item_id, key)
          }
        elsif record["type"].to_s == "head" && State::Models.head_retry_target?(record)
          { kind: :retry, track_click: true, double_click: worker_double_click?(item_id, key) }
        else
          { kind: :none, track_click: false, double_click: false }
        end
      end

      def agent_tree_record(state, item_id)
        return nil if item_id.to_s.empty?

        Array(state.fetch("issues", [])).find { |record| record.is_a?(Hash) && record["id"].to_s == item_id.to_s } ||
          Array(state.fetch("agents", [])).find { |record| record.is_a?(Hash) && record["id"].to_s == item_id.to_s }
      end

      def worker_workspace_available?(worker)
        Workspace::PathResolver.path_for(worker)
      rescue StandardError
        nil
      end

      def issue_tree_record?(record)
        AgentTreeNavigation.issue_record?(record)
      end

      def submit_head_retry_from_tree(item_id, on_submit, state)
        @workspace_draft = ""
        unless on_submit
          append_jump_response("Retry #{item_id} with /retry #{item_id}.")
          return true
        end

        submit_prompt("/retry #{item_id}", on_submit, state)
        true
      end

      def select_agent_tree_item(state, item_id)
        if agent_tree_selectable_agent_ids(state).include?(item_id)
          @agent_tree_navigation_active = true
          @agent_tree_navigation_mode = :agent
          @selected_agent_id = item_id
          remember_workspace_agent(state, item_id)
        elsif LogScope.selectable?(state, item_id)
          # Projects are valid log-filter targets but not jump targets, so
          # selecting one leaves jump mode instead of moving its cursor.
          @agent_tree_navigation_active = false
          @agent_tree_navigation_mode = :agent
          @selected_agent_id = nil
        else
          return false
        end

        set_log_scope(item_id)
        true
      end

      def deselect_agent_tree_item
        clear_log_scope
        exit_agent_tree_navigation if @agent_tree_navigation_active
        false
      end

      # A worker-authored logs cell is a direct filter gesture, not a pane or
      # keyboard-mode transition. Keep logs focus and its viewport; if jump mode
      # was already active, move its cursor to the same worker without toggling
      # the mode. A stale/removed worker is deliberately inert.
      def select_worker_from_logs(state, worker_id)
        worker = Array(state.fetch("agents", [])).find do |record|
          record.is_a?(Hash) && record.fetch("type", nil).to_s == "worker" && record.fetch("id", nil).to_s == worker_id.to_s
        end
        return false unless worker

        @logs_worker_click_rollback = {
          worker_id: worker.fetch("id").to_s,
          previous_scope: @log_scope_id,
          previous_selected_agent: @selected_agent_id
        }
        @log_scope_id = worker.fetch("id").to_s
        if @agent_tree_navigation_active
          @selected_agent_id = @log_scope_id
          remember_workspace_agent(state, @log_scope_id)
        end
        @revealed_agent_tree_item_id = nil
        true
      end

      # The logs filter follows the selection, so retargeting it also resets the
      # logs viewport to the newest matching entry and drops a caret/highlight
      # that pointed at lines the filter no longer renders.
      def set_log_scope(item_id)
        id = item_id.to_s
        return false if id.empty?

        @log_scope_id = id
        @scroll_offsets["logs"] = 0
        clear_logs_selection
        true
      end

      def clear_log_scope
        return false unless log_scope_active?

        @log_scope_id = nil
        @scroll_offsets["logs"] = 0
        clear_logs_selection
        true
      end

      def log_scope_active?
        !@log_scope_id.to_s.empty?
      end

      # Compatibility for extensions that invoked the old worker-only helper.
      def select_agent_tree_worker(state, worker_id)
        select_agent_tree_item(state, worker_id)
      end

      def worker_double_click?(worker_id, key)
        now = monotonic_time
        click = {
          agent_id: worker_id,
          x: key.fetch("x", nil).to_i,
          y: key.fetch("y", nil).to_i,
          at: now
        }
        previous = @last_worker_click
        @last_worker_click = click
        return false unless previous
        return false unless previous.fetch(:agent_id, nil) == worker_id
        return false unless previous.fetch(:x, nil) == click.fetch(:x) && previous.fetch(:y, nil) == click.fetch(:y)

        if now - previous.fetch(:at, 0.0) <= DOUBLE_CLICK_INTERVAL_SECONDS
          @last_worker_click = nil
          true
        else
          false
        end
      end

      # The open-PR count is not an AgentTree node and must never enter jump mode
      # or change the sticky log/chat selection. It therefore keeps an isolated
      # click tracker rather than borrowing the node-specific one above.
      def open_pull_requests_summary_double_click?(key)
        now = monotonic_time
        click = { x: key.fetch("x", nil).to_i, y: key.fetch("y", nil).to_i, at: now }
        previous = @last_open_pull_requests_summary_click
        @last_open_pull_requests_summary_click = click
        return false unless previous
        return false unless previous.fetch(:y) == click.fetch(:y)
        return false unless (previous.fetch(:x) - click.fetch(:x)).abs <= DOUBLE_CLICK_COLUMN_TOLERANCE

        if now - previous.fetch(:at, 0.0) <= DOUBLE_CLICK_INTERVAL_SECONDS
          @last_open_pull_requests_summary_click = nil
          true
        else
          false
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def cancel_workspace_leader!
        @workspace_leader_pending = false
        @workspace_leader_started_at = nil
        @agent_workspace_notice = nil
      end

      def expire_workspace_leader!
        return unless @workspace_leader_pending
        return unless @workspace_leader_started_at
        return if monotonic_time - @workspace_leader_started_at < WORKSPACE_LEADER_TIMEOUT_SECONDS

        cancel_workspace_leader!
      end

      def reset_base_state_cache
        @cached_base_state = nil
        @cached_base_state_at = nil
      end

      def read_only_base_state(state_provider, now: monotonic_time)
        if @cached_base_state && @cached_base_state_at && (now - @cached_base_state_at) < REFRESH_INTERVAL
          return @cached_base_state
        end

        @cached_base_state = state_provider.call || State::Models.empty_state
        @cached_base_state_at = now
        @cached_base_state
      end
    end
  end
end
