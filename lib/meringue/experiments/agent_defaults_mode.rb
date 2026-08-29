# frozen_string_literal: true

module Meringue
  module Experiments
    # How future heads and workers get their model and reasoning level.
    #
    # This replaces two booleans that were never independent. "Split head and
    # worker defaults" decided whether the two roles could hold different
    # values, and "worker model selection guidance" asked heads to choose each
    # worker's model. Guidance is meaningless without per-role values to assign,
    # so the pair had one meaningless combination (guidance on, split off) and
    # no single place that said which arrangement was in force.
    #
    # The three arrangements are therefore one setting with three modes:
    #
    # - `shared`        one model and reasoning level for every future session
    # - `role_specific` heads and workers keep independent values
    # - `guided`        as `role_specific`, and heads assign each worker's pair
    #
    # `guided` implies `role_specific` rather than depending on it, which is why
    # `role_specific?` is true for both.
    module AgentDefaultsMode
      # Hyphenated because the settings schema normalizes every enum that way;
      # `normalize` still accepts the underscored spelling.
      SHARED = "shared"
      ROLE_SPECIFIC = "role-specific"
      GUIDED = "guided"
      MODES = [SHARED, ROLE_SPECIFIC, GUIDED].freeze
      DEFAULT = ROLE_SPECIFIC

      CONFIG_PATH = %w[experiments agent_defaults_mode].freeze
      LEGACY_SPLIT_PATH = %w[experiments split_defaults].freeze
      LEGACY_GUIDANCE_PATH = %w[experiments worker_spawning_guidance].freeze

      LABELS = {
        SHARED => "Shared",
        ROLE_SPECIFIC => "Split",
        GUIDED => "Guided"
      }.freeze

      DESCRIPTIONS = {
        SHARED => "One model and reasoning level for every future head and worker.",
        ROLE_SPECIFIC => "Split head and worker model and reasoning defaults independently.",
        GUIDED => "Heads choose each worker's model and reasoning from guidance you write; roles stay independent."
      }.freeze

      module_function

      def normalize(value)
        text = value.to_s.strip.downcase.tr("_ ", "--")
        return text if MODES.include?(text)

        nil
      end

      def label(mode)
        LABELS.fetch(normalize(mode) || DEFAULT)
      end

      def description(mode)
        DESCRIPTIONS.fetch(normalize(mode) || DEFAULT)
      end

      # The mode in force for `config`. An explicit mode always wins; otherwise
      # the retired booleans are read so an installation that never opens
      # Settings keeps behaving the way it did before the consolidation.
      def resolve(config)
        return DEFAULT if config.nil?

        explicit = normalize(config.value(*CONFIG_PATH))
        return explicit if explicit

        from_legacy(
          split: config.value(*LEGACY_SPLIT_PATH),
          guidance: config.value(*LEGACY_GUIDANCE_PATH)
        )
      end

      # Guidance was the narrower opt-in, so it wins when both legacy flags are
      # set. Split defaults defaulted to on, so only an explicit `false` means
      # the installation actually wanted one shared value.
      def from_legacy(split:, guidance:)
        return GUIDED if truthy?(guidance)
        return SHARED if falsey?(split)

        ROLE_SPECIFIC
      end

      def role_specific?(config)
        resolve(config) != SHARED
      end

      def guided?(config)
        resolve(config) == GUIDED
      end

      def truthy?(value)
        value == true || %w[true yes 1 on].include?(value.to_s.strip.downcase)
      end

      def falsey?(value)
        value == false || %w[false no 0 off].include?(value.to_s.strip.downcase)
      end
    end
  end
end
