# frozen_string_literal: true

module Meringue
  module Heads
    class FakeRunner < Runner
      def run(user_message:, snapshot:, context: nil, question_id: nil)
        command = build_command(user_message: user_message, snapshot: snapshot, context: context)

        {
          "title" => title_from(user_message),
          "summary" => "Fake head generated a deterministic #{command.fetch("type")} command from the prompt.",
          "commands" => [command],
          "questions" => []
        }
      end

      private

      def build_command(user_message:, snapshot:, context:)
        project = snapshot.fetch("projects", []).first

        return add_project_command(context) unless project

        create_issue_command(
          project_id: project.fetch("id"),
          title: title_from(user_message),
          user_message: user_message
        )
      end

      def add_project_command(context)
        cwd = context&.cwd || Dir.pwd

        {
          "type" => "AddProject",
          "payload" => {
            "path" => cwd,
            "name" => File.basename(cwd)
          }
        }
      end

      def create_issue_command(project_id:, title:, user_message:)
        {
          "type" => "CreateIssue",
          "payload" => {
            "project_id" => project_id,
            "title" => title,
            "description" => "Fake issue generated from user prompt:\n\n#{user_message}\n\nThis manual loop only prints the proposed command; the kernel has not applied it.",
            "parent_issue_id" => nil
          }
        }
      end

      def title_from(user_message)
        words = user_message.to_s.strip.split(/\s+/).first(8)
        title = words.join(" ")
        return "Untitled fake head task" if title.empty?

        title[0] = title[0].upcase
        title
      end
    end
  end
end
