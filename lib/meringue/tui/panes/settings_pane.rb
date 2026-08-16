# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class SettingsPane
        STATE_KEY = Settings::STATE_KEY
        SAVE_LABEL = "[ Save ]"
        CANCEL_LABEL = "[ Cancel ]"

        def active?(state)
          Settings.enabled?(state)
        end

        def snapshot(state)
          Settings.snapshot(state)
        end

        def too_small?(width:, height:)
          width.to_i < Settings::MIN_WIDTH || height.to_i < Settings::MIN_HEIGHT
        end

        def wide?(width)
          width.to_i >= Settings::WIDE_WIDTH
        end

        def compact?(width)
          width.to_i < Settings::COMPACT_WIDTH
        end

        def geometry(state, width:, height:)
          width = [width.to_i, 1].max
          height = [height.to_i, 1].max
          return { too_small: true, width: width, height: height } if too_small?(width: width, height: height)

          footer_y = height - 1
          header_y = 0
          body_y = 2
          body_height = [footer_y - body_y, 1].max
          if wide?(width)
            rail_width = [[width / 4, 22].max, 30].min
            {
              too_small: false,
              wide: true,
              header_y: header_y,
              footer_y: footer_y,
              body_y: body_y,
              body_height: body_height,
              rail: { x: 1, y: body_y, width: rail_width, height: body_height },
              detail: { x: rail_width + 2, y: body_y, width: width - rail_width - 3, height: body_height }
            }
          else
            {
              too_small: false,
              wide: false,
              header_y: header_y,
              footer_y: footer_y,
              body_y: body_y,
              body_height: body_height,
              detail: { x: 1, y: body_y, width: width - 2, height: body_height }
            }
          end
        end

        def header_segments(state, width:)
          snap = snapshot(state)
          mode = snap.fetch("mode", "settings") == "setup" ? "setup" : "settings"
          segments = [["meringue · #{mode}", Style::TITLE]]
          segments << ["  • unsaved", Style::WARNING] if snap.fetch("dirty", false)
          segments << ["  • saving…", Style::ACCENT] if snap.fetch("saving", false)
          segments
        end

        def category_lines(state, height:)
          snap = snapshot(state)
          categories = Array(snap.fetch("categories", []))
          selected = snap.fetch("category_index", 0).to_i.clamp(0, [categories.length - 1, 0].max)
          categories.first([height.to_i, 0].max).map.with_index do |category, index|
            marker = index == selected ? "› " : "  "
            style = index == selected ? Style::ACCENT_BOLD : Style::MUTED
            [["#{marker}#{category}", style]]
          end
        end

        def detail(state, width:, height:)
          snap = snapshot(state)
          return confirmation_detail(snap, width: width, height: height) if snap.fetch("discard_confirm", false)
          return editor_detail(snap, width: width, height: height) if snap.fetch("editor", nil).is_a?(Hash)

          rows = Array(snap.fetch("rows", []))
          selected = snap.fetch("row_index", 0).to_i.clamp(0, [rows.length - 1, 0].max)
          reserved = 4
          capacity = [[height.to_i - reserved, 1].max, 1].max
          start = window_start(rows.length, selected, capacity)
          visible = rows.drop(start).first(capacity)
          lines = visible.map.with_index do |row, offset|
            row_line(row, selected: start + offset == selected, width: width)
          end
          selected_row = rows[selected]
          lines << [["", Style::DIM]]
          if selected_row
            description = selected_row.fetch("description", "").to_s
            detail_text = wrap(description, [width.to_i - 2, 8].max).first(2)
            lines.concat(detail_text.map { |line| [[line, Style::MUTED]] })
            lines << [["current: ", Style::DIM], [selected_row.fetch("display_value", "").to_s, Style::TEXT], [" · default: ", Style::DIM], [selected_row.fetch("default_value", "").to_s, Style::MUTED]]
            error = selected_row.fetch("error", nil).to_s
            lines << [["! #{error}", Style::ERROR]] unless error.empty?
          end
          global_error = snap.fetch("global_error", nil).to_s
          lines << [["! #{global_error}", Style::ERROR]] unless global_error.empty?
          counter = rows.empty? ? "No settings in this category" : "#{start + 1}–#{start + visible.length} of #{rows.length}"
          {
            lines: lines.first([height.to_i, 1].max),
            window_start: start,
            visible_count: visible.length,
            counter: counter,
            selected_row: selected_row
          }
        end

        def footer_segments(state, width:)
          snap = snapshot(state)
          if too_small?(width: width, height: snap.fetch("height", Settings::MIN_HEIGHT))
            return [["Esc cancel", Style::WARNING]]
          end
          if snap.fetch("discard_confirm", false)
            return [["Enter discard", Style::ERROR], [" · Esc keep editing", Style::MUTED]]
          end
          if snap.fetch("editor", nil).is_a?(Hash)
            return [["Enter apply field", Style::ACCENT_BOLD], [" · Esc cancel field", Style::MUTED]]
          end

          error_count = snap.fetch("error_count", 0).to_i
          hint = if compact?(width)
                   "Esc cancel · Ctrl-S save · ↑↓ · Enter edit"
                 else
                   "↑↓ rows · Tab categories · Space toggle · Enter edit · Ctrl-S save · Esc cancel"
                 end
          segments = [[hint, Style::DIM]]
          segments << [" · #{error_count} error#{error_count == 1 ? "" : "s"}", Style::ERROR] if error_count.positive?
          segments
        end

        def action_segments(state)
          snap = snapshot(state)
          save_style = snap.fetch("saving", false) ? Style::DIM : Style::ACCENT_BOLD
          [[SAVE_LABEL, save_style], [" ", Style::DIM], [CANCEL_LABEL, Style::MUTED]]
        end

        # A visible category, row, or footer button. Everything else is inert.
        def hit(state, width:, height:, x:, y:)
          geometry = geometry(state, width: width, height: height)
          return :cancel if geometry.fetch(:too_small) && y.to_i >= height.to_i - 1
          return :inert if geometry.fetch(:too_small)

          snap = snapshot(state)
          if y.to_i == geometry.fetch(:footer_y)
            action_width = SAVE_LABEL.length + 1 + CANCEL_LABEL.length
            start = width.to_i - action_width - 1
            return :save if x.to_i >= start && x.to_i < start + SAVE_LABEL.length
            return :cancel if x.to_i >= start + SAVE_LABEL.length + 1 && x.to_i < start + action_width
            return :inert
          end
          return :inert if snap.fetch("discard_confirm", false) || snap.fetch("editor", nil).is_a?(Hash)

          if geometry.fetch(:wide) && inside_content?(x, y, geometry.fetch(:rail))
            index = y.to_i - geometry.dig(:rail, :y) - 1
            return [:category, index] if index >= 0 && index < Array(snap.fetch("categories", [])).length
          end
          detail_bounds = geometry.fetch(:detail)
          return :inert unless inside_content?(x, y, detail_bounds)

          detail_view = detail(state, width: [detail_bounds.fetch(:width) - 4, 8].max, height: [detail_bounds.fetch(:height) - 2, 1].max)
          row_offset = y.to_i - detail_bounds.fetch(:y) - 1
          return :inert if row_offset.negative? || row_offset >= detail_view.fetch(:visible_count)

          index = detail_view.fetch(:window_start) + row_offset
          row = Array(snap.fetch("rows", []))[index]
          return :inert unless row

          toggle = row.fetch("editor", nil) == "checkbox" && x.to_i <= detail_bounds.fetch(:x) + 4
          [toggle ? :toggle : :row, index]
        end

        private

        def row_line(row, selected:, width:)
          marker = selected ? "›" : " "
          dirty = row.fetch("dirty", false) ? "•" : " "
          editor = row.fetch("editor", nil)
          value = row.fetch("display_value", "").to_s
          value = row.fetch("value", false) == true ? "[x]" : "[ ]" if editor == "checkbox"
          source = row.fetch("source", "default").to_s
          restart = row.fetch("apply_mode", nil) == "restart" ? " · restart" : ""
          label = row.fetch("label", row.fetch("id", "setting")).to_s
          label = label[0, 18] + "…" if compact?(width) && label.length > 19
          available = [width.to_i - marker.length - dirty.length - label.length - 8, 4].max
          value = value.length > available ? "…#{value[-(available - 1), available - 1]}" : value
          style = selected ? Style::AGENT_TREE_SELECTED : Style::TEXT
          secondary = selected ? Style::AGENT_TREE_SELECTED_DIM : Style::MUTED
          segments = [["#{marker}#{dirty} #{label}", style], ["  #{value}", secondary]]
          unless compact?(width)
            badge = "  #{source}#{restart}"
            segments << [badge, selected ? Style::AGENT_TREE_SELECTED_DIM : Style::DIM]
          end
          segments
        end

        def editor_detail(snap, width:, height:)
          editor = snap.fetch("editor")
          row = editor.fetch("row", {}) || {}
          buffer = editor.fetch("buffer", "").to_s
          lines = [
            [["Edit #{row.fetch("label", row.fetch("id", "setting"))}", Style::PANEL_TITLE]],
            [[row.fetch("description", ""), Style::MUTED]],
            [["", Style::DIM]]
          ]
          wrapped = wrap(buffer.empty? ? " " : buffer, [width.to_i - 2, 8].max)
          lines.concat(wrapped.first([height.to_i - 5, 1].max).map { |line| [[line, Style::SELECTION]] })
          error = row.fetch("error", nil).to_s
          lines << [["! #{error}", Style::ERROR]] unless error.empty?
          { lines: lines.first([height.to_i, 1].max), window_start: 0, visible_count: 0, counter: "text editor", selected_row: row }
        end

        def confirmation_detail(_snap, width:, height:)
          lines = [
            [["Discard unsaved changes?", Style::ERROR]],
            [["Nothing has been written. The original theme will be restored.", Style::MUTED]],
            [["", Style::DIM]],
            [["Enter", Style::ACCENT_BOLD], [" discard changes", Style::TEXT]],
            [["Esc", Style::ACCENT_BOLD], [" keep editing", Style::TEXT]]
          ]
          { lines: lines.first([height.to_i, 1].max), window_start: 0, visible_count: 0, counter: "confirmation", selected_row: nil }
        end

        def window_start(count, selected, capacity)
          return 0 if count <= capacity

          half = capacity / 2
          [[selected - half, 0].max, count - capacity].min
        end

        def wrap(text, width)
          text.to_s.lines(chomp: true).flat_map do |line|
            line.empty? ? [""] : line.scan(/.{1,#{[width.to_i, 1].max}}/)
          end
        end

        def inside?(x, y, bounds)
          x.to_i >= bounds.fetch(:x) && x.to_i < bounds.fetch(:x) + bounds.fetch(:width) &&
            y.to_i >= bounds.fetch(:y) && y.to_i < bounds.fetch(:y) + bounds.fetch(:height)
        end

        def inside_content?(x, y, bounds)
          x.to_i >= bounds.fetch(:x) + 2 && x.to_i < bounds.fetch(:x) + bounds.fetch(:width) - 2 &&
            y.to_i >= bounds.fetch(:y) + 1 && y.to_i < bounds.fetch(:y) + bounds.fetch(:height) - 1
        end
      end
    end
  end
end
