# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The bottom status-bar composer: arranging its components and saving the layout.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def open_status_bar_composer(_state, return_to_settings: false)
        initial_value = if return_to_settings && @settings_draft
                          @settings_draft.value("appearance.status_bar_layout")
                        end
        @status_bar_composer_draft = StatusBarComposer::Draft.new(config, initial_value: initial_value)
        @status_bar_composer_active = true
        @status_bar_composer_saving = false
        @status_bar_composer_drag = nil
        @status_bar_composer_return_to_settings = return_to_settings == true
        close_delivery_pr_picker
        close_model_picker
        close_question_picker
        @force_full_redraw = true
        true
      rescue StandardError => e
        append_jump_response("Could not open Status bar composer: #{e.message}")
        false
      end

      def close_status_bar_composer
        @status_bar_composer_active = false
        @status_bar_composer_draft = nil
        @status_bar_composer_saving = false
        @status_bar_composer_drag = nil
        @status_bar_composer_return_to_settings = false
        @force_full_redraw = true
        true
      end

      def status_bar_composer_snapshot(state = nil)
        return nil unless @status_bar_composer_active && @status_bar_composer_draft

        preview_state = status_bar_preview_state(state || State::Models.empty_state)
        @status_bar_composer_draft.saving_snapshot(
          saving: @status_bar_composer_saving,
          preview_components: layout.status_bar_component_segments(preview_state)
        )
      end

      # The preview is derived from live runtime state; the removed Setup/Settings
      # picker no longer needs a second draft state layered onto it.
      def status_bar_preview_state(state)
        state
      end

      def handle_status_bar_composer_key(key, input_buffer, input_cursor, slash_suggestion_index, on_submit, state)
        unchanged = [input_buffer, input_cursor, slash_suggestion_index]
        return unchanged unless @status_bar_composer_draft

        if mouse_event?(key)
          return unchanged if @status_bar_composer_saving

          return handle_status_bar_composer_mouse(key, unchanged, on_submit, state)
        end
        return unchanged if @status_bar_composer_saving

        if hard_escape_key?(key)
          close_status_bar_composer
        elsif hard_save_key?(key) || ENTER_KEYS.include?(key)
          save_status_bar_composer(on_submit, state)
        elsif UP_KEYS.include?(key)
          @status_bar_composer_draft.select_component(@status_bar_composer_draft.component_index - 1)
        elsif DOWN_KEYS.include?(key) || TAB_KEYS.include?(key) || FOCUS_FORWARD_KEYS.include?(key)
          @status_bar_composer_draft.select_component(@status_bar_composer_draft.component_index + 1)
        elsif SHIFT_TAB_KEYS.include?(key) || FOCUS_BACK_KEYS.include?(key)
          @status_bar_composer_draft.select_component(@status_bar_composer_draft.component_index - 1)
        elsif LEFT_KEYS.include?(key)
          @status_bar_composer_draft.nudge_selected(-1)
        elsif RIGHT_KEYS.include?(key)
          @status_bar_composer_draft.nudge_selected(1)
        elsif HOME_KEYS.include?(key)
          @status_bar_composer_draft.move_to_edge("left")
        elsif END_KEYS.include?(key)
          @status_bar_composer_draft.move_to_edge("right")
        elsif key == " "
          @status_bar_composer_draft.cycle_selected_location
        elsif BACKSPACE_KEYS.include?(key) || DELETE_KEYS.include?(key) || key.to_s.downcase == "x"
          @status_bar_composer_draft.remove
        elsif key.to_s.downcase == "r"
          @status_bar_composer_draft.reset!
        end
        unchanged
      rescue StandardError => e
        @status_bar_composer_draft.apply_save_failure("Status bar input failed: #{e.message}")
        unchanged
      end

      def handle_status_bar_composer_mouse(key, unchanged, on_submit, state)
        if mouse_wheel_up?(key) || mouse_wheel_down?(key)
          delta = mouse_wheel_up?(key) ? -1 : 1
          @status_bar_composer_draft.select_component(@status_bar_composer_draft.component_index + delta)
          return unchanged
        end

        hit = layout.status_bar_composer_hit(state, width: render_width, height: render_height, x: mouse_x(key), y: mouse_y(key))
        if mouse_button_press?(key)
          case hit
          when :save then save_status_bar_composer(on_submit, state)
          when :cancel then close_status_bar_composer
          when :reset then @status_bar_composer_draft.reset!
          when Array
            component = status_bar_hit_component(status_bar_composer_snapshot(state), hit)
            if component
              @status_bar_composer_draft.select_component_id(component)
              @status_bar_composer_drag = { component: component, moved: false }
            end
          end
          return unchanged
        end

        if mouse_drag?(key) && @status_bar_composer_drag
          @status_bar_composer_drag[:moved] = true if apply_status_bar_drop(
            @status_bar_composer_draft,
            @status_bar_composer_drag.fetch(:component),
            hit
          )
          return unchanged
        end

        @status_bar_composer_drag = nil if mouse_button_release?(key)
        unchanged
      end

      def save_status_bar_composer(on_submit, state)
        return false if @status_bar_composer_saving
        unless @status_bar_composer_draft.validate
          return false
        end

        if @status_bar_composer_return_to_settings && @settings_draft
          layout = @status_bar_composer_draft.layout
          value = layout.configured? ? layout.serialized : ""
          @settings_draft.set("appearance.status_bar_layout", value)
          close_status_bar_composer
          return true
        end

        changes = @status_bar_composer_draft.changes
        if changes.empty?
          close_status_bar_composer
          return true
        end

        unless on_submit
          @status_bar_composer_draft.apply_save_failure("Configuration save is unavailable in this TUI session.")
          return false
        end

        payload = {
          "base_fingerprint" => @status_bar_composer_draft.baseline_fingerprint,
          "changes" => changes
        }
        encoded = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
        @status_bar_composer_saving = true
        @status_bar_composer_draft.clear_save_failure
        submit_prompt("/config save #{encoded}", on_submit, state)
        true
      end

      def status_bar_hit_component(snapshot, hit)
        kind, source, index = Array(hit)
        return nil unless kind == :component

        records = source.to_s == "palette" ? Array(snapshot["palette"]) : Array(snapshot.dig("zones", source.to_s))
        records[index.to_i]&.fetch("id", nil)
      end

      def apply_status_bar_drop(draft, component, hit)
        kind, zone, index = Array(hit)
        return false unless %i[component drop].include?(kind)
        return draft.remove(component) if zone.to_s == "palette"
        return false unless StatusBarLayout::ZONES.include?(zone.to_s)

        draft.place(component, zone, index)
      end

      # --- full-screen settings --------------------------------------------

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
    end
  end
end
