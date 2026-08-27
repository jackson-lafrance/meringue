# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Scroll offsets for the focused pane, and the limits that keep them in range.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def mouse_wheel_up?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "wheel_up"
      end

      def mouse_wheel_down?(key)
        key.is_a?(Hash) && key.fetch("type", nil) == "mouse" && key.fetch("kind", nil) == "wheel_down"
      end

      def mouse_wheel?(key)
        mouse_wheel_up?(key) || mouse_wheel_down?(key)
      end

      def scroll_focused_pane(direction, steps:, state:)
        scroll_pane(@focused_pane.to_s, direction, steps: steps, state: state)
      end

      def scroll_pane(pane, direction, steps:, state:, max_offset: nil)
        pane = pane.to_s
        delta = scroll_delta_for(pane, direction, steps)
        max_offset ||= scroll_max_for(pane, state)
        @scroll_offsets[pane] = (@scroll_offsets[pane].to_i + delta).clamp(0, max_offset)
      end

      def scroll_focused_pane_to(edge, state:)
        pane = @focused_pane.to_s
        max_offset = scroll_max_for(pane, state)
        # The AgentTree counts rows from the first line down; tail panes count
        # back from the newest line, so "top" is the opposite end there.
        top_offset, bottom_offset = pane == "agent_tree" ? [0, max_offset] : [max_offset, 0]
        @scroll_offsets[pane] = edge == :top ? top_offset : bottom_offset
      end

      def scroll_delta_for(pane, direction, step)
        if pane == "agent_tree"
          direction == :down ? step : -step
        else
          direction == :up ? step : -step
        end
      end

      def scroll_key_step(page: false)
        page ? PAGE_SCROLL_STEP : 1
      end

      def mouse_wheel_count(key)
        [key.fetch("count", 1).to_i, 1].max
      end

      def scroll_limits_for(state)
        layout.scroll_limits(
          state,
          width: @last_render_width || DEFAULT_WIDTH,
          height: @last_render_height || DEFAULT_HEIGHT
        )
      end

      def scroll_max_for(pane, state)
        scroll_limits_for(state).fetch(pane.to_s, 0).to_i
      end

      def clamp_scroll_offsets!(state)
        scroll_limits_for(state).each do |pane, max_offset|
          @scroll_offsets[pane] = @scroll_offsets[pane].to_i.clamp(0, max_offset.to_i)
        end
      end
    end
  end
end
