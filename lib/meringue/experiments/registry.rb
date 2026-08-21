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
      keyword_init: true
    ) do
      def initialize(**values)
        super
        self.id = id.to_s.freeze
        self.config_path = Array(config_path).map(&:to_s).freeze
        self.dependencies = Array(dependencies).map(&:to_s).freeze
        self.conflicts = Array(conflicts).map(&:to_s).freeze
        freeze
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
          availability_probe: nil
        ),
        Definition.new(
          id: "split_agent_defaults",
          config_path: %w[experiments split_agent_defaults],
          label: "Split head and worker defaults",
          description: "Choose different model and thinking defaults for heads and workers.",
          default: false,
          restart_required: false,
          risk: "Enables role-scoped /model and /thinking commands instead of one shared default.",
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
    end
  end
end
