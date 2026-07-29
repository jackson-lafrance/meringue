# frozen_string_literal: true

module Meringue
  module Heads
    class FakeRunner < Runner
      # Symbolic id for the CreateIssue command in a generated batch. A worker for a
      # brand-new issue references this command instead of predicting the issue id.
      ISSUE_COMMAND_ID = "create-issue"

      def run(user_message:, snapshot:, context: nil, question_id: nil)
        commands = build_commands(user_message: user_message, snapshot: snapshot, context: context)

        {
          "title" => title_from(user_message),
          "summary" => "Fake head proposed #{commands.length} deterministic kernel command(s): reuse the best issue and worker session when possible.",
          "commands" => commands,
          "questions" => []
        }
      end

      private

      def build_commands(user_message:, snapshot:, context:)
        commands = []
        selected_target = selected_target_from(context)
        selected_issue = snapshot.fetch("issues", []).find do |issue|
          issue.fetch("id", nil).to_s == selected_target.fetch("issue_id", nil).to_s
        end
        selected_worker = snapshot.fetch("agents", []).find do |agent|
          agent.fetch("id", nil).to_s == selected_target.fetch("selected_agent_id", nil).to_s &&
            agent.fetch("issue_id", nil).to_s == selected_issue&.fetch("id", nil).to_s
        end
        return [prompt_worker_command(selected_worker, user_message)] if resumable_worker?(selected_worker)

        explicit_worker = referenced_worker(snapshot, user_message) unless selected_issue
        return [prompt_worker_command(explicit_worker, user_message)] if resumable_worker?(explicit_worker)

        existing_issue = selected_issue || referenced_issue(snapshot, user_message) || matching_issue(snapshot, user_message)
        project = project_for_issue(snapshot, existing_issue) || referenced_project(snapshot, user_message) || snapshot.fetch("projects", []).first

        unless project
          project_id = next_project_id(snapshot)
          commands << add_project_command(context)
        end

        project_id ||= project.fetch("id")
        existing_issue = nil if existing_issue && existing_issue.fetch("project_id", nil) != project_id
        title = title_from(user_message)

        if existing_issue
          issue_id = existing_issue.fetch("id")
          prior_worker = latest_worker(snapshot, issue_id)
          if resumable_worker?(prior_worker)
            commands << prompt_worker_command(prior_worker, user_message)
            return commands
          end
        else
          # Never predict the id of an issue this batch creates; point the worker at the
          # CreateIssue command instead and let the kernel resolve the real id.
          issue_command_id = ISSUE_COMMAND_ID
          commands << create_issue_command(
            project_id: project_id,
            title: title,
            user_message: user_message,
            command_id: issue_command_id
          )
        end

        prior_worker ||= latest_worker(snapshot, issue_id) if issue_id
        commands << spawn_worker_command(
          issue_id: issue_id,
          issue_from_command: issue_command_id,
          title: title,
          user_message: user_message,
          follow_up_of_agent_id: follow_up_worker_id(prior_worker),
          replace_agent_id: replacement_worker_id(prior_worker)
        )
        commands
      end

      def selected_target_from(context)
        return {} unless context&.respond_to?(:to_prompt_h)

        target = context.to_prompt_h.dig("routing_context", "selected_target")
        target.is_a?(Hash) ? target : {}
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

      def create_issue_command(project_id:, title:, user_message:, command_id: nil)
        {
          "command_id" => command_id,
          "type" => "CreateIssue",
          "payload" => {
            "project_id" => project_id,
            "title" => title,
            "description" => "Fake issue generated from user prompt:\n\n#{user_message}\n\nThe simple loop will ask the kernel to validate and apply this command before spawning the worker.",
            "parent_issue_id" => nil
          }
        }.compact
      end

      def spawn_worker_command(issue_id:, title:, user_message:, issue_from_command: nil, follow_up_of_agent_id: nil, replace_agent_id: nil)
        {
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => issue_id,
            "issue_from_command" => issue_from_command,
            "title" => title,
            "prompt" => "Work on issue '#{title}' from this user request:\n\n#{user_message}\n\nKeep the change focused and summarize what you did.",
            "workspace_path" => nil,
            "follow_up_of_agent_id" => follow_up_of_agent_id,
            "replace_agent_id" => replace_agent_id
          }.compact
        }
      end

      def prompt_worker_command(worker, user_message)
        {
          "type" => "PromptAgent",
          "payload" => {
            "agent_id" => worker.fetch("id"),
            "prompt" => user_message.to_s,
            "mode" => prompt_mode(worker, user_message)
          }
        }
      end

      def referenced_worker(snapshot, user_message)
        id = user_message.to_s[/\bP\d+-I\d+-W\d+\b/i]&.upcase
        snapshot.fetch("agents", []).find { |agent| agent.fetch("id", nil) == id && agent.fetch("type", nil) == "worker" }
      end

      def referenced_issue(snapshot, user_message)
        id = user_message.to_s[/\bP\d+-I\d+\b/i]&.upcase
        snapshot.fetch("issues", []).find { |issue| issue.fetch("id", nil) == id }
      end

      def referenced_project(snapshot, user_message)
        id = user_message.to_s[/\bP\d+\b/i]&.upcase
        snapshot.fetch("projects", []).find { |project| project.fetch("id", nil) == id }
      end

      def project_for_issue(snapshot, issue)
        return nil unless issue

        snapshot.fetch("projects", []).find { |project| project.fetch("id", nil) == issue.fetch("project_id", nil) }
      end

      def matching_issue(snapshot, user_message)
        issues = snapshot.fetch("issues", [])
        prompt_terms = routing_terms(user_message)
        scored = issues.map do |issue|
          issue_terms = routing_terms([issue.fetch("title", ""), issue.fetch("description", "")].join(" "))
          [prompt_terms.count { |term| issue_terms.include?(term) }, issue]
        end
        score, issue = scored.max_by { |candidate_score, candidate| [candidate_score, candidate.fetch("updated_at", "").to_s] }
        return issue if score.to_i.positive?
        return issues.max_by { |candidate| candidate.fetch("updated_at", candidate.fetch("created_at", "")).to_s } if follow_up_language?(user_message)

        nil
      end

      def routing_terms(text)
        stop_words = %w[a an and are for from i in is it of on that the this to we with you]
        text.to_s.downcase.scan(/[a-z0-9_]{3,}/).reject { |term| stop_words.include?(term) }.uniq
      end

      def follow_up_language?(text)
        text.to_s.match?(/\b(also|continue|follow[ -]?up|instead|it|that|those|why)\b/i)
      end

      def latest_worker(snapshot, issue_id)
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id
        end.max_by { |agent| [agent.fetch("updated_at", "").to_s, agent.fetch("id", "").to_s] }
      end

      def resumable_worker?(worker)
        return false unless worker
        return false if %w[killed errored].include?(worker.fetch("status", nil))

        worker.fetch("pid", nil) || worker.fetch("harness_session_id", nil) || worker.fetch("harness_session_file", nil)
      end

      def prompt_mode(worker, user_message)
        metadata = worker.fetch("harness_metadata", {}) || {}
        return "normal" unless metadata.fetch("is_streaming", false)
        return "steer" if user_message.to_s.match?(/\b(stop|actually|correction|don't|do not|wrong|urgent)\b/i)

        "follow_up"
      end

      def replacement_worker_id(worker)
        worker&.fetch("id", nil) if worker&.fetch("status", nil) == "errored"
      end

      def follow_up_worker_id(worker)
        return nil unless worker
        return nil if replacement_worker_id(worker)

        worker.fetch("id", nil)
      end

      def next_project_id(snapshot)
        next_number = snapshot.fetch("counters", {}).fetch("projects", max_project_number(snapshot)).to_i + 1
        "P#{next_number}"
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
