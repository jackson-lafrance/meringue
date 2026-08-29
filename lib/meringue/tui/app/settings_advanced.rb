# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # The advanced-settings disclosure, shared by /config and first-run setup.
      #
      # It is one behaviour in two surfaces: Settings hides the schema rows marked
      # advanced behind it per category, setup hides its own curated list behind it
      # on the harness step. Both open and close through the same row and the same
      # key, which is the part that has to stay in one place — a reveal that only
      # opens leaves setup with no way back to the plain card.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def settings_advanced_toggle_row(count, expanded)
        synthetic_settings_row(
          "_show_advanced",
          expanded ? "Hide advanced settings (#{count})" : "Show advanced settings (#{count})",
          "#{expanded ? "Hide" : "Reveal"} #{count} advanced setting#{count == 1 ? "" : "s"} in #{settings_category}. " \
            "Enter or A toggles them; other categories keep their own advanced settings hidden.",
          expanded ? "#{count} shown" : "#{count} hidden"
        )
      end

      def settings_advanced_expanded?
        @settings_expanded_advanced.fetch(settings_category, false)
      end

      # How many advanced rows this step or category actually has, whether or not
      # they are currently revealed. Setup curates its own list; Settings reads
      # the schema, minus rows that are hidden for unrelated reasons.
      def settings_advanced_count
        return 0 unless @settings_draft
        return Settings::SetupFlow.advanced_setting_ids(settings_category).length if setup_mode?

        @settings_draft.definitions_for(settings_category, include_advanced: true).count do |definition|
          definition.advanced && settings_row_visible?(@settings_draft.row(definition))
        end
      end

      # One toggle behind both Enter on the reveal row and the A keybinding, in
      # setup and in Settings alike. The cursor stays on the toggle so the key
      # that opened the section is still under the hand that closes it.
      def toggle_settings_advanced
        return false unless settings_advanced_count.positive?

        category = settings_category
        @settings_expanded_advanced[category] = !@settings_expanded_advanced.fetch(category, false)
        @settings_footer_focus = false
        @settings_row_index = settings_rows.index { |row| row.fetch("id", nil) == "_show_advanced" } || 0
        true
      end
    end
  end
end
