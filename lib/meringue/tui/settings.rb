# frozen_string_literal: true

require "json"
require "shellwords"

module Meringue
  module TUI
    module Settings
      STATE_KEY = "_settings"
      MIN_WIDTH = 32
      MIN_HEIGHT = 10
      WIDE_WIDTH = 80
      COMPACT_WIDTH = 46

      # Curated first-run mode over the same Draft, schema definitions, editors,
      # and pane used by /config. Experiment ids are always derived from the
      # registry so setup cannot drift from the complete Settings surface.
      module SetupFlow
        WELCOME = "Welcome"
        HARNESS = "Harness"
        THEME = "Theme"
        STATUS_BAR = "Status bar"
        # The step id stays the schema category it draws from; only the heading
        # reads "Meringue Xtras".
        EXPERIMENTS = "Experiments"
        DONE = "Done"

        # Head and worker used to be two separate steps, which asked a first-time
        # user to make the same decision twice before they had been told what
        # either word meant. They are one step now, and the two rows read as a
        # confirmation rather than a decision whenever exactly one harness is
        # actually installed. Welcome and Done carry no controls at all: a first
        # run should open and close with something to read, not a form.
        STEPS = [WELCOME, HARNESS, THEME, STATUS_BAR, EXPERIMENTS, DONE].freeze
        NARRATIVE_STEPS = [WELCOME, DONE].freeze

        FIXED_SETTING_IDS = {
          HARNESS => %w[agent.head_harness agent.worker_harness].freeze,
          THEME => %w[appearance.theme appearance.animations].freeze,
          STATUS_BAR => %w[appearance.status_bar_layout].freeze
        }.freeze

        # Model and reasoning both have per-harness defaults that are correct for
        # a first session, and both are the kind of choice someone makes once they
        # have opinions. They stay one keystroke away instead of sitting between a
        # new user and a working install.
        ADVANCED_SETTING_IDS = {
          HARNESS => %w[agent.head_model agent.head_thinking agent.worker_model agent.worker_thinking].freeze
        }.freeze

        # Setup will not finish without these. Validation normally runs only over
        # settings the user changed, which is right for /config — an unrelated save
        # must not fail on a field nobody edited — but it is also how setup used to
        # complete with no harness at all.
        REQUIRED_SETTING_IDS = %w[agent.head_harness agent.worker_harness].freeze

        module_function

        def steps
          STEPS
        end

        def narrative?(step)
          NARRATIVE_STEPS.include?(step.to_s)
        end

        def setting_ids(step, draft: nil, include_advanced: false)
          ids = if step.to_s == EXPERIMENTS
                  experiment_setting_ids(draft)
                else
                  FIXED_SETTING_IDS.fetch(step.to_s, []).dup
                end
          include_advanced ? ids + advanced_setting_ids(step) : ids
        end

        def advanced_setting_ids(step)
          ADVANCED_SETTING_IDS.fetch(step.to_s, [])
        end

        def experiment_setting_ids(draft)
          ids = Experiments::Registry.setting_ids.dup
          if draft && Experiments::AgentDefaultsMode.normalize(draft.value("experiments.agent_defaults_mode")) == Experiments::AgentDefaultsMode::GUIDED
            ids << "experiments.worker_spawning_guidance_prompt"
          end
          ids
        end

        def step_for_setting(id)
          candidate = id.to_s
          steps.find do |step|
            setting_ids(step, include_advanced: true).include?(candidate) ||
              (step == EXPERIMENTS && candidate == "experiments.worker_spawning_guidance_prompt")
          end
        end

        def experiment_defaults(draft, explicit_only: false)
          Experiments::Registry.all.each_with_object({}) do |experiment, values|
            definition = Config::Schema.fetch("experiments.#{experiment.id}")
            next if explicit_only && draft.config.path_present?(*definition.path)

            values[definition.id] = draft.value(definition.id)
          end
        end
      end

      # Transactional, schema-backed UI draft. It owns no persistence; Save emits
      # one patch payload for the kernel's SaveConfiguration command.
      class Draft
        attr_reader :config, :baseline_fingerprint, :values, :original_values,
                    :errors, :global_error, :original_theme

        def initialize(config, env: ENV)
          @config = config
          @env = env
          @baseline_fingerprint = config.fingerprint
          @definitions = Config::Schema.definitions.reject { |definition| definition.visibility == "internal" }
          @values = Config::Schema.effective_values(config, env: env).slice(*@definitions.map(&:id))
          @original_values = Config.deep_copy(@values)
          @errors = {}
          @global_error = nil
          @original_theme = Style.current_colorscheme.to_s
        end

        def definitions
          @definitions
        end

        def categories
          Config::Schema.categories.select { |category| definitions.any? { |definition| definition.category == category } }
        end

        def definitions_for(category, include_advanced: true)
          definitions.select do |definition|
            definition.category == category.to_s && (include_advanced || !definition.advanced) && visible_definition?(definition)
          end
        end

        def value(id)
          key = id.to_s
          return Config.deep_copy(values.fetch(key)) if values.key?(key)

          definition = @definitions.find { |candidate| candidate.id == key }
          return definition.default_value(config, env: @env) if definition&.type == "action"

          raise KeyError, "Unknown setting #{id.inspect}"
        end

        def changed?(id)
          values[id.to_s] != original_values[id.to_s]
        end

        def dirty?
          definitions.any? { |definition| changed?(definition.id) }
        end

        def changed_ids
          definitions.filter_map { |definition| definition.id if changed?(definition.id) }
        end

        def changes
          changed_ids.to_h { |id| [id, Config.deep_copy(values.fetch(id))] }
        end

        def set(id, candidate)
          definition = Config::Schema.fetch(id)
          previous = values[definition.id]
          normalized = definition.validate_value(candidate, config: config)
          values[definition.id] = normalized
          update_role_model_for_harness_change(definition.id, previous, normalized)
          errors.delete(definition.id)
          @global_error = nil
          normalized
        rescue ArgumentError => e
          errors[definition.id] = e.message
          nil
        end

        def cycle(id, delta)
          definition = Config::Schema.fetch(id)
          options = definition.option_values(config)
          return value(id) if options.empty?

          current = value(id).to_s
          index = options.index(current) || 0
          set(id, options[(index + delta.to_i) % options.length])
        end

        def toggle(id)
          set(id, !truthy?(value(id)))
        end

        # Validation runs over `changes`, so a setting the user never touched is
        # never checked. That is right for /config, where an unrelated save must
        # not fail on a field nobody edited — but it is also exactly how first-run
        # setup used to reach Complete with no harness chosen, write
        # `outcome = "completed"`, and leave a dashboard that rejects the first
        # prompt. Setup names the settings it will not finish without.
        def validate(required_ids: [])
          @errors = {}
          Config::Schema.validate_changes(changes, config: config)
          missing = Array(required_ids).each_with_object({}) do |id, result|
            next unless value(id).to_s.strip.empty?

            result[id.to_s] = "#{Config::Schema.fetch(id).label} is required — Meringue cannot start an agent without it."
          end
          raise Config::ValidationError, missing unless missing.empty?

          true
        rescue Config::ValidationError => e
          @errors = e.field_errors
          false
        end

        def apply_save_failure(message, field_errors = nil)
          @global_error = message.to_s
          @errors.merge!(Config.deep_stringify(field_errors || {}))
        end

        def clear_save_failure
          @global_error = nil
        end

        def restore_theme
          return if original_theme.empty? || Style.current_colorscheme.to_s == original_theme

          Style.configure!(original_theme)
        rescue ArgumentError
          nil
        end

        def preview_theme
          selected = values["appearance.theme"].to_s
          return if selected.empty? || selected == Style.current_colorscheme.to_s

          Style.configure!(selected)
        rescue ArgumentError
          nil
        end

        def editor_text(id)
          definition = Config::Schema.fetch(id)
          current = value(id)
          case definition.type
          when "command_argv", "string_list", "blacklist_glob_list", "keybinding_list", "environment_map"
            JSON.pretty_generate(current)
          else
            current.to_s
          end
        end

        def parse_editor(id, text)
          definition = Config::Schema.fetch(id)
          value = case definition.type
                  when "integer", "duration"
                    Integer(text.to_s.strip)
                  when "command_argv"
                    parse_command(text, optional: definition.optional)
                  when "string_list", "blacklist_glob_list", "keybinding_list"
                    parse_list(text)
                  when "environment_map"
                    parse_environment(text)
                  else
                    text.to_s
                  end
          set(id, value)
        rescue ArgumentError, JSON::ParserError, Shellwords::ParseError => e
          errors[id.to_s] = e.message
          nil
        end

        def row(definition)
          current = value(definition.id)
          default = definition.default_value(config, env: @env)
          {
            "id" => definition.id,
            "label" => definition.label,
            "description" => definition.description,
            "type" => definition.type,
            "editor" => definition.editor,
            "value" => Config.deep_copy(current),
            "display_value" => display_value(definition, current),
            "default_value" => display_value(definition, default),
            "source" => definition.source(config, env: @env),
            "dirty" => changed?(definition.id),
            "error" => errors[definition.id],
            "advanced" => definition.advanced,
            "read_only" => definition.visibility == "read_only" || definition.type == "read_only",
            "apply_mode" => definition.apply_mode,
            "options" => definition.option_values(config),
            "option_labels" => definition.option_values(config).to_h { |option| [option, definition.option_label(option)] },
            "option_descriptions" => definition.option_values(config).to_h { |option| [option, definition.option_description(option)] }
          }.compact
        end

        private

        def update_role_model_for_harness_change(setting_id, previous_provider, provider)
          match = setting_id.to_s.match(/\Aagent\.(head|worker)_harness\z/)
          return unless match

          role = match[1]
          model_id = "agent.#{role}_model"
          previous_default = if previous_provider.to_s.strip.empty?
                               Harness::Registry::DEFAULT_MODEL
                             else
                               Harness::Registry.default_model_for(previous_provider)
                             end
          return unless values[model_id].to_s == previous_default.to_s

          values[model_id] = Harness::Registry.default_model_for(provider)
        rescue ArgumentError
          nil
        end

        # The guided selection prompt only means something in guided mode, so it
        # appears and disappears with that mode rather than sitting inert.
        def visible_definition?(definition)
          return true unless definition.id == "experiments.worker_spawning_guidance_prompt"

          Experiments::AgentDefaultsMode.normalize(value("experiments.agent_defaults_mode")) ==
            Experiments::AgentDefaultsMode::GUIDED
        rescue KeyError
          false
        end

        def truthy?(value)
          value == true || value.to_s.strip.downcase == "true"
        end

        def parse_command(text, optional: false)
          stripped = text.to_s.strip
          return [] if optional && stripped.empty?
          return JSON.parse(stripped).map(&:to_s) if stripped.start_with?("[")

          Shellwords.split(stripped)
        end

        def parse_list(text)
          stripped = text.to_s.strip
          return [] if stripped.empty?
          return JSON.parse(stripped).map(&:to_s) if stripped.start_with?("[")

          stripped.split(/\r?\n|,/).map(&:strip).reject(&:empty?)
        end

        def parse_environment(text)
          stripped = text.to_s.strip
          return {} if stripped.empty?
          return JSON.parse(stripped) if stripped.start_with?("{")

          stripped.lines.each_with_object({}) do |line, result|
            next if line.strip.empty?
            key, value = line.chomp.split("=", 2)
            raise ArgumentError, "environment entries use KEY=VALUE" if value.nil?

            result[key] = value
          end
        end

        def display_value(definition, value)
          return "<redacted: #{value.is_a?(Hash) ? value.length : 1} entr#{value.is_a?(Hash) && value.length == 1 ? "y" : "ies"}>" if definition.sensitive && !value.to_h.empty?

          # An enum that carries its own labels shows the label, so a row reads
          # "By role" rather than the stored "role-specific".
          labelled = definition.option_label(value) if definition.type == "enum"
          return labelled if labelled && labelled != value.to_s

          case value
          when TrueClass then "on"
          when FalseClass then "off"
          when Array then value.empty? ? "(empty)" : value.join(" ")
          when Hash then value.empty? ? "(empty)" : "#{value.length} entries"
          else
            text = value.to_s
            text.empty? ? "(empty)" : text
          end
        rescue NoMethodError
          value.to_s
        end
      end

      module_function

      def enabled?(state)
        snapshot(state).fetch("active", false) == true
      end

      def snapshot(state)
        value = (state || {}).fetch(STATE_KEY, nil)
        value.is_a?(Hash) ? value : {}
      end

      # Seconds a working agent may produce nothing before its row is marked quiet. The kernel
      # publishes this into state metadata from `agent.quiet_worker_warning`; a dashboard that
      # has not seen a reconciliation pass yet falls back to the same default the kernel uses,
      # so the marker never depends on a race with the first pass. 0 turns the marker off.
      DEFAULT_QUIET_WORKER_WARNING_SECONDS = 900

      def quiet_worker_warning_seconds(state)
        configured = (state || {}).fetch("metadata", {})
        configured = {} unless configured.is_a?(Hash)
        value = configured["quiet_worker_warning_seconds"]
        return DEFAULT_QUIET_WORKER_WARNING_SECONDS unless value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

        seconds = value.to_i
        seconds.negative? ? 0 : seconds
      end

      # How long this worker has been silent, or nil when it is not quiet.
      #
      # The clock has to be `last_activity_at` and nothing else. Falling back to the record's own
      # `updated_at` looked appealing - it is the only evidence a pre-upgrade record has - but
      # routine reconciliation bookkeeping moves it, and a state file that has simply been sitting
      # on disk would light up every `working` row at once. The kernel seeds the real clock on the
      # first reconciliation pass it makes, so "no clock yet" means "not watched yet", and the
      # honest answer to how long it has been silent is to say nothing.
      def worker_quiet_seconds(worker, threshold:, now: Time.now)
        return nil unless threshold.to_i.positive?
        return nil unless worker.is_a?(Hash) && worker["type"] == "worker" && worker["status"] == "working"

        metadata = worker["harness_metadata"]
        metadata = {} unless metadata.is_a?(Hash)
        # A worker still waiting on its worktree has not been given a session to be quiet in.
        return nil if metadata["provisioning_state"].to_s.start_with?("provisioning", "allocating", "retry")

        from = Timestamps.parse(metadata["last_activity_at"])
        return nil unless from

        elapsed = (now - from).to_i
        elapsed >= threshold.to_i ? elapsed : nil
      end

      def quiet_worker_count(state)
        threshold = quiet_worker_warning_seconds(state)
        return 0 unless threshold.positive?

        now = Time.now
        (state || {}).fetch("agents", []).count { |agent| worker_quiet_seconds(agent, threshold: threshold, now: now) }
      end

      def github_enabled?(state)
        capabilities = (state || {}).fetch("_capabilities", {}) || {}
        capabilities.fetch("github_support", true) != false
      end
    end
  end
end
