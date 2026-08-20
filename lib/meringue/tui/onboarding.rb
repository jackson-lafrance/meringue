# frozen_string_literal: true

module Meringue
  module TUI
    # First-run lifecycle and completion copy. The interactive controller and
    # renderer intentionally live in Settings: setup is a curated Settings::Draft,
    # not a second wizard or command-per-step persistence path.
    module Onboarding
      module_function

      def completed?(config)
        version_for(config) >= Meringue::Config::ONBOARDING_VERSION
      end

      def version_for(config)
        return 0 unless config.respond_to?(:value)

        config.value(Meringue::Config::ONBOARDING_SECTION, "completed_version").to_i
      end

      def fits?(width:, height:)
        width.to_i >= Settings::MIN_WIDTH && height.to_i >= Settings::MIN_HEIGHT
      end

      def unavailable_message
        "Setup needs a live kernel. Run meringue (not meringue demo) to choose your defaults."
      end

      def collapsed_message
        "Setup needs a bigger terminal (at least #{Settings::MIN_WIDTH}×#{Settings::MIN_HEIGHT}) — run /setup after resizing."
      end

      def values(config)
        Config::Schema.effective_values(config).slice(
          "appearance.theme",
          "agent.head_harness",
          "agent.head_model",
          "agent.head_thinking",
          "agent.worker_harness",
          "agent.worker_model",
          "agent.worker_thinking",
          *Experiments::Registry.ids.map { |id| "experiments.#{id}" }
        )
      end

      def completion_card(config)
        selected = values(config)
        lines = [
          "✓ Setup complete.",
          "  Theme: #{selected.fetch("appearance.theme")}",
          "  Head: #{role_summary(selected, "head")}",
          "  Worker: #{role_summary(selected, "worker")}",
          "  Experiments: #{experiment_summary(selected)}",
          "",
          "  Type a goal in plain English to begin. Run /config to change any setting."
        ]
        lines.join("\n")
      end

      def skip_card
        "Setup skipped — defaults were left unchanged. Run /setup any time."
      end

      def role_summary(selected, role)
        harness = selected.fetch("agent.#{role}_harness")
        parts = ["#{harness} harness"]
        # Model and reasoning are only worth reporting for a backend that actually accepts them.
        if Harness::Registry.session_defaults_supported_for?(harness)
          parts << selected.fetch("agent.#{role}_model")
          parts << "reasoning #{selected.fetch("agent.#{role}_thinking")}"
        end
        parts.join(" · ")
      end
      private_class_method :role_summary

      def experiment_summary(selected)
        Experiments::Registry.all.map do |experiment|
          enabled = selected.fetch("experiments.#{experiment.id}") == true
          "#{experiment.label} #{enabled ? "on" : "off"}"
        end.join(" · ")
      end
      private_class_method :experiment_summary
    end
  end
end
