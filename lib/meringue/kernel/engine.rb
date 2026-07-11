# frozen_string_literal: true

require "time"

module Meringue
  module Kernel
    class Engine
      WORKER_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue worker agent. Work only on the assigned issue and workspace.
        Follow the user's prompt and the repository instructions in your working directory.
      PROMPT

      COMMAND_ALIASES = {
        "add_project" => "AddProject",
        "create_issue" => "CreateIssue",
        "spawn_worker" => "SpawnWorker",
        "list_all" => "ListAll"
      }.freeze

      attr_reader :store, :harness_client, :head_runner, :workspace_manager

      def initialize(store: State::Store.new, harness_client: Harness::FakeClient.new,
                     head_runner: Heads::FakeRunner.new,
                     workspace_manager: Workspace::Manager.new)
        @store = store
        @harness_client = harness_client
        @head_runner = head_runner
        @workspace_manager = workspace_manager
      end

      def list_all
        store.load
      end

      def apply(command)
        normalized = normalize_command(command)
        command_type = normalized.fetch("type", nil)
        command_id = normalized.fetch("command_id", nil)
        payload = normalized.fetch("payload", {})

        return rejected_result(command_id, nil, "Kernel command is missing a type.", ["missing_type"]) if blank?(command_type)

        command_type = canonical_command_type(command_type)

        case command_type
        when "ListAll"
          accepted_result(command_id, command_type, nil, "Loaded Meringue state.", store.load, [])
        when "AddProject"
          add_project(command_id, command_type, payload)
        when "CreateIssue"
          create_issue(command_id, command_type, payload)
        when "SpawnWorker"
          spawn_worker(command_id, command_type, payload)
        else
          rejected_result(
            command_id,
            command_type,
            "Unknown kernel command: #{command_type}",
            ["unknown_command"]
          )
        end
      rescue StandardError => e
        failed_result(
          command_id,
          command_type || "Unknown",
          "Kernel command failed: #{e.message}",
          [e.class.name, e.message]
        )
      end

      def apply_all(commands)
        Array(commands).map { |command| apply(command) }
      end

      private

      def add_project(command_id, command_type, payload)
        root_path = value_at(payload, "path", "Path", "root_path", "RootPath")
        name = value_at(payload, "name", "Name")
        errors = []

        errors << "path is required" if blank?(root_path)
        expanded_path = File.expand_path(root_path.to_s) unless blank?(root_path)
        errors << "path must be an existing directory" if expanded_path && !Dir.exist?(expanded_path)
        return rejected_result(command_id, command_type, "Project was not added.", errors) unless errors.empty?

        state = normalized_state
        if state.fetch("projects").any? { |project| File.expand_path(project.fetch("root_path")) == expanded_path }
          return rejected_result(command_id, command_type, "Project is already registered.", ["project_already_exists"])
        end

        now = timestamp
        project_id = next_project_id!(state)
        project = {
          "id" => project_id,
          "name" => present_string(name) || default_project_name(expanded_path),
          "root_path" => expanded_path,
          "status" => "working",
          "created_at" => now,
          "updated_at" => now
        }

        state.fetch("projects") << project
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: project_id,
          level: "info",
          message: "Added project #{project_id}: #{project.fetch("name")}",
          details: { "root_path" => expanded_path }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, project_id, "Added project #{project_id}.", project, log_ids)
      end

      def create_issue(command_id, command_type, payload)
        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        title = value_at(payload, "title", "Title")
        description = value_at(payload, "description", "Description") || ""
        parent_issue_id = value_at(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
        status = value_at(payload, "status", "Status") || "queued"
        errors = []

        errors << "project_id is required" if blank?(project_id)
        errors << "title is required" if blank?(title)
        errors << "status must be one of #{State::Models::LIFECYCLE_STATUSES.join(", ")}" unless State::Models::LIFECYCLE_STATUSES.include?(status.to_s)
        return rejected_result(command_id, command_type, "Issue was not created.", errors) unless errors.empty?

        state = normalized_state
        project = find_project(state, project_id)
        return rejected_result(command_id, command_type, "Project #{project_id} does not exist.", ["project_not_found"]) unless project

        if present_string(parent_issue_id)
          parent = find_issue(state, parent_issue_id)
          unless parent && parent.fetch("project_id") == project.fetch("id")
            return rejected_result(command_id, command_type, "Parent issue #{parent_issue_id} does not exist in #{project.fetch("id")}.", ["parent_issue_not_found"])
          end
        end

        now = timestamp
        issue_id = next_issue_id!(state, project.fetch("id"))
        issue = {
          "id" => issue_id,
          "project_id" => project.fetch("id"),
          "parent_issue_id" => present_string(parent_issue_id),
          "title" => title.to_s.strip,
          "description" => description.to_s,
          "status" => status.to_s,
          "agent_ids" => [],
          "created_at" => now,
          "updated_at" => now
        }

        state.fetch("issues") << issue
        project["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: issue_id,
          level: "info",
          message: "Created issue #{issue_id}: #{issue.fetch("title")}",
          details: { "project_id" => project.fetch("id"), "parent_issue_id" => issue.fetch("parent_issue_id") }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, issue_id, "Created issue #{issue_id}.", issue, log_ids)
      end

      def spawn_worker(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        prompt = value_at(payload, "prompt", "Prompt")
        requested_workspace_path = value_at(payload, "workspace_path", "WorkspacePath", "workspacePath")
        errors = []

        errors << "issue_id is required" if blank?(issue_id)
        errors << "prompt is required" if blank?(prompt)
        return rejected_result(command_id, command_type, "Worker was not spawned.", errors) unless errors.empty?

        state = normalized_state
        issue = find_issue(state, issue_id)
        return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) unless issue

        project = find_project(state, issue.fetch("project_id"))
        return rejected_result(command_id, command_type, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

        workspace = resolve_worker_workspace(
          project: project,
          issue: issue,
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: preview_worker_id(state, issue.fetch("id"))
        )
        return rejected_result(command_id, command_type, "Worker workspace is invalid.", workspace.fetch("errors")) unless workspace.fetch("errors").empty?

        now = timestamp
        agent_id = next_worker_id!(state, issue.fetch("id"))
        workspace = resolve_worker_workspace(
          project: project,
          issue: issue,
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: agent_id
        )
        session_ref = nil

        begin
          session_ref = harness_client.spawn_session(
            kind: "worker",
            cwd: workspace.fetch("workspace_path"),
            prompt: prompt.to_s,
            system_prompt: worker_system_prompt(issue),
            session_name: worker_session_name(agent_id, issue)
          )
        rescue StandardError => e
          decrement_worker_counter!(state, issue.fetch("id"))
          return failed_result(
            command_id,
            command_type,
            "Harness failed to spawn worker #{agent_id}: #{e.message}",
            [e.class.name, e.message]
          )
        end

        agent = build_worker_agent(
          agent_id: agent_id,
          issue: issue,
          project: project,
          workspace: workspace,
          session_ref: session_ref,
          now: now
        )

        state.fetch("agents") << agent
        issue.fetch("agent_ids") << agent_id
        issue["status"] = "working"
        issue["updated_at"] = now
        project["status"] = "working"
        project["updated_at"] = now

        log_ids = []
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "info",
          message: "Spawned worker #{agent_id} for #{issue.fetch("id")}",
          details: {
            "issue_id" => issue.fetch("id"),
            "project_id" => project.fetch("id"),
            "workspace_path" => agent.fetch("workspace_path"),
            "workspace_strategy" => agent.fetch("workspace_strategy")
          }
        ))
        log_ids.concat(append_log(
          state,
          source_type: "harness",
          source_id: agent_id,
          level: "info",
          message: "Started #{agent.fetch("harness")} session for #{agent_id}",
          details: {
            "pid" => agent.fetch("pid"),
            "harness_session_id" => agent.fetch("harness_session_id"),
            "harness_session_file" => agent.fetch("harness_session_file"),
            "is_streaming" => agent.fetch("harness_metadata").fetch("is_streaming", nil)
          }
        ))
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, agent_id, "Spawned worker #{agent_id}.", agent, log_ids)
      rescue StandardError => e
        kill_session_safely(session_ref) if session_ref
        raise e
      end

      def build_worker_agent(agent_id:, issue:, project:, workspace:, session_ref:, now:)
        session_metadata = session_ref.fetch("metadata", {}) || {}
        {
          "id" => agent_id,
          "type" => "worker",
          "status" => "working",
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "workspace_path" => workspace.fetch("workspace_path"),
          "workspace_strategy" => workspace.fetch("workspace_strategy"),
          "workspace_branch" => workspace.fetch("workspace_branch"),
          "harness" => session_ref.fetch("harness", nil),
          "pid" => session_ref.fetch("pid", nil),
          "harness_session_id" => session_ref.fetch("session_id", nil),
          "harness_session_file" => session_ref.fetch("session_file", nil),
          "harness_metadata" => session_metadata.merge(
            "cwd" => session_ref.fetch("cwd", workspace.fetch("workspace_path")),
            "is_streaming" => session_ref.fetch("is_streaming", false),
            "last_event_at" => session_ref.fetch("last_event_at", nil),
            "workspace_note" => workspace.fetch("note", nil),
            "workspace_plan" => workspace.fetch("plan", nil)
          ).compact,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def resolve_worker_workspace(project:, issue:, requested_workspace_path:, preview_agent_id:)
        if present_string(requested_workspace_path)
          expanded_path = File.expand_path(requested_workspace_path.to_s)
          errors = Dir.exist?(expanded_path) ? [] : ["workspace_path must be an existing directory"]
          strategy = same_path?(expanded_path, project.fetch("root_path")) ? "project_root" : "dedicated_directory"

          return {
            "workspace_path" => expanded_path,
            "workspace_strategy" => strategy,
            "workspace_branch" => nil,
            "plan" => nil,
            "note" => nil,
            "errors" => errors
          }
        end

        plan = workspace_manager.plan_worker_workspace(
          project_root: project.fetch("root_path"),
          project_id: project.fetch("id"),
          issue_id: issue.fetch("id"),
          agent_id: preview_agent_id
        )

        if plan.fetch("created", false) && Dir.exist?(plan.fetch("workspace_path"))
          return {
            "workspace_path" => File.expand_path(plan.fetch("workspace_path")),
            "workspace_strategy" => plan.fetch("strategy"),
            "workspace_branch" => plan.fetch("workspace_branch"),
            "plan" => plan,
            "note" => nil,
            "errors" => []
          }
        end

        {
          "workspace_path" => File.expand_path(project.fetch("root_path")),
          "workspace_strategy" => "project_root",
          "workspace_branch" => nil,
          "plan" => plan,
          "note" => "Workspace manager only planned a git worktree; real worktree creation is deferred, so the worker uses the project root cwd.",
          "errors" => Dir.exist?(project.fetch("root_path")) ? [] : ["project root must be an existing directory"]
        }
      end

      def worker_system_prompt(issue)
        <<~PROMPT
          #{WORKER_SYSTEM_PROMPT}

          Assigned issue:
          #{issue.fetch("id")} - #{issue.fetch("title")}

          Issue description:
          #{issue.fetch("description")}
        PROMPT
      end

      def worker_session_name(agent_id, issue)
        title = issue.fetch("title").to_s.strip.gsub(/\s+/, " ")
        title = "worker" if title.empty?
        "#{agent_id} #{title}"[0, 96]
      end

      def normalized_state
        state = store.load
        ensure_state_shape!(state)
        state
      end

      def ensure_state_shape!(state)
        state["schema_version"] ||= State::Models::SCHEMA_VERSION
        state["projects"] ||= []
        state["issues"] ||= []
        state["agents"] ||= []
        state["questions"] ||= []
        state["logs"] ||= []
        state["counters"] ||= {}
        state["counters"]["projects"] ||= max_numeric_suffix(state.fetch("projects"), /^P(\d+)$/)
        state["counters"]["heads"] ||= max_numeric_suffix(state.fetch("agents").select { |agent| agent["type"] == "head" }, /^H(\d+)$/)
        state["counters"]["questions"] ||= max_numeric_suffix(state.fetch("questions"), /^Q(\d+)$/)
        state["counters"]["logs"] ||= max_numeric_suffix(state.fetch("logs"), /^L(\d+)$/)
        state["counters"]["issues_by_project"] ||= {}
        state["counters"]["workers_by_issue"] ||= {}
        state["metadata"] ||= {}
        state["metadata"]["created_at"] ||= timestamp
        state["metadata"]["updated_at"] ||= state["metadata"].fetch("created_at")
      end

      def max_numeric_suffix(records, pattern)
        records.filter_map do |record|
          match = record.fetch("id", "").match(pattern)
          match && match[1].to_i
        end.max || 0
      end

      def next_project_id!(state)
        state.fetch("counters")["projects"] = state.fetch("counters").fetch("projects", 0).to_i + 1
        "P#{state.fetch("counters").fetch("projects")}"
      end

      def next_issue_id!(state, project_id)
        counters = state.fetch("counters").fetch("issues_by_project")
        counters[project_id] ||= max_issue_number(state, project_id)
        counters[project_id] = counters.fetch(project_id).to_i + 1
        "#{project_id}-I#{counters.fetch(project_id)}"
      end

      def preview_worker_id(state, issue_id)
        counters = state.fetch("counters").fetch("workers_by_issue")
        next_number = (counters[issue_id] || max_worker_number(state, issue_id)).to_i + 1
        "#{issue_id}-W#{next_number}"
      end

      def next_worker_id!(state, issue_id)
        counters = state.fetch("counters").fetch("workers_by_issue")
        counters[issue_id] ||= max_worker_number(state, issue_id)
        counters[issue_id] = counters.fetch(issue_id).to_i + 1
        "#{issue_id}-W#{counters.fetch(issue_id)}"
      end

      def decrement_worker_counter!(state, issue_id)
        counters = state.fetch("counters").fetch("workers_by_issue")
        return unless counters[issue_id]

        counters[issue_id] = [counters.fetch(issue_id).to_i - 1, max_worker_number(state, issue_id)].max
      end

      def max_issue_number(state, project_id)
        max_numeric_suffix(state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project_id }, /^#{Regexp.escape(project_id)}-I(\d+)$/)
      end

      def max_worker_number(state, issue_id)
        max_numeric_suffix(state.fetch("agents").select { |agent| agent.fetch("issue_id", nil) == issue_id }, /^#{Regexp.escape(issue_id)}-W(\d+)$/)
      end

      def append_log(state, source_type:, source_id:, level:, message:, details: {})
        raise ArgumentError, "invalid log source_type: #{source_type}" unless State::Models::LOG_SOURCE_TYPES.include?(source_type)
        raise ArgumentError, "invalid log level: #{level}" unless State::Models::LOG_LEVELS.include?(level)

        now = timestamp
        state.fetch("counters")["logs"] = state.fetch("counters").fetch("logs", 0).to_i + 1
        log_id = "L#{state.fetch("counters").fetch("logs")}"
        state.fetch("logs") << {
          "id" => log_id,
          "timestamp" => now,
          "source_type" => source_type,
          "source_id" => source_id,
          "level" => level,
          "message" => message,
          "details" => details
        }
        [log_id]
      end

      def touch_state!(state, now = timestamp)
        state.fetch("metadata")["updated_at"] = now
      end

      def find_project(state, project_id)
        state.fetch("projects").find { |project| project.fetch("id", nil) == project_id.to_s }
      end

      def find_issue(state, issue_id)
        state.fetch("issues").find { |issue| issue.fetch("id", nil) == issue_id.to_s }
      end

      def normalize_command(command)
        case command
        when Command
          {
            "command_id" => nil,
            "type" => command.type,
            "payload" => command.payload || {}
          }
        when Hash
          {
            "command_id" => value_at(command, "command_id", "id"),
            "type" => value_at(command, "type", "command_type"),
            "payload" => value_at(command, "payload") || {}
          }
        else
          {
            "command_id" => nil,
            "type" => nil,
            "payload" => {}
          }
        end
      end

      def canonical_command_type(command_type)
        text = command_type.to_s
        COMMAND_ALIASES.fetch(text, text)
      end

      def value_at(hash, *keys)
        return nil unless hash.respond_to?(:[])

        keys.each do |key|
          return hash[key] if hash.key?(key)

          symbol_key = key.to_sym
          return hash[symbol_key] if hash.key?(symbol_key)
        end
        nil
      end

      def accepted_result(command_id, command_type, target_id, message, result, log_entry_ids)
        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "accepted",
          target_id: target_id,
          message: message,
          result: result,
          errors: [],
          log_entry_ids: log_entry_ids
        ).to_h
      end

      def rejected_result(command_id, command_type, message, errors)
        log_entry_ids = record_result_log(
          command_id: command_id,
          command_type: command_type,
          status: "rejected",
          level: "warning",
          message: message,
          errors: errors
        )

        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "rejected",
          message: message,
          errors: errors,
          log_entry_ids: log_entry_ids
        ).to_h
      end

      def failed_result(command_id, command_type, message, errors)
        log_entry_ids = record_result_log(
          command_id: command_id,
          command_type: command_type,
          status: "failed",
          level: "error",
          message: message,
          errors: errors
        )

        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "failed",
          message: message,
          errors: errors,
          log_entry_ids: log_entry_ids
        ).to_h
      end

      def record_result_log(command_id:, command_type:, status:, level:, message:, errors: [])
        state = normalized_state
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: level,
          message: "#{status.capitalize} #{command_type || "unknown"}: #{message}",
          details: {
            "command_id" => command_id,
            "command_type" => command_type,
            "status" => status,
            "errors" => errors
          }
        )
        touch_state!(state)
        store.save(state)
        log_ids
      rescue StandardError
        []
      end

      def kill_session_safely(session_ref)
        harness_client.kill_session(session_ref)
      rescue StandardError
        nil
      end

      def same_path?(left, right)
        File.expand_path(left.to_s) == File.expand_path(right.to_s)
      end

      def default_project_name(path)
        basename = File.basename(path)
        basename.empty? || basename == "/" ? path : basename
      end

      def present_string(value)
        value = value.to_s.strip unless value.nil?
        value unless blank?(value)
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def timestamp
        Time.now.utc.iso8601
      end
    end
  end
end
