# frozen_string_literal: true

module Meringue
  module Heads
    class Context
      DEFAULT_KERNEL_COMMANDS_PATH = Meringue.root_path("docs", "head_agent_kernel_commands.md")
      ACTIVE_STATUSES = %w[queued working idle].freeze
      DISCOVERY_ALLOWED_COMMANDS = [
        "pwd",
        "ls",
        "find nearby project directories and .git folders",
        "rg project names, manifests, READMEs, and domain terms",
        "git rev-parse --show-toplevel",
        "git remote -v",
        "git status --short --branch",
        "read lightweight project files such as README.md, AGENTS.md, package.json, Gemfile, or pyproject.toml"
      ].freeze
      DISCOVERY_FORBIDDEN_COMMANDS = [
        "file edits or writes",
        "git checkout/switch/worktree/branch/pull/fetch/merge/rebase",
        "package installs or dependency upgrades",
        "generators, migrations, or formatters that write files",
        "production/staging, credential, database, or destructive commands"
      ].freeze

      ROUTING_ACTIVITY_LIMIT = 16
      ROUTING_CANDIDATE_LIMIT = 40
      ROUTING_TEXT_LIMIT = 2_000

      attr_reader :head_id, :user_message, :snapshot, :question_id,
                  :kernel_commands_path, :cwd, :state_path

      def initialize(head_id:, user_message:, snapshot:, question_id: nil,
                     kernel_commands_path: DEFAULT_KERNEL_COMMANDS_PATH, cwd: Dir.pwd,
                     state_path: State::Store.default_path)
        @head_id = head_id
        @user_message = user_message
        @snapshot = snapshot
        @question_id = question_id
        @kernel_commands_path = kernel_commands_path
        @cwd = File.expand_path(cwd)
        @state_path = File.expand_path(state_path)
      end

      def to_h
        to_prompt_h.merge("kernel_command_reference" => kernel_command_reference)
      end

      def to_prompt_h
        {
          "head_id" => head_id,
          "user_message" => user_message,
          "question_id" => question_id,
          "cwd" => cwd,
          "state_access" => state_access,
          "project_discovery" => project_discovery,
          "current_state_summary" => current_state_summary,
          "routing_context" => routing_context,
          "kernel_command_reference" => reference_metadata.merge(
            "appended_to_system_prompt" => true
          )
        }
      end

      def system_prompt
        <<~PROMPT
          You are a stateless Meringue head agent.
          Read the user message and return a HeadResult JSON object only.
          The prompt includes the Meringue state file path and read-only commands you may run when state details are necessary.
          Do not assume all state is embedded in the prompt; inspect only the parts of state you need.
          You may use tools to inspect local projects and git repositories before deciding, but discovery must be read-only and limited to routing/orchestration context.
          Do not investigate or answer the user's substantive task directly; create or reuse issues and spawn or prompt workers for investigation, implementation, and informational work.
          Treat the supplied routing context as candidate evidence, not a conversation database. Classify whether this message starts a new goal or follows an existing issue, then deliberately choose whether to prompt, follow up, or replace an existing worker.
          Prefer a healthy existing worker session when its Pi or other harness history contains the context needed for the follow-up. Do not duplicate that harness history in Meringue state.
          Do not mutate files, git state, dependencies, databases, remote services, or Meringue state directly.
          Propose kernel commands using the reference below.

          #{kernel_command_reference}
        PROMPT
      end

      def reference_metadata
        {
          "path" => kernel_commands_path,
          "bytes" => kernel_command_reference.bytesize,
          "lines" => kernel_command_reference.lines.count
        }
      end

      private

      def kernel_command_reference
        @kernel_command_reference ||= File.read(kernel_commands_path)
      rescue Errno::ENOENT
        raise ArgumentError, "Head kernel command reference not found: #{kernel_commands_path}"
      end

      def state_access
        {
          "state_path" => state_path,
          "read_only" => true,
          "guidance" => "The full Meringue state is intentionally not embedded. Read this file only when the user request requires current projects, issues, agents, questions, logs, counters, or prior PR URLs.",
          "suggested_commands" => [
            {
              "purpose" => "Read full JSON state when necessary.",
              "tool" => "read",
              "path" => state_path
            },
            {
              "purpose" => "Summarize projects, issues, agents, and open questions without printing full logs or harness metadata.",
              "tool" => "bash",
              "command" => state_summary_command
            }
          ]
        }
      end

      def current_state_summary
        {
          "project_count" => snapshot.fetch("projects", []).length,
          "issue_count" => snapshot.fetch("issues", []).length,
          "agent_count" => snapshot.fetch("agents", []).length,
          "open_question_count" => unresolved_questions.length,
          "active_head_count" => active_heads.length,
          "active_worker_count" => active_workers.length,
          "status_counts" => status_counts,
          "registered_projects" => registered_projects
        }
      end

      def routing_context
        {
          "purpose" => "Stateless routing hints assembled from existing issues, logs, and inspectable harness session metadata. These are not a separate conversation history.",
          "explicit_references" => explicit_references,
          "question_being_answered" => question_being_answered,
          "issue_candidates" => routing_issue_candidates,
          "worker_candidates" => routing_worker_candidates,
          "recent_activity" => recent_routing_activity,
          "decision_rules" => [
            "Explicit project, issue, worker, or question ids in the user message take precedence when they exist and are compatible.",
            "A refinement, correction, question about findings, or next step for an existing durable goal should reuse that issue.",
            "Prefer PromptAgent when a healthy worker on that issue has useful persisted harness context; do not spawn a new worker merely because this is a new user message.",
            "Use steer for an urgent correction to active work, follow_up for related work that should run after the active turn, and normal for a settled resumable session.",
            "Spawn a follow-up worker on the same issue only when no suitable session is resumable, work should be independent or parallel, context is known to be over 50%, or a delivered workspace should remain immutable.",
            "Use replace_agent_id only when the old worker is stale, unhealthy, pursuing the wrong approach, or must stop before a successor continues. Replacement starts the successor before killing the old session.",
            "Create a new issue only for a genuinely distinct durable goal. Ask a clarifying question instead of guessing between plausible issues or workers."
          ]
        }
      end

      def explicit_references
        mentioned_ids = user_message.to_s.scan(/\b(?:P\d+(?:-I\d+(?:-W\d+)?)?|H\d+|Q\d+)\b/i).map(&:upcase).uniq
        resolved_ids = mentioned_ids.flat_map { |id| [id, *parent_ids_for(id)] }.uniq
        known_state_ids = (
          snapshot.fetch("projects", []).map { |record| record["id"] } +
          snapshot.fetch("issues", []).map { |record| record["id"] } +
          snapshot.fetch("agents", []).map { |record| record["id"] } +
          snapshot.fetch("questions", []).map { |record| record["id"] }
        ).compact
        {
          "mentioned_ids" => mentioned_ids,
          "known_ids" => resolved_ids.select { |id| known_state_ids.include?(id) },
          "unknown_ids" => mentioned_ids.reject { |id| known_state_ids.include?(id) }
        }
      end

      def parent_ids_for(id)
        worker_match = id.match(/\A(P\d+)-(I\d+)-W\d+\z/)
        return [worker_match[1], "#{worker_match[1]}-#{worker_match[2]}"] if worker_match

        issue_match = id.match(/\A(P\d+)-I\d+\z/)
        issue_match ? [issue_match[1]] : []
      end

      def question_being_answered
        return nil unless question_id

        question = snapshot.fetch("questions", []).find { |candidate| candidate["id"] == question_id }
        question&.slice("id", "head_id", "project_id", "issue_id", "question", "context", "status", "answer", "created_at", "updated_at")
      end

      def routing_issue_candidates
        routing_candidates(snapshot.fetch("issues", [])).map do |issue|
          workers = workers_for_issue(issue.fetch("id", nil))
          {
            "id" => issue.fetch("id", nil),
            "project_id" => issue.fetch("project_id", nil),
            "parent_issue_id" => issue.fetch("parent_issue_id", nil),
            "title" => issue.fetch("title", nil),
            "description" => bounded_text(issue.fetch("description", nil)),
            "status" => issue.fetch("status", nil),
            "agent_ids" => workers.map { |worker| worker.fetch("id", nil) },
            "latest_agent_id" => workers.max_by { |worker| routing_sort_key(worker) }&.fetch("id", nil),
            "has_delivery_pull_request" => issue_delivery?(issue),
            "updated_at" => issue.fetch("updated_at", nil)
          }.compact
        end
      end

      def routing_worker_candidates
        workers = snapshot.fetch("agents", []).select { |agent| agent.fetch("type", nil) == "worker" }
        routing_candidates(workers).map do |agent|
          metadata = agent.fetch("harness_metadata", {}) || {}
          streaming = !!metadata.fetch("is_streaming", false)
          session_available = present_value?(agent.fetch("harness_session_id", nil)) ||
            present_value?(agent.fetch("harness_session_file", nil)) || present_value?(agent.fetch("pid", nil))
          {
            "id" => agent.fetch("id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "issue_id" => agent.fetch("issue_id", nil),
            "title" => metadata.fetch("title", nil),
            "status" => agent.fetch("status", nil),
            "harness" => agent.fetch("harness", nil),
            "harness_session_id" => agent.fetch("harness_session_id", nil),
            "harness_session_file" => agent.fetch("harness_session_file", nil),
            "is_streaming" => streaming,
            "session_available" => session_available,
            "resumable" => session_available && !%w[killed errored].include?(agent.fetch("status", nil)),
            "supported_prompt_modes_now" => supported_prompt_modes(agent, streaming: streaming, session_available: session_available),
            "recommended_prompt_mode" => recommended_prompt_mode(agent, streaming: streaming, session_available: session_available),
            "prompt_count" => metadata.fetch("prompt_count", 0).to_i,
            "last_prompt_mode" => metadata.fetch("last_prompt_mode", nil),
            "context_utilization" => context_utilization(metadata),
            "last_result" => bounded_text(metadata.fetch("last_assistant_text", nil)),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "has_delivery_pull_request" => issue_delivery?(issue_for_agent(agent)),
            "follow_up_of_agent_id" => agent.fetch("follow_up_of_agent_id", nil),
            "replaces_agent_id" => agent.fetch("replaces_agent_id", nil),
            "replaced_by_agent_id" => agent.fetch("replaced_by_agent_id", nil),
            "created_at" => agent.fetch("created_at", nil),
            "updated_at" => agent.fetch("updated_at", nil)
          }.compact
        end
      end

      def routing_candidates(records)
        sorted = records.sort_by { |record| routing_sort_key(record) }.reverse
        referenced = explicit_references.fetch("known_ids")
        explicit_records = sorted.select { |record| referenced.include?(record.fetch("id", nil)) }
        (explicit_records + sorted.first(ROUTING_CANDIDATE_LIMIT)).uniq { |record| record.fetch("id", nil) }
      end

      def recent_routing_activity
        snapshot.fetch("logs", []).last(ROUTING_ACTIVITY_LIMIT).map do |log|
          {
            "id" => log.fetch("id", nil),
            "timestamp" => log.fetch("timestamp", nil),
            "source_type" => log.fetch("source_type", nil),
            "source_id" => log.fetch("source_id", nil),
            "level" => log.fetch("level", nil),
            "message" => bounded_text(log.fetch("message", nil)),
            "routing" => routing_log_details(log.fetch("details", nil))
          }.compact
        end
      end

      def routing_log_details(details)
        return nil unless details.is_a?(Hash)

        details.slice(
          "head_id", "question_id", "project_id", "issue_id", "agent_id", "target_id",
          "mode", "routing_action", "follow_up_of_agent_id", "replaces_agent_id", "replaced_by_agent_id"
        ).compact
      end

      def workers_for_issue(issue_id)
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id
        end
      end

      def issue_for_agent(agent)
        snapshot.fetch("issues", []).find { |issue| issue.fetch("id", nil) == agent.fetch("issue_id", nil) }
      end

      def issue_delivery?(issue)
        return false unless issue.is_a?(Hash)

        present_value?(issue.fetch("delivery_pull_request", nil)) || Array(issue.fetch("delivery_pull_requests", [])).any?
      end

      def supported_prompt_modes(agent, streaming:, session_available:)
        return [] unless session_available
        return [] if %w[killed errored].include?(agent.fetch("status", nil))

        if streaming
          agent.fetch("harness", nil) == "pi" ? %w[steer follow_up] : []
        else
          ["normal"]
        end
      end

      def recommended_prompt_mode(agent, streaming:, session_available:)
        modes = supported_prompt_modes(agent, streaming: streaming, session_available: session_available)
        return nil if modes.empty?

        streaming ? "follow_up" : "normal"
      end

      def context_utilization(metadata)
        value = metadata.fetch("context_utilization", nil) || metadata.dig("pi_state", "contextUtilization")
        value&.to_f
      end

      def routing_sort_key(record)
        [record.fetch("updated_at", "").to_s, record.fetch("created_at", "").to_s, record.fetch("id", "").to_s]
      end

      def bounded_text(value)
        text = value.to_s.strip
        return nil if text.empty?
        return text if text.length <= ROUTING_TEXT_LIMIT

        "#{text[0, ROUTING_TEXT_LIMIT]}…"
      end

      def present_value?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def state_summary_command
        <<~COMMAND.strip
          ruby -rjson -e 's=JSON.parse(File.read(ARGV.fetch(0))); puts JSON.pretty_generate({projects:s.fetch("projects",[]).map{|p|p.slice("id","name","root_path","status")}, issues:s.fetch("issues",[]).map{|i|i.slice("id","project_id","title","status","agent_ids")}, agents:s.fetch("agents",[]).map{|a|a.slice("id","type","status","project_id","issue_id","workspace_path","workspace_branch","harness")}, open_questions:s.fetch("questions",[]).select{|q|q["status"]=="open"}.map{|q|q.slice("id","head_id","project_id","issue_id","question","status")}, counters:s.fetch("counters",{})})' #{state_path.inspect}
        COMMAND
      end

      def active_heads
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "head" && ACTIVE_STATUSES.include?(agent.fetch("status", nil))
        end
      end

      def active_workers
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "worker" && ACTIVE_STATUSES.include?(agent.fetch("status", nil))
        end
      end

      def unresolved_questions
        snapshot.fetch("questions", []).select do |question|
          question.fetch("status", nil) == "open"
        end
      end

      def project_discovery
        {
          "responsibility" => "The head discovers local projects and proposes AddProject when needed; the kernel only validates and mutates state.",
          "starting_points" => discovery_starting_points,
          "registered_projects" => registered_projects,
          "allowed_read_only_discovery" => DISCOVERY_ALLOWED_COMMANDS,
          "forbidden_discovery" => DISCOVERY_FORBIDDEN_COMMANDS,
          "current_directory" => current_directory_metadata,
          "candidate_search_roots" => candidate_search_roots,
          "decision_rules" => [
            "Prefer a registered project when the id, name, root_path, git root, or remote clearly matches the request.",
            "For phrases like this project, current project, here, or this repo, prefer the current_directory.git_root when present; otherwise use cwd.",
            "If the preferred local repository is not registered, propose AddProject with its absolute root before CreateIssue or SpawnWorker.",
            "Before proposing CreateIssue, inspect existing issues in the chosen project. If the prompt is a follow-up, refinement, or next step for an existing issue, reuse that issue and propose SpawnWorker only.",
            "Do not investigate or answer substantive task content yourself. Route implementation, investigation, and informational work through CreateIssue/SpawnWorker or PromptAgent as appropriate.",
            "Use the HeadResult summary to describe routing decisions, not to deliver the worker's substantive answer.",
            "Do not create nested/subissues for ordinary follow-up prompts; keep parent_issue_id null unless the user explicitly asks for a child issue hierarchy.",
            "Always include a short action-oriented title in SpawnWorker payloads so workers render clearly under their issue in the AgentTree.",
            "When chaining AddProject with CreateIssue and SpawnWorker in one HeadResult, read state counters when necessary and compute the future project id from counters.projects or the max existing P<number>.",
            "If the app was launched outside the target project, use registered projects and candidate_search_roots to inspect likely local repositories by name/path before choosing.",
            "Ask a clarifying question when multiple repositories are plausible."
          ]
        }
      end

      def registered_projects
        snapshot.fetch("projects", []).map do |project|
          {
            "id" => project.fetch("id", nil),
            "name" => project.fetch("name", nil),
            "root_path" => project.fetch("root_path", nil),
            "status" => project.fetch("status", nil)
          }
        end
      end

      def current_directory_metadata
        git_root = nearest_git_root(cwd)
        default_root = git_root || cwd
        {
          "cwd" => cwd,
          "git_root" => git_root,
          "default_project_root" => default_root,
          "default_project_name" => File.basename(default_root),
          "registered_project_id" => registered_project_id_for(default_root),
          "should_propose_add_project_for_current_directory" => registered_project_id_for(default_root).nil?
        }
      end

      def candidate_search_roots
        env_roots = ENV.fetch("MERINGUE_PROJECT_ROOTS", "").split(File::PATH_SEPARATOR)
        common_roots = [
          "~/slaade/Projects",
          "~/Projects",
          "~/Developer",
          "~/code",
          "~/src"
        ]

        (discovery_starting_points + env_roots + common_roots)
          .compact
          .map(&:to_s)
          .reject(&:empty?)
          .map { |path| File.expand_path(path) }
          .select { |path| Dir.exist?(path) }
          .uniq
      end

      def registered_project_id_for(path)
        expanded_path = File.expand_path(path.to_s)
        snapshot.fetch("projects", []).find do |project|
          root_path = project.fetch("root_path", nil).to_s
          next false if root_path.empty?

          File.expand_path(root_path) == expanded_path
        end&.fetch("id", nil)
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

      def discovery_starting_points
        ([cwd, nearest_git_root(cwd)] + snapshot.fetch("projects", []).map { |project| project.fetch("root_path", nil) })
          .compact
          .map(&:to_s)
          .reject(&:empty?)
          .uniq
      end

      def status_counts
        snapshot.fetch("agents", []).each_with_object(Hash.new(0)) do |agent, counts|
          counts[agent.fetch("status", "unknown")] += 1
        end
      end
    end
  end
end
