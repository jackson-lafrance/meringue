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
                     chat_pane: Panes::ChatPane.new,
                     agent_workspace_pane: Panes::AgentWorkspacePane.new)
        @agent_tree_pane = agent_tree_pane
        @chat_pane = chat_pane
        @agent_workspace_pane = agent_workspace_pane
      end

      def render(state, width:, height:, color: false)
        width = bounded_width(width)
        height = bounded_height(height)
        canvas = Canvas.new(width: width, height: height)
        return render_agent_workspace(canvas, state, width, height, color: color) if agent_workspace_active?(state)

        metrics = layout_metrics(width, height, state)
        agent_tree_lines = agent_tree_pane.lines(state, width: metrics.fetch(:sidebar_width) - 4)
        agent_tree_height = metrics.fetch(:top_height) - 2
        agent_tree_offset = agent_tree_scroll_offset(state, agent_tree_lines, agent_tree_height)
        draw_pane(
          canvas,
          metrics.fetch(:sidebar_x),
          metrics.fetch(:top_y),
          metrics.fetch(:sidebar_width),
          metrics.fetch(:top_height),
          agent_tree_title(agent_tree_lines.length, agent_tree_height, agent_tree_offset),
          agent_tree_lines,
          active: scroll_pane_active?(state, "agent_tree"),
          overflow: :agent_tree,
          scroll_offset: agent_tree_offset
        )
        draw_pane(
          canvas,
          metrics.fetch(:main_x),
          metrics.fetch(:top_y),
          metrics.fetch(:main_width),
          metrics.fetch(:logs_height),
          logs_pane_title(state),
          chat_pane.log_lines(state, width: metrics.fetch(:main_width) - 4),
          active: scroll_pane_active?(state, "logs"),
          overflow: :tail,
          scroll_offset: pane_scroll_offset(state, "logs"),
          selection: pane_selection(state, "logs"),
          # A filtered logs pane carries the identity color of the node it is
          # filtered to.
          title_style: logs_pane_title_style(state)
        )
        if metrics.fetch(:suggestion_height).positive?
          draw_pane(
            canvas,
            metrics.fetch(:suggestion_x),
            metrics.fetch(:suggestion_y),
            metrics.fetch(:suggestion_width),
            metrics.fetch(:suggestion_height),
            chat_pane.popup_pane_title(state),
            chat_pane.popup_lines(state),
            active: false
          )
          # The counter and key hints are a caption for the box, not a row in it, so
          # they render on their own reserved line under the border, indented to the
          # box's content column.
          if metrics.fetch(:suggestion_footer_height).positive?
            canvas.write_segments(
              metrics.fetch(:suggestion_x) + 2,
              metrics.fetch(:suggestion_footer_y),
              chat_pane.popup_footer_line(state),
              max_width: [metrics.fetch(:suggestion_width) - 4, 0].max,
              default_style: Style::DIM
            )
          end
        end

        composer_active = scroll_pane_active?(state, "chat")
        draw_pane(
          canvas,
          metrics.fetch(:composer_x),
          metrics.fetch(:composer_y),
          metrics.fetch(:composer_width),
          metrics.fetch(:composer_height),
          composer_pane_title(state),
          chat_pane.composer_lines(state, width: metrics.fetch(:composer_content_width)),
          active: composer_active,
          overflow: :tail,
          # The composer is tinted with the selected chat target's own color, so
          # the box the user types into matches the AgentTree row it prompts.
          border_style: composer_border_style(state, active: composer_active),
          title_style: composer_title_style(state)
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
        return "agent_workspace" if agent_workspace_active?(state)

        metrics = layout_metrics([width.to_i, MIN_WIDTH].max, [height.to_i, MIN_HEIGHT].max, state)
        focusable_pane_bounds(metrics).find do |_pane, bounds|
          point_in_bounds?(x.to_i, y.to_i, bounds)
        end&.first
      end

      # Logs selection points are content coordinates (index into the wrapped log
      # lines plus a column) so a highlight follows the content while scrolling.
      # Coordinates are clamped into the logs text area, which is what keeps a
      # drag started in the logs pane from bleeding into the agent tree.
      def logs_text_position(state, width:, height:, x:, y:)
        view = logs_text_view(state, width: width, height: height)
        rows = view ? view.fetch(:rows) : []
        return nil if rows.empty?

        row_index = (y.to_i - rows.first.fetch(:y)).clamp(0, rows.length - 1)
        row = rows.fetch(row_index)
        column = (x.to_i - view.fetch(:x)).clamp(0, row.fetch(:text).length)
        Selection.point(row.fetch(:line_index), column)
      end

      # Plain text of every wrapped logs content line. Keyboard selection uses
      # this to move a caret through the same coordinates the mouse produces.
      def logs_text_lines(state, width:, height:)
        view = logs_text_view(state, width: width, height: height)
        return [] unless view

        view.fetch(:lines).map { |line| line_plain_text(line) }
      end

      # Which content lines the logs pane is currently showing, so keyboard
      # selection can page by a real screenful and place a fresh caret in view.
      def logs_visible_window(state, width:, height:)
        dimensions = logs_content_dimensions(state, width: width, height: height)
        return nil unless dimensions

        line_count = dimensions.fetch(:lines).length
        window = tail_window(line_count, dimensions.fetch(:content_height), pane_scroll_offset(state, "logs"))
        {
          "start_index" => window.fetch(:start_index),
          "finish_index" => window.fetch(:finish_index),
          "capacity" => [window.fetch(:finish_index) - window.fetch(:start_index), 0].max,
          "line_count" => line_count,
          "content_width" => dimensions.fetch(:content_width)
        }
      end

      # Smallest logs scroll offset change that keeps a content line on screen.
      # Keyboard selection uses it so a caret can never walk out of the view.
      def logs_scroll_offset_for_line(state, width:, height:, line_index:)
        dimensions = logs_content_dimensions(state, width: width, height: height)
        return nil unless dimensions

        lines = dimensions.fetch(:lines)
        content_height = dimensions.fetch(:content_height)
        line_count = lines.length
        offset = pane_scroll_offset(state, "logs")
        max_offset = tail_scroll_max(line_count, content_height)
        return 0 if max_offset.zero?

        window = tail_window(line_count, content_height, offset)
        capacity = [window.fetch(:finish_index) - window.fetch(:start_index), 1].max
        index = line_index.to_i.clamp(0, line_count - 1)
        offset = line_count - index - 1 if index >= window.fetch(:finish_index)
        offset = line_count - index - capacity if index < window.fetch(:start_index)
        offset.clamp(0, max_offset)
      end

      def logs_selection_text(state, width:, height:, selection:)
        view = logs_text_view(state, width: width, height: height)
        return "" unless view

        texts = {}
        view.fetch(:lines).each_with_index { |line, index| texts[index] = line_plain_text(line) }
        Selection.text_for(selection, texts)
      end

      # Composer selection is stored as character offsets into the input buffer,
      # so a click maps to one index that the chat pane owns the wrapping for.
      def composer_text_index(state, width:, height:, x:, y:)
        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        content_x = metrics.fetch(:composer_x) + 2
        content_y = metrics.fetch(:composer_y) + 1
        content_width = metrics.fetch(:composer_content_width)
        content_height = metrics.fetch(:composer_height) - 2
        return nil if content_width <= 0 || content_height <= 0

        row_count = chat_pane.composer_row_spans(state, width: content_width).length
        return 0 if row_count.zero?

        window = tail_window(row_count, content_height, 0)
        visible_rows = window.fetch(:finish_index) - window.fetch(:start_index)
        return 0 if visible_rows <= 0

        row_offset = (y.to_i - (content_y + window.fetch(:row_offset))).clamp(0, visible_rows - 1)
        chat_pane.composer_char_index_at(
          state,
          row: window.fetch(:start_index) + row_offset,
          # The composer prints a two column prompt prefix before buffer text.
          column: x.to_i - content_x - 2,
          width: content_width
        )
      end

      # Where a click landed relative to the open-PR picker: the entry index for a
      # row, `:chrome` for the picker's own border/footer, and `:outside` for
      # anywhere else (which is what dismisses it).
      def delivery_pr_picker_hit(state, width:, height:, x:, y:)
        return :outside unless chat_pane.delivery_pr_picker?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return :outside unless metrics.fetch(:suggestion_height).positive?

        # The caption line under the box belongs to the picker, so clicking it is not
        # a click-away dismiss.
        bounds = pane_bounds(metrics, :suggestion_x, :suggestion_y, :suggestion_width, :suggestion_height)
        bounds = bounds.merge(height: bounds.fetch(:height) + metrics.fetch(:suggestion_footer_height))
        return :outside unless point_in_bounds?(x.to_i, y.to_i, bounds)

        row = y.to_i - metrics.fetch(:suggestion_y) - 1
        return :chrome if row.negative? || row >= Panes::ChatPane::VISIBLE_SUGGESTION_LIMIT

        index = chat_pane.delivery_pr_picker_window_start(state) + row
        index < OpenPullRequests.entries(state).length ? index : :chrome
      end

      def agent_tree_item_at(state, width:, height:, x:, y:)
        return nil if agent_workspace_active?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return nil unless point_in_bounds?(x.to_i, y.to_i, pane_bounds(metrics, :sidebar_x, :top_y, :sidebar_width, :top_height))

        content_x = metrics.fetch(:sidebar_x) + 2
        content_y = metrics.fetch(:top_y) + 1
        content_width = metrics.fetch(:sidebar_width) - 4
        content_height = metrics.fetch(:top_height) - 2
        return nil if content_width <= 0 || content_height <= 0
        return nil unless x.to_i >= content_x && x.to_i < content_x + content_width
        return nil unless y.to_i >= content_y && y.to_i < content_y + content_height

        lines = agent_tree_pane.lines(state, width: content_width)
        item_ids = agent_tree_pane.line_item_ids(state, width: content_width)
        offset = agent_tree_scroll_offset(state, lines, content_height)
        item_ids[y.to_i - content_y + offset]
      end

      # Compatibility for integrations that still use the worker-specific name.
      def agent_tree_worker_at(state, width:, height:, x:, y:)
        agent_tree_item_at(state, width: width, height: height, x: x, y: y)
      end

      # Which AgentTree content lines are on screen right now, plus how much is
      # hidden above and below. Callers use it for page steps and to tell the
      # user that a clipped tree is scrollable rather than missing data.
      def agent_tree_visible_window(state, width:, height:)
        dimensions = agent_tree_content_dimensions(state, width: width, height: height)
        return nil unless dimensions

        lines = dimensions.fetch(:lines)
        content_height = dimensions.fetch(:content_height)
        offset = agent_tree_scroll_offset(state, lines, content_height)
        finish_index = [offset + content_height, lines.length].min
        {
          "start_index" => offset,
          "finish_index" => finish_index,
          "capacity" => content_height,
          "line_count" => lines.length,
          "offset" => offset,
          "max_offset" => scroll_max(lines.length, content_height),
          "hidden_above" => offset,
          "hidden_below" => [lines.length - finish_index, 0].max
        }
      end

      # Content line range an AgentTree item occupies, so callers can reveal a
      # selected issue/agent without duplicating the pane's wrapping rules.
      def agent_tree_item_line_range(state, width:, height:, item_id:)
        return nil if item_id.to_s.empty?

        dimensions = agent_tree_content_dimensions(state, width: width, height: height)
        return nil unless dimensions

        item_ids = agent_tree_pane.line_item_ids(state, width: dimensions.fetch(:content_width))
        first_index = item_ids.index { |candidate| candidate.to_s == item_id.to_s }
        return nil unless first_index

        last_index = item_ids.rindex { |candidate| candidate.to_s == item_id.to_s } || first_index
        [first_index, last_index]
      end

      # Smallest AgentTree scroll offset change that keeps a content line on
      # screen. This mirrors logs_scroll_offset_for_line so selection reveal
      # behaves the same in both panes.
      def agent_tree_scroll_offset_for_line(state, width:, height:, line_index:, last_line_index: nil)
        dimensions = agent_tree_content_dimensions(state, width: width, height: height)
        return nil unless dimensions

        lines = dimensions.fetch(:lines)
        content_height = dimensions.fetch(:content_height)
        max_offset = scroll_max(lines.length, content_height)
        return 0 if max_offset.zero?

        offset = pane_scroll_offset(state, "agent_tree").clamp(0, max_offset)
        first = line_index.to_i.clamp(0, lines.length - 1)
        last = (last_line_index || first).to_i.clamp(first, lines.length - 1)
        # A wrapped item that cannot fit whole still shows its first row.
        offset = last - content_height + 1 if last >= offset + content_height
        offset = first if first < offset
        offset.clamp(0, max_offset)
      end

      # Largest useful scroll offset for the focused workspace pane, using the
      # same geometry the renderer uses. Callers clamp with this so scrolling
      # past the end cannot build up a dead offset.
      def agent_workspace_scroll_max(state, width:, height:)
        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        workspace = state.fetch("_agent_workspace", {}) || {}
        pane_width = width - (OUTER_MARGIN * 2)
        content_width = pane_width - 4
        lines = agent_workspace_pane.content_lines(state, width: content_width)

        if workspace.fetch("view", "agent") == "terminal"
          [lines.length - ((height - BOTTOM_HINT_HEIGHT) - 2), 0].max
        else
          composer_line_count = agent_workspace_pane.composer_lines(state, width: pane_width - 4).length
          composer_height = composer_height_for(height - BOTTOM_HINT_HEIGHT, composer_line_count)
          content_height = height - BOTTOM_HINT_HEIGHT - composer_height - GAP - 2
          pinned_tail_scroll_max(lines, content_height)
        end
      end

      def scroll_limits(state, width:, height:)
        return { "agent_tree" => 0, "logs" => 0, "chat" => 0 } if agent_workspace_active?(state)

        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        metrics = layout_metrics(width, height, state)
        agent_tree_lines = agent_tree_pane.lines(state, width: metrics.fetch(:sidebar_width) - 4)
        log_lines = chat_pane.log_lines(state, width: metrics.fetch(:main_width) - 4)
        {
          "agent_tree" => scroll_max(agent_tree_lines.length, metrics.fetch(:top_height) - 2),
          "logs" => tail_scroll_max(log_lines.length, metrics.fetch(:logs_height) - 2),
          "chat" => 0
        }
      end

      private

      attr_reader :agent_tree_pane, :chat_pane, :agent_workspace_pane

      def agent_workspace_active?(state)
        workspace = state.fetch("_agent_workspace", {}) || {}
        !!workspace.fetch("active", false)
      end

      def render_agent_workspace(canvas, state, width, height, color:)
        workspace = state.fetch("_agent_workspace", {}) || {}
        view = workspace.fetch("view", "agent")
        pane_x = OUTER_MARGIN
        pane_width = width - (OUTER_MARGIN * 2)
        hint_y = height - BOTTOM_HINT_HEIGHT

        if view == "terminal"
          draw_pane(
            canvas,
            pane_x,
            0,
            pane_width,
            hint_y,
            agent_workspace_pane.title(state),
            agent_workspace_pane.content_lines(state, width: pane_width - 4),
            active: true,
            overflow: :terminal,
            scroll_offset: workspace.fetch("scroll_offset", 0),
            title_style: agent_workspace_title_style(state)
          )
        else
          composer_width = pane_width
          composer_content_width = composer_width - 4
          composer_line_count = agent_workspace_pane.composer_lines(state, width: composer_content_width).length
          composer_height = composer_height_for(height - BOTTOM_HINT_HEIGHT, composer_line_count)
          suggestion_height = workspace_suggestion_height(state, height, composer_height)
          content_height = height - BOTTOM_HINT_HEIGHT - composer_height - GAP - (suggestion_height.positive? ? suggestion_height + GAP : 0)
          draw_pane(
            canvas,
            pane_x,
            0,
            pane_width,
            content_height,
            agent_workspace_pane.title(state),
            agent_workspace_pane.content_lines(state, width: pane_width - 4),
            active: true,
            overflow: :pinned_tail,
            scroll_offset: workspace.fetch("scroll_offset", 0),
            # The focused pane title keeps the worker's identity color.
            title_style: agent_workspace_title_style(state)
          )
          if suggestion_height.positive?
            draw_pane(
              canvas,
              pane_x,
              content_height + GAP,
              pane_width,
              suggestion_height,
              "workspace commands",
              agent_workspace_pane.slash_suggestion_lines(state),
              active: false
            )
          end
          draw_pane(
            canvas,
            pane_x,
            height - BOTTOM_HINT_HEIGHT - composer_height,
            composer_width,
            composer_height,
            "chat",
            agent_workspace_pane.composer_lines(state, width: composer_content_width),
            active: true,
            overflow: :tail
          )
        end

        status_line = agent_workspace_pane.status_line(state)
        hint_width = pane_width - 2
        status_width = segment_text_width(status_line)
        available_hint_width = [hint_width - (status_width.positive? ? status_width + 2 : 0), 0].max
        draw_hint_line(
          canvas,
          pane_x + 1,
          hint_y,
          hint_width,
          agent_workspace_pane.hint_line(state, width: available_hint_width),
          status_line
        )
        canvas.render(color: color)
      end

      def agent_workspace_title_style(state)
        return nil unless agent_workspace_pane.respond_to?(:title_style)

        agent_workspace_pane.title_style(state)
      end

      # Rendering must stay inside the terminal's real viewport. The old minimum
      # rectangle made a resized terminal receive a wider/taller frame than it
      # could display, which clipped the chat pane at the edges. Geometry below
      # is deliberately defensive for compact terminals instead of expanding the
      # canvas past the requested dimensions.
      def bounded_width(width)
        [width.to_i, 1].max
      end

      def bounded_height(height)
        [height.to_i, 1].max
      end

      # Shared AgentTree geometry so hit-testing, scrolling, reveal, and the
      # overflow indicator all wrap the same content at the same width.
      def agent_tree_content_dimensions(state, width:, height:)
        return nil if agent_workspace_active?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        content_width = metrics.fetch(:sidebar_width) - 4
        content_height = metrics.fetch(:top_height) - 2
        return nil if content_width <= 0 || content_height <= 0

        {
          content_x: metrics.fetch(:sidebar_x) + 2,
          content_y: metrics.fetch(:top_y) + 1,
          content_width: content_width,
          content_height: content_height,
          lines: agent_tree_pane.lines(state, width: content_width)
        }
      end

      # A clipped tree must never read as missing data, so the pane title says
      # how many rows are hidden above and below the viewport.
      def agent_tree_title(line_count, content_height, offset)
        content_height = content_height.to_i
        return "agent tree" if content_height <= 0 || line_count.to_i <= content_height

        hidden_above = offset.to_i
        hidden_below = [line_count.to_i - (hidden_above + content_height), 0].max
        "agent tree  ↑#{hidden_above} ↓#{hidden_below}"
      end

      # Shared logs geometry so hit-testing, keyboard selection, and scrolling
      # all wrap the same content at the same width.
      def logs_content_dimensions(state, width:, height:)
        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        content_width = metrics.fetch(:main_width) - 4
        content_height = metrics.fetch(:logs_height) - 2
        return nil if content_width <= 0 || content_height <= 0

        {
          content_x: metrics.fetch(:main_x) + 2,
          content_y: metrics.fetch(:top_y) + 1,
          content_width: content_width,
          content_height: content_height,
          lines: chat_pane.log_lines(state, width: content_width)
        }
      end

      def logs_text_view(state, width:, height:)
        dimensions = logs_content_dimensions(state, width: width, height: height)
        return nil unless dimensions

        content_x = dimensions.fetch(:content_x)
        content_width = dimensions.fetch(:content_width)
        content_height = dimensions.fetch(:content_height)
        lines = dimensions.fetch(:lines)
        window = tail_window(lines.length, content_height, pane_scroll_offset(state, "logs"))
        first_row_y = dimensions.fetch(:content_y) + window.fetch(:row_offset)
        rows = (window.fetch(:start_index)...window.fetch(:finish_index)).each_with_index.map do |line_index, offset|
          {
            line_index: line_index,
            y: first_row_y + offset,
            text: line_plain_text(lines[line_index])
          }
        end

        { x: content_x, width: content_width, rows: rows, lines: lines }
      end

      # The logs title carries the active AgentTree filter when one is selected.
      def logs_pane_title(state)
        return "logs" unless chat_pane.respond_to?(:log_pane_title)

        chat_pane.log_pane_title(state)
      end

      def logs_pane_title_style(state)
        return nil unless chat_pane.respond_to?(:log_pane_title_style)

        chat_pane.log_pane_title_style(state)
      end

      def composer_pane_title(state)
        return "chat" unless chat_pane.respond_to?(:composer_pane_title)

        chat_pane.composer_pane_title(state)
      end

      # nil keeps draw_pane's focus-driven default, which is what the untargeted
      # composer states render as.
      def composer_border_style(state, active:)
        return nil unless chat_pane.respond_to?(:composer_border_style)

        chat_pane.composer_border_style(state, active: active)
      end

      def composer_title_style(state)
        return nil unless chat_pane.respond_to?(:composer_title_style)

        chat_pane.composer_title_style(state)
      end

      def pane_selection(state, pane)
        selection = state.fetch("_selection", {}) || {}
        return nil unless selection.fetch("pane", nil).to_s == pane.to_s

        selection
      end

      def line_plain_text(line)
        return line.to_s unless line.is_a?(Array)

        line.map { |segment| segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s }.join
      end

      # Bounded like the dashboard's slash popup: the transcript keeps a usable
      # minimum height, and the list collapses instead of squeezing it away.
      def workspace_suggestion_height(state, height, composer_height)
        return 0 unless agent_workspace_pane.respond_to?(:slash_suggestions?) && agent_workspace_pane.slash_suggestions?(state)

        desired = [agent_workspace_pane.slash_suggestion_lines(state).length + 2, 8].min
        available = height - BOTTOM_HINT_HEIGHT - composer_height - GAP - MIN_CHAT_HEIGHT - GAP
        bounded = [desired, [available, 0].max].min
        bounded >= 3 ? bounded : 0
      end

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
        popup = popup_metrics(state, height, composer_height)
        suggestion_height = popup.fetch(:height)
        suggestion_footer_height = popup.fetch(:footer_height)
        vertical_gaps = GAP + (suggestion_height.positive? ? GAP : 0)
        top_height = height - BOTTOM_HINT_HEIGHT - composer_height - suggestion_height - suggestion_footer_height - vertical_gaps

        logs_height = top_height

        {
          top_y: top_y,
          top_height: top_height,
          sidebar_x: sidebar_x,
          sidebar_width: sidebar_width,
          main_x: main_x,
          main_width: main_width,
          logs_height: logs_height,
          suggestion_x: composer_x,
          suggestion_y: top_y + top_height + GAP,
          suggestion_width: composer_width,
          suggestion_height: suggestion_height,
          suggestion_footer_height: suggestion_footer_height,
          suggestion_footer_y: top_y + top_height + GAP + suggestion_height,
          composer_x: composer_x,
          composer_y: top_y + top_height + GAP + (suggestion_height.positive? ? suggestion_height + suggestion_footer_height + GAP : 0),
          composer_width: composer_width,
          composer_height: composer_height,
          composer_content_width: composer_content_width,
          hint_x: OUTER_MARGIN + 1,
          hint_y: height - BOTTOM_HINT_HEIGHT,
          hint_width: width - (OUTER_MARGIN * 2) - 1
        }
      end

      # One popup slot above the composer, shared by the slash-command list and the
      # open-PR picker (see ChatPane#popup?), so both are bounded the same way.
      #
      # The caption under the box gets its own reserved row, so the box keeps every
      # visible entry row it would otherwise have spent on the counter, and the
      # caption can never overlap the composer or the bottom hint line. The list
      # collapses entirely rather than squeezing the logs pane below MIN_CHAT_HEIGHT.
      def popup_metrics(state, total_height, composer_height)
        return { height: 0, footer_height: 0 } unless chat_pane.popup?(state)

        footer_height = chat_pane.popup_footer_line(state).empty? ? 0 : 1
        desired_height = [chat_pane.popup_lines(state).length + 2, 7].min
        available_height = total_height - BOTTOM_HINT_HEIGHT - composer_height - GAP - MIN_CHAT_HEIGHT - GAP - footer_height
        height = [desired_height, [available_height, 0].max].min
        return { height: 0, footer_height: 0 } if height < 3

        { height: height, footer_height: footer_height }
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

      # The stored offset is the single source of truth for what the tree shows.
      # Keeping a selected row visible is a scroll update owned by the app (see
      # agent_tree_scroll_offset_for_line), not a render-time override, so manual
      # scrolling is never fought by the renderer.
      def agent_tree_scroll_offset(state, lines, content_height)
        content_height = content_height.to_i
        return 0 if content_height <= 0 || lines.length <= content_height

        pane_scroll_offset(state, "agent_tree").clamp(0, scroll_max(lines.length, content_height))
      end

      def pane_scroll_offset(state, pane)
        scroll = state.fetch("_scroll", {}) || {}
        offsets = scroll.fetch("offsets", {}) || {}
        offsets.fetch(pane, 0).to_i
      end

      def focusable_pane_bounds(metrics)
        {
          "agent_tree" => pane_bounds(metrics, :sidebar_x, :top_y, :sidebar_width, :top_height),
          "logs" => pane_bounds(metrics, :main_x, :top_y, :main_width, :logs_height),
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

      def draw_pane(canvas, x, y, width, height, title, lines, active: false, overflow: :head, scroll_offset: 0,
                    selection: nil, border_style: nil, title_style: nil)
        border_style ||= active ? Style::BORDER_ACTIVE : Style::BORDER
        canvas.draw_box(x, y, width, height, title: title, style: border_style, title_style: title_style || Style::PANEL_TITLE)
        content_width = width - 4
        content_height = height - 2
        return if content_width <= 0 || content_height <= 0

        case overflow
        when :tail
          draw_tail_content(canvas, x, y, content_width, content_height, lines, scroll_offset: scroll_offset, selection: selection)
        when :terminal
          draw_terminal_content(canvas, x, y, content_width, content_height, lines, scroll_offset: scroll_offset)
        when :pinned_tail
          draw_pinned_tail_content(canvas, x, y, content_width, content_height, lines, scroll_offset: scroll_offset)
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

      # Mirrors draw_pinned_tail_content so clamping and drawing agree.
      def pinned_tail_scroll_max(lines, content_height)
        content_height = content_height.to_i
        return 0 if content_height <= 0

        pinned_count = pinned_line_count(lines)
        pinned_height = [pinned_count, content_height].min
        remaining_height = content_height - pinned_height
        return 0 unless remaining_height.positive?

        tail_length = lines.length - pinned_count
        visible_capacity = [remaining_height - 1, 0].max
        return 0 if tail_length <= remaining_height || visible_capacity.zero?

        [tail_length - visible_capacity, 0].max
      end

      def pinned_line_count(lines)
        separator = lines.index do |line|
          Array(line).all? { |segment| (segment.is_a?(Array) ? segment.first : segment).to_s.empty? }
        end
        separator ? separator + 1 : [lines.length, 5].min
      end

      def draw_pinned_tail_content(canvas, x, y, content_width, content_height, lines, scroll_offset: 0)
        pinned_count = pinned_line_count(lines)
        pinned = lines.first([pinned_count, content_height].min)
        pinned.each_with_index { |line, index| draw_line(canvas, x + 2, y + 1 + index, content_width, line) }

        remaining_height = content_height - pinned.length
        return unless remaining_height.positive?

        tail = lines.drop(pinned_count)
        if tail.length <= remaining_height
          tail.each_with_index do |line, index|
            draw_line(canvas, x + 2, y + 1 + pinned.length + index, content_width, line)
          end
          return
        end

        visible_capacity = [remaining_height - 1, 0].max
        offset = scroll_offset.to_i.clamp(0, [tail.length - visible_capacity, 0].max)
        finish_index = tail.length - offset
        start_index = [finish_index - visible_capacity, 0].max
        label = offset.positive? ? "… #{start_index} earlier · #{offset} later" : "… #{start_index} earlier"
        canvas.write(x + 2, y + 1 + pinned.length, label.ljust(content_width), max_width: content_width, style: Style::DIM)
        Array(tail[start_index...finish_index]).each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 2 + pinned.length + index, content_width, line)
        end
      end

      # A live shell screen is already sized to the pane, so it is drawn as a
      # viewport: no row is spent on an overflow label and the newest rows stay
      # visible. Transient notices above the screen scroll away first.
      def draw_terminal_content(canvas, x, y, content_width, content_height, lines, scroll_offset: 0)
        offset = scroll_offset.to_i.clamp(0, [lines.length - content_height, 0].max)
        finish_index = lines.length - offset
        start_index = [finish_index - content_height, 0].max
        Array(lines[start_index...finish_index]).each_with_index do |line, index|
          draw_line(canvas, x + 2, y + 1 + index, content_width, line)
        end
      end

      def draw_tail_content(canvas, x, y, content_width, content_height, lines, scroll_offset: 0, selection: nil)
        window = tail_window(lines.length, content_height, scroll_offset)
        label = window.fetch(:label)
        canvas.write(x + 2, y + 1, label.ljust(content_width), max_width: content_width, style: Style::DIM) if label

        first_row_y = y + 1 + window.fetch(:row_offset)
        (window.fetch(:start_index)...window.fetch(:finish_index)).each_with_index do |line_index, offset|
          row_y = first_row_y + offset
          line = lines[line_index]
          draw_line(canvas, x + 2, row_y, content_width, line)
          highlight_selection(canvas, x + 2, row_y, content_width, line, line_index, selection)
        end
      end

      # Shared visible window for tail panes so rendering, scroll bounds, and
      # selection hit-testing always agree on which content line is on which row.
      def tail_window(line_count, content_height, scroll_offset)
        line_count = line_count.to_i
        content_height = content_height.to_i
        if line_count <= content_height
          return { start_index: 0, finish_index: line_count, row_offset: 0, label: nil }
        end

        visible_capacity = [content_height - 1, 0].max
        offset = scroll_offset.to_i.clamp(0, tail_scroll_max(line_count, content_height))
        finish_index = line_count - offset
        start_index = [finish_index - visible_capacity, 0].max
        label = offset.positive? ? "… #{start_index} earlier · #{offset} later" : "… #{start_index} earlier"
        { start_index: start_index, finish_index: finish_index, row_offset: 1, label: label }
      end

      # Selection only restyles cells that were already drawn for this pane, so a
      # highlight cannot escape the pane and costs nothing extra to redraw.
      def highlight_selection(canvas, x, y, content_width, line, line_index, selection)
        return unless selection

        text = line_plain_text(line)
        visible_length = [text.length, content_width].min
        columns = Selection.columns_for(selection, line_index, visible_length)
        canvas.restyle(x + columns.first, y, columns.size, Style::SELECTION) if columns
        highlight_selection_cursor(canvas, x, y, content_width, line_index, selection)
      end

      # The keyboard selection caret is one restyled cell, so it renders with the
      # same SELECTION colors as a drag highlight and costs one extra cell.
      def highlight_selection_cursor(canvas, x, y, content_width, line_index, selection)
        cursor = selection.fetch("cursor", nil)
        return unless cursor.is_a?(Hash)
        return unless cursor.fetch("line", -1).to_i == line_index

        column = cursor.fetch("column", 0).to_i.clamp(0, [content_width - 1, 0].max)
        canvas.restyle(x + column, y, 1, Style.selection_cursor)
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
