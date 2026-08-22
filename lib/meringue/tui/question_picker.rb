# frozen_string_literal: true

module Meringue
  module TUI
    # The open-question list behind `/questions`.
    #
    # Question ids are durable state identifiers and may have gaps after records
    # are answered, dismissed, or renumbered. The picker therefore gives each
    # visible row its own one-based display number while retaining the canonical
    # id that `/answer` needs.
    module QuestionPicker
      module_function

      def entries(state)
        Array((state || {}).fetch("questions", []))
          .select { |question| question.is_a?(Hash) && question.fetch("status", nil).to_s == "open" }
          .each_with_index.map do |question, index|
            question.merge("display_number" => index + 1)
          end
      end

      def entry_at(state, index)
        list = entries(state)
        return nil if list.empty?

        list[index.to_i.clamp(0, list.length - 1)]
      end

      def count(state)
        entries(state).length
      end
    end
  end
end
