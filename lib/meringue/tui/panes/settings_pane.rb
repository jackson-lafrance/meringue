# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class SettingsPane
        STATE_KEY = Settings::STATE_KEY
        SAVE_LABEL = "[ Save ]"
        NEXT_LABEL = "[ Next ]"
        BEGIN_LABEL = "[ Begin ]"
        FINISH_LABEL = "[ Complete ]"
        CANCEL_LABEL = "[ Cancel ]"
        HELP_TAGLINE = "Not sure what to change? Ask your agent for help."
        COMPACT_HELP_TAGLINE = "Need help? Ask your agent."
        INLINE_GUIDANCE_ID = "experiments.worker_spawning_guidance_prompt"
        SETUP_HEADINGS = {
          Settings::SetupFlow::WELCOME => "Welcome to Meringue",
          Settings::SetupFlow::HARNESS => "Pick the agent that does the work",
          Settings::SetupFlow::PROJECT => "Point Meringue at a repository",
          Settings::SetupFlow::THEME => "Make the workspace yours",
          Settings::SetupFlow::STATUS_BAR => "Your bottom bar",
          Settings::SetupFlow::EXPERIMENTS => "Meringue Xtras",
          Settings::SetupFlow::DONE => "You're ready"
        }.freeze
        SETUP_INTROS = {
          Settings::SetupFlow::WELCOME => "About a minute: one harness, one repository, one look.",
          Settings::SetupFlow::HARNESS => "Meringue drives a coding agent you already have. It never installs one for you.",
          Settings::SetupFlow::PROJECT => "Projects are the boards your issues and workers live on.",
          Settings::SetupFlow::THEME => "Previewed live. Nothing is written until you finish.",
          Settings::SetupFlow::STATUS_BAR => "This is the live bar. The default is ready to use.",
          Settings::SetupFlow::EXPERIMENTS => "All optional, all off. Turn any of them on now or from /config later.",
          Settings::SetupFlow::DONE => "Everything below is saved when you finish."
        }.freeze
        # The Welcome card used to be two lines of copy inside eighteen blank
        # rows, and two steps later it asked the reader to "choose how heads
        # think". Three nouns carry the whole product; this is where they get
        # introduced, in the space that was already there.
        WELCOME_BODY = [
          ["Meringue runs many coding agents at once, in one window.", :text],
          ["", :blank],
          ["  You describe a goal", :text],
          ["    a head reads the repository and decides what should happen", :muted],
          ["  The head opens an issue", :text],
          ["    workers do the work, each in its own git worktree and branch", :muted],
          ["  You watch the tree", :text],
          ["    and jump into an agent only when you actually want to", :muted],
          ["", :blank],
          ["Esc skips setup and /setup reopens it. To look around a populated", :dim],
          ["dashboard first, quit and run: meringue demo", :dim]
        ].freeze

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
          return setup_geometry(width: width, height: height) if snapshot(state).fetch("mode", "settings") == "setup"

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
          setup = snap.fetch("mode", "settings") == "setup"
          title = setup ? "meringue · setup" : "meringue · settings"
          if setup && width.to_i >= Settings::COMPACT_WIDTH
            title = "#{title}  #{snap.fetch("setup_step", 1)}/#{snap.fetch("setup_step_count", 1)}"
          end
          segments = [[title, Style::TITLE]]
          unless setup
            helper = if width.to_i >= Settings::WIDE_WIDTH
                       HELP_TAGLINE
                     elsif width.to_i >= Settings::COMPACT_WIDTH
                       COMPACT_HELP_TAGLINE
                     end
            segments << ["  · #{helper}", Style::MUTED] if helper
          end
          segments << ["  • unsaved", Style::WARNING] if snap.fetch("dirty", false)
          segments << ["  • saving…", Style::ACCENT] if snap.fetch("saving", false)
          segments
        end

        def setup_geometry(width:, height:)
          available_width = [width.to_i - 2, 1].max
          available_height = [height.to_i - 1, 1].max
          card_width = [[width.to_i - 8, 56].max, 76].min
          card_width = [card_width, available_width].min
          card_height = [[available_height, 10].max, 26].min
          card_height = [card_height, available_height].min
          card = {
            x: [(width.to_i - card_width) / 2, 0].max,
            y: [(available_height - card_height) / 2, 0].max,
            width: card_width,
            height: card_height
          }
          {
            too_small: false,
            setup: true,
            wide: width.to_i >= Settings::WIDE_WIDTH,
            header_y: 0,
            footer_y: height.to_i - 1,
            body_y: card.fetch(:y),
            body_height: card.fetch(:height),
            action_y: card.fetch(:y) + card.fetch(:height) - 2,
            card: card,
            detail: card
          }
        end

        def setup_view(state, width:, height:)
          snap = snapshot(state)
          geometry = setup_geometry(width: width, height: height)
          card = geometry.fetch(:card)
          content_width = [card.fetch(:width) - 4, 1].max
          card_content_height = [card.fetch(:height) - 2, 1].max
          detail = if snap.fetch("discard_confirm", false) || modal_editor?(snap) || snap.fetch("picker", nil).is_a?(Hash)
                     detail(state, width: content_width, height: card_content_height)
                   end
          return setup_modal_view(snap, detail, geometry) if detail

          if snap.fetch("category", "") == "Status bar" && snap.fetch("status_bar_composer", nil).is_a?(Hash)
            composer_y = card.fetch(:y) + 5
            return {
              geometry: geometry,
              card_title: setup_card_title(snap),
              heading: setup_heading(snap),
              progress: setup_progress(snap, width: content_width),
              content_x: card.fetch(:x) + 2,
              content_y: composer_y,
              content_width: content_width,
              lines: [],
              row_y: nil,
              window_start: 0,
              visible_count: 0,
              selected_row: nil,
              counter: "",
              modal: false,
              composer: snap.fetch("status_bar_composer"),
              composer_bounds: {
                x: card.fetch(:x) + 2,
                y: composer_y,
                width: content_width,
                height: [geometry.fetch(:action_y) - composer_y, 1].max
              }
            }
          end

          rows = Array(snap.fetch("rows", []))
          selected = snap.fetch("row_index", 0).to_i.clamp(0, [rows.length - 1, 0].max)
          editing_inline = inline_guidance_editor_active?(snap)
          on_action = snap.fetch("footer_focus", false)
          described = on_action ? nil : rows[selected]
          preamble = editing_inline ? [] : setup_preamble(snap, described, width: content_width)
          content_y = card.fetch(:y) + 6
          action_y = geometry.fetch(:action_y)
          content_limit = [action_y - content_y, 0].max
          row_y = content_y + preamble.length
          inline_height = inline_guidance_editor?(snap) ? [content_limit - preamble.length - [rows.length, 1].max, 3].max : 0
          capacity = [action_y - row_y - inline_height, 1].max
          start = window_start(rows.length, selected, capacity)
          visible = rows.drop(start).first(capacity)
          # Focus is in one place at a time. With the action focused nothing in
          # the list is selected, even though the index is kept so arrowing back
          # up returns to the row it left rather than to the top.
          lines = preamble + visible.map.with_index do |row, offset|
            setup_row_line(row, selected: !on_action && start + offset == selected, width: content_width)
          end
          if inline_guidance_editor?(snap)
            editor_capacity = [content_limit - lines.length, 3].max
            lines.concat(inline_guidance_editor_lines(snap, width: content_width, height: editor_capacity))
          end
          row_error = rows[selected]&.fetch("error", nil).to_s
          lines << [["! #{row_error}", Style::ERROR]] unless row_error.empty?
          global_error = snap.fetch("global_error", nil).to_s
          lines << [["! #{global_error}", Style::ERROR]] unless global_error.empty?
          {
            geometry: geometry,
            card_title: setup_card_title(snap),
            heading: setup_heading(snap),
            progress: setup_progress(snap, width: content_width),
            content_x: card.fetch(:x) + 2,
            content_y: content_y,
            content_width: content_width,
            lines: lines.first(content_limit),
            row_y: row_y,
            window_start: start,
            visible_count: visible.length,
            selected_row: rows[selected],
            counter: setup_counter(rows.length, start, visible.length, snap),
            modal: false
          }
        end

        def setup_animation_marker(state)
          snap = snapshot(state)
          ascii = ascii_glyphs?
          return (ascii ? "*" : "✦") unless snap.fetch("setup_animations", true)

          frames = ascii ? %w[* + . +] : %w[✦ ✧ · ✧]
          frames.fetch(snap.fetch("setup_animation_phase", 0).to_i % frames.length)
        end

        def setup_footer_segments(state, width:)
          snap = snapshot(state)
          return footer_segments(state, width: width) unless snap.fetch("mode", "settings") == "setup"
          if snap.fetch("discard_confirm", false) || snap.fetch("editor", nil).is_a?(Hash)
            return footer_segments(state, width: width)
          end
          if snap.fetch("picker", nil).is_a?(Hash)
            return [["Enter choose", Style::ACCENT_BOLD], [" · Esc close", Style::MUTED]]
          end

          hint = if width.to_i < Settings::COMPACT_WIDTH
                   "Navigate"
                 else
                   "Navigate: Enter or Arrow keys toggle · Tab advances · Backspace returns"
                 end
          [[hint, Style::DIM]]
        end

        def category_lines(state, height:)
          snap = snapshot(state)
          categories = Array(snap.fetch("categories", []))
          selected = snap.fetch("category_index", 0).to_i.clamp(0, [categories.length - 1, 0].max)
          setup = snap.fetch("mode", "settings") == "setup"
          counts = snap.fetch("category_counts", {})
          categories.first([height.to_i, 0].max).map.with_index do |category, index|
            marker = if index == selected
                       "› "
                     elsif setup && index < selected
                       "✓ "
                     else
                       "  "
                     end
            hidden = counts.dig(category, "hidden_advanced").to_i
            suffix = hidden.positive? ? " (#{hidden} advanced hidden)" : ""
            style = index == selected ? Style::ACCENT_BOLD : Style::MUTED
            [["#{marker}#{category}#{suffix}", style]]
          end
        end

        def detail(state, width:, height:)
          snap = snapshot(state)
          return confirmation_detail(snap, width: width, height: height) if snap.fetch("discard_confirm", false)
          return keybinding_capture_detail(snap, width: width, height: height) if snap.fetch("keybinding_capture", nil).is_a?(Hash)
          return editor_detail(snap, width: width, height: height) if modal_editor?(snap)
          return setup_picker_detail(snap, width: width, height: height) if snap.fetch("picker", nil).is_a?(Hash)

          rows = Array(snap.fetch("rows", []))
          selected = snap.fetch("row_index", 0).to_i.clamp(0, [rows.length - 1, 0].max)
          inline_height = inline_guidance_editor?(snap) ? [[height.to_i / 2, 9].min, 4].max : 0
          reserved = 4 + inline_height
          capacity = [[height.to_i - reserved, 1].max, 1].max
          start = window_start(rows.length, selected, capacity)
          visible = rows.drop(start).first(capacity)
          lines = visible.map.with_index do |row, offset|
            row_line(row, selected: start + offset == selected, width: width)
          end
          selected_row = rows[selected]
          lines << [["", Style::DIM]]
          if selected_row && !inline_guidance_editor_active?(snap)
            description = selected_row.fetch("description", "").to_s
            detail_text = wrap(description, [width.to_i - 2, 8].max).first(2)
            lines.concat(detail_text.map { |line| [[line, Style::MUTED]] })
            unless selected_row.fetch("id", nil) == INLINE_GUIDANCE_ID
              lines << [["current: ", Style::DIM], [selected_row.fetch("display_value", "").to_s, Style::TEXT], [" · default: ", Style::DIM], [selected_row.fetch("default_value", "").to_s, Style::MUTED]]
            end
            error = selected_row.fetch("error", nil).to_s
            lines << [["! #{error}", Style::ERROR]] unless error.empty?
          end
          lines.concat(inline_guidance_editor_lines(snap, width: width, height: inline_height)) if inline_height.positive?
          global_error = snap.fetch("global_error", nil).to_s
          lines << [["! #{global_error}", Style::ERROR]] unless global_error.empty?
          visible_settings = snap.fetch("visible_setting_count", rows.length).to_i
          hidden_advanced = snap.fetch("hidden_advanced_count", 0).to_i
          counter = if hidden_advanced.positive?
                      "#{visible_settings} setting#{visible_settings == 1 ? "" : "s"} · #{hidden_advanced} advanced hidden"
                    elsif rows.empty?
                      "No settings in this category"
                    else
                      "#{start + 1}–#{start + visible.length} of #{rows.length} settings"
                    end
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
            if snap.fetch("confirmation", "discard") == "skip"
              return [["Enter skip setup", Style::WARNING], [" · Esc keep setting up", Style::MUTED]]
            end
            return [["Enter discard", Style::ERROR], [" · Esc keep editing", Style::MUTED]]
          end
          if snap.fetch("keybinding_capture", nil).is_a?(Hash)
            return [["Press a key to bind", Style::ACCENT_BOLD], [" · Esc cancel · Backspace/Delete clear", Style::MUTED]]
          end
          if snap.fetch("editor", nil).is_a?(Hash)
            if inline_guidance_editor_active?(snap)
              return [
                ["Enter apply", Style::ACCENT_BOLD],
                [" · Shift-Enter newline · arrows/word keys move · Shift+arrows select · Esc cancel", Style::MUTED]
              ]
            end
            return [["Enter apply field", Style::ACCENT_BOLD], [" · Esc cancel field", Style::MUTED]]
          end

          error_count = snap.fetch("error_count", 0).to_i
          setup = snap.fetch("mode", "settings") == "setup"
          cancel = snap.fetch("setup_auto", false) ? "skip" : "cancel"
          hint = if setup && width.to_i < Settings::WIDE_WIDTH
                   "Esc #{cancel} · Tab next · Shift-Tab back · ↑↓ · ←→ change · Enter edit"
                 elsif setup && width.to_i < 100
                   "Esc #{cancel} · Tab/S-Tab steps · ↑↓ · ←→ · Enter edit"
                 elsif setup
                   "↑↓ · ←→ change · Tab next · S-Tab back · Space · Enter edit · Esc #{cancel}"
                 elsif compact?(width)
                   "Esc cancel · Ctrl-S save · ↑↓ · Enter edit"
                 elsif width.to_i < 100
                   "Esc cancel · Ctrl-S save · Tab category · ↑↓ · Enter edit"
                 else
                   "↑↓ · Tab category · Space toggle · Enter edit · Ctrl-S save · Esc cancel"
                 end
          segments = [[hint, Style::DIM]]
          segments << [" · #{error_count} error#{error_count == 1 ? "" : "s"}", Style::ERROR] if error_count.positive?
          segments
        end

        def action_segments(state)
          snap = snapshot(state)
          return [] if snap.fetch("keybinding_capture", nil).is_a?(Hash)
          return [] if snap.fetch("picker", nil).is_a?(Hash) || snap.fetch("editor", nil).is_a?(Hash)

          save_style = snap.fetch("saving", false) ? Style::DIM : Style::ACCENT_BOLD
          if snap.fetch("mode", "settings") == "setup"
            return setup_action_segments(snap, dim: save_style == Style::DIM)
          end
          [[primary_label(snap), save_style], [" ", Style::DIM], [CANCEL_LABEL, Style::MUTED]]
        end

        # A visible category, row, or footer button. Everything else is inert.
        def hit(state, width:, height:, x:, y:)
          geometry = geometry(state, width: width, height: height)
          return :cancel if geometry.fetch(:too_small) && y.to_i >= height.to_i - 1
          return :inert if geometry.fetch(:too_small)

          snap = snapshot(state)
          return setup_hit(state, snap, geometry, width: width, height: height, x: x, y: y) if geometry.fetch(:setup, false)
          return :inert if snap.fetch("keybinding_capture", nil).is_a?(Hash)

          if y.to_i == geometry.fetch(:footer_y)
            primary = primary_label(snap)
            action_width = primary.length + 1 + CANCEL_LABEL.length
            start = width.to_i - action_width - 1
            return :save if x.to_i >= start && x.to_i < start + primary.length
            return :cancel if x.to_i >= start + primary.length + 1 && x.to_i < start + action_width
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

        def setup_hit(state, snap, geometry, width:, height:, x:, y:)
          if snap.fetch("picker", nil).is_a?(Hash)
            return setup_picker_hit(snap, geometry, x: x, y: y)
          end
          return :inert if snap.fetch("discard_confirm", false) || snap.fetch("editor", nil).is_a?(Hash)

          if y.to_i == geometry.fetch(:action_y)
            actions = action_segments(state)
            action_width = actions.sum { |text, _style| text.to_s.length }
            card = geometry.fetch(:card)
            start = card.fetch(:x) + [(card.fetch(:width) - action_width) / 2, 1].max
            return :next if x.to_i >= start && x.to_i < start + action_width
            return :inert
          end

          card = geometry.fetch(:card)
          return :inert unless x.to_i >= card.fetch(:x) + 1 && x.to_i < card.fetch(:x) + card.fetch(:width) - 1 &&
                               y.to_i >= card.fetch(:y) + 1 && y.to_i < card.fetch(:y) + card.fetch(:height) - 1

          view = setup_view(state, width: width, height: height)
          row_y = view.fetch(:row_y)
          visible_count = view.fetch(:visible_count).to_i
          if row_y && y.to_i >= row_y && y.to_i < row_y + visible_count
            index = view.fetch(:window_start) + y.to_i - row_y
            row = Array(snap.fetch("rows", []))[index]
            return :inert unless row

            toggle = row.fetch("editor", nil) == "checkbox" && x.to_i <= card.fetch(:x) + 6
            return [toggle ? :toggle : :row, index]
          end

          :scroll
        end

        private

        def setup_modal_view(snap, detail, geometry)
          card = geometry.fetch(:card)
          content_width = [card.fetch(:width) - 4, 1].max
          content_height = [card.fetch(:height) - 2, 1].max
          {
            geometry: geometry,
            card_title: setup_card_title(snap),
            heading: setup_heading(snap),
            progress: setup_progress(snap, width: content_width),
            content_x: card.fetch(:x) + 2,
            content_y: card.fetch(:y) + 4,
            content_width: content_width,
            lines: Array(detail.fetch(:lines, [])).first(content_height),
            row_y: nil,
            window_start: 0,
            visible_count: 0,
            selected_row: detail.fetch(:selected_row, nil),
            counter: detail.fetch(:counter, ""),
            modal: true
          }
        end

        def setup_card_title(_snap)
          "Setup"
        end

        def setup_heading(snap)
          SETUP_HEADINGS.fetch(snap.fetch("category", Settings::SetupFlow::WELCOME), "Setup")
        end

        NARRATIVE_STYLES = {
          text: Style::TEXT,
          muted: Style::MUTED,
          dim: Style::DIM,
          blank: Style::DIM
        }.freeze

        def setup_preamble(snap, selected_row, width:)
          category = snap.fetch("category", Settings::SetupFlow::WELCOME)
          intro = SETUP_INTROS.fetch(category, "Choose a value, then continue when it feels right.")
          return welcome_lines(intro, width: width) if category == Settings::SetupFlow::WELCOME
          return done_lines(snap, intro, width: width) if category == Settings::SetupFlow::DONE
          return status_bar_lines(snap, intro, width: width) if category == Settings::SetupFlow::STATUS_BAR

          description = selected_row ? selected_row.fetch("description", "").to_s : setup_action_description(snap)
          lines = wrap(intro, [width.to_i, 8].max).first(2).map { |line| [[line, Style::MUTED]] }
          lines << [["", Style::DIM]]
          unless description.empty?
            lines << [[wrap(description, [width.to_i, 8].max).first.to_s, Style::DIM]]
            lines << [["", Style::DIM]]
          end
          lines
        end

        # The slot that describes the selected row describes the action once the
        # action is what has focus: a row nobody selected should not be the thing
        # explaining itself. It stays filled rather than collapsing so arrowing
        # onto the action does not reflow the card underneath the cursor.
        def setup_action_description(snap)
          steps = Settings::SetupFlow.steps
          index = steps.index(snap.fetch("category", ""))
          destination = index && steps[index + 1]
          destination ? "Next: #{destination}." : ""
        end

        # The default layout, spelled out. The drag surface is one keystroke away
        # and stays out of the way of someone who has never seen the bar in use.
        def status_bar_lines(snap, intro, width:)
          lines = [[[intro, Style::MUTED]], [["", Style::DIM]]]
          Array(snap.fetch("setup_status_bar_preview", [])).each do |line|
            wrap(line.to_s, [width.to_i, 8].max).each { |wrapped| lines << [[wrapped, Style::TEXT]] }
          end
          lines << [["", Style::DIM]]
          lines
        end

        def welcome_lines(intro, width:)
          lines = [[[intro, Style::MUTED]], [["", Style::DIM]]]
          WELCOME_BODY.each do |text, kind|
            style = NARRATIVE_STYLES.fetch(kind, Style::TEXT)
            if text.empty?
              lines << [["", style]]
              next
            end
            indented_wrap(text, width).each { |line| lines << [[line, style]] }
          end
          lines
        end

        # `wrap` splits on whitespace, which is right for a paragraph and wrong
        # for a line whose leading spaces are the indentation carrying the
        # structure. Wrap the text, then put the indent back on every line it
        # produced.
        def indented_wrap(text, width)
          indent = text.to_s[/\A */].to_s
          body = text.to_s.lstrip
          limit = [width.to_i - indent.length, 8].max
          wrap(body, limit).map { |line| "#{indent}#{line}" }
        end

        # The last card states what finishing will actually do, so "Complete" is
        # a decision the reader can check rather than a button they hope about.
        def done_lines(snap, intro, width:)
          lines = [[[intro, Style::MUTED]], [["", Style::DIM]]]
          Array(snap.fetch("setup_summary", [])).each do |entry|
            label = entry.fetch("label", "").to_s
            value = entry.fetch("value", "").to_s
            next if label.empty?

            wrap("#{label}: #{value}", [width.to_i, 8].max).each_with_index do |line, index|
              lines << [[line, index.zero? ? Style::TEXT : Style::MUTED]]
            end
          end
          lines << [["", Style::DIM]]
          wrap("Then describe a goal in plain English — Meringue creates the issue and starts the worker.", [width.to_i, 8].max).each do |line|
            lines << [[line, Style::DIM]]
          end
          lines
        end

        def setup_progress(snap, width:)
          steps = Array(snap.fetch("categories", []))
          selected = snap.fetch("category_index", 0).to_i
          {
            caption: [["Step #{snap.fetch("setup_step", selected + 1)} of #{snap.fetch("setup_step_count", steps.length)}", Style::ACCENT_BOLD]],
            bar: []
          }
        end

        def setup_row_line(row, selected:, width:)
          ascii = ascii_glyphs?
          marker = selected ? (ascii ? ">" : "›") : " "
          dirty = row.fetch("dirty", false) ? (ascii ? "*" : "•") : " "
          editor = row.fetch("editor", nil)
          value = row.fetch("display_value", "").to_s
          value = row.fetch("value", false) == true ? "[x]" : "[ ]" if editor == "checkbox"
          value = "Enter" if editor == "action" && value.empty?
          label = row.fetch("label", row.fetch("id", "setting")).to_s
          hint = selected ? setup_control_hint(row) : ""
          available = [width.to_i - marker.length - dirty.length - label.length - hint.length - 6, 4].max
          value = value.length > available ? "…#{value[-(available - 1), available - 1]}" : value
          style = selected ? Style::AGENT_TREE_SELECTED : Style::TEXT
          secondary = selected ? Style::AGENT_TREE_SELECTED_DIM : Style::MUTED
          [["#{marker}#{dirty} #{label}", style], ["  #{value}", secondary], [hint, Style::DIM]]
        end

        def setup_control_hint(row)
          case row.fetch("editor", nil)
          when "checkbox" then "  · Enter toggle"
          when "selector", "model" then "  · Enter open picker"
          when "text" then "  · Enter edit"
          when "action" then "  · Enter select"
          else ""
          end
        end

        def setup_counter(total, start, visible, snap)
          return "" if total.zero? || Settings::SetupFlow.narrative?(snap.fetch("category", ""))

          "#{start + 1}–#{start + visible} of #{total}"
        end

        def ascii_glyphs?
          defined?(Harness::Registry) && Harness::Registry.ascii_glyphs?
        end

        # Focus has to be visible on the action the same way it is on a row, or
        # arrowing down to it looks like nothing happened and Enter becomes a
        # guess. Selected reads as `› [ Next ] ‹` in the selection style; the
        # markers carry it when color is off.
        def setup_action_segments(snap, dim: false)
          label = primary_label(snap)
          return [[label, Style::DIM]] if dim
          return [[label, Style::ACCENT_BOLD]] unless snap.fetch("footer_focus", false)

          ascii = ascii_glyphs?
          [["#{ascii ? ">" : "›"} #{label} #{ascii ? "<" : "‹"}", Style::AGENT_TREE_SELECTED]]
        end

        def primary_label(snap)
          return SAVE_LABEL unless snap.fetch("mode", "settings") == "setup"
          return BEGIN_LABEL if snap.fetch("category", "") == Settings::SetupFlow::WELCOME

          snap.fetch("setup_last_step", false) ? FINISH_LABEL : NEXT_LABEL
        end

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

        def keybinding_capture_detail(snap, width:, height:)
          capture = snap.fetch("keybinding_capture")
          row = capture.fetch("row", {}) || {}
          current = row.fetch("display_value", "(unbound)").to_s
          lines = [
            [["Set #{row.fetch("label", row.fetch("id", "keybinding"))}", Style::PANEL_TITLE]],
            [["Press the next keyboard key to replace this binding.", Style::MUTED]],
            [["current: ", Style::DIM], [current, Style::TEXT]],
            [["", Style::DIM]],
            [["Esc", Style::ACCENT_BOLD], [" cancel", Style::TEXT], [" · Backspace/Delete", Style::ACCENT_BOLD], [" clear / unbind", Style::TEXT]]
          ]
          error = capture.fetch("error", nil).to_s
          lines << [["! #{error}", Style::ERROR]] unless error.empty?
          {
            lines: lines.first([height.to_i, 1].max),
            window_start: 0,
            visible_count: 0,
            counter: "key capture",
            selected_row: row
          }
        end

        def setup_picker_detail(snap, width:, height:)
          picker = snap.fetch("picker")
          row = picker.fetch("row", {}) || {}
          options = Array(picker.fetch("options", []))
          selected = picker.fetch("index", 0).to_i.clamp(0, [options.length - 1, 0].max)
          capacity = [[height.to_i - 3, 1].max, 1].max
          start = window_start(options.length, selected, capacity)
          visible = options.drop(start).first(capacity)
          query = picker.fetch("query", "").to_s
          lines = [
            [["Choose #{row.fetch("label", "value")}", Style::PANEL_TITLE]],
            [["↑↓ move", Style::MUTED], [" · type to filter", Style::ACCENT_BOLD], [" · Enter choose", Style::ACCENT_BOLD], [" · Esc close", Style::MUTED]],
            [[query.empty? ? "" : "filter: #{query}", Style::DIM]]
          ]
          visible.each_with_index do |option, offset|
            index = start + offset
            label = option.is_a?(Hash) ? option.fetch("name", option.fetch("reference", "")) : option.to_s
            reference = option.is_a?(Hash) ? option.fetch("reference", label) : label
            marker = index == selected ? "› " : "  "
            lines << [["#{marker}#{label}", index == selected ? Style::AGENT_TREE_SELECTED : Style::TEXT], ["  #{reference}", Style::DIM]]
          end
          lines = [[[(query.empty? ? "No choices are available yet." : "No choices match “#{query}”."), Style::MUTED]]] if options.empty?
          {
            lines: lines.first([height.to_i, 1].max),
            window_start: start,
            visible_count: visible.length,
            counter: options.empty? ? "No choices available" : "#{start + 1}–#{start + visible.length} of #{options.length}",
            selected_row: row
          }
        end

        def modal_editor?(snap)
          editor = snap.fetch("editor", nil)
          editor.is_a?(Hash) && editor.fetch("id", nil) != INLINE_GUIDANCE_ID
        end

        def inline_guidance_editor_active?(snap)
          editor = snap.fetch("editor", nil)
          editor.is_a?(Hash) && editor.fetch("id", nil) == INLINE_GUIDANCE_ID
        end

        def inline_guidance_editor?(snap)
          Array(snap.fetch("rows", [])).any? { |row| row.fetch("id", nil) == INLINE_GUIDANCE_ID }
        end

        def inline_guidance_editor_lines(snap, width:, height:)
          return [] unless inline_guidance_editor?(snap) && height.to_i.positive?

          active = inline_guidance_editor_active?(snap)
          row = Array(snap.fetch("rows", [])).find { |candidate| candidate.fetch("id", nil) == INLINE_GUIDANCE_ID } || {}
          editor = active ? snap.fetch("editor") : {}
          buffer = active ? editor.fetch("buffer", "").to_s : row.fetch("value", "").to_s
          cursor = active ? editor.fetch("cursor", buffer.chars.length).to_i : nil
          selection = active ? editor.fetch("selection", nil) : nil
          title = active ? "Worker selection guidance — editing" : "Worker selection guidance — Enter to edit"
          lines = [[[title, active ? Style::ACCENT_BOLD : Style::PANEL_TITLE]]]
          input_capacity = [height.to_i - 2, 1].max
          input_lines = MultilineInput.lines(
            buffer,
            input_cursor: cursor,
            width: width,
            selection: selection,
            placeholder: "describe how heads should choose worker model and thinking"
          )
          cursor_row = active ? MultilineInput.cursor_row(buffer, cursor, width: width) : 0
          start = window_start(input_lines.length, cursor_row, input_capacity)
          lines.concat(input_lines.drop(start).first(input_capacity))
          error = row.fetch("error", nil).to_s
          lines << [["! #{error}", Style::ERROR]] unless error.empty?
          status = editor.fetch("status", nil).to_s
          lines << [[status, Style::SUCCESS]] unless status.empty?
          lines.first(height.to_i)
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
          counter = if row.fetch("id", nil) == "experiments.worker_spawning_guidance_prompt"
                      "text editor · Tab completes @ models / # thinking levels"
                    else
                      "text editor"
                    end
          { lines: lines.first([height.to_i, 1].max), window_start: 0, visible_count: 0, counter: counter, selected_row: row }
        end

        def confirmation_detail(snap, width:, height:)
          if snap.fetch("confirmation", "discard") == "skip"
            lines = [
              [["Skip first-run setup?", Style::WARNING]],
              [["Your draft will be discarded. Only the skipped marker and explicit experiment defaults will be saved.", Style::MUTED]],
              [["", Style::DIM]],
              [["Enter", Style::ACCENT_BOLD], [" skip setup", Style::TEXT]],
              [["Esc", Style::ACCENT_BOLD], [" keep setting up", Style::TEXT]]
            ]
            return { lines: lines.first([height.to_i, 1].max), window_start: 0, visible_count: 0, counter: "confirmation", selected_row: nil }
          end

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
          limit = [width.to_i, 1].max
          text.to_s.lines(chomp: true).flat_map do |source|
            next [""] if source.empty?

            source.split(/\s+/).each_with_object([+""]) do |word, lines|
              if lines.last.empty?
                lines[-1] = +word
              elsif lines.last.length + word.length + 1 <= limit
                lines.last << " " << word
              else
                lines << +word
              end
            end.flat_map { |line| line.length <= limit ? [line] : line.scan(/.{1,#{limit}}/) }
          end
        end

        def setup_picker_hit(snap, geometry, x:, y:)
          picker = snap.fetch("picker", {})
          options = Array(picker.fetch("options", []))
          card = geometry.fetch(:card)
          content_height = [card.fetch(:height) - 2, 1].max
          capacity = [[content_height - 3, 1].max, 1].max
          selected = picker.fetch("index", 0).to_i.clamp(0, [options.length - 1, 0].max)
          start = window_start(options.length, selected, capacity)
          option_y = card.fetch(:y) + 4 + 3
          offset = y.to_i - option_y
          index = start + offset
          return [:picker, index] if offset >= 0 && offset < [options.length - start, capacity].min

          :inert
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
