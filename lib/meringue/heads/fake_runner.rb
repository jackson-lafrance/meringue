# frozen_string_literal: true

module Meringue
  module Heads
    class FakeRunner < Runner
      def run(user_message:, snapshot:, context: nil, question_id: nil)
        commands = build_commands(user_message: user_message, snapshot: snapshot, context: context)

        {
          "title" => title_from(user_message),
          "summary" => "Fake head proposed #{commands.length} deterministic kernel command(s): reuse an issue when possible and spawn a worker.",
          "commands" => commands,
          "questions" => []
        }
      end

      private

      def build_commands(user_message:, snapshot:, context:)
        project = snapshot.fetch("projects", []).first
        commands = []

        unless project
          project_id = next_project_id(snapshot)
          commands << add_project_command(context)
        end

        project_id ||= project.fetch("id")
        existing_issue = snapshot.fetch("issues", []).find { |issue| issue.fetch("project_id", nil) == project_id }
        title = title_from(user_message)

        if existing_issue
          issue_id = existing_issue.fetch("id")
        else
          issue_id = next_issue_id(snapshot, project_id)
          commands << create_issue_command(
            project_id: project_id,
            title: title,
            user_message: user_message
          )
        end

        commands << spawn_worker_command(
          issue_id: issue_id,
          title: title,
          user_message: user_message
        )
        commands
      end

      def add_project_command(context)
        project_root = default_project_root(context&.cwd || Dir.pwd)

        {
          "type" => "AddProject",
          "payload" => {
            "path" => project_root,
            "name" => File.basename(project_root)
          }
        }
      end

      def create_issue_command(project_id:, title:, user_message:)
        {
          "type" => "CreateIssue",
          "payload" => {
            "project_id" => project_id,
            "title" => title,
            "description" => "Fake issue generated from user prompt:\n\n#{user_message}\n\nThe simple loop will ask the kernel to validate and apply this command before spawning the worker.",
            "parent_issue_id" => nil
          }
        }
      end

      def spawn_worker_command(issue_id:, title:, user_message:)
        {
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => issue_id,
            "title" => title,
            "prompt" => "Work on issue '#{title}' from this user request:\n\n#{user_message}\n\nKeep the change focused and summarize what you did.",
            "workspace_path" => nil
          }
        }
      end

      def next_project_id(snapshot)
        next_number = snapshot.fetch("counters", {}).fetch("projects", max_project_number(snapshot)).to_i + 1
        "P#{next_number}"
      end

      def next_issue_id(snapshot, project_id)
        issue_counters = snapshot.fetch("counters", {}).fetch("issues_by_project", {})
        next_number = issue_counters.fetch(project_id, max_issue_number(snapshot, project_id)).to_i + 1
        "#{project_id}-I#{next_number}"
      end

      def default_project_root(path)
        nearest_git_root(path) || File.expand_path(path)
      end

      def nearest_git_root(path)
        current = File.expand_path(path.to_s)

        loop do
          return current if File.exist?(File.join(current, ".git"))

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def max_project_number(snapshot)
        snapshot.fetch("projects", []).filter_map do |project|
          match = project.fetch("id", "").match(/\AP(\d+)\z/)
          match && match[1].to_i
        end.max || 0
      end

      def max_issue_number(snapshot, project_id)
        snapshot.fetch("issues", []).filter_map do |issue|
          next unless issue.fetch("project_id", nil) == project_id

          match = issue.fetch("id", "").match(/\A#{Regexp.escape(project_id)}-I(\d+)\z/)
          match && match[1].to_i
        end.max || 0
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
