# frozen_string_literal: true

module Meringue
  module Heads
    class Runner
      def run(user_message:, snapshot:, context: nil, question_id: nil)
        raise NotImplementedError, "head runners must implement #run"
      end
    end
  end
end
