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
          "project_discovery" => project_discovery,
          "kernel_state" => snapshot,
          "agent_tree" => agent_tree,
          "active_heads" => active_heads,
          "active_workers" => active_workers,
          "unresolved_questions" => unresolved_questions,
          "kernel_command_reference" => reference_metadata.merge(
            "appended_to_system_prompt" => true
          )
        }
      end

      def system_prompt
        <<~PROMPT
          You are a stateless Meringue head agent.
          Read the user message, inspect the supplied Meringue snapshot, and return a HeadResult JSON object only.
          You may use tools to inspect local projects and git repositories before deciding, but discovery must be read-only.
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

      def agent_tree
        {
          "projects" => snapshot.fetch("projects", []),
          "issues" => snapshot.fetch("issues", []),
          "agents" => snapshot.fetch("agents", []),
          "questions" => snapshot.fetch("questions", []),
          "status_counts" => status_counts
        }
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
          "registered_projects" => snapshot.fetch("projects", []).map do |project|
            {
              "id" => project.fetch("id", nil),
              "name" => project.fetch("name", nil),
              "root_path" => project.fetch("root_path", nil),
              "status" => project.fetch("status", nil)
            }
          end,
          "allowed_read_only_discovery" => DISCOVERY_ALLOWED_COMMANDS,
          "forbidden_discovery" => DISCOVERY_FORBIDDEN_COMMANDS,
          "current_directory" => current_directory_metadata,
          "candidate_search_roots" => candidate_search_roots,
          "decision_rules" => [
            "Prefer a registered project when the id, name, root_path, git root, or remote clearly matches the request.",
            "For phrases like this project, current project, here, or this repo, prefer the current_directory.git_root when present; otherwise use cwd.",
            "If the preferred local repository is not registered, propose AddProject with its absolute root before CreateIssue or SpawnWorker.",
            "When chaining AddProject with CreateIssue and SpawnWorker in one HeadResult, compute the future project id from kernel_state.counters.projects or the max existing P<number>.",
            "If the app was launched outside the target project, use registered projects and candidate_search_roots to inspect likely local repositories by name/path before choosing.",
            "Ask a clarifying question when multiple repositories are plausible."
          ]
        }
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
