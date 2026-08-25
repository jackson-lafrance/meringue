# frozen_string_literal: true

module Meringue
  module Experiments
    # Additional head-only instructions for selecting a worker's model and
    # thinking level. The @ and # markers are also the inline completion syntax
    # exposed by the input layer.
    module WorkerSpawningGuidance
      DEFAULT_PROMPT = <<~TEXT.strip
        Choose each worker's model and thinking level from the task's complexity, risk, and need for speed. Use lighter choices for routine, bounded work and stronger choices for ambiguous or high-impact work. Set both model and thinking_level explicitly on every SpawnWorker, using an available model and one of off, minimal, low, medium, high, xhigh, or max.
      TEXT

      module_function

      def default_text
        DEFAULT_PROMPT
      end

      def text(prompt = nil)
        prompt.nil? ? DEFAULT_PROMPT : prompt.to_s
      end
    end
  end
end
