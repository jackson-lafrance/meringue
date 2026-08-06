# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      # The full-screen first-run setup screen.
      #
      # Setup used to render in the shared popup slot over the dashboard, which
      # made it compete with the logs pane for rows and made a click anywhere on
      # the screen meaningful. It now owns the terminal while it runs: the
      # dashboard is not drawn at all, the flow is driven by keyboard or mouse
      # row selection, and this pane is the only thing on screen.
      #
      # Like every other pane, it is a pure view over the composed state snapshot
      # and produces `[text, style]` segment lines for `Layout` to draw with the
      # existing Canvas primitives. Animation is expressed the same way: every
      # animated value is a pure function of the `elapsed` seconds carried in the
      # snapshot (see `Onboarding::Motion`), so a dropped frame, a resize, or a
      # forced full redraw all recompute the same picture for the same instant,
      # and a terminal that cannot animate simply renders the settled frame.
      class OnboardingPane
        STATE_KEY = "_onboarding"
        Motion = Onboarding::Motion

        # --- snapshot readers -------------------------------------------------

        def active?(state)
          snapshot(state).fetch("active", false) == true
        end

        def snapshot(state)
          value = (state || {}).fetch(STATE_KEY, nil)
          value.is_a?(Hash) ? value : {}
        end

        def step(state)
          snapshot(state).fetch("step", Onboarding::WELCOME).to_s
        end

        def plan(state)
          steps = Array(snapshot(state).fetch("plan", nil))
          steps.empty? ? Onboarding.plan(harness(state)) : steps
        end

        def harness(state)
          snapshot(state).fetch("harness", nil)
        end

        def query(state)
          snapshot(state).fetch("query", "").to_s
        end

        def applied(state)
          value = snapshot(state).fetch("applied", nil)
          value.is_a?(Hash) ? value : {}
        end

        def animated?(state)
          snapshot(state).fetch("animated", false) == true
        end

        def ascii?(state)
          snapshot(state).fetch("ascii", false) == true
        end

        def glyphs(state)
          Onboarding.glyphs(ascii: ascii?(state))
        end

        # Seconds since this step was entered. Every animated value is derived
        # from it, never from a stored frame counter, so nothing can drift.
        def elapsed(state)
          snapshot(state).fetch("elapsed", 0.0).to_f
        end

        # Transient answer to something the flow refused to do, stored as a kind so
        # the wording can be chosen for the width it is drawn at.
        def notice_kind(state)
          snapshot(state).fetch("notice", nil).to_s
        end

        def rows(state)
          Onboarding.rows(
            state,
            step: step(state),
            harness: harness(state),
            query: query(state),
            saved_theme: snapshot(state).fetch("theme", nil)
          )
        end

        # Clamped against the list that exists this frame, so a catalog that
        # arrives mid-step cannot leave the highlight past the end.
        def index(state)
          entries = rows(state)
          return -1 if entries.empty?

          snapshot(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def title(state)
          Onboarding.step_title(
            step(state),
            plan(state),
            harness: Onboarding.harness_for(state, harness(state))
          )
        end

        # Whether this frame still has motion left in it. The app polls it to use
        # a fast refresh interval only while something is moving.
        def animating?(state)
          return false unless animated?(state)

          Motion.animating?(elapsed(state), count: reveal_count(state), animated: true)
        end

        # --- header -----------------------------------------------------------

        def header_segments(state)
          [
            ["meringue", Style::ACCENT_BOLD],
            [" · first-run setup", Style::MUTED]
          ]
        end

        # A rule that sweeps out from the left under the title. It is the cheapest
        # possible transition: one row, one string, no cursor tricks.
        def rule_segments(state, width:)
          total = [width.to_i, 0].max
          return [] if total.zero?

          marks = glyphs(state)
          drawn = Motion.rule_width(total, elapsed(state), animated: animated?(state))
          return [] if drawn.zero?

          segments = []
          body = drawn > 1 ? marks.fetch("rule") * (drawn - 1) : ""
          segments << [body, Style::BORDER] unless body.empty?
          segments << [marks.fetch("rule_head"), Style::ACCENT_BOLD] if drawn < total
          segments << [marks.fetch("rule"), Style::BORDER] if drawn >= total
          segments
        end

        # One chip per choice step, so the flow's shape and how far it has come are
        # both visible: `✓ harness pi   ▸ model   · thinking   · theme`. A rail that
        # would not fit drops the applied values before it lets a step name be cut
        # in half, and is truncated only as a last resort.
        def rail_segments(state, width:)
          marks = glyphs(state)
          entries = Onboarding.rail_entries(steps: plan(state), step: step(state), applied: applied(state))
          [true, false].each do |values|
            segments = rail_line(entries, marks, values: values)
            return segments if segment_width(segments) <= width.to_i
          end
          clip(rail_line(entries, marks, values: false), width)
        end

        # Bar plus counter. The filled portion eases toward the step it belongs to
        # from wherever the previous step left it, so advancing reads as movement
        # rather than a jump, and going back animates in reverse.
        def progress_segments(state, width:)
          width = [width.to_i, 0].max
          return [] if width < 12

          marks = glyphs(state)
          label = progress_label(state)
          label_width = [label.length + 2, width - 8].min
          bar_width = [width - label_width - 5, 4].max
          fraction = progress_fraction(state)
          filled = (bar_width * fraction).round.clamp(0, bar_width)
          [
            [label.ljust(label_width), Style::MUTED],
            [marks.fetch("bar_filled") * filled, Style::ACCENT_BOLD],
            [marks.fetch("bar_empty") * (bar_width - filled), Style::DIM],
            ["  #{(fraction * 100).round}%", Style::DIM]
          ]
        end

        def progress_fraction(state)
          target = Onboarding.step_fraction(step(state), plan(state))
          from = snapshot(state).fetch("progress_from", target).to_f
          Motion.eased(from, target, elapsed(state), animated: animated?(state)).clamp(0.0, 1.0)
        end

        def progress_label(state)
          steps = plan(state)
          count = Onboarding.choice_steps(steps).length
          number = Onboarding.step_number(step(state), steps)
          return "welcome" unless number

          "step #{number} of #{count}"
        end

        # --- the card ---------------------------------------------------------

        # Everything inside the box, plus which slice of a long list is showing so
        # the caption can say so. One computation, so the caption can never
        # disagree with the rows that were drawn.
        def card(state, width:, height:)
          width = [width.to_i, 8].max
          capacity = [height.to_i, 1].max
          entries = rows(state)
          prose = prose_entries(state, width: width, height: capacity)
          prose, row_capacity = budget(prose, entries.length, capacity)
          window_start = Onboarding.window_start(entries.length, index(state), limit: row_capacity)
          visible = entries.drop(window_start).first(row_capacity)
          {
            lines: card_lines(state, prose: prose, visible: visible, window_start: window_start, width: width).first(capacity),
            row_start: prose.length,
            window: { "start" => window_start, "finish" => window_start + visible.length, "count" => entries.length }
          }
        end

        def card_lines(state, prose:, visible:, window_start:, width:)
          marks = glyphs(state)
          animated = animated?(state)
          seconds = elapsed(state)
          total = prose.length + visible.length
          selected = index(state)
          pulse = Motion.pulse?(seconds, animated: animated)

          lines = prose.each_with_index.map do |(text, style), position|
            phase = Motion.row_phase(position, seconds, count: total, animated: animated)
            prose_line(text, style, phase)
          end
          lines + visible.each_with_index.map do |row, position|
            phase = Motion.row_phase(prose.length + position, seconds, count: total, animated: animated)
            row_line(
              row,
              selected: window_start + position == selected,
              phase: phase,
              marks: marks,
              pulse: pulse,
              width: width
            )
          end
        end

        # Prose above the rows: the banner and pitch on the welcome screen, the
        # step's own explanation elsewhere, plus whatever the model step has to say
        # about a catalog it cannot list.
        def prose_entries(state, width:, height: Onboarding::MAX_VISIBLE_ROWS)
          current_step = step(state)
          entries = []
          if current_step == Onboarding::WELCOME && banner?(state, width: width, height: height)
            Onboarding.banner_lines(ascii: ascii?(state)).each { |line| entries << [line, Style::ACCENT_BOLD] }
            entries << ["", Style::MUTED]
          end
          refresh = refresh_segment(state)
          # Wrapped two columns narrow so the reveal's slide-in has somewhere to
          # slide from without a line being clipped mid-animation.
          Onboarding.note_lines(
            state,
            step: current_step,
            steps: plan(state),
            harness: harness(state),
            query: query(state),
            width: width - Motion.indent_for(Motion::ENTERING)
          ).each { |line| entries << [line, Style::MUTED] }
          entries << refresh if refresh
          entries << ["", Style::MUTED] unless entries.empty? || rows(state).empty?
          entries
        end

        # The wordmark is the first thing to go: on a short card the pitch that
        # explains the product is worth more than the logo above it.
        def banner?(state, width:, height:)
          return false unless Onboarding.banner_width(ascii: ascii?(state)) <= width.to_i

          height.to_i >= Onboarding.banner_lines(ascii: ascii?(state)).length + 6
        end

        # The spinner is only honest while the catalog can still change: it stops
        # as soon as the cached snapshot the step reads is a different one, and it
        # gives up after a bounded wait instead of spinning forever.
        def refresh_segment(state)
          refresh = snapshot(state).fetch("refresh", nil)
          return nil unless refresh.is_a?(Hash)
          return nil unless step(state) == Onboarding::MODEL

          seconds = refresh.fetch("elapsed", 0.0).to_f
          return nil if seconds > Onboarding::REFRESH_SPINNER_SECONDS

          name = Onboarding.harness_for(state, harness(state))
          return nil unless refresh.fetch("signature", nil).to_s == Onboarding.catalog_signature(state, harness: name)

          frame = Motion.spinner_frame(glyphs(state).fetch("spinner"), seconds, animated: animated?(state))
          ["#{frame} asking #{name} for its model list…", Style::ACCENT]
        end

        # --- caption and hints -------------------------------------------------

        # Directly under the box: where the flow is, what is filtered, and every
        # key that works here. Setup is met once, so it always states its keys
        # instead of assuming any of them are known yet.
        #
        # A narrow terminal drops information in a fixed order rather than letting
        # the line be clipped: the list window first, then the counter, then the
        # optional keys. `Esc` is in every variant, because the exit key is the one
        # that must never be the thing that got cut off.
        def caption_segments(state, window: nil, width: nil)
          variants = caption_variants(state, window)
          limit = width.to_i
          return variants.last if limit <= 0

          variants.find { |segments| segment_width(segments) <= limit } || variants.last
        end

        def caption_variants(state, window)
          current_step = step(state)
          counter = [caption_counter(state), Style::MUTED]
          list = window_label(window)
          list = list ? [list, Style::MUTED] : nil
          filter = query(state)
          filter = filter.empty? ? nil : ["filter: #{filter}", Style::TEXT]
          full = [key_hints(current_step), Style::DIM]
          short = [short_key_hints(current_step), Style::DIM]
          minimal = [minimum_key_hints(current_step), Style::DIM]
          [
            [counter, list, filter, full],
            [counter, filter, full],
            [counter, filter, short],
            [filter, short],
            [minimal]
          ].map { |parts| join_caption(parts.compact) }
        end

        def join_caption(parts)
          parts.each_with_index.flat_map do |part, position|
            position.zero? ? [part] : [["  ·  ", Style::DIM], part]
          end
        end

        def caption_counter(state)
          steps = plan(state)
          count = Onboarding.choice_steps(steps).length
          number = Onboarding.step_number(step(state), steps)
          number ? "step #{number} of #{count}" : "#{count} steps"
        end

        def window_label(window)
          return nil unless window.is_a?(Hash)

          count = window.fetch("count", 0).to_i
          start = window.fetch("start", 0).to_i
          finish = window.fetch("finish", 0).to_i
          return nil if count.zero? || finish - start >= count

          "#{start + 1}–#{finish} of #{count}"
        end

        # Short enough to survive a narrow terminal without losing the exit key:
        # Esc is always last, and it is the one that must never be clipped.
        def key_hints(step)
          return "Enter/click begins · Esc skips setup (/setup reopens it)" if step.to_s == Onboarding::WELCOME

          hints = ["↑↓ move", "click row", "Enter applies", "← back", "Esc skip"]
          hints.concat(["type to filter", "Ctrl-R refresh"]) if step.to_s == Onboarding::MODEL
          hints.join(" · ")
        end

        def short_key_hints(step)
          return "Enter/click begins · Esc skips" if step.to_s == Onboarding::WELCOME

          "↑↓ move · click/Enter applies · Esc skip"
        end

        def minimum_key_hints(step)
          step.to_s == Onboarding::WELCOME ? "Enter/click · Esc" : "↑↓ · click/Enter · Esc"
        end

        # Bottom line of the screen. A stray click is answered here rather than by
        # advancing the flow, which is the whole point: only option rows are
        # clickable, so the mouse cannot skip setup from empty space.
        def hint_segments(state, width: nil)
          limit = width.to_i
          kind = notice_kind(state)
          return [[Onboarding.notice_text(kind, width: limit), Style::WARNING]] unless kind.empty?

          return [["click rows or use keys", Style::MUTED]] if limit.positive? && limit < 52

          [
            ["click rows or use keys", Style::MUTED],
            [" · empty-space clicks cannot skip setup", Style::DIM]
          ]
        end

        # Dropped entirely rather than clipped when there is not room for all of it.
        def right_hint_segments(_state, width: nil)
          text = "Ctrl-C quits · /setup reopens"
          return [] if width.to_i < text.length

          [[text, Style::DIM]]
        end

        # --- helpers ----------------------------------------------------------

        # How many lines take part in the staggered reveal, used to decide whether
        # this frame still has motion in it.
        def reveal_count(state)
          entries = rows(state)
          prose = prose_entries(state, width: Onboarding::MAX_CARD_WIDTH - 4)
          prose.length + [entries.length, Onboarding::MAX_VISIBLE_ROWS].min
        end

        def segment_width(segments)
          Array(segments).sum { |text, _style| text.to_s.length }
        end

        private

        # Rows own the card: prose is trimmed from the end before a choice list
        # loses rows, because a step the user cannot answer is worse than a step
        # that explains itself less.
        def budget(prose, row_count, capacity)
          return [prose.first(capacity), 0] if row_count.zero?

          minimum = [row_count, 3, capacity].min
          prose = prose.first([capacity - minimum, 0].max)
          row_capacity = [[capacity - prose.length, 1].max, Onboarding::MAX_VISIBLE_ROWS, row_count].min
          [prose, row_capacity]
        end

        def prose_line(text, style, phase)
          return [["", Style::DIM]] if phase == Motion::HIDDEN

          indent = " " * Motion.indent_for(phase)
          [["#{indent}#{text}", phase == Motion::ENTERING ? Style::DIM : style]]
        end

        def row_line(row, selected:, phase:, marks:, pulse:, width:)
          return [["", Style::DIM]] if phase == Motion::HIDDEN

          indent = " " * Motion.indent_for(phase)
          label = row.fetch("label").to_s
          detail = row.fetch("detail", "").to_s
          return selected_row_line(indent, label, detail, marks, pulse, width) if selected

          entering = phase == Motion::ENTERING
          [
            ["#{indent}#{" " * marks.fetch("marker").length} ", Style::DIM],
            [label, entering ? Style::DIM : Style::TEXT],
            detail.empty? ? nil : ["  #{detail}", entering ? Style::DIM : Style::MUTED]
          ].compact
        end

        # The highlighted row carries the AgentTree's selection palette and the
        # marker, so focus survives both a colorless terminal and a theme where
        # the accent is subtle. The marker breathes between two glyphs instead of
        # blinking.
        def selected_row_line(indent, label, detail, marks, pulse, width)
          marker = pulse ? marks.fetch("marker_pulse") : marks.fetch("marker")
          segments = [
            ["#{indent}#{marker} ", Style::AGENT_TREE_SELECTED_STATUS],
            [label, Style::AGENT_TREE_SELECTED],
            detail.empty? ? nil : ["  #{detail}", Style::AGENT_TREE_SELECTED_DIM]
          ].compact
          pad(segments, width, Style::AGENT_TREE_SELECTED_DIM)
        end

        def pad(segments, width, style)
          length = segments.sum { |text, _style| text.to_s.length }
          return segments if length >= width.to_i

          segments + [[" " * (width.to_i - length), style]]
        end

        def rail_line(entries, marks, values:)
          entries.each_with_index.flat_map do |entry, position|
            chip = rail_chip(entry, marks, values: values)
            position.zero? ? chip : [["   ", Style::DIM]] + chip
          end
        end

        def clip(segments, width)
          remaining = [width.to_i, 0].max
          segments.each_with_object([]) do |(text, style), clipped|
            next if remaining <= 0

            visible = text.to_s[0, remaining].to_s
            clipped << [visible, style]
            remaining -= visible.length
          end
        end

        def rail_chip(entry, marks, values: true)
          case entry.fetch("state")
          when "done"
            value = values ? entry.fetch("value", "").to_s : ""
            [
              ["#{marks.fetch("done")} ", Style::SUCCESS],
              [entry.fetch("step"), Style::MUTED],
              value.empty? ? nil : [" #{value}", Style::SUCCESS]
            ].compact
          when "current"
            [
              ["#{marks.fetch("current")} ", Style::ACCENT_BOLD],
              [entry.fetch("step"), Style::ACCENT_BOLD]
            ]
          else
            [
              ["#{marks.fetch("pending")} ", Style::DIM],
              [entry.fetch("step"), Style::DIM]
            ]
          end
        end
      end
    end
  end
end
