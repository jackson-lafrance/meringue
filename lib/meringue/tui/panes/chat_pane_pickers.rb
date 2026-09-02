# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      # The popup slot shared by every transient list over the composer: the
      # question, model/thinking/theme/harness, and open-PR pickers plus slash
      # suggestions. Log rendering, the composer, and the status bar stay in
      # `chat_pane.rb`; this file only decides what the popup shows.
      class ChatPane
        def slash_suggestions?(state)
          slash_suggestion_records(state).any?
        end

        # The popup slot between the logs pane and the composer. Question, model,
        # thinking, theme, harness, open-PR, and slash-command lists are all
        # transient lists
        # over the composer, so they share one geometry, one border, and one
        # keyboard shape instead of introducing another overlay mechanism. A picker
        # wins while it is up.
        #
        # First-run setup is a full-screen Settings mode rather than a popup in
        # this composer slot.
        def popup?(state)
          question_picker?(state) || model_picker?(state) || delivery_pr_picker?(state) || slash_suggestions?(state)
        end

        # How many entry rows the popup shows at once, and therefore how tall the
        # layout should let the box grow.
        def popup_visible_limit(state)
          return QUESTION_PICKER_VISIBLE_LIMIT if question_picker?(state)
          return MODEL_PICKER_VISIBLE_LIMIT if model_picker?(state)

          VISIBLE_SUGGESTION_LIMIT
        end

        def popup_max_box_height(state)
          popup_visible_limit(state) + 2
        end

        def popup_pane_title(state)
          return "open questions" if question_picker?(state)

          if model_picker?(state)
            label = if model_picker_thinking?(state)
                      "thinking"
                    elsif model_picker_theme?(state)
                      "theme"
                    elsif model_picker_harness_picker?(state)
                      "harness"
                    else
                      "models (#{model_picker_harness(state)})"
                    end
            tabs = model_picker_role_tabs?(state) ? " · #{model_picker_tabs(state)}" : ""
            return "#{label}#{tabs}"
          end

          delivery_pr_picker?(state) ? "open pull requests" : "slash commands"
        end

        # Only entries live inside the popup box. The counter and the key hints are
        # *about* the list rather than members of it, so a row that says "1–15 of
        # 27 commands" inside the border reads like a 16th command and costs the
        # list a visible row. The layout draws #popup_footer_line under the box.
        def popup_lines(state)
          return question_picker_lines(state) if question_picker?(state)
          return model_picker_lines(state) if model_picker?(state)

          delivery_pr_picker?(state) ? delivery_pr_picker_lines(state) : slash_suggestion_lines(state)
        end

        # Dim line rendered directly below the popup box: where the window sits in
        # the full list, and the keys that move it. Empty when there is nothing to
        # say, in which case the layout reserves no row for it.
        def popup_footer_line(state)
          return question_picker_footer_line(state) if question_picker?(state)
          return model_picker_footer_line(state) if model_picker?(state)

          delivery_pr_picker?(state) ? delivery_pr_picker_footer_line(state) : slash_suggestion_footer_line(state)
        end

        def question_picker?(state)
          question_picker_state(state).fetch("active", false) == true
        end

        def question_picker_state(state)
          value = chat_state(state).fetch("question_picker", nil)
          value.is_a?(Hash) ? value : {}
        end

        def question_picker_entries(state)
          QuestionPicker.entries(state)
        end

        def question_picker_index(state)
          entries = question_picker_entries(state)
          return NO_SLASH_SELECTION if entries.empty?

          question_picker_state(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def question_picker_window_start(state)
          slash_suggestion_window_start(
            question_picker_entries(state).length,
            question_picker_index(state),
            limit: QUESTION_PICKER_VISIBLE_LIMIT
          )
        end

        def question_picker_lines(state)
          entries = question_picker_entries(state)
          return [[["No open questions.", Style::MUTED]]] if entries.empty?

          selected_index = question_picker_index(state)
          window_start = question_picker_window_start(state)
          entries.drop(window_start).first(QUESTION_PICKER_VISIBLE_LIMIT).map.with_index do |entry, offset|
            question_picker_line(entry, selected: window_start + offset == selected_index)
          end
        end

        def question_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          style = selected ? Style::ACCENT_BOLD : Style::TEXT
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            ["#{entry.fetch("display_number")}. ", style],
            [entry.fetch("id"), selected ? Style::ACCENT_BOLD : Style::MUTED],
            ["  #{entry.fetch("question", "")}", style]
          ]
        end

        def question_picker_footer_line(state)
          total = question_picker_entries(state).length
          return [["Esc closes", Style::DIM]] if total.zero?

          count = if total > QUESTION_PICKER_VISIBLE_LIMIT
                    window_start = question_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + QUESTION_PICKER_VISIBLE_LIMIT, total].min} of #{total} open questions"
                  else
                    "#{total} open question#{total == 1 ? "" : "s"}"
                  end
          [[count, Style::MUTED], ["  ·  ↑↓ move · Enter inserts /answer · Esc closes", Style::DIM]]
        end

        # The `/models` picker: one searchable list of the models the harness
        # itself reported, replacing the old catalog dump in the log.
        def model_picker?(state)
          model_picker_state(state).fetch("active", false) == true
        end

        def model_picker_state(state)
          value = chat_state(state).fetch("model_picker", nil)
          value.is_a?(Hash) ? value : {}
        end

        def model_picker_query(state)
          model_picker_state(state).fetch("query", "").to_s
        end

        def model_picker_role(state)
          role = model_picker_state(state).fetch("role", "head").to_s.downcase
          %w[head worker].include?(role) ? role : "head"
        end

        def model_picker_kind(state)
          kind = model_picker_state(state).fetch("kind", "model").to_s
          %w[model thinking theme harness].include?(kind) ? kind : "model"
        end

        def model_picker_thinking?(state)
          model_picker_kind(state) == "thinking"
        end

        def model_picker_theme?(state)
          model_picker_kind(state) == "theme"
        end

        def model_picker_harness_picker?(state)
          model_picker_kind(state) == "harness"
        end

        # Themes have no roles at all. Model and thinking have two only while
        # heads and workers keep independent values; in shared mode there is one
        # value and nothing to switch between. Role harnesses are always
        # independent, so the harness picker keeps its tabs either way.
        def model_picker_role_tabs?(state)
          return false if model_picker_theme?(state)
          return true if model_picker_harness_picker?(state)

          model_picker_state(state).fetch("role_tabs", true) != false
        end

        def model_picker_tabs(state)
          role = model_picker_role(state)
          role == "head" ? "[Head]  Worker" : "Head  [Worker]"
        end

        def model_picker_harness(state)
          ModelPicker.harness_for(state, model_picker_state(state).fetch("harness", nil))
        end

        def model_picker_entries(state)
          if model_picker_thinking?(state)
            ModelPicker.thinking_entries(state, role: model_picker_role(state), query: model_picker_query(state))
          elsif model_picker_theme?(state)
            query = model_picker_query(state).downcase
            Style.colorschemes.filter_map.with_index do |theme, index|
              next unless query.empty? || theme.downcase.include?(query)

              {
                "reference" => theme,
                "name" => theme,
                "index" => index
              }
            end
          elsif model_picker_harness_picker?(state)
            query = model_picker_query(state).downcase
            Harness::Registry.provider_choices.filter_map.with_index do |choice, index|
              provider = choice.fetch("provider")
              label = choice.fetch("label")
              next unless query.empty? || provider.downcase.include?(query) || label.downcase.include?(query)

              {
                "reference" => provider,
                "name" => label,
                "description" => choice.fetch("description", "future #{model_picker_role(state)} harness"),
                "index" => index
              }
            end
          else
            ModelPicker.entries(
              state,
              harness: model_picker_harness(state),
              query: model_picker_query(state),
              role: model_picker_role(state)
            )
          end
        end

        # Clamped against the list that exists this frame, so a refresh that
        # shortens the catalog cannot leave the cursor past the end.
        def model_picker_index(state)
          entries = model_picker_entries(state)
          return NO_SLASH_SELECTION if entries.empty?

          model_picker_state(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def model_picker_window_start(state)
          slash_suggestion_window_start(
            model_picker_entries(state).length,
            model_picker_index(state),
            limit: MODEL_PICKER_VISIBLE_LIMIT
          )
        end

        # An empty list always explains itself: an unavailable or unsupported
        # harness catalog says so in the harness's own words instead of rendering
        # a blank box the user cannot tell from "no models exist".
        def model_picker_lines(state)
          entries = model_picker_entries(state)
          if entries.empty?
            message = if model_picker_thinking?(state)
                        "No thinking level matches “#{model_picker_query(state)}”."
                      elsif model_picker_theme?(state)
                        "No theme matches “#{model_picker_query(state)}”."
                      elsif model_picker_harness_picker?(state)
                        "No harness matches “#{model_picker_query(state)}”."
                      else
                        ModelPicker.empty_message(state, harness: model_picker_harness(state), query: model_picker_query(state))
                      end
            return [[[message, Style::MUTED]]]
          end

          selected_index = model_picker_index(state)
          window_start = model_picker_window_start(state)
          entries.drop(window_start).first(MODEL_PICKER_VISIBLE_LIMIT).map.with_index do |entry, offset|
            selected = window_start + offset == selected_index
            if model_picker_thinking?(state)
              thinking_picker_line(entry, selected: selected)
            elsif model_picker_theme?(state) || model_picker_harness_picker?(state)
              choice_picker_line(entry, selected: selected)
            else
              model_picker_line(entry, selected: selected)
            end
          end
        end

        def model_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          details = []
          details << "current default" if entry.fetch("current", false)
          details << entry.fetch("name") unless entry.fetch("name", "").to_s.empty?
          levels = Array(entry.fetch("thinking_levels", []))
          details << "thinking: #{levels.join(", ")}" unless levels.empty?
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            [entry.fetch("reference"), selected ? Style::ACCENT_BOLD : Style::TEXT],
            details.empty? ? nil : ["  #{details.join(" · ")}", Style::MUTED]
          ].compact
        end

        # Caption under the box: where the window sits, what the query is, and the
        # keys. The picker is modal and met rarely, so it always states its keys.
        def thinking_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          details = entry.fetch("description", "").to_s
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            [entry.fetch("level"), selected ? Style::ACCENT_BOLD : Style::TEXT],
            details.empty? ? nil : ["  #{details}", Style::MUTED]
          ].compact
        end

        # No row is labelled as the active choice. The theme picker applies each
        # highlighted theme live, so the dashboard itself already shows which one
        # is current, and the selection color marks the row; a "current" tag next
        # to that is redundant. A name that merely repeats the reference (every
        # theme is listed by its own slug) is dropped for the same reason, so a
        # theme row reads as one word instead of the same word twice.
        def choice_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          reference = entry.fetch("reference", "").to_s
          name = entry.fetch("name", "").to_s
          details = []
          details << name unless name.empty? || name == reference
          details << entry.fetch("description", "") unless entry.fetch("description", "").to_s.empty?
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            [entry.fetch("reference"), selected ? Style::ACCENT_BOLD : Style::TEXT],
            details.empty? ? nil : ["  #{details.join(" · ")}", Style::MUTED]
          ].compact
        end

        def model_picker_footer_line(state)
          total = model_picker_entries(state).length
          segments = []
          if total.positive?
            segments << [model_picker_count_label(state, total), Style::MUTED]
          end
          query = model_picker_query(state)
          segments << ["  ·  filter: #{query}", Style::TEXT] unless query.empty?
          action = if model_picker_theme?(state)
                     "Enter applies the theme"
                   elsif model_picker_harness_picker?(state)
                     "Enter applies the harness"
                   else
                     "Enter sets the default"
                   end
          tabs = model_picker_role_tabs?(state) ? " · ←→ switch role" : ""
          refresh = model_picker_theme?(state) || model_picker_harness_picker?(state) ? "" : " · Ctrl-R refreshes"
          segments << ["#{segments.empty? ? "" : "  ·  "}type to filter · ↑↓ move#{tabs} · #{action}#{refresh} · Esc closes", Style::DIM]
          segments
        end

        def model_picker_count_label(state, total)
          kind_label = if model_picker_thinking?(state)
                         "thinking level"
                       elsif model_picker_theme?(state)
                         "theme"
                       elsif model_picker_harness_picker?(state)
                         "harness"
                       else
                         "model"
                       end
          noun = total == 1 ? kind_label : "#{kind_label}s"
          label = if total > MODEL_PICKER_VISIBLE_LIMIT
                    window_start = model_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + MODEL_PICKER_VISIBLE_LIMIT, total].min} of #{total} #{noun}"
                  else
                    "#{total} #{noun}"
                  end
          return label unless model_picker_kind(state) == "model"

          state_label = ModelPicker.state_label(state, harness: model_picker_harness(state))
          state_label ? "#{label} (#{state_label})" : label
        end

        def delivery_pr_picker?(state)
          Settings.github_enabled?(state) && delivery_pr_picker_state(state).fetch("active", false) == true
        end

        # Highlighted row, clamped to the list that exists this frame so a PR that
        # merged (and left the list) cannot leave the cursor pointing past the end.
        def delivery_pr_picker_index(state)
          entries = OpenPullRequests.entries(state)
          return NO_SLASH_SELECTION if entries.empty?

          delivery_pr_picker_state(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def delivery_pr_picker_window_start(state)
          slash_suggestion_window_start(OpenPullRequests.entries(state).length, delivery_pr_picker_index(state))
        end

        def delivery_pr_picker_lines(state)
          entries = OpenPullRequests.entries(state)
          return [[["No open pull requests are tracked yet.", Style::MUTED]]] if entries.empty?

          selected_index = delivery_pr_picker_index(state)
          window_start = delivery_pr_picker_window_start(state)
          entries.drop(window_start).first(VISIBLE_SUGGESTION_LIMIT).map.with_index do |entry, offset|
            delivery_pr_picker_line(entry, selected: window_start + offset == selected_index)
          end
        end

        def delivery_pr_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            ["##{entry.fetch("number")}", selected ? Style::ACCENT_BOLD : Style::PR_MARKER],
            ["  #{entry.fetch("title")}", selected ? Style::ACCENT_BOLD : Style::TEXT],
            ["  #{entry.fetch("issue_id")} · #{entry.fetch("status")}", Style::MUTED]
          ]
        end

        # The picker always explains its own keys, because it is a modal list a user
        # meets rarely; the count is only interesting once the window hides rows.
        def delivery_pr_picker_footer_line(state)
          total = OpenPullRequests.entries(state).length
          return [["Esc closes", Style::DIM]] if total.zero?

          count = if total > VISIBLE_SUGGESTION_LIMIT
                    window_start = delivery_pr_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + VISIBLE_SUGGESTION_LIMIT, total].min} of #{total} open PRs"
                  else
                    "#{total} open PR#{total == 1 ? "" : "s"}"
                  end
          [[count, Style::MUTED], ["  ·  ↑↓ move · Enter opens · Esc closes", Style::DIM]]
        end

        def delivery_pr_picker_state(state)
          value = chat_state(state).fetch("delivery_pr_picker", nil)
          value.is_a?(Hash) ? value : {}
        end

        def slash_suggestion_lines(state)
          records = slash_suggestion_records(state)
          return [[["No matching slash commands.", Style::MUTED]]] if slash_prompt?(chat_state(state).fetch("input_buffer", "")) && records.empty?

          selected_index = selected_slash_suggestion_index(state, records.length)
          window_start = slash_suggestion_window_start_for(state)
          records.drop(window_start).first(VISIBLE_SUGGESTION_LIMIT).map.with_index do |record, offset|
            selected = window_start + offset == selected_index
            marker = selected ? "›" : " "
            marker_style = selected ? Style::ACCENT_BOLD : Style::DIM
            usage_style = selected ? Style::ACCENT_BOLD : Style::TEXT
            [
              ["#{marker} ", marker_style],
              [record.fetch("usage"), usage_style],
              [" — #{record.fetch("description")}", Style::MUTED]
            ]
          end
        end

        # A three-row window over a long list reads like a three-item list. A
        # harness can offer a hundred models, so say how many entries exist and
        # how to reach the rest instead of letting the window imply the total.
        # This is a caption under the box, not a list row (see #popup_lines).
        def slash_suggestion_footer_line(state)
          records = slash_suggestion_records(state)
          # The trailing catalog-state note is an explanation, not an entry.
          total = records.count { |record| record.fetch("kind", "command") != "session_models_unavailable" }
          return [] if total <= VISIBLE_SUGGESTION_LIMIT

          # The same window the rows above use, so the caption can never disagree
          # with what is on screen.
          window_start = slash_suggestion_window_start_for(state)
          last_shown = [window_start + VISIBLE_SUGGESTION_LIMIT, total].min
          [
            ["#{window_start + 1}–#{last_shown} of #{total} #{slash_suggestion_scope_label(records)}", Style::MUTED],
            ["  ·  ↑↓ scroll · keep typing to filter", Style::DIM]
          ]
        end

        def slash_suggestion_window_start_for(state)
          records = slash_suggestion_records(state)
          slash_suggestion_window_start(records.length, selected_slash_suggestion_index(state, records.length))
        end

        def slash_suggestion_scope_label(records)
          kinds = records.map { |record| record.fetch("kind", "command") }.uniq
          return "models" if kinds.include?("session_models")
          return "thinking levels" if kinds == ["thinking_levels"]

          kinds == ["command"] ? "commands" : "matches"
        end

        def slash_suggestion_records(state)
          input_buffer = chat_state(state).fetch("input_buffer", "")
          return [] unless slash_prompt?(input_buffer)

          Meringue::Input::SlashCommandParser.command_suggestion_records(input_buffer, limit: nil, state: state)
        end

        def slash_prompt?(input_buffer)
          input_buffer.to_s.strip.start_with?("/") || Meringue::Input::SlashCommandParser.inline_suggestion_active?(input_buffer)
        end
      end
    end
  end
end
