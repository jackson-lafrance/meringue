# frozen_string_literal: true

module Meringue
  module TUI
    class Layout
      MIN_WIDTH = 40
      MIN_HEIGHT = 16
      HEADER_HEIGHT = 2
      MIN_CHAT_HEIGHT = 9
      MAX_CHAT_HEIGHT = 10

      def initialize(agent_tree_pane: Panes::AgentTreePane.new,
                     log_pane: Panes::LogPane.new,
                     chat_pane: Panes::ChatPane.new)
        @agent_tree_pane = agent_tree_pane
        @log_pane = log_pane
        @chat_pane = chat_pane
      end

      def render(state, width:, height:)
        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        canvas = Canvas.new(width: width, height: height)

        draw_header(canvas, state, width)

        chat_height = chat_height_for(height)
        main_height = height - HEADER_HEIGHT - chat_height
        tree_width = tree_width_for(width)
        log_width = width - tree_width
        main_top = HEADER_HEIGHT
        chat_top = main_top + main_height

        draw_pane(canvas, 0, main_top, tree_width, main_height, "AgentTree", agent_tree_pane.lines(state))
        draw_pane(canvas, tree_width, main_top, log_width, main_height, "Logs", log_pane.lines(state))
        draw_pane(canvas, 0, chat_top, width, chat_height, "Chat/Input", chat_pane.lines(state))

        canvas.render
      end

      private

      attr_reader :agent_tree_pane, :log_pane, :chat_pane

      def draw_header(canvas, state, width)
        project_count = state.fetch("projects", []).length
        issue_count = state.fetch("issues", []).length
        agent_count = state.fetch("agents", []).length
        log_count = state.fetch("logs", []).length

        title = " MERINGUE TUI DEMO "
        canvas.write(0, 0, title.ljust(width, "="), max_width: width)
        canvas.write(
          0,
          1,
          " Fake fixture only | Projects: #{project_count} Issues: #{issue_count} Agents: #{agent_count} Logs: #{log_count} | q quits ".ljust(width),
          max_width: width
        )
      end

      def chat_height_for(total_height)
        proposed_height = [MIN_CHAT_HEIGHT, total_height / 4].max
        [proposed_height, MAX_CHAT_HEIGHT, total_height - HEADER_HEIGHT - 4].min
      end

      def tree_width_for(total_width)
        return total_width / 2 if total_width < 70

        [(total_width * 0.34).floor, 34].max
      end

      def draw_pane(canvas, x, y, width, height, title, lines)
        canvas.draw_box(x, y, width, height, title: title)
        content_width = width - 4
        content_height = height - 2
        return if content_width <= 0 || content_height <= 0

        has_overflow = lines.length > content_height
        visible_capacity = has_overflow ? content_height - 1 : content_height
        lines.first(visible_capacity).each_with_index do |line, index|
          canvas.write(x + 2, y + 1 + index, line, max_width: content_width)
        end

        return unless has_overflow

        overflow = "... #{lines.length - visible_capacity} more"
        canvas.write(x + 2, y + height - 2, overflow.ljust(content_width), max_width: content_width)
      end
    end
  end
end
