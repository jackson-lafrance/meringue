# frozen_string_literal: true

require "json"
require "monitor"
require "open3"
require "time"

module Meringue
  module Kernel
    class Engine
      WORKER_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue worker agent. Work only on the assigned issue and workspace.
        Follow the user's prompt and the repository instructions in your working directory.

        You do not directly interface with the user, so do not ask for permission before taking normal implementation or delivery actions requested by the assigned issue. You may edit files, commit, push, and open or update pull requests when the assigned issue asks for those actions.

        The Meringue kernel allocates your workspace before you start. Stay in the assigned workspace and current branch unless the assigned workspace is unusable or the user explicitly asks for a different branch/worktree; report that as a blocker instead of silently creating nested worktrees.

        Before editing, inspect the repository status and active instructions. Avoid overwriting unrelated active work. Treat the assigned workspace as your task branch/worktree for git-backed projects, commit only the assigned issue's changes, and open a pull request when requested and the environment allows.

        Use human-facing delivery names. Branch names, pull request titles, and pull request metadata should be derived from the assigned issue title or requested change, not from Meringue agent ids, worker ids, Pi ids, or subagent implementation details. If a unique suffix is needed, use a short opaque suffix rather than an orchestration id.

        Report true blockers instead of asking for routine approval: missing credentials, authentication or authorization failures, missing or invalid remotes, branch/worktree collisions, unrelated uncommitted work that would be overwritten, or unsafe/destructive operations.
      PROMPT
      WORKER_RESUME_PROMPT = <<~PROMPT.freeze
        Continue this Meringue worker session from the existing conversation and workspace state.
        First inspect the current repository state, then continue the assigned issue from the last incomplete step.
        If the issue is already complete, summarize the final status and include any pull request link.
      PROMPT
      HEAD_RESULT_REPAIR_PROMPT = <<~PROMPT.freeze
        Your previous response was not valid Meringue HeadResult JSON.
        Return exactly one JSON object with string fields "title" and "summary", an array field "commands", and an array field "questions".
        Do not include markdown, prose, code fences, or tool calls.
      PROMPT
      PULL_REQUEST_URL_PATTERN = /https?:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+(?:[\/?#][^\s<>"'\])}]*)?/.freeze
      ERROR_MESSAGE_MAX_BYTES = 2_000

      COMMAND_ALIASES = {
        "add_project" => "AddProject",
        "create_issue" => "CreateIssue",
        "spawn_worker" => "SpawnWorker",
        "spawn_head" => "SpawnHead",
        "apply_head_result" => "ApplyHeadResult",
        "ask_question" => "AskQuestion",
        "answer_question" => "AnswerQuestion",
        "dismiss_question" => "DismissQuestion",
        "modify_issue" => "ModifyIssue",
        "prompt_agent" => "PromptAgent",
        "kill" => "Kill",
        "help" => "Help",
        "get_state" => "GetState",
        "list_questions" => "ListQuestions",
        "reconcile_sessions" => "ReconcileSessions",
        "prune" => "Prune",
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
        ["/jump [agent_id]", "TUI local: open an agent harness session in Alacritty, or navigate the AgentTree when no id is provided."],
        ["/jumpr [agent_id]", "TUI local: open an agent pull request, or navigate agents with attached PRs when no id is provided."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "List questions and their statuses."],
        ["/answer <question_id> \"<answer>\"", "Answer a pending question."],
        ["/dismiss <question_id>", "Dismiss an open question without answering it."],
        ["/prune <merged|errored>", "Remove merged PR issue bundles or errored records from active state."]
      ].freeze
      TERMINAL_AGENT_STATUSES = %w[completed errored killed].freeze
      HEAD_RECONCILE_ERROR_GRACE_SECONDS = 30
      HEAD_RECONCILE_WARNING_DELAY_SECONDS = 5
      HEAD_RESULT_REPAIR_MAX_ATTEMPTS = 1
      WORKER_RECONCILE_RESUME_MAX_ATTEMPTS = 3
      RECONCILE_STATE_HEALTHY = "healthy"
      RECONCILE_STATE_RESUMING = "resuming"
      RECONCILE_STATE_RESUME_FAILED = "resume_failed"
      RECONCILE_STATE_TRANSIENT_ERROR = "transient_error"
      RECONCILE_STATE_TERMINAL_ERROR = "terminal_error"

      attr_reader :store, :harness_client, :head_runner, :workspace_manager, :cwd, :forge_client

      def initialize(store: State::Store.new, harness_client: Harness::FakeClient.new,
                     head_runner: Heads::FakeRunner.new,
                     harness_client_resolver: nil,
                     workspace_manager: Workspace::Manager.new,
                     cwd: Dir.pwd,
                     async_heads: false,
                     forge_client: Forge::GitHubClient.new)
        @store = store
        @harness_client = harness_client
        @head_runner = head_runner
        @workspace_manager = workspace_manager
        @cwd = File.expand_path(cwd)
        @async_heads = async_heads
        @forge_client = forge_client
        @harness_client_resolver = harness_client_resolver
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
          error = error_payload(e)
          failed_result(
            command_id,
            command_type || "Unknown",
            "Kernel command failed: #{error.fetch("message")}",
            [error.fetch("class"), error.fetch("message")]
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
        when "DismissQuestion"
          dismiss_question(command_id, command_type, payload)
        when "ReconcileSessions"
          reconcile_sessions(command_id: command_id, command_type: command_type)
        when "Prune"
          prune(command_id, command_type, payload)
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
          if %w[completed killed].include?(agent.fetch("status", nil))
            return accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Worker #{agent.fetch("id")} is already #{agent.fetch("status")}.", agent, [])
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

          candidate_pr_urls = worker_pr_urls(last_assistant_text: last_assistant_text, harness_events: harness_events)
          agent["harness_metadata"].delete("delivery_pull_request")
          agent["harness_metadata"].delete("reported_pr_urls")
          agent["harness_metadata"].delete("candidate_pr_urls")
          agent["harness_metadata"]["candidate_pr_urls"] = candidate_pr_urls unless candidate_pr_urls.empty?
          delivery_pull_request = verified_worker_pull_request(agent: agent, project: project, candidate_urls: candidate_pr_urls)
          if delivery_pull_request
            agent["harness_metadata"]["delivery_pull_request"] = delivery_pull_request
            agent["harness_metadata"]["reported_pr_urls"] = [delivery_pull_request.fetch("url")]
          end

          completion_details = {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "settled_event_count" => Array(harness_events).length,
            "last_assistant_text" => present_string(last_assistant_text)
          }.compact
          completion_details["candidate_pr_urls"] = candidate_pr_urls unless candidate_pr_urls.empty?
          completion_details["delivery_pull_request"] = delivery_pull_request if delivery_pull_request

          log_ids = append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "info",
            message: "Worker #{agent.fetch("id")} completed.",
            details: completion_details
          )
          touch_state!(state, now)
          store.save(state)

          accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Marked worker #{agent.fetch("id")} completed.", agent, log_ids)
        end
      end

      def record_user_kernel_command(input:, commands: [])
        synchronized_state do
          state = normalized_state
          command_types = Array(commands).filter_map do |command|
            next unless command.respond_to?(:[])

            command["type"] || command[:type] || command["command_type"] || command[:command_type]
          end
          log_ids = append_log(
            state,
            source_type: "user",
            source_id: nil,
            level: "info",
            message: "User ran kernel command: #{input.to_s}",
            details: { "input" => input.to_s, "command_types" => command_types }
          )
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end

      def reconcile_sessions(command_id: nil, command_type: "ReconcileSessions")
        prune_result = prune_killed_agents
        agents = synchronized_state do
          normalized_state.fetch("agents").select { |agent| reconcile_candidate?(agent) }.map { |agent| deep_copy(agent) }
        end

        poll_results = agents.map { |agent| poll_agent_session(agent) }
        applied_results = poll_results.map { |poll_result| apply_poll_result(poll_result) }
        changed_count = applied_results.count { |result| result.fetch("changed", false) }
        changed_count += 1 if prune_result.fetch("changed", false)
        accepted_result(
          command_id,
          command_type,
          nil,
          "Reconciled #{agents.length} harness-backed agent session(s).",
          {
            "checked_count" => agents.length,
            "changed_count" => changed_count,
            "pruned_agent_ids" => prune_result.fetch("removed_agent_ids", []),
            "poll_results" => applied_results
          },
          (prune_result.fetch("log_entry_ids", []) + applied_results.flat_map { |result| result.fetch("log_entry_ids", []) }).uniq
        )
      rescue StandardError => e
        error = error_payload(e)
        failed_result(command_id, command_type, "Session reconciliation failed: #{error.fetch("message")}", [error.fetch("class"), error.fetch("message")])
      end

      private

      def prune_killed_agents
        synchronized_state do
          state = normalized_state
          killed_agents = state.fetch("agents").select { |agent| agent.fetch("status", nil) == "killed" }
          removed_agent_ids = killed_agents.map { |agent| agent.fetch("id") }
          return { "changed" => false, "removed_agent_ids" => [], "log_entry_ids" => [] } if removed_agent_ids.empty?

          state["agents"] = state.fetch("agents").reject { |agent| removed_agent_ids.include?(agent.fetch("id", nil)) }
          state.fetch("issues").each do |issue|
            next unless issue.key?("agent_ids")

            issue["agent_ids"] = Array(issue["agent_ids"]) - removed_agent_ids
          end

          now = timestamp
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: nil,
            level: "info",
            message: "Removed #{removed_agent_ids.length} killed agent#{removed_agent_ids.length == 1 ? "" : "s"} from active state.",
            details: { "removed_agent_ids" => removed_agent_ids }
          )
          touch_state!(state, now)
          store.save(state)
          { "changed" => true, "removed_agent_ids" => removed_agent_ids, "log_entry_ids" => log_ids }
        end
      end

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

          kill_session_safely(session_ref_from_agent(agent), agent: agent) if present_string(agent.fetch("harness", nil))
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

        if async_heads? && head_runner.respond_to?(:spawn_head_session)
          session_ref = head_runner.spawn_head_session(
            user_message: user_message.to_s,
            snapshot: started.fetch("snapshot"),
            question_id: present_string(question_id),
            context: started.fetch("context")
          )

          return synchronized_state do
            state = normalized_state
            agent = find_agent(state, head_id)
            raise "Head #{head_id} disappeared before its session could be recorded." unless agent

            merge_session_ref_into_agent!(agent, session_ref)
            agent["status"] = "working"
            agent["updated_at"] = timestamp
            log_ids = started.fetch("log_ids")
            log_ids.concat(append_log(
              state,
              source_type: "harness",
              source_id: head_id,
              level: "info",
              message: "Started #{agent.fetch("harness")} head session for #{head_id}; polling will apply its HeadResult when it settles.",
              details: {
                "pid" => agent.fetch("pid", nil),
                "harness_session_id" => agent.fetch("harness_session_id", nil),
                "harness_session_file" => agent.fetch("harness_session_file", nil),
                "is_streaming" => agent.fetch("harness_metadata", {}).fetch("is_streaming", nil)
              }
            ))
            touch_state!(state)
            store.save(state)

            accepted_result(command_id, command_type, head_id, "Spawned head #{head_id}; polling will apply its HeadResult when complete.", agent, log_ids)
          end
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

      def dismiss_question(command_id, command_type, payload)
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        errors = []

        errors << "question_id is required" if blank?(question_id)
        return rejected_result(command_id, command_type, "Question was not dismissed.", errors) unless errors.empty?

        state = normalized_state
        question = find_question(state, question_id)
        return rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"]) unless question

        current_status = question.fetch("status", nil)
        return accepted_result(command_id, command_type, question.fetch("id"), "Question #{question.fetch("id")} is already dismissed.", question, []) if current_status == "dismissed"
        unless current_status == "open"
          return rejected_result(command_id, command_type, "Question #{question.fetch("id")} is #{current_status}, not open.", ["question_not_open"])
        end

        now = timestamp
        question["status"] = "dismissed"
        question["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: question.fetch("id"),
          level: "info",
          message: "Dismissed question #{question.fetch("id")}.",
          details: {
            "head_id" => question.fetch("head_id", nil),
            "project_id" => question.fetch("project_id", nil),
            "issue_id" => question.fetch("issue_id", nil)
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, question.fetch("id"), "Dismissed question #{question.fetch("id")}.", question, log_ids)
      end

      def prune(command_id, command_type, payload)
        selector = value_at(payload, "selector", "Selector", "kind", "status")
        return rejected_result(command_id, command_type, "Prune selector is required.", ["selector is required: merged or errored"]) if blank?(selector)

        case selector.to_s.downcase
        when "merged"
          prune_merged(command_id, command_type)
        when "errored"
          prune_errored(command_id, command_type)
        else
          rejected_result(command_id, command_type, "Unknown prune selector: #{selector}", ["supported selectors: merged, errored"])
        end
      end

      def prune_merged(command_id, command_type)
        state = normalized_state
        delivery_refreshes = refresh_worker_delivery_pull_requests!(state)
        worker_checks = merged_pr_worker_checks(state)
        issue_decisions = merged_pr_issue_decisions(state, worker_checks)
        issue_ids = issue_decisions.select { |decision| decision.fetch("prunable", false) }.map { |decision| decision.fetch("issue_id") }
        now = timestamp
        prune_result = remove_issue_bundles_and_agents!(state, issue_ids: issue_ids, extra_agent_ids: [], reason: "pull_request_merged", now: now)
        checked_urls = worker_checks.flat_map { |check| check.fetch("statuses", []).map { |status| status.fetch("url", nil) } }.compact.uniq
        skipped_urls = issue_decisions.reject { |decision| decision.fetch("prunable", false) }.flat_map { |decision| decision.fetch("pr_urls", []) }.uniq

        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: "Pruned #{prune_result.fetch("removed_issue_ids").length} merged issue bundle#{prune_result.fetch("removed_issue_ids").length == 1 ? "" : "s"}.",
          details: prune_result.merge(
            "selector" => "merged",
            "checked_pr_urls" => checked_urls,
            "skipped_pr_urls" => skipped_urls,
            "worker_checks" => worker_checks,
            "issue_decisions" => issue_decisions,
            "delivery_pull_request_refreshes" => delivery_refreshes
          )
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, nil, "Pruned #{prune_result.fetch("removed_issue_ids").length} merged issue bundle#{prune_result.fetch("removed_issue_ids").length == 1 ? "" : "s"}.", prune_result.merge("checked_pr_urls" => checked_urls, "skipped_pr_urls" => skipped_urls, "issue_decisions" => issue_decisions, "delivery_pull_request_refreshes" => delivery_refreshes), log_ids)
      end

      def prune_errored(command_id, command_type)
        state = normalized_state
        errored_issue_ids = state.fetch("issues").select { |issue| errored_issue_prune_candidate?(state, issue) }.map { |issue| issue.fetch("id") }
        errored_head_ids = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "head" && agent.fetch("status", nil) == "errored" }.map { |agent| agent.fetch("id") }
        now = timestamp
        prune_result = remove_issue_bundles_and_agents!(state, issue_ids: errored_issue_ids, extra_agent_ids: errored_head_ids, reason: "errored", now: now)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: "Pruned #{prune_result.fetch("removed_issue_ids").length} errored issue bundle#{prune_result.fetch("removed_issue_ids").length == 1 ? "" : "s"} and #{prune_result.fetch("removed_standalone_agent_ids").length} standalone errored agent#{prune_result.fetch("removed_standalone_agent_ids").length == 1 ? "" : "s"}.",
          details: prune_result.merge("selector" => "errored")
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, nil, "Pruned #{prune_result.fetch("removed_issue_ids").length} errored issue bundle#{prune_result.fetch("removed_issue_ids").length == 1 ? "" : "s"} and #{prune_result.fetch("removed_standalone_agent_ids").length} standalone errored agent#{prune_result.fetch("removed_standalone_agent_ids").length == 1 ? "" : "s"}.", prune_result, log_ids)
      end

      def refresh_worker_delivery_pull_requests!(state)
        state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }.filter_map do |worker|
          metadata = worker.fetch("harness_metadata", {}) || {}
          candidate_urls = Array(metadata.fetch("candidate_pr_urls", nil)).map(&:to_s).map(&:strip).reject(&:empty?).uniq
          next if candidate_urls.empty?

          issue = find_issue(state, worker.fetch("issue_id", nil))
          project = issue && find_project(state, issue.fetch("project_id", nil))
          next unless project

          delivery_pull_request = verified_worker_pull_request(agent: worker, project: project, candidate_urls: candidate_urls) ||
                                  merged_same_repo_candidate_pull_request(agent: worker, project: project, candidate_urls: candidate_urls)
          next unless delivery_pull_request

          worker["harness_metadata"] = metadata.merge(
            "delivery_pull_request" => delivery_pull_request,
            "reported_pr_urls" => [delivery_pull_request.fetch("url")]
          )

          {
            "agent_id" => worker.fetch("id", nil),
            "issue_id" => worker.fetch("issue_id", nil),
            "url" => delivery_pull_request.fetch("url", nil),
            "matched_by" => delivery_pull_request.fetch("matched_by", nil)
          }.compact
        end
      end

      def merged_pr_worker_checks(state)
        state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }.filter_map do |worker|
          urls = agent_pr_urls(worker)
          next if urls.empty?

          statuses = urls.map { |url| pull_request_status(url) }
          {
            "agent_id" => worker.fetch("id", nil),
            "issue_id" => worker.fetch("issue_id", nil),
            "pr_urls" => urls,
            "statuses" => statuses,
            "merged" => statuses.any? { |status| status.fetch("state", nil) == "merged" }
          }
        end
      end

      def merged_pr_issue_decisions(state, worker_checks)
        checks_by_issue = worker_checks.group_by { |check| check.fetch("issue_id", nil) }
        checks_by_issue.filter_map do |issue_id, checks|
          next if blank?(issue_id)
          next unless find_issue(state, issue_id)

          workers = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id }
          statuses = checks.flat_map { |check| check.fetch("statuses", []) }
          active_worker_ids = workers.select { |worker| prune_blocking_worker_status?(worker.fetch("status", nil)) }.map { |worker| worker.fetch("id", nil) }.compact
          non_merged_statuses = statuses.reject { |status| status.fetch("state", nil) == "merged" }
          merged = statuses.any? { |status| status.fetch("state", nil) == "merged" }
          blockers = []
          blockers << "active_workers" if active_worker_ids.any?
          blockers << "non_merged_pull_requests" if non_merged_statuses.any?
          blockers << "no_merged_pull_request" unless merged

          {
            "issue_id" => issue_id,
            "prunable" => blockers.empty?,
            "blockers" => blockers,
            "active_worker_ids" => active_worker_ids,
            "non_merged_pr_urls" => non_merged_statuses.map { |status| status.fetch("url", nil) }.compact.uniq,
            "pr_urls" => checks.flat_map { |check| check.fetch("pr_urls", []) }.uniq,
            "worker_ids" => workers.map { |worker| worker.fetch("id", nil) }.compact
          }
        end
      end

      def prune_blocking_worker_status?(status)
        %w[queued working idle blocked].include?(status.to_s)
      end

      def verified_worker_pull_request(agent:, project:, candidate_urls:)
        branch = worker_delivery_branch(agent)
        project_repository = project && project_github_repository(project)
        return nil if blank?(branch) || blank?(project_repository)

        Array(candidate_urls).filter_map do |url|
          status = pull_request_status(url)
          next unless verified_worker_pull_request?(status, branch: branch, project_repository: project_repository)

          status.merge(
            "matched_by" => "workspace_branch",
            "matched_branch" => branch,
            "verified_at" => timestamp
          )
        end.first
      end

      def verified_worker_pull_request?(status, branch:, project_repository:)
        status.fetch("provider", nil) == "github" &&
          status.fetch("base_repository", nil).to_s.downcase == project_repository.to_s.downcase &&
          normalized_branch_name(status.fetch("head_branch", nil)) == normalized_branch_name(branch)
      end

      def merged_same_repo_candidate_pull_request(agent:, project:, candidate_urls:)
        return nil unless agent.fetch("status", nil) == "completed"
        return nil unless Array(candidate_urls).compact.uniq.length == 1
        return nil if persisted_worker_delivery_branch(agent)

        project_repository = project && project_github_repository(project)
        return nil if blank?(project_repository)

        status = pull_request_status(Array(candidate_urls).first)
        return nil unless status.fetch("provider", nil) == "github"
        return nil unless status.fetch("state", nil) == "merged"
        return nil unless status.fetch("base_repository", nil).to_s.downcase == project_repository.to_s.downcase
        return nil if status.fetch("is_cross_repository", false)
        return nil unless status.fetch("head_repository", nil).to_s.downcase == project_repository.to_s.downcase

        status.merge(
          "matched_by" => "merged_same_repo_candidate_without_branch",
          "verified_at" => timestamp
        )
      end

      def worker_delivery_branch(agent)
        normalized_branch_name(
          persisted_worker_delivery_branch(agent) ||
            current_workspace_branch_for_delivery(agent)
        )
      end

      def persisted_worker_delivery_branch(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        present_string(metadata.fetch("delivery_branch", nil)) || present_string(agent.fetch("workspace_branch", nil))
      end

      def current_workspace_branch_for_delivery(agent)
        return nil if agent.fetch("workspace_strategy", nil) == "project_root"

        current_workspace_branch(agent)
      end

      def current_workspace_branch(agent)
        workspace_path = agent.fetch("workspace_path", nil)
        return nil if blank?(workspace_path) || !Dir.exist?(workspace_path.to_s)

        stdout, _stderr, status = Open3.capture3("git", "-C", workspace_path.to_s, "branch", "--show-current")
        return nil unless status.success?

        present_string(stdout)
      rescue StandardError
        nil
      end

      def normalized_branch_name(branch)
        value = present_string(branch)
        return nil unless value

        value.sub(/\Arefs\/heads\//, "").sub(/\Aorigin\//, "")
      end

      def project_github_repository(project)
        root_path = project.fetch("root_path", nil)
        return nil if blank?(root_path) || !Dir.exist?(root_path.to_s)

        stdout, _stderr, status = Open3.capture3("git", "-C", root_path.to_s, "remote", "get-url", "origin")
        return nil unless status.success?

        github_repository_from_remote(stdout)
      rescue StandardError
        nil
      end

      def github_repository_from_remote(remote)
        text = remote.to_s.strip.sub(/\.git\z/, "")
        match = text.match(%r{github\.com[:/]([^/]+/[^/]+)\z})
        match && match[1]
      end

      def pull_request_status(url)
        forge_client.pull_request_status(url)
      rescue StandardError => e
        {
          "provider" => "unknown",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => e.message
        }
      end

      def agent_pr_urls(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        delivery_pull_requests = [
          agent.fetch("delivery_pull_request", nil),
          metadata.fetch("delivery_pull_request", nil),
          *Array(agent.fetch("delivery_pull_requests", nil)),
          *Array(metadata.fetch("delivery_pull_requests", nil))
        ].compact
        delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }
                              .map(&:to_s)
                              .map(&:strip)
                              .reject(&:empty?)
                              .uniq
      end

      def errored_issue_prune_candidate?(state, issue)
        return false unless issue.fetch("status", nil) == "errored"

        workers = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue.fetch("id") }
        workers.none? { |worker| %w[queued working idle blocked].include?(worker.fetch("status", nil)) }
      end

      def remove_issue_bundles_and_agents!(state, issue_ids:, extra_agent_ids:, reason:, now:)
        root_issue_ids = Array(issue_ids).compact.uniq
        issue_ids_to_remove = root_issue_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        issues_to_remove = state.fetch("issues").select { |issue| issue_ids_to_remove.include?(issue.fetch("id", nil)) }
        project_ids = issues_to_remove.map { |issue| issue.fetch("project_id", nil) }.compact.uniq
        issue_agent_ids = issues_to_remove.flat_map { |issue| Array(issue.fetch("agent_ids", [])) }
        worker_agent_ids = state.fetch("agents").select { |agent| issue_ids_to_remove.include?(agent.fetch("issue_id", nil)) }.map { |agent| agent.fetch("id", nil) }
        originating_head_ids = issues_to_remove.map { |issue| issue.fetch("originating_head_id", nil) }.compact
        agent_ids_to_remove = (issue_agent_ids + worker_agent_ids + originating_head_ids + Array(extra_agent_ids)).compact.uniq
        standalone_agent_ids = Array(extra_agent_ids).compact.uniq - (issue_agent_ids + worker_agent_ids + originating_head_ids).compact.uniq

        state["issues"] = state.fetch("issues").reject { |issue| issue_ids_to_remove.include?(issue.fetch("id", nil)) }
        state["agents"] = state.fetch("agents").reject { |agent| agent_ids_to_remove.include?(agent.fetch("id", nil)) }
        state.fetch("issues").each do |issue|
          issue["agent_ids"] = Array(issue.fetch("agent_ids", [])) - agent_ids_to_remove if issue.key?("agent_ids")
        end
        refresh_projects_after_prune!(state, project_ids, now)

        {
          "reason" => reason,
          "root_issue_ids" => root_issue_ids,
          "removed_issue_ids" => issue_ids_to_remove,
          "removed_agent_ids" => agent_ids_to_remove,
          "removed_standalone_agent_ids" => standalone_agent_ids,
          "updated_project_ids" => project_ids
        }
      end

      def issue_subtree_ids(state, root_issue_id)
        root = root_issue_id.to_s
        return [] unless find_issue(state, root)

        children = state.fetch("issues").select { |issue| issue.fetch("parent_issue_id", nil) == root }.map { |issue| issue.fetch("id") }
        [root] + children.flat_map { |child_id| issue_subtree_ids(state, child_id) }
      end

      def refresh_projects_after_prune!(state, project_ids, now)
        Array(project_ids).each do |project_id|
          project = find_project(state, project_id)
          next unless project

          remaining_issues = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }
          if remaining_issues.empty?
            project["status"] = "idle"
            project["updated_at"] = now
          else
            update_project_status_from_issues!(state, project, now)
          end
        end
      end

      def clear_state(command_id, command_type)
        now = timestamp
        state = State::Models.empty_state(now: now)
        store.save(state, preserve_conversation: false)

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
        originating_head_id = value_at(payload, "originating_head_id", "originatingHeadId", "_head_id")
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
          "originating_head_id" => present_string(originating_head_id),
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
            preview_agent_id: preview_worker_id(state, issue.fetch("id")),
            task_title: worker_display_title(worker_title, issue),
            create: false
          )
          return rejected_result(command_id, command_type, "Worker workspace is invalid.", workspace.fetch("errors")) unless workspace.fetch("errors").empty?

          now = timestamp
          agent_id = next_worker_id!(state, issue.fetch("id"))
          workspace = resolve_worker_workspace(
            project: project,
            issue: issue,
            requested_workspace_path: requested_workspace_path,
            preview_agent_id: agent_id,
            task_title: worker_display_title(worker_title, issue),
            create: true
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
            session_name: worker_session_name(reservation.fetch("issue"), worker_title: worker_title)
          )
        rescue StandardError => e
          cleanup_worker_workspace_safely(reservation.fetch("workspace"))
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
            cleanup_worker_workspace_safely(reservation.fetch("workspace"))
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
              "workspace_branch" => agent.fetch("workspace_branch"),
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
        cleanup_worker_workspace_safely(reservation.fetch("workspace")) if defined?(reservation) && reservation
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
            "workspace_plan" => workspace.fetch("plan", nil),
            "delivery_branch" => workspace.fetch("workspace_branch", nil)
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

      def resolve_worker_workspace(project:, issue:, requested_workspace_path:, preview_agent_id:, task_title:, create: false)
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

        plan = if create
                 workspace_manager.allocate_worker_workspace(
                   project_root: project.fetch("root_path"),
                   project_id: project.fetch("id"),
                   issue_id: issue.fetch("id"),
                   agent_id: preview_agent_id,
                   task_title: task_title
                 )
               else
                 workspace_manager.plan_worker_workspace(
                   project_root: project.fetch("root_path"),
                   project_id: project.fetch("id"),
                   issue_id: issue.fetch("id"),
                   agent_id: preview_agent_id,
                   task_title: task_title
                 ).merge("errors" => [])
               end

        if plan.fetch("errors", []).any?
          return {
            "workspace_path" => File.expand_path(project.fetch("root_path")),
            "workspace_strategy" => plan.fetch("strategy", "git_worktree"),
            "workspace_branch" => plan.fetch("workspace_branch", nil),
            "plan" => plan,
            "note" => nil,
            "created" => plan.fetch("created", false),
            "errors" => plan.fetch("errors")
          }
        end

        if plan.fetch("strategy", nil) == "project_root"
          return {
            "workspace_path" => File.expand_path(plan.fetch("workspace_path", project.fetch("root_path"))),
            "workspace_strategy" => "project_root",
            "workspace_branch" => nil,
            "plan" => plan.fetch("plan", nil),
            "note" => plan.fetch("fallback_reason", nil),
            "created" => false,
            "errors" => Dir.exist?(project.fetch("root_path")) ? [] : ["project root must be an existing directory"]
          }
        end

        if create && plan.fetch("created", false) && Dir.exist?(plan.fetch("workspace_path"))
          return {
            "workspace_path" => File.expand_path(plan.fetch("workspace_path")),
            "workspace_strategy" => plan.fetch("strategy"),
            "workspace_branch" => plan.fetch("workspace_branch"),
            "plan" => plan,
            "note" => nil,
            "created" => true,
            "errors" => []
          }
        end

        {
          "workspace_path" => File.expand_path(project.fetch("root_path")),
          "workspace_strategy" => "project_root",
          "workspace_branch" => nil,
          "plan" => plan,
          "note" => create ? "Workspace manager did not create a git worktree, so the worker uses the project root cwd." : "Workspace manager planned a git worktree for this worker.",
          "created" => false,
          "errors" => Dir.exist?(project.fetch("root_path")) ? [] : ["project root must be an existing directory"]
        }
      end

      def cleanup_worker_workspace_safely(workspace)
        workspace_manager.release_worker_workspace(workspace, delete_branch: true)
      rescue StandardError
        false
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

      def worker_session_name(issue, worker_title: nil)
        title = human_delivery_title(worker_display_title(worker_title, issue))
        title = "Task" if title.empty?
        title[0, 96]
      end

      def human_delivery_title(value)
        value.to_s.gsub(/\bP\d+(?:-I\d+)?(?:-W\d+)?\b/i, " ")
             .gsub(/\b[HQ]\d+\b/i, " ")
             .strip
             .gsub(/\s+/, " ")
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
        return command unless command.is_a?(Hash)

        payload = value_at(command, "payload") || {}
        enriched_command = if value_at(command, "type", "command_type").to_s == "CreateIssue" && payload.is_a?(Hash)
                             command.merge("payload" => payload.merge("_head_id" => head_id.to_s))
                           else
                             command
                           end
        return enriched_command unless blank?(value_at(enriched_command, "command_id", "id"))

        enriched_command.merge("command_id" => "#{head_id}-C#{index + 1}")
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
          error_info = error_payload(error)
          head["status"] = "errored"
          head["updated_at"] = now
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "error_class" => error_info.fetch("class"),
            "error_message" => error_info.fetch("message")
          )
          append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "error",
            message: "Head #{head_id} failed: #{error_info.fetch("message")}",
            details: { "class" => error_info.fetch("class") }
          )
          touch_state!(state, now)
          store.save(state)
        end
      rescue StandardError
        nil
      end

      def async_heads?
        @async_heads
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

      def worker_pr_urls(last_assistant_text:, harness_events:)
        sources = [present_string(last_assistant_text)]
        Array(harness_events).each do |event|
          sources << serializable_text(event)
        end

        sources.compact.flat_map { |source| extract_pull_request_urls(source) }.uniq
      end

      def extract_pull_request_urls(text)
        text.to_s.scan(PULL_REQUEST_URL_PATTERN).map do |url|
          url.sub(/[.,;:]+\z/, "")
        end
      end

      def serializable_text(value)
        JSON.generate(value)
      rescue StandardError
        value.inspect
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

      def reconcile_candidate?(agent)
        return false if blank?(agent.fetch("harness", nil)) || agent.fetch("harness", nil) == "fake"
        return false unless agent_has_session_reference?(agent)
        return false if %w[completed killed].include?(agent.fetch("status", nil))
        return false unless harness_client_available_for_agent?(agent)
        return true unless agent.fetch("status", nil) == "errored"

        resumable_worker_reconcile_candidate?(agent)
      end

      def harness_client_available_for_agent?(agent)
        !!harness_client_for_agent(agent)
      rescue StandardError
        false
      end

      def agent_has_session_reference?(agent)
        present_string(agent.fetch("pid", nil)) ||
          present_string(agent.fetch("harness_session_id", nil)) ||
          present_string(agent.fetch("harness_session_file", nil))
      end

      def resumable_worker_reconcile_candidate?(agent)
        agent.fetch("type", nil) == "worker" && worker_resume_attempt_count(agent) < WORKER_RECONCILE_RESUME_MAX_ATTEMPTS
      end

      def poll_agent_session(agent)
        client = harness_client_for_agent(agent)
        session_ref = agent_session_ref(agent)
        state_ref = client.get_state(session_ref)
        events = client.respond_to?(:read_events) ? client.read_events(state_ref) : []
        assistant_text = completed_session?(state_ref) ? safe_last_assistant_text(client, state_ref) : nil

        {
          "agent_id" => agent.fetch("id"),
          "agent_type" => agent.fetch("type", nil),
          "state" => completed_session?(state_ref) ? "completed" : "working",
          "session_ref" => state_ref,
          "events" => events,
          "last_assistant_text" => assistant_text
        }
      rescue StandardError => e
        return resume_worker_session_from_poll_error(agent, client, session_ref, e) if worker_reconcile_resume_eligible?(agent, client)

        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => agent.fetch("type", nil),
          "state" => "errored",
          "error" => error_payload(e),
          "reconcile" => reconcile_error_model(agent, e)
        }
      end

      def apply_poll_result(poll_result)
        case poll_result.fetch("state", nil)
        when "working"
          refresh_agent_session_state(poll_result)
        when "completed"
          if poll_result.fetch("agent_type", nil) == "head"
            complete_polled_head(poll_result)
          else
            result = mark_worker_completed(
              agent_id: poll_result.fetch("agent_id"),
              harness_events: poll_result.fetch("events", []),
              last_assistant_text: poll_result.fetch("last_assistant_text", nil)
            )
            poll_result.merge("changed" => result.fetch("status", nil) == "accepted", "completion_result" => result,
                              "log_entry_ids" => result.fetch("log_entry_ids", []))
          end
        when "errored"
          apply_reconcile_error_from_poll(poll_result)
        else
          poll_result.merge("changed" => false, "log_entry_ids" => [])
        end
      end

      def refresh_agent_session_state(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))

          now = timestamp
          merge_session_ref_into_agent!(agent, poll_result.fetch("session_ref", {}))
          agent["status"] = "working"
          agent["updated_at"] = now
          refresh_worker_parent_statuses!(state, agent, now) if agent.fetch("type", nil) == "worker"
          log_ids = append_resume_success_log(state, agent, poll_result)
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => poll_result.fetch("resumed", false), "log_entry_ids" => log_ids)
        end
      end

      def complete_polled_head(poll_result)
        head_result = if head_runner.respond_to?(:parse_head_result_text)
                        head_runner.parse_head_result_text(poll_result.fetch("last_assistant_text", nil).to_s)
                      else
                        Heads::ResultParser.parse(poll_result.fetch("last_assistant_text", nil).to_s)
                      end
        apply_result = @head_result_mutex.synchronize do
          apply_head_result(
            nil,
            "ApplyHeadResult",
            "head_id" => poll_result.fetch("agent_id"),
            "head_result" => head_result
          )
        end
        log_ids = record_polled_head_completion(poll_result, head_result, apply_result)
        kill_completed_head_session(poll_result.fetch("session_ref", {}))
        poll_result.merge(
          "changed" => apply_result.fetch("status", nil) == "accepted",
          "head_result" => head_result,
          "apply_result" => apply_result,
          "log_entry_ids" => (apply_result.fetch("log_entry_ids", []) + log_ids).uniq
        )
      rescue Heads::InvalidHeadResultError => e
        repair_invalid_head_result(poll_result, e)
      rescue StandardError => e
        mark_agent_errored_from_poll(
          poll_result.merge(
            "state" => "errored",
            "error" => { "class" => e.class.name, "message" => e.message }
          )
        )
      end

      def repair_invalid_head_result(poll_result, error)
        agent = synchronized_state { find_agent(normalized_state, poll_result.fetch("agent_id")) }
        return mark_agent_errored_from_poll(invalid_head_result_poll_error(poll_result, error)) unless head_result_repair_eligible?(agent)

        session_ref = poll_result.fetch("session_ref", {})
        client = harness_client_for_agent(agent)
        repaired_ref = prompt_head_result_repair(client, session_ref, error)
        record_head_result_repair_requested(poll_result, error, repaired_ref)
      rescue StandardError => repair_error
        mark_agent_errored_from_poll(
          poll_result.merge(
            "state" => "errored",
            "error" => { "class" => repair_error.class.name, "message" => repair_error.message },
            "reconcile" => {
              "state" => RECONCILE_STATE_TERMINAL_ERROR,
              "error_class" => error.class.name,
              "error_message" => error.message,
              "repair_error_class" => repair_error.class.name,
              "repair_error_message" => repair_error.message
            }
          )
        )
      end

      def invalid_head_result_poll_error(poll_result, error)
        poll_result.merge(
          "state" => "errored",
          "error" => { "class" => error.class.name, "message" => error.message }
        )
      end

      def head_result_repair_eligible?(agent)
        return false unless agent
        return false unless agent.fetch("type", nil) == "head"
        return false if TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil))

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.fetch("head_result_repair_count", 0).to_i < HEAD_RESULT_REPAIR_MAX_ATTEMPTS
      end

      def prompt_head_result_repair(client, session_ref, error)
        mode = session_ref.fetch("is_streaming", false) ? "follow_up" : "normal"
        prompt = <<~PROMPT
          #{HEAD_RESULT_REPAIR_PROMPT}

          Validation error: #{error.message}
        PROMPT
        client.prompt_session(session_ref, prompt, mode: mode)
      end

      def record_head_result_repair_requested(poll_result, error, repaired_ref)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless head
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if TERMINAL_AGENT_STATUSES.include?(head.fetch("status", nil))

          now = timestamp
          metadata = head.fetch("harness_metadata", {}) || {}
          repair_count = metadata.fetch("head_result_repair_count", 0).to_i + 1
          merge_session_ref_into_agent!(head, repaired_ref)
          head["status"] = "working"
          head["updated_at"] = now
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "head_result_repair_count" => repair_count,
            "head_result_repair_requested_at" => now,
            "head_result_repair_error_class" => error.class.name,
            "head_result_repair_error_message" => error.message
          ).compact
          log_ids = append_log(
            state,
            source_type: "head",
            source_id: head.fetch("id"),
            level: "warning",
            message: "Head #{head.fetch("id")} returned invalid HeadResult JSON; requested one repair response.",
            details: {
              "repair_count" => repair_count,
              "error_class" => error.class.name,
              "error_message" => error.message
            }
          )
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("state" => "working", "changed" => true, "repaired" => true, "session_ref" => repaired_ref, "log_entry_ids" => log_ids)
        end
      end

      def record_polled_head_completion(poll_result, head_result, apply_result)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, poll_result.fetch("agent_id"))
          return [] unless head

          now = timestamp
          merge_session_ref_into_agent!(head, poll_result.fetch("session_ref", {}))
          head["status"] = apply_result.fetch("status", nil) == "accepted" ? "completed" : "errored"
          head["updated_at"] = now
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "completed_at" => now,
            "head_result" => head_result,
            "head_result_applied_at" => apply_result.fetch("status", nil) == "accepted" ? now : nil,
            "head_result_apply_status" => apply_result.fetch("status", nil),
            "is_streaming" => false
          ).compact
          log_ids = append_log(
            state,
            source_type: "head",
            source_id: head.fetch("id"),
            level: apply_result.fetch("status", nil) == "accepted" ? "info" : "error",
            message: apply_result.fetch("status", nil) == "accepted" ? "Polled head #{head.fetch("id")} completed and applied its HeadResult." : "Polled head #{head.fetch("id")} completed but its HeadResult was not applied.",
            details: {
              "head_result" => head_result,
              "apply_status" => apply_result.fetch("status", nil),
              "apply_message" => apply_result.fetch("message", nil)
            }
          )
          touch_state!(state, now)
          store.save(state)
          log_ids
        end
      end

      def apply_reconcile_error_from_poll(poll_result)
        if transient_head_reconcile_error?(poll_result)
          defer_head_reconcile_error_from_poll(poll_result)
        elsif worker_resume_failed_reconcile_error?(poll_result)
          defer_worker_reconcile_error_from_poll(poll_result)
        else
          mark_agent_errored_from_poll(poll_result)
        end
      end

      def transient_head_reconcile_error?(poll_result)
        poll_result.fetch("agent_type", nil) == "head" &&
          poll_result.dig("reconcile", "state") == RECONCILE_STATE_TRANSIENT_ERROR
      end

      def worker_resume_failed_reconcile_error?(poll_result)
        poll_result.fetch("agent_type", nil) == "worker" &&
          poll_result.dig("reconcile", "state") == RECONCILE_STATE_RESUME_FAILED
      end

      def reconcile_error_model(agent, error)
        state = agent.fetch("type", nil) == "head" ? RECONCILE_STATE_TRANSIENT_ERROR : RECONCILE_STATE_TERMINAL_ERROR
        {
          "state" => state,
          "agent_type" => agent.fetch("type", nil),
          "error_class" => error.class.name,
          "error_message" => sanitized_error_message(error)
        }
      end

      def worker_reconcile_resume_eligible?(agent, client)
        agent.fetch("type", nil) == "worker" &&
          client.respond_to?(:attach_session) &&
          agent_has_session_reference?(agent) &&
          worker_resume_attempt_count(agent) < WORKER_RECONCILE_RESUME_MAX_ATTEMPTS
      end

      def resume_worker_session_from_poll_error(agent, client, session_ref, original_error)
        attempt = worker_resume_attempt_count(agent) + 1
        resumed_ref = client.attach_session(session_ref)
        resumed_ref = prompt_resumed_worker_session(client, resumed_ref)
        {
          "agent_id" => agent.fetch("id"),
          "agent_type" => "worker",
          "state" => "working",
          "session_ref" => resumed_ref,
          "events" => client.respond_to?(:read_events) ? client.read_events(resumed_ref) : [],
          "last_assistant_text" => nil,
          "resumed" => true,
          "reconcile" => {
            "state" => RECONCILE_STATE_RESUMING,
            "resume_attempt_count" => attempt,
            "resume_attempted_at" => timestamp,
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error)
          }
        }
      rescue StandardError => resume_error
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "worker",
          "state" => "errored",
          "error" => error_payload(resume_error),
          "reconcile" => worker_resume_failed_reconcile_model(agent, original_error, resume_error, attempt)
        }
      end

      def prompt_resumed_worker_session(client, session_ref)
        return session_ref unless client.respond_to?(:prompt_session)
        return session_ref if session_ref.fetch("is_streaming", false)

        client.prompt_session(session_ref, WORKER_RESUME_PROMPT, mode: "normal")
      end

      def worker_resume_failed_reconcile_model(agent, original_error, resume_error, attempt)
        {
          "state" => RECONCILE_STATE_RESUME_FAILED,
          "resume_attempt_count" => attempt,
          "resume_attempts_remaining" => [WORKER_RECONCILE_RESUME_MAX_ATTEMPTS - attempt, 0].max,
          "resume_attempted_at" => timestamp,
          "original_error_class" => original_error.class.name,
          "original_error_message" => sanitized_error_message(original_error),
          "error_class" => resume_error.class.name,
          "error_message" => sanitized_error_message(resume_error)
        }
      end

      def worker_resume_attempt_count(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile.fetch("resume_attempt_count", reconcile.fetch("error_count", 0)).to_i
      end

      def defer_head_reconcile_error_from_poll(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil))
          return mark_agent_errored_from_poll(poll_result) unless agent.fetch("type", nil) == "head"

          now = timestamp
          metadata = agent.fetch("harness_metadata", {}) || {}
          previous_reconcile = metadata.fetch("reconcile", {}) || {}
          first_error_at = previous_reconcile.fetch("first_error_at", nil) || now
          error_count = previous_reconcile.fetch("error_count", 0).to_i + 1
          warning_logged_at = previous_reconcile.fetch("warning_logged_at", nil)

          reconcile = poll_result.fetch("reconcile", {}).merge(
            "state" => RECONCILE_STATE_TRANSIENT_ERROR,
            "first_error_at" => first_error_at,
            "last_error_at" => now,
            "error_count" => error_count,
            "grace_seconds" => HEAD_RECONCILE_ERROR_GRACE_SECONDS,
            "warning_delay_seconds" => HEAD_RECONCILE_WARNING_DELAY_SECONDS,
            "warning_logged_at" => warning_logged_at
          ).compact

          return mark_agent_errored_from_poll(poll_result.merge("reconcile" => reconcile)) unless head_reconcile_grace_active?(first_error_at, now)

          log_ids = []
          if warning_logged_at.nil? && head_reconcile_warning_due?(agent, first_error_at, now)
            reconcile["warning_logged_at"] = now
            log_ids = append_log(
              state,
              source_type: "head",
              source_id: agent.fetch("id"),
              level: "warning",
              message: "Head #{agent.fetch("id")} had a transient harness reconciliation error; keeping it working during the startup grace window.",
              details: reconcile
            )
          end

          agent["status"] = "working"
          agent["updated_at"] = now
          agent["harness_metadata"] = metadata.merge(
            "reconcile_state" => RECONCILE_STATE_TRANSIENT_ERROR,
            "reconcile" => reconcile
          ).compact

          touch_state!(state, now)
          store.save(state)
          poll_result.merge("state" => "working", "changed" => true, "deferred" => true, "reconcile" => reconcile, "log_entry_ids" => log_ids)
        end
      end

      def defer_worker_reconcile_error_from_poll(poll_result)
        return mark_agent_errored_from_poll(poll_result) if poll_result.dig("reconcile", "resume_attempt_count").to_i >= WORKER_RECONCILE_RESUME_MAX_ATTEMPTS

        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))
          return mark_agent_errored_from_poll(poll_result) unless agent.fetch("type", nil) == "worker"

          now = timestamp
          reconcile = poll_result.fetch("reconcile", {}).merge("state" => RECONCILE_STATE_RESUME_FAILED).compact
          agent["status"] = "blocked"
          agent["updated_at"] = now
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "is_streaming" => false,
            "reconcile_state" => RECONCILE_STATE_RESUME_FAILED,
            "reconcile" => reconcile
          ).compact
          refresh_worker_parent_statuses!(state, agent, now)
          log_ids = append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "warning",
            message: "Worker #{agent.fetch("id")} could not resume its harness session; will retry reconciliation.",
            details: reconcile
          )
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => true, "blocked" => true, "reconcile" => reconcile, "log_entry_ids" => log_ids)
        end
      end

      def mark_agent_errored_from_poll(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))

          now = timestamp
          agent["status"] = "errored"
          agent["updated_at"] = now
          reconcile = terminal_reconcile_error_model(poll_result, now)
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "is_streaming" => false,
            "error_class" => poll_result.dig("error", "class"),
            "error_message" => poll_result.dig("error", "message"),
            "errored_at" => now,
            "reconcile_state" => RECONCILE_STATE_TERMINAL_ERROR,
            "reconcile" => reconcile
          ).compact

          if agent.fetch("type", nil) == "worker"
            issue = find_issue(state, agent.fetch("issue_id", nil))
            project = issue && find_project(state, issue.fetch("project_id", nil))
            update_issue_status_from_workers!(state, issue, now) if issue
            update_project_status_from_issues!(state, project, now) if project
          end

          log_ids = append_log(
            state,
            source_type: agent.fetch("type", nil) == "head" ? "head" : "worker",
            source_id: agent.fetch("id"),
            level: "error",
            message: "#{agent.fetch("type", "Agent").capitalize} #{agent.fetch("id")} errored while reconciling its harness session.",
            details: reconcile
          )
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => true, "log_entry_ids" => log_ids)
        end
      end

      def terminal_reconcile_error_model(poll_result, now)
        reconcile = poll_result.fetch("reconcile", {}) || {}
        reconcile.merge(
          "state" => RECONCILE_STATE_TERMINAL_ERROR,
          "last_error_at" => now,
          "error_class" => reconcile.fetch("error_class", poll_result.dig("error", "class")),
          "error_message" => reconcile.fetch("error_message", poll_result.dig("error", "message"))
        ).compact
      end

      def head_reconcile_grace_active?(first_error_at, now)
        (Time.iso8601(now) - Time.iso8601(first_error_at.to_s)) < HEAD_RECONCILE_ERROR_GRACE_SECONDS
      rescue ArgumentError, TypeError
        false
      end

      def head_reconcile_warning_due?(agent, first_error_at, now)
        started_at = agent.fetch("created_at", nil) || first_error_at
        reference_time = [parse_time_or_nil(started_at), parse_time_or_nil(first_error_at)].compact.min
        return true unless reference_time

        (Time.iso8601(now) - reference_time) >= HEAD_RECONCILE_WARNING_DELAY_SECONDS
      rescue ArgumentError, TypeError
        true
      end

      def parse_time_or_nil(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def refresh_worker_parent_statuses!(state, agent, now)
        issue = find_issue(state, agent.fetch("issue_id", nil))
        project = issue && find_project(state, issue.fetch("project_id", nil))
        update_issue_status_from_workers!(state, issue, now) if issue
        update_project_status_from_issues!(state, project, now) if project
      end

      def append_resume_success_log(state, agent, poll_result)
        return [] unless poll_result.fetch("resumed", false)

        append_log(
          state,
          source_type: "worker",
          source_id: agent.fetch("id"),
          level: "info",
          message: "Resumed worker #{agent.fetch("id")} from its harness session and prompted it to continue.",
          details: poll_result.fetch("reconcile", {})
        )
      end

      def completed_session?(session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        return true if metadata.fetch("completed", false)

        pi_state = metadata.fetch("pi_state", {}) || {}
        return true if pi_state["completed"]

        !session_ref.fetch("is_streaming", false)
      end

      def safe_last_assistant_text(client, session_ref)
        return nil unless client.respond_to?(:last_assistant_text)

        client.last_assistant_text(session_ref)
      rescue StandardError
        nil
      end

      def harness_client_for_agent(agent)
        resolved = @harness_client_resolver&.call(agent)
        return resolved if resolved

        if agent.fetch("type", nil) == "head" && head_runner.respond_to?(:harness_client)
          return head_runner.harness_client
        end

        harness_client
      end

      def merge_session_ref_into_agent!(agent, session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        agent["harness"] = session_ref.fetch("harness", agent.fetch("harness", nil))
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["workspace_path"] ||= session_ref.fetch("cwd", nil)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          metadata,
          "cwd" => session_ref.fetch("cwd", metadata.fetch("cwd", nil)),
          "is_streaming" => session_ref.fetch("is_streaming", false),
          "last_event_at" => session_ref.fetch("last_event_at", nil),
          "reconcile_state" => RECONCILE_STATE_HEALTHY,
          "reconcile" => nil
        ).compact
      end

      def kill_completed_head_session(session_ref)
        agent_like = { "type" => "head", "harness" => session_ref.fetch("harness", nil) }
        client = harness_client_for_agent(agent_like)
        client.kill_session(session_ref) if client.respond_to?(:kill_session)
      rescue StandardError
        nil
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

      def kill_session_safely(session_ref, agent: nil)
        client = agent ? harness_client_for_agent(agent) : harness_client
        client.kill_session(session_ref)
      rescue StandardError
        nil
      end

      def head_harness_name
        if head_runner.respond_to?(:harness_client) && head_runner.harness_client
          client = head_runner.harness_client
          return client.harness_name if client.respond_to?(:harness_name)

          client.class.name.to_s.split("::").last.to_s.sub(/Client\z/, "").downcase
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

      def error_payload(error)
        {
          "class" => error.class.name,
          "message" => sanitized_error_message(error)
        }
      end

      def sanitized_error_message(error)
        truncate_for_state(error.message.to_s, ERROR_MESSAGE_MAX_BYTES)
      end

      def truncate_for_state(text, max_bytes)
        return text if text.bytesize <= max_bytes

        text.byteslice(0, max_bytes).to_s.scrub + "\n… [truncated #{text.bytesize - max_bytes} bytes]"
      end

      def timestamp
        Time.now.utc.iso8601
      end
    end
  end
end
