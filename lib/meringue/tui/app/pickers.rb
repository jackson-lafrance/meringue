# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The model, thinking, theme, harness, question, and pull-request pickers.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def model_picker_snapshot
        return nil unless @model_picker_active

        {
          "active" => true,
          "index" => @model_picker_index,
          "query" => @model_picker_query.to_s,
          "harness" => @model_picker_harness,
          "role" => @model_picker_role,
          # Model and thinking hold one shared value in shared mode, so the
          # picker has nothing to switch between and hides its role tabs. The
          # harness picker is unaffected: role harnesses are always independent.
          "role_tabs" => @config.role_specific_agent_defaults?,
          "kind" => @model_picker_kind
        }.compact
      end

      # Model and choice pickers always open, even when their source cannot give
      # us a catalog/list: an explicit explanation inside the popup is the useful
      # answer, and a chat line or blank popup is not. The model path reads the
      # kernel-cached snapshot, so opening it never starts a harness process.
      def open_model_picker(state, harness: nil, role: nil)
        close_model_picker
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = harness.to_s.strip.empty? ? nil : harness.to_s.strip
        @model_picker_role = %w[head worker].include?(role.to_s.downcase) ? role.to_s.downcase : "head"
        @model_picker_kind = "model"
        close_delivery_pr_picker
        close_question_picker
        true
      end

      def open_thinking_picker(state, role: nil)
        close_model_picker
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = %w[head worker].include?(role.to_s.downcase) ? role.to_s.downcase : "head"
        @model_picker_kind = "thinking"
        close_delivery_pr_picker
        close_question_picker
        true
      end

      def open_theme_picker(state)
        close_model_picker
        @theme_picker_original = Style.current_colorscheme.to_s
        @model_picker_active = true
        @model_picker_index = Style.colorschemes.index(@theme_picker_original) || 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = "head"
        @model_picker_kind = "theme"
        close_delivery_pr_picker
        close_question_picker
        true
      end

      def open_harness_picker(state, role: nil)
        close_model_picker
        @model_picker_active = true
        @model_picker_index = 0
        @model_picker_query = +""
        @model_picker_harness = nil
        @model_picker_role = %w[head worker].include?(role.to_s.downcase) ? role.to_s.downcase : "head"
        @model_picker_kind = "harness"
        close_delivery_pr_picker
        close_question_picker
        true
      end

      def close_model_picker(restore_theme: true)
        if restore_theme && @model_picker_kind == "theme" && @theme_picker_original
          restore_theme_picker(@theme_picker_original)
        end
        @theme_picker_original = nil if @model_picker_kind == "theme"
        @model_picker_active = false
        @model_picker_query = +""
        @model_picker_index = 0
        @model_picker_harness = nil
        @model_picker_role = "head"
        @model_picker_kind = "model"
      end

      def restore_theme_picker(theme)
        return if theme.to_s.empty? || Style.current_colorscheme == theme.to_s

        Style.configure!(theme.to_s)
      rescue ArgumentError
        nil
      end

      def restore_pending_theme_picker
        original = @theme_picker_pending_original
        @theme_picker_pending_original = nil
        restore_theme_picker(original) if original
      end

      def preview_theme_picker(state)
        entry = selected_model_picker_entry(model_picker_entries(state))
        return unless entry

        theme = entry.fetch("reference")
        Style.configure!(theme) unless Style.current_colorscheme == theme
      rescue ArgumentError
        nil
      end

      def model_picker_entries(state)
        case @model_picker_kind
        when "thinking"
          ModelPicker.thinking_entries(state, role: @model_picker_role, query: @model_picker_query)
        when "theme"
          Style.colorschemes.filter_map.with_index do |theme, index|
            next unless @model_picker_query.to_s.empty? || theme.downcase.include?(@model_picker_query.to_s.downcase)

            {
              "reference" => theme,
              "name" => theme,
              "index" => index
            }
          end
        when "harness"
          query = @model_picker_query.to_s.downcase
          Harness::Registry.provider_choices.filter_map.with_index do |choice, index|
            provider = choice.fetch("provider")
            label = choice.fetch("label")
            next unless query.empty? || provider.downcase.include?(query) || label.downcase.include?(query)

            {
              "reference" => provider,
              "name" => label,
              "description" => choice.fetch("description", "future #{(@model_picker_role || "head")} harness"),
              "index" => index
            }
          end
        else
          ModelPicker.entries(
            state,
            harness: @model_picker_harness,
            query: @model_picker_query,
            role: @model_picker_role
          )
        end
      end

      # A modal list that owns typing while it is up: printable keys filter it,
      # arrows move, Enter applies the model, Ctrl-R re-fetches the catalog, and
      # Esc closes. Unlike the open-PR picker it does not close on any other key,
      # because typing here is the search box rather than the composer.
      def handle_model_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        entries = model_picker_entries(state)
        return handle_model_picker_mouse(key, unchanged, on_submit, state, entries) if mouse_event?(key)

        if keybinding?("cursor_left", key)
          switch_model_picker_role(-1)
          return unchanged
        end
        if keybinding?("cursor_right", key)
          switch_model_picker_role(1)
          return unchanged
        end
        if keybinding?("suggestion_previous", key)
          move_model_picker(-1, entries.length, state: state)
          return unchanged
        end
        if keybinding?("suggestion_next", key)
          move_model_picker(1, entries.length, state: state)
          return unchanged
        end
        if keybinding?("refresh_model_catalog", key)
          if @model_picker_kind == "model" || @model_picker_kind == "thinking"
            refresh_model_catalog(on_submit, state)
          end
          return unchanged
        end
        if keybinding?("submit", key)
          apply_model_picker_entry(selected_model_picker_entry(entries), on_submit, state)
          return unchanged
        end
        if keybinding?("cancel_navigation", key)
          close_model_picker
          return unchanged
        end
        if keybinding?("delete_word_backward", key)
          @model_picker_query = +""
          @model_picker_index = 0
          preview_theme_picker(state) if @model_picker_kind == "theme"
          return unchanged
        end
        if keybinding?("delete_backward", key)
          @model_picker_query = @model_picker_query.to_s.chars[0...-1].join
          @model_picker_index = 0
          preview_theme_picker(state) if @model_picker_kind == "theme"
          return unchanged
        end
        if printable_key?(key)
          @model_picker_query = "#{@model_picker_query}#{key}"
          @model_picker_index = 0
          preview_theme_picker(state) if @model_picker_kind == "theme"
          return unchanged
        end

        close_model_picker
        nil
      end

      def handle_model_picker_mouse(key, unchanged, on_submit, state, entries)
        hit = layout.model_picker_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        if mouse_drag?(key)
          if hit.is_a?(Integer) && hit < entries.length
            @model_picker_index = hit
            preview_theme_picker(state) if @model_picker_kind == "theme"
          end
          return unchanged
        end
        return unchanged unless mouse_button_press?(key) || mouse_wheel?(key)

        if mouse_wheel?(key)
          return nil if hit == :outside

          move_model_picker(mouse_wheel_up?(key) ? -1 : 1, entries.length, state: state)
          return unchanged
        end

        if hit.is_a?(Integer)
          apply_model_picker_entry(entries[hit], on_submit, state)
        elsif hit == :outside
          close_model_picker
        end
        unchanged
      end

      def move_model_picker(step, count, state: nil)
        return if count <= 0

        @model_picker_index = (@model_picker_index.to_i + step) % count
        preview_theme_picker(state) if @model_picker_kind == "theme"
      end

      def switch_model_picker_role(step)
        return if %w[model thinking].include?(@model_picker_kind.to_s) && !@config.role_specific_agent_defaults?

        roles = %w[head worker]
        index = roles.index(@model_picker_role) || 0
        @model_picker_role = roles[(index + step.to_i) % roles.length]
        @model_picker_index = 0
        @model_picker_query = +""
      end

      def selected_model_picker_entry(entries)
        return nil if entries.empty?

        entries[@model_picker_index.to_i.clamp(0, entries.length - 1)]
      end

      # Selecting a row is exactly `/model <provider/model>`: the same parser, the
      # same `SetDefaultSessionModel` validation, the same journaling, and the same
      # log line. The picker never writes session defaults itself.
      def apply_model_picker_entry(entry, on_submit, state)
        unless entry
          # Expected unavailability (no catalog, or a query that matched nothing)
          # is already rendered inside the popup. Do not duplicate it in chat.
          return false
        end

        kind = @model_picker_kind
        role = @model_picker_role
        if kind == "theme"
          original = @theme_picker_original
          close_model_picker(restore_theme: false)
          @theme_picker_pending_original = original
        else
          close_model_picker
        end
        command = case kind
                  when "thinking"
                    "/thinking #{role} #{entry.fetch("level")}"
                  when "theme"
                    "/theme #{entry.fetch("reference")}"
                  when "harness"
                    "/harness #{role} #{entry.fetch("reference")}"
                  else
                    "/model #{role} #{entry.fetch("reference")}"
                  end
        submit_prompt(command, on_submit, state)
        true
      end

      # Refreshing is the kernel's job: the picker submits `/models refresh`, the
      # kernel re-asks the harness and persists the snapshot, and the next frame
      # renders the new list. The picker stays open while that happens.
      def refresh_model_catalog(on_submit, state)
        command = ["/models", @model_picker_harness, "refresh"].compact.join(" ")
        submit_prompt(command, on_submit, state)
        true
      end

      def open_question_picker(state)
        @question_picker_active = true
        @question_picker_index = 0
        close_delivery_pr_picker
        close_model_picker
        true
      end

      def close_question_picker
        @question_picker_active = false
        @question_picker_index = 0
      end

      def question_picker_entries(state)
        QuestionPicker.entries(state)
      end

      def handle_question_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        entries = question_picker_entries(state)
        return handle_question_picker_mouse(key, unchanged, state, entries) if mouse_event?(key)

        if keybinding?("suggestion_previous", key)
          move_question_picker(-1, entries.length)
          return unchanged
        end
        if keybinding?("suggestion_next", key)
          move_question_picker(1, entries.length)
          return unchanged
        end
        if keybinding?("submit", key)
          return apply_question_picker_entry(selected_question_picker_entry(entries), unchanged)
        end
        if keybinding?("cancel_navigation", key)
          close_question_picker
          return unchanged
        end

        close_question_picker
        nil
      end

      def handle_question_picker_mouse(key, unchanged, state, entries)
        return unchanged unless mouse_button_press?(key) || mouse_wheel?(key)

        hit = layout.question_picker_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        if mouse_wheel?(key)
          return nil if hit == :outside

          move_question_picker(mouse_wheel_up?(key) ? -1 : 1, entries.length)
          return unchanged
        end

        if hit.is_a?(Integer)
          apply_question_picker_entry(entries[hit], unchanged)
        elsif hit == :outside
          close_question_picker
          unchanged
        else
          unchanged
        end
      end

      def move_question_picker(step, count)
        return if count <= 0

        @question_picker_index = (@question_picker_index.to_i + step) % count
      end

      def selected_question_picker_entry(entries)
        return nil if entries.empty?

        entries[@question_picker_index.to_i.clamp(0, entries.length - 1)]
      end

      def apply_question_picker_entry(entry, unchanged)
        # The empty-list explanation is already rendered inside the popup. Keep
        # Enter inert there rather than duplicating expected unavailability in chat.
        return unchanged unless entry

        close_question_picker
        command = "/answer #{entry.fetch("id")} "
        [command, command.chars.length, NO_SLASH_SELECTION]
      end

      def open_delivery_pr_picker(state)
        entries = OpenPullRequests.entries(state)
        # Keep the empty explanation in the same bordered popup as a populated
        # picker. Previously `/prs`/Ctrl-B appended this expected state to chat,
        # which made the picker contract depend on whether a PR happened to be
        # available at that instant.
        @delivery_pr_picker_active = true
        @delivery_pr_picker_index = @delivery_pr_picker_index.to_i.clamp(0, [entries.length - 1, 0].max)
        close_question_picker
        close_model_picker
        true
      end

      def close_delivery_pr_picker
        @delivery_pr_picker_active = false
      end

      # A small modal list: it owns the arrow keys, Enter, Esc, and clicks while it
      # is up. Any other key closes it and is then handled normally, so the picker
      # can never trap the composer.
      def handle_delivery_pr_picker_key(key, input_buffer, input_cursor, slash_suggestion_index, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        entries = OpenPullRequests.entries(state)
        return handle_delivery_pr_picker_mouse(key, unchanged, state, entries) if mouse_event?(key)

        if keybinding?("suggestion_previous", key)
          move_delivery_pr_picker(-1, entries.length)
          return unchanged
        end
        if keybinding?("suggestion_next", key)
          move_delivery_pr_picker(1, entries.length)
          return unchanged
        end
        if keybinding?("submit", key)
          open_delivery_pr_entry(selected_delivery_pr_entry(entries))
          close_delivery_pr_picker
          return unchanged
        end
        if keybinding?("cancel_navigation", key) || keybinding?("open_delivery_pr", key)
          close_delivery_pr_picker
          return unchanged
        end

        close_delivery_pr_picker
        nil
      end

      def handle_delivery_pr_picker_mouse(key, unchanged, state, entries)
        return unchanged unless mouse_button_press?(key) || mouse_wheel?(key)

        hit = layout.delivery_pr_picker_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        if mouse_wheel?(key)
          return nil if hit == :outside

          move_delivery_pr_picker(mouse_wheel_up?(key) ? -1 : 1, entries.length)
          return unchanged
        end

        # Click-away dismisses; a click on a row opens it.
        if hit.is_a?(Integer)
          open_delivery_pr_entry(entries[hit])
          close_delivery_pr_picker
        elsif hit == :outside
          close_delivery_pr_picker
        end
        unchanged
      end

      def move_delivery_pr_picker(step, count)
        return if count <= 0

        @delivery_pr_picker_index = (@delivery_pr_picker_index.to_i + step) % count
      end

      # The list is rebuilt from state every frame, so a PR that merged (and left
      # the list) must not leave the highlight pointing past the end.
      def selected_delivery_pr_entry(entries)
        return nil if entries.empty?

        entries[@delivery_pr_picker_index.to_i.clamp(0, entries.length - 1)]
      end

      def open_delivery_pr_entry(entry)
        return false unless entry

        result = pull_request_opener.open(entry.fetch("url"))
        return true if open_succeeded?(result)

        append_jump_response(result.fetch("message", "Could not open pull request ##{entry.fetch("number", "?")}."))
        false
      rescue StandardError => e
        append_jump_response("Could not open pull request ##{entry.fetch("number", "?")}: #{e.message}")
        false
      end

      def open_pr_by_agent_id(state, agent_id, silent_fail: false)
        record = pr_record_for_id(state, agent_id)
        unless record
          append_jump_response("Agent tree item #{agent_id} does not exist.") unless silent_fail
          return false
        end

        pr_url = AgentTreeNavigation.agent_pr_url(record)
        unless pr_url
          append_jump_response("Agent tree item #{agent_id} does not have an attached pull request yet.") unless silent_fail
          return false
        end

        result = pull_request_opener.open(pr_url)
        # Opening a PR is a transient UI action: only failures are worth a log entry.
        return true if open_succeeded?(result)

        append_jump_response(result.fetch("message", "Could not open pull request for #{agent_id}.")) unless silent_fail
        false
      rescue StandardError => e
        append_jump_response("Could not open pull request for #{agent_id}: #{e.message}") unless silent_fail
        false
      end

      def open_succeeded?(result)
        status = result.is_a?(Hash) ? result.fetch("status", nil).to_s : ""
        !%w[failed rejected].include?(status)
      end

      def pr_record_for_id(state, id)
        issue = Array(state["issues"]).find { |candidate| candidate["id"].to_s == id.to_s }
        return issue if issue

        agent = Array(state["agents"]).find { |candidate| candidate["id"].to_s == id.to_s }
        return nil unless agent
        return agent unless agent.fetch("type", nil) == "worker"

        worker_issue = Array(state["issues"]).find { |candidate| candidate["id"].to_s == agent.fetch("issue_id", nil).to_s }
        AgentTreeNavigation.agent_pr_url(worker_issue || {}) ? worker_issue : agent
      end
    end
  end
end
