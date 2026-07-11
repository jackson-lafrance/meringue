# frozen_string_literal: true

module Meringue
  module TUI
    class Layout
      MIN_WIDTH = 64
      MIN_HEIGHT = 18
      HEADER_HEIGHT = 3
      OUTER_MARGIN = 1
      GAP = 1
      SIDEBAR_MIN_WIDTH = 34
      SIDEBAR_MAX_WIDTH = 42
      COMPOSER_HEIGHT = 5
      MIN_CHAT_HEIGHT = 5
      MIN_LOG_HEIGHT = 3
      MAX_LOG_HEIGHT = 9

      def initialize(agent_tree_pane: Panes::AgentTreePane.new,
                     log_pane: Panes::LogPane.new,
                     chat_pane: Panes::ChatPane.new)
        @agent_tree_pane = agent_tree_pane
        @log_pane = log_pane
        @chat_pane = chat_pane
      end

      def render(state, width:, height:, color: false)
        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        canvas = Canvas.new(width: width, height: height)

        draw_header(canvas, state, width)

        metrics = layout_metrics(width, height)
        draw_pane(
          canvas,
          metrics.fetch(:sidebar_x),
          metrics.fetch(:body_y),
          metrics.fetch(:sidebar_width),
          metrics.fetch(:body_height),
          "agents",
          agent_tree_pane.lines(state)
        )
        draw_pane(
          canvas,
          metrics.fetch(:main_x),
          metrics.fetch(:body_y),
          metrics.fetch(:main_width),
          metrics.fetch(:chat_height),
          "chat",
          chat_pane.conversation_lines(state),
          active: true
        )
        draw_pane(
          canvas,
          metrics.fetch(:main_x),
          metrics.fetch(:log_y),
          metrics.fetch(:main_width),
          metrics.fetch(:log_height),
          "activity",
          log_pane.lines(state)
        )
        draw_pane(
          canvas,
          metrics.fetch(:main_x),
          metrics.fetch(:composer_y),
          metrics.fetch(:main_width),
          metrics.fetch(:composer_height),
          "message",
          chat_pane.composer_lines(state),
          active: true
        )

        canvas.render(color: color)
      end

      private

      attr_reader :agent_tree_pane, :log_pane, :chat_pane

      def draw_header(canvas, state, width)
        project_count = state.fetch("projects", []).length
        issue_count = state.fetch("issues", []).length
        agent_count = state.fetch("agents", []).length
        log_count = state.fetch("logs", []).length

        canvas.write(0, 0, " " * width, max_width: width, style: Style::HEADER)
        canvas.write_segments(
          1,
          0,
          [
            ["✦ meringue", Style::ACCENT_BOLD],
            ["  fake TUI rendering demo", Style::HEADER_MUTED]
          ],
          max_width: width - 2,
          default_style: Style::HEADER_MUTED
        )

        canvas.write(0, 1, " " * width, max_width: width, style: Style::HEADER)
        canvas.write_segments(
          1,
          1,
          [
            ["fixture only", Style::WARNING],
            ["  ·  no Pi sessions", Style::HEADER_MUTED],
            ["  ·  no state writes", Style::HEADER_MUTED],
            ["  ·  #{project_count} projects / #{issue_count} issues / #{agent_count} agents / #{log_count} logs", Style::HEADER_MUTED],
            ["  ·  q quits", Style::HEADER_MUTED]
          ],
          max_width: width - 2,
          default_style: Style::HEADER_MUTED
        )

        canvas.write(0, 2, "─" * width, max_width: width, style: Style::BORDER)
      end

      def layout_metrics(width, height)
        sidebar_x = OUTER_MARGIN
        body_y = HEADER_HEIGHT
        body_height = height - HEADER_HEIGHT - OUTER_MARGIN
        sidebar_width = sidebar_width_for(width)
        main_x = sidebar_x + sidebar_width + GAP
        main_width = width - main_x - OUTER_MARGIN

        composer_height = composer_height_for(body_height)
        remaining = body_height - composer_height - (GAP * 2)
        log_height = log_height_for(remaining)
        chat_height = remaining - log_height

        if chat_height < MIN_CHAT_HEIGHT
          chat_height = [remaining - MIN_LOG_HEIGHT, MIN_CHAT_HEIGHT].max
          log_height = remaining - chat_height
        end

        {
          sidebar_x: sidebar_x,
          body_y: body_y,
          body_height: body_height,
          sidebar_width: sidebar_width,
          main_x: main_x,
          main_width: main_width,
          chat_height: chat_height,
          log_y: body_y + chat_height + GAP,
          log_height: log_height,
          composer_y: body_y + chat_height + GAP + log_height + GAP,
          composer_height: composer_height
        }
      end

      def sidebar_width_for(total_width)
        ideal_width = (total_width * 0.34).floor
        max_for_main = [total_width - 36, SIDEBAR_MIN_WIDTH].max
        [[ideal_width, SIDEBAR_MIN_WIDTH].max, SIDEBAR_MAX_WIDTH, max_for_main].min
      end

      def composer_height_for(body_height)
        [COMPOSER_HEIGHT, [body_height / 4, 3].max].min
      end

      def log_height_for(remaining_height)
        desired = [[remaining_height / 3, MIN_LOG_HEIGHT].max, MAX_LOG_HEIGHT].min
        max_log_height = [remaining_height - MIN_CHAT_HEIGHT, MIN_LOG_HEIGHT].max
        [desired, max_log_height].min
      end

      def draw_pane(canvas, x, y, width, height, title, lines, active: false)
        border_style = active ? Style::BORDER_ACTIVE : Style::BORDER
        canvas.draw_box(x, y, width, height, title: title, style: border_style, title_style: Style::PANEL_TITLE)
        content_width = width - 4
        content_height = height - 2
        return if content_width <= 0 || content_height <= 0

        has_overflow = lines.length > content_height
        visible_capacity = has_overflow ? [content_height - 1, 0].max : content_height
        lines.first(visible_capacity).each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 1 + index, content_width, line)
        end

        return unless has_overflow

        overflow = "… #{lines.length - visible_capacity} more"
        canvas.write(x + 2, y + height - 2, overflow.ljust(content_width), max_width: content_width, style: Style::DIM)
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
