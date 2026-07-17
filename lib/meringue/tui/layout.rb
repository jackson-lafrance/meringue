# frozen_string_literal: true

module Meringue
  module TUI
    class Layout
      MIN_WIDTH = 64
      MIN_HEIGHT = 18
      OUTER_MARGIN = 1
      GAP = 1
      SIDEBAR_MIN_WIDTH = 34
      SIDEBAR_MAX_WIDTH = 42
      COMPOSER_HEIGHT = 3
      BOTTOM_HINT_HEIGHT = 1
      MAX_COMPOSER_HEIGHT = 12
      MIN_CHAT_HEIGHT = 5
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

        metrics = layout_metrics(width, height, state)
        agent_tree_lines = agent_tree_pane.lines(state, width: metrics.fetch(:sidebar_width) - 4)
        draw_pane(
          canvas,
          metrics.fetch(:sidebar_x),
          metrics.fetch(:top_y),
          metrics.fetch(:sidebar_width),
          metrics.fetch(:top_height),
          "agent tree",
          agent_tree_lines,
          active: scroll_pane_active?(state, "agent_tree"),
          overflow: :agent_tree,
          scroll_offset: agent_tree_scroll_offset(state, agent_tree_lines, metrics.fetch(:top_height) - 2)
        )
        draw_pane(
          canvas,
          metrics.fetch(:main_x),
          metrics.fetch(:top_y),
          metrics.fetch(:main_width),
          metrics.fetch(:conversation_height),
          "conversation + kernel",
          chat_pane.conversation_lines(state, width: metrics.fetch(:main_width) - 4),
          active: scroll_pane_active?(state, "conversation"),
          overflow: :tail,
          scroll_offset: pane_scroll_offset(state, "conversation")
        )
        if metrics.fetch(:suggestion_height).positive?
          draw_pane(
            canvas,
            metrics.fetch(:suggestion_x),
            metrics.fetch(:suggestion_y),
            metrics.fetch(:suggestion_width),
            metrics.fetch(:suggestion_height),
            "slash commands",
            chat_pane.slash_suggestion_lines(state),
            active: false
          )
        end

        draw_pane(
          canvas,
          metrics.fetch(:composer_x),
          metrics.fetch(:composer_y),
          metrics.fetch(:composer_width),
          metrics.fetch(:composer_height),
          "chat",
          chat_pane.composer_lines(state, width: metrics.fetch(:composer_content_width)),
          active: scroll_pane_active?(state, "chat"),
          overflow: :tail
        )
        draw_hint_line(
          canvas,
          metrics.fetch(:hint_x),
          metrics.fetch(:hint_y),
          metrics.fetch(:hint_width),
          chat_pane.bottom_hint_line(state),
          chat_pane.bottom_right_status_line(state)
        )

        canvas.render(color: color)
      end

      def pane_at(state, width:, height:, x:, y:)
        metrics = layout_metrics([width.to_i, MIN_WIDTH].max, [height.to_i, MIN_HEIGHT].max, state)
        focusable_pane_bounds(metrics).find do |_pane, bounds|
          point_in_bounds?(x.to_i, y.to_i, bounds)
        end&.first
      end

      def agent_tree_worker_at(state, width:, height:, x:, y:)
        metrics = layout_metrics([width.to_i, MIN_WIDTH].max, [height.to_i, MIN_HEIGHT].max, state)
        return nil unless point_in_bounds?(x.to_i, y.to_i, pane_bounds(metrics, :sidebar_x, :top_y, :sidebar_width, :top_height))

        content_x = metrics.fetch(:sidebar_x) + 2
        content_y = metrics.fetch(:top_y) + 1
        content_width = metrics.fetch(:sidebar_width) - 4
        content_height = metrics.fetch(:top_height) - 2
        return nil if content_width <= 0 || content_height <= 0
        return nil unless x.to_i >= content_x && x.to_i < content_x + content_width
        return nil unless y.to_i >= content_y && y.to_i < content_y + content_height

        lines = agent_tree_pane.lines(state, width: content_width)
        worker_ids = agent_tree_pane.line_worker_ids(state, width: content_width)
        offset = agent_tree_scroll_offset(state, lines, content_height)
        worker_ids[y.to_i - content_y + offset]
      end

      def scroll_limits(state, width:, height:)
        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        metrics = layout_metrics(width, height, state)
        agent_tree_lines = agent_tree_pane.lines(state, width: metrics.fetch(:sidebar_width) - 4)
        conversation_lines = chat_pane.conversation_lines(state, width: metrics.fetch(:main_width) - 4)
        {
          "agent_tree" => scroll_max(agent_tree_lines.length, metrics.fetch(:top_height) - 2),
          "conversation" => tail_scroll_max(conversation_lines.length, metrics.fetch(:conversation_height) - 2),
          "logs" => 0,
          "chat" => 0
        }
      end

      private

      attr_reader :agent_tree_pane, :log_pane, :chat_pane

      def layout_metrics(width, height, state)
        top_y = 0
        sidebar_x = OUTER_MARGIN
        sidebar_width = sidebar_width_for(width)
        main_x = sidebar_x + sidebar_width + GAP
        main_width = width - main_x - OUTER_MARGIN
        composer_x = OUTER_MARGIN
        composer_width = width - (OUTER_MARGIN * 2)
        composer_content_width = composer_width - 4
        composer_content_height = chat_pane.composer_lines(state, width: composer_content_width).length
        composer_height = composer_height_for(height - BOTTOM_HINT_HEIGHT, composer_content_height)
        suggestion_height = bounded_slash_suggestion_height(height, composer_height, state)
        vertical_gaps = GAP + (suggestion_height.positive? ? GAP : 0)
        top_height = height - BOTTOM_HINT_HEIGHT - composer_height - suggestion_height - vertical_gaps

        conversation_height = top_height

        {
          top_y: top_y,
          top_height: top_height,
          sidebar_x: sidebar_x,
          sidebar_width: sidebar_width,
          main_x: main_x,
          main_width: main_width,
          conversation_height: conversation_height,
          suggestion_x: composer_x,
          suggestion_y: top_y + top_height + GAP,
          suggestion_width: composer_width,
          suggestion_height: suggestion_height,
          composer_x: composer_x,
          composer_y: top_y + top_height + GAP + (suggestion_height.positive? ? suggestion_height + GAP : 0),
          composer_width: composer_width,
          composer_height: composer_height,
          composer_content_width: composer_content_width,
          hint_x: OUTER_MARGIN + 1,
          hint_y: height - BOTTOM_HINT_HEIGHT,
          hint_width: width - (OUTER_MARGIN * 2) - 1
        }
      end

      def bounded_slash_suggestion_height(total_height, composer_height, state)
        raw_height = slash_suggestion_height(state)
        return 0 unless raw_height.positive?

        reserved_top_height = MIN_CHAT_HEIGHT
        max_height = total_height - BOTTOM_HINT_HEIGHT - composer_height - GAP - reserved_top_height - GAP
        bounded_height = [raw_height, [max_height, 0].max].min
        bounded_height >= 3 ? bounded_height : 0
      end

      def slash_suggestion_height(state)
        return 0 unless chat_pane.slash_suggestions?(state)

        [chat_pane.slash_suggestion_lines(state).length + 2, 7].min
      end

      def sidebar_width_for(total_width)
        ideal_width = (total_width * 0.34).floor
        max_for_main = [total_width - 36, SIDEBAR_MIN_WIDTH].max
        [[ideal_width, SIDEBAR_MIN_WIDTH].max, SIDEBAR_MAX_WIDTH, max_for_main].min
      end

      def composer_height_for(total_height, content_line_count)
        base_height = COMPOSER_HEIGHT
        desired_height = [content_line_count.to_i + 2, base_height].max
        max_available_height = [total_height - GAP - MIN_CHAT_HEIGHT, base_height].max
        max_height = [[total_height / 3, base_height].max, MAX_COMPOSER_HEIGHT, max_available_height].min

        [desired_height, max_height].min
      end

      def agent_tree_scroll_offset(state, lines, content_height)
        content_height = content_height.to_i
        return 0 if content_height <= 0 || lines.length <= content_height

        max_offset = scroll_max(lines.length, content_height)
        selected_index = selected_agent_tree_line_index(lines)
        if AgentTreeNavigation.active?(state) && selected_index
          return (selected_index - (content_height / 2)).clamp(0, max_offset)
        end

        pane_scroll_offset(state, "agent_tree").clamp(0, max_offset)
      end

      def pane_scroll_offset(state, pane)
        scroll = state.fetch("_scroll", {}) || {}
        offsets = scroll.fetch("offsets", {}) || {}
        offsets.fetch(pane, 0).to_i
      end

      def focusable_pane_bounds(metrics)
        {
          "agent_tree" => pane_bounds(metrics, :sidebar_x, :top_y, :sidebar_width, :top_height),
          "conversation" => pane_bounds(metrics, :main_x, :top_y, :main_width, :conversation_height),
          "chat" => pane_bounds(metrics, :composer_x, :composer_y, :composer_width, :composer_height)
        }
      end

      def pane_bounds(metrics, x_key, y_key, width_key, height_key)
        {
          x: metrics.fetch(x_key),
          y: metrics.fetch(y_key),
          width: metrics.fetch(width_key),
          height: metrics.fetch(height_key)
        }
      end

      def point_in_bounds?(x, y, bounds)
        x >= bounds.fetch(:x) && x < bounds.fetch(:x) + bounds.fetch(:width) &&
          y >= bounds.fetch(:y) && y < bounds.fetch(:y) + bounds.fetch(:height)
      end

      def scroll_pane_active?(state, pane)
        scroll = state.fetch("_scroll", {}) || {}
        scroll.fetch("active_pane", nil).to_s == pane.to_s
      end

      def selected_agent_tree_line_index(lines)
        selected_styles = [
          Style::AGENT_TREE_SELECTED,
          Style::AGENT_TREE_SELECTED_DIM,
          Style::AGENT_TREE_SELECTED_STATUS
        ]
        lines.index do |line|
          Array(line).any? { |segment| segment.is_a?(Array) && selected_styles.include?(segment[1]) }
        end
      end

      def draw_hint_line(canvas, x, y, width, line, right_line = [])
        right_width = segment_text_width(right_line)
        if right_width.positive? && right_width < width
          left_width = [width - right_width - 2, 0].max
          canvas.write_segments(x, y, line, max_width: left_width, default_style: Style::MUTED)
          canvas.write_segments(x + width - right_width, y, right_line, max_width: right_width, default_style: Style::MUTED)
        else
          canvas.write_segments(x, y, line, max_width: width, default_style: Style::MUTED)
        end
      end

      def segment_text_width(segments)
        Array(segments).sum do |segment|
          if segment.is_a?(Array)
            segment.fetch(0, "").to_s.length
          else
            segment.to_s.length
          end
        end
      end

      def draw_pane(canvas, x, y, width, height, title, lines, active: false, overflow: :head, scroll_offset: 0)
        border_style = active ? Style::BORDER_ACTIVE : Style::BORDER
        canvas.draw_box(x, y, width, height, title: title, style: border_style, title_style: Style::PANEL_TITLE)
        content_width = width - 4
        content_height = height - 2
        return if content_width <= 0 || content_height <= 0

        case overflow
        when :tail
          draw_tail_content(canvas, x, y, content_width, content_height, lines, scroll_offset: scroll_offset)
        when :agent_tree
          draw_scroll_content(canvas, x, y, content_width, content_height, lines, scroll_offset: scroll_offset)
        else
          draw_head_content(canvas, x, y, height, content_width, content_height, lines)
        end
      end

      def draw_scroll_content(canvas, x, y, content_width, content_height, lines, scroll_offset:)
        offset = scroll_offset.to_i.clamp(0, scroll_max(lines.length, content_height))
        lines.drop(offset).first(content_height).each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 1 + index, content_width, line)
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

      def draw_tail_content(canvas, x, y, content_width, content_height, lines, scroll_offset: 0)
        has_overflow = lines.length > content_height
        unless has_overflow
          lines.each_with_index do |line, index|
            draw_line(canvas, x + 2, y + 1 + index, content_width, line)
          end
          return
        end

        visible_capacity = [content_height - 1, 0].max
        max_offset = tail_scroll_max(lines.length, content_height)
        offset = scroll_offset.to_i.clamp(0, max_offset)
        finish_index = lines.length - offset
        start_index = [finish_index - visible_capacity, 0].max
        visible_lines = lines[start_index...finish_index] || []
        hidden_count = start_index
        label = offset.positive? ? "… #{hidden_count} earlier · #{offset} later" : "… #{hidden_count} earlier"
        canvas.write(x + 2, y + 1, label.ljust(content_width), max_width: content_width, style: Style::DIM)
        visible_lines.each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 2 + index, content_width, line)
        end
      end

      def scroll_max(line_count, content_height)
        [[line_count.to_i - content_height.to_i, 0].max, 0].max
      end

      def tail_scroll_max(line_count, content_height)
        content_height = content_height.to_i
        line_count = line_count.to_i
        return 0 if content_height <= 0 || line_count <= content_height

        visible_capacity = [content_height - 1, 0].max
        [line_count - visible_capacity, 0].max
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
