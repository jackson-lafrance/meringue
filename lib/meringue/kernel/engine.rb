# frozen_string_literal: true

require "digest"
require "json"
require "monitor"
require "open3"
require "securerandom"
require "socket"
require "time"
require "zlib"

require_relative "../config"
require_relative "../delivery_artifact_policy"
require_relative "../ids"

module Meringue
  module Kernel
    class Engine
      attr_reader :store, :workspace_manager, :cwd, :forge_client, :config_path,
                  :config, :state_lock, :instance_pid, :instance_id, :prune_forge_lookup_budget,
                  :prune_workspace_cleanup_budget, :post_prune_cleanup_budget, :metric_probe, :goal_advance_budget,
                  :delivery_pull_request_refresh_budget, :worker_provisioning_concurrency

      # `harness_client` and `head_runner` are deliberately *not* plain readers: the
      # constructor may be handed nil clients before any harness is configured, and the
      # provider lambdas resolve the real backend for whichever harness state names now.
      # They are public because embedders (`Heads::PromptLoop`, `Heads::SimpleLoop`) settle
      # spawned workers through them. Defining them here, before `private`, is what keeps
      # them public: an identical pair defined below the `private` keyword used to shadow
      # the readers and silently make both callers raise `NoMethodError`.
      def harness_client
        active_harness_client
      end

      def head_runner
        active_head_runner
      end

      def initialize(store: State::Store.new, harness_client: Harness::FakeClient.new,
                     head_runner: Heads::FakeRunner.new,
                     harness_client_resolver: nil,
                     harness_client_provider: nil,
                     head_runner_provider: nil,
                     default_harness_provider: nil,
                     default_head_harness_provider: nil,
                     default_worker_harness_provider: nil,
                     session_defaults_provider: nil,
                     session_defaults_updater: nil,
                     model_catalog_provider: nil,
                     runtime_config_updater: nil,
                     workspace_manager: Workspace::Manager.new,
                     version_control_backend: nil,
                     cwd: Dir.pwd,
                     async_heads: false,
                     async_worker_provisioning: false,
                     worker_provisioning_concurrency: nil,
                     forge_client: Forge::GitHubClient.new,
                     metric_probe: Goals::MetricProbe.new,
                     config_path: Config::DEFAULT_PATH,
                     config: nil,
                     prune_forge_lookup_budget: PRUNE_FORGE_LOOKUP_BUDGET_SECONDS,
                     prune_workspace_cleanup_budget: PRUNE_WORKSPACE_CLEANUP_BUDGET_SECONDS,
                     delivery_pull_request_refresh_budget: DELIVERY_PULL_REQUEST_REFRESH_BUDGET_SECONDS,
                     goal_advance_budget: GOAL_ADVANCE_BUDGET_SECONDS,
                     post_prune_cleanup_budget: POST_PRUNE_CLEANUP_BUDGET_SECONDS,
                     state_lock: nil,
                     instance_pid: Process.pid,
                     instance_id: nil)
        @store = store
        @harness_client = harness_client
        @head_runner = head_runner
        @harness_client_provider = harness_client_provider
        @head_runner_provider = head_runner_provider
        @default_harness_provider = normalize_initial_harness_provider(default_harness_provider || inferred_default_harness_provider)
        @default_head_harness_provider = normalize_initial_harness_provider(default_head_harness_provider || @default_harness_provider)
        @default_worker_harness_provider = normalize_initial_harness_provider(default_worker_harness_provider || @default_harness_provider)
        @session_defaults_provider = session_defaults_provider
        @session_defaults_updater = session_defaults_updater
        @model_catalog_provider = model_catalog_provider
        @runtime_config_updater = runtime_config_updater
        @workspace_manager = workspace_manager
        @config_path = File.expand_path(config_path.to_s)
        @config = config || Config.load(path: @config_path)
        @version_control_backend = version_control_backend || begin
          configured_backend = @config.setting("version_control.backend").to_s
          configured_backend == "command" ? Meringue::VersionControl::UnavailableBackend.new("alternate") : Meringue::VersionControl::GitHubGitBackend.new(manager: workspace_manager)
        end
        @cwd = File.expand_path(cwd)
        @async_heads = async_heads
        @forge_client = forge_client
        @metric_probe = metric_probe
        @deferred_worker_default_failure_policy = @config.conflict_predecessor_failure
        # The dashboard enables this explicitly. Small synchronous embedders retain their existing
        # apply-and-observe contract unless they opt into the background executor.
        @async_worker_provisioning = !!async_worker_provisioning
        configured_provisioning_concurrency = worker_provisioning_concurrency || @config.worker_provisioning_concurrency
        @worker_provisioning_concurrency = [[Integer(configured_provisioning_concurrency), 1].max,
                                             Config::MAX_WORKER_PROVISIONING_CONCURRENCY].min
        @prune_forge_lookup_budget = Float(prune_forge_lookup_budget)
        @prune_workspace_cleanup_budget = Float(prune_workspace_cleanup_budget)
        @post_prune_cleanup_budget = Float(post_prune_cleanup_budget)
        @delivery_pull_request_refresh_budget = Float(delivery_pull_request_refresh_budget)
        @goal_advance_budget = Float(goal_advance_budget)
        @harness_client_resolver = harness_client_resolver
        @instance_pid = Integer(instance_pid)
        # Identifies this engine across processes. The pid alone is not enough:
        # liveness comes from the pid, identity from this token.
        @instance_id = (instance_id || "#{@instance_pid}-#{SecureRandom.hex(4)}").to_s
        # Meringue instances share one state file, so in-process mutexes alone
        # cannot keep command application exactly-once. The state lock makes each
        # read-modify-write section a single writer across instances.
        @state_lock = state_lock || State::FileLock.for_store(store)
        @state_mutex = Monitor.new
        @head_result_mutex = Mutex.new
        @worker_spawn_mutex = Mutex.new
        @prune_mutex = Mutex.new
        @session_reconcile_mutex = Mutex.new
        @model_catalog_mutex = Mutex.new
        @goal_mutex = Mutex.new
        @worker_provisioning_queue = Queue.new
        @worker_provisioning_jobs = {}
        @worker_provisioning_jobs_mutex = Mutex.new
        @worker_provisioning_jobs_condition = ConditionVariable.new
        @worker_provisioning_threads = []
      end

      # Waits only for work already submitted to this engine. The dashboard never calls this in its
      # input path; it is useful to orderly embedders and deterministic tests that need to observe a
      # completed asynchronous provision without polling state.
      def wait_for_worker_provisioning(timeout: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
        @worker_provisioning_jobs_mutex.synchronize do
          until @worker_provisioning_jobs.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false unless remaining.positive?

            @worker_provisioning_jobs_condition.wait(@worker_provisioning_jobs_mutex, remaining)
          end
        end
        true
      end

      def list_all
        synchronized_state { store.load }
      end

      def apply(command)
        normalized = normalize_command(command)
        command_type = normalized.fetch("type", nil)
        command_id = normalized.fetch("command_id", nil)
        payload = canonicalize_payload_record_ids(normalized.fetch("payload", {}))

        return synchronized_state { rejected_result(command_id, nil, "Kernel command is missing a type.", ["missing_type"]) } if blank?(command_type)

        command_type = canonical_command_type(command_type)

        if command_type == "SpawnHead"
          spawn_head(command_id, command_type, payload)
        elsif command_type == "AnswerQuestion"
          answer_question_and_route(command_id, command_type, payload)
        elsif command_type == "PromptAgent"
          prompt_agent_command(command_id, command_type, payload)
        elsif command_type == "RetryHead"
          retry_head_command(command_id, command_type, payload)
        elsif command_type == "SetWorkerSelectionGuidance"
          set_worker_selection_guidance(command_id, command_type, payload)
        elsif command_type == "SpawnWorker"
          @worker_spawn_mutex.synchronize { spawn_worker(command_id, command_type, payload) }
        elsif command_type == "ApplyHeadResult"
          @head_result_mutex.synchronize { apply_head_result(command_id, command_type, payload) }
        elsif command_type == "ReconcileSessions"
          reconcile_sessions(command_id: command_id, command_type: command_type)
        elsif %w[PauseWorker ResumeWorker].include?(command_type)
          command_type == "PauseWorker" ? pause_worker(command_id, command_type, payload) : resume_worker(command_id, command_type, payload)
        elsif command_type == "ExportWorkers"
          export_workers(command_id, command_type, payload)
        elsif command_type == "ImportWorkers"
          @worker_spawn_mutex.synchronize { import_workers(command_id, command_type, payload) }
        elsif command_type == "Prune"
          @prune_mutex.synchronize { prune(command_id, command_type, payload) }
        elsif command_type == "SetAgentPruneProtection"
          set_agent_prune_protection(command_id, command_type, payload)
        elsif command_type == "SaveConfiguration"
          # The config lock must be acquired before the state lock. Validation and
          # atomic publication happen first; runtime/state mirrors follow.
          save_configuration(command_id, command_type, payload)
        elsif command_type == "TestGitHubAccess"
          # Authentication and repository checks are external I/O. Resolve the gate under the
          # state lock, then run the bounded forge call without holding it.
          test_github_access(command_id, command_type, payload)
        elsif command_type == "SetHarness"
          set_harness(command_id, command_type, payload)
        elsif command_type == "GetModelCatalog"
          # Reading a catalog may start a short-lived harness process, so it must
          # not hold the state lock while it waits on that process.
          get_model_catalog(command_id, command_type, payload)
        elsif command_type == "Kill"
          kill(command_id, command_type, payload)
        elsif command_type == "Recount"
          @worker_spawn_mutex.synchronize { synchronized_state { dispatch_command(command_id, command_type, payload) } }
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
        when "GetSessionDefaults"
          get_session_defaults(command_id, command_type)
        when "GetModelCatalog"
          get_model_catalog(command_id, command_type, payload)
        when "SetDefaultSessionModel"
          set_default_session_model(command_id, command_type, payload)
        when "SetDefaultSessionThinkingLevel"
          set_default_session_thinking_level(command_id, command_type, payload)
        when "SetSessionModel"
          set_session_model(command_id, command_type, payload)
        when "SetSessionThinkingLevel"
          set_session_thinking_level(command_id, command_type, payload)
        when "ListQuestions"
          list_questions(command_id, command_type)
        when "GetInfo"
          get_info(command_id, command_type, payload)
        when "Help"
          help(command_id, command_type)
        when "InvalidSlashCommand"
          invalid_slash_command(command_id, command_type, payload)
        when "CompleteOnboarding"
          complete_onboarding(command_id, command_type, payload)
        when "SaveConfiguration"
          save_configuration(command_id, command_type, payload)
        when "SetWorkerSelectionGuidance"
          set_worker_selection_guidance(command_id, command_type, payload)
        when "TestGitHubAccess"
          test_github_access(command_id, command_type, payload)
        when "SetTheme"
          set_theme(command_id, command_type, payload)
        when "SetHarness"
          set_harness(command_id, command_type, payload)
        when "AddProject"
          add_project(command_id, command_type, payload)
        when "ModifyProject"
          modify_project(command_id, command_type, payload)
        when "CreateIssue"
          create_issue(command_id, command_type, payload)
        when "ModifyIssue"
          modify_issue(command_id, command_type, payload)
        when "MoveWorker"
          move_worker(command_id, command_type, payload)
        when "MoveIssue"
          move_issue(command_id, command_type, payload)
        when "SpawnWorker"
          spawn_worker(command_id, command_type, payload)
        when "PromptAgent"
          prompt_agent(command_id, command_type, payload)
        when "PauseWorker"
          pause_worker(command_id, command_type, payload)
        when "ResumeWorker"
          resume_worker(command_id, command_type, payload)
        when "ExportWorkers"
          export_workers(command_id, command_type, payload)
        when "ImportWorkers"
          import_workers(command_id, command_type, payload)
        when "NoOp"
          no_op(command_id, command_type, payload)
        when "CreateGoal"
          create_goal(command_id, command_type, payload)
        when "ModifyGoal"
          modify_goal(command_id, command_type, payload)
        when "StopGoal"
          stop_goal(command_id, command_type, payload)
        when "ListGoals"
          list_goals(command_id, command_type, payload)
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
        when "SetAgentPruneProtection"
          set_agent_prune_protection(command_id, command_type, payload)
        when "Recount"
          recount(command_id, command_type, payload)
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
    end
  end
end

# One class, split across these files by command family. Each one reopens
# `Meringue::Kernel::Engine`; none of them adds a module to the ancestor chain, so method lookup,
# constants, and instance variables behave exactly as they did when this was a single 20,940-line
# file. `dispatch_command` above is the index: it names every command and the method that answers
# it, and the file that method lives in is the one named for its command family.
require_relative "engine/apply_head_result"
require_relative "engine/command_output"
require_relative "engine/completion_continuations"
require_relative "engine/configuration"
require_relative "engine/constants"
require_relative "engine/deferred_resolution"
require_relative "engine/deferred_workers"
require_relative "engine/delivery_pull_requests"
require_relative "engine/goal_loop"
require_relative "engine/goals"
require_relative "engine/head_batch_targets"
require_relative "engine/head_results"
require_relative "engine/head_sessions"
require_relative "engine/interactive_focus"
require_relative "engine/kill"
require_relative "engine/projects_and_issues"
require_relative "engine/prompting"
require_relative "engine/prune"
require_relative "engine/prune_protection"
require_relative "engine/questions"
require_relative "engine/quiet_workers"
require_relative "engine/reconciliation"
require_relative "engine/record_removal"
require_relative "engine/session_polling"
require_relative "engine/session_recovery"
require_relative "engine/session_settings"
require_relative "engine/settle_failures"
require_relative "engine/spawn_head"
require_relative "engine/spawn_worker"
require_relative "engine/state_access"
require_relative "engine/support"
require_relative "engine/wait_gates"
require_relative "engine/worker_provisioning"
require_relative "engine/worker_sessions"
require_relative "engine/worker_settlement"
require_relative "engine/worker_workspaces"
require_relative "engine/workspace_allocation"
