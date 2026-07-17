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

      attr_reader :head_id, :user_message, :snapshot, :question_id,
                  :kernel_commands_path, :cwd

      def initialize(head_id:, user_message:, snapshot:, question_id: nil,
                     kernel_commands_path: DEFAULT_KERNEL_COMMANDS_PATH, cwd: Dir.pwd)
        @head_id = head_id
        @user_message = user_message
        @snapshot = snapshot
        @question_id = question_id
        @kernel_commands_path = kernel_commands_path
        @cwd = File.expand_path(cwd)
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

      def state_path
        State::Store.default_path
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
