# frozen_string_literal: true

module Meringue
  module Heads
    class FakeRunner < Runner
      def run(user_message:, snapshot:, question_id: nil)
        {
          "title" => "Fake head",
          "summary" => "Fake head received a prompt but does not propose work in the scaffold.",
          "commands" => [],
          "questions" => [],
          "metadata" => {
            "user_message" => user_message,
            "question_id" => question_id,
            "snapshot_schema_version" => snapshot.fetch("schema_version", nil)
          }
        }
      end
    end
  end
end
