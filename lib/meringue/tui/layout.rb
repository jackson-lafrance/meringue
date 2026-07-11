# frozen_string_literal: true

module Meringue
  module TUI
    class Layout
      MIN_WIDTH = 64
      MIN_HEIGHT = 18
      OUTER_MARGIN = 1
      GAP = 1
      SIDEBAR_MIN_WIDTH = 34
      SIDEBAR_MAX_WIDTH = 48

      def initialize(agent_tree_pane: Panes::AgentTreePane.new,
                     log_pane: Panes::LogPane.new)
        @agent_tree_pane = agent_tree_pane
        @log_pane = log_pane
      end

      def render(state, width:, height:, color: false)
        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        canvas = Canvas.new(width: width, height: height)

        metrics = layout_metrics(width, height)
        draw_pane(
          canvas,
          metrics.fetch(:sidebar_x),
          metrics.fetch(:content_y),
          metrics.fetch(:sidebar_width),
          metrics.fetch(:content_height),
          "agent tree",
          agent_tree_pane.lines(state)
        )
        draw_pane(
          canvas,
          metrics.fetch(:log_x),
          metrics.fetch(:content_y),
          metrics.fetch(:log_width),
          metrics.fetch(:content_height),
          "kernel logs",
          log_pane.lines(state),
          overflow: :tail
        )

        canvas.render(color: color)
      end

      private

      attr_reader :agent_tree_pane, :log_pane

      def layout_metrics(width, height)
        sidebar_x = OUTER_MARGIN
        sidebar_width = sidebar_width_for(width)
        log_x = sidebar_x + sidebar_width + GAP
        log_width = width - log_x - OUTER_MARGIN

        {
          content_y: 0,
          content_height: height,
          sidebar_x: sidebar_x,
          sidebar_width: sidebar_width,
          log_x: log_x,
          log_width: log_width
        }
      end

      def sidebar_width_for(total_width)
        ideal_width = (total_width * 0.38).floor
        max_for_log_pane = [total_width - 30, SIDEBAR_MIN_WIDTH].max
        [[ideal_width, SIDEBAR_MIN_WIDTH].max, SIDEBAR_MAX_WIDTH, max_for_log_pane].min
      end

      def draw_pane(canvas, x, y, width, height, title, lines, active: false, overflow: :head)
        border_style = active ? Style::BORDER_ACTIVE : Style::BORDER
        canvas.draw_box(x, y, width, height, title: title, style: border_style, title_style: Style::PANEL_TITLE)
        content_width = width - 4
        content_height = height - 2
        return if content_width <= 0 || content_height <= 0

        if overflow == :tail
          draw_tail_content(canvas, x, y, height, content_width, content_height, lines)
        else
          draw_head_content(canvas, x, y, height, content_width, content_height, lines)
        end
      end

      def draw_head_content(canvas, x, y, height, content_width, content_height, lines)
        has_overflow = lines.length > content_height
        visible_capacity = has_overflow ? [content_height - 1, 0].max : content_height
        lines.first(visible_capacity).each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 1 + index, content_width, line)
        end

        return unless has_overflow

        overflow = "… #{lines.length - visible_capacity} more"
        canvas.write(x + 2, y + height - 2, overflow.ljust(content_width), max_width: content_width, style: Style::DIM)
      end

      def draw_tail_content(canvas, x, y, _height, content_width, content_height, lines)
        has_overflow = lines.length > content_height
        unless has_overflow
          lines.each_with_index do |line, index|
            draw_line(canvas, x + 2, y + 1 + index, content_width, line)
          end
          return
        end

        visible_capacity = [content_height - 1, 0].max
        hidden_count = lines.length - visible_capacity
        canvas.write(x + 2, y + 1, "… #{hidden_count} earlier".ljust(content_width), max_width: content_width, style: Style::DIM)
        lines.last(visible_capacity).each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 2 + index, content_width, line)
        end
      end

      def draw_line(canvas, x, y, width, line)
        if line.is_a?(Array)
          canvas.write_segments(x, y, line, max_width: width, default_style: Style::TEXT)
        else
          canvas.write(x, y, line.to_s, max_width: width, style: Style::TEXT)
        end
      end
    end
  end
end
