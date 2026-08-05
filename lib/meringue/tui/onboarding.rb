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
    # It is a view model in the same shape as `ModelPicker`: it answers from
    # persisted state and the config file only, so building a frame never starts
    # a harness process and never writes anything. Every choice the user makes is
    # applied by the TUI as the ordinary slash command for it
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
      # A row of prose or a row of choices; the popup slot is the same size as the
      # model picker's so the flow reads as the same product.
      VISIBLE_LIMIT = 10
      # Below this the shared popup slot collapses to nothing (see
      # Layout#popup_metrics), and a modal with no visible box would swallow keys.
      MIN_TERMINAL_HEIGHT = 20
      SENTINEL = "keep"
      # Prose is wrapped here rather than at render time because the popup slot
      # renders pre-built lines. 74 columns is the content width of the box on an
      # 80-column terminal, so an explanation never gets clipped on the narrowest
      # supported size and only leaves slack on wider ones.
      PROSE_WIDTH = 74

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

      module_function

      # --- the marker -------------------------------------------------------

      def completed?(config)
        version_for(config) >= Meringue::Config::ONBOARDING_VERSION
      end

      def version_for(config)
        return 0 unless config.respond_to?(:value)

        config.value(Meringue::Config::ONBOARDING_SECTION, "completed_version").to_i
      end

      # --- steps ------------------------------------------------------------

      def harness_for(state, requested = nil)
        ModelPicker.harness_for(state, requested)
      end

      def pi?(harness)
        Meringue::Harness::Registry.public_provider_name(harness) == "pi"
      end

      # The whole flow in order. Recomputed from the chosen harness, so picking
      # Claude at step 1 drops the two Pi-only steps instead of showing steps that
      # cannot apply.
      def plan(harness = nil)
        steps = [WELCOME, HARNESS]
        steps.concat(PI_ONLY_STEPS) if pi?(harness)
        steps << THEME
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

      # --- content ----------------------------------------------------------

      # Prose above the rows. The welcome screen is all prose; the model step
      # borrows the picker's own explanation when the catalog cannot be listed, so
      # a degraded harness reads as an explanation instead of an empty box.
      def note_lines(state, step:, steps: nil, harness: nil, query: nil)
        case step.to_s
        when WELCOME
          welcome_lines(steps || plan(harness))
        when MODEL
          return [] unless model_entries(state, harness: harness, query: query).empty?

          wrap(ModelPicker.empty_message(state, harness: harness_for(state, harness), query: query))
        else
          []
        end
      end

      def welcome_lines(steps)
        [
          "Meringue runs many coding agents at once and keeps you in one window.",
          "",
          "You type a goal, a head agent routes it, and workers do the work in their",
          "own git worktrees. The tree on the left is how you watch them.",
          "",
          "#{choice_steps(steps).length} quick choices, each already on a sensible default:",
          "hold Enter to accept them all."
        ]
      end

      # Selectable rows for a step. Every row carries the slash command that
      # applies it, so the controller never has to know how a setting is written.
      def rows(state, step:, harness: nil, query: nil, saved_theme: nil)
        case step.to_s
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
      # set and what to do next. Nothing lingers over the dashboard afterwards.
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
          "  · Double-click a worker to open its focused workspace: full transcript, a shell",
          "    in its worktree, and its pull request.",
          "",
          "  Enter send · Tab focus · / commands · Esc clear · Ctrl-B pull request · /keybind all keys"
        ]
      end

      def skip_card(settings)
        "Setup skipped — run /setup any time.\n  Now: #{summary_line(settings)}"
      end

      def collapsed_message
        "Setup needs a taller terminal — run /setup after resizing."
      end

      def unavailable_message
        "Setup needs a live kernel. Run meringue (not meringue demo) to choose your defaults."
      end

      def wrap(text, width = PROSE_WIDTH)
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
