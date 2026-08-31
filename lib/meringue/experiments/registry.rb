# frozen_string_literal: true

module Meringue
  module Experiments
    Definition = Struct.new(
      :id,
      :config_path,
      :label,
      :description,
      :default,
      :restart_required,
      :risk,
      :dependencies,
      :conflicts,
      :migration,
      :availability_probe,
      :actions,
      # Present only on an experiment that selects among named modes rather than
      # being on or off. Settings renders these as a selector instead of a
      # checkbox, and `mode?` is what tells the two apart.
      :modes,
      :mode_labels,
      :mode_descriptions,
      # Optional callable that derives the effective value from a config that
      # has not recorded this experiment yet, so a setting that replaced older
      # keys reads correctly before the migration writes it.
      :resolver,
      keyword_init: true
    ) do
      def initialize(**values)
        super
        self.id = id.to_s.freeze
        self.config_path = Array(config_path).map(&:to_s).freeze
        self.dependencies = Array(dependencies).map(&:to_s).freeze
        self.conflicts = Array(conflicts).map(&:to_s).freeze
        self.actions = Array(actions).map { |action| action.to_h.transform_keys(&:to_s).freeze }.freeze
        self.modes = modes.nil? ? nil : Array(modes).map(&:to_s).freeze
        self.mode_labels = (mode_labels || {}).transform_keys(&:to_s).transform_values(&:to_s).freeze
        self.mode_descriptions = (mode_descriptions || {}).transform_keys(&:to_s).transform_values(&:to_s).freeze
        freeze
      end

      # A mode experiment stores one of `modes`; a plain experiment stores a
      # boolean. Everything that renders or validates an experiment branches
      # here rather than special-casing an id.
      def mode?
        !modes.nil?
      end

      def mode_label(mode)
        mode_labels.fetch(mode.to_s, mode.to_s)
      end

      def mode_description(mode)
        mode_descriptions.fetch(mode.to_s, "")
      end

      def action_setting_ids
        actions.map { |action| "experiments.#{action.fetch("id")}" }
      end

      def apply_mode
        restart_required ? "restart" : "live"
      end

      def available?(context = nil)
        return true unless availability_probe.respond_to?(:call)

        availability_probe.call(context) != false
      end
    end

    # The authoritative list of opt-in product capabilities. Settings and future
    # setup flows consume this registry directly; neither keeps a parallel list.
    module Registry
      DEFINITIONS = [
        Definition.new(
          id: "github_support",
          config_path: %w[experiments github_support],
          label: "GitHub support",
          description: "Track, refresh, open, and retain work around GitHub pull requests.",
          default: false,
          restart_required: false,
          risk: "May run bounded read-only gh lookups and show GitHub-specific delivery UI.",
          dependencies: [],
          conflicts: [],
          migration: "enable_for_existing_installations",
          actions: [
            {
              "id" => "github_support_test_access",
              "label" => "Test GitHub access",
              "description" => "Check GitHub authentication and read access to this repository without changing GitHub."
            }
          ],
          availability_probe: nil
        ),
        Definition.new(
          id: "agent_defaults_mode",
          config_path: AgentDefaultsMode::CONFIG_PATH,
          resolver: ->(config) { AgentDefaultsMode.resolve(config) },
          label: "Model and reasoning defaults",
          description: "Choose how future heads and workers get their model and reasoning level.",
          default: AgentDefaultsMode::DEFAULT,
          modes: AgentDefaultsMode::MODES,
          mode_labels: AgentDefaultsMode::LABELS,
          mode_descriptions: AgentDefaultsMode::DESCRIPTIONS,
          restart_required: false,
          risk: "Heads and workers may intentionally use different models, and guided mode lets heads assign them.",
          dependencies: [],
          conflicts: [],
          migration: "preserve_existing_role_defaults",
          actions: [],
          availability_probe: nil
        ),
        Definition.new(
          id: "self_fixing_workers",
          config_path: %w[experiments self_fixing_workers],
          label: "Self-fixing workers",
          description: "Diagnose and attempt one bounded recovery for eligible errored or blocked workers.",
          default: false,
          restart_required: false,
          risk: "May start one isolated recovery worker per failed worker; recovery workers cannot recursively recover themselves.",
          dependencies: [],
          conflicts: [],
          migration: nil,
          availability_probe: nil
        )
      ].freeze

      module_function

      def all
        DEFINITIONS
      end

      def fetch(id)
        all.find { |definition| definition.id == id.to_s } || raise(KeyError, "Unknown experiment #{id.inspect}")
      end

      def ids
        all.map(&:id)
      end

      def setting_ids
        all.flat_map { |definition| ["experiments.#{definition.id}", *definition.action_setting_ids] }
      end

      def action(id)
        all.flat_map(&:actions).find { |candidate| "experiments.#{candidate.fetch("id")}" == id.to_s }
      end
    end
  end
end
