# frozen_string_literal: true

module Meringue
  module Heads
    class FakeRunner < Runner
      # Symbolic id for the CreateIssue command in a generated batch. A worker for a
      # brand-new issue references this command instead of predicting the issue id.
      ISSUE_COMMAND_ID = "create-issue"

      def run(user_message:, snapshot:, context: nil, question_id: nil)
        routing = build_commands(user_message: user_message, snapshot: snapshot, context: context)
        commands = routing.fetch("commands")

        {
          "title" => title_from(user_message),
          "summary" => "Fake head proposed #{commands.length} deterministic kernel command(s): reuse the best issue and worker session when possible.",
          "commands" => commands,
          "questions" => routing.fetch("questions")
        }
      end

      private

      def build_commands(user_message:, snapshot:, context:)
        commands = []
        maintenance = maintenance_commands(user_message: user_message, snapshot: snapshot)
        return { "commands" => maintenance, "questions" => [] } if maintenance

        selected_target = selected_target_from(context)
        selected_issue = snapshot.fetch("issues", []).find do |issue|
          issue.fetch("id", nil).to_s == selected_target.fetch("issue_id", nil).to_s
        end
        selected_worker = snapshot.fetch("agents", []).find do |agent|
          agent.fetch("id", nil).to_s == selected_target.fetch("selected_agent_id", nil).to_s &&
            agent.fetch("issue_id", nil).to_s == selected_issue&.fetch("id", nil).to_s
        end
        if resumable_worker?(selected_worker)
          return { "commands" => [prompt_worker_command(selected_worker, user_message)], "questions" => [] }
        end

        explicit_worker = referenced_worker(snapshot, user_message) unless selected_issue
        if resumable_worker?(explicit_worker)
          return { "commands" => [prompt_worker_command(explicit_worker, user_message)], "questions" => [] }
        end

        explicit_issue = selected_issue || referenced_issue(snapshot, user_message)
        route = project_route(snapshot, user_message, context, explicit_issue)
        if route.fetch("ambiguous")
          return {
            "commands" => [],
            "questions" => [project_clarification_question(user_message, route.fetch("candidates"))]
          }
        end

        project = route.fetch("project")
        project_id = project&.fetch("id", nil)
        unless project_id
          project_id = next_project_id(snapshot)
          commands << add_project_command(context)
        end

        existing_issue = explicit_issue || matching_issue(
          snapshot,
          user_message,
          project_id: project_id,
          allow_recent_fallback: !route.fetch("request_identified")
        )
        existing_issue = nil if existing_issue && existing_issue.fetch("project_id", nil) != project_id
        title = title_from(user_message)

        if existing_issue
          issue_id = existing_issue.fetch("id")
          prior_worker = latest_worker(snapshot, issue_id)
          if resumable_worker?(prior_worker)
            commands << prompt_worker_command(prior_worker, user_message)
            return { "commands" => commands, "questions" => [] }
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
        { "commands" => commands, "questions" => [] }
      end

      def selected_target_from(context)
        return {} unless context&.respond_to?(:to_prompt_h)

        target = context.to_prompt_h.dig("routing_context", "selected_target")
        target.is_a?(Hash) ? target : {}
      end

      # Housekeeping requests map onto the user slash commands the kernel already owns instead of
      # creating an issue and spawning a worker. The patterns stay deliberately narrow so ordinary
      # work prompts ("clean up the signup code") still route to a worker.
      def maintenance_commands(user_message:, snapshot:)
        message = user_message.to_s
        return [command("ClearState", "confirmed_by_user" => true)] if clear_state_request?(message)
        target = referenced_record_id(snapshot, message)
        if target && message.match?(/\b(unprotect|allow\s+prun)/i)
          return [command("SetAgentPruneProtection", "agent_id" => target, "protected" => false)]
        end
        if target && message.match?(/\bprotect\b/i)
          return [command("SetAgentPruneProtection", "agent_id" => target, "protected" => true)]
        end
        return [command("Prune")] if prune_request?(message)
        return [command("Recount")] if message.match?(/\b(recount|renumber)\b/i)

        return [command("Kill", "target_id" => target, "confirmed_by_user" => true)] if target && kill_request?(message)
        return [command("GetInfo", "target_id" => target)] if target && info_request?(message)

        nil
      end

      def clear_state_request?(message)
        message.match?(/\b(clear|reset|wipe|erase|nuke|purge)\b[^.!?\n]{0,40}?\b(state|everything|meringue|agent[\s_-]?tree|agenttree|logs|slate|board)\b/i)
      end

      def prune_request?(message)
        return true if message.match?(/\bprune\b/i)

        message.match?(/\b(clean\s*up|clear|remove|delete|tidy)\b[^.!?\n]{0,40}?\b(merged|completed|resolved|finished|done|errored|killed|stale|old)\b[^.!?\n]{0,20}?\b(issues?|records?|agents?|workers?|projects?|work)\b/i)
      end

      def kill_request?(message)
        message.match?(/\b(kill|terminate|abort|shut\s*down|shutdown|halt)\b/i)
      end

      def info_request?(message)
        message.match?(/\b(what\s+is|what's|whats|status\s+of|info\s+(on|about|for)|details?\s+(on|about|for)|tell\s+me\s+about|describe)\b/i)
      end

      def referenced_record_id(snapshot, message)
        candidate = message[/\bP\d+(?:-I\d+(?:-W\d+)?)?\b/i]&.upcase
        candidate ||= message[/\bQ\d+\b/i]&.upcase
        return nil unless candidate

        known = snapshot.fetch("agents", []).map { |agent| agent.fetch("id", nil) } +
                snapshot.fetch("issues", []).map { |issue| issue.fetch("id", nil) } +
                snapshot.fetch("projects", []).map { |project| project.fetch("id", nil) } +
                snapshot.fetch("questions", []).map { |question| question.fetch("id", nil) }
        known.compact.include?(candidate) ? candidate : nil
      end

      def command(type, payload = {})
        { "type" => type, "payload" => payload }
      end

      def add_project_command(context)
        project_root = default_project_root(context&.cwd || Dir.pwd)
        # Re-read the repository's canonical name at command construction time. Do not
        # derive a project name from the request title or stale routing metadata.
        suggested_name = Meringue::ProjectNaming.name_for(project_root)

        {
          "type" => "AddProject",
          "payload" => {
            "path" => project_root,
            "name" => suggested_name
          }.compact
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

      def project_route(snapshot, user_message, context, explicit_issue)
        return {
          "project" => project_for_issue(snapshot, explicit_issue),
          "request_identified" => true,
          "ambiguous" => false,
          "candidates" => []
        } if explicit_issue

        explicit_project = referenced_project(snapshot, user_message)
        if explicit_project
          return {
            "project" => explicit_project,
            "request_identified" => true,
            "ambiguous" => false,
            "candidates" => []
          }
        end

        candidates = matching_project_candidates(snapshot, user_message, context)
        if candidates.any?
          top_score = candidates.first.fetch("score")
          top = candidates.take_while { |candidate| candidate.fetch("score") == top_score }
          return {
            "project" => top.first.fetch("project"),
            "request_identified" => true,
            "ambiguous" => false,
            "candidates" => top.map { |candidate| candidate.fetch("project") }
          } if top.length == 1

          return {
            "project" => nil,
            "request_identified" => true,
            "ambiguous" => true,
            "candidates" => top.map { |candidate| candidate.fetch("project") }
          }
        end

        current_project = current_project(snapshot, context)
        if current_project
          return {
            "project" => current_project,
            "request_identified" => false,
            "ambiguous" => false,
            "candidates" => []
          }
        end

        projects = snapshot.fetch("projects", [])
        return {
          "project" => projects.first,
          "request_identified" => false,
          "ambiguous" => false,
          "candidates" => []
        } if projects.length == 1

        return {
          "project" => nil,
          "request_identified" => false,
          "ambiguous" => false,
          "candidates" => []
        } if projects.empty?

        {
          "project" => nil,
          "request_identified" => false,
          "ambiguous" => true,
          "candidates" => projects
        }
      end

      def matching_project_candidates(snapshot, user_message, context)
        projects = snapshot.fetch("projects", []).map { |project| [project, false] }
        local_project = current_local_project(context)
        if local_project && !projects.any? { |project, _| same_project_root?(project, local_project) }
          projects << [local_project, true]
        end

        prompt_terms = routing_terms(user_message)
        projects.filter_map do |project, _local|
          project_name = Meringue::ProjectNaming.canonical_name(project.fetch("name", ""))
          repository_name = Meringue::ProjectNaming.canonical_name(File.basename(project.fetch("root_path", "")))
          project_terms = routing_terms([project_name, repository_name].compact.join(" "))
          score = prompt_terms.count { |term| project_terms.include?(term) }
          score.positive? ? { "score" => score, "project" => project } : nil
        end.sort_by do |candidate|
          project = candidate.fetch("project")
          [-candidate.fetch("score"), project.fetch("id", "").to_s, project.fetch("name", "").to_s]
        end
      end

      def current_project(snapshot, context)
        local_project = current_local_project(context)
        return nil unless local_project

        snapshot.fetch("projects", []).find { |project| same_project_root?(project, local_project) }
      end

      def current_local_project(context)
        return nil unless context&.respond_to?(:cwd)

        root = default_project_root(context.cwd)
        return nil unless File.directory?(root)
        return nil unless File.exist?(File.join(root, ".git"))

        {
          "id" => nil,
          "name" => Meringue::ProjectNaming.name_for(root),
          "root_path" => root,
          "status" => "working",
          "updated_at" => ""
        }
      end

      def same_project_root?(left, right)
        left_root = left.fetch("root_path", nil).to_s
        right_root = right.fetch("root_path", nil).to_s
        !left_root.empty? && !right_root.empty? && File.expand_path(left_root) == File.expand_path(right_root)
      end

      def project_clarification_question(user_message, candidates)
        choices = candidates.map do |project|
          label = project.fetch("name", nil).to_s.strip
          path = project.fetch("root_path", nil).to_s.strip
          label = path if label.empty?
          path.empty? || path == label ? label : "#{label} (#{path})"
        end.uniq

        {
          "question" => "Which project should receive #{user_message.to_s.inspect}? Choose one of: #{choices.join(", ")}",
          "context" => "The request did not identify one project clearly enough, and recent issue activity is not safe routing evidence."
        }
      end

      def matching_issue(snapshot, user_message, project_id: nil, allow_recent_fallback: true)
        issues = snapshot.fetch("issues", [])
        issues = issues.select { |issue| issue.fetch("project_id", nil) == project_id } if project_id
        prompt_terms = routing_terms(user_message)
        scored = issues.map do |issue|
          issue_terms = routing_terms([issue.fetch("title", ""), issue.fetch("description", "")].join(" "))
          [prompt_terms.count { |term| issue_terms.include?(term) }, issue]
        end
        score, issue = scored.max_by { |candidate_score, candidate| [candidate_score, candidate.fetch("updated_at", "").to_s] }
        return issue if score.to_i.positive?
        return issues.max_by { |candidate| candidate.fetch("updated_at", candidate.fetch("created_at", "")).to_s } if allow_recent_fallback && follow_up_language?(user_message)

        nil
      end

      def routing_terms(text)
        stop_words = %w[
          a an and are as at be by completed complete done for from i in is it of on or
          that the this to we with you add change clean cleanup completed fix fixed improve
          implement implementation update updated work
        ]
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
