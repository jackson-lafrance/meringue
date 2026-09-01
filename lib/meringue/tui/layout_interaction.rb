# frozen_string_literal: true

module Meringue
  module TUI
    class Layout
    private
      def agent_workspace_active?(state)
        return false if settings_active?(state)

        workspace = state.fetch("_agent_workspace", {}) || {}
        !!workspace.fetch("active", false)
      end

      def embedded_agent_workspace?(state)
        workspace = state.fetch("_agent_workspace", {}) || {}
        agent_workspace_active?(state) && !!workspace.fetch("embedded", false)
      end

      def fullscreen_agent_workspace?(state)
        agent_workspace_active?(state) && !embedded_agent_workspace?(state)
      end

      def dashboard_status_bar_lines(state)
        components = chat_pane.status_bar_components(state)
        left = %w[context human_input open_pull_requests workers heads].flat_map { |id| status_bar_component(components, id) }
        right = %w[harness model thinking].flat_map { |id| status_bar_component(components, id) }
        [join_status_bar_components(left), join_status_bar_components(right)]
      end

      def status_bar_component(components, id)
        segments = components[id] || components[id.to_sym]
        Array(segments).empty? ? [] : [segments]
      end

      def join_status_bar_components(components)
        components.each_with_index.flat_map { |segments, index| index.zero? ? Array(segments) : [[" · ", Style::DIM]] + Array(segments) }
      end

      def render_setup(canvas, state, width, height, color:)
        geometry = settings_pane.geometry(state, width: width, height: height)
        if geometry.fetch(:too_small)
          message = "Terminal too small for Setup (need #{Settings::MIN_WIDTH}×#{Settings::MIN_HEIGHT})"
          canvas.write_segments(
            [(width - message.length) / 2, 0].max,
            [height / 2, 0].max,
            [[message, Style::WARNING]],
            max_width: width
          )
          canvas.write_segments(1, [height - 1, 0].max, [["Esc cancel", Style::ACCENT_BOLD]], max_width: [width - 2, 1].max)
          return canvas.render(color: color)
        end

        view = settings_pane.setup_view(state, width: width, height: height)
        card = geometry.fetch(:card)
        canvas.draw_box(card.fetch(:x), card.fetch(:y), card.fetch(:width), card.fetch(:height), title: view.fetch(:card_title), style: Style::BORDER_ACTIVE, title_style: Style::TITLE)
        content_width = view.fetch(:content_width)
        heading = [["#{settings_pane.setup_animation_marker(state)} #{view.fetch(:heading)}", Style::PANEL_TITLE]]
        write_centered_segments(canvas, card.fetch(:x) + 2, card.fetch(:y) + 1, content_width, heading)
        progress = view.fetch(:progress)
        write_centered_segments(canvas, card.fetch(:x) + 2, card.fetch(:y) + 2, content_width, progress.fetch(:caption))
        write_centered_segments(canvas, card.fetch(:x) + 2, card.fetch(:y) + 3, content_width, progress.fetch(:bar)) unless progress.fetch(:bar).empty?
        view.fetch(:lines).each_with_index do |line, index|
          draw_line(canvas, view.fetch(:content_x), view.fetch(:content_y) + index, content_width, line)
        end
        footer_y = geometry.fetch(:footer_y)
        footer = settings_pane.setup_footer_segments(state, width: width)
        actions = !view.fetch(:modal, false) ? settings_pane.action_segments(state) : []
        action_width = segment_text_width(actions)
        action_x = actions.empty? ? card.fetch(:x) + card.fetch(:width) - 2 : card.fetch(:x) + [(card.fetch(:width) - action_width) / 2, 1].max
        counter = view.fetch(:counter).to_s
        unless counter.empty?
          canvas.write_segments(
            card.fetch(:x) + 2,
            geometry.fetch(:action_y),
            [[counter, Style::DIM]],
            max_width: [action_x - card.fetch(:x) - 3, 1].max
          )
        end
        unless actions.empty?
          canvas.write_segments([action_x, card.fetch(:x) + 1].max, geometry.fetch(:action_y), actions, max_width: action_width)
        end
        canvas.write_segments(1, footer_y, footer, max_width: [width - 2, 1].max, default_style: Style::DIM)
        canvas.render(color: color)
      end

      def render_settings(canvas, state, width, height, color:)
        geometry = settings_pane.geometry(state, width: width, height: height)
        if geometry.fetch(:too_small)
          mode = Settings.snapshot(state).fetch("mode", "settings") == "setup" ? "Setup" : "Settings"
          message = "Terminal too small for #{mode} (need #{Settings::MIN_WIDTH}×#{Settings::MIN_HEIGHT})"
          cancel = "Esc cancel"
          canvas.write_segments(
            [(width - message.length) / 2, 0].max,
            [height / 2, 0].max,
            [[message, Style::WARNING]],
            max_width: width
          )
          canvas.write_segments(1, [height - 1, 0].max, [[cancel, Style::ACCENT_BOLD]], max_width: [width - 2, 1].max)
          return canvas.render(color: color)
        end

        header = settings_pane.header_segments(state, width: width)
        canvas.write_segments(
          [(width - segment_text_width(header)) / 2, 0].max,
          geometry.fetch(:header_y),
          header,
          max_width: width,
          default_style: Style::TITLE
        )
        detail_bounds = geometry.fetch(:detail)
        detail = settings_pane.detail(
          state,
          width: [detail_bounds.fetch(:width) - 4, 8].max,
          height: [detail_bounds.fetch(:height) - 2, 1].max
        )
        if geometry.fetch(:wide)
          rail = geometry.fetch(:rail)
          draw_pane(
            canvas,
            rail.fetch(:x), rail.fetch(:y), rail.fetch(:width), rail.fetch(:height),
            Settings.snapshot(state).fetch("mode", "settings") == "setup" ? "setup steps" : "categories",
            settings_pane.category_lines(state, height: rail.fetch(:height) - 2),
            active: true
          )
        end
        snap = Settings.snapshot(state)
        selected_category = snap.fetch("category", "settings")
        title = if geometry.fetch(:wide)
                  selected_category
                elsif snap.fetch("mode", "settings") == "setup"
                  "#{snap.fetch("setup_step", 1)}/#{snap.fetch("setup_step_count", 1)} · #{selected_category}  ·  Tab steps"
                else
                  "#{selected_category}  ·  Tab/Shift-Tab categories"
                end
        draw_pane(
          canvas,
          detail_bounds.fetch(:x), detail_bounds.fetch(:y), detail_bounds.fetch(:width), detail_bounds.fetch(:height),
          title,
          detail.fetch(:lines),
          active: true
        )
        footer_y = geometry.fetch(:footer_y)
        footer = settings_pane.footer_segments(state, width: width)
        actions = width >= Settings::WIDE_WIDTH ? settings_pane.action_segments(state) : []
        action_width = segment_text_width(actions)
        canvas.write_segments(1, footer_y, footer, max_width: [width - action_width - 3, 1].max, default_style: Style::DIM)
        canvas.write_segments([width - action_width - 1, 0].max, footer_y, actions, max_width: action_width)
        counter = detail.fetch(:counter, "").to_s
        unless counter.empty? || footer_y <= geometry.fetch(:body_y)
          canvas.write_segments(
            [detail_bounds.fetch(:x) + detail_bounds.fetch(:width) - counter.length - 2, detail_bounds.fetch(:x) + 2].max,
            [footer_y - 1, geometry.fetch(:body_y)].max,
            [[counter, Style::DIM]],
            max_width: [detail_bounds.fetch(:width) - 4, 1].max
          )
        end
        canvas.render(color: color)
      end

      def render_agent_workspace(canvas, state, width, height, color:)
        workspace = state.fetch("_agent_workspace", {}) || {}
        view = workspace.fetch("view", "agent")
        pane_x = OUTER_MARGIN
        pane_width = width - (OUTER_MARGIN * 2)
        hint_y = height - BOTTOM_HINT_HEIGHT

        if workspace.fetch("interactive", false)
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
            scroll_offset: 0,
            title_style: agent_workspace_title_style(state)
          )
        elsif view == "terminal"
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

      def bounded_width(width)
        [width.to_i, 1].max
      end

      def bounded_height(height)
        [height.to_i, 1].max
      end

      def agent_tree_content_dimensions(state, width:, height:)
        return nil if settings_active?(state) || fullscreen_agent_workspace?(state)

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

      def agent_tree_title(line_count, content_height, offset)
        content_height = content_height.to_i
        return "agent tree" if content_height <= 0 || line_count.to_i <= content_height

        hidden_above = offset.to_i
        hidden_below = [line_count.to_i - (hidden_above + content_height), 0].max
        "agent tree  ↑#{hidden_above} ↓#{hidden_below}"
      end

      def logs_content_dimensions(state, width:, height:)
        return nil if embedded_agent_workspace?(state)

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

      def logs_pane_title(state, width: nil)
        return "logs" unless chat_pane.respond_to?(:log_pane_title)

        chat_pane.log_pane_title(state, width: width)
      end

      def logs_pane_title_style(state)
        return nil unless chat_pane.respond_to?(:log_pane_title_style)

        chat_pane.log_pane_title_style(state)
      end

      def composer_pane_title(state)
        return "chat" unless chat_pane.respond_to?(:composer_pane_title)

        chat_pane.composer_pane_title(state)
      end

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

      def workspace_suggestion_height(state, height, composer_height)
        return 0 unless agent_workspace_pane.respond_to?(:slash_suggestions?) && agent_workspace_pane.slash_suggestions?(state)

        desired = [agent_workspace_pane.slash_suggestion_lines(state).length + 2, 8].min
        available = height - BOTTOM_HINT_HEIGHT - composer_height - GAP - MIN_CHAT_HEIGHT - GAP
        bounded = [desired, [available, 0].max].min
        bounded >= 3 ? bounded : 0
      end

      # Geometry equality is the safety gate for row-only input updates. Popup,
      # context-menu, resize, and multiline-height changes all need a full frame.
      def input_surface_geometry(state, width, height)
        return nil if settings_active?(state) || context_menu_snapshot(state)

        width = bounded_width(width)
        height = bounded_height(height)
        if fullscreen_agent_workspace?(state)
          workspace = state.fetch("_agent_workspace", {}) || {}
          return nil if workspace.fetch("interactive", false) || workspace.fetch("view", "agent") != "agent"
          return nil if agent_workspace_pane.slash_suggestions?(state)

          pane_width = width - (OUTER_MARGIN * 2)
          content_width = pane_width - 4
          line_count = agent_workspace_pane.composer_lines(state, width: content_width).length
          composer_height = composer_height_for(height - BOTTOM_HINT_HEIGHT, line_count)
          return {
            surface: :workspace,
            screen_width: width,
            x: OUTER_MARGIN,
            y: height - BOTTOM_HINT_HEIGHT - composer_height,
            width: pane_width,
            height: composer_height,
            content_width: content_width
          }
        end

        return nil if chat_pane.popup?(state)

        metrics = layout_metrics(width, height, state)
        {
          surface: :dashboard,
          screen_width: width,
          x: metrics.fetch(:composer_x),
          y: metrics.fetch(:composer_y),
          width: metrics.fetch(:composer_width),
          height: metrics.fetch(:composer_height),
          content_width: metrics.fetch(:composer_content_width),
          metrics: metrics
        }
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

      def popup_metrics(state, total_height, composer_height)
        return { height: 0, footer_height: 0 } unless chat_pane.popup?(state)

        footer_height = chat_pane.popup_footer_line(state).empty? ? 0 : 1
        desired_height = [chat_pane.popup_lines(state).length + 2, chat_pane.popup_max_box_height(state)].min
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
        return canvas.write_segments(x, y, line, max_width: width, default_style: Style::MUTED) unless right_width.positive?

        # Keep the right-hand status as the right-hand status even when a
        # role-split model summary is wider than the terminal. The old fallback
        # drew the left hint instead, making model/status text disappear or jump
        # sides as the effective string crossed the available width.
        visible_right_width = [right_width, width].min
        left_width = hint_left_width(width, right_line)
        if right_width < width
          canvas.write_segments(x, y, line, max_width: left_width, default_style: Style::MUTED)
        end
        canvas.write_segments(
          x + width - visible_right_width,
          y,
          right_line,
          max_width: visible_right_width,
          default_style: Style::MUTED
        )
      end

      def hint_left_width(width, right_line)
        right_width = segment_text_width(right_line)
        return width unless right_width.positive?

        visible_right_width = [right_width, width].min
        [width - visible_right_width - 2, 0].max
      end

      def write_centered_segments(canvas, x, y, width, segments)
        line_width = segment_text_width(segments)
        offset = [(width.to_i - line_width) / 2, 0].max
        canvas.write_segments(x.to_i + offset, y, segments, max_width: [width.to_i - offset, 0].max, default_style: Style::TEXT)
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

      def highlight_selection(canvas, x, y, content_width, line, line_index, selection)
        return unless selection

        text = line_plain_text(line)
        visible_length = [text.length, content_width].min
        columns = Selection.columns_for(selection, line_index, visible_length)
        canvas.restyle(x + columns.first, y, columns.size, Style::SELECTION) if columns
        highlight_selection_cursor(canvas, x, y, content_width, line_index, selection)
      end

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
