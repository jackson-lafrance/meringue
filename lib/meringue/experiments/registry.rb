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
      keyword_init: true
    ) do
      def initialize(**values)
        super
        self.id = id.to_s.freeze
        self.config_path = Array(config_path).map(&:to_s).freeze
        self.dependencies = Array(dependencies).map(&:to_s).freeze
        self.conflicts = Array(conflicts).map(&:to_s).freeze
        self.actions = Array(actions).map { |action| action.to_h.transform_keys(&:to_s).freeze }.freeze
        freeze
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
          id: "split_defaults",
          config_path: %w[experiments split_defaults],
          label: "Split head and worker defaults",
          description: "Allow heads and workers to keep independent harness, model, and thinking defaults.",
          default: true,
          restart_required: false,
          risk: "Future heads and workers may intentionally use different providers and settings.",
          dependencies: [],
          conflicts: [],
          migration: "preserve_existing_role_defaults",
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
