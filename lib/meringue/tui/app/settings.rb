# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The full-screen Settings and first-run Setup surface: its rows, its editors, and saving it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def open_settings(_state, mode: "settings", setup_origin: "manual")
        @settings_draft = Settings::Draft.new(config)
        @settings_active = true
        @settings_mode = mode.to_s == "setup" ? "setup" : "settings"
        @settings_setup_auto = @settings_mode == "setup" && setup_origin.to_s == "auto"
        @settings_setup_outcome = nil
        @settings_category_index = 0
        @settings_row_index = 0
        @settings_expanded_advanced = {}
        @settings_editor = nil
        @settings_picker = nil
        @settings_picker_theme_original = nil
        @settings_keybinding_capture = nil
        @settings_footer_focus = false
        @settings_footer_button = "next"
        @settings_discard_confirm = false
        @settings_saving = false
        @github_access_test_result = nil
        @harness_check_result = nil
        @harness_availability = harness_availability_snapshot
        preselect_detected_harnesses if setup_mode?
        close_delivery_pr_picker
        close_model_picker
        close_question_picker
        @force_full_redraw = true
        true
      rescue StandardError => e
        append_jump_response("Could not open #{@settings_mode == "setup" ? "Setup" : "Settings"}: #{e.message}")
        false
      end

      def close_settings(discard: false)
        @settings_draft&.restore_theme if discard
        @settings_active = false
        @settings_draft = nil
        @settings_category_index = 0
        @settings_row_index = 0
        @settings_expanded_advanced = {}
        @settings_editor = nil
        @settings_picker = nil
        @settings_picker_theme_original = nil
        @settings_keybinding_capture = nil
        @settings_footer_focus = false
        @settings_footer_button = "next"
        @settings_discard_confirm = false
        @settings_saving = false
        @github_access_test_result = nil
        @harness_check_result = nil
        @harness_availability = nil
        @settings_setup_auto = false
        @settings_setup_outcome = nil
        @settings_mode = "settings"
        close_question_picker
        @force_full_redraw = true
        true
      end

      def setup_mode?
        @settings_mode == "setup"
      end

      # Welcome and Done carry no controls, so the navigation action is the only
      # thing Enter can mean there. Derived rather than stored: whichever way the
      # step was reached, a card with nothing to select focuses its action.
      def settings_footer_focused?
        return true if setup_mode? && settings_rows.empty?

        @settings_footer_focus ? true : false
      end

      def setup_animation_phase
        return 0 unless setup_mode? && @settings_draft
        return 0 unless @settings_draft.value("appearance.animations") == true

        (monotonic_time * 3).floor % 4
      rescue StandardError
        0
      end

      def settings_categories
        return [] unless @settings_draft

        setup_mode? ? Settings::SetupFlow.steps : @settings_draft.categories
      end

      def settings_category
        categories = settings_categories
        categories[@settings_category_index.to_i.clamp(0, [categories.length - 1, 0].max)].to_s
      end

      def settings_rows
        return [] unless @settings_draft
        if setup_mode?
          return setup_rows.filter_map do |row|
            decorate_github_access_action_row(row) if settings_row_visible?(row)
          end
        end

        expanded = settings_advanced_expanded?
        plain, advanced = @settings_draft
                          .definitions_for(settings_category, include_advanced: true)
                          .select { |definition| settings_row_visible?(@settings_draft.row(definition)) }
                          .partition { |definition| !definition.advanced }
        rows = plain.map { |definition| decorate_github_access_action_row(@settings_draft.row(definition)) }
        return rows if advanced.empty?

        # The reveal is a disclosure, not a door: it keeps its place in the list
        # whether it is open or closed, so the row that revealed the advanced
        # settings is also the row that puts them away.
        rows << settings_advanced_toggle_row(advanced.length, expanded)
        rows.concat(advanced.map { |definition| decorate_github_access_action_row(@settings_draft.row(definition)) }) if expanded
        rows
      end

      def settings_row_visible?(row)
        return true unless row.fetch("id", nil) == "experiments.github_support_test_access"

        @settings_draft.value("experiments.github_support") == true
      rescue KeyError
        false
      end

      def decorate_github_access_action_row(row)
        return row unless row.fetch("id", nil) == "experiments.github_support_test_access"

        enabled = @settings_draft.value("experiments.github_support") == true
        result = @github_access_test_result
        display_value = if !enabled
                          "Enable support"
                        elsif result
                          github_access_test_label(result.fetch("outcome", result.fetch("status", "unavailable")))
                        else
                          "Run test"
                        end
        description = if !enabled
                        "Enable GitHub support above before running this read-only check."
                      elsif result
                        result.fetch("message", row.fetch("description", "")).to_s
                      else
                        row.fetch("description", "")
                      end
        row.merge(
          "display_value" => display_value,
          "description" => description,
          "disabled" => !enabled
        )
      rescue KeyError
        row
      end

      def github_access_test_label(outcome)
        {
          "testing" => "Testing…",
          "success" => "Ready",
          "disabled" => "Disabled",
          "unavailable" => "Unavailable",
          "missing_tooling" => "GitHub CLI missing",
          "unauthenticated" => "Not authenticated",
          "permission_denied" => "Permission denied",
          "repository_read_failure" => "Repository not readable",
          "timeout" => "Timed out",
          "malformed_remote" => "Malformed remote"
        }.fetch(outcome.to_s, outcome.to_s.tr("_", " ").capitalize)
      end

      def synthetic_settings_row(id, label, description, display_value, dirty: false, source: "setup")
        {
          "id" => id,
          "label" => label,
          "description" => description,
          "type" => "action",
          "editor" => "action",
          "display_value" => display_value,
          "default_value" => display_value,
          "source" => source,
          "dirty" => dirty,
          "read_only" => false,
          "apply_mode" => "none"
        }
      end

      def settings_category_counts
        settings_categories.to_h do |category|
          if setup_mode?
            rows = setup_rows
            count = category == settings_category ? rows.length : 0
            [category, { "visible" => count, "total" => count, "hidden_advanced" => 0 }]
          else
            definitions = @settings_draft.definitions_for(category, include_advanced: true).select do |definition|
              settings_row_visible?(@settings_draft.row(definition))
            end
            advanced = definitions.count(&:advanced)
            hidden = @settings_expanded_advanced.fetch(category, false) ? 0 : advanced
            visible = definitions.length - hidden
            [category, { "visible" => visible, "total" => definitions.length, "hidden_advanced" => hidden }]
          end
        end
      end

      def settings_picker_snapshot
        return nil unless @settings_picker

        options = settings_picker_options
        @settings_picker["index"] = @settings_picker.fetch("index", 0).to_i.clamp(0, [options.length - 1, 0].max)
        @settings_picker.merge(
          "options" => options,
          "query" => @settings_picker.fetch("query", "").to_s,
          "row" => @settings_picker.fetch("row", {}).merge(
            "error" => (@settings_draft ? @settings_draft.errors[@settings_picker.fetch("id")] : nil)
          ).compact
        ).compact
      end

      def settings_snapshot(state = nil)
        return nil unless @settings_active && @settings_draft

        rows = settings_rows
        @settings_row_index = @settings_row_index.to_i.clamp(0, [rows.length - 1, 0].max)
        counts = settings_category_counts
        current_counts = counts.fetch(settings_category, {})
        editor = if @settings_editor
                   row = @settings_editor.fetch("row", {}).merge(
                     "error" => @settings_draft.errors[@settings_editor.fetch("id")]
                   ).compact
                   @settings_editor.merge("row" => row)
                 end
        capture = if @settings_keybinding_capture
                    @settings_keybinding_capture.merge("row" => @settings_keybinding_capture.fetch("row", {}).merge(
                      "error" => @settings_keybinding_capture.fetch("error", nil)
                    ).compact)
                  end
        {
          "active" => true,
          "mode" => @settings_mode,
          "categories" => settings_categories,
          "category" => settings_category,
          "category_index" => @settings_category_index,
          "category_counts" => counts,
          "visible_setting_count" => current_counts.fetch("visible", rows.length),
          "hidden_advanced_count" => current_counts.fetch("hidden_advanced", 0),
          "rows" => rows,
          "row_index" => @settings_row_index,
          "dirty" => @settings_draft.dirty?,
          "saving" => @settings_saving,
          "advanced" => settings_advanced_expanded?,
          "advanced_available" => settings_advanced_count.positive?,
          "editor" => editor,
          "keybinding_capture" => capture,
          "picker" => settings_picker_snapshot,
          "footer_focus" => settings_footer_focused?,
          "footer_button" => @settings_footer_button,
          "setup_last_step" => setup_mode? && @settings_category_index.to_i == settings_categories.length - 1,
          "discard_confirm" => @settings_discard_confirm.is_a?(String),
          "confirmation" => (@settings_discard_confirm if @settings_discard_confirm.is_a?(String)),
          "setup_auto" => @settings_setup_auto,
          "setup_step" => setup_mode? ? @settings_category_index + 1 : nil,
          "setup_step_count" => setup_mode? ? settings_categories.length : nil,
          "setup_animations" => setup_mode? ? @settings_draft.value("appearance.animations") == true : nil,
          "setup_animation_phase" => setup_mode? ? setup_animation_phase : nil,
          "setup_summary" => (setup_summary_entries if setup_mode? && settings_category == Settings::SetupFlow::DONE),
          "error_count" => @settings_draft.errors.length,
          "global_error" => @settings_draft.global_error,
          "width" => render_width,
          "height" => render_height
        }.compact
      end

      def handle_settings_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        if render_width < Settings::MIN_WIDTH || render_height < Settings::MIN_HEIGHT
          close_settings(discard: true) if hard_escape_key?(key)
          return unchanged
        end
        if @settings_keybinding_capture
          return handle_settings_keybinding_capture_key(key, unchanged)
        end
        if @settings_picker
          return handle_settings_picker_key(key, unchanged, on_submit, state)
        end
        if mouse_event?(key)
          return handle_settings_mouse(key, unchanged, on_submit, state)
        end

        if @settings_discard_confirm.is_a?(String)
          if ENTER_KEYS.include?(key)
            if @settings_discard_confirm == "skip"
              @settings_discard_confirm = false
              save_settings(on_submit, state, onboarding_outcome: "skipped")
            else
              close_settings(discard: true)
            end
          elsif hard_escape_key?(key)
            @settings_discard_confirm = false
          end
          return unchanged
        end

        if @settings_editor
          return handle_settings_editor_key(key, unchanged, on_submit, state)
        end
        rows = settings_rows
        if hard_save_key?(key)
          setup_mode? ? setup_next_or_finish(on_submit, state) : save_settings(on_submit, state)
        elsif hard_escape_key?(key)
          request_settings_cancel
        elsif setup_mode? && (BACKSPACE_KEYS.include?(key) || DELETE_KEYS.include?(key))
          move_settings_category(-1)
        elsif TAB_KEYS.include?(key) || FOCUS_FORWARD_KEYS.include?(key)
          move_settings_category(1)
        elsif SHIFT_TAB_KEYS.include?(key)
          move_settings_category(-1)
        elsif UP_KEYS.include?(key) || keybinding?("suggestion_previous", key)
          move_settings_row(-1)
        elsif DOWN_KEYS.include?(key) || keybinding?("suggestion_next", key)
          move_settings_row(1)
        elsif PAGE_UP_KEYS.include?(key)
          move_settings_row(-settings_page_size)
        elsif PAGE_DOWN_KEYS.include?(key)
          move_settings_row(settings_page_size)
        elsif HOME_KEYS.include?(key)
          @settings_row_index = 0
          @settings_footer_focus = false
          @settings_footer_button = "next"
        elsif END_KEYS.include?(key)
          @settings_row_index = [rows.length - 1, 0].max
          @settings_footer_focus = false
          @settings_footer_button = "next"
        elsif LEFT_KEYS.include?(key)
          cycle_or_move_settings(-1, state)
        elsif RIGHT_KEYS.include?(key)
          cycle_or_move_settings(1, state)
        elsif key == " "
          activate_settings_row(state, toggle_only: true, on_submit: on_submit) unless setup_mode?
        elsif ENTER_KEYS.include?(key)
          if setup_mode? && settings_footer_focused?
            activate_setup_footer(on_submit, state)
          else
            activate_settings_row(state, on_submit: on_submit)
          end
        elsif key.to_s.downcase == "a"
          toggle_settings_advanced
        end
        unchanged
      rescue StandardError => e
        @settings_draft&.apply_save_failure("Settings input failed: #{e.message}")
        unchanged
      end

      def handle_settings_keybinding_capture_key(key, unchanged)
        capture = @settings_keybinding_capture
        if mouse_event?(key)
          capture["error"] = "Mouse input cannot be bound here; press a keyboard key, Esc, or Backspace."
          return unchanged
        end
        if hard_escape_key?(key)
          @settings_keybinding_capture = nil
          return unchanged
        end
        if BACKSPACE_KEYS.include?(key) || DELETE_KEYS.include?(key)
          id = capture.fetch("id")
          @settings_draft.set(id, [])
          @settings_keybinding_capture = nil unless @settings_draft.errors.key?(id)
          capture["error"] = @settings_draft.errors[id] if @settings_keybinding_capture
          return unchanged
        end

        name = Keybindings.capture_name(key)
        unless name
          capture["error"] = "That input cannot be used as a keybinding; press one key at a time."
          return unchanged
        end

        id = capture.fetch("id")
        @settings_draft.set(id, [name])
        if @settings_draft.errors.key?(id)
          capture["error"] = @settings_draft.errors[id]
        else
          @settings_keybinding_capture = nil
        end
        unchanged
      end

      def handle_settings_editor_key(key, unchanged, on_submit, state)
        editor = @settings_editor
        if hard_escape_key?(key)
          @settings_editor = nil
          return unchanged
        end
        if hard_save_key?(key)
          if apply_settings_editor
            @settings_editor = nil
            setup_mode? ? setup_next_or_finish(on_submit, state) : save_settings(on_submit, state)
          end
          return unchanged
        end
        if keybinding?("newline", key)
          insert_settings_editor_text("\n")
          return unchanged
        end
        if keybinding?("submit", key)
          @settings_editor = nil if apply_settings_editor
          return unchanged
        end
        if paste_key?(key) || plain_text_paste_key?(key)
          insert_settings_editor_text(paste_key?(key) ? paste_text(key) : key)
          return unchanged
        end
        if (TAB_KEYS.include?(key) || keybinding?("complete_suggestion", key)) && editor.fetch("id") == "experiments.worker_spawning_guidance_prompt"
          complete_settings_guidance_editor(state)
          return unchanged
        end

        selection_action = SELECTION_MOVEMENTS.keys.find { |action| keybinding?(action, key) }
        if selection_action
          move_settings_editor_selection(SELECTION_MOVEMENTS.fetch(selection_action), state)
          return unchanged
        end
        if keybinding?("copy_selection", key) && settings_editor_selection_range
          copy_settings_editor_selection
          return unchanged
        end
        if keybinding?("cut_selection", key) && settings_editor_selection_range
          copy_settings_editor_selection
          delete_settings_editor_selection
          return unchanged
        end
        if keybinding?("paste_clipboard", key)
          text = Clipboard.paste
          if text.to_s.empty?
            editor["status"] = "clipboard is empty"
          else
            insert_settings_editor_text(text)
          end
          return unchanged
        end
        if ctrl_c_key?(key)
          editor["buffer"] = +""
          editor["cursor"] = 0
          clear_settings_editor_selection
          return unchanged
        end

        if selection_edit_key?(key) && settings_editor_selection_range
          delete_settings_editor_selection
          return unchanged
        end
        if keybinding?("delete_backward", key)
          update_settings_editor_buffer(*delete_backward(editor.fetch("buffer"), editor.fetch("cursor")))
          return unchanged
        end
        if keybinding?("delete_forward", key)
          update_settings_editor_buffer(*delete_forward(editor.fetch("buffer"), editor.fetch("cursor")))
          return unchanged
        end
        if keybinding?("delete_word_backward", key)
          update_settings_editor_buffer(*delete_backward_word(editor.fetch("buffer"), editor.fetch("cursor")))
          return unchanged
        end
        if keybinding?("delete_word_forward", key)
          update_settings_editor_buffer(*delete_forward_word(editor.fetch("buffer"), editor.fetch("cursor")))
          return unchanged
        end

        moved = settings_editor_cursor_after_navigation(key, state)
        if moved != editor.fetch("cursor").to_i
          editor["cursor"] = moved
          clear_settings_editor_selection
          return unchanged
        end
        if printable_key?(key)
          insert_settings_editor_text(key)
          return unchanged
        end
        unchanged
      end

      def complete_settings_guidance_editor(state)
        editor = @settings_editor
        chars = editor.fetch("buffer").chars
        cursor = editor.fetch("cursor").to_i.clamp(0, chars.length)
        prefix = chars.first(cursor).join
        suffix = chars.drop(cursor).join
        records = Input::SlashCommandParser.command_suggestion_records(prefix, limit: nil, state: state)
        record = records.find { |candidate| candidate.fetch("completion", "") != prefix }
        return false unless record

        completion = record.fetch("completion")
        editor["buffer"] = completion + suffix
        editor["cursor"] = completion.chars.length
        clear_settings_editor_selection
        true
      end

      def insert_settings_editor_text(text)
        editor = @settings_editor
        delete_settings_editor_selection if settings_editor_selection_range
        buffer, cursor = insert_text(editor.fetch("buffer"), editor.fetch("cursor"), text)
        update_settings_editor_buffer(buffer, cursor)
      end

      def settings_editor_selection_range
        selection = @settings_editor&.fetch("selection", nil)
        return nil unless selection.is_a?(Hash)

        length = @settings_editor.fetch("buffer", "").chars.length
        start_index = selection.fetch("start", 0).to_i.clamp(0, length)
        finish_index = selection.fetch("end", 0).to_i.clamp(0, length)
        return nil if finish_index <= start_index

        (start_index...finish_index)
      end

      def clear_settings_editor_selection
        return unless @settings_editor

        @settings_editor.delete("selection")
        @settings_editor.delete("selection_anchor")
      end

      def update_settings_editor_buffer(buffer, cursor)
        @settings_editor["buffer"] = buffer
        @settings_editor["cursor"] = cursor
        @settings_editor.delete("status")
        clear_settings_editor_selection
        [buffer, cursor]
      end

      def delete_settings_editor_selection
        range = settings_editor_selection_range
        return false unless range

        buffer, cursor = delete_range(@settings_editor.fetch("buffer"), range)
        update_settings_editor_buffer(buffer, cursor)
        true
      end

      def copy_settings_editor_selection
        range = settings_editor_selection_range
        return false unless range

        text = @settings_editor.fetch("buffer").chars[range].join
        transport = Clipboard.copy(text, output: clipboard_output)
        @settings_editor["status"] = transport ? copy_status_text(text) : "clipboard unavailable"
        !transport.nil?
      end

      def move_settings_editor_selection(movement, state)
        editor = @settings_editor
        cursor = editor.fetch("cursor").to_i
        anchor = editor.fetch("selection_anchor", cursor).to_i
        moved = settings_editor_cursor_for_movement(movement, state: state)
        editor["cursor"] = moved
        editor["selection_anchor"] = anchor
        start_index, finish_index = [anchor, moved].minmax
        if finish_index > start_index
          editor["selection"] = { "start" => start_index, "end" => finish_index }
        else
          editor.delete("selection")
        end
        moved
      end

      def settings_editor_cursor_after_navigation(key, state)
        movement = if keybinding?("cursor_left", key) then :left
                   elsif keybinding?("cursor_right", key) then :right
                   elsif keybinding?("cursor_up", key) then :up
                   elsif keybinding?("cursor_down", key) then :down
                   elsif keybinding?("cursor_home", key) then :home
                   elsif keybinding?("cursor_end", key) then :end
                   elsif keybinding?("cursor_word_left", key) then :word_left
                   elsif keybinding?("cursor_word_right", key) then :word_right
                   end
        return @settings_editor.fetch("cursor").to_i unless movement

        settings_editor_cursor_for_movement(movement, state: state)
      end

      def settings_editor_cursor_for_movement(movement, state: nil)
        editor = @settings_editor
        buffer = editor.fetch("buffer").to_s
        chars = buffer.chars
        cursor = editor.fetch("cursor").to_i.clamp(0, chars.length)
        case movement
        when :left then [cursor - 1, 0].max
        when :right then [cursor + 1, chars.length].min
        when :up, :down
          MultilineInput.vertical_cursor(
            buffer,
            cursor,
            direction: movement,
            width: layout.settings_text_width(
              state || compose_state(-> { State::Models.empty_state }, ""),
              width: render_width,
              height: render_height
            )
          )
        when :home then current_line_start(chars, cursor)
        when :end then current_line_end(chars, cursor)
        when :word_left then previous_word_boundary(chars, cursor)
        when :word_right then next_word_start(chars, cursor)
        else cursor
        end
      end

      def apply_settings_editor
        id = @settings_editor.fetch("id")
        applied = @settings_draft.parse_editor(id, @settings_editor.fetch("buffer"))
        @settings_draft.preview_theme if id == "appearance.theme" && applied
        !applied.nil?
      end

      def handle_settings_mouse(key, unchanged, on_submit, state)
        if mouse_drag?(key) && @settings_picker
          hit = layout.settings_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
          if hit.is_a?(Array) && hit.first == :picker
            @settings_picker["index"] = hit.last.to_i
            preview_settings_picker_theme
          end
          return unchanged
        end
        if mouse_wheel_up?(key) || mouse_wheel_down?(key)
          hit = layout.settings_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
          move_settings_row(mouse_wheel_up?(key) ? -3 : 3) unless hit == :inert
          return unchanged
        end
        return unchanged unless mouse_button_press?(key) && key.fetch("button", 0).to_i.zero?

        hit = layout.settings_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        case hit
        when :save, :next
          setup_mode? ? setup_next_or_finish(on_submit, state) : save_settings(on_submit, state)
        when :cancel
          request_settings_cancel
        when Array
          kind, index = hit
          if kind == :picker
            option = settings_picker_options[index.to_i]
            apply_settings_picker_choice(option) if option
          elsif kind == :category
            @settings_category_index = index.to_i.clamp(0, [settings_categories.length - 1, 0].max)
            @settings_row_index = 0
            @settings_footer_focus = false
            @settings_footer_button = "next"
          elsif %i[row toggle].include?(kind)
            @settings_row_index = index.to_i.clamp(0, [settings_rows.length - 1, 0].max)
            @settings_footer_focus = false
            @settings_footer_button = "next"
            activate_settings_row(state, toggle_only: kind == :toggle, on_submit: on_submit)
          end
        end
        unchanged
      end

      def hard_escape_key?(key)
        key == "\e" || keybinding?("cancel_navigation", key)
      end

      def hard_save_key?(key)
        CTRL_S_KEYS.include?(key)
      end

      def move_settings_category(delta)
        count = settings_categories.length
        return if count.zero?

        return if setup_mode? && delta.to_i.positive? && block_setup_advance?

        @settings_category_index = if setup_mode?
                                     (@settings_category_index.to_i + delta.to_i).clamp(0, count - 1)
                                   else
                                     (@settings_category_index.to_i + delta.to_i) % count
                                   end
        @settings_row_index = 0
        @settings_footer_focus = false
        @settings_footer_button = "next"
      end

      def move_settings_row(delta)
        count = settings_rows.length
        return if count.zero?

        if setup_mode?
          if delta.to_i.positive?
            if @settings_footer_focus
              return
            elsif @settings_row_index.to_i >= count - 1
              @settings_footer_focus = true
              @settings_footer_button = "next"
            else
              @settings_row_index += 1
            end
          elsif delta.to_i.negative?
            if @settings_footer_focus
              @settings_footer_focus = false
              @settings_footer_button = "next"
              @settings_row_index = [count - 1, 0].max
            else
              @settings_row_index = [@settings_row_index.to_i - 1, 0].max
            end
          end
          return
        end

        @settings_row_index = (@settings_row_index.to_i + delta.to_i) % count
      end

      def settings_page_size
        [render_height - 8, 1].max
      end

      def selected_settings_row
        rows = settings_rows
        rows[@settings_row_index.to_i.clamp(0, [rows.length - 1, 0].max)]
      end

      def cycle_or_move_settings(delta, state)
        return if setup_mode? && @settings_footer_focus

        row = selected_settings_row
        return move_settings_row(delta) if setup_mode? && !row

        if setup_mode?
          @settings_draft.set(row.fetch("id"), delta.to_i.positive?) if row.fetch("editor", nil) == "checkbox"
          return
        end

        return unless row
        if %w[selector enum].include?(row.fetch("editor", nil))
          @settings_draft.cycle(row.fetch("id"), delta)
          @settings_draft.preview_theme if row.fetch("id") == "appearance.theme"
        elsif row.fetch("editor", nil) == "model"
          cycle_settings_model(row, delta, state)
        end
      end

      # The model list a settings row should offer belongs to the harness that row is about, so a
      # user editing the worker model is never shown another backend's catalog.
      def settings_model_harness(state = nil, role: nil)
        selected_role = role.to_s.strip.downcase
        selected_role = "worker" unless %w[head worker].include?(selected_role)
        configured = @settings_draft&.value("agent.#{selected_role}_harness").to_s.strip
        if configured.empty?
          configured = begin
            Harness::Registry.new(config: config).worker_provider.to_s.strip
          rescue StandardError
            ""
          end
        end
        if configured.to_s.strip.empty? && state.is_a?(Hash)
          configured = state.dig("metadata", "active_worker_harness") || state.dig("metadata", "active_harness")
        end
        configured.to_s.strip.empty? ? nil : configured
      rescue StandardError
        nil
      end

      def cycle_settings_model(row, delta, state)
        role = row.fetch("id", "").to_s.split(".").fetch(1, "").sub(/_model\z/, "")
        options = ModelPicker.entries(state, harness: settings_model_harness(state, role: role), query: "").map { |entry| entry.fetch("reference") }
        current = @settings_draft.value(row.fetch("id")).to_s
        options.unshift(current) unless options.include?(current)
        return if options.empty?

        index = options.index(current) || 0
        @settings_draft.set(row.fetch("id"), options[(index + delta.to_i) % options.length])
      end

      def activate_settings_row(state, toggle_only: false, on_submit: nil)
        row = selected_settings_row
        return false unless row

        id = row.fetch("id")
        if id == "experiments.worker_spawning_guidance_prompt"
          return false if toggle_only

          return edit_guidance_prompt(row)
        end
        if id == "_show_advanced"
          return toggle_settings_advanced
        end
        if id == "setup.run_again"
          close_settings(discard: true)
          return handle_local_setup_command(state)
        end
        if id == "_setup_begin"
          move_settings_category(1)
          return true
        end
        if id == "experiments.github_support_test_access"
          return test_github_access_from_settings(state, on_submit)
        end
        if id == "setup.check_harness"
          return false if toggle_only

          return check_harness_from_settings
        end
        return false if row.fetch("read_only", false)

        case row.fetch("editor", nil)
        when "checkbox"
          @settings_draft.toggle(id)
        when "keybinding"
          return false if toggle_only
          open_settings_keybinding_capture(row)
        when "selector", "model", "editor_command"
          return false if toggle_only
          if row.fetch("editor") == "editor_command"
            open_settings_picker(row, state)
          else
            setup_mode? ? open_settings_picker(row, state) : (row.fetch("editor") == "model" ? open_settings_editor(row) : @settings_draft.cycle(id, 1))
          end
          @settings_draft.preview_theme if id == "appearance.theme" && !@settings_picker
        else
          return false if toggle_only
          open_settings_editor(row)
        end
        true
      end

      def test_github_access_from_settings(state, on_submit)
        unless @settings_draft.value("experiments.github_support") == true
          @github_access_test_result = {
            "outcome" => "unavailable",
            "message" => "Enable GitHub support in Settings → Experiments before testing access."
          }
          return false
        end

        @github_access_test_result = {
          "outcome" => "testing",
          "message" => "Testing GitHub authentication and read access…"
        }
        # Setup may test an opt-in before its draft is persisted. The marker is
        # interpreted by the kernel only for this explicit command and does not
        # mutate the saved configuration.
        command = setup_mode? ? "/github test --draft-support" : "/github test"
        submit_prompt(command, on_submit, state)
        true
      rescue StandardError => e
        @github_access_test_result = {
          "outcome" => "unavailable",
          "message" => "GitHub access test could not start: #{e.message}"
        }
        false
      end

      def focus_setup_setting(id)
        step = Settings::SetupFlow.step_for_setting(id)
        return false unless step

        @settings_category_index = settings_categories.index(step) || 0
        @settings_row_index = settings_rows.index { |row| row.fetch("id", nil) == id.to_s } || 0
        true
      end

      def open_settings_picker(row, state)
        id = row.fetch("id")
        options = if row.fetch("editor") == "model"
                    role = row.fetch("id", "").to_s.split(".").fetch(1, "").sub(/_model\z/, "")
                    ModelPicker.entries(state, harness: settings_model_harness(state, role: role), query: "").map do |entry|
                      { "reference" => entry.fetch("reference"), "name" => entry.fetch("name", entry.fetch("reference")) }
                    end
                  elsif row.fetch("editor") == "editor_command"
                    Array(row.fetch("options", [])).map(&:to_s) + [Settings::EDITOR_CUSTOM_OPTION]
                  else
                    # An enum that carries labels shows them the way the model
                    # picker does: the label reads, the stored value stays
                    # visible beside it.
                    labels = row.fetch("option_labels", {}) || {}
                    values = Array(row.fetch("options", [])).map(&:to_s)
                    if values.any? { |value| labels[value].to_s != "" && labels[value] != value }
                      values.map { |value| { "reference" => value, "name" => labels.fetch(value, value) } }
                    else
                      values
                    end
                  end
        current_value = @settings_draft.value(id)
        current = if row.fetch("editor") == "editor_command"
                     Shellwords.join(Array(current_value))
                   else
                     current_value.to_s
                   end
        # An exact model reference the catalog does not list stays selectable, so
        # it is carried into the list. "Nothing chosen yet" is not a choice
        # though: offering it as the first row of a required field is how the
        # harness picker used to invite you to pick blank.
        keep_current = !current.empty? || row.fetch("editor") == "model"
        if keep_current && options.none? { |option| option.is_a?(Hash) ? option.fetch("reference") == current : option == current }
          options.unshift(row.fetch("editor") == "model" ? { "reference" => current, "name" => current } : current)
        end
        @settings_picker_theme_original = Style.current_colorscheme.to_s if id == "appearance.theme"
        @settings_picker = {
          "id" => id,
          "row" => row,
          "all_options" => options,
          "options" => options,
          "query" => "",
          "index" => [options.index { |option| option.is_a?(Hash) ? option.fetch("reference") == current : option == current } || 0, 0].max
        }
        preview_settings_picker_theme
        true
      end

      def handle_settings_picker_key(key, unchanged, _on_submit, _state)
        if mouse_event?(key)
          return handle_settings_mouse(key, unchanged, _on_submit, _state)
        end
        options = settings_picker_options
        if UP_KEYS.include?(key)
          @settings_picker["index"] = (@settings_picker.fetch("index", 0).to_i - 1) % [options.length, 1].max
          preview_settings_picker_theme
        elsif DOWN_KEYS.include?(key)
          @settings_picker["index"] = (@settings_picker.fetch("index", 0).to_i + 1) % [options.length, 1].max
          preview_settings_picker_theme
        elsif ENTER_KEYS.include?(key)
          option = options[@settings_picker.fetch("index", 0).to_i]
          apply_settings_picker_choice(option) if option
        elsif keybinding?("delete_word_backward", key)
          @settings_picker["query"] = ""
          @settings_picker["index"] = 0
          preview_settings_picker_theme
        elsif keybinding?("delete_backward", key)
          @settings_picker["query"] = @settings_picker.fetch("query", "").to_s.chars[0...-1].join
          @settings_picker["index"] = 0
          preview_settings_picker_theme
        elsif printable_key?(key)
          @settings_picker["query"] = "#{@settings_picker.fetch("query", "")}#{key}"
          @settings_picker["index"] = 0
          preview_settings_picker_theme
        elsif hard_escape_key?(key)
          cancel_settings_picker
        end
        unchanged
      end

      # Committing a picker choice, for both the key and the mouse. They were two
      # copies, and the mouse copy was missing the harness mirror: clicking a
      # harness during setup set one role and left the other empty, where
      # pressing Enter on the same row set both.
      def apply_settings_picker_choice(option)
        id = @settings_picker.fetch("id")
        if id == "workspace.editor" && option == Settings::EDITOR_CUSTOM_OPTION
          row = @settings_picker.fetch("row")
          @settings_picker = nil
          @settings_picker_theme_original = nil
          return open_settings_editor(row)
        end

        value = option.is_a?(Hash) ? option.fetch("reference") : option
        @settings_draft.set(id, value)
        pair_setup_harness(id, value) if setup_mode?
        @settings_draft.preview_theme if id == "appearance.theme"
        @settings_picker = nil
        @settings_picker_theme_original = nil
      end

      def preview_settings_picker_theme
        return unless @settings_picker&.fetch("id", nil) == "appearance.theme"

        option = settings_picker_options[@settings_picker.fetch("index", 0).to_i]
        theme = option.is_a?(Hash) ? option.fetch("reference", "") : option.to_s
        Style.configure!(theme) unless theme.empty? || Style.current_colorscheme.to_s == theme
      rescue ArgumentError
        nil
      end

      def cancel_settings_picker
        original = @settings_picker_theme_original
        @settings_picker = nil
        @settings_picker_theme_original = nil
        return unless original && !original.empty? && Style.current_colorscheme.to_s != original

        Style.configure!(original)
      rescue ArgumentError
        nil
      end

      def settings_picker_options
        return [] unless @settings_picker

        tokens = @settings_picker.fetch("query", "").to_s.downcase.split(/\s+/).reject(&:empty?)
        Array(@settings_picker.fetch("all_options", @settings_picker.fetch("options", []))).select do |option|
          next true if tokens.empty?

          haystack = if option.is_a?(Hash)
                       [option.fetch("reference", ""), option.fetch("name", "")].join(" ")
                     else
                       option.to_s
                     end.downcase
          tokens.all? { |token| haystack.include?(token) }
        end
      end

      def open_settings_keybinding_capture(row)
        @settings_draft.errors.delete(row.fetch("id"))
        @settings_keybinding_capture = {
          "id" => row.fetch("id"),
          "row" => row,
          "error" => nil
        }
      end

      def edit_guidance_prompt(row)
        original = @settings_draft.value(row.fetch("id")).to_s
        launcher = if workspace_controller&.respond_to?(:edit_text)
                     ->(text) { workspace_controller.edit_text(text: text, extension: ".md") }
                   else
                     editor = Workspace::EditorLauncher.from_config(config)
                     ->(text) { editor.edit_text(text, extension: ".md") }
                   end
        result = if terminal.respond_to?(:with_external_editor)
                   terminal.with_external_editor { launcher.call(original) }
                 else
                   launcher.call(original)
                 end
        if result.is_a?(Hash) && result.fetch("status", nil) == "edited"
          @settings_draft.set(row.fetch("id"), result.fetch("text", original).to_s)
          @settings_draft.clear_save_failure
        elsif !result.is_a?(Hash) || result.fetch("status", nil) != "cancelled"
          message = result.is_a?(Hash) ? result.fetch("message", "The original text was kept.") : "The original text was kept."
          @settings_draft.apply_save_failure(message)
        end
        @force_full_redraw = true
        true
      rescue StandardError => e
        @settings_draft.apply_save_failure("Could not edit the guided selection prompt: #{e.message}; the original text was kept.")
        @force_full_redraw = true
        true
      end

      def open_settings_editor(row)
        id = row.fetch("id")
        text = @settings_draft.editor_text(id)
        @settings_editor = {
          "id" => id,
          "row" => row,
          "buffer" => text,
          "cursor" => text.chars.length
        }
      end

      def request_settings_cancel
        if setup_mode?
          if @settings_setup_auto
            @settings_discard_confirm = "skip"
          elsif @settings_draft&.dirty?
            @settings_discard_confirm = "discard"
          else
            close_settings(discard: true)
          end
          return true
        end

        return close_settings(discard: true) unless @settings_draft&.dirty?

        @settings_discard_confirm = "discard"
        true
      end

      def activate_setup_footer(on_submit, state)
        setup_next_or_finish(on_submit, state)
      end

      def setup_next_or_finish(on_submit, state)
        if setup_mode? && @settings_category_index.to_i >= settings_categories.length - 1
          save_settings(on_submit, state, onboarding_outcome: "completed")
        else
          move_settings_category(1)
        end
      end

      def save_settings(on_submit, state, onboarding_outcome: nil)
        return false if @settings_saving

        # Completing setup is the one path that must not be able to produce an
        # install Meringue cannot use. A skip deliberately writes only the marker,
        # so it stays permissive.
        required = onboarding_outcome == "completed" ? Settings::SetupFlow::REQUIRED_SETTING_IDS : []
        unless @settings_draft.validate(required_ids: required)
          first_id = @settings_draft.errors.keys.first
          focus_settings_id(first_id) if first_id
          return false
        end

        changes = @settings_draft.changes
        unless onboarding_outcome.to_s.empty?
          explicit_experiments = Settings::SetupFlow.experiment_defaults(@settings_draft, explicit_only: true)
          changes = onboarding_outcome == "skipped" ? explicit_experiments : changes.merge(explicit_experiments)
        end
        if changes.empty? && onboarding_outcome.to_s.empty?
          close_settings(discard: false)
          return true
        end

        payload = {
          "base_fingerprint" => @settings_draft.baseline_fingerprint,
          "changes" => changes
        }
        payload["onboarding_outcome"] = onboarding_outcome unless onboarding_outcome.to_s.empty?
        encoded = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
        @settings_saving = true
        @settings_setup_outcome = onboarding_outcome
        @settings_draft.clear_save_failure
        submit_prompt("/config save #{encoded}", on_submit, state)
        true
      end

      def focus_settings_id(id)
        return focus_setup_setting(id) if setup_mode?

        definition = @settings_draft.definitions.find { |candidate| candidate.id == id.to_s }
        return unless definition

        if definition.advanced
          @settings_expanded_advanced[definition.category] = true
        end
        @settings_category_index = settings_categories.index(definition.category) || 0
        @settings_row_index = settings_rows.index { |row| row.fetch("id", nil) == definition.id } || 0
      end

      def github_support_enabled?(state = nil)
        explicit = config.value("experiments", "github_support")
        return explicit if explicit == true || explicit == false
        return true if config.value("settings", "schema_version").to_i < Config::Schema::VERSION
        return false unless state.is_a?(Hash)

        Array(state.fetch("issues", [])).any? { |issue| State::Models.pull_request_records_from(issue).any? }
      end

      def github_support_disabled_message
        "Enable GitHub support in Settings → Experiments to use pull request commands."
      end

      # --- first-run setup --------------------------------------------------
    end
  end
end
