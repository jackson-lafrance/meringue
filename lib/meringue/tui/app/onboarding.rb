# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # First-run setup: when it opens by itself, and the refresh cadence while it animates.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def frame_refresh_interval(_state)
        if embedded_agent_workspace?
          # The child PTY needs a fast visual cadence while it owns keyboard
          # focus. When the user moves to dashboard chat or the AgentTree, input
          # still wakes the run loop immediately; polling the unchanged native
          # screen at 40 Hz only competes with the pane the user is typing in.
          return @focused_pane == "logs" ? TERMINAL_REFRESH_INTERVAL : REFRESH_INTERVAL
        end
        if @agent_workspace_active && (@agent_workspace_interactive || @agent_workspace_view == "terminal")
          return TERMINAL_REFRESH_INTERVAL
        end

        REFRESH_INTERVAL
      end

      # Auto-open decision, made once per launch. It never opens when the config
      # already carries the marker, when there is no kernel behind the UI, or when
      # the terminal is too small to draw the popup at all.
      def maybe_open_onboarding(state_provider)
        return false unless onboarding_autostart?

        state = state_provider.call || State::Models.empty_state
        open_settings(state, mode: "setup", setup_origin: "auto")
      end

      def onboarding_autostart?
        return false unless @onboarding_enabled
        # No harness means the app cannot route work yet, so force setup open
        # even when a prior onboarding marker exists. Setup is the only path
        # that persists a harness through the kernel.
        return true unless harness_configured?
        return false if Onboarding.completed?(config)

        width, height = terminal.dimensions
        Onboarding.fits?(width: width, height: height)
      end

      def harness_configured?
        @harness_configured_check.call ? true : false
      end

      # Compatibility seam for tests/extensions that opened the old controller
      # directly. Setup now opens the curated transactional Settings mode.
      def open_onboarding(state)
        open_settings(state, mode: "setup", setup_origin: "manual")
      end

      def setup_command?(text)
        text.to_s.strip.downcase == "/setup"
      end

      # Bare `/setup` is local UI. `/setup complete|skip` remain compatibility
      # kernel commands for scripts, while the interactive flow saves its marker
      # together with the reviewed draft in one SaveConfiguration transaction.
      def handle_local_setup_command(state)
        unless @onboarding_enabled
          append_jump_response(Onboarding.unavailable_message)
          return true
        end

        unless onboarding_fits?
          append_jump_response(Onboarding.collapsed_message)
          return true
        end

        open_settings(state, mode: "setup", setup_origin: "manual")
        true
      end

      def onboarding_fits?
        Onboarding.fits?(width: render_width, height: render_height)
      end
    end
  end
end
