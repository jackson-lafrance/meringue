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
                     agent_workspace_pane: Panes::AgentWorkspacePane.new,
                     settings_pane: Panes::SettingsPane.new)
        @agent_tree_pane = agent_tree_pane
        @chat_pane = chat_pane
        @agent_workspace_pane = agent_workspace_pane
        @settings_pane = settings_pane
      end

      def render(state, width:, height:, color: false)
        raw_width = [width.to_i, 1].max
        raw_height = [height.to_i, 1].max
        if settings_active?(state)
          canvas = Canvas.new(width: raw_width, height: raw_height)
          return render_setup(canvas, state, raw_width, raw_height, color: color) if Settings.snapshot(state).fetch("mode", "settings") == "setup"

          return render_settings(canvas, state, raw_width, raw_height, color: color)
        end
        width = bounded_width(width)
        height = bounded_height(height)
        canvas = Canvas.new(width: width, height: height)
        return render_agent_workspace(canvas, state, width, height, color: color) if fullscreen_agent_workspace?(state)

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
        if embedded_agent_workspace?(state)
          workspace = state.fetch("_agent_workspace", {}) || {}
          draw_pane(
            canvas,
            metrics.fetch(:main_x),
            metrics.fetch(:top_y),
            metrics.fetch(:main_width),
            metrics.fetch(:logs_height),
            nil,
            agent_workspace_pane.content_lines(state, width: metrics.fetch(:main_width) - 4),
            active: scroll_pane_active?(state, "logs"),
            overflow: :terminal,
            # Native harness history is application-owned and is changed by
            # forwarded wheel/page input. Only the separate worktree terminal
            # retains a Meringue viewport offset.
            scroll_offset: workspace.fetch("view", "agent") == "terminal" ? workspace.fetch("scroll_offset", 0) : 0,
            title_style: agent_workspace_title_style(state)
          )
          status = agent_workspace_pane.top_status_layout(state, width: metrics.fetch(:main_width) - 4)
          canvas.write_segments(
            metrics.fetch(:main_x) + 2,
            metrics.fetch(:top_y),
            status.fetch(:segments),
            max_width: [metrics.fetch(:main_width) - 4, 0].max
          )
        else
          draw_pane(
            canvas,
            metrics.fetch(:main_x),
            metrics.fetch(:top_y),
            metrics.fetch(:main_width),
            metrics.fetch(:logs_height),
            logs_pane_title(state, width: metrics.fetch(:main_width) - 4),
            chat_pane.log_lines(state, width: metrics.fetch(:main_width) - 4),
            active: scroll_pane_active?(state, "logs"),
            overflow: :tail,
            scroll_offset: pane_scroll_offset(state, "logs"),
            selection: pane_selection(state, "logs"),
            # A filtered logs pane carries the identity color of the node it is
            # filtered to.
            title_style: logs_pane_title_style(state)
          )
        end
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
        composer_lines = chat_pane.composer_lines(state, width: metrics.fetch(:composer_content_width))
        draw_pane(
          canvas,
          metrics.fetch(:composer_x),
          metrics.fetch(:composer_y),
          metrics.fetch(:composer_width),
          metrics.fetch(:composer_height),
          composer_pane_title(state),
          composer_lines,
          active: composer_active,
          overflow: :tail,
          # The composer follows the caret rather than exposing a separate scroll
          # control, so upward navigation never leaves it above the viewport.
          scroll_offset: composer_viewport_offset(state, metrics, composer_lines),
          # The composer is tinted with the selected chat target's own color, so
          # the box the user types into matches the AgentTree row it prompts.
          border_style: composer_border_style(state, active: composer_active),
          title_style: composer_title_style(state)
        )
        bottom_left, bottom_right = dashboard_status_bar_lines(state)
        draw_hint_line(
          canvas,
          metrics.fetch(:hint_x),
          metrics.fetch(:hint_y),
          metrics.fetch(:hint_width),
          bottom_left,
          bottom_right
        )
        # Drawn last so it floats above every pane it overlaps.
        draw_context_menu(canvas, state, width, height)

        canvas.render(color: color)
      end

      CONTEXT_MENU_STATE_KEY = "_context_menu"

      def context_menu_snapshot(state)
        value = (state || {}).fetch(CONTEXT_MENU_STATE_KEY, nil)
        value.is_a?(Hash) && value.fetch("active", false) ? value : nil
      end

      # Geometry for the floating menu, clamped so the whole box stays on screen
      # no matter where the click landed. A click near the right or bottom edge
      # flips the box back inside rather than being drawn half off the canvas.
      def context_menu_geometry(state, width:, height:)
        menu = context_menu_snapshot(state)
        return nil unless menu

        entries = Array(menu.fetch("entries", []))
        return nil if entries.empty?

        label_width = entries.map { |entry| context_menu_entry_text(entry).length }.max.to_i
        box_width = [[label_width + 4, 22].max, [width.to_i - 2, 22].max].min
        box_height = [entries.length + 2, [height.to_i - 2, 3].max].min
        x = menu.fetch("x", 0).to_i
        y = menu.fetch("y", 0).to_i
        x = [[x, 0].max, [width.to_i - box_width, 0].max].min
        y = [[y, 0].max, [height.to_i - box_height, 0].max].min
        { x: x, y: y, width: box_width, height: box_height, entries: entries, visible: box_height - 2 }
      end

      def ascii_glyphs?
        defined?(Harness::Registry) && Harness::Registry.ascii_glyphs?
      end

      def context_menu_entry_text(entry)
        note = entry.fetch("note", nil).to_s
        label = entry.fetch("label", "").to_s
        note.empty? || entry.fetch("enabled", true) ? label : "#{label} — #{note}"
      end

      def draw_context_menu(canvas, state, width, height)
        geometry = context_menu_geometry(state, width: width, height: height)
        return unless geometry

        menu = context_menu_snapshot(state)
        entries = geometry.fetch(:entries)
        selected = menu.fetch("index", 0).to_i.clamp(0, entries.length - 1)
        visible = geometry.fetch(:visible)
        start = [[selected - visible + 1, 0].max, [entries.length - visible, 0].max].min
        canvas.draw_box(
          geometry.fetch(:x), geometry.fetch(:y), geometry.fetch(:width), geometry.fetch(:height),
          title: menu.fetch("title", nil), style: Style::BORDER_ACTIVE, title_style: Style::PANEL_TITLE
        )
        entries.drop(start).first(visible).each_with_index do |entry, offset|
          index = start + offset
          chosen = index == selected
          enabled = entry.fetch("enabled", true)
          style = if !enabled
                    Style::DIM
                  else
                    chosen ? Style::AGENT_TREE_SELECTED : Style::TEXT
                  end
          marker = chosen ? (ascii_glyphs? ? ">" : "›") : " "
          canvas.write_segments(
            geometry.fetch(:x) + 1,
            geometry.fetch(:y) + 1 + offset,
            [["#{marker} #{context_menu_entry_text(entry)}", style]],
            max_width: [geometry.fetch(:width) - 2, 0].max
          )
        end
      end

      # Which entry a click at (x, y) lands on, or nil when the click is outside
      # the menu entirely. The app uses nil to mean "dismiss".
      def context_menu_entry_at(state, width:, height:, x:, y:)
        geometry = context_menu_geometry(state, width: width, height: height)
        return nil unless geometry

        menu = context_menu_snapshot(state)
        entries = geometry.fetch(:entries)
        visible = geometry.fetch(:visible)
        selected = menu.fetch("index", 0).to_i.clamp(0, entries.length - 1)
        start = [[selected - visible + 1, 0].max, [entries.length - visible, 0].max].min
        row = y.to_i - geometry.fetch(:y) - 1
        return nil if row.negative? || row >= visible
        return nil unless x.to_i >= geometry.fetch(:x) && x.to_i < geometry.fetch(:x) + geometry.fetch(:width)

        index = start + row
        index < entries.length ? index : nil
      end

      def context_menu_hit?(state, width:, height:, x:, y:)
        geometry = context_menu_geometry(state, width: width, height: height)
        return false unless geometry

        x.to_i >= geometry.fetch(:x) && x.to_i < geometry.fetch(:x) + geometry.fetch(:width) &&
          y.to_i >= geometry.fetch(:y) && y.to_i < geometry.fetch(:y) + geometry.fetch(:height)
      end

      def pane_at(state, width:, height:, x:, y:)
        return "settings" if settings_active?(state)
        return "agent_workspace" if fullscreen_agent_workspace?(state)

        metrics = layout_metrics([width.to_i, MIN_WIDTH].max, [height.to_i, MIN_HEIGHT].max, state)
        focusable_pane_bounds(metrics).find do |_pane, bounds|
          point_in_bounds?(x.to_i, y.to_i, bounds)
        end&.first
      end

      # Resolves clicks on the embedded Agent session's top control strip. The
      # leader itself is a visual state indicator; destination controls return
      # their normal workspace action.
      def agent_workspace_control_at(state, width:, height:, x:, y:)
        return nil unless embedded_agent_workspace?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return nil unless point_in_bounds?(x.to_i, y.to_i, {
          x: metrics.fetch(:main_x),
          y: metrics.fetch(:top_y),
          width: metrics.fetch(:main_width),
          height: metrics.fetch(:logs_height)
        })
        return nil unless y.to_i == metrics.fetch(:top_y)

        relative_x = x.to_i - metrics.fetch(:main_x) - 2
        status = agent_workspace_pane.top_status_layout(state, width: metrics.fetch(:main_width) - 4)
        status.fetch(:controls).find do |record|
          relative_x >= record.fetch(:start) && relative_x < record.fetch(:finish)
        end&.fetch(:action)
      end

      # Converts dashboard coordinates into the one-based coordinates of the
      # embedded Agent session's PTY. Hovering the pane is enough; dashboard
      # focus does not need to move first.
      def agent_workspace_mouse_event(state, width:, height:, x:, y:, event:)
        return nil unless embedded_agent_workspace?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return nil unless point_in_bounds?(x.to_i, y.to_i, {
          x: metrics.fetch(:main_x),
          y: metrics.fetch(:top_y),
          width: metrics.fetch(:main_width),
          height: metrics.fetch(:logs_height)
        })

        dimensions = embedded_agent_workspace_dimensions(state, width: width, height: height)
        event.merge(
          "x" => (x.to_i - metrics.fetch(:main_x) - 1).clamp(1, dimensions.fetch("columns")),
          "y" => (y.to_i - metrics.fetch(:top_y)).clamp(1, dimensions.fetch("rows"))
        )
      end

      # The all-open-PR count is one actionable segment in the dashboard summary
      # row, not a target covering the whole row. Map only the cells actually
      # rendered for "1 open PR" / "N open PRs"; neighboring status and key hints
      # retain their existing mouse behavior. A scoped issue shows its own PR
      # instead, and zero/untracked PRs have no picker to open.
      def open_pull_requests_summary_hit?(state, width:, height:, x:, y:)
        return false if settings_active?(state) || fullscreen_agent_workspace?(state)
        return false unless Settings.github_enabled?(state)
        return false unless DeliveryPullRequest.scoped_id(state).empty?
        return false unless OpenPullRequests.count(state).positive?

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return false unless y.to_i == metrics.fetch(:hint_y)

        label = OpenPullRequests.summary_label(state)
        offset = 0
        dashboard_left, dashboard_right = dashboard_status_bar_lines(state)
        dashboard_left.each do |segment|
          text = segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s
          if text == label
            visible_width = [text.length, hint_left_width(metrics.fetch(:hint_width), dashboard_right) - offset].min
            return false unless visible_width.positive?

            start_x = metrics.fetch(:hint_x) + offset
            return x.to_i >= start_x && x.to_i < start_x + visible_width
          end
          offset += text.length
        end
        false
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

      # A logs drag remains pane-scoped even after the pointer leaves the pane.
      # Reaching either visible text edge arms autoscroll in that direction; App
      # owns the repeated timer ticks and asks for fresh content coordinates
      # after each offset change.
      def logs_drag_scroll_direction(state, width:, height:, y:)
        view = logs_text_view(state, width: width, height: height)
        rows = view ? view.fetch(:rows) : []
        return nil if rows.empty?

        return :up if y.to_i <= rows.first.fetch(:y)
        return :down if y.to_i >= rows.last.fetch(:y)

        nil
      end

      # Vertical cursor movement follows the same wrapping width used to draw the
      # dashboard composer instead of treating only hard newlines as rows.
      def composer_vertical_cursor(state, width:, height:, input_buffer:, input_cursor:, direction:)
        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        chat_pane.composer_vertical_cursor(
          input_buffer,
          input_cursor,
          direction: direction,
          width: metrics.fetch(:composer_content_width)
        )
      end

      # Worker authored the actionable cell under this logs-pane coordinate.
      # ChatPane owns the per-entry row metadata; Layout only resolves viewport
      # geometry and never guesses an id from displayed prose.
      def logs_worker_at(state, width:, height:, x:, y:)
        dimensions = logs_content_dimensions(state, width: width, height: height)
        position = logs_text_position(state, width: width, height: height, x: x, y: y)
        return nil unless dimensions && position
        return nil unless chat_pane.respond_to?(:log_worker_at)

        chat_pane.log_worker_at(
          state,
          position.fetch("line"),
          position.fetch("column"),
          width: dimensions.fetch(:content_width)
        )
      end

      # Plain text of every wrapped logs content line. Keyboard selection uses
      # this to move a caret through the same coordinates the mouse produces.
      def logs_text_lines(state, width:, height:)
        view = logs_text_view(state, width: width, height: height)
        return [] unless view

        view.fetch(:lines).map { |line| line_plain_text(line) }
      end

      # Inclusive wrapped-row bounds of the displayed paragraph under a logs
      # selection point. ChatPane owns paragraph grouping because it knows which
      # soft-wrapped rows came from the same log body.
      def logs_text_paragraph_range(state, width:, height:, line_index:)
        dimensions = logs_content_dimensions(state, width: width, height: height)
        return nil unless dimensions
        return nil unless chat_pane.respond_to?(:log_paragraph_range)

        chat_pane.log_paragraph_range(state, line_index, width: dimensions.fetch(:content_width))
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

        lines = {}
        view.fetch(:lines).each_with_index { |line, index| lines[index] = line }
        Selection.text_for(selection, lines)
      end

      # Copy one complete displayed logs row through the same segment-aware path
      # as an extended selection. Keyboard selection mode uses this for its
      # unextended caret, so mouse and keyboard copies omit identical chrome.
      def logs_line_copy_text(state, width:, height:, line_index:)
        view = logs_text_view(state, width: width, height: height)
        return "" unless view

        line = view.fetch(:lines)[line_index.to_i]
        return "" unless line

        length = Selection.display_length(line)
        return "" if length.zero?

        selection = Selection.normalize(
          "logs",
          Selection.point(line_index, 0),
          Selection.point(line_index, length)
        )
        Selection.text_for(selection, { line_index.to_i => line })
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

      # Where a click landed relative to the open-question picker: the entry index
      # for a row, `:chrome` for the picker's own border/footer, and `:outside`
      # for anywhere else (which is what dismisses it).
      def question_picker_hit(state, width:, height:, x:, y:)
        return :outside unless chat_pane.question_picker?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return :outside unless metrics.fetch(:suggestion_height).positive?

        bounds = pane_bounds(metrics, :suggestion_x, :suggestion_y, :suggestion_width, :suggestion_height)
        bounds = bounds.merge(height: bounds.fetch(:height) + metrics.fetch(:suggestion_footer_height))
        return :outside unless point_in_bounds?(x.to_i, y.to_i, bounds)

        row = y.to_i - metrics.fetch(:suggestion_y) - 1
        return :chrome if row.negative? || row >= Panes::ChatPane::QUESTION_PICKER_VISIBLE_LIMIT

        index = chat_pane.question_picker_window_start(state) + row
        index < QuestionPicker.entries(state).length ? index : :chrome
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

      def settings_active?(state)
        settings_pane.active?(state)
      end

      def settings_hit(state, width:, height:, x:, y:)
        return :inert unless settings_active?(state)

        settings_pane.hit(state, width: width, height: height, x: x, y: y)
      end

      # Content width used by the inline guidance editor. It is the same width
      # SettingsPane renders, so soft-wrap cursor movement cannot drift from the
      # visible rows.
      def settings_text_width(state, width:, height:)
        geometry = settings_pane.geometry(state, width: width, height: height)
        return 1 if geometry.fetch(:too_small, false)

        bounds = geometry.fetch(geometry.fetch(:setup, false) ? :card : :detail)
        [bounds.fetch(:width).to_i - 4, 1].max
      end

      # Same three answers for the model picker: a row index, `:chrome` for its
      # own border/caption, and `:outside` for a click-away dismiss.
      def model_picker_hit(state, width:, height:, x:, y:)
        return :outside unless chat_pane.model_picker?(state)

        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        return :outside unless metrics.fetch(:suggestion_height).positive?

        bounds = pane_bounds(metrics, :suggestion_x, :suggestion_y, :suggestion_width, :suggestion_height)
        bounds = bounds.merge(height: bounds.fetch(:height) + metrics.fetch(:suggestion_footer_height))
        return :outside unless point_in_bounds?(x.to_i, y.to_i, bounds)

        row = y.to_i - metrics.fetch(:suggestion_y) - 1
        return :chrome if row.negative? || row >= Panes::ChatPane::MODEL_PICKER_VISIBLE_LIMIT

        index = chat_pane.model_picker_window_start(state) + row
        index < chat_pane.model_picker_entries(state).length ? index : :chrome
      end

      def agent_tree_item_at(state, width:, height:, x:, y:)
        return nil if settings_active?(state) || fullscreen_agent_workspace?(state)

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
      # Native focus uses the dashboard's logs rectangle rather than the former
      # full-screen workspace rectangle. The harness PTY receives exactly the
      # drawable content size so it can reflow and handle terminal resize events.
      def embedded_agent_workspace_dimensions(state, width:, height:)
        metrics = layout_metrics(bounded_width(width), bounded_height(height), state)
        {
          "rows" => [metrics.fetch(:logs_height) - 2, 1].max,
          "columns" => [metrics.fetch(:main_width) - 4, 1].max
        }
      end

      def agent_workspace_scroll_max(state, width:, height:)
        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        workspace = state.fetch("_agent_workspace", {}) || {}

        if embedded_agent_workspace?(state)
          # The embedded harness owns its history position; its captured screen
          # is always rendered as one viewport. The worktree terminal remains a
          # Meringue-owned surface and keeps its existing retained-row scrolling.
          return 0 unless workspace.fetch("view", "agent") == "terminal"

          dimensions = embedded_agent_workspace_dimensions(state, width: width, height: height)
          lines = agent_workspace_pane.content_lines(state, width: dimensions.fetch("columns"))
          [lines.length - dimensions.fetch("rows"), 0].max
        else
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
      end

      def scroll_limits(state, width:, height:)
        return { "agent_tree" => 0, "logs" => 0, "chat" => 0 } if settings_active?(state) || fullscreen_agent_workspace?(state)

        width = [width.to_i, MIN_WIDTH].max
        height = [height.to_i, MIN_HEIGHT].max
        metrics = layout_metrics(width, height, state)
        agent_tree_lines = agent_tree_pane.lines(state, width: metrics.fetch(:sidebar_width) - 4)
        log_lines = embedded_agent_workspace?(state) ? [] : chat_pane.log_lines(state, width: metrics.fetch(:main_width) - 4)
        {
          "agent_tree" => scroll_max(agent_tree_lines.length, metrics.fetch(:top_height) - 2),
          "logs" => embedded_agent_workspace?(state) ? 0 : tail_scroll_max(log_lines.length, metrics.fetch(:logs_height) - 2),
          "chat" => 0
        }
      end

      private

      attr_reader :agent_tree_pane, :chat_pane, :agent_workspace_pane, :settings_pane










      # Rendering must stay inside the terminal's real viewport. The old minimum
      # rectangle made a resized terminal receive a wider/taller frame than it
      # could display, which clipped the chat pane at the edges. Geometry below
      # is deliberately defensive for compact terminals instead of expanding the
      # canvas past the requested dimensions.


      # Shared AgentTree geometry so hit-testing, scrolling, reveal, and the
      # overflow indicator all wrap the same content at the same width.

      # A clipped tree must never read as missing data, so the pane title says
      # how many rows are hidden above and below the viewport.

      # Shared logs geometry so hit-testing, keyboard selection, and scrolling
      # all wrap the same content at the same width.


      # The logs title carries the active AgentTree filter when one is selected.



      # nil keeps draw_pane's focus-driven default, which is what the untargeted
      # composer states render as.




      # Bounded like the dashboard's slash popup: the transcript keeps a usable
      # minimum height, and the list collapses instead of squeezing it away.


      # One popup slot above the composer, shared by slash suggestions and every
      # interactive choice picker (models, thinking, themes, harnesses, open
      # questions, and open PRs; see ChatPane#popup?), so all of them stay on-screen
      # instead of duplicating feedback in chat. Only the number of visible rows
      # differs: browsed pickers are allowed to be taller. First-run setup is
      # not in this slot; it takes over the screen.
      #
      # The caption under the box gets its own reserved row, so the box keeps every
      # visible entry row it would otherwise have spent on the counter, and the
      # caption can never overlap the composer or the bottom hint line. The list
      # collapses entirely rather than squeezing the logs pane below MIN_CHAT_HEIGHT.



      # The stored offset is the single source of truth for what the tree shows.
      # Keeping a selected row visible is a scroll update owned by the app (see
      # agent_tree_scroll_offset_for_line), not a render-time override, so manual
      # scrolling is never fought by the renderer.













      # Mirrors draw_pinned_tail_content so clamping and drawing agree.



      # A live shell screen is already sized to the pane, so it is drawn as a
      # viewport: no row is spent on an overflow label and the newest rows stay
      # visible. Transient notices above the screen scroll away first.


      # Shared visible window for tail panes so rendering, scroll bounds, and
      # selection hit-testing always agree on which content line is on which row.
      def composer_viewport_offset(state, metrics, lines)
        content_height = metrics.fetch(:composer_height).to_i - 2
        line_count = Array(lines).length
        return 0 if content_height <= 0 || line_count <= content_height

        visible_capacity = [content_height - 1, 0].max
        return 0 if visible_capacity.zero?

        chat = state.fetch("_chat", {}) || {}
        input = chat.fetch("input_buffer", "").to_s
        cursor = chat.fetch("input_cursor", input.length).to_i
        cursor_row = MultilineInput.cursor_row(input, cursor, width: metrics.fetch(:composer_content_width))
        # tail_window reserves its first row for the hidden-content marker.
        # Offsets are measured back from the newest row.
        [line_count - cursor_row - visible_capacity, 0].max
          .clamp(0, tail_scroll_max(line_count, content_height))
      end

      # Selection only restyles cells that were already drawn for this pane, so a
      # highlight cannot escape the pane and costs nothing extra to redraw.

      # The keyboard selection caret is one restyled cell, so it renders with the
      # same SELECTION colors as a drag highlight and costs one extra cell.



    end
  end
end
