# frozen_string_literal: true

require "json"
require "monitor"
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
        "spawn_head" => "SpawnHead",
        "apply_head_result" => "ApplyHeadResult",
        "ask_question" => "AskQuestion",
        "answer_question" => "AnswerQuestion",
        "modify_issue" => "ModifyIssue",
        "prompt_agent" => "PromptAgent",
        "kill" => "Kill",
        "help" => "Help",
        "get_state" => "GetState",
        "list_questions" => "ListQuestions",
        "clear" => "ClearState",
        "clear_state" => "ClearState",
        "list_all" => "ListAll"
      }.freeze

      HELP_COMMANDS = [
        ["/help", "Show slash command help."],
        ["/project add <path> [name]", "Register a project directory."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/prompt <worker_id> \"<message>\"", "Prompt an existing worker harness session."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "List questions and their statuses."],
        ["/answer <question_id> \"<answer>\"", "Answer a pending question."]
      ].freeze

      attr_reader :store, :harness_client, :head_runner, :workspace_manager, :cwd

      def initialize(store: State::Store.new, harness_client: Harness::FakeClient.new,
                     head_runner: Heads::FakeRunner.new,
                     workspace_manager: Workspace::Manager.new,
                     cwd: Dir.pwd)
        @store = store
        @harness_client = harness_client
        @head_runner = head_runner
        @workspace_manager = workspace_manager
        @cwd = File.expand_path(cwd)
        @state_mutex = Monitor.new
        @head_result_mutex = Mutex.new
      end

      def list_all
        synchronized_state { store.load }
      end

      def apply(command)
        normalized = normalize_command(command)
        command_type = normalized.fetch("type", nil)
        command_id = normalized.fetch("command_id", nil)
        payload = normalized.fetch("payload", {})

        return synchronized_state { rejected_result(command_id, nil, "Kernel command is missing a type.", ["missing_type"]) } if blank?(command_type)

        command_type = canonical_command_type(command_type)

        if command_type == "SpawnHead"
          spawn_head(command_id, command_type, payload)
        elsif command_type == "SpawnWorker"
          spawn_worker(command_id, command_type, payload)
        elsif command_type == "ApplyHeadResult"
          @head_result_mutex.synchronize { apply_head_result(command_id, command_type, payload) }
        else
          synchronized_state { dispatch_command(command_id, command_type, payload) }
        end
      rescue StandardError => e
        synchronized_state do
          failed_result(
            command_id,
            command_type || "Unknown",
            "Kernel command failed: #{e.message}",
            [e.class.name, e.message]
          )
        end
      end

      def dispatch_command(command_id, command_type, payload)
        case command_type
        when "ListAll"
          accepted_result(command_id, command_type, nil, "Loaded Meringue state.", store.load, [])
        when "GetState"
          get_state(command_id, command_type)
        when "ListQuestions"
          list_questions(command_id, command_type)
        when "Help"
          help(command_id, command_type)
        when "InvalidSlashCommand"
          invalid_slash_command(command_id, command_type, payload)
        when "AddProject"
          add_project(command_id, command_type, payload)
        when "CreateIssue"
          create_issue(command_id, command_type, payload)
        when "ModifyIssue"
          modify_issue(command_id, command_type, payload)
        when "SpawnWorker"
          spawn_worker(command_id, command_type, payload)
        when "PromptAgent"
          prompt_agent(command_id, command_type, payload)
        when "Kill"
          kill(command_id, command_type, payload)
        when "ApplyHeadResult"
          apply_head_result(command_id, command_type, payload)
        when "AskQuestion"
          ask_question(command_id, command_type, payload)
        when "AnswerQuestion"
          answer_question(command_id, command_type, payload)
        when "ClearState"
          clear_state(command_id, command_type)
        else
          rejected_result(
            command_id,
            command_type,
            "Unknown kernel command: #{command_type}",
            ["unknown_command"]
          )
        end
      end

      private :dispatch_command

      def apply_all(commands)
        Array(commands).map { |command| apply(command) }
      end

      def mark_worker_completed(agent_id:, harness_events: [], last_assistant_text: nil)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return rejected_result(nil, "MarkWorkerCompleted", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          unless agent.fetch("type", nil) == "worker"
            return rejected_result(nil, "MarkWorkerCompleted", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"])
          end

          now = timestamp
          agent["status"] = "completed"
          agent["updated_at"] = now
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "completed_at" => now,
            "is_streaming" => false,
            "settled_event_count" => Array(harness_events).length,
            "last_assistant_text" => present_string(last_assistant_text)
          ).compact

          issue = find_issue(state, agent.fetch("issue_id", nil))
          project = issue && find_project(state, issue.fetch("project_id", nil))
          update_issue_status_from_workers!(state, issue, now) if issue
          update_project_status_from_issues!(state, project, now) if project

          log_ids = append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "info",
            message: "Worker #{agent.fetch("id")} completed.",
            details: {
              "issue_id" => agent.fetch("issue_id", nil),
              "project_id" => agent.fetch("project_id", nil),
              "settled_event_count" => Array(harness_events).length,
              "last_assistant_text" => present_string(last_assistant_text)
            }.compact
          )
          touch_state!(state, now)
          store.save(state)

          accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Marked worker #{agent.fetch("id")} completed.", agent, log_ids)
        end
      end

      private

      def get_state(command_id, command_type)
        accepted_result(command_id, command_type, nil, "Loaded Meringue state.", store.load, [])
      end

      def list_questions(command_id, command_type)
        state = normalized_state
        questions = state.fetch("questions", [])
        accepted_result(
          command_id,
          command_type,
          nil,
          "Loaded #{questions.length} question#{questions.length == 1 ? "" : "s"}.",
          questions,
          []
        )
      end

      def help(command_id, command_type)
        accepted_result(
          command_id,
          command_type,
          nil,
          "Loaded slash command help.",
          HELP_COMMANDS.map { |usage, description| { "usage" => usage, "description" => description } },
          []
        )
      end

      def invalid_slash_command(command_id, command_type, payload)
        message = value_at(payload, "message") || "Invalid slash command."
        usage = value_at(payload, "usage")
        errors = [message.to_s]
        errors << "Try #{usage}" if present_string(usage)
        rejected_result(command_id, command_type, message.to_s, errors)
      end

      def prompt_agent(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        prompt = value_at(payload, "prompt", "Prompt", "message", "Message")
        mode = value_at(payload, "mode", "Mode") || "normal"
        errors = []

        errors << "agent_id is required" if blank?(agent_id)
        errors << "prompt is required" if blank?(prompt)
        return rejected_result(command_id, command_type, "Agent was not prompted.", errors) unless errors.empty?

        state = normalized_state
        agent = find_agent(state, agent_id)
        return rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
        return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
        return rejected_result(command_id, command_type, "Agent #{agent_id} has no harness session.", ["agent_has_no_harness_session"]) if blank?(agent.fetch("harness", nil))
        return rejected_result(command_id, command_type, "Agent #{agent_id} is killed.", ["agent_killed"]) if agent.fetch("status", nil) == "killed"

        session_ref = session_ref_from_agent(agent)
        updated_ref = harness_client.prompt_session(session_ref, prompt.to_s, mode: mode.to_s)
        now = timestamp
        apply_session_ref_to_agent!(agent, updated_ref)
        agent["status"] = "working" if agent.fetch("status", nil) == "idle"
        agent["updated_at"] = now

        log_ids = append_log(
          state,
          source_type: "worker",
          source_id: agent.fetch("id"),
          level: "info",
          message: "Prompted agent #{agent.fetch("id")}.",
          details: { "mode" => mode.to_s, "prompt" => prompt.to_s }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, agent.fetch("id"), "Prompted agent #{agent.fetch("id")}.", agent, log_ids)
      end

      def kill(command_id, command_type, payload)
        target_id = value_at(payload, "target_id", "TargetID", "targetId", "id")
        return rejected_result(command_id, command_type, "Target was not killed.", ["target_id is required"]) if blank?(target_id)

        state = normalized_state
        target = find_agent(state, target_id) || find_issue(state, target_id) || find_project(state, target_id)
        return rejected_result(command_id, command_type, "Target #{target_id} does not exist.", ["target_not_found"]) unless target

        now = timestamp
        killed_agent_ids = kill_target_in_state!(state, target_id.to_s, now)
        killed_agent_ids.each do |agent_id|
          agent = find_agent(state, agent_id)
          next unless agent

          kill_session_safely(session_ref_from_agent(agent)) if present_string(agent.fetch("harness", nil))
        end

        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: target_id.to_s,
          level: "info",
          message: "Killed #{target_id}.",
          details: { "target_id" => target_id.to_s, "killed_agent_ids" => killed_agent_ids }
        )
        touch_state!(state, now)
        store.save(state)

        result = find_agent(state, target_id) || find_issue(state, target_id) || find_project(state, target_id)
        accepted_result(command_id, command_type, target_id.to_s, "Killed #{target_id}.", result, log_ids)
      end

      def spawn_head(command_id, command_type, payload)
        user_message = value_at(payload, "user_message", "UserMessage", "message")
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        errors = []

        errors << "user_message is required" if blank?(user_message)
        return synchronized_state { rejected_result(command_id, command_type, "Head was not spawned.", errors) } unless errors.empty?

        head_id = nil
        started = synchronized_state do
          state = normalized_state
          if present_string(question_id) && !find_question(state, question_id)
            return rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"])
          end

          now = timestamp
          head_id = next_head_id!(state)
          agent = build_head_agent(head_id: head_id, now: now)
          state.fetch("agents") << agent

          log_ids = []
          log_ids.concat(append_log(
            state,
            source_type: "user",
            source_id: head_id,
            level: "info",
            message: "User prompt routed to head #{head_id}.",
            details: {
              "user_message" => user_message.to_s,
              "question_id" => present_string(question_id)
            }
          ))
          log_ids.concat(append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "info",
            message: "Spawned head #{head_id}.",
            details: { "runner" => head_runner.class.name, "cwd" => cwd }
          ))
          touch_state!(state, now)
          store.save(state)

          snapshot = deep_copy(state)
          context = Heads::Context.new(
            head_id: head_id,
            user_message: user_message.to_s,
            snapshot: snapshot,
            question_id: present_string(question_id),
            cwd: cwd
          )

          {
            "context" => context,
            "log_ids" => log_ids,
            "snapshot" => snapshot
          }
        end

        head_result = head_runner.run(
          user_message: user_message.to_s,
          snapshot: started.fetch("snapshot"),
          question_id: present_string(question_id),
          context: started.fetch("context")
        )

        synchronized_state do
          state = normalized_state
          agent = find_agent(state, head_id)
          raise "Head #{head_id} disappeared before completion could be recorded." unless agent

          agent["status"] = "completed"
          agent["updated_at"] = timestamp
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "title" => head_result.is_a?(Hash) ? head_result["title"] : nil,
            "summary" => head_result.is_a?(Hash) ? head_result["summary"] : nil,
            "head_result" => head_result
          ).compact
          log_ids = started.fetch("log_ids")
          log_ids.concat(append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "info",
            message: "Head #{head_id} completed with #{Array(head_result.is_a?(Hash) ? head_result["commands"] : []).length} proposed command(s).",
            details: { "head_result" => head_result }
          ))
          touch_state!(state)
          store.save(state)

          accepted_result(command_id, command_type, head_id, "Spawned and completed head #{head_id}.", agent, log_ids)
        end
      rescue StandardError => e
        mark_head_errored(head_id, e) if defined?(head_id) && head_id
        synchronized_state do
          failed_result(
            command_id,
            command_type,
            "Head failed: #{e.message}",
            [e.class.name, e.message]
          )
        end
      end

      def apply_head_result(command_id, command_type, payload)
        head_id = value_at(payload, "head_id", "HeadID", "headId")
        head_result = value_at(payload, "head_result", "HeadResult", "result")
        errors = validate_head_result_shape(head_result)
        errors << "head_id is required" if blank?(head_id)
        return synchronized_state { rejected_result(command_id, command_type, "Head result was not applied.", errors) } unless errors.empty?

        log_ids = []
        question_ids = synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return rejected_result(command_id, command_type, "Head #{head_id} does not exist.", ["head_not_found"]) unless head
          return rejected_result(command_id, command_type, "Agent #{head_id} is not a head.", ["agent_is_not_head"]) unless head.fetch("type", nil) == "head"

          head["status"] = "completed" unless head.fetch("status", nil) == "errored"
          head["updated_at"] = timestamp
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "title" => head_result.fetch("title"),
            "summary" => head_result.fetch("summary"),
            "head_result" => head_result
          )
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: head_id.to_s,
            level: "info",
            message: "Applying head result for #{head_id}.",
            details: {
              "title" => head_result.fetch("title"),
              "summary" => head_result.fetch("summary"),
              "command_count" => head_result.fetch("commands").length,
              "question_count" => head_result.fetch("questions").length
            }
          ))

          ids = create_head_questions!(state, head_id, head_result.fetch("questions"), log_ids)
          touch_state!(state)
          store.save(state)
          ids
        end

        command_results = head_result.fetch("commands").each_with_index.map do |proposed_command, index|
          apply(command_with_default_id(proposed_command, head_id: head_id.to_s, index: index))
        end

        synchronized_state do
          state = normalized_state
          accepted_count = command_results.count { |result| result.fetch("status", nil) == "accepted" }
          rejected_count = command_results.count { |result| result.fetch("status", nil) == "rejected" }
          failed_count = command_results.count { |result| result.fetch("status", nil) == "failed" }
          summary_log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: head_id.to_s,
            level: failed_count.positive? ? "error" : "info",
            message: "Applied head result for #{head_id}: #{accepted_count} accepted, #{rejected_count} rejected, #{failed_count} failed.",
            details: {
              "head_id" => head_id.to_s,
              "question_ids" => question_ids,
              "command_results" => command_results
            }
          )
          touch_state!(state)
          store.save(state)
          log_ids.concat(command_results.flat_map { |result| result.fetch("log_entry_ids", []) })
          log_ids.concat(summary_log_ids)

          accepted_result(
            command_id,
            command_type,
            head_id.to_s,
            "Applied head result for #{head_id}.",
            {
              "head_id" => head_id.to_s,
              "title" => head_result.fetch("title"),
              "summary" => head_result.fetch("summary"),
              "question_ids" => question_ids,
              "command_results" => command_results
            },
            log_ids.uniq
          )
        end
      end

      def answer_question(command_id, command_type, payload)
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        answer = value_at(payload, "answer", "Answer")
        errors = []

        errors << "question_id is required" if blank?(question_id)
        errors << "answer is required" if blank?(answer)
        return rejected_result(command_id, command_type, "Question was not answered.", errors) unless errors.empty?

        state = normalized_state
        question = find_question(state, question_id)
        return rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"]) unless question

        now = timestamp
        question["status"] = "answered"
        question["answer"] = answer.to_s
        question["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: question.fetch("id"),
          level: "info",
          message: "Answered question #{question.fetch("id")}.",
          details: {
            "head_id" => question.fetch("head_id", nil),
            "project_id" => question.fetch("project_id", nil),
            "issue_id" => question.fetch("issue_id", nil)
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, question.fetch("id"), "Answered question #{question.fetch("id")}.", question, log_ids)
      end

      def clear_state(command_id, command_type)
        now = timestamp
        state = State::Models.empty_state(now: now)
        store.save(state)

        accepted_result(command_id, command_type, nil, "Cleared Meringue state.", state, [])
      end

      def ask_question(command_id, command_type, payload)
        head_id = value_at(payload, "head_id", "HeadID", "headId")
        question_text = value_at(payload, "question", "Question")
        context = value_at(payload, "context", "Context")
        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        errors = []

        errors << "head_id is required" if blank?(head_id)
        errors << "question is required" if blank?(question_text)
        return rejected_result(command_id, command_type, "Question was not stored.", errors) unless errors.empty?

        state = normalized_state
        return rejected_result(command_id, command_type, "Head #{head_id} does not exist.", ["head_not_found"]) unless find_agent(state, head_id)
        return rejected_result(command_id, command_type, "Project #{project_id} does not exist.", ["project_not_found"]) if present_string(project_id) && !find_project(state, project_id)
        return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) if present_string(issue_id) && !find_issue(state, issue_id)

        log_ids = []
        question = build_question(
          state: state,
          head_id: head_id.to_s,
          question_text: question_text.to_s,
          context: context.to_s,
          project_id: present_string(project_id),
          issue_id: present_string(issue_id)
        )
        state.fetch("questions") << question
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: question.fetch("id"),
          level: "info",
          message: "Stored question #{question.fetch("id")} from #{head_id}.",
          details: { "head_id" => head_id.to_s }
        ))
        touch_state!(state)
        store.save(state)

        accepted_result(command_id, command_type, question.fetch("id"), "Stored question #{question.fetch("id")}.", question, log_ids)
      end

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

      def modify_issue(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        title = value_at(payload, "title", "Title")
        description = value_at(payload, "description", "Description")
        parent_issue_id = value_at(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
        status = value_at(payload, "status", "Status")
        errors = []

        errors << "issue_id is required" if blank?(issue_id)
        errors << "status must be one of #{State::Models::LIFECYCLE_STATUSES.join(", ")}" if present_string(status) && !State::Models::LIFECYCLE_STATUSES.include?(status.to_s)
        return rejected_result(command_id, command_type, "Issue was not modified.", errors) unless errors.empty?

        state = normalized_state
        issue = find_issue(state, issue_id)
        return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) unless issue

        project = find_project(state, issue.fetch("project_id"))
        return rejected_result(command_id, command_type, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

        if payload_has?(payload, "parent_issue_id", "ParentIssueID", "parentIssueId") && present_string(parent_issue_id)
          parent = find_issue(state, parent_issue_id)
          return rejected_result(command_id, command_type, "Parent issue #{parent_issue_id} does not exist in #{project.fetch("id")}.", ["parent_issue_not_found"]) unless parent && parent.fetch("project_id") == project.fetch("id")
          return rejected_result(command_id, command_type, "Issue cannot be its own parent.", ["invalid_parent_issue"]) if parent.fetch("id") == issue.fetch("id")
        end

        now = timestamp
        changed_fields = []
        if payload_has?(payload, "title", "Title")
          issue["title"] = title.to_s.strip
          changed_fields << "title"
        end
        if payload_has?(payload, "description", "Description")
          issue["description"] = description.to_s
          changed_fields << "description"
        end
        if payload_has?(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
          issue["parent_issue_id"] = present_string(parent_issue_id)
          changed_fields << "parent_issue_id"
        end
        if present_string(status)
          issue["status"] = status.to_s
          changed_fields << "status"
        end

        issue["updated_at"] = now
        project["updated_at"] = now
        update_project_status_from_issues!(state, project, now)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: issue.fetch("id"),
          level: "info",
          message: "Modified issue #{issue.fetch("id")}: #{changed_fields.empty? ? "no fields changed" : changed_fields.join(", ")}",
          details: {
            "project_id" => project.fetch("id"),
            "changed_fields" => changed_fields
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, issue.fetch("id"), "Modified issue #{issue.fetch("id")}.", issue, log_ids)
      end

      def prompt_agent(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        prompt = value_at(payload, "prompt", "Prompt")
        mode = value_at(payload, "mode", "Mode") || "normal"
        errors = []

        errors << "agent_id is required" if blank?(agent_id)
        errors << "prompt is required" if blank?(prompt)
        return rejected_result(command_id, command_type, "Agent was not prompted.", errors) unless errors.empty?

        state = normalized_state
        agent = find_agent(state, agent_id)
        return rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
        return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
        if blank?(agent.fetch("pid", nil)) && blank?(agent.fetch("harness_session_id", nil))
          return rejected_result(command_id, command_type, "Agent #{agent_id} has no harness session.", ["missing_harness_session"])
        end

        session_ref = agent_session_ref(agent)
        begin
          session_ref = harness_client.prompt_session(session_ref, prompt.to_s, mode: mode.to_s)
        rescue StandardError => e
          return failed_result(
            command_id,
            command_type,
            "Harness failed to prompt agent #{agent_id}: #{e.message}",
            [e.class.name, e.message]
          )
        end

        now = timestamp
        session_metadata = session_ref.fetch("metadata", {}) || {}
        agent["status"] = "working" if session_ref.fetch("is_streaming", false)
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          session_metadata,
          "last_prompt_mode" => mode.to_s,
          "is_streaming" => session_ref.fetch("is_streaming", false),
          "last_event_at" => session_ref.fetch("last_event_at", nil)
        ).compact
        agent["updated_at"] = now

        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: "Prompted agent #{agent.fetch("id")} with #{mode} mode.",
          details: {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "mode" => mode.to_s,
            "is_streaming" => session_ref.fetch("is_streaming", false)
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, agent.fetch("id"), "Prompted agent #{agent.fetch("id")}.", agent, log_ids)
      end

      def spawn_worker(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        prompt = value_at(payload, "prompt", "Prompt")
        worker_title = value_at(payload, "title", "Title", "worker_title", "workerTitle")
        requested_workspace_path = value_at(payload, "workspace_path", "WorkspacePath", "workspacePath")
        errors = []

        errors << "issue_id is required" if blank?(issue_id)
        errors << "prompt is required" if blank?(prompt)
        return synchronized_state { rejected_result(command_id, command_type, "Worker was not spawned.", errors) } unless errors.empty?

        reservation = synchronized_state do
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
          touch_state!(state, now)
          store.save(state)

          {
            "agent_id" => agent_id,
            "issue" => deep_copy(issue),
            "project" => deep_copy(project),
            "workspace" => workspace,
            "now" => now
          }
        end

        session_ref = nil
        begin
          session_ref = harness_client.spawn_session(
            kind: "worker",
            cwd: reservation.fetch("workspace").fetch("workspace_path"),
            prompt: prompt.to_s,
            system_prompt: worker_system_prompt(reservation.fetch("issue")),
            session_name: worker_session_name(reservation.fetch("agent_id"), reservation.fetch("issue"), worker_title: worker_title)
          )
        rescue StandardError => e
          return synchronized_state do
            failed_result(
              command_id,
              command_type,
              "Harness failed to spawn worker #{reservation.fetch("agent_id")}: #{e.message}",
              [e.class.name, e.message]
            )
          end
        end

        synchronized_state do
          state = normalized_state
          issue = find_issue(state, reservation.fetch("issue").fetch("id"))
          project = issue && find_project(state, issue.fetch("project_id"))
          unless issue && project
            kill_session_safely(session_ref)
            return failed_result(
              command_id,
              command_type,
              "Worker #{reservation.fetch("agent_id")} could not be recorded because its issue or project no longer exists.",
              ["issue_or_project_not_found"]
            )
          end

          agent = build_worker_agent(
            agent_id: reservation.fetch("agent_id"),
            issue: issue,
            project: project,
            workspace: reservation.fetch("workspace"),
            session_ref: session_ref,
            now: reservation.fetch("now"),
            title: worker_title
          )

          state.fetch("agents") << agent
          issue.fetch("agent_ids") << reservation.fetch("agent_id")
          issue["status"] = "working"
          issue["updated_at"] = reservation.fetch("now")
          project["status"] = "working"
          project["updated_at"] = reservation.fetch("now")

          log_ids = []
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: reservation.fetch("agent_id"),
            level: "info",
            message: "Spawned worker #{reservation.fetch("agent_id")} for #{issue.fetch("id")}",
            details: {
              "issue_id" => issue.fetch("id"),
              "project_id" => project.fetch("id"),
              "workspace_path" => agent.fetch("workspace_path"),
              "workspace_strategy" => agent.fetch("workspace_strategy"),
              "title" => agent.fetch("harness_metadata", {}).fetch("title", nil)
            }
          ))
          log_ids.concat(append_log(
            state,
            source_type: "harness",
            source_id: reservation.fetch("agent_id"),
            level: "info",
            message: "Started #{agent.fetch("harness")} session for #{reservation.fetch("agent_id")}",
            details: {
              "pid" => agent.fetch("pid"),
              "harness_session_id" => agent.fetch("harness_session_id"),
              "harness_session_file" => agent.fetch("harness_session_file"),
              "is_streaming" => agent.fetch("harness_metadata").fetch("is_streaming", nil)
            }
          ))
          touch_state!(state, reservation.fetch("now"))
          store.save(state)

          accepted_result(command_id, command_type, reservation.fetch("agent_id"), "Spawned worker #{reservation.fetch("agent_id")}.", agent, log_ids)
        end
      rescue StandardError => e
        kill_session_safely(session_ref) if session_ref
        raise e
      end

      def build_head_agent(head_id:, now:)
        {
          "id" => head_id,
          "type" => "head",
          "status" => "working",
          "project_id" => nil,
          "issue_id" => nil,
          "workspace_path" => nil,
          "workspace_strategy" => nil,
          "workspace_branch" => nil,
          "harness" => head_harness_name,
          "pid" => nil,
          "harness_session_id" => nil,
          "harness_session_file" => nil,
          "harness_metadata" => {
            "runner" => head_runner.class.name,
            "cwd" => cwd
          },
          "created_at" => now,
          "updated_at" => now
        }
      end

      def build_worker_agent(agent_id:, issue:, project:, workspace:, session_ref:, now:, title: nil)
        session_metadata = session_ref.fetch("metadata", {}) || {}
        display_title = worker_display_title(title, issue)
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
            "title" => display_title,
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

      def session_ref_from_agent(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        {
          "harness" => agent.fetch("harness", nil),
          "pid" => agent.fetch("pid", nil),
          "cwd" => metadata.fetch("cwd", agent.fetch("workspace_path", nil)),
          "session_id" => agent.fetch("harness_session_id", nil),
          "session_file" => agent.fetch("harness_session_file", nil),
          "is_streaming" => metadata.fetch("is_streaming", false),
          "last_event_at" => metadata.fetch("last_event_at", nil),
          "metadata" => metadata
        }
      end

      def apply_session_ref_to_agent!(agent, session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          metadata.merge(
            "cwd" => session_ref.fetch("cwd", metadata.fetch("cwd", agent.fetch("workspace_path", nil))),
            "is_streaming" => session_ref.fetch("is_streaming", metadata.fetch("is_streaming", false)),
            "last_event_at" => session_ref.fetch("last_event_at", metadata.fetch("last_event_at", nil))
          ).compact
        )
      end

      def kill_target_in_state!(state, target_id, now)
        if (agent = find_agent(state, target_id))
          mark_agent_killed!(agent, now)
          return [agent.fetch("id")]
        end

        if (issue = find_issue(state, target_id))
          return kill_issue_subtree!(state, issue, now)
        end

        project = find_project(state, target_id)
        return [] unless project

        project["status"] = "killed"
        project["updated_at"] = now
        state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }
             .flat_map { |issue| kill_issue_subtree!(state, issue, now) }
             .uniq
      end

      def kill_issue_subtree!(state, issue, now)
        issue["status"] = "killed"
        issue["updated_at"] = now
        child_agent_ids = state.fetch("agents").select { |agent| agent.fetch("issue_id", nil) == issue.fetch("id") }.map do |agent|
          mark_agent_killed!(agent, now)
          agent.fetch("id")
        end
        child_issue_agent_ids = state.fetch("issues")
                                     .select { |candidate| candidate.fetch("parent_issue_id", nil) == issue.fetch("id") }
                                     .flat_map { |child_issue| kill_issue_subtree!(state, child_issue, now) }
        (child_agent_ids + child_issue_agent_ids).uniq
      end

      def mark_agent_killed!(agent, now)
        agent["status"] = "killed"
        agent["updated_at"] = now
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("killed_at" => now)
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

      def worker_session_name(agent_id, issue, worker_title: nil)
        title = worker_display_title(worker_title, issue).to_s.strip.gsub(/\s+/, " ")
        title = "worker" if title.empty?
        "#{agent_id} #{title}"[0, 96]
      end

      def worker_display_title(worker_title, issue)
        title = present_string(worker_title)
        title || issue.fetch("title").to_s.strip
      end

      def validate_head_result_shape(head_result)
        errors = []
        unless head_result.is_a?(Hash)
          errors << "head_result must be an object"
          return errors
        end

        errors << "head_result.title must be a string" unless head_result["title"].is_a?(String)
        errors << "head_result.summary must be a string" unless head_result["summary"].is_a?(String)
        validate_head_commands(head_result["commands"], errors)
        validate_head_questions(head_result["questions"], errors)
        errors
      end

      def validate_head_commands(commands, errors)
        unless commands.is_a?(Array)
          errors << "head_result.commands must be an array"
          return
        end

        commands.each_with_index do |command, index|
          unless command.is_a?(Hash)
            errors << "head_result.commands[#{index}] must be an object"
            next
          end

          errors << "head_result.commands[#{index}].type must be a string" unless command["type"].is_a?(String)
          errors << "head_result.commands[#{index}].payload must be an object" unless command["payload"].is_a?(Hash)
        end
      end

      def validate_head_questions(questions, errors)
        unless questions.is_a?(Array)
          errors << "head_result.questions must be an array"
          return
        end

        questions.each_with_index do |question, index|
          unless question.is_a?(Hash)
            errors << "head_result.questions[#{index}] must be an object"
            next
          end

          errors << "head_result.questions[#{index}].question must be a string" unless question["question"].is_a?(String)
        end
      end

      def create_head_questions!(state, head_id, questions, log_ids)
        questions.map do |question_payload|
          question = build_question(
            state: state,
            head_id: head_id.to_s,
            question_text: question_payload.fetch("question").to_s,
            context: question_payload.fetch("context", "").to_s,
            project_id: present_string(value_at(question_payload, "project_id", "projectId")),
            issue_id: present_string(value_at(question_payload, "issue_id", "issueId"))
          )
          state.fetch("questions") << question
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: question.fetch("id"),
            level: "info",
            message: "Stored question #{question.fetch("id")} from #{head_id}.",
            details: {
              "head_id" => head_id.to_s,
              "project_id" => question.fetch("project_id"),
              "issue_id" => question.fetch("issue_id")
            }
          ))
          question.fetch("id")
        end
      end

      def command_with_default_id(command, head_id:, index:)
        return command unless command.is_a?(Hash) && blank?(value_at(command, "command_id", "id"))

        command.merge("command_id" => "#{head_id}-C#{index + 1}")
      end

      def build_question(state:, head_id:, question_text:, context:, project_id:, issue_id:)
        now = timestamp
        question_id = next_question_id!(state)
        {
          "id" => question_id,
          "head_id" => head_id,
          "project_id" => project_id,
          "issue_id" => issue_id,
          "question" => question_text,
          "context" => context,
          "status" => "open",
          "answer" => nil,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def update_issue_status_from_workers!(state, issue, now)
        workers = state.fetch("agents").select do |candidate|
          candidate.fetch("type", nil) == "worker" && candidate.fetch("issue_id", nil) == issue.fetch("id")
        end
        return if workers.empty?

        issue["status"] = if workers.all? { |worker| worker.fetch("status", nil) == "completed" }
                            "completed"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "errored" }
                            "errored"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "blocked" }
                            "blocked"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "working" }
                            "working"
                          else
                            issue.fetch("status", "idle")
                          end
        issue["updated_at"] = now
      end

      def update_project_status_from_issues!(state, project, now)
        issues = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }
        return if issues.empty?

        project["status"] = if issues.all? { |issue| issue.fetch("status", nil) == "completed" }
                              "completed"
                            elsif issues.any? { |issue| issue.fetch("status", nil) == "errored" }
                              "errored"
                            elsif issues.any? { |issue| issue.fetch("status", nil) == "blocked" }
                              "blocked"
                            elsif issues.any? { |issue| issue.fetch("status", nil) == "working" }
                              "working"
                            else
                              project.fetch("status", "idle")
                            end
        project["updated_at"] = now
      end

      def mark_head_errored(head_id, error)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return unless head

          now = timestamp
          head["status"] = "errored"
          head["updated_at"] = now
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "error_class" => error.class.name,
            "error_message" => error.message
          )
          append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "error",
            message: "Head #{head_id} failed: #{error.message}",
            details: { "class" => error.class.name }
          )
          touch_state!(state, now)
          store.save(state)
        end
      rescue StandardError
        nil
      end

      def synchronized_state(&block)
        @state_mutex.synchronize(&block)
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
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

      def next_head_id!(state)
        state.fetch("counters")["heads"] = state.fetch("counters").fetch("heads", 0).to_i + 1
        "H#{state.fetch("counters").fetch("heads")}"
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

      def next_question_id!(state)
        state.fetch("counters")["questions"] = state.fetch("counters").fetch("questions", 0).to_i + 1
        "Q#{state.fetch("counters").fetch("questions")}"
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

      def find_agent(state, agent_id)
        state.fetch("agents").find { |agent| agent.fetch("id", nil) == agent_id.to_s }
      end

      def find_question(state, question_id)
        state.fetch("questions").find { |question| question.fetch("id", nil) == question_id.to_s }
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

      def agent_session_ref(agent)
        {
          "harness" => agent.fetch("harness", nil),
          "pid" => agent.fetch("pid", nil),
          "cwd" => agent.fetch("workspace_path", nil),
          "session_id" => agent.fetch("harness_session_id", nil),
          "session_file" => agent.fetch("harness_session_file", nil),
          "is_streaming" => agent.fetch("harness_metadata", {}).fetch("is_streaming", false),
          "last_event_at" => agent.fetch("harness_metadata", {}).fetch("last_event_at", nil),
          "metadata" => agent.fetch("harness_metadata", {}) || {}
        }
      end

      def payload_has?(hash, *keys)
        return false unless hash.respond_to?(:key?)

        keys.any? do |key|
          hash.key?(key) || hash.key?(key.to_sym)
        end
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

      def head_harness_name
        if head_runner.respond_to?(:harness_client) && head_runner.harness_client
          head_runner.harness_client.class.name.to_s.split("::").last.to_s.sub(/Client\z/, "").downcase
        elsif head_runner.class.name.to_s.end_with?("FakeRunner")
          "fake"
        else
          "unknown"
        end
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
