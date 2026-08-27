# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The right-click context menu: opening it on a target, moving through it, and running the\nentry that was chosen.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def context_menu_key?(key)
        CONTEXT_MENU_KEYS.include?(key)
      end

      def context_menu_active?
        @context_menu.is_a?(Hash)
      end

      def context_menu_snapshot(_state = nil)
        return nil unless context_menu_active?

        @context_menu.merge("active" => true)
      end

      CONTEXT_MENU_TITLES = {
        "worker" => "worker",
        "head" => "head",
        "issue" => "issue",
        "project" => "project",
        "background" => "agent tree"
      }.freeze

      def open_context_menu(state, target_id, x:, y:)
        kind = ContextMenu.kind_for(state, target_id)
        entries = ContextMenu.entries(state, target_id, github_enabled: github_support_enabled?(state)).map(&:to_h)
        return false if entries.empty?

        close_model_picker
        close_delivery_pr_picker
        close_question_picker
        # Open on the first entry the user can actually pick, so Enter never
        # lands on a disabled row.
        first_enabled = entries.index { |entry| entry.fetch("enabled", true) } || 0
        @context_menu = {
          "kind" => kind,
          "title" => CONTEXT_MENU_TITLES.fetch(kind, kind),
          "target_id" => target_id.to_s.empty? ? nil : target_id.to_s,
          "entries" => entries,
          "index" => first_enabled,
          "x" => x.to_i,
          "y" => y.to_i
        }.compact
        true
      end

      def close_context_menu
        @context_menu = nil
      end

      # Shift-F10 is the platform convention for "context menu without a mouse".
      # It targets the selected AgentTree row, or the background when nothing is
      # selected, and anchors the box next to the tree rather than at a pointer.
      def open_context_menu_for_selection(state)
        target_id = @selected_agent_id || @log_scope_id
        open_context_menu(state, target_id, x: 4, y: 3)
      end

      def move_context_menu(step)
        return unless context_menu_active?

        entries = Array(@context_menu.fetch("entries", []))
        return if entries.empty?

        index = @context_menu.fetch("index", 0).to_i
        entries.length.times do
          index = (index + step) % entries.length
          break if entries[index].fetch("enabled", true)
        end
        @context_menu["index"] = index
      end

      def selected_context_menu_entry
        return nil unless context_menu_active?

        entries = Array(@context_menu.fetch("entries", []))
        return nil if entries.empty?

        entries[@context_menu.fetch("index", 0).to_i.clamp(0, entries.length - 1)]
      end

      # An entry either runs a local view action the app already owns, or hands
      # the composer a slash command draft. Nothing here writes orchestration
      # state directly: the kernel stays the only writer, and a drafted command is
      # exactly what the user could have typed, so it stays cancellable.
      def activate_context_menu_entry(state, input_buffer, input_cursor, slash_suggestion_index)
        entry = selected_context_menu_entry
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        return unchanged unless entry
        return unchanged unless entry.fetch("enabled", true)

        target_id = @context_menu&.fetch("target_id", nil)
        draft = entry.fetch("draft", nil)
        action = entry.fetch("action", nil)
        close_context_menu

        if draft
          exit_agent_tree_navigation if @agent_tree_navigation_active
          set_selection_status("Review the command and press Enter") if draft.end_with?(" ")
          return [draft, draft.chars.length, NO_SLASH_SELECTION]
        end

        case action
        when "open_pr" then open_pr_by_agent_id(state, target_id)
        when "open_workspace" then open_agent_workspace_by_id(state, target_id)
        when "info" then show_context_menu_info(state, target_id)
        end
        unchanged
      end

      # `/info` has no slash command, so the menu's Info entry reports the same
      # facts inline the way other local commands answer.
      def show_context_menu_info(state, target_id)
        record = ContextMenu.find_record(state, target_id)
        return set_selection_status("Nothing selected") unless record

        kind = ContextMenu.kind_for(state, target_id)
        details = case kind
                  when "project"
                    ["#{record.fetch("name", target_id)}", record.fetch("root_path", ""), record.fetch("status", "")]
                  when "issue"
                    [record.fetch("title", target_id), "project #{record.fetch("project_id", "?")}", record.fetch("status", "")]
                  else
                    [
                      record.dig("harness_metadata", "title") || record.fetch("id"),
                      record.fetch("harness", "?").to_s,
                      record.fetch("status", "").to_s,
                      record.fetch("workspace_path", nil)
                    ].compact
                  end
        set_selection_status("#{target_id}: #{details.reject { |part| part.to_s.strip.empty? }.join(" · ")}")
      end

      def handle_context_menu_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        return handle_context_menu_mouse(key, unchanged, state) if mouse_event?(key)

        if keybinding?("suggestion_previous", key) || key == "\e[A"
          move_context_menu(-1)
          return unchanged
        end
        if keybinding?("suggestion_next", key) || key == "\e[B"
          move_context_menu(1)
          return unchanged
        end
        if keybinding?("submit", key)
          return activate_context_menu_entry(state, input_buffer, input_cursor, slash_suggestion_index)
        end

        # Anything else dismisses rather than leaking into the composer, which is
        # what a menu that is up is expected to do.
        close_context_menu
        unchanged
      end

      def handle_context_menu_mouse(key, unchanged, state)
        return unchanged unless mouse_button_press?(key) || mouse_right_button_press?(key)

        index = layout.context_menu_entry_at(
          compose_state(-> { state }, "", -1, 0),
          width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key)
        )
        if index.nil?
          close_context_menu
          return unchanged
        end

        @context_menu["index"] = index
        entry = selected_context_menu_entry
        return unchanged unless entry && entry.fetch("enabled", true)

        activate_context_menu_entry(state, *unchanged)
      end
    end
  end
end
