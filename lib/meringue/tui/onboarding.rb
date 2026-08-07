# frozen_string_literal: true

module Meringue
  module TUI
    # First-run setup: the read-only view model behind the onboarding flow.
    #
    # A new user used to land on two empty boxes and a prompt, with `/harness`,
    # `/model`, `/thinking`, `/theme` and the AgentTree gestures all
    # undiscoverable. This module describes a short guided flow that leaves them
    # with those four settings chosen and enough of a tutorial to send a real
    # first prompt.
    #
    # Setup takes over the whole terminal while it runs (see
    # Layout#render_onboarding), so it is not a popup competing with the
    # dashboard for rows: it owns the screen, accepts keyboard and mouse row
    # selection, and a stray click cannot skip or dismiss it.
    #
    # It is still a view model in the same shape as `ModelPicker`: it answers
    # from persisted state and the config file only, so building a frame never
    # starts a harness process and never writes anything. Every choice the user
    # makes is applied by the TUI as the ordinary slash command for it
    # (`/harness`, `/model`, `/thinking`, `/theme`), so the kernel stays the only
    # writer of harness state and config.
    module Onboarding
      WELCOME = "welcome"
      HARNESS = "harness"
      MODEL = "model"
      THINKING = "thinking"
      THEME = "theme"
      # Model and thinking defaults are written into `[harness.pi]`, and the other
      # harnesses report both as unsupported, so those two steps only exist when
      # the user is on Pi. The step counter is computed from the plan, never
      # hard-coded, so "2/4" is always true.
      PI_ONLY_STEPS = [MODEL, THINKING].freeze
      # The setup screen is a centered card, not a full-bleed wall of text: past
      # this width long model references still fit while prose stays readable.
      MAX_CARD_WIDTH = 88
      # A browsed list, capped so a 122-model catalog cannot turn the card into a
      # scrolling wall. The caption says where the window sits in the full list.
      MAX_VISIBLE_ROWS = 12
      # Below this the card plus its caption and the exit hint cannot all be
      # drawn, and a modal with no visible box would swallow keys. Setup does not
      # auto-open below it, and closes with `collapsed_message` if the terminal is
      # resized under it while setup is up.
      MIN_TERMINAL_WIDTH = 46
      MIN_TERMINAL_HEIGHT = 12
      # Motion is chrome. Under this size every row is needed for content, so the
      # flow renders its settled frame immediately instead of animating.
      ANIMATION_MIN_WIDTH = 60
      ANIMATION_MIN_HEIGHT = 16
      SENTINEL = "keep"
      # Prose is wrapped by the caller at the card's real content width; this is
      # the fallback for callers that do not know a width yet.
      PROSE_WIDTH = 74
      # How long the "click an option row" answer to a missed click stays up.
      NOTICE_SECONDS = 4.0
      # A refresh spinner is honest only while the catalog can still change. After
      # this the kernel has already logged whatever happened.
      REFRESH_SPINNER_SECONDS = 12.0

      HARNESS_NOTES = {
        "pi" => "live streaming and steering",
        "claude" => "print mode",
        "antigravity" => "print mode"
      }.freeze

      THEME_NOTES = {
        "meringue" => "yellow and white",
        "rose-pine" => "muted rose and pine",
        "tokyonight" => "cool neon blue",
        "gruvbox" => "warm retro",
        "catppuccin" => "soft pastel",
        "kanagawa" => "ink and indigo"
      }.freeze

      # One line per step explaining what the choice actually changes, so the
      # flow teaches instead of just listing values.
      STEP_BLURBS = {
        HARNESS => "Which coding harness runs your agents. Pi streams and can be steered mid-turn.",
        MODEL => "The default model for new Pi sessions. Type to filter, Ctrl-R re-asks the harness.",
        THINKING => "How hard new sessions think before answering. Higher costs more time and tokens.",
        THEME => "Colors for the whole dashboard. Moving the highlight repaints it live."
      }.freeze

      # Glyphs are grouped so the whole screen can fall back together: a terminal
      # that cannot draw a heavy bar cannot draw a spinner either, and a half
      # ASCII screen reads worse than a consistent one.
      GLYPHS = {
        "bar_filled" => "━",
        "bar_empty" => "╌",
        "rule" => "─",
        "rule_head" => "╸",
        "marker" => "▸",
        "marker_pulse" => "▹",
        "done" => "✓",
        "current" => "▸",
        "pending" => "·",
        "spinner" => %w[◐ ◓ ◑ ◒].freeze
      }.freeze

      ASCII_GLYPHS = {
        "bar_filled" => "=",
        "bar_empty" => "-",
        "rule" => "-",
        "rule_head" => ">",
        "marker" => ">",
        "marker_pulse" => "-",
        "done" => "*",
        "current" => ">",
        "pending" => ".",
        "spinner" => ["|", "/", "-", "\\"].freeze
      }.freeze

      # Three rows of box-drawing glyphs, 22 columns wide. It is chrome: the
      # welcome card drops it on short terminals and replaces it with the plain
      # word on terminals that are not drawing UTF-8.
      BANNER = [
        "┏┳┓┏━╸┏━┓╻┏┓╻┏━╸╻ ╻┏━╸",
        "┃┃┃┣╸ ┣┳┛┃┃┗┫┃╺┓┃ ┃┣╸ ",
        "╹ ╹┗━╸╹┗╸╹╹ ╹┗━┛┗━┛┗━╸"
      ].freeze
      BANNER_WIDTH = 22

      # Answers to mouse input that did not hit an option row. Clicking used to
      # advance or dismiss setup from anywhere; now only visible options apply, so
      # missed clicks explain where to click instead of looking frozen.
      NOTICE_MOUSE = "mouse"
      NOTICE_TEXTS = {
        NOTICE_MOUSE => [
          "Click an option row, press Enter to continue, or Esc to skip setup.",
          "Click a row, Enter, or Esc."
        ].freeze
      }.freeze

      # Wording for a notice at the width it will be drawn at, so the message is
      # never the thing that gets clipped.
      def self.notice_text(kind, width: 0)
        variants = NOTICE_TEXTS.fetch(kind.to_s, nil)
        return "" unless variants

        width = width.to_i
        return variants.first if width <= 0

        variants.find { |text| text.length <= width } || variants.last
      end

      # Every animated value below is a pure function of elapsed seconds, which is
      # what makes the flow safe in a shared render loop: frames are never queued
      # or replayed, a slow terminal simply skips intermediate values and still
      # lands on the settled frame, and a resize or a full redraw mid-animation
      # recomputes the same value for the same instant.
      module Motion
        HIDDEN = :hidden
        ENTERING = :entering
        SETTLED = :settled

        # Per-row reveal delay, and the ceiling on the whole reveal: a long model
        # list tightens its stagger instead of taking seconds to appear.
        ROW_STAGGER = 0.045
        ROW_REVEAL_CAP = 0.36
        # How long a row stays dim/indented after it appears.
        ROW_ENTER = 0.10
        RULE_DURATION = 0.30
        PROGRESS_DURATION = 0.40
        # Slow on purpose: the selection caret breathes rather than blinks, so the
        # idle screen costs a few frames a second and never strobes.
        PULSE_PERIOD = 1.2
        SPINNER_PERIOD = 0.4
        # One frame every 50ms while a step animates (20fps), then a slow idle
        # cadence for the caret and transient notices.
        FRAME_INTERVAL = 0.05
        IDLE_INTERVAL = 0.3

        module_function

        def stagger(count)
          count = count.to_i
          return 0.0 if count <= 1

          [ROW_STAGGER, ROW_REVEAL_CAP / (count - 1)].min
        end

        def reveal_duration(count)
          count = count.to_i
          return 0.0 if count <= 0

          (stagger(count) * (count - 1)) + ROW_ENTER
        end

        # :hidden, :entering, or :settled for one row of a staggered reveal.
        def row_phase(index, elapsed, count:, animated: true)
          return SETTLED unless animated

          start = index.to_i * stagger(count)
          elapsed = elapsed.to_f
          return HIDDEN if elapsed < start

          elapsed < start + ROW_ENTER ? ENTERING : SETTLED
        end

        # Rows slide two columns to the left as they land.
        def indent_for(phase)
          phase == ENTERING ? 2 : 0
        end

        # Cubic ease-out, so the progress bar decelerates into its target instead
        # of snapping.
        def eased(from, to, elapsed, duration: PROGRESS_DURATION, animated: true)
          from = from.to_f
          to = to.to_f
          return to unless animated
          return to if duration.to_f <= 0

          progress = (elapsed.to_f / duration.to_f).clamp(0.0, 1.0)
          from + ((to - from) * (1 - ((1 - progress)**3)))
        end

        # Width of the rule that sweeps out under the title.
        def rule_width(total, elapsed, animated: true)
          total = total.to_i
          return total unless animated
          return total if total <= 0

          eased(0.0, total.to_f, elapsed, duration: RULE_DURATION, animated: true).round.clamp(0, total)
        end

        def pulse?(elapsed, animated: true)
          return false unless animated

          ((elapsed.to_f / (PULSE_PERIOD / 2)).floor % 2) == 1
        end

        def spinner_frame(frames, elapsed, animated: true)
          frames = Array(frames)
          return "" if frames.empty?
          return frames.first unless animated

          frames[(elapsed.to_f / SPINNER_PERIOD).floor % frames.length]
        end

        # True while a step still has motion left. The app uses it to pick a fast
        # refresh interval only while something is actually moving.
        def animating?(elapsed, count:, animated: true)
          return false unless animated

          elapsed.to_f < [reveal_duration(count), RULE_DURATION, PROGRESS_DURATION].max
        end
      end

      module_function

      # --- the marker -------------------------------------------------------

      def completed?(config)
        version_for(config) >= Meringue::Config::ONBOARDING_VERSION
      end

      def version_for(config)
        return 0 unless config.respond_to?(:value)

        config.value(Meringue::Config::ONBOARDING_SECTION, "completed_version").to_i
      end

      # --- size and motion capability ---------------------------------------

      # Whether the full-screen flow can be drawn at all at this size.
      def fits?(width:, height:)
        width.to_i >= MIN_TERMINAL_WIDTH && height.to_i >= MIN_TERMINAL_HEIGHT
      end

      def animation_allowed?(width:, height:)
        width.to_i >= ANIMATION_MIN_WIDTH && height.to_i >= ANIMATION_MIN_HEIGHT
      end

      # Motion is opt-out: `MERINGUE_NO_ANIMATION=1` or `animations = false`
      # under `[tui]` renders the settled frame immediately.
      def reduced_motion?(env: ENV, config: nil)
        flag = env.to_h.fetch("MERINGUE_NO_ANIMATION", "").to_s.strip.downcase
        return true if %w[1 true yes on].include?(flag)
        return false unless config.respond_to?(:value)

        config.value("tui", "animations") == false
      end

      # UTF-8 is the default assumption, exactly like the rest of the TUI. The
      # same `MERINGUE_ASCII_GLYPHS` the AgentTree's harness marks already honor
      # switches the whole setup screen to ASCII, and a locale that explicitly
      # says it is not UTF-8 is taken at its word.
      def ascii_only?(env: ENV)
        return true unless env.to_h.fetch("MERINGUE_ASCII_GLYPHS", "").to_s.strip.empty?

        locales = %w[LC_ALL LC_CTYPE LANG].filter_map do |key|
          value = env.to_h.fetch(key, nil).to_s.strip
          value.empty? ? nil : value
        end
        return false if locales.empty?

        locales.none? { |locale| locale.downcase.delete("-").include?("utf8") }
      end

      def glyphs(ascii: false)
        ascii ? ASCII_GLYPHS : GLYPHS
      end

      # --- steps ------------------------------------------------------------

      def harness_for(state, requested = nil)
        ModelPicker.harness_for(state, requested)
      end

      def pi?(harness)
        Meringue::Harness::Registry.public_provider_name(harness) == "pi"
      end

      # The whole flow in order. Theme is the first real choice so the rest of
      # setup renders in the colors the user picked. The plan is still recomputed
      # from the chosen harness, so picking Claude drops the two Pi-only steps
      # instead of showing steps that cannot apply.
      def plan(harness = nil)
        steps = [WELCOME, THEME, HARNESS]
        steps.concat(PI_ONLY_STEPS) if pi?(harness)
        steps
      end

      def choice_steps(steps)
        Array(steps) - [WELCOME]
      end

      def step_number(step, steps)
        index = choice_steps(steps).index(step)
        index ? index + 1 : nil
      end

      def step_title(step, steps, harness: nil)
        return "setup · welcome" if step.to_s == WELCOME

        number = step_number(step, steps)
        label = step.to_s == MODEL ? "model (#{harness_for(nil, harness)})" : step.to_s
        return "setup · #{label}" unless number

        "setup · #{number}/#{choice_steps(steps).length} · #{label}"
      end

      # How far through the choice steps this step is, as a fraction. The welcome
      # screen is 0 and finishing is 1, so the bar is honest at both ends.
      def step_fraction(step, steps)
        count = choice_steps(steps).length
        return 0.0 if count.zero?

        number = step_number(step, steps)
        return 0.0 unless number

        (number - 1).to_f / count
      end

      # --- content ----------------------------------------------------------

      # Prose above the rows. The welcome screen is all prose; every choice step
      # gets one line saying what it changes, and the model step borrows the
      # picker's own explanation when the catalog cannot be listed, so a degraded
      # harness reads as an explanation instead of an empty box.
      def note_lines(state, step:, steps: nil, harness: nil, query: nil, width: PROSE_WIDTH)
        case step.to_s
        when WELCOME
          welcome_lines(steps || plan(harness), width: width)
        when MODEL
          lines = blurb_lines(MODEL, width: width)
          entries = model_entries(state, harness: harness, query: query)
          return lines unless entries.empty?

          lines + wrap(ModelPicker.empty_message(state, harness: harness_for(state, harness), query: query), width)
        else
          blurb_lines(step, width: width)
        end
      end

      def blurb_lines(step, width: PROSE_WIDTH)
        blurb = STEP_BLURBS[step.to_s]
        return [] unless blurb

        wrap(blurb, width)
      end

      def welcome_lines(steps, width: PROSE_WIDTH)
        paragraphs = [
          "Meringue runs many coding agents at once and keeps you in one window.",
          "You type a goal, a head agent routes it, and workers do the work in their own git " \
          "worktrees. The tree on the left is how you watch them.",
          "#{choice_steps(steps).length} quick choices, each already on a sensible default: pick a theme first so the rest of setup uses it, or hold Enter to accept them all."
        ]
        paragraphs.each_with_object([]) do |paragraph, lines|
          lines << "" unless lines.empty?
          lines.concat(wrap(paragraph, width))
        end
      end

      def banner_lines(ascii: false)
        return ["MERINGUE"] if ascii

        BANNER.dup
      end

      def banner_width(ascii: false)
        ascii ? "MERINGUE".length : BANNER_WIDTH
      end

      # Selectable rows for a step. Every row carries the slash command that
      # applies it, so the controller never has to know how a setting is written.
      def rows(state, step:, harness: nil, query: nil, saved_theme: nil)
        case step.to_s
        when WELCOME then welcome_rows
        when HARNESS then harness_rows(state, harness)
        when MODEL then model_rows(state, harness: harness, query: query)
        when THINKING then thinking_rows(state, harness: harness)
        when THEME then theme_rows(saved_theme)
        else []
        end
      end

      def row_at(state, index, step:, harness: nil, query: nil, saved_theme: nil)
        entries = rows(state, step: step, harness: harness, query: query, saved_theme: saved_theme)
        return nil if entries.empty?

        entries[index.to_i.clamp(0, entries.length - 1)]
      end

      # Where the highlight starts on a step: the value that is already in effect,
      # so pressing Enter straight through accepts every current default and
      # changes nothing.
      def default_index(state, step:, harness: nil, query: nil, saved_theme: nil)
        entries = rows(state, step: step, harness: harness, query: query, saved_theme: saved_theme)
        index = entries.index { |row| row.fetch("current", false) }
        index || 0
      end

      # First visible row of a windowed list, keeping the highlight inside it.
      def window_start(count, index, limit:)
        count = count.to_i
        limit = [limit.to_i, 1].max
        return 0 if count <= limit

        index = index.to_i.clamp(0, count - 1)
        start = index - ((limit - 1) / 2)
        start.clamp(0, count - limit)
      end

      def welcome_rows
        [
          {
            "kind" => SENTINEL,
            "value" => "begin",
            "label" => "begin setup",
            "detail" => "choose a theme first",
            "current" => true,
            "command" => nil
          }
        ]
      end

      def harness_rows(state, chosen)
        current = harness_for(state, chosen)
        Meringue::Harness::Registry.provider_choices.map do |choice|
          provider = choice.fetch("provider")
          {
            "kind" => HARNESS,
            "value" => provider,
            "label" => "#{Meringue::Harness::Registry.provider_glyph(provider)} #{provider}",
            "detail" => [
              choice.fetch("label"),
              provider == current ? "current" : nil,
              HARNESS_NOTES[provider]
            ].compact.join(" · "),
            "current" => provider == current,
            "command" => "/harness #{provider}"
          }
        end
      end

      def model_entries(state, harness: nil, query: nil)
        ModelPicker.entries(state, harness: harness_for(state, harness), query: query)
      end

      # The picker's own rows, so this step is the same list `/models` shows.
      # When the catalog is missing, stale-but-empty, or filtered to nothing, the
      # step still offers one row: onboarding must never be a dead end while a
      # background catalog fetch is in flight.
      def model_rows(state, harness: nil, query: nil)
        harness = harness_for(state, harness)
        entries = model_entries(state, harness: harness, query: query)
        return [keep_model_row(state, harness)] if entries.empty?

        entries.map do |entry|
          reference = entry.fetch("reference")
          details = []
          details << "current default" if entry.fetch("current", false)
          details << entry.fetch("name") unless entry.fetch("name", "").to_s.empty?
          levels = Array(entry.fetch("thinking_levels", []))
          details << "thinking: #{levels.join(", ")}" unless levels.empty?
          {
            "kind" => MODEL,
            "value" => reference,
            "label" => reference,
            "detail" => details.join(" · "),
            "current" => entry.fetch("current", false),
            "command" => "/model #{reference}"
          }
        end
      end

      def keep_model_row(state, harness)
        reference = default_model_reference(state, harness)
        {
          "kind" => SENTINEL,
          "value" => reference,
          "label" => "keep the default",
          "detail" => [reference, "Ctrl-R asks #{harness} for its model list"].reject { |part| part.to_s.empty? }.join(" · "),
          "current" => true,
          "command" => nil
        }
      end

      def default_model_reference(state, harness)
        reference = ModelPicker.default_model_reference(state).to_s.strip
        return reference unless reference.empty?
        return Meringue::Harness::Registry::DEFAULT_PI_MODEL if pi?(harness)

        ""
      end

      # Identity of the cached catalog snapshot the model step is reading. The
      # refresh spinner compares it against the snapshot that was on screen when
      # Ctrl-R was pressed, so the spinner stops when a real answer lands instead
      # of running for a fixed guess.
      def catalog_signature(state, harness: nil)
        harness = harness_for(state, harness)
        snapshot = ModelPicker.snapshot_for(state, harness)
        return "none:#{harness}" unless snapshot

        [
          harness,
          snapshot.fetch("availability", ""),
          snapshot.fetch("fetched_at", ""),
          snapshot.fetch("last_attempt_at", ""),
          Array(snapshot.fetch("models", [])).length
        ].join(":")
      end

      # Every level the kernel accepts, labelled by what the catalog knows.
      # Filtering the ladder by the catalog would hide levels the user can really
      # set (see docs/session-settings.md), so support is a label, never a filter.
      def thinking_rows(state, harness: nil)
        harness = harness_for(state, harness)
        parser = Meringue::Input::SlashCommandParser
        reference = parser.thinking_level_model_reference(state, harness)
        supported = parser.normalized_thinking_levels(ModelPicker.catalog(state, harness).thinking_levels_for(reference))
        current = parser.current_default_thinking_level(state, harness)
        parser.ordered_thinking_levels(current).map do |level|
          {
            "kind" => THINKING,
            "value" => level,
            "label" => level,
            "detail" => parser.thinking_level_description(level, reference, supported, current),
            "current" => level == current,
            "command" => "/thinking #{level}"
          }
        end
      end

      def theme_rows(saved_theme = nil)
        saved = (saved_theme || Style.current_colorscheme).to_s
        Style.colorschemes.map do |name|
          {
            "kind" => THEME,
            "value" => name,
            "label" => name,
            "detail" => [name == saved ? "current" : nil, THEME_NOTES[name]].compact.join(" · "),
            "current" => name == saved,
            "command" => "/theme #{name}"
          }
        end
      end

      # --- the step rail ----------------------------------------------------

      # One chip per choice step: done (with the value that was applied), current,
      # or pending. It is the flow's progress made concrete, and it animates for
      # free because a chip changes state the moment a step is applied.
      def rail_entries(steps:, step:, applied: {})
        applied = stringify(applied)
        choices = choice_steps(steps)
        current_index = choices.index(step.to_s)
        choices.each_with_index.map do |name, index|
          state = if current_index.nil?
                    index.zero? ? "current" : "pending"
                  elsif index < current_index
                    "done"
                  elsif index == current_index
                    "current"
                  else
                    "pending"
                  end
          { "step" => name, "state" => state, "value" => applied.fetch(name, nil).to_s }
        end
      end

      # --- the finish card --------------------------------------------------

      # What the user ends up with. `applied` is what this run of the flow just
      # submitted, which is authoritative for a choice the kernel has not finished
      # writing back into state yet; everything else is read from live state and
      # the live theme, so a step the user skipped reports what is really in
      # effect rather than what the flow would have set.
      def settings(state, applied: {}, harness: nil)
        applied = stringify(applied)
        resolved_harness = applied[HARNESS] || harness_for(state, harness)
        {
          HARNESS => resolved_harness,
          MODEL => applied[MODEL] || default_model_reference(state, resolved_harness),
          THINKING => applied[THINKING] || Meringue::Input::SlashCommandParser.current_default_thinking_level(state, resolved_harness),
          THEME => applied[THEME] || Style.current_colorscheme.to_s
        }
      end

      def summary_line(settings)
        parts = ["harness #{settings.fetch(HARNESS)}"]
        if pi?(settings.fetch(HARNESS))
          parts << "model #{settings.fetch(MODEL)}" unless settings.fetch(MODEL).to_s.empty?
          parts << "thinking #{settings.fetch(THINKING)}" unless settings.fetch(THINKING).to_s.empty?
        end
        parts << "theme #{settings.fetch(THEME)}"
        parts.join(" · ")
      end

      # The last onboarding artifact: one card in the logs pane naming what was
      # set and what to do next. The setup screen is gone by then; nothing
      # lingers over the dashboard.
      def completion_card(settings)
        lines = ["✓ Setup complete.", "  #{summary_line(settings)}"]
        unless pi?(settings.fetch(HARNESS))
          lines << "  Model and thinking defaults apply to Pi sessions only today."
        end
        lines.concat(["", "  How Meringue works"])
        lines.concat(tutorial_lines)
        lines.concat(["", "  Try:  add a smoke test for the login page in ~/code/my-app"])
        lines.join("\n")
      end

      def tutorial_lines
        [
          "  · Type what you want in plain English and press Enter. A head agent reads it,",
          "    picks the project and issue, and spawns or prompts a worker for you.",
          "  · The left pane is the AgentTree: projects → issues → workers. Click a row to",
          "    filter the logs to it and aim your next message at it; Esc clears that.",
          "  · Double-click an issue to open its pull request; double-click a worker to open",
          "    its focused workspace: full transcript, a shell in its worktree, and its context.",
          "",
          "  Enter send · Tab focus · / commands · Esc clear · Ctrl-B pull request · /keybind all keys"
        ]
      end

      def skip_card(settings)
        "Setup skipped — run /setup any time.\n  Now: #{summary_line(settings)}"
      end

      def collapsed_message
        "Setup needs a bigger terminal (at least #{MIN_TERMINAL_WIDTH}×#{MIN_TERMINAL_HEIGHT}) — run /setup after resizing."
      end

      def unavailable_message
        "Setup needs a live kernel. Run meringue (not meringue demo) to choose your defaults."
      end

      def wrap(text, width = PROSE_WIDTH)
        width = [width.to_i, 8].max
        words = text.to_s.split(/\s+/).reject(&:empty?)
        return [] if words.empty?

        words.each_with_object([+""]) do |word, lines|
          line = lines.last
          if line.empty?
            line << word
          elsif line.length + 1 + word.length <= width
            line << " " << word
          else
            lines << +word
          end
        end
      end

      def stringify(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, entry), result| result[key.to_s] = entry }
      end
    end
  end
end
