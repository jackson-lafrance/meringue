# frozen_string_literal: true

module Meringue
  module Experiments
    # Additional head-only instructions for selecting a worker's model and
    # thinking level. The @ and # markers are also the inline completion syntax
    # exposed by the input layer.
    module WorkerSpawningGuidance
      DEFAULT_PROMPT = <<~TEXT.strip
        Choose a worker's model and thinking level for the task instead of applying one setting to every task.

        Use the exact @<provider>/<model> and #<thinking-level> markers when expressing a deliberate worker selection. Examples from the model catalog: implementation work can use @openai/gpt-5.6-luna with #xhigh thinking; investigation work can use @openai/gpt-5.6-sol with a task-appropriate thinking level. These are examples, not a hard-coded allowlist: choose from the configured catalog when it is available, and use only accepted thinking levels (off, minimal, low, medium, high, xhigh, max). Put the selected model and thinking_level on SpawnWorker, and leave either field omitted when no deliberate choice is needed.
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
