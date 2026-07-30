# frozen_string_literal: true

require "digest"
require "json"
require "monitor"
require "open3"
require "securerandom"
require "socket"
require "time"

require_relative "../config"
require_relative "../ids"

module Meringue
  module Kernel
    class Engine
      WORKER_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue worker agent. Work only on the assigned issue and workspace.
        Follow the user's prompt and the repository instructions in your working directory.

        You do not directly interface with the user, so do not ask for permission before taking normal implementation or delivery actions requested by the assigned issue. You may edit files, commit, push, and open or update pull requests when the assigned issue asks for those actions.

        The Meringue kernel allocates your workspace before you start. Stay in the assigned workspace and current branch unless the assigned workspace is unusable or the user explicitly asks for a different branch/worktree; report that as a blocker instead of silently creating nested worktrees.

        Before editing, inspect the repository status and active instructions. Avoid overwriting unrelated active work. Treat the assigned workspace as your task branch/worktree for git-backed projects, commit only the assigned issue's changes, and open a pull request when requested and the environment allows.

        Not every worker issue requires a pull request. If the assigned issue is investigation-only or informational and does not require repository changes, return the requested findings or answer without opening a PR unless the issue explicitly asks for one.

        Use human-facing delivery names. Branch names, pull request titles, and pull request metadata should be derived from the assigned issue title or requested change, not from Meringue agent ids, worker ids, Pi ids, or subagent implementation details. If a unique suffix is needed, use a short opaque suffix rather than an orchestration id.

        Report true blockers instead of asking for routine approval: missing credentials, authentication or authorization failures, missing or invalid remotes, branch/worktree collisions, unrelated uncommitted work that would be overwritten, or unsafe/destructive operations.
      PROMPT
      WORKER_RESUME_PROMPT = <<~PROMPT.freeze
        Continue this Meringue worker session from the existing session history and workspace state.
        First inspect the current repository state, then continue the assigned issue from the last incomplete step.
        If the issue is already complete, summarize the final status and include any pull request link.
      PROMPT
      HEAD_RESUME_PROMPT = <<~PROMPT.freeze
        Continue the interrupted Meringue head request from this session's existing context.
        Return exactly one valid HeadResult JSON object and no other text. Do not repeat tool work that is already complete.
      PROMPT
      HEAD_RESULT_REPAIR_PROMPT = <<~PROMPT.freeze
        Your previous response was not valid Meringue HeadResult JSON.
        Return exactly one JSON object with string fields "title" and "summary", an array field "commands", and an array field "questions".
        Do not include markdown, prose, code fences, or tool calls.
      PROMPT
      PULL_REQUEST_URL_PATTERN = /https?:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+(?:[\/?#][^\s<>"'\])}]*)?/.freeze
      # `/prune` is one combined cleanup pass: resolved (completed/killed) and errored records
      # are eligible together, so an errored record is terminal rather than a retention blocker.
      PRUNE_ELIGIBLE_STATUSES = %w[completed killed errored].freeze
      # Only work that could still move on its own retains a record. An errored worker is
      # settled; a queued, working, or blocked worker is not.
      PRUNE_BLOCKING_WORKER_STATUSES = %w[queued working blocked].freeze
      PRUNE_SETTLED_PULL_REQUEST_STATES = %w[merged closed].freeze
      # A merged pull request is terminal on the forge: it can never go back to open. Once Meringue
      # has verified and persisted a merged status for a URL, prune trusts that record instead of
      # spending its bounded forge budget (or, on an unreachable forge, downgrading the URL to
      # `unknown`) to confirm it again. `closed` is deliberately excluded because a closed pull
      # request can be reopened, so it is always re-verified.
      PRUNE_TRUSTED_PULL_REQUEST_STATES = %w[merged].freeze
      # How many retained records the prune message names before it falls back to "and N more". The
      # full per-record reason set always stays in the log details.
      PRUNE_RETENTION_REPORT_LIMIT = 5
      ERROR_MESSAGE_MAX_BYTES = 2_000
      HARNESS_EVENT_LOG_LIMIT = 20
      HARNESS_EVENT_IGNORED_TYPES = %w[
        response state session session_state ping pong heartbeat token text_delta
        content_delta message_delta thinking_delta stream_delta stream_chunk
      ].freeze
      HARNESS_EVENT_LOG_PATTERN = /(process_(?:exit|error|failed)|rpc_parse_error|error|failed|failure)/i.freeze

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
        "set_harness" => "SetHarness",
        "harness" => "SetHarness",
        "help" => "Help",
        "theme" => "SetTheme",
        "set_theme" => "SetTheme",
        "get_state" => "GetState",
        "get_session_defaults" => "GetSessionDefaults",
        "get_model_catalog" => "GetModelCatalog",
        "models" => "GetModelCatalog",
        "list_models" => "GetModelCatalog",
        "set_default_session_model" => "SetDefaultSessionModel",
        "set_default_session_thinking_level" => "SetDefaultSessionThinkingLevel",
        "get_session_settings" => "GetSessionSettings",
        "set_session_model" => "SetSessionModel",
        "set_session_thinking_level" => "SetSessionThinkingLevel",
        "list_questions" => "ListQuestions",
        "reconcile_sessions" => "ReconcileSessions",
        "prune" => "Prune",
        "recount" => "Recount",
        "clear" => "ClearState",
        "clear_state" => "ClearState",
        "list_all" => "ListAll",
        "get_info" => "GetInfo",
        "info" => "GetInfo"
      }.freeze

      HELP_COMMANDS = [
        ["/help", "Show slash command help."],
        ["/theme <name>", "Set and persist the TUI theme. Available: catppuccin, gruvbox, kanagawa, meringue, rose-pine, tokyonight."],
        ["/project add <path> [name]", "Register a project directory."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/prompt <worker_id> \"<message>\"", "Prompt an existing worker agent session."],
        ["/harness <pi|claude|antigravity>", "Select the active harness backend for future heads and workers."],
        ["/defaults", "Show the model and thinking level used for all future Pi heads and workers."],
        ["/models [harness] [refresh]", "List every model the selected harness reports, refreshing the catalog when it is stale."],
        ["/default-model <provider/model>", "Persist the model used for all future Pi heads and workers; existing sessions are unchanged."],
        ["/default-thinking <level>", "Persist the thinking level used for all future Pi heads and workers: off, minimal, low, medium, high, xhigh, or max."],
        ["/session-settings <agent_id>", "Refresh and show one existing agent's effective Pi session model and thinking level."],
        ["/model <agent_id> <provider/model>", "Change only one existing Pi session's model; future-session defaults are unchanged."],
        ["/thinking <agent_id> <level>", "Change only one existing Pi session's thinking level: off, minimal, low, medium, high, xhigh, or max."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/jump [agent_id]", "TUI local: open an agent's focused workspace, or navigate the AgentTree when no id is provided."],
        ["/keybind", "TUI local: show all keybindings."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "List questions and their statuses."],
        ["/answer <question_id> \"<answer>\"", "Answer an open question; the kernel records the answer and routes the work it unblocks."],
        ["/dismiss <question_id>", "Dismiss an open question without answering it."],
        ["/prune", "Remove resolved and errored records plus their safely cleanable managed worktrees."],
        ["/recount", "Compact project, issue, worker, and question IDs after records are removed."],
        ["/clear", "Reset persisted Meringue state and clear the visible logs."]
      ].freeze
      # Every user-facing slash command that maps to a kernel command is also proposable by a
      # head, so "prune the merged issues" is applied, journaled, and logged exactly like a typed
      # `/prune`. Only the kernel/parser internals stay off limits: `ApplyHeadResult` is how the
      # kernel applies a head batch in the first place, and `InvalidSlashCommand` only reports a
      # typing mistake back to the person who typed it.
      HEAD_PROPOSABLE_COMMANDS = %w[
        ListAll GetState GetInfo Help ListQuestions
        GetSessionDefaults GetModelCatalog SetDefaultSessionModel SetDefaultSessionThinkingLevel
        GetSessionSettings SetSessionModel SetSessionThinkingLevel
        AddProject CreateIssue ModifyIssue SpawnWorker PromptAgent SpawnHead
        AskQuestion AnswerQuestion DismissQuestion
        Kill Prune Recount ClearState SetTheme SetHarness ReconcileSessions
      ].freeze
      HEAD_BLOCKED_COMMANDS = %w[ApplyHeadResult InvalidSlashCommand].freeze
      HEAD_UNPROPOSABLE_COMMAND_REASON = "command_not_proposable_by_head"
      # Destructive commands a head may only propose when the user's own message is an
      # unambiguous instruction and the head marks the command user-confirmed. Everything else
      # (Prune, Recount, killing one worker/issue, DismissQuestion) is ordinary housekeeping.
      HEAD_CONFIRMATION_PAYLOAD_KEYS = %w[confirmed_by_user user_confirmed confirmed explicit_user_instruction].freeze
      # Matches only whole-state wipe language. "prune the merged issues" or "delete the completed
      # issues" intentionally do not match, so a vague or prune-flavored prompt can never wipe
      # Meringue state through a head.
      HEAD_CLEAR_STATE_INSTRUCTION_PATTERN = /
        (?:\A|\s)\/clear\b
        |\b(?:clear|reset|wipe|erase|nuke|purge)\b[^.!?\n]{0,40}?\b(?:state|everything|meringue|agent[\s_-]?tree|agenttree|logs|slate|board)\b
      /xi.freeze
      HEAD_KILL_INSTRUCTION_PATTERN = /\b(?:kill|stop|terminate|abort|cancel|shut\s*down|shutdown|halt|nuke|end)\b/i.freeze
      TERMINAL_AGENT_STATUSES = %w[completed errored killed].freeze
      PROMPT_MODES = %w[normal steer follow_up].freeze
      HEAD_RECONCILE_ERROR_GRACE_SECONDS = 30
      HEAD_RECONCILE_WARNING_DELAY_SECONDS = 5
      # Token-overlap ratio above which two clarifications from the same head are treated as
      # one restated question instead of two separate questions.
      DUPLICATE_QUESTION_SIMILARITY_THRESHOLD = 0.6
      # A head command batch is applied by one kernel instance at a time. The applying instance
      # refreshes this lease as it works, so another instance (or another Meringue process
      # sharing the same state file) can tell an in-flight batch from an abandoned one.
      HEAD_RESULT_APPLY_LEASE_SECONDS = 60
      # Heads propose a whole batch at once, so a command that targets an issue created earlier in
      # the same batch cannot know the real issue id yet. These payload keys let a head point at
      # the issue-creating command instead of predicting the id the kernel will mint.
      BATCH_ISSUE_REFERENCE_KEYS = %w[
        issue_from_command IssueFromCommand issueFromCommand
        issue_ref IssueRef issueRef
      ].freeze
      # Marks a symbolic intra-batch reference when it is written in the `issue_id` field, e.g.
      # "@H1-C1" or "@index:0".
      BATCH_REFERENCE_PREFIX = "@"
      # Command types whose payload `issue_id` may be an intra-batch reference.
      BATCH_ISSUE_REFERENCE_COMMANDS = %w[SpawnWorker ModifyIssue AskQuestion].freeze
      # Command types where a wrong predicted issue id would silently route work onto another
      # head's issue, so the kernel verifies the reference before applying them.
      BATCH_ISSUE_GUARDED_COMMANDS = %w[SpawnWorker ModifyIssue].freeze
      # Same idea for a project created earlier in the same batch: a head can point at the
      # AddProject command instead of predicting `P<n>`.
      BATCH_PROJECT_REFERENCE_KEYS = %w[
        project_from_command ProjectFromCommand projectFromCommand
        project_ref ProjectRef projectRef
      ].freeze
      BATCH_PROJECT_REFERENCE_COMMANDS = %w[CreateIssue].freeze
      # A head can queue a worker that only starts once another agent settles ("spawn B, but start
      # it after A finishes"). The dependency is durable state on the queued worker record, not an
      # in-memory timer: the kernel activates it from the worker-settle path and from the
      # reconciliation pass, so it survives a restart.
      DEFERRED_WORKER_AFTER_KEYS = %w[
        after_agent_id AfterAgentID afterAgentId
        after_agent AfterAgent afterAgent
      ].freeze
      # Same intra-batch reference style as issue_from_command: point at the SpawnWorker command in
      # this batch instead of predicting the worker id the kernel will mint.
      DEFERRED_WORKER_AFTER_REFERENCE_KEYS = %w[
        after_from_command AfterFromCommand afterFromCommand
        after_agent_from_command AfterAgentFromCommand afterAgentFromCommand
        after_ref AfterRef afterRef
      ].freeze
      DEFERRED_WORKER_FAILURE_POLICY_KEYS = %w[
        if_predecessor_fails IfPredecessorFails ifPredecessorFails
        on_predecessor_failure OnPredecessorFailure onPredecessorFailure
      ].freeze
      DEFERRED_WORKER_HANDOVER_KEYS = %w[
        include_predecessor_result IncludePredecessorResult includePredecessorResult
      ].freeze
      # `cancel` (default) drops the dependent with a warning when its predecessor errors; `run`
      # starts it anyway and says so in the handover. A killed predecessor always cancels.
      DEFERRED_WORKER_FAILURE_POLICIES = %w[cancel run].freeze
      DEFERRED_WORKER_DEFAULT_FAILURE_POLICY = "cancel"
      # Bounds how long a chain of queued workers may be, so one batch cannot schedule work forever.
      DEFERRED_WORKER_MAX_CHAIN_DEPTH = 5
      # The handover is a bounded excerpt of the predecessor's final report, never a transcript.
      DEFERRED_WORKER_HANDOVER_MAX_CHARS = 4_000
      DEFERRED_STATE_WAITING = "waiting"
      DEFERRED_STATE_ACTIVATING = "activating"
      DEFERRED_STATE_ACTIVATED = "activated"
      DEFERRED_STATE_CANCELLED = "cancelled"
      DEFERRED_PENDING_STATES = [DEFERRED_STATE_WAITING, DEFERRED_STATE_ACTIVATING].freeze
      # The lineage fields need the same treatment as `after_agent_id`: when a head puts a research
      # worker and the implementation worker that follows it on one issue in one batch, the
      # predecessor's agent id only exists after the kernel mints it, so these fields accept the
      # same intra-batch reference instead of a predicted `<issue>-W<n>` id.
      BATCH_AGENT_REFERENCE_FIELDS = [
        {
          "field" => "follow_up_of_agent_id",
          "aliases" => %w[follow_up_of_agent_id FollowUpOfAgentID followUpOfAgentID followUpOfAgentId],
          "reference_keys" => %w[
            follow_up_of_command FollowUpOfCommand followUpOfCommand
            follow_up_of_agent_from_command follow_up_ref followUpRef
          ]
        },
        {
          "field" => "replace_agent_id",
          "aliases" => %w[replace_agent_id ReplaceAgentID replaceAgentID replaceAgentId],
          "reference_keys" => %w[
            replace_agent_from_command ReplaceAgentFromCommand replaceAgentFromCommand
            replace_agent_ref replaceAgentRef
          ]
        }
      ].freeze
      # Predicting a worker id is the failure mode this hint exists for: the predecessor's agent id
      # depends on the issue id the kernel mints, so a prediction goes stale as soon as another head
      # creates an issue first.
      RELATED_AGENT_REFERENCE_HINT = "When the predecessor is spawned by this same head result, " \
                                     "reference its SpawnWorker command (follow_up_of_command, " \
                                     "after_from_command, or an \"@<command_id>\" value) instead of " \
                                     "predicting a worker id."
      # Reconciliation redelivery attempts for a prompt that arrived while the session was busy.
      PENDING_PROMPT_MAX_ATTEMPTS = 20
      HEAD_RESULT_REPAIR_MAX_ATTEMPTS = 1
      HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS = 1
      WORKER_RECONCILE_RESUME_MAX_ATTEMPTS = 3
      DELIVERY_PULL_REQUEST_REFRESH_INTERVAL_SECONDS = 5 * 60
      # `/prune` verifies PR state conservatively, but forge discovery/status commands are external
      # I/O. Bound the whole lookup phase so one unreachable forge cannot leave the command pending
      # indefinitely. URLs not resolved inside the budget become `unknown` and retain their issue.
      PRUNE_FORGE_LOOKUP_BUDGET_SECONDS = 5.0
      # Harness model catalogs change when a user logs into a provider, installs an
      # extension, or edits models.json, so a persisted snapshot is refreshed
      # periodically in the background instead of on every completion keystroke.
      MODEL_CATALOG_REFRESH_INTERVAL_SECONDS = 10 * 60
      # A catalog that could not be read is retried sooner, but not on every
      # 2-second reconciliation pass.
      MODEL_CATALOG_RETRY_INTERVAL_SECONDS = 60
      # How many catalog entries `/models` prints before summarizing the rest.
      MODEL_CATALOG_OUTPUT_LIMIT = 30
      RECONCILE_STATE_HEALTHY = "healthy"
      RECONCILE_STATE_RESUMING = "resuming"
      RECONCILE_STATE_RESUME_FAILED = "resume_failed"
      RECONCILE_STATE_TRANSIENT_ERROR = "transient_error"
      RECONCILE_STATE_TERMINAL_ERROR = "terminal_error"
      # Head sessions live for as long as the head agent record is alive. `pending` is the
      # window between creating the head record and its harness session, `active` means the
      # head owns a tracked session, `released` is terminal, and `unavailable` means the
      # configured head runner cannot back the head with a harness session at all.
      HEAD_SESSION_STATE_PENDING = "pending"
      HEAD_SESSION_STATE_ACTIVE = "active"
      HEAD_SESSION_STATE_RELEASED = "released"
      HEAD_SESSION_STATE_UNAVAILABLE = "unavailable"

      attr_reader :store, :harness_client, :head_runner, :workspace_manager, :cwd, :forge_client, :config_path,
                  :state_lock, :instance_pid, :instance_id, :prune_forge_lookup_budget

      def initialize(store: State::Store.new, harness_client: Harness::FakeClient.new,
                     head_runner: Heads::FakeRunner.new,
                     harness_client_resolver: nil,
                     harness_client_provider: nil,
                     head_runner_provider: nil,
                     default_harness_provider: nil,
                     session_defaults_provider: nil,
                     session_defaults_updater: nil,
                     model_catalog_provider: nil,
                     workspace_manager: Workspace::Manager.new,
                     cwd: Dir.pwd,
                     async_heads: false,
                     forge_client: Forge::GitHubClient.new,
                     config_path: Config::DEFAULT_PATH,
                     prune_forge_lookup_budget: PRUNE_FORGE_LOOKUP_BUDGET_SECONDS,
                     state_lock: nil,
                     instance_pid: Process.pid,
                     instance_id: nil)
        @store = store
        @harness_client = harness_client
        @head_runner = head_runner
        @harness_client_provider = harness_client_provider
        @head_runner_provider = head_runner_provider
        @default_harness_provider = normalize_initial_harness_provider(default_harness_provider || inferred_default_harness_provider)
        @session_defaults_provider = session_defaults_provider
        @session_defaults_updater = session_defaults_updater
        @model_catalog_provider = model_catalog_provider
        @workspace_manager = workspace_manager
        @cwd = File.expand_path(cwd)
        @async_heads = async_heads
        @forge_client = forge_client
        @config_path = File.expand_path(config_path.to_s)
        @prune_forge_lookup_budget = Float(prune_forge_lookup_budget)
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
      end

      def list_all
        synchronized_state { store.load }
      end

      # Opens a read-only harness-neutral transcript handle. The handle cannot
      # attach, detach, signal, or kill the managed process.
      def open_agent_session_view(agent_id)
        agent = synchronized_state do
          candidate = find_agent(normalized_state, agent_id.to_s)
          raise ArgumentError, "Agent #{agent_id} does not exist." unless candidate
          raise ArgumentError, "Agent #{agent_id} is not a worker." unless candidate.fetch("type", nil) == "worker"

          deep_copy(candidate)
        end
        client = harness_client_for_agent(agent)
        client.open_session_view(agent_session_ref(agent))
      end

      # Abort is a turn-level operation, unlike Kill. It preserves the harness
      # process/session and lets reconciliation observe the resulting settled
      # state. This is intentionally not a general process-control API.
      def cancel_agent_turn(agent_id)
        agent = synchronized_state do
          state = normalized_state
          candidate = find_agent(state, agent_id.to_s)
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless candidate
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless candidate.fetch("type", nil) == "worker"
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent_id} is not currently working.", ["agent_not_working"]) unless candidate.fetch("status", nil) == "working"

          deep_copy(candidate)
        end

        client = harness_client_for_agent(agent)
        session_ref = client.abort_session(agent_session_ref(agent))

        synchronized_state do
          state = normalized_state
          current = find_agent(state, agent.fetch("id"))
          return rejected_result(nil, "CancelAgentTurn", "Agent #{agent.fetch("id")} no longer exists.", ["agent_not_found"]) unless current

          now = timestamp
          merge_session_ref_into_agent!(current, session_ref)
          unless TERMINAL_AGENT_STATUSES.include?(current.fetch("status", nil))
            current["status"] = session_ref.fetch("is_streaming", false) ? "working" : "idle"
            current["updated_at"] = now
            current["harness_metadata"] = (current.fetch("harness_metadata", {}) || {}).merge(
              "turn_cancelled_at" => now,
              "is_streaming" => session_ref.fetch("is_streaming", false)
            )
            refresh_worker_parent_statuses!(state, current, now)
          end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: "warning",
            message: "Cancelled the current turn for worker #{current.fetch("id")} without terminating its agent session.",
            details: { "agent_id" => current.fetch("id"), "session_preserved" => true }
          )
          touch_state!(state, now)
          store.save(state)
          accepted_result(nil, "CancelAgentTurn", current.fetch("id"), "Cancelled the current turn for worker #{current.fetch("id")}.", current, log_ids)
        end
      rescue StandardError => e
        synchronized_state do
          error = error_payload(e)
          failed_result(nil, "CancelAgentTurn", "Could not cancel agent #{agent_id}: #{error.fetch("message")}", [error.fetch("class"), error.fetch("message")])
        end
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
        elsif command_type == "SpawnWorker"
          @worker_spawn_mutex.synchronize { spawn_worker(command_id, command_type, payload) }
        elsif command_type == "ApplyHeadResult"
          @head_result_mutex.synchronize { apply_head_result(command_id, command_type, payload) }
        elsif command_type == "ReconcileSessions"
          reconcile_sessions(command_id: command_id, command_type: command_type)
        elsif command_type == "Prune"
          @prune_mutex.synchronize { prune(command_id, command_type, payload) }
        elsif command_type == "GetModelCatalog"
          # Reading a catalog may start a short-lived harness process, so it must
          # not hold the state lock while it waits on that process.
          get_model_catalog(command_id, command_type, payload)
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
        when "GetSessionSettings"
          get_session_settings(command_id, command_type, payload)
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
        when "SetTheme"
          set_theme(command_id, command_type, payload)
        when "SetHarness"
          set_harness(command_id, command_type, payload)
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

      def mark_worker_completed(agent_id:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        result = record_worker_completion(
          agent_id: agent_id,
          harness_events: harness_events,
          last_assistant_text: last_assistant_text,
          session_ref: session_ref
        )
        return result unless result.fetch("status", nil) == "accepted"

        # First of the two activation hooks for queued dependents. Reconciliation is the second, so
        # a dependent cannot be lost if this process dies between A finishing and B starting.
        deferred = resolve_deferred_workers(trigger: "predecessor_settled")
        return result if deferred.empty?

        result.merge(
          "log_entry_ids" => (
            Array(result.fetch("log_entry_ids", [])) +
              deferred.flat_map { |entry| Array(entry.fetch("log_entry_ids", [])) }
          ).uniq,
          "deferred_worker_results" => deferred
        )
      end

      def record_worker_completion(agent_id:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        synchronized_state do
          state = normalized_state
          agent = find_session_agent(state, agent_id: agent_id, session_ref: session_ref)
          return rejected_result(nil, "MarkWorkerCompleted", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          unless agent.fetch("type", nil) == "worker"
            return rejected_result(nil, "MarkWorkerCompleted", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"])
          end
          if %w[completed killed].include?(agent.fetch("status", nil))
            return accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Worker #{agent.fetch("id")} is already #{agent.fetch("status")}.", agent, [])
          end

          merge_session_ref_into_agent!(agent, session_ref) if session_ref
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
          State::Models.scrub_worker_pull_request_keys!(agent["harness_metadata"])
          delivery_pull_request = verified_worker_pull_request(agent: agent, project: project, candidate_urls: candidate_pr_urls)
          attach_issue_pull_requests!(issue, delivery_pull_request, candidate_pr_urls) if issue

          completion_details = {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "settled_event_count" => Array(harness_events).length,
            "last_assistant_text" => present_string(last_assistant_text)
          }.compact
          completion_details["candidate_pr_urls"] = candidate_pr_urls unless candidate_pr_urls.empty?
          completion_details["delivery_pull_request"] = delivery_pull_request if delivery_pull_request

          log_ids = append_harness_event_logs(state, agent, harness_events)
          log_ids.concat(append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "info",
            message: "Worker #{agent.fetch("id")} completed.",
            details: completion_details
          ))
          touch_state!(state, now)
          store.save(state)

          accepted_result(nil, "MarkWorkerCompleted", agent.fetch("id"), "Marked worker #{agent.fetch("id")} completed.", worker_completion_result(agent, issue), log_ids)
        end
      end

      private :record_worker_completion

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
            message: "User ran command: #{input.to_s}",
            details: {
              "input" => input.to_s,
              "command_types" => command_types,
              "kind" => "kernel_command",
              "presentation" => "cmd"
            }
          )
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end

      def record_user_kernel_command_output(input:, command_results: [])
        lines = kernel_command_output_lines(command_results)
        return [] if lines.empty?

        synchronized_state do
          state = normalized_state
          log_ids = lines.flat_map do |line|
            append_log(
              state,
              source_type: "kernel",
              source_id: nil,
              level: "info",
              message: "Command output: #{line}",
              details: {
                "input" => input.to_s,
                "kind" => "kernel_command_output",
                "presentation" => "cmd"
              }
            )
          end
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end

      def reconcile_sessions(command_id: nil, command_type: "ReconcileSessions")
        @session_reconcile_mutex.synchronize do
          reconcile_sessions_once(command_id: command_id, command_type: command_type)
        end
      end

      def reconcile_sessions_once(command_id:, command_type:)
        # Each step is isolated: a single unhealthy record must not turn a routine
        # reconciliation pass into a user-visible "Failed ReconcileSessions" error.
        normalized_state_changed = reconcile_step("normalize_state", false) { persist_normalized_state_if_changed }
        recovered_worker_results = reconcile_step("recover_worker_reservations", []) { recover_worker_reservations }
        pending_prompt_results = reconcile_step("deliver_pending_prompts", []) { deliver_pending_agent_prompts }
        recovered_results = reconcile_step("recover_head_results", []) { recover_unapplied_head_results }
        prune_result = reconcile_step("prune_killed_records", { "changed" => false, "log_entry_ids" => [] }) { prune_killed_records }
        delivery_pr_refreshes = reconcile_step("refresh_delivery_pull_requests", []) { refresh_stale_delivery_pull_requests }
        model_catalog_refresh = reconcile_step("refresh_model_catalog", { "changed" => false }) { refresh_active_model_catalog }
        agents = synchronized_state do
          normalized_state.fetch("agents").select { |agent| reconcile_candidate?(agent) }.map { |agent| deep_copy(agent) }
        end

        poll_results = agents.map { |agent| poll_agent_session(agent) }
        applied_results = poll_results.map { |poll_result| apply_poll_result(poll_result) }
        # Second activation hook for queued dependents. It runs after the polls so a predecessor
        # that settled in this same pass is honoured immediately, and it is the hook that recovers
        # a dependency whose predecessor settled, errored, or disappeared while Meringue was down.
        deferred_worker_results = reconcile_step("resolve_deferred_workers", []) { resolve_deferred_workers(trigger: "reconcile") }
        changed_count = applied_results.count { |result| result.fetch("changed", false) }
        changed_count += deferred_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += recovered_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += pending_prompt_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += recovered_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += 1 if normalized_state_changed
        changed_count += 1 if prune_result.fetch("changed", false)
        changed_count += delivery_pr_refreshes.count { |refresh| refresh.fetch("changed", false) }
        changed_count += 1 if model_catalog_refresh.fetch("changed", false)
        accepted_result(
          command_id,
          command_type,
          nil,
          "Reconciled #{agents.length} agent session(s).",
          {
            "checked_count" => agents.length,
            "changed_count" => changed_count,
            "pruned_issue_ids" => prune_result.fetch("removed_issue_ids", []),
            "pruned_agent_ids" => prune_result.fetch("removed_agent_ids", []),
            "pruned_project_ids" => prune_result.fetch("removed_project_ids", []),
            "recovered_worker_results" => recovered_worker_results,
            "pending_prompt_results" => pending_prompt_results,
            "recovered_head_results" => recovered_results,
            "delivery_pull_request_refreshes" => delivery_pr_refreshes,
            "model_catalog_refresh" => model_catalog_refresh,
            "deferred_worker_results" => deferred_worker_results,
            "poll_results" => applied_results
          },
          (recovered_worker_results.flat_map { |result| result.fetch("log_entry_ids", []) } + pending_prompt_results.flat_map { |result| result.fetch("log_entry_ids", []) } + recovered_results.flat_map { |result| result.fetch("log_entry_ids", []) } + prune_result.fetch("log_entry_ids", []) + applied_results.flat_map { |result| result.fetch("log_entry_ids", []) } + deferred_worker_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) }).uniq
        )
      rescue StandardError => e
        error = error_payload(e)
        failed_result(command_id, command_type, "Session reconciliation failed: #{error.fetch("message")}", [error.fetch("class"), error.fetch("message")])
      end

      private :reconcile_sessions_once

      private

      # Isolates one reconciliation step. A step that raises records a warning and
      # falls back, instead of aborting the whole pass with an error log.
      def reconcile_step(name, fallback)
        yield
      rescue StandardError => e
        synchronized_state do
          state = normalized_state
          append_log(
            state,
            source_type: "kernel",
            source_id: nil,
            level: "warning",
            message: "Skipped session reconciliation step #{name}: #{sanitized_error_message(e)}",
            details: { "step" => name, "error" => error_payload(e) }
          )
          touch_state!(state)
          store.save(state)
        end
        fallback
      end

      # True when another *live* Meringue instance owns this record. Recovery is
      # for records whose owner is gone; stealing in-flight work from a live
      # instance is what applies one logical command twice.
      def owned_by_other_live_instance?(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        !other_live_instance_pid(
          metadata.fetch("owner_instance_id", nil),
          metadata.fetch("owner_instance_pid", nil),
          metadata.fetch("owner_instance_started_at", nil)
        ).nil?
      end

      # Returns the pid of the other live owner, or nil when the record is
      # unowned, owned by this engine, or owned by a process that is gone.
      def other_live_instance_pid(owner_instance_id, owner_instance_pid, owner_started_at = nil)
        return nil if blank?(owner_instance_id) && blank?(owner_instance_pid)
        return nil if present_string(owner_instance_id) && owner_instance_id.to_s == instance_id
        return nil if blank?(owner_instance_id) && owner_instance_pid.to_i == instance_pid

        pid = blank?(owner_instance_pid) ? instance_pid : owner_instance_pid.to_i
        instance_alive?(pid, owner_started_at) ? pid : nil
      end

      # A recorded pid can be reused by an unrelated process, which would make a
      # crashed owner look alive and block recovery forever. The recorded start
      # time settles it when available.
      def instance_alive?(pid, started_at)
        return false unless Harness::ProcessIdentity.alive?(pid)
        return true if blank?(started_at)

        Harness::ProcessIdentity.matches?(pid, started_at: started_at)
      end

      def instance_started_at
        return @instance_started_at if defined?(@instance_started_at)

        described = Harness::ProcessIdentity.describe(instance_pid)
        started_at = described && described.fetch("started_at", nil)
        @instance_started_at = started_at && started_at.iso8601
      end

      def instance_ownership_metadata
        {
          "owner_instance_pid" => instance_pid,
          "owner_instance_id" => instance_id,
          "owner_instance_started_at" => instance_started_at
        }.compact
      end

      def recover_worker_reservations
        reservations = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "worker" && agent.fetch("status", nil) == "queued"
            next if agent_has_session_reference?(agent)
            next if owned_by_other_live_instance?(agent)
            # A worker queued behind another agent is not an interrupted provisioning attempt. It is
            # waiting on purpose, and only resolve_deferred_workers may start it.
            next if waiting_deferred_worker?(agent)

            metadata = agent.fetch("harness_metadata", {}) || {}
            command_id = present_string(metadata.fetch("spawn_command_id", nil))
            prompt = present_string(metadata.fetch("spawn_prompt", nil))
            next unless command_id && prompt

            {
              "command_id" => command_id,
              "type" => "SpawnWorker",
              "payload" => {
                "issue_id" => agent.fetch("issue_id"),
                "title" => metadata.fetch("title", nil),
                "prompt" => prompt,
                "workspace_path" => metadata.fetch("requested_workspace_path", nil),
                "follow_up_of_agent_id" => metadata.fetch("follow_up_of_agent_id", nil),
                "replace_agent_id" => metadata.fetch("replace_agent_id", nil),
                # An activation that was interrupted between the flip and the harness spawn resumes
                # here; it must not be re-evaluated as a fresh deferral request.
                "after_agent_id" => present_string(agent.fetch("after_agent_id", nil)),
                "_activate_deferred" => deferred_spawn_metadata(agent).fetch("state", nil) == DEFERRED_STATE_ACTIVATING
              }
            }
          end
        end
        reservations.map { |command| apply(command) }
      end

      def recover_unapplied_head_results
        candidates = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "head"

            metadata = agent.fetch("harness_metadata", {}) || {}
            head_result = metadata.fetch("head_result", nil)
            next unless head_result.is_a?(Hash)
            next if present_string(metadata.fetch("head_result_applied_at", nil))
            next if owned_by_other_live_instance?(agent)
            next unless metadata.fetch("head_result_apply_state", nil) == "applying" ||
                        (agent.fetch("status", nil) == "completed" && agent_has_session_reference?(agent))
            # Another kernel instance is applying this batch right now; recovering it here would
            # apply every command a second time.
            next if head_result_apply_lease_held_elsewhere?(agent)

            { "head_id" => agent.fetch("id"), "head_result" => deep_copy(head_result) }
          end
        end

        candidates.map do |candidate|
          begin
            @head_result_mutex.synchronize do
              apply_head_result(
                nil,
                "ApplyHeadResult",
                "head_id" => candidate.fetch("head_id"),
                "head_result" => candidate.fetch("head_result"),
                "_recover" => true
              )
            end
          rescue StandardError => e
            synchronized_state do
              rejected_result(
                nil,
                "ApplyHeadResult",
                "Head result recovery for #{candidate.fetch("head_id")} was skipped: #{sanitized_error_message(e)}",
                [e.class.name, sanitized_error_message(e)]
              )
            end
          end
        end
      end

      def kernel_command_output_lines(command_results)
        Array(command_results).flat_map do |result|
          next [] if command_result_already_logged?(result)

          status = result.fetch("status", "unknown")
          command_type = result.fetch("command_type", "command")
          message = result.fetch("message", "").to_s.strip
          lines = ["#{command_type}: #{status}#{message.empty? ? "" : " — #{message}"}"]
          if status == "accepted"
            lines.concat(kernel_command_output_detail_lines(command_type, result.fetch("result", nil)))
          else
            lines.concat(Array(result.fetch("errors", [])).map { |error| "  - #{error}" })
          end
          lines
        end.reject { |line| line.to_s.strip.empty? }
      end

      def command_result_already_logged?(result)
        Array(result.fetch("log_entry_ids", [])).any?
      end

      def kernel_command_output_detail_lines(command_type, result)
        case command_type
        when "SetTheme"
          theme = result.is_a?(Hash) ? result["theme"] : nil
          config_path = result.is_a?(Hash) ? result["config_path"] : nil
          ["  theme: #{theme}", config_path ? "  config: #{config_path}" : nil].compact
        when "SetHarness"
          harness = result.is_a?(Hash) ? result["active_harness"] || result["harness"] : nil
          harness ? ["  harness: #{harness}"] : []
        when "Help"
          Array(result).map { |item| "  #{item.fetch("usage", "")} — #{item.fetch("description", "")}" }
        when "GetModelCatalog"
          model_catalog_output_lines(result)
        when "ListQuestions"
          questions = Array(result)
          return ["  No questions."] if questions.empty?

          lines = questions.map { |question| "  #{question.fetch("id", "?")} [#{question.fetch("status", "?")}] #{question.fetch("question", "")}" }
          open_question = questions.find { |question| question.fetch("status", nil) == "open" }
          if open_question
            lines << "  Answer with /answer #{open_question.fetch("id", "Q1")} \"<answer>\", or just reply in chat and a head will match your reply to the question."
          end
          lines
        when "Prune"
          prune_result = result || {}
          cleanup_outcomes = Array(prune_result["workspace_cleanup_outcomes"])
          retained = Array(prune_result["retention_reasons"])
          [
            "  removed issues: #{Array(prune_result["removed_issue_ids"]).length}",
            "  removed projects: #{Array(prune_result["removed_project_ids"]).length}",
            "  removed agents: #{Array(prune_result["removed_agent_ids"]).length}",
            "  cleaned worktrees: #{cleanup_outcomes.count { |outcome| %w[removed already_removed].include?(outcome["status"]) }}",
            "  blocked worktree cleanups: #{cleanup_outcomes.count { |outcome| !outcome.fetch("success", false) }}",
            "  retained issues: #{Array(prune_result["retained_issue_ids"]).length}",
            *retained.first(PRUNE_RETENTION_REPORT_LIMIT).map do |reason|
              "    #{reason["issue_id"]}: #{Array(reason["blockers"]).join(", ")}"
            end
          ]
        when "Recount"
          mappings = result.is_a?(Hash) ? result.fetch("mappings", {}) : {}
          ["  renamed IDs: #{mappings.values.sum { |mapping| mapping.length }}"]
        when "ClearState"
          ["  state: reset"]
        when "GetInfo"
          info = result.is_a?(Hash) ? result : {}
          record = info.fetch("record", {}) || {}
          deferred = info["deferred_spawn"].is_a?(Hash) ? info["deferred_spawn"] : nil
          waiting_dependents = Array(info["waiting_dependent_agent_ids"])
          [
            "  #{info.fetch("kind", "record")}: #{record["id"] || info["id"]}",
            record["status"] ? "  status: #{record["status"]}" : nil,
            record["title"] || record["name"] || record["question"] ? "  #{record["title"] || record["name"] || record["question"]}" : nil,
            deferred ? "  #{deferred_info_line(deferred)}" : nil,
            waiting_dependents.any? ? "  queued after this worker: #{waiting_dependents.join(", ")}" : nil
          ].compact
        when "ListAll", "GetState"
          state = result || {}
          [
            "  projects: #{Array(state["projects"]).length}",
            "  issues: #{Array(state["issues"]).length}",
            "  agents: #{Array(state["agents"]).length}",
            "  questions: #{Array(state["questions"]).length}"
          ]
        else
          target_id = result.is_a?(Hash) ? result["id"] : nil
          target_id ? ["  target: #{target_id}"] : []
        end
      end

      # Bounded, scannable listing: the full catalog can be over a hundred models,
      # so the chat output shows a window and points at completion for the rest.
      def model_catalog_output_lines(result)
        catalog = result.is_a?(Hash) ? result : {}
        models = Array(catalog["models"])
        lines = ["  harness: #{catalog.fetch("harness", "unknown")}", "  availability: #{catalog.fetch("availability", "unknown")}"]
        lines << "  source: #{catalog.fetch("source")}" if catalog["source"]
        lines << "  confirmed: #{catalog.fetch("fetched_at")}" if catalog["fetched_at"]
        lines << "  last refresh attempt: #{catalog.fetch("last_attempt_at")}" if catalog["last_attempt_at"]
        lines << "  note: #{catalog.fetch("note")}" if catalog["note"]
        return lines if models.empty?

        shown = models.first(MODEL_CATALOG_OUTPUT_LIMIT)
        lines.concat(
          shown.map do |model|
            details = [model["name"], Array(model["thinking_levels"]).empty? ? nil : "thinking: #{Array(model["thinking_levels"]).join(", ")}"].compact
            "  #{model.fetch("reference", "?")}#{details.empty? ? "" : " — #{details.join(" · ")}"}"
          end
        )
        remaining = models.length - shown.length
        lines << "  … and #{remaining} more; press Tab after /model or /default-model to search all #{models.length}." if remaining.positive?
        lines
      end

      def prune_killed_records
        synchronized_state do
          state = normalized_state
          killed_project_ids = state.fetch("projects").select { |project| project.fetch("status", nil) == "killed" }.map { |project| project.fetch("id") }
          killed_issue_ids = state.fetch("issues").select { |issue| issue.fetch("status", nil) == "killed" }.map { |issue| issue.fetch("id") }
          killed_agent_ids = state.fetch("agents").select { |agent| agent.fetch("status", nil) == "killed" }.map { |agent| agent.fetch("id") }
          if killed_project_ids.empty? && killed_issue_ids.empty? && killed_agent_ids.empty?
            return {
              "changed" => false,
              "removed_issue_ids" => [],
              "removed_agent_ids" => [],
              "removed_standalone_agent_ids" => [],
              "removed_project_ids" => [],
              "log_entry_ids" => []
            }
          end

          now = timestamp
          prune_result = remove_issue_bundles_and_agents!(
            state,
            issue_ids: killed_issue_ids,
            project_ids: killed_project_ids,
            extra_agent_ids: killed_agent_ids,
            reason: "killed",
            now: now,
            remove_empty_projects: false,
            cleanup_worker_workspaces: true
          )
          removed_project_ids = prune_result.fetch("removed_project_ids", [])
          touch_state!(state, now)
          store.save(state)
          prune_result.merge(
            "changed" => true,
            "removed_project_ids" => removed_project_ids,
            "log_entry_ids" => prune_result.fetch("workspace_cleanup_log_entry_ids", [])
          )
        end
      end

      def get_state(command_id, command_type)
        accepted_result(command_id, command_type, nil, "Loaded Meringue state.", store.load, [])
      end

      def get_session_defaults(command_id, command_type)
        state = normalized_state
        defaults = configured_pi_session_defaults
        message = pi_session_defaults_message(defaults)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: message,
          details: defaults.merge("config_path" => config_path)
        )
        touch_state!(state)
        store.save(state)
        accepted_result(command_id, command_type, "pi", message, defaults.merge("config_path" => config_path), log_ids)
      end

      # Lists the models the selected harness itself reports. The catalog is
      # cached in state metadata so completion never has to start a harness
      # process while the user types.
      def get_model_catalog(command_id, command_type, payload)
        requested = value_at(payload, "harness", "provider", "Harness", "Provider")
        provider =
          if blank?(requested)
            synchronized_state { active_harness_provider(normalized_state) }
          else
            begin
              Meringue::Harness::Registry.normalize_provider!(requested)
            rescue ArgumentError => e
              return synchronized_state do
                rejected_result(command_id, command_type, "Model catalog was not loaded.", [e.message])
              end
            end
          end

        force = model_catalog_force_flag?(value_at(payload, "refresh", "force", "Refresh", "Force"))
        catalog = refresh_model_catalog!(provider: provider, force: force)
        accepted_result(
          command_id,
          command_type,
          catalog.fetch("harness", nil),
          model_catalog_message(catalog),
          catalog,
          []
        )
      rescue StandardError => e
        synchronized_state do
          error = error_payload(e)
          failed_result(
            command_id,
            command_type,
            "Could not load the model catalog: #{error.fetch("message")}",
            [error.fetch("class"), error.fetch("message")]
          )
        end
      end

      def model_catalog_force_flag?(value)
        return false if value.nil?
        return value if value == true || value == false

        %w[true yes 1 refresh reload force].include?(value.to_s.strip.downcase)
      end

      def model_catalog_message(catalog)
        harness = catalog.fetch("harness", "harness")
        count = catalog.fetch("model_count", Array(catalog["models"]).length)
        case catalog.fetch("availability", nil)
        when Meringue::Harness::ModelCatalog::AVAILABLE
          "#{harness} reports #{count} available model#{count == 1 ? "" : "s"}. " \
            "Use /default-model <provider/model> for future sessions or /model <agent_id> <provider/model> for one session."
        when Meringue::Harness::ModelCatalog::STALE
          "Showing the last #{count} model#{count == 1 ? "" : "s"} #{harness} confirmed at #{catalog.fetch("fetched_at", "an earlier time")}; " \
            "the newest refresh failed: #{catalog.fetch("note", "unknown error")}"
        else
          note = catalog.fetch("note", nil)
          blank?(note) ? "No #{harness} model catalog is available." : note.to_s
        end
      end

      # Fetching a catalog can start a harness process, so the fetch happens
      # outside the state lock and only the resulting snapshot is persisted.
      def refresh_model_catalog!(provider:, force: false)
        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        @model_catalog_mutex.synchronize do
          existing = persisted_model_catalog(public_name)
          return existing if existing && !force && !model_catalog_stale?(existing)

          snapshot = merged_model_catalog(fetch_model_catalog(provider), existing)
          persist_model_catalog!(public_name, snapshot)
          snapshot
        end
      end

      # A failed or empty refresh must never shrink a working model list. A harness
      # hiccup (restart, provider auth blip, sleeping laptop) would otherwise drop
      # the selector back to the couple of references Meringue remembers, which
      # looks exactly like the catalog never worked. Keep the last list the harness
      # confirmed, marked stale with the failure attached.
      def merged_model_catalog(fetched, existing)
        catalog = Meringue::Harness::ModelCatalog.coerce(fetched)
        return catalog.to_h if catalog.usable?

        previous = Meringue::Harness::ModelCatalog.coerce(existing)
        return catalog.to_h unless previous.usable?

        Meringue::Harness::ModelCatalog.retained(previous: previous, failure: catalog).to_h
      end

      def persisted_model_catalog(public_name)
        synchronized_state do
          catalog = normalized_state.dig("metadata", "harness_model_catalogs", public_name)
          catalog.is_a?(Hash) ? deep_copy(catalog) : nil
        end
      end

      def persist_model_catalog!(public_name, snapshot)
        synchronized_state do
          state = normalized_state
          catalogs = (state.fetch("metadata")["harness_model_catalogs"] ||= {})
          catalogs[public_name] = deep_copy(snapshot)
          touch_state!(state)
          store.save(state)
        end
      end

      def fetch_model_catalog(provider)
        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        unless @model_catalog_provider
          return Meringue::Harness::ModelCatalog.unsupported(
            harness: public_name,
            note: "This Meringue instance has no harness model catalog source configured, " \
                  "so #{public_name} models cannot be listed."
          ).to_h
        end

        Meringue::Harness::ModelCatalog.coerce(
          @model_catalog_provider.call(provider),
          harness: public_name
        ).to_h
      rescue StandardError => e
        Meringue::Harness::ModelCatalog.unavailable(
          harness: public_name,
          note: "Could not read the #{public_name} model catalog: #{sanitized_error_message(e)}",
          reason: "fetch_failed",
          error: e.class.name
        ).to_h
      end

      # Refresh cadence is measured from the last fetch *attempt*, so a retained
      # (stale) list is retried on the failure cadence instead of being re-probed
      # on every pass just because its confirmed timestamp is old.
      def model_catalog_stale?(snapshot)
        return true unless snapshot.is_a?(Hash)

        catalog = Meringue::Harness::ModelCatalog.from_h(snapshot)
        age = catalog.attempt_age_seconds
        return true if age.nil?
        return false if age.negative?

        age >= (catalog.available? ? MODEL_CATALOG_REFRESH_INTERVAL_SECONDS : MODEL_CATALOG_RETRY_INTERVAL_SECONDS)
      end

      # Background refresh for the harness that future sessions will use. Silent
      # by design: an expected "no catalog yet" state is surfaced in `/models`
      # and in completion, not as repeated durable log entries.
      def refresh_active_model_catalog
        return { "changed" => false, "skipped" => "no_catalog_source" } unless @model_catalog_provider

        provider = synchronized_state { active_harness_provider(normalized_state) }
        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        existing = persisted_model_catalog(public_name)
        if existing && !model_catalog_stale?(existing)
          return {
            "changed" => false,
            "harness" => public_name,
            "availability" => existing.fetch("availability", nil),
            "model_count" => existing.fetch("model_count", 0)
          }
        end

        snapshot = refresh_model_catalog!(provider: provider)
        {
          "changed" => existing.nil? || existing.fetch("fetched_at", nil) != snapshot.fetch("fetched_at", nil),
          "harness" => public_name,
          "availability" => snapshot.fetch("availability", nil),
          "model_count" => snapshot.fetch("model_count", 0)
        }
      end

      def set_default_session_model(command_id, command_type, payload)
        model_reference = value_at(payload, "model", "model_reference", "Model", "ModelReference")
        return rejected_result(command_id, command_type, "Default Pi model was not changed.", ["model is required"]) if blank?(model_reference)
        unless model_reference.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z})
          return rejected_result(
            command_id,
            command_type,
            "Default Pi model was not changed.",
            ["model must use an exact provider/model id, for example openai/gpt-5.6-sol"]
          )
        end

        update_pi_session_defaults(
          command_id,
          command_type,
          model: model_reference.to_s,
          changed_field: "model"
        )
      end

      def set_default_session_thinking_level(command_id, command_type, payload)
        level = value_at(payload, "level", "thinking_level", "Level", "ThinkingLevel").to_s.strip.downcase
        unless Meringue::Harness::PiClient::THINKING_LEVELS.include?(level)
          return rejected_result(
            command_id,
            command_type,
            "Default Pi thinking level was not changed.",
            ["thinking level must be one of: #{Meringue::Harness::PiClient::THINKING_LEVELS.join(", ")}"]
          )
        end

        update_pi_session_defaults(
          command_id,
          command_type,
          thinking_level: level,
          changed_field: "thinking_level"
        )
      end

      def update_pi_session_defaults(command_id, command_type, model: nil, thinking_level: nil, changed_field:)
        previous = configured_pi_session_defaults
        defaults = if @session_defaults_updater
                     @session_defaults_updater.call("pi", model: model, thinking_level: thinking_level)
                   else
                     saved = Config.save_pi_session_defaults!(
                       model: model,
                       thinking_level: thinking_level,
                       path: config_path
                     )
                     Meringue::Harness::Registry.new(config: saved).session_defaults(provider: "pi")
                   end
        defaults = Config.deep_stringify(defaults)
        state = normalized_state
        state.fetch("metadata")["pi_session_defaults"] = deep_copy(defaults)
        unchanged_ids = existing_pi_session_ids(state)
        value = changed_field == "model" ? defaults.fetch("model", model) : defaults.fetch("thinking_level", thinking_level)
        label = changed_field == "model" ? "model" : "thinking level"
        message = "Set the default Pi #{label} to #{value} for all future Pi heads and workers. " \
                  "Existing Pi sessions were not changed#{unchanged_ids.empty? ? "." : ": #{unchanged_ids.join(", ")}."}"
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: message,
          details: {
            "changed_field" => changed_field,
            "previous_defaults" => previous,
            "pi_session_defaults" => defaults,
            "scope" => "future_pi_sessions",
            "existing_session_ids_unchanged" => unchanged_ids,
            "config_path" => config_path
          }
        )
        touch_state!(state)
        store.save(state)
        accepted_result(
          command_id,
          command_type,
          "pi",
          message,
          defaults.merge(
            "config_path" => config_path,
            "existing_session_ids_unchanged" => unchanged_ids
          ),
          log_ids
        )
      rescue Config::ParseError => e
        rejected_result(command_id, command_type, "Default Pi session settings were not changed because config could not be read.", [e.message])
      end

      def configured_pi_session_defaults
        defaults = if @session_defaults_provider
                     @session_defaults_provider.call("pi")
                   else
                     config = Config.load(path: config_path)
                     Meringue::Harness::Registry.new(config: config).session_defaults(provider: "pi")
                   end
        Config.deep_stringify(defaults)
      rescue Config::ParseError
        fallback_pi_session_defaults
      end

      def fallback_pi_session_defaults
        model = Meringue::Harness::Registry::DEFAULT_PI_MODEL
        thinking = Meringue::Harness::Registry::DEFAULT_PI_THINKING_LEVEL
        {
          "harness" => "pi",
          "model" => model,
          "thinking_level" => thinking,
          "consistency" => "consistent",
          "roles" => {
            "head" => { "model" => model, "thinking_level" => thinking },
            "worker" => { "model" => model, "thinking_level" => thinking }
          },
          "scope" => "future_pi_sessions"
        }
      end

      def existing_pi_session_ids(state)
        state.fetch("agents", []).select do |agent|
          agent.fetch("harness", nil).to_s == "pi" && agent_has_session_reference?(agent)
        end.map { |agent| agent.fetch("id", nil) }.compact
      end

      def pi_session_defaults_message(defaults)
        model = defaults.fetch("model", nil) || "mixed by role"
        thinking = defaults.fetch("thinking_level", nil) || "mixed by role"
        "Future Pi heads and workers use #{model} with thinking #{thinking}. Existing sessions keep their own effective settings."
      end

      def get_session_settings(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "target_id", "AgentID", "TargetID")
        state = normalized_state
        agent, rejection = session_settings_target(state, command_id, command_type, agent_id)
        return rejection if rejection

        client = harness_client_for_agent(agent)
        outcome = client.get_session_settings(agent_session_ref(agent))
        persist_session_settings_result!(agent, outcome)
        settings = outcome.fetch("settings")
        message = session_settings_message(agent.fetch("id"), settings)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: message,
          details: { "agent_id" => agent.fetch("id"), "session_settings" => settings }
        )
        touch_state!(state)
        store.save(state)
        accepted_result(command_id, command_type, agent.fetch("id"), message, session_settings_result(agent, settings), log_ids)
      rescue StandardError => e
        failed_result(
          command_id,
          command_type,
          "Could not inspect session settings for #{agent_id}: #{sanitized_error_message(e)}",
          [e.class.name, sanitized_error_message(e)]
        )
      end

      def set_session_model(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "target_id", "AgentID", "TargetID")
        model_reference = value_at(payload, "model", "model_reference", "Model", "ModelReference")
        return rejected_result(command_id, command_type, "Session model was not changed.", ["model is required"]) if blank?(model_reference)
        unless model_reference.to_s.match?(%r{\A[^/\s]+/[^/\s]+\z})
          return rejected_result(
            command_id,
            command_type,
            "Session model was not changed.",
            ["model must use an exact provider/model id, for example openai/gpt-5.6-sol"]
          )
        end

        state = normalized_state
        agent, rejection = session_settings_target(state, command_id, command_type, agent_id)
        return rejection if rejection

        previous = deep_copy(agent.fetch("session_settings", {}) || {})
        client = harness_client_for_agent(agent)
        outcome = client.set_session_model(agent_session_ref(agent), model_reference.to_s)
        persist_session_settings_result!(agent, outcome)
        settings = outcome.fetch("settings")
        message = "Updated #{agent.fetch("id")} session model to #{settings.dig("model", "reference") || "unknown"}; " \
                  "effective thinking is #{settings.fetch("thinking_level", nil) || "unknown"}. This session only; defaults were not changed."
        log_ids = log_session_settings_update(state, agent, message, previous, settings, "model")
        accepted_result(command_id, command_type, agent.fetch("id"), message, session_settings_result(agent, settings), log_ids)
      rescue StandardError => e
        failed_result(
          command_id,
          command_type,
          "Could not update session model for #{agent_id}: #{sanitized_error_message(e)}",
          [e.class.name, sanitized_error_message(e)]
        )
      end

      def set_session_thinking_level(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "target_id", "AgentID", "TargetID")
        level = value_at(payload, "level", "thinking_level", "Level", "ThinkingLevel")
        return rejected_result(command_id, command_type, "Session thinking level was not changed.", ["thinking level is required"]) if blank?(level)

        state = normalized_state
        agent, rejection = session_settings_target(state, command_id, command_type, agent_id)
        return rejection if rejection

        previous = deep_copy(agent.fetch("session_settings", {}) || {})
        client = harness_client_for_agent(agent)
        outcome = client.set_session_thinking_level(agent_session_ref(agent), level.to_s)
        persist_session_settings_result!(agent, outcome)
        settings = outcome.fetch("settings")
        message = "Updated #{agent.fetch("id")} session thinking level to #{settings.fetch("thinking_level", nil) || "unknown"}; " \
                  "effective model is #{settings.dig("model", "reference") || "unknown"}. This session only; defaults were not changed."
        log_ids = log_session_settings_update(state, agent, message, previous, settings, "thinking_level")
        accepted_result(command_id, command_type, agent.fetch("id"), message, session_settings_result(agent, settings), log_ids)
      rescue StandardError => e
        failed_result(
          command_id,
          command_type,
          "Could not update session thinking level for #{agent_id}: #{sanitized_error_message(e)}",
          [e.class.name, sanitized_error_message(e)]
        )
      end

      def session_settings_target(state, command_id, command_type, agent_id)
        return [nil, rejected_result(command_id, command_type, "A target agent id is required.", ["agent_id is required"])] if blank?(agent_id)

        agent = find_agent(state, agent_id.to_s)
        return [nil, rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"])] unless agent
        return [nil, rejected_result(command_id, command_type, "Agent #{agent_id} has been killed and is not resumable.", ["session_unavailable"])] if agent.fetch("status", nil) == "killed"
        unless agent_has_session_reference?(agent)
          return [nil, rejected_result(command_id, command_type, "Agent #{agent_id} has no harness session.", ["missing_harness_session"])]
        end

        client = harness_client_for_agent(agent)
        unless client.respond_to?(:session_settings_supported?) && client.session_settings_supported?
          harness = agent.fetch("harness", "unknown")
          return [nil, rejected_result(
            command_id,
            command_type,
            "#{harness} session settings are not supported yet; model and thinking controls are currently Pi-only.",
            ["unsupported_harness"]
          )]
        end

        [agent, nil]
      end

      def persist_session_settings_result!(agent, outcome)
        session_ref = outcome.fetch("session_ref")
        merge_session_ref_into_agent!(agent, session_ref)
        agent["session_settings"] = deep_copy(outcome.fetch("settings"))
        agent["updated_at"] = timestamp
      end

      def log_session_settings_update(state, agent, message, previous, settings, field)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: message,
          details: {
            "agent_id" => agent.fetch("id"),
            "changed_field" => field,
            "previous_session_settings" => previous,
            "session_settings" => settings,
            "scope" => "current_session"
          }
        )
        touch_state!(state)
        store.save(state)
        log_ids
      end

      def session_settings_message(agent_id, settings)
        model = settings.dig("model", "reference") || "unknown"
        thinking = settings.fetch("thinking_level", nil) || "unknown"
        source = settings.fetch("source", "harness")
        "#{agent_id} session uses #{model} with thinking #{thinking} (source: #{source})."
      end

      def session_settings_result(agent, settings)
        {
          "agent_id" => agent.fetch("id"),
          "harness" => agent.fetch("harness", nil),
          "scope" => "current_session",
          "session_settings" => settings
        }
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

      def set_theme(command_id, command_type, payload)
        requested_theme = value_at(payload, "theme", "Theme", "name", "Name")
        return rejected_result(command_id, command_type, "Theme was not changed.", ["theme is required"]) if blank?(requested_theme)

        theme = normalized_theme_name(requested_theme)
        unless theme_names.include?(theme)
          return rejected_result(
            command_id,
            command_type,
            "Unknown theme: #{requested_theme}",
            ["available themes: #{theme_names.join(", ")}"]
          )
        end

        Config.save_tui_theme!(theme, path: config_path)
        apply_tui_theme(theme)

        state = normalized_state
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: "Set TUI theme to #{theme}.",
          details: { "theme" => theme, "config_path" => config_path }
        )
        touch_state!(state)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          theme,
          "Set TUI theme to #{theme} and saved it to #{config_path}.",
          { "theme" => theme, "config_path" => config_path, "available_themes" => theme_names },
          log_ids
        )
      rescue Config::ParseError => e
        rejected_result(command_id, command_type, "Theme was not changed because config could not be read.", [e.message])
      end

      def set_harness(command_id, command_type, payload)
        requested_provider = value_at(payload, "provider", "Provider", "harness", "Harness")
        return rejected_result(command_id, command_type, "Harness was not changed.", ["provider is required"]) if blank?(requested_provider)

        provider = normalize_selectable_harness_provider(requested_provider)
        unless provider
          supported = Meringue::Harness::Registry.supported_provider_names.join(", ")
          return rejected_result(
            command_id,
            command_type,
            "Unsupported harness provider #{requested_provider.inspect}. Choose one of: #{supported}.",
            ["unsupported_harness_provider"]
          )
        end

        state = normalized_state
        # A head may propose `/harness` for itself; it is not its own blocker. The switch only
        # affects future heads and workers, and this head's session is torn down right after.
        proposing_head_id = present_string(value_at(payload, "_head_id", "head_id", "HeadID", "headId"))
        active_agents = active_harness_selection_blockers(state) - [proposing_head_id].compact
        if active_agents.any?
          return rejected_result(
            command_id,
            command_type,
            "Harness was not changed because #{active_agents.length} agent#{active_agents.length == 1 ? " is" : "s are"} active or working: #{active_agents.join(", ")}.",
            ["active_agents", *active_agents]
          )
        end

        previous_provider = active_harness_provider(state)
        previous_public_provider = Meringue::Harness::Registry.public_provider_name(previous_provider)
        public_provider = Meringue::Harness::Registry.public_provider_name(provider)
        now = timestamp
        metadata = state.fetch("metadata")
        changed = previous_provider != provider
        metadata["active_harness"] = public_provider
        metadata["active_harness_label"] = Meringue::Harness::Registry.provider_label(provider)
        metadata["harness_selected_at"] = now
        metadata["harness_generation"] = metadata.fetch("harness_generation", 0).to_i + (changed ? 1 : 0)

        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: changed ? "Selected #{metadata.fetch("active_harness_label")} harness for future agents." : "#{metadata.fetch("active_harness_label")} harness is already selected.",
          details: {
            "previous_harness" => previous_public_provider,
            "active_harness" => public_provider,
            "internal_active_harness" => provider,
            "harness_generation" => metadata.fetch("harness_generation")
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          public_provider,
          changed ? "Selected #{metadata.fetch("active_harness_label")} for future heads and workers." : "#{metadata.fetch("active_harness_label")} is already the active harness.",
          {
            "active_harness" => public_provider,
            "active_harness_label" => metadata.fetch("active_harness_label"),
            "previous_harness" => previous_public_provider,
            "internal_active_harness" => provider,
            "harness_generation" => metadata.fetch("harness_generation")
          },
          log_ids
        )
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
        return rejected_result(command_id, command_type, "Agent #{agent_id} has no agent session.", ["agent_has_no_harness_session"]) if blank?(agent.fetch("harness", nil))
        return rejected_result(command_id, command_type, "Agent #{agent_id} is killed.", ["agent_killed"]) if agent.fetch("status", nil) == "killed"

        client = harness_client_for_agent(agent)
        session_ref = session_ref_from_agent(agent)
        updated_ref = client.prompt_session(session_ref, prompt.to_s, mode: mode.to_s)
        now = timestamp
        apply_session_ref_to_agent!(agent, updated_ref)
        agent["status"] = "working"
        agent["updated_at"] = now
        refresh_worker_parent_statuses!(state, agent, now)

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
        # A worker queued behind a killed agent can never settle its predecessor, so it is cancelled
        # in the same command instead of waiting forever on a record that is being removed.
        cancelled_dependents = cancel_deferred_dependents_in_state!(
          state,
          killed_agent_ids,
          now: now,
          reason: "predecessor_killed",
          trigger: "kill"
        )
        killed_agent_ids = (killed_agent_ids + cancelled_dependents.fetch("agent_ids")).uniq
        killed_agent_ids.each do |agent_id|
          agent = find_agent(state, agent_id)
          next unless agent

          kill_session_safely(session_ref_from_agent(agent), agent: agent) if present_string(agent.fetch("harness", nil))
        end

        result = deep_copy(target)
        removal = remove_killed_target_records!(state, target_id.to_s, killed_agent_ids, now)

        log_ids = cancelled_dependents.fetch("log_entry_ids").dup
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: target_id.to_s,
          level: "info",
          message: "Killed #{target_id}.",
          details: {
            "target_id" => target_id.to_s,
            "killed_agent_ids" => killed_agent_ids,
            "cancelled_deferred_agent_ids" => cancelled_dependents.fetch("agent_ids"),
            "removed_issue_ids" => removal.fetch("removed_issue_ids", []),
            "removed_agent_ids" => removal.fetch("removed_agent_ids", []),
            "removed_project_ids" => removal.fetch("removed_project_ids", [])
          }.compact
        ))
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, target_id.to_s, "Killed #{target_id}.", result, log_ids)
      end

      # Kill is an immediate stop-and-remove operation: lifecycle state is marked first so
      # attached sessions are stopped consistently, then the target bundle leaves active state.
      def remove_killed_target_records!(state, target_id, killed_agent_ids, now)
        issue_ids = []
        project_ids = []
        if find_agent(state, target_id).nil?
          if (issue = find_issue(state, target_id))
            issue_ids << issue.fetch("id")
          elsif (project = find_project(state, target_id))
            project_ids << project.fetch("id")
          end
        end

        remove_issue_bundles_and_agents!(
          state,
          issue_ids: issue_ids,
          project_ids: project_ids,
          extra_agent_ids: killed_agent_ids,
          reason: "killed",
          now: now,
          remove_empty_projects: false
        )
      end

      def spawn_head(command_id, command_type, payload)
        user_message = value_at(payload, "user_message", "UserMessage", "message")
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        requested_selected_target = value_at(payload, "selected_target", "SelectedTarget", "selectedTarget")
        # Internally routed heads (for example the head spawned for an answered question) carry a
        # long structured prompt. The visible chat log should stay short and human-facing.
        log_message = present_string(value_at(payload, "log_message", "LogMessage"))
        errors = []

        errors << "user_message is required" if blank?(user_message)
        return synchronized_state { rejected_result(command_id, command_type, "Head was not spawned.", errors) } unless errors.empty?

        head_id = nil
        selected_target = nil
        started = synchronized_state do
          state = normalized_state
          if present_string(question_id) && !find_question(state, question_id)
            return rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"])
          end

          selected_target, selected_target_error = resolve_selected_head_target(state, requested_selected_target)
          if selected_target_error
            return rejected_result(
              command_id,
              command_type,
              "Head was not spawned: #{selected_target_error.fetch("message")}",
              [selected_target_error.fetch("code")]
            )
          end

          active_provider = active_harness_provider(state)
          active_runner = active_head_runner(provider: active_provider)
          now = timestamp
          head_id = next_head_id!(state)
          agent = build_head_agent(
            head_id: head_id,
            now: now,
            provider: active_provider,
            runner: active_runner,
            harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i,
            user_message: user_message.to_s,
            question_id: present_string(question_id),
            selected_target: selected_target,
            snapshot_issue_ids: state.fetch("issues").map { |issue| issue.fetch("id", nil) }.compact,
            snapshot_project_ids: state.fetch("projects").map { |project| project.fetch("id", nil) }.compact,
            snapshot_counters: deep_copy(state.fetch("counters", {}))
          )
          state.fetch("agents") << agent

          log_ids = append_log(
            state,
            source_type: "user",
            source_id: nil,
            level: "info",
            message: log_message || user_message.to_s.strip,
            details: {
              "head_id" => head_id,
              "question_id" => present_string(question_id),
              **selected_target_log_details(selected_target)
            }.compact
          )
          touch_state!(state, now)
          store.save(state)

          snapshot = deep_copy(state)
          context = Heads::Context.new(
            head_id: head_id,
            user_message: user_message.to_s,
            snapshot: snapshot,
            question_id: present_string(question_id),
            selected_target: selected_target,
            cwd: cwd,
            state_path: store.path
          )

          {
            "context" => context,
            "log_ids" => log_ids,
            "snapshot" => snapshot,
            "head_runner" => active_runner
          }
        end

        runner = started.fetch("head_runner")
        # A head owns a harness session for its whole lifetime. The kernel spawns that
        # session, records it on the head agent record, and only tears it down when the
        # head reaches a terminal state (result applied, errored, or killed).
        session_ref = nil
        if runner.respond_to?(:spawn_head_session)
          session_ref = runner.spawn_head_session(
            user_message: user_message.to_s,
            snapshot: started.fetch("snapshot"),
            question_id: present_string(question_id),
            context: started.fetch("context")
          )
          session_record = record_head_session!(head_id, session_ref)
          session_log_ids = session_record.fetch("log_entry_ids", [])

          if async_heads?
            return synchronized_state do
              accepted_result(
                command_id,
                command_type,
                head_id,
                "Spawned head #{head_id}; polling will apply its HeadResult when complete.",
                session_record.fetch("agent"),
                (started.fetch("log_ids") + session_log_ids).uniq
              )
            end
          end
        else
          session_log_ids = mark_head_session_unavailable!(head_id, reason: "head_runner_has_no_session").fetch("log_entry_ids", [])
        end

        head_result = if session_ref && runner.respond_to?(:await_head_result)
                        runner.await_head_result(session_ref)
                      else
                        runner.run(
                          user_message: user_message.to_s,
                          snapshot: started.fetch("snapshot"),
                          question_id: present_string(question_id),
                          context: started.fetch("context")
                        )
                      end

        synchronized_state do
          state = normalized_state
          agent = find_agent(state, head_id)
          raise "Head #{head_id} disappeared before completion could be recorded." unless agent

          agent["status"] = "completed"
          agent["updated_at"] = timestamp
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "title" => head_result.is_a?(Hash) ? head_result["title"] : nil,
            "summary" => head_result.is_a?(Hash) ? head_result["summary"] : nil,
            "head_result" => head_result,
            "is_streaming" => false
          ).compact
          log_ids = (started.fetch("log_ids") + session_log_ids).uniq
          touch_state!(state)
          store.save(state)

          accepted_result(command_id, command_type, head_id, "Spawned and completed head #{head_id}.", agent, log_ids)
        end
      rescue StandardError => e
        released = mark_head_errored(head_id, e, release_session: true) if defined?(head_id) && head_id
        # If the head record itself is gone the kernel still owns the session it spawned.
        if !released && defined?(session_ref) && session_ref && runner.respond_to?(:close_head_session)
          runner.close_head_session(session_ref)
        end
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

        cleanup_head = value_at(payload, "_cleanup_head", "cleanup_head")
        cleanup_head = true if cleanup_head.nil?
        recovering = !!value_at(payload, "_recover", "recover")
        log_ids = []

        initialization = synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return rejected_result(command_id, command_type, "Head #{head_id} does not exist.", ["head_not_found"]) unless head
          return rejected_result(command_id, command_type, "Agent #{head_id} is not a head.", ["agent_is_not_head"]) unless head.fetch("type", nil) == "head"

          if head_result_apply_lease_held_elsewhere?(head)
            return accepted_result(
              command_id,
              command_type,
              head_id.to_s,
              "Head result for #{head_id} is already being applied by another kernel instance.",
              { "head_id" => head_id.to_s, "skipped" => "head_result_apply_in_progress" },
              []
            )
          end

          now = timestamp
          metadata = head.fetch("harness_metadata", {}) || {}
          already_initialized = present_string(metadata.fetch("head_result_initialized_at", nil))
          # Exactly-once: a finished batch is never re-applied, no matter which
          # loop (prompt loop, session poll, or recovery) delivers it again.
          if present_string(metadata.fetch("head_result_applied_at", nil))
            return already_applied_head_result(command_id, command_type, head_id.to_s, metadata)
          end

          stored_result = metadata.fetch("head_result", nil)
          fingerprint = head_result_fingerprint(head_result)
          stored_fingerprint = present_string(metadata.fetch("head_result_fingerprint", nil))
          duplicate_variant = already_initialized && stored_result.is_a?(Hash) &&
                              stored_fingerprint && stored_fingerprint != fingerprint
          if duplicate_variant
            # The first recorded result stays authoritative so a re-read or
            # re-parse of the head's output cannot append a second batch of
            # questions, issues, or workers.
            head_result = deep_copy(stored_result)
            fingerprint = stored_fingerprint
          end

          head["status"] = "working"
          head["updated_at"] = now
          metadata = metadata.merge(
            "title" => head_result.fetch("title"),
            "summary" => head_result.fetch("summary"),
            "head_result" => head_result,
            "head_result_fingerprint" => fingerprint,
            "head_result_apply_state" => "applying",
            "head_result_initialized_at" => metadata.fetch("head_result_initialized_at", nil) || now
          ).merge(head_result_apply_lease(now))
          instance_ownership_metadata.each { |key, value| metadata[key] ||= value }
          if duplicate_variant
            metadata["head_result_duplicate_count"] = metadata.fetch("head_result_duplicate_count", 0).to_i + 1
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: head_id.to_s,
              level: "warning",
              message: "Ignored a duplicate result for head #{head_id}; its first result is still being applied.",
              details: { "head_id" => head_id.to_s, "duplicate_count" => metadata.fetch("head_result_duplicate_count") }
            ))
          end
          metadata["head_result_command_journal"] = initialize_head_command_journal(
            state: state,
            head_id: head_id.to_s,
            head_result: head_result,
            existing: metadata.fetch("head_result_command_journal", []),
            recovering: recovering
          )
          unless already_initialized
            metadata["head_result_question_ids"] = ensure_head_questions!(state, head_id.to_s, head_result.fetch("questions"), log_ids)
            log_ids.concat(append_head_summary_log(state, head_id, head_result))
          end
          head["harness_metadata"] = metadata
          touch_state!(state, now)
          store.save(state)
          {
            "question_ids" => Array(metadata.fetch("head_result_question_ids", [])),
            "journal" => deep_copy(metadata.fetch("head_result_command_journal")),
            "head" => deep_copy(head)
          }
        end
        return initialization if kernel_command_result?(initialization)

        command_results = []
        interrupted = false
        claimed_by = nil
        state_cleared = false
        skipped_after_clear = 0
        head_snapshot = initialization.fetch("head", nil)
        head_result.fetch("commands").each_with_index do |proposed_command, index|
          command = command_with_default_id(proposed_command, head_id: head_id.to_s, index: index)
          if state_cleared
            skipped_after_clear += 1
            next
          end

          journal_entry = current_head_journal_entry(head_id.to_s, index)
          if journal_entry && terminal_command_status?(journal_entry.fetch("status", nil))
            command_results << command_result_from_journal(journal_entry)
            next
          end

          # Another live instance already claimed this command. Re-running it here
          # is what produced duplicate workers and duplicate spawn logs.
          if (owner = head_command_claim_owner(journal_entry))
            claimed_by = owner
            break
          end

          # The head record can disappear mid-batch when it is killed, cleaned up, or finished
          # by another kernel instance. Stop instead of raising so reconciliation keeps working.
          unless mark_head_command_started!(head_id.to_s, index)
            interrupted = true
            break
          end

          # Resolve intra-batch issue references (and catch mispredicted issue ids) before the
          # command can attach work to an issue this head never created. Then apply the
          # head-command permission/destructive guardrails to the resolved command.
          resolution = resolve_head_batch_issue_reference(
            command: command,
            head_id: head_id.to_s,
            index: index,
            commands: head_result.fetch("commands")
          )
          result = if (rejection = resolution.fetch("rejection", nil))
                     synchronized_state do
                       rejected_result(
                         value_at(command, "command_id", "id"),
                         canonical_command_type(value_at(command, "type", "command_type")),
                         rejection.fetch("message"),
                         rejection.fetch("errors")
                       )
                     end
                   else
                     resolved_command = resolution.fetch("command")
                     guard_result = head_command_guard_result(resolved_command, head: head_snapshot)
                     unless guard_result
                       log_ids.concat(log_head_batch_issue_remap(head_id.to_s, resolution))
                     end
                     guard_result || apply(resolved_command)
                   end
          command_results << result
          # ClearState removes the journal along with everything else, so it is the last command
          # the kernel can honestly journal. Report the batch as applied instead of treating the
          # deliberate wipe as an interrupted batch.
          if result.fetch("command_type", nil) == "ClearState" && result.fetch("status", nil) == "accepted"
            state_cleared = true
            next
          end

          unless checkpoint_head_command_result!(head_id.to_s, index, result)
            interrupted = true
            break
          end
        end

        if state_cleared
          return cleared_state_head_result(
            command_id,
            command_type,
            head_id.to_s,
            head_result: head_result,
            head_snapshot: head_snapshot,
            command_results: command_results,
            skipped_after_clear: skipped_after_clear
          )
        end

        if claimed_by
          return synchronized_state do
            rejected_result(
              command_id,
              command_type,
              "Head #{head_id}'s result is already being applied by Meringue instance #{claimed_by}.",
              ["head_result_claimed_by_another_instance"]
            )
          end
        end

        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          unless head
            return interrupted_head_result(command_id, command_type, state, head_id.to_s, command_results, log_ids)
          end

          accepted_count = command_results.count { |result| result.fetch("status", nil) == "accepted" }
          rejected_count = command_results.count { |result| result.fetch("status", nil) == "rejected" }
          failed_count = command_results.count { |result| result.fetch("status", nil) == "failed" }
          question_ids = initialization.fetch("question_ids")
          if interrupted
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: head_id.to_s,
              level: "warning",
              message: "Stopped applying head #{head_id}'s remaining commands because its command journal is no longer tracked.",
              details: { "head_id" => head_id.to_s, "applied_command_count" => command_results.length }
            ))
          end
          # Same visible output as the typed slash path: the kernel's own command output reaches
          # the user, so a head summary never has to restate "Pruned N issues, ...".
          log_ids.concat(append_head_command_output_logs(state, head_id.to_s, command_results))
          summary_log_ids = if rejected_count.positive? || failed_count.positive?
                              append_log(
                                state,
                                source_type: "kernel",
                                source_id: head_id.to_s,
                                level: failed_count.positive? ? "error" : "warning",
                                message: "Head result for #{head_id}: #{accepted_count} accepted, #{rejected_count} rejected, #{failed_count} failed.",
                                details: {
                                  "head_id" => head_id.to_s,
                                  "question_ids" => question_ids,
                                  "command_results" => command_results
                                }
                              )
                            else
                              []
                            end
          # A batch that accepted nothing routed nothing, so the user's message would otherwise
          # survive only as command error lines. Surface the message itself so it stays actionable.
          unrouted_log_ids = if accepted_count.zero? && question_ids.empty?
                               append_unrouted_user_message_log(state, head_id.to_s, command_results)
                             else
                               []
                             end
          now = timestamp
          metadata = head.fetch("harness_metadata", {}) || {}
          metadata["head_result_apply_state"] = rejected_count.positive? || failed_count.positive? ? "partially_applied" : "applied"
          metadata["head_result_apply_status"] = rejected_count.positive? || failed_count.positive? ? "partial" : "accepted"
          metadata["head_result_applied_at"] = now
          head["harness_metadata"] = metadata
          head["status"] = rejected_count.positive? || failed_count.positive? ? "blocked" : "completed"
          head["updated_at"] = now

          log_ids.concat(command_results.flat_map { |result| result.fetch("log_entry_ids", []) })
          log_ids.concat(summary_log_ids)
          log_ids.concat(unrouted_log_ids)
          cleanup = if cleanup_head && rejected_count.zero? && failed_count.zero?
                      cleanup_applied_head!(state, head_id.to_s, now: now)
                    elsif cleanup_head
                      { "changed" => false, "reason" => "partially_applied" }
                    else
                      { "changed" => false, "reason" => "deferred" }
                    end
          log_ids.concat(cleanup.fetch("log_entry_ids", []))
          touch_state!(state, now)
          store.save(state)

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
              "command_results" => command_results,
              "head_cleanup" => cleanup
            },
            log_ids.uniq
          )
        end
      end

      # Stable identity for one head result, so a re-delivered or re-parsed copy of
      # the same decision can be recognized instead of applied again.
      def head_result_fingerprint(head_result)
        Digest::SHA256.hexdigest(
          JSON.generate(
            "title" => head_result.fetch("title", nil).to_s,
            "summary" => head_result.fetch("summary", nil).to_s,
            "commands" => Array(head_result.fetch("commands", [])),
            "questions" => Array(head_result.fetch("questions", []))
          )
        )
      end

      def already_applied_head_result(command_id, command_type, head_id, metadata)
        journal = Array(metadata.fetch("head_result_command_journal", []))
        accepted_result(
          command_id,
          command_type,
          head_id,
          "Head result for #{head_id} was already applied.",
          {
            "head_id" => head_id,
            "title" => metadata.fetch("title", nil),
            "summary" => metadata.fetch("summary", nil),
            "question_ids" => Array(metadata.fetch("head_result_question_ids", [])),
            "command_results" => journal.map { |entry| command_result_from_journal(entry) },
            "duplicate_apply" => true
          },
          []
        )
      end

      # The head record can be killed or cleaned up while its batch is running.
      # Commands that already ran still count as applied work, so this reports what
      # happened as a warning rather than a command failure.
      def interrupted_head_result(command_id, command_type, state, head_id, command_results, log_ids)
        log_ids.concat(command_results.flat_map { |result| result.fetch("log_entry_ids", []) })
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: head_id,
          level: "warning",
          message: "Head #{head_id} was no longer tracked when its result finished applying; #{command_results.length} command(s) were applied.",
          details: { "head_id" => head_id, "applied_command_count" => command_results.length }
        ))
        touch_state!(state)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          head_id,
          "Applied head result for #{head_id} after the head was cleaned up.",
          {
            "head_id" => head_id,
            "command_results" => command_results,
            "head_missing" => true
          },
          log_ids.uniq
        )
      end

      # Answering an open question is not bookkeeping. The answer is the input a head said it
      # needed, so the kernel records the answer, closes the question, and then spawns a fresh
      # head carrying the answer plus the original question context (question text, context,
      # project/issue scope, originating head, and the user message that triggered the question)
      # so the work the question blocked actually gets routed instead of silently stopping at
      # "Answered question Q<n>."
      def answer_question_and_route(command_id, command_type, payload)
        outcome = synchronized_state { record_question_answer(command_id, command_type, payload) }
        result = outcome.fetch("result")
        return result unless result.fetch("status", nil) == "accepted"
        return result unless outcome.fetch("recorded", false)
        return result unless answer_routing_enabled?(payload)

        question = outcome.fetch("question")
        routing = route_answered_question(question)
        accepted_result(
          command_id,
          command_type,
          question.fetch("id"),
          answer_routing_message(question, routing),
          question.merge("routing" => answer_routing_summary(routing)),
          (Array(result.fetch("log_entry_ids", [])) + answer_routing_log_entry_ids(routing)).uniq
        )
      end

      # A head that proposes AnswerQuestion returns its own routing commands in the same batch,
      # so the kernel must not spawn a second head for that answer. It also must not re-enter the
      # head-result apply path while that batch still holds the apply lease.
      def answer_routing_enabled?(payload)
        return false if present_string(value_at(payload, "_head_id", "head_id", "HeadID"))
        return false if @head_result_mutex.owned?

        flag = value_at(payload, "route_answer", "spawn_head", "route")
        return true if flag.nil?

        flag != false && flag.to_s.strip.downcase != "false"
      end

      def route_answered_question(question)
        spawn_result = spawn_head(
          nil,
          "SpawnHead",
          "user_message" => answer_routing_prompt(question),
          "question_id" => question.fetch("id"),
          "log_message" => "Answered #{question.fetch("id")}: #{question.fetch("answer")}"
        )
        routing = { "spawn_head_result" => spawn_result }
        return routing unless spawn_result.fetch("status", nil) == "accepted"

        head_id = present_string(spawn_result.fetch("target_id", nil))
        routing["head_id"] = head_id if head_id
        head_result = (spawn_result.dig("result", "harness_metadata") || {})["head_result"]
        # Asynchronous head runners hand the result to reconciliation instead, which applies it
        # through the same ApplyHeadResult path once the session settles.
        return routing unless head_id && head_result.is_a?(Hash)

        routing["apply_head_result"] = @head_result_mutex.synchronize do
          apply_head_result(nil, "ApplyHeadResult", "head_id" => head_id, "head_result" => head_result)
        end
        routing
      rescue StandardError => e
        { "error" => error_payload(e) }
      end

      def answer_routing_prompt(question)
        question_id = question.fetch("id")
        lines = [
          "The user answered open Meringue question #{question_id}. This is the missing input for the work that question blocked, not a brand-new goal.",
          "",
          "Question (#{question_id}): #{question.fetch("question")}"
        ]
        context = present_string(question.fetch("context", nil))
        lines << "Question context: #{context}" if context
        original_message = present_string(question.fetch("original_user_message", nil))
        lines << "Original user message that led to the question: #{original_message}" if original_message
        asking_head = present_string(question.fetch("head_id", nil))
        lines << "Question was asked by head: #{asking_head}" if asking_head
        project_id = present_string(question.fetch("project_id", nil))
        issue_id = present_string(question.fetch("issue_id", nil))
        scope = [project_id ? "project #{project_id}" : nil, issue_id ? "issue #{issue_id}" : nil].compact
        lines << "Question scope: #{scope.join(", ")}" unless scope.empty?
        lines << "User answer: #{question.fetch("answer")}"
        lines << ""
        lines << "The question is already recorded as answered, so do not ask it again and do not propose AnswerQuestion for it."
        lines << "Route the work this answer unblocks: reuse the question's issue when it still represents the durable goal, prompt the healthiest existing worker on that issue when its session context is relevant, and create or spawn only when nothing suitable exists."
        lines << "Ask a new clarifying question only if the answer still leaves the routing genuinely ambiguous."
        lines.join("\n")
      end

      def answer_routing_message(question, routing)
        question_id = question.fetch("id")
        if routing.key?("error")
          return "Answered question #{question_id}, but routing the answer failed: #{routing.dig("error", "message")}"
        end

        head_id = routing.fetch("head_id", nil)
        return "Answered question #{question_id}, but no head could be spawned to act on the answer." unless head_id

        "Answered question #{question_id} and spawned head #{head_id} to act on the answer."
      end

      def answer_routing_summary(routing)
        {
          "head_id" => routing.fetch("head_id", nil),
          "spawn_head_status" => routing.dig("spawn_head_result", "status"),
          "apply_head_result_status" => routing.dig("apply_head_result", "status"),
          # Nested results so callers can see (and wait on) the work the answer actually started.
          "command_results" => routing.dig("apply_head_result", "result", "command_results"),
          "error" => routing.fetch("error", nil)
        }.compact
      end

      def answer_routing_log_entry_ids(routing)
        [routing.fetch("spawn_head_result", nil), routing.fetch("apply_head_result", nil)].compact.flat_map do |result|
          Array(result.fetch("log_entry_ids", []))
        end
      end

      # A head-proposed `ClearState` deliberately removes the head record, its journal, and the
      # visible logs. The batch therefore ends here: the wipe is reported as applied work, the
      # head's harness session is released, and the kernel's own command output is re-logged into
      # the fresh state so the user still sees "Cleared Meringue state."
      def cleared_state_head_result(command_id, command_type, head_id, head_result:, head_snapshot:,
                                    command_results:, skipped_after_clear: 0)
        release_head_session!(head_snapshot, reason: "head_result_cleared_state") if head_snapshot.is_a?(Hash)

        synchronized_state do
          state = normalized_state
          log_ids = append_head_command_output_logs(state, head_id, command_results)
          if skipped_after_clear.positive?
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: head_id,
              level: "warning",
              message: "Skipped #{skipped_after_clear} command(s) after head #{head_id}'s ClearState reset Meringue state.",
              details: { "head_id" => head_id, "skipped_command_count" => skipped_after_clear }
            ))
          end
          touch_state!(state)
          store.save(state)

          accepted_result(
            command_id,
            command_type,
            head_id,
            "Applied head result for #{head_id}; ClearState reset Meringue state.",
            {
              "head_id" => head_id,
              "title" => head_result.fetch("title", nil),
              "summary" => head_result.fetch("summary", nil),
              "question_ids" => [],
              "command_results" => command_results,
              "state_cleared" => true,
              "skipped_command_count" => skipped_after_clear
            },
            log_ids.uniq
          )
        end
      end

      # Head-proposed commands must reach the user the way typed slash command output does. This
      # is the head-side twin of `record_user_kernel_command_output`, and it uses the same
      # formatter: a command that already logged its own outcome (Prune, Recount, Kill,
      # SpawnWorker, and every rejection) is not repeated, while read-only commands are surfaced
      # here instead of staying buried inside the ApplyHeadResult envelope.
      def append_head_command_output_logs(state, head_id, command_results)
        Array(command_results).flat_map do |result|
          next [] unless result.is_a?(Hash)

          kernel_command_output_lines([result]).flat_map do |line|
            append_log(
              state,
              source_type: "kernel",
              source_id: head_id.to_s,
              level: result.fetch("status", nil) == "accepted" ? "info" : "warning",
              message: "Command output: #{line}",
              details: {
                "head_id" => head_id.to_s,
                "command_type" => result.fetch("command_type", nil),
                "kind" => "kernel_command_output",
                "presentation" => "cmd"
              }.compact
            )
          end
        end
      end

      # Guardrails for head-proposed commands. Returns nil when the command may run, or a rejected
      # KernelCommandResult that is journaled and logged exactly like any other rejection.
      #
      # Policy:
      # - Ordinary housekeeping (Prune, Recount, DismissQuestion, killing one worker/issue, and
      #   every read-only command) runs on a clear user request, with no extra ceremony.
      # - Irreversible commands (ClearState, killing a whole project) additionally require the
      #   head to mark the command user-confirmed AND require the user's own message to be an
      #   unambiguous instruction. A vague prompt can therefore never wipe state or a project.
      # - Kernel-internal commands are never proposable.
      def head_command_guard_result(command, head:)
        return nil unless command.is_a?(Hash)

        command_type = canonical_command_type(value_at(command, "type", "command_type").to_s)
        command_id = value_at(command, "command_id", "id")
        payload = value_at(command, "payload")
        payload = {} unless payload.is_a?(Hash)
        head = {} unless head.is_a?(Hash)
        head_id = head.fetch("id", nil).to_s

        if HEAD_BLOCKED_COMMANDS.include?(command_type)
          return synchronized_state do
            rejected_result(
              command_id,
              command_type,
              "Head #{head_id} may not propose #{command_type}.",
              [HEAD_UNPROPOSABLE_COMMAND_REASON, "proposable commands: #{HEAD_PROPOSABLE_COMMANDS.join(", ")}"]
            )
          end
        end
        # Unknown command types continue through normal kernel dispatch and keep the established
        # `unknown_command` validation error. The explicit block above is only for known
        # kernel/parser internals; user-facing commands are enumerated for the head contract.

        guard = case command_type
                when "ClearState" then clear_state_head_guard(head, payload)
                when "Kill" then kill_head_guard(head, payload)
                end
        return nil unless guard

        synchronized_state do
          rejected_result(command_id, command_type, guard.fetch("message"), guard.fetch("errors"))
        end
      end

      def clear_state_head_guard(head, payload)
        confirmed = head_command_user_confirmed?(payload)
        user_message = head_record_user_message(head)
        explicit = HEAD_CLEAR_STATE_INSTRUCTION_PATTERN.match?(user_message)
        return nil if confirmed && explicit

        errors = []
        errors << "clear_state_requires_user_confirmation" unless confirmed
        errors << "clear_state_requires_explicit_user_instruction" unless explicit
        errors << "ask the user a confirmation question, then propose ClearState with \"confirmed_by_user\": true only when they explicitly ask to clear/reset/wipe Meringue state"
        {
          "message" => "ClearState was refused because the user did not unambiguously ask to reset Meringue state.",
          "errors" => errors
        }
      end

      def kill_head_guard(head, payload)
        target_id = present_string(value_at(payload, "target_id", "TargetID", "targetId", "id"))
        return nil unless target_id

        head_id = head.fetch("id", nil).to_s
        if target_id == head_id
          return {
            "message" => "Head #{head_id} may not kill itself while its own commands are being applied.",
            "errors" => ["head_cannot_kill_itself"]
          }
        end

        project = synchronized_state { find_project(normalized_state, target_id) }
        return nil unless project

        confirmed = head_command_user_confirmed?(payload)
        user_message = head_record_user_message(head)
        explicit = HEAD_KILL_INSTRUCTION_PATTERN.match?(user_message) && head_message_names_project?(user_message, project)
        return nil if confirmed && explicit

        errors = []
        errors << "project_kill_requires_user_confirmation" unless confirmed
        errors << "project_kill_requires_explicit_user_instruction" unless explicit
        errors << "ask the user a confirmation question, then propose Kill with \"confirmed_by_user\": true only when they explicitly name project #{project.fetch("id", target_id)} and ask to kill it"
        {
          "message" => "Kill was refused for project #{project.fetch("id", target_id)} because the user did not unambiguously ask to kill the whole project.",
          "errors" => errors
        }
      end

      def head_command_user_confirmed?(payload)
        HEAD_CONFIRMATION_PAYLOAD_KEYS.any? do |key|
          value = value_at(payload, key)
          value == true || value.to_s.strip.downcase == "true"
        end
      end

      # The user's own words are the authoritative evidence for a destructive command. A head
      # cannot manufacture them: the kernel reads the message it recorded when it spawned the head.
      def head_record_user_message(head)
        metadata = head.is_a?(Hash) ? (head.fetch("harness_metadata", {}) || {}) : {}
        request = metadata.is_a?(Hash) ? (metadata.fetch("head_request", {}) || {}) : {}
        request.is_a?(Hash) ? request.fetch("user_message", "").to_s : ""
      end

      def head_message_names_project?(user_message, project)
        message = user_message.to_s.downcase
        project_id = project.fetch("id", "").to_s.downcase
        name = project.fetch("name", "").to_s.downcase
        return true if !project_id.empty? && message.match?(/\b#{Regexp.escape(project_id)}\b/)
        return true if name.length >= 3 && message.include?(name)

        false
      end

      def get_info(command_id, command_type, payload)
        target_id = present_string(value_at(payload, "target_id", "TargetID", "targetId", "id"))
        return rejected_result(command_id, command_type, "Info was not loaded.", ["target_id is required"]) unless target_id

        state = normalized_state
        kind, record = %w[agent issue project question].filter_map do |candidate_kind|
          found = case candidate_kind
                  when "agent" then find_agent(state, target_id)
                  when "issue" then find_issue(state, target_id)
                  when "project" then find_project(state, target_id)
                  else find_question(state, target_id)
                  end
          [candidate_kind, found] if found
        end.first
        unless record
          return rejected_result(command_id, command_type, "#{target_id} does not exist.", ["target_not_found"])
        end

        info = {
          "kind" => kind,
          "id" => record.fetch("id", target_id),
          "record" => deep_copy(record),
          "recent_logs" => state.fetch("logs").select { |log| log.fetch("source_id", nil) == target_id }
                                .last(5).map { |log| log.slice("id", "timestamp", "level", "message") }
        }
        info["issues"] = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == target_id }
                              .map { |issue| issue.slice("id", "title", "status") } if kind == "project"
        info["agents"] = state.fetch("agents").select { |agent| agent.fetch("issue_id", nil) == target_id }
                              .map { |agent| agent.slice("id", "type", "status") } if kind == "issue"
        if kind == "agent" && record.fetch("type", nil) == "worker"
          deferred = deferred_spawn_metadata(record)
          unless deferred.empty?
            predecessor = find_agent(state, deferred_worker_after_agent_id(record))
            info["deferred_spawn"] = deep_copy(deferred).merge(
              "after_agent_status" => predecessor ? predecessor.fetch("status", nil) : "missing"
            ).compact
          end
          dependents = waiting_deferred_dependents(state, [record.fetch("id")])
          info["waiting_dependent_agent_ids"] = dependents.map { |dependent| dependent.fetch("id") } if dependents.any?
        end

        accepted_result(command_id, command_type, record.fetch("id", target_id), "Loaded #{kind} #{target_id}.", info, [])
      end

      def answer_question(command_id, command_type, payload)
        record_question_answer(command_id, command_type, payload).fetch("result")
      end

      def record_question_answer(command_id, command_type, payload)
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        answer = value_at(payload, "answer", "Answer")
        errors = []

        errors << "question_id is required" if blank?(question_id)
        errors << "answer is required" if blank?(answer)
        unless errors.empty?
          return { "result" => rejected_result(command_id, command_type, "Question was not answered.", errors), "recorded" => false }
        end

        state = normalized_state
        question = find_question(state, question_id)
        unless question
          return {
            "result" => rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"]),
            "recorded" => false
          }
        end

        if question.fetch("status", nil) == "answered" && question.fetch("answer", nil).to_s == answer.to_s
          return {
            "result" => accepted_result(
              command_id,
              command_type,
              question.fetch("id"),
              "Question #{question.fetch("id")} already records this answer.",
              deep_copy(question),
              []
            ),
            "question" => deep_copy(question),
            "recorded" => false
          }
        end

        now = timestamp
        question["status"] = "answered"
        question["answer"] = answer.to_s
        question["answered_at"] = now
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
            "issue_id" => question.fetch("issue_id", nil),
            "question_id" => question.fetch("id"),
            "answer" => answer.to_s,
            "routing_action" => "answer_question"
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        {
          "result" => accepted_result(
            command_id,
            command_type,
            question.fetch("id"),
            "Answered question #{question.fetch("id")}.",
            deep_copy(question),
            log_ids
          ),
          "question" => deep_copy(question),
          "recorded" => true
        }
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

      # Prune takes no options. One pass removes resolved (completed/killed) and errored records
      # that are eligible for cleanup. A legacy `selector` value is still accepted for
      # compatibility and recorded for traceability, but it never changes what is pruned.
      def prune(command_id, command_type, payload)
        requested_selector = present_string(value_at(payload, "selector", "Selector", "kind", "status").to_s.downcase)
        # Never hold the global state/file lock while `gh` or another forge client performs
        # external I/O. First populate a short-lived, per-command cache from a state snapshot.
        # Then reacquire the lock and apply the prune against current state using only cached
        # results. A PR introduced after the snapshot is treated as unknown and retained.
        lookup_context = prepare_prune_forge_lookups
        synchronized_state do
          with_prune_forge_lookup_context(lookup_context) do
            prune_records(command_id, command_type, requested_selector: requested_selector)
          end
        end
      end

      def prepare_prune_forge_lookups
        snapshot = synchronized_state { deep_copy(normalized_state) }
        context = new_prune_forge_lookup_context
        seed_trusted_prune_pull_request_statuses!(context, snapshot)
        with_prune_forge_lookup_context(context) do
          # These are the only prune phases that can consult the forge, and they share one bounded
          # budget, so they run in the order retention actually depends on:
          #   1. the status of every pull request already recorded on an issue,
          #   2. branch discovery for settled workers whose delivery pull request is still unknown,
          #   3. exploratory verification of historical candidate URLs.
          # Running step 3 first (the old order) let a handful of stale candidate URLs, or one
          # unreachable forge call, exhaust the budget before any retention-critical lookup ran, so
          # known-merged pull requests came back `unknown` and their whole subtree was retained.
          # Running all phases on the snapshot still fills one cache, so each URL/branch is looked
          # up once per pass instead of once per phase/record.
          prune_pull_request_checks(snapshot)
          warm_prune_branch_discovery!(snapshot)
          refresh_worker_delivery_pull_requests!(snapshot)
        end
        context["allow_external"] = false
        context
      end

      def new_prune_forge_lookup_context
        budget = [prune_forge_lookup_budget, 0.0].max
        started_at = monotonic_time
        {
          "status_by_url" => {},
          "urls_by_branch" => {},
          "branch_lookup_failures" => {},
          "branch_lookup_blockers_by_issue" => {},
          "trusted_status_urls" => [],
          "external_status_urls" => [],
          "external_branch_lookups" => [],
          "unavailable_status_urls" => [],
          "budget_exhausted" => false,
          "allow_external" => true,
          "budget_seconds" => budget,
          "started_at" => started_at,
          "deadline" => started_at + budget
        }
      end

      # Prune's own state is the first source of truth for a merged pull request. Seeding the
      # per-command cache from persisted merged records means a settled record is prunable even
      # when `gh` is unavailable, and leaves the whole budget for URLs whose state can still
      # change.
      def seed_trusted_prune_pull_request_statuses!(context, state)
        cache = context.fetch("status_by_url")
        state.fetch("issues").each do |issue|
          State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).each do |record|
            status = trusted_persisted_pull_request_status(record)
            next unless status

            url = status.fetch("url")
            next if cache.key?(url)

            cache[url] = status
            context.fetch("trusted_status_urls") << url
          end
        end
        context
      end

      def trusted_persisted_pull_request_status(record)
        return nil unless record.is_a?(Hash)

        url = present_string(State::Models.pull_request_record_url(record))
        return nil if blank?(url)
        return nil unless record.fetch("provider", nil).to_s == "github"
        return nil unless PRUNE_TRUSTED_PULL_REQUEST_STATES.include?(record.fetch("state", nil).to_s)

        record.reject { |key, _value| %w[availability last_refresh_error].include?(key) }
              .merge("url" => url, "lookup_source" => "state")
      end

      # The merged delivery pull request recorded for exactly this worker branch. Used to skip
      # forge work that could only re-derive what state already proves.
      def trusted_delivery_pull_request_for_branch(issue, branch)
        normalized = normalized_branch_name(branch)
        return nil if blank?(normalized) || !issue.is_a?(Hash)

        State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).find do |record|
          next false unless trusted_persisted_pull_request_status(record)

          [record.fetch("matched_branch", nil), record.fetch("head_branch", nil)].any? do |candidate|
            normalized_branch_name(candidate) == normalized
          end
        end
      end

      # Branch discovery is the only exploratory lookup that can create a retention blocker, so it
      # gets budget priority over candidate-URL verification.
      def warm_prune_branch_discovery!(state)
        worker_agents_by_issue(state).each do |issue_id, workers|
          issue = find_issue(state, issue_id)
          next unless issue

          project = find_project(state, issue.fetch("project_id", nil))
          next unless project

          workers.each { |worker| discovered_worker_candidate_pr_urls(agent: worker, project: project, issue: issue) }
        end
      end

      def worker_agents_by_issue(state)
        state.fetch("agents").select { |agent| agent.fetch("type", nil) == "worker" }
             .group_by { |worker| worker.fetch("issue_id", nil) }
      end

      def with_prune_forge_lookup_context(context)
        key = prune_forge_lookup_thread_key
        previous = Thread.current[key]
        Thread.current[key] = context
        yield
      ensure
        Thread.current[key] = previous
      end

      def prune_forge_lookup_context
        Thread.current[prune_forge_lookup_thread_key]
      end

      def prune_forge_lookup_thread_key
        @prune_forge_lookup_thread_key ||= "meringue-prune-forge-#{object_id}"
      end

      def prune_forge_lookup_remaining(context)
        [context.fetch("deadline", monotonic_time) - monotonic_time, 0.0].max
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # A head may propose `/recount` for itself. The head that is applying the batch is not an
      # "in flight" head for this purpose: its own commands are what asked for the renumber, and
      # Recount never renames head ids. Any other live head still blocks the pass.
      def recount(command_id, command_type, payload = {})
        state = normalized_state
        proposing_head_id = present_string(value_at(payload, "_head_id", "head_id", "HeadID", "headId"))
        active_head_ids = state.fetch("agents").select { |agent| agent.fetch("type", nil) == "head" }
                               .map { |agent| agent.fetch("id") }
                               .reject { |head_id| head_id == proposing_head_id }
        if active_head_ids.any?
          return rejected_result(
            command_id,
            command_type,
            "AgentTree IDs were not recounted because a head result is still in flight.",
            ["active_heads", *active_head_ids]
          )
        end
        now = timestamp
        mappings = State::Recounter.recount!(state)
        changed_count = mappings.values.sum(&:length)
        state.fetch("metadata")["last_recount"] = {
          "recounted_at" => now,
          "changed_id_count" => changed_count,
          "mappings" => mappings
        }
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: "Recounted AgentTree IDs; renamed #{changed_count} record#{changed_count == 1 ? "" : "s"}.",
          details: {
            "changed_id_count" => changed_count,
            "mappings" => mappings,
            "unchanged_id_types" => %w[head log conversation_message harness_session workspace]
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          nil,
          "Recounted AgentTree IDs; renamed #{changed_count} record#{changed_count == 1 ? "" : "s"}.",
          {
            "changed_id_count" => changed_count,
            "mappings" => mappings,
            "counters" => deep_copy(state.fetch("counters"))
          },
          log_ids
        )
      end

      # One prune pass over the whole tree. Eligibility is shared by resolved and errored
      # records: an issue subtree must be free of nonterminal issues, queued/working/blocked
      # workers, open questions, and unsettled pull requests, and a project is removed only when
      # it is terminal with every contained issue eligible. Standalone errored heads are removed
      # in the same pass. A worker bundle leaves state only after its clean, unlocked,
      # Meringue-managed worktree has been removed (or is confirmed already absent).
      def prune_records(command_id, command_type, requested_selector: nil)
        state = normalized_state
        delivery_refreshes = refresh_worker_delivery_pull_requests!(state)
        pull_request_checks = prune_pull_request_checks(state)
        issue_decisions = issue_prune_decisions(state, pull_request_checks)
        project_decisions = project_prune_decisions(state, issue_decisions)
        removable_project_ids = project_decisions.select { |decision| decision.fetch("prunable", false) }.map { |decision| decision.fetch("project_id") }
        removable_issue_ids = issue_prune_roots(issue_decisions, removable_project_ids)
        errored_head_ids = state.fetch("agents").select do |agent|
          agent.fetch("type", nil) == "head" && agent.fetch("status", nil) == "errored" && !head_applying_batch?(agent)
        end.map { |agent| agent.fetch("id") }
        now = timestamp
        prune_result = remove_issue_bundles_and_agents!(
          state,
          issue_ids: removable_issue_ids,
          project_ids: removable_project_ids,
          extra_agent_ids: errored_head_ids,
          reason: "prune",
          now: now,
          remove_empty_projects: false,
          cleanup_worker_workspaces: true
        )
        annotate_workspace_cleanup_blockers!(issue_decisions, project_decisions, prune_result)
        checked_urls = pull_request_checks.flat_map { |check| check.fetch("statuses", []).map { |status| status.fetch("url", nil) } }.compact.uniq
        blocked_urls = issue_decisions.flat_map do |decision|
          decision.fetch("pull_request_blockers", []).map { |status| status.fetch("url", nil) }
        end.compact.uniq
        forge_lookup = prune_forge_lookup_summary
        retention = prune_retention_summary(issue_decisions, prune_result, forge_lookup)
        message = ([prune_summary_message(prune_result)] + retention.fetch("sentences")).join(" ")
        details = prune_result.merge(
          "requested_selector" => requested_selector,
          "checked_pr_urls" => checked_urls,
          "blocked_pr_urls" => blocked_urls,
          "pull_request_checks" => pull_request_checks,
          "issue_decisions" => issue_decisions,
          "project_decisions" => project_decisions,
          "delivery_pull_request_refreshes" => delivery_refreshes,
          "retained_issue_ids" => retention.fetch("retained_issue_ids"),
          "retention_reasons" => retention.fetch("reasons"),
          "forge_lookup" => forge_lookup
        ).compact
        log_ids = prune_result.fetch("workspace_cleanup_log_entry_ids", []).dup
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: retention.fetch("level"),
          message: message,
          details: details
        ))
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, nil, message, details, log_ids)
      end

      def prune_summary_message(prune_result)
        issues = Array(prune_result.fetch("removed_issue_ids", [])).length
        projects = Array(prune_result.fetch("removed_project_ids", [])).length
        standalone_agents = Array(prune_result.fetch("removed_standalone_agent_ids", [])).length
        parts = [
          "#{issues} issue#{issues == 1 ? "" : "s"}",
          "#{projects} project#{projects == 1 ? "" : "s"}",
          "#{standalone_agents} standalone agent#{standalone_agents == 1 ? "" : "s"}"
        ]
        "Pruned #{parts[0]}, #{parts[1]}, and #{parts[2]}."
      end

      # Retention must never look like a silent no-op. Nonterminal issues, queued/working/blocked
      # workers, and open questions are all visible in the AgentTree, so the summary only spells out
      # the reasons the user cannot otherwise see: a pull request status Meringue could not verify,
      # and a managed worktree it refused to remove. Every retained record and its blockers are
      # always available in the log details.
      def prune_retention_summary(issue_decisions, prune_result, forge_lookup)
        reasons = Array(issue_decisions).reject { |decision| decision.fetch("prunable", false) }.map do |decision|
          pull_request_blockers = Array(decision.fetch("pull_request_blockers", []))
          unverified, unsettled = pull_request_blockers.partition { |status| status.fetch("state", nil).to_s == "unknown" }
          {
            "issue_id" => decision.fetch("issue_id", nil),
            "blockers" => Array(decision.fetch("blockers", [])),
            "unverified_pr_urls" => unverified.filter_map { |status| status.fetch("url", nil) }.uniq,
            "open_pr_urls" => unsettled.filter_map { |status| status.fetch("url", nil) }.uniq,
            "nonterminal_issue_ids" => Array(decision.fetch("nonterminal_issue_ids", [])),
            "blocking_worker_ids" => Array(decision.fetch("blocking_worker_ids", [])),
            "open_question_ids" => Array(decision.fetch("open_question_ids", [])),
            "workspace_cleanup_blocking_agent_ids" => Array(decision.fetch("workspace_cleanup_blocking_agent_ids", []))
          }
        end
        unverified_issue_ids = reasons.select { |reason| reason.fetch("unverified_pr_urls").any? }
                                     .filter_map { |reason| reason.fetch("issue_id") }
        blocked_cleanups = Array(prune_result.fetch("workspace_cleanup_outcomes", []))
                           .reject { |outcome| outcome.fetch("success", false) }
        sentences = []
        if unverified_issue_ids.any?
          sentences << "Retained #{count_phrase(unverified_issue_ids.length, "issue")} because Meringue could not " \
                       "verify their pull request status: #{id_list_phrase(unverified_issue_ids)}" \
                       "#{prune_forge_lookup_clause(forge_lookup)}."
        end
        if blocked_cleanups.any?
          listed = blocked_cleanups.first(PRUNE_RETENTION_REPORT_LIMIT).map do |outcome|
            "#{outcome.fetch("agent_id", "worker")} (#{outcome.fetch("reason", "unknown_error")})"
          end
          remainder = blocked_cleanups.length - listed.length
          listed << "and #{remainder} more" if remainder.positive?
          sentences << "Retained #{count_phrase(blocked_cleanups.length, "worker")} because their managed worktree " \
                       "could not be removed: #{listed.join(", ")}."
        end

        {
          "retained_issue_ids" => reasons.filter_map { |reason| reason.fetch("issue_id") },
          "reasons" => reasons,
          "unverified_issue_ids" => unverified_issue_ids,
          "sentences" => sentences,
          "level" => unverified_issue_ids.any? || blocked_cleanups.any? ? "warning" : "info"
        }
      end

      def prune_forge_lookup_clause(forge_lookup)
        return "" unless forge_lookup.is_a?(Hash)

        if forge_lookup.fetch("budget_exhausted", false)
          " (the #{format_seconds(forge_lookup.fetch("budget_seconds", prune_forge_lookup_budget))}s forge lookup " \
            "budget was exhausted)"
        else
          " (the forge lookup was unavailable)"
        end
      end

      def format_seconds(value)
        format("%g", Float(value))
      rescue ArgumentError, TypeError
        value.to_s
      end

      def count_phrase(count, noun)
        "#{count} #{noun}#{count == 1 ? "" : "s"}"
      end

      def id_list_phrase(ids)
        listed = Array(ids).first(PRUNE_RETENTION_REPORT_LIMIT)
        remainder = Array(ids).length - listed.length
        listed = listed + ["and #{remainder} more"] if remainder.positive?
        listed.join(", ")
      end

      # Observability for the bounded lookup phase: how much of the budget the pass used, how many
      # external lookups it actually made, which URLs came from state instead of the forge, and
      # which ones the forge could not answer.
      def prune_forge_lookup_summary
        context = prune_forge_lookup_context
        return nil unless context

        started_at = context.fetch("started_at", monotonic_time)
        {
          "budget_seconds" => context.fetch("budget_seconds", prune_forge_lookup_budget),
          "elapsed_seconds" => (monotonic_time - started_at).round(3),
          "remaining_seconds" => prune_forge_lookup_remaining(context).round(3),
          "budget_exhausted" => context.fetch("budget_exhausted", false),
          "status_lookup_count" => context.fetch("external_status_urls", []).length,
          "branch_lookup_count" => context.fetch("external_branch_lookups", []).length,
          "trusted_from_state_urls" => context.fetch("trusted_status_urls", []).uniq,
          "unavailable_urls" => context.fetch("unavailable_status_urls", []).uniq
        }
      end

      # Refresh only already-verified delivery PRs. Candidate/reported URLs remain inert, and an
      # unavailable forge never replaces the last known open/closed/merged state. /prune still
      # performs its own authoritative checks and therefore keeps its conservative rules.
      def refresh_stale_delivery_pull_requests
        synchronized_state do
          state = normalized_state
          now = timestamp
          refreshes = state.fetch("issues").flat_map do |issue|
            State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).filter_map do |record|
              url = State::Models.pull_request_record_url(record)
              next if blank?(url) || !delivery_pull_request_refresh_due?(record, now)

              status = pull_request_status(url)
              unavailable = status.fetch("state", nil).to_s == "unknown"
              refreshed = if unavailable
                            record.merge(
                              "availability" => "unavailable",
                              "last_checked_at" => now,
                              "last_refresh_error" => present_string(status.fetch("error", nil))
                            ).compact
                          else
                            # The nil must survive `.compact` and the record merge inside
                            # `attach_pull_requests_to_issue!`; dropping the key instead left the
                            # previous failure attached to a record the forge just answered.
                            record.merge(status).merge(
                              "availability" => "available",
                              "last_checked_at" => now
                            ).compact.merge("last_refresh_error" => nil)
                          end
              State::Models.attach_pull_requests_to_issue!(issue, delivery_pull_requests: [refreshed])
              {
                "issue_id" => issue.fetch("id", nil),
                "url" => url,
                "state" => refreshed.fetch("state", "unknown"),
                "availability" => refreshed.fetch("availability"),
                "changed" => refreshed != record
              }.compact
            end
          end
          if refreshes.any? { |refresh| refresh.fetch("changed", false) }
            touch_state!(state, now)
            store.save(state)
          end
          refreshes
        end
      end

      def delivery_pull_request_refresh_due?(record, now)
        checked_at = record.is_a?(Hash) && (record["last_checked_at"] || record["verified_at"])
        return true if blank?(checked_at)

        Time.iso8601(now) - Time.iso8601(checked_at.to_s) >= DELIVERY_PULL_REQUEST_REFRESH_INTERVAL_SECONDS
      rescue ArgumentError, TypeError
        true
      end

      def refresh_worker_delivery_pull_requests!(state)
        workers_by_issue = worker_agents_by_issue(state)
        state.fetch("issues").flat_map do |issue|
          workers = workers_by_issue.fetch(issue.fetch("id", nil), [])
          project = find_project(state, issue.fetch("project_id", nil))
          next [] unless project

          candidate_urls = (
            Array(issue.fetch("candidate_pr_urls", nil)) +
            workers.flat_map { |worker| worker_legacy_candidate_pr_urls(worker) } +
            workers.flat_map { |worker| discovered_worker_candidate_pr_urls(agent: worker, project: project, issue: issue) }
          ).map(&:to_s).map(&:strip).reject(&:empty?).uniq
          next [] if candidate_urls.empty?

          matches = workers.flat_map do |worker|
            # This worker's branch already has a merged delivery pull request attached to the issue.
            # Re-verifying every historical candidate URL against it cannot change the record and
            # would spend forge budget that unknown deliveries need.
            next [] if trusted_delivery_pull_request_for_branch(issue, persisted_worker_delivery_branch(worker))

            verified_worker_pull_requests(agent: worker, project: project, candidate_urls: candidate_urls).map do |pull_request|
              [worker, pull_request]
            end
          end
          if matches.empty?
            matches = workers.filter_map do |worker|
              pull_request = merged_same_repo_candidate_pull_request(agent: worker, project: project, candidate_urls: candidate_urls)
              [worker, pull_request] if pull_request
            end
          end
          matches = matches.uniq { |_worker, pull_request| pull_request.fetch("url", nil) }
          next [] if matches.empty?

          matches.map do |matched_worker, delivery_pull_request|
            attach_issue_pull_requests!(issue, delivery_pull_request, candidate_urls)

            {
              "agent_id" => matched_worker.fetch("id", nil),
              "issue_id" => issue.fetch("id", nil),
              "url" => delivery_pull_request.fetch("url", nil),
              "matched_by" => delivery_pull_request.fetch("matched_by", nil)
            }.compact
          end
        end
      end

      def prune_pull_request_checks(state)
        workers_by_issue = worker_agents_by_issue(state)
        state.fetch("issues").filter_map do |issue|
          urls = (issue_pr_urls(issue) + workers_by_issue.fetch(issue.fetch("id", nil), []).flat_map { |worker| worker_legacy_pr_urls(worker) }).uniq
          next if urls.empty?

          {
            "issue_id" => issue.fetch("id", nil),
            "pr_urls" => urls,
            "statuses" => urls.map { |url| pull_request_status(url) }
          }
        end
      end

      def issue_prune_decisions(state, pull_request_checks)
        checks_by_issue = pull_request_checks.to_h { |check| [check.fetch("issue_id", nil), check] }
        state.fetch("issues").map do |issue|
          subtree_ids = issue_subtree_ids(state, issue.fetch("id"))
          subtree_issues = state.fetch("issues").select { |candidate| subtree_ids.include?(candidate.fetch("id", nil)) }
          workers = state.fetch("agents").select do |agent|
            agent.fetch("type", nil) == "worker" && subtree_ids.include?(agent.fetch("issue_id", nil))
          end
          blocking_workers = workers.select { |worker| PRUNE_BLOCKING_WORKER_STATUSES.include?(worker.fetch("status", nil).to_s) }
          open_questions = state.fetch("questions").select do |question|
            question.fetch("status", nil) == "open" && subtree_ids.include?(question.fetch("issue_id", nil))
          end
          statuses = subtree_ids.flat_map { |issue_id| Array(checks_by_issue.dig(issue_id, "statuses")) }
          discovery_blockers = subtree_ids.flat_map do |issue_id|
            Array(prune_forge_lookup_context&.dig("branch_lookup_blockers_by_issue", issue_id))
          end
          pull_request_blockers = (statuses + discovery_blockers).reject do |status|
            PRUNE_SETTLED_PULL_REQUEST_STATES.include?(status.fetch("state", nil).to_s)
          end
          nonterminal_issue_ids = subtree_issues.reject do |candidate|
            PRUNE_ELIGIBLE_STATUSES.include?(candidate.fetch("status", nil).to_s)
          end.map { |candidate| candidate.fetch("id") }
          # A predecessor must outlive its queue: removing it here would leave a queued dependent
          # (possibly on another issue) with nothing to wait for.
          deferred_dependents = waiting_deferred_dependents(state, workers.map { |worker| worker.fetch("id", nil) })
          blockers = []
          blockers << "nonterminal_issues" if nonterminal_issue_ids.any?
          blockers << "unresolved_workers" if blocking_workers.any?
          blockers << "open_questions" if open_questions.any?
          blockers << "unsettled_pull_requests" if pull_request_blockers.any?
          blockers << "pending_deferred_dependents" if deferred_dependents.any?

          {
            "issue_id" => issue.fetch("id"),
            "project_id" => issue.fetch("project_id", nil),
            "parent_issue_id" => issue.fetch("parent_issue_id", nil),
            "subtree_issue_ids" => subtree_ids,
            "prunable" => blockers.empty?,
            "blockers" => blockers,
            "nonterminal_issue_ids" => nonterminal_issue_ids,
            "blocking_worker_ids" => blocking_workers.map { |worker| worker.fetch("id", nil) }.compact,
            "deferred_dependent_worker_ids" => deferred_dependents.map { |dependent| dependent.fetch("id", nil) }.compact,
            "open_question_ids" => open_questions.map { |question| question.fetch("id", nil) }.compact,
            "pull_request_blockers" => pull_request_blockers,
            "pr_urls" => subtree_ids.flat_map { |issue_id| Array(checks_by_issue.dig(issue_id, "pr_urls")) }.uniq
          }
        end
      end

      def project_prune_decisions(state, issue_decisions)
        decisions_by_issue = issue_decisions.to_h { |decision| [decision.fetch("issue_id"), decision] }
        state.fetch("projects").map do |project|
          issue_ids = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }.map { |issue| issue.fetch("id") }
          blocking_workers = state.fetch("agents").select do |agent|
            agent.fetch("type", nil) == "worker" &&
              agent.fetch("project_id", nil) == project.fetch("id") &&
              PRUNE_BLOCKING_WORKER_STATUSES.include?(agent.fetch("status", nil).to_s)
          end
          open_questions = state.fetch("questions").select do |question|
            question.fetch("status", nil) == "open" && question.fetch("project_id", nil) == project.fetch("id")
          end
          ineligible_issue_ids = issue_ids.reject { |issue_id| decisions_by_issue.fetch(issue_id).fetch("prunable", false) }
          blockers = []
          blockers << "project_not_terminal" unless PRUNE_ELIGIBLE_STATUSES.include?(project.fetch("status", nil).to_s)
          blockers << "ineligible_issues" if ineligible_issue_ids.any?
          blockers << "unresolved_workers" if blocking_workers.any?
          blockers << "open_questions" if open_questions.any?

          {
            "project_id" => project.fetch("id"),
            "issue_ids" => issue_ids,
            "prunable" => blockers.empty?,
            "blockers" => blockers,
            "ineligible_issue_ids" => ineligible_issue_ids,
            "blocking_worker_ids" => blocking_workers.map { |worker| worker.fetch("id", nil) }.compact,
            "open_question_ids" => open_questions.map { |question| question.fetch("id", nil) }.compact
          }
        end
      end

      def issue_prune_roots(issue_decisions, removable_project_ids)
        eligible_issue_ids = issue_decisions.select { |decision| decision.fetch("prunable", false) }.map { |decision| decision.fetch("issue_id") }
        issue_decisions.filter_map do |decision|
          next unless decision.fetch("prunable", false)
          next if removable_project_ids.include?(decision.fetch("project_id", nil))
          next if eligible_issue_ids.include?(decision.fetch("parent_issue_id", nil))

          decision.fetch("issue_id")
        end
      end

      def verified_worker_pull_request(agent:, project:, candidate_urls:)
        verified_worker_pull_requests(agent: agent, project: project, candidate_urls: candidate_urls).first
      end

      def verified_worker_pull_requests(agent:, project:, candidate_urls:)
        branch = worker_delivery_branch(agent)
        project_repository = project && project_github_repository(project)
        return [] if blank?(branch) || blank?(project_repository)

        Array(candidate_urls).filter_map do |url|
          status = pull_request_status(url)
          next unless verified_worker_pull_request?(status, branch: branch, project_repository: project_repository)

          status.merge(
            "matched_by" => "workspace_branch",
            "matched_branch" => branch,
            "verified_at" => timestamp,
            "last_checked_at" => timestamp,
            "availability" => "available"
          )
        end
      end

      def verified_worker_pull_request?(status, branch:, project_repository:)
        status.fetch("provider", nil) == "github" &&
          status.fetch("base_repository", nil).to_s.downcase == project_repository.to_s.downcase &&
          !status.fetch("is_cross_repository", false) &&
          status.fetch("head_repository", nil).to_s.downcase == project_repository.to_s.downcase &&
          normalized_branch_name(status.fetch("head_branch", nil)) == normalized_branch_name(branch)
      end

      def discovered_worker_candidate_pr_urls(agent:, project:, issue: nil)
        # A worker can settle without usable final output, so recover from the durable branch
        # identity rather than treating arbitrary URLs elsewhere in its session as deliveries.
        return [] unless agent.fetch("status", nil) == "completed"
        return [] unless forge_client.respond_to?(:pull_request_urls_for_branch)

        branch = normalized_branch_name(persisted_worker_delivery_branch(agent))
        repository = project_github_repository(project)
        return [] if blank?(branch) || blank?(repository)
        # A merged delivery pull request is already recorded for this exact branch, so discovery can
        # only re-derive URLs Meringue already has. Skipping it stops a slow or unreachable forge
        # from manufacturing an `unknown` blocker for settled work, and leaves the budget for
        # branches whose delivery really is unknown.
        return [] if trusted_delivery_pull_request_for_branch(issue, branch)

        urls = pull_request_urls_for_branch(repository: repository, branch: branch)
        context = prune_forge_lookup_context
        failure = context&.dig("branch_lookup_failures", [repository.to_s, branch.to_s])
        if failure
          blocker = unavailable_prune_pull_request_status(
            "github-branch://#{repository}/#{branch}",
            failure
          )
          blockers = context.fetch("branch_lookup_blockers_by_issue")
          issue_blockers = blockers[agent.fetch("issue_id", nil)] ||= []
          issue_blockers << blocker unless issue_blockers.any? { |existing| existing.fetch("url", nil) == blocker.fetch("url") }
        end
        urls
      rescue StandardError
        []
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
          "verified_at" => timestamp,
          "last_checked_at" => timestamp,
          "availability" => "available"
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

      def pull_request_urls_for_branch(repository:, branch:)
        context = prune_forge_lookup_context
        return Array(forge_client.pull_request_urls_for_branch(repository: repository, branch: branch)) unless context

        key = [repository.to_s, branch.to_s]
        cache = context.fetch("urls_by_branch")
        return cache.fetch(key) if cache.key?(key)
        unless context.fetch("allow_external", false)
          return record_prune_branch_lookup_failure(context, key, "Branch appeared after the prune lookup snapshot")
        end

        remaining = prune_forge_lookup_remaining(context)
        unless remaining.positive?
          context["budget_exhausted"] = true
          return record_prune_branch_lookup_failure(context, key, prune_budget_exhausted_error(context))
        end

        context.fetch("external_branch_lookups") << key
        cache[key] = Array(invoke_forge_branch_lookup(repository: repository, branch: branch, timeout: remaining))
      rescue StandardError => e
        context ? record_prune_branch_lookup_failure(context, key, e.message) : []
      end

      def record_prune_branch_lookup_failure(context, key, error)
        context.fetch("branch_lookup_failures")[key] = error.to_s
        context.fetch("urls_by_branch")[key] = []
      end

      def pull_request_status(url)
        context = prune_forge_lookup_context
        return forge_client.pull_request_status(url) unless context

        key = url.to_s
        cache = context.fetch("status_by_url")
        return cache.fetch(key) if cache.key?(key)
        unless context.fetch("allow_external", false)
          return cache[key] = unavailable_prune_pull_request_status(key, "PR appeared after the prune lookup snapshot")
        end

        remaining = prune_forge_lookup_remaining(context)
        unless remaining.positive?
          context["budget_exhausted"] = true
          return cache[key] = unavailable_prune_pull_request_status(key, prune_budget_exhausted_error(context))
        end

        context.fetch("external_status_urls") << key
        status = invoke_forge_status_lookup(key, timeout: remaining)
        record_prune_status_availability(context, key, status)
        cache[key] = status
      rescue StandardError => e
        status = unavailable_prune_pull_request_status(url, e.message)
        return status unless context

        record_prune_status_availability(context, url.to_s, status)
        context.fetch("status_by_url")[url.to_s] = status
      end

      def record_prune_status_availability(context, url, status)
        return unless status.is_a?(Hash) && status.fetch("state", nil).to_s == "unknown"

        context.fetch("unavailable_status_urls") << url
      end

      def prune_budget_exhausted_error(context)
        budget = context.is_a?(Hash) ? context.fetch("budget_seconds", prune_forge_lookup_budget) : prune_forge_lookup_budget
        "Prune forge lookup budget of #{format_seconds(budget)}s was exhausted"
      end

      def invoke_forge_status_lookup(url, timeout:)
        method = forge_client.method(:pull_request_status)
        return method.call(url, timeout: timeout) if forge_method_accepts_timeout?(method)

        method.call(url)
      end

      def invoke_forge_branch_lookup(repository:, branch:, timeout:)
        method = forge_client.method(:pull_request_urls_for_branch)
        if forge_method_accepts_timeout?(method)
          return method.call(repository: repository, branch: branch, timeout: timeout)
        end

        method.call(repository: repository, branch: branch)
      end

      def forge_method_accepts_timeout?(method)
        method.parameters.any? do |kind, name|
          kind == :keyrest || (%i[key keyreq].include?(kind) && name == :timeout)
        end
      end

      def unavailable_prune_pull_request_status(url, error)
        {
          "provider" => "unknown",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => error.to_s
        }
      end

      def attach_issue_pull_requests!(issue, delivery_pull_request, candidate_pr_urls)
        return unless issue

        State::Models.attach_pull_requests_to_issue!(
          issue,
          delivery_pull_requests: [delivery_pull_request].compact,
          candidate_urls: candidate_pr_urls,
          reported_urls: delivery_pull_request ? [delivery_pull_request.fetch("url", nil)] : []
        )
      end

      def worker_completion_result(agent, issue)
        result = deep_copy(agent)
        if issue
          result["issue"] = issue_pull_request_summary(issue)
          result["issue_id"] = issue.fetch("id", nil)
        end
        result
      end

      def issue_pull_request_summary(issue)
        {
          "id" => issue.fetch("id", nil),
          "delivery_pull_request" => issue.fetch("delivery_pull_request", nil),
          "delivery_pull_requests" => Array(issue.fetch("delivery_pull_requests", [])),
          "reported_pr_urls" => Array(issue.fetch("reported_pr_urls", [])),
          "candidate_pr_urls" => Array(issue.fetch("candidate_pr_urls", []))
        }.compact
      end

      def issue_pr_urls(issue)
        State::Models.pull_request_urls_from([
          issue.fetch("delivery_pull_request", nil),
          *Array(issue.fetch("delivery_pull_requests", nil)),
          *Array(issue.fetch("reported_pr_urls", nil))
        ])
      end

      def worker_legacy_pr_urls(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        State::Models.pull_request_urls_from([
          agent.fetch("delivery_pull_request", nil),
          metadata.fetch("delivery_pull_request", nil),
          *Array(agent.fetch("delivery_pull_requests", nil)),
          *Array(metadata.fetch("delivery_pull_requests", nil)),
          *Array(agent.fetch("reported_pr_urls", nil)),
          *Array(metadata.fetch("reported_pr_urls", nil))
        ])
      end

      def worker_legacy_candidate_pr_urls(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        State::Models.pull_request_urls_from([
          *Array(agent.fetch("candidate_pr_urls", nil)),
          *Array(metadata.fetch("candidate_pr_urls", nil))
        ])
      end

      def remove_issue_bundles_and_agents!(state, issue_ids:, extra_agent_ids:, reason:, now:, remove_empty_projects: true,
                                           project_ids: [], cleanup_worker_workspaces: false)
        requested_project_ids = Array(project_ids).compact.uniq
        requested_issue_ids = Array(issue_ids).compact.uniq
        initial_project_issue_ids = project_issue_ids(state, requested_project_ids)
        initial_root_issue_ids = (requested_issue_ids + initial_project_issue_ids).uniq
        initial_issue_ids = initial_root_issue_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        initial_worker_ids = state.fetch("agents").filter_map do |agent|
          next unless agent.fetch("type", nil) == "worker"
          next unless initial_issue_ids.include?(agent.fetch("issue_id", nil)) || Array(extra_agent_ids).include?(agent.fetch("id", nil))

          agent.fetch("id", nil)
        end.compact.uniq

        workspace_cleanups = if cleanup_worker_workspaces
                               cleanup_pruned_worker_workspaces!(state, initial_worker_ids, now)
                             else
                               []
                             end
        blocked_worker_ids = workspace_cleanups.reject { |outcome| outcome.fetch("success", false) }
                                                .map { |outcome| outcome.fetch("agent_id") }
        blocked_workers = state.fetch("agents").select { |agent| blocked_worker_ids.include?(agent.fetch("id", nil)) }
        blocked_project_ids = requested_project_ids.select do |project_id|
          blocked_workers.any? { |worker| worker.fetch("project_id", nil) == project_id }
        end
        blocked_issue_ids = requested_issue_ids.select do |issue_id|
          subtree_ids = issue_subtree_ids(state, issue_id)
          blocked_workers.any? { |worker| subtree_ids.include?(worker.fetch("issue_id", nil)) }
        end

        effective_project_ids = requested_project_ids - blocked_project_ids
        effective_issue_ids = (requested_issue_ids - blocked_issue_ids).reject do |issue_id|
          issue = find_issue(state, issue_id)
          issue && blocked_project_ids.include?(issue.fetch("project_id", nil))
        end
        root_issue_ids = (effective_issue_ids + project_issue_ids(state, effective_project_ids)).uniq
        issue_ids_to_remove = root_issue_ids.flat_map { |issue_id| issue_subtree_ids(state, issue_id) }.uniq
        issues_to_remove = state.fetch("issues").select { |issue| issue_ids_to_remove.include?(issue.fetch("id", nil)) }
        affected_project_ids = (issues_to_remove.map { |issue| issue.fetch("project_id", nil) } + effective_project_ids).compact.uniq
        empty_project_ids = if remove_empty_projects
                              affected_project_ids.select do |project_id|
                                state.fetch("issues").none? do |issue|
                                  issue.fetch("project_id", nil) == project_id && !issue_ids_to_remove.include?(issue.fetch("id", nil))
                                end
                              end
                            else
                              []
                            end
        removed_project_ids = (effective_project_ids + empty_project_ids).uniq
        # The agent record owns workspace routing. A stale id in issue.agent_ids must never make
        # pruning one issue remove a worker (and worktree) whose issue_id points at another issue.
        issue_owned_agent_ids = state.fetch("agents").select do |agent|
          issue_ids_to_remove.include?(agent.fetch("issue_id", nil))
        end.map { |agent| agent.fetch("id", nil) }
        originating_head_ids = issues_to_remove.map { |issue| issue.fetch("originating_head_id", nil) }.compact
        related_head_ids = pruned_related_head_agent_ids(state, issue_ids_to_remove, removed_project_ids)
        bundled_agent_ids = (issue_owned_agent_ids + originating_head_ids + related_head_ids).compact.uniq
        effective_extra_agent_ids = Array(extra_agent_ids).compact.uniq - blocked_worker_ids
        agent_ids_to_remove = (bundled_agent_ids + effective_extra_agent_ids).compact.uniq
        standalone_agent_ids = effective_extra_agent_ids - bundled_agent_ids

        released_head_ids = release_head_sessions_for_removed_agents!(state, agent_ids_to_remove, now)
        state["issues"] = state.fetch("issues").reject { |issue| issue_ids_to_remove.include?(issue.fetch("id", nil)) }
        state["agents"] = state.fetch("agents").reject { |agent| agent_ids_to_remove.include?(agent.fetch("id", nil)) }
        state["projects"] = state.fetch("projects").reject { |project| removed_project_ids.include?(project.fetch("id", nil)) }
        state.fetch("issues").each do |issue|
          issue["agent_ids"] = Array(issue.fetch("agent_ids", [])) - agent_ids_to_remove if issue.key?("agent_ids")
          # Killing a worker removes its record, so routing pointers must not keep naming it.
          # A misrouted worker that was killed used to leave `last_agent_id` dangling on the
          # issue it never belonged to.
          clear_dangling_issue_routing_pointer!(issue, agent_ids_to_remove, now)
        end
        updated_project_ids = refresh_projects_after_prune!(state, affected_project_ids - removed_project_ids, now)

        {
          "reason" => reason,
          "root_issue_ids" => root_issue_ids,
          "removed_issue_ids" => issue_ids_to_remove,
          "removed_agent_ids" => agent_ids_to_remove,
          "removed_standalone_agent_ids" => standalone_agent_ids,
          "removed_project_ids" => removed_project_ids,
          "updated_project_ids" => updated_project_ids,
          "released_head_session_agent_ids" => released_head_ids,
          "workspace_cleanup_outcomes" => workspace_cleanups,
          "workspace_cleanup_blocked_agent_ids" => blocked_worker_ids,
          "workspace_cleanup_blocked_issue_ids" => blocked_issue_ids,
          "workspace_cleanup_blocked_project_ids" => blocked_project_ids,
          "workspace_cleanup_log_entry_ids" => workspace_cleanups.flat_map { |outcome| Array(outcome.fetch("log_entry_ids", [])) }.uniq
        }
      end

      def project_issue_ids(state, project_ids)
        state.fetch("issues").select do |issue|
          Array(project_ids).include?(issue.fetch("project_id", nil))
        end.map { |issue| issue.fetch("id") }
      end

      def cleanup_pruned_worker_workspaces!(state, worker_ids, now)
        Array(worker_ids).filter_map do |agent_id|
          worker = find_agent(state, agent_id)
          next unless worker && worker.fetch("type", nil) == "worker"

          protected_paths = state.fetch("agents").filter_map do |other|
            next unless other.fetch("type", nil) == "worker" && other.fetch("id", nil) != agent_id

            worker_worktree_root_path(other)
          end
          outcome = workspace_manager.cleanup_pruned_worker_workspace(
            worker_workspace_cleanup_record(state, worker),
            protected_paths: protected_paths
          ).merge(
            "agent_id" => agent_id,
            "issue_id" => worker.fetch("issue_id", nil),
            "project_id" => worker.fetch("project_id", nil),
            "checked_at" => now
          )
          worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome)
          log_ids = append_workspace_cleanup_log(state, worker, outcome)
          outcome.merge("log_entry_ids" => log_ids)
        rescue StandardError => e
          outcome = {
            "agent_id" => agent_id,
            "issue_id" => worker && worker.fetch("issue_id", nil),
            "project_id" => worker && worker.fetch("project_id", nil),
            "status" => "failed",
            "reason" => "workspace_cleanup_error",
            "success" => false,
            "attempted" => false,
            "error" => sanitized_error_message(e),
            "checked_at" => now
          }.compact
          worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome) if worker
          outcome.merge("log_entry_ids" => worker ? append_workspace_cleanup_log(state, worker, outcome) : [])
        end
      end

      def worker_workspace_cleanup_record(state, worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", nil)
        project = find_project(state, worker.fetch("project_id", nil))
        {
          "workspace_strategy" => worker.fetch("workspace_strategy", nil),
          "workspace_path" => worker.fetch("workspace_path", nil),
          "workspace_branch" => worker.fetch("workspace_branch", nil),
          "project_root" => project && project.fetch("root_path", nil),
          "plan" => plan.is_a?(Hash) ? plan : nil
        }.compact
      end

      def worker_worktree_root_path(worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", {})
        plan = {} unless plan.is_a?(Hash)
        plan["worktree_root_path"] || plan["workspace_root_path"] || worker.fetch("workspace_path", nil) || plan["workspace_path"]
      end

      def append_workspace_cleanup_log(state, worker, outcome)
        status = outcome.fetch("status", "failed")
        return [] if status == "skipped"

        successful = outcome.fetch("success", false)
        message = if status == "removed"
                    "Removed managed worktree for worker #{worker.fetch("id")}."
                  elsif status == "already_removed"
                    "Confirmed the managed worktree for worker #{worker.fetch("id")} was already removed."
                  else
                    "Retained worker #{worker.fetch("id")} because its managed worktree could not be removed: #{outcome.fetch("reason", "unknown_error")}."
                  end
        append_log(
          state,
          source_type: "kernel",
          source_id: worker.fetch("id"),
          level: successful ? "info" : "warning",
          message: message,
          details: outcome.merge(
            "agent_id" => worker.fetch("id"),
            "issue_id" => worker.fetch("issue_id", nil),
            "project_id" => worker.fetch("project_id", nil)
          ).compact
        )
      end

      def annotate_workspace_cleanup_blockers!(issue_decisions, project_decisions, prune_result)
        blocked_issue_ids = prune_result.fetch("workspace_cleanup_blocked_issue_ids", [])
        blocked_project_ids = prune_result.fetch("workspace_cleanup_blocked_project_ids", [])
        failed_outcomes = prune_result.fetch("workspace_cleanup_outcomes", []).reject { |outcome| outcome.fetch("success", false) }
        Array(issue_decisions).each do |decision|
          next unless blocked_issue_ids.include?(decision.fetch("issue_id", nil))

          blocking_agent_ids = failed_outcomes.filter_map do |outcome|
            outcome.fetch("agent_id", nil) if Array(decision.fetch("subtree_issue_ids", [])).include?(outcome.fetch("issue_id", nil))
          end
          decision["prunable"] = false
          decision["blockers"] = (Array(decision.fetch("blockers", [])) + ["workspace_cleanup_failed"]).uniq
          decision["workspace_cleanup_blocking_agent_ids"] = blocking_agent_ids
        end
        Array(project_decisions).each do |decision|
          next unless blocked_project_ids.include?(decision.fetch("project_id", nil))

          blocking_agent_ids = failed_outcomes.filter_map do |outcome|
            outcome.fetch("agent_id", nil) if outcome.fetch("project_id", nil) == decision.fetch("project_id", nil)
          end
          decision["prunable"] = false
          decision["blockers"] = (Array(decision.fetch("blockers", [])) + ["workspace_cleanup_failed"]).uniq
          decision["workspace_cleanup_blocking_agent_ids"] = blocking_agent_ids
        end
      end

      def clear_dangling_issue_routing_pointer!(issue, removed_agent_ids, now)
        return unless removed_agent_ids.include?(issue.fetch("last_agent_id", nil))

        issue["last_agent_id"] = Array(issue.fetch("agent_ids", [])).last
        issue["last_routing_action"] = nil if issue["last_agent_id"].nil?
        issue["updated_at"] = now
      end

      # A head's harness session only lives as long as its head record. Whenever a head
      # leaves active state its session is stopped and marked terminal; worker session
      # handling is intentionally untouched here.
      def release_head_sessions_for_removed_agents!(state, agent_ids, now)
        Array(agent_ids).filter_map do |agent_id|
          agent = find_agent(state, agent_id)
          next unless agent && agent.fetch("type", nil) == "head"

          release_head_session!(agent, reason: "head_record_removed", now: now).fetch("changed", false) ? agent_id : nil
        end
      end

      def pruned_related_head_agent_ids(state, issue_ids_to_remove, removed_project_ids)
        state.fetch("agents").select { |agent| agent.fetch("type", nil) == "head" }
             .reject { |agent| head_applying_batch?(agent) }
             .select { |agent| head_related_to_pruned_work?(state, agent, issue_ids_to_remove, removed_project_ids) }
             .map { |agent| agent.fetch("id", nil) }
      end

      # A head that is mid-batch owns the commands still being journaled. Pruning it from inside
      # its own `Prune` command would drop the journal and abort the rest of the batch.
      def head_applying_batch?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.is_a?(Hash) && metadata.fetch("head_result_apply_state", nil) == "applying"
      end

      def head_related_to_pruned_work?(state, head, issue_ids_to_remove, removed_project_ids)
        return true if issue_ids_to_remove.include?(head.fetch("issue_id", nil))
        return true if removed_project_ids.include?(head.fetch("project_id", nil))

        related = head_result_related_ids(state, head)
        (related.fetch("issue_ids") & issue_ids_to_remove).any? ||
          (related.fetch("project_ids") & removed_project_ids).any?
      end

      def head_result_related_ids(state, head)
        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", nil)
        commands = head_result.is_a?(Hash) ? Array(value_at(head_result, "commands") || []) : []
        journal_issue_ids = head_batch_created_issues(Array(metadata.fetch("head_result_command_journal", []))).filter_map { |entry| entry.fetch("issue_id", nil) }
        commands.each_with_object({ "issue_ids" => journal_issue_ids.dup, "project_ids" => [] }) do |command, ids|
          next unless command.is_a?(Hash)

          payload = value_at(command, "payload")
          payload = {} unless payload.is_a?(Hash)
          collect_head_command_related_ids!(state, ids, payload)
        end.transform_values { |values| values.compact.uniq }
      end

      def collect_head_command_related_ids!(state, ids, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        target_id = value_at(payload, "target_id", "TargetID", "targetId", "id")

        ids.fetch("issue_ids") << issue_id if present_string(issue_id) && !batch_issue_reference_value?(issue_id)
        ids.fetch("project_ids") << project_id if present_string(project_id)
        collect_related_ids_for_agent_target!(state, ids, agent_id)
        collect_related_ids_for_target!(state, ids, target_id)
      end

      def collect_related_ids_for_agent_target!(state, ids, agent_id)
        agent = present_string(agent_id) && find_agent(state, agent_id)
        return unless agent

        ids.fetch("issue_ids") << agent.fetch("issue_id", nil)
        ids.fetch("project_ids") << agent.fetch("project_id", nil)
      end

      def collect_related_ids_for_target!(state, ids, target_id)
        target = present_string(target_id)
        return unless target

        if (issue = find_issue(state, target))
          ids.fetch("issue_ids") << issue.fetch("id", nil)
          ids.fetch("project_ids") << issue.fetch("project_id", nil)
        elsif (project = find_project(state, target))
          ids.fetch("project_ids") << project.fetch("id", nil)
        elsif (agent = find_agent(state, target))
          ids.fetch("issue_ids") << agent.fetch("issue_id", nil)
          ids.fetch("project_ids") << agent.fetch("project_id", nil)
        end
      end

      def issue_subtree_ids(state, root_issue_id)
        root = root_issue_id.to_s
        return [] unless find_issue(state, root)

        children = state.fetch("issues").select { |issue| issue.fetch("parent_issue_id", nil) == root }.map { |issue| issue.fetch("id") }
        [root] + children.flat_map { |child_id| issue_subtree_ids(state, child_id) }
      end

      def refresh_projects_after_prune!(state, project_ids, now)
        Array(project_ids).filter_map do |project_id|
          project = find_project(state, project_id)
          next unless project

          update_project_status_from_issues!(state, project, now)
          project.fetch("id")
        end
      end

      def clear_state(command_id, command_type)
        now = timestamp
        state = State::Models.empty_state(now: now)
        store.save(state, preserve_log_buffer: false)

        accepted_result(command_id, command_type, nil, "Cleared Meringue state.", state, [])
      end

      def ask_question(command_id, command_type, payload)
        head_id = value_at(payload, "head_id", "HeadID", "headId", "_head_id")
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

        # One clarification must produce one question record and one log line, even when a head
        # expresses it both in its HeadResult `questions` array and as an `AskQuestion` command.
        existing_question = find_duplicate_head_question(state, head_id.to_s, question_text)
        if existing_question
          return accepted_result(
            command_id,
            command_type,
            existing_question.fetch("id"),
            "Question #{existing_question.fetch("id")} already records this clarification for head #{head_id}.",
            existing_question,
            []
          )
        end

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
          message: "Question #{question.fetch("id")}: #{question.fetch("question")}",
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
        mode = (value_at(payload, "mode", "Mode") || "normal").to_s
        errors = []

        errors << "agent_id is required" if blank?(agent_id)
        errors << "prompt is required" if blank?(prompt)
        errors << "mode must be one of #{PROMPT_MODES.join(", ")}" unless PROMPT_MODES.include?(mode)
        return rejected_result(command_id, command_type, "Agent was not prompted.", errors) unless errors.empty?

        state = normalized_state
        agent = find_agent(state, agent_id)
        return rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
        return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
        return rejected_result(command_id, command_type, "Agent #{agent_id} cannot be continued because it is #{agent.fetch("status")}.", ["agent_not_resumable"]) if %w[killed errored].include?(agent.fetch("status", nil))
        if blank?(agent.fetch("pid", nil)) && blank?(agent.fetch("harness_session_id", nil)) && blank?(agent.fetch("harness_session_file", nil))
          return rejected_result(command_id, command_type, "Agent #{agent_id} has no agent session.", ["missing_harness_session"])
        end

        pending_prompt_id = present_string(value_at(payload, "_pending_prompt_id", "pending_prompt_id"))
        client = harness_client_for_agent(agent)
        session_ref = agent_session_ref(agent)
        begin
          session_ref = client.prompt_session(session_ref, prompt.to_s, mode: mode)
        rescue StandardError => e
          # A session that is busy elsewhere is a timing condition, not a failure: queue the
          # prompt and let reconciliation deliver it once the current turn settles.
          if Harness.transient_session_error?(e)
            return queue_transient_prompt(
              command_id: command_id,
              command_type: command_type,
              agent_id: agent.fetch("id"),
              prompt: prompt.to_s,
              mode: mode,
              pending_prompt_id: pending_prompt_id,
              error: e
            )
          end

          return failed_result(
            command_id,
            command_type,
            "Could not prompt agent #{agent_id}: #{e.message}",
            [e.class.name, e.message]
          )
        end

        now = timestamp
        session_metadata = session_ref.fetch("metadata", {}) || {}
        previous_metadata = agent.fetch("harness_metadata", {}) || {}
        # The harness may have had to deliver the prompt in a different mode than the caller asked
        # for (a normal prompt into a mid-turn session is queued as a follow-up instead of being
        # dropped). Record and log what actually happened, not what was requested.
        delivered_mode = delivered_prompt_mode(session_metadata, mode)
        coerced = delivered_mode != mode
        mode_note = coerced ? present_string(session_metadata.fetch("prompt_mode_note", nil)) : nil
        agent["status"] = "working"
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["session_settings"] = deep_copy(session_ref.fetch("session_settings")) if session_ref.fetch("session_settings", nil).is_a?(Hash)
        agent["harness_metadata"] = previous_metadata.merge(
          session_metadata,
          "prompt_count" => previous_metadata.fetch("prompt_count", 0).to_i + 1,
          "last_prompt_mode" => delivered_mode,
          "requested_prompt_mode" => coerced ? mode : nil,
          "delivered_prompt_mode" => coerced ? delivered_mode : nil,
          "prompt_mode_note" => mode_note,
          "last_prompted_at" => now,
          "is_streaming" => session_ref.fetch("is_streaming", false),
          "last_event_at" => session_ref.fetch("last_event_at", nil),
          "routing_action" => prompt_routing_action(delivered_mode)
        ).compact
        agent["updated_at"] = now

        issue = find_issue(state, agent.fetch("issue_id", nil))
        project = issue && find_project(state, issue.fetch("project_id", nil))
        if issue
          issue["status"] = "working"
          issue["last_agent_id"] = agent.fetch("id")
          issue["last_routing_action"] = prompt_routing_action(delivered_mode)
          issue["last_routed_at"] = now
          issue["updated_at"] = now
        end
        if project
          project["status"] = "working"
          project["updated_at"] = now
        end

        # The harness accepted the prompt, so the delivery is logged exactly once, here.
        remove_pending_prompts!(agent, pending_prompt_id: pending_prompt_id, command_id: command_id)
        delivery_message = prompt_log_message(agent, delivered_mode, requested_mode: coerced ? mode : nil, note: mode_note)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: delivery_message,
          details: {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "agent_id" => agent.fetch("id"),
            "mode" => delivered_mode,
            "requested_mode" => mode,
            "prompt_mode_note" => mode_note,
            "routing_action" => prompt_routing_action(delivered_mode),
            "is_streaming" => session_ref.fetch("is_streaming", false)
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, agent.fetch("id"), delivery_message, agent, log_ids)
      end

      # Harness clients report a mode they had to substitute through generic session metadata; an
      # unknown or absent value means the requested mode was used as-is.
      def delivered_prompt_mode(session_metadata, requested_mode)
        reported = present_string(session_metadata.fetch("delivered_prompt_mode", nil))
        return requested_mode.to_s unless reported && PROMPT_MODES.include?(reported)

        reported
      end

      # A session that is momentarily owned by another instance mid-turn is not a command failure.
      # The prompt is stored on the agent and redelivered by reconciliation until it lands.
      def queue_transient_prompt(command_id:, command_type:, agent_id:, prompt:, mode:, pending_prompt_id:, error:)
        state = normalized_state
        agent = find_agent(state, agent_id)
        return failed_result(command_id, command_type, "Agent #{agent_id} disappeared before its prompt could be queued.", ["agent_not_found"]) unless agent

        now = timestamp
        metadata = agent.fetch("harness_metadata", {}) || {}
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        existing = pending.find do |entry|
          (pending_prompt_id && entry.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && entry.fetch("command_id", nil).to_s == command_id.to_s) ||
            (entry.fetch("prompt", nil).to_s == prompt && entry.fetch("mode", nil).to_s == mode.to_s)
        end

        attempts = existing ? existing.fetch("attempts", 0).to_i + 1 : 1
        if attempts > PENDING_PROMPT_MAX_ATTEMPTS
          pending.delete(existing)
          metadata["pending_prompts"] = pending
          agent["harness_metadata"] = metadata
          agent["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent.fetch("id"),
            level: "warning",
            message: "Gave up the queued #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} after #{PENDING_PROMPT_MAX_ATTEMPTS} attempts: #{error.message}",
            details: { "agent_id" => agent.fetch("id"), "mode" => mode, "attempts" => attempts }
          )
          touch_state!(state, now)
          store.save(state)
          return rejected_result(command_id, command_type, "Worker #{agent.fetch("id")} could not accept the prompt: #{error.message}", ["session_busy"])
        end

        entry = existing || {
          "id" => next_pending_prompt_id(agent, pending),
          "command_id" => present_string(command_id),
          "prompt" => prompt,
          "mode" => mode.to_s,
          "queued_at" => now
        }.compact
        entry["attempts"] = attempts
        entry["last_attempted_at"] = now
        entry["last_error"] = error.message
        pending << entry unless existing
        metadata["pending_prompts"] = pending
        agent["harness_metadata"] = metadata
        agent["updated_at"] = now

        log_ids = if existing
                    []
                  else
                    append_log(
                      state,
                      source_type: "kernel",
                      source_id: agent.fetch("id"),
                      level: "info",
                      message: "Waiting to deliver the #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} until its current turn settles.",
                      details: {
                        "agent_id" => agent.fetch("id"),
                        "issue_id" => agent.fetch("issue_id", nil),
                        "mode" => mode.to_s,
                        "pending_prompt_id" => entry.fetch("id")
                      }
                    )
                  end
        touch_state!(state, now)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          agent.fetch("id"),
          "Queued the #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} until its current turn settles.",
          { "agent_id" => agent.fetch("id"), "queued" => true, "pending_prompt_id" => entry.fetch("id"), "attempts" => attempts },
          log_ids
        )
      end

      def remove_pending_prompts!(agent, pending_prompt_id:, command_id:)
        metadata = agent.fetch("harness_metadata", {}) || {}
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        return if pending.empty?

        remaining = pending.reject do |entry|
          (pending_prompt_id && entry.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && entry.fetch("command_id", nil).to_s == command_id.to_s)
        end
        metadata["pending_prompts"] = remaining
        agent["harness_metadata"] = metadata
      end

      def prompt_delivery_noun(mode)
        case mode.to_s
        when "steer" then "correction"
        when "follow_up" then "follow-up"
        else "prompt"
        end
      end

      def next_pending_prompt_id(agent, pending)
        numbers = Array(pending).filter_map do |entry|
          match = entry.is_a?(Hash) && entry.fetch("id", "").to_s.match(/-PP(\d+)\z/)
          match && match[1].to_i
        end
        "#{agent.fetch("id")}-PP#{(numbers.max || 0) + 1}"
      end

      # Redelivers prompts that were queued while a session was busy mid-turn.
      def deliver_pending_agent_prompts
        pending = synchronized_state do
          normalized_state.fetch("agents").flat_map do |agent|
            next [] unless agent.fetch("type", nil) == "worker"
            next [] if TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil))

            metadata = agent.fetch("harness_metadata", {}) || {}
            Array(metadata.fetch("pending_prompts", [])).filter_map do |entry|
              next nil unless entry.is_a?(Hash) && present_string(entry.fetch("prompt", nil))

              { "agent_id" => agent.fetch("id"), "entry" => deep_copy(entry) }
            end
          end
        end

        pending.map do |item|
          entry = item.fetch("entry")
          apply(
            "command_id" => entry.fetch("command_id", nil),
            "type" => "PromptAgent",
            "payload" => {
              "agent_id" => item.fetch("agent_id"),
              "prompt" => entry.fetch("prompt"),
              "mode" => entry.fetch("mode", "normal"),
              "_pending_prompt_id" => entry.fetch("id", nil)
            }
          )
        end
      end

      def spawn_worker(command_id, command_type, payload)
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        prompt = value_at(payload, "prompt", "Prompt")
        worker_title = value_at(payload, "title", "Title", "worker_title", "workerTitle")
        follow_up_of_agent_id = value_at(payload, "follow_up_of_agent_id", "followUpOfAgentID", "followUpOfAgentId")
        replace_agent_id = value_at(payload, "replace_agent_id", "replaceAgentID", "replaceAgentId")
        after_agent_id = value_at(payload, *DEFERRED_WORKER_AFTER_KEYS)
        failure_policy = normalized_deferred_failure_policy(payload)
        include_predecessor_result = deferred_handover_requested?(payload)
        # Set by the kernel when it starts a worker it had queued behind another agent. It is the
        # only way past the deferral branch, so a queued worker cannot start itself twice.
        activating_deferred = !!value_at(payload, "_activate_deferred", "activate_deferred")
        deferred_agent_id = present_string(value_at(payload, "_deferred_agent_id", "deferred_agent_id"))
        requested_workspace_path = value_at(payload, "workspace_path", "WorkspacePath", "workspacePath")
        # Set by the kernel when it corrected a head's predicted issue id; kept on the worker and
        # in its spawn log so a corrected route is visible instead of silent.
        rerouted_from_issue_id = present_string(value_at(payload, "_rerouted_from_issue_id", "rerouted_from_issue_id"))
        errors = []

        errors << "issue_id is required" if blank?(issue_id)
        errors << "prompt is required" if blank?(prompt)
        if present_string(follow_up_of_agent_id) && present_string(replace_agent_id)
          errors << "follow_up_of_agent_id and replace_agent_id are mutually exclusive"
        end
        if present_string(after_agent_id) && present_string(replace_agent_id)
          # A replacement takes over now: the kernel spawns the successor and then kills the worker
          # it replaces. Deferring that would leave the replaced worker running indefinitely.
          errors << "deferred_after_agent_conflicts_with_replace"
        end
        errors << "invalid_if_predecessor_fails" if failure_policy.nil?
        return synchronized_state { rejected_result(command_id, command_type, "Worker was not spawned.", errors) } unless errors.empty?

        reservation = synchronized_state do
          state = normalized_state
          issue = find_issue(state, issue_id)
          return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) unless issue

          project = find_project(state, issue.fetch("project_id"))
          return rejected_result(command_id, command_type, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

          # An activation names the queued record directly: its reservation was written by an earlier
          # command, so resolving it only through spawn_command_id would risk provisioning a second
          # worker for the same queued record.
          existing = worker_for_spawn_command(state, command_id)
          existing ||= find_agent(state, deferred_agent_id) if activating_deferred && deferred_agent_id
          if existing && agent_has_session_reference?(existing)
            return accepted_result(command_id, command_type, existing.fetch("id"), "Worker #{existing.fetch("id")} was already spawned.", existing, [])
          end
          # A reservation being provisioned by another live instance must not be
          # provisioned again here: that races on the same worktree branch and
          # leaves two harness sessions in one workspace.
          if existing && worker_provisioning_in_progress?(existing) && owned_by_other_live_instance?(existing)
            return rejected_result(
              command_id,
              command_type,
              "Worker #{existing.fetch("id")} is already being spawned by another Meringue instance.",
              ["worker_spawn_in_progress"]
            )
          end
          # This command already queued its worker behind another agent. Report the queued record
          # instead of starting a second session for the same logical command.
          if existing && waiting_deferred_worker?(existing) && !activating_deferred
            return accepted_result(
              command_id,
              command_type,
              existing.fetch("id"),
              deferred_queue_message(existing),
              deep_copy(existing),
              []
            )
          end

          unless existing
            related_agent_id = present_string(replace_agent_id) || present_string(follow_up_of_agent_id)
            related_agent = find_agent(state, related_agent_id) if related_agent_id
            if related_agent_id && (!related_agent || related_agent.fetch("type", nil) != "worker")
              return rejected_result(
                command_id,
                command_type,
                "Related worker #{related_agent_id} does not exist. #{RELATED_AGENT_REFERENCE_HINT}",
                ["related_agent_not_found"]
              )
            end
            if related_agent && related_agent.fetch("issue_id", nil) != issue.fetch("id")
              return rejected_result(
                command_id,
                command_type,
                "Related worker #{related_agent_id} belongs to another issue. #{RELATED_AGENT_REFERENCE_HINT}",
                ["related_agent_issue_mismatch"]
              )
            end
            if present_string(replace_agent_id) && !replaceable_worker?(related_agent)
              return rejected_result(command_id, command_type, "Worker #{related_agent_id} has already been killed or replaced.", ["agent_not_replaceable"])
            end

            if present_string(after_agent_id) && !activating_deferred
              decision = deferred_spawn_decision(state, after_agent_id: after_agent_id, failure_policy: failure_policy)
              case decision.fetch("kind")
              when "reject"
                return rejected_result(command_id, command_type, decision.fetch("message"), decision.fetch("errors"))
              when "defer"
                return queue_deferred_worker(
                  state,
                  command_id: command_id,
                  command_type: command_type,
                  issue: issue,
                  project: project,
                  prompt: prompt,
                  title: worker_title,
                  requested_workspace_path: requested_workspace_path,
                  follow_up_of_agent_id: present_string(follow_up_of_agent_id),
                  predecessor: decision.fetch("predecessor"),
                  chain_depth: decision.fetch("chain_depth"),
                  failure_policy: failure_policy,
                  include_predecessor_result: include_predecessor_result,
                  rerouted_from_issue_id: rerouted_from_issue_id
                )
              else
                # Nothing left to wait for: the predecessor already settled, so start now and still
                # hand its final report to this worker.
                after_agent_id = decision.fetch("predecessor").fetch("id")
                prompt = deferred_handover_prompt(prompt, decision.fetch("predecessor"), include_predecessor_result)
              end
            end
          end

          active_provider = active_harness_provider(state)
          now = timestamp
          if existing
            agent_id = existing.fetch("id")
            workspace = workspace_from_reserved_agent(existing)
            active_provider = existing.fetch("harness", active_provider)
            existing_metadata = existing.fetch("harness_metadata", {}) || {}
            follow_up_of_agent_id = existing_metadata.fetch("follow_up_of_agent_id", follow_up_of_agent_id)
            replace_agent_id = existing_metadata.fetch("replace_agent_id", replace_agent_id)
            after_agent_id = present_string(existing.fetch("after_agent_id", nil)) ||
                             present_string(deferred_spawn_metadata(existing).fetch("after_agent_id", nil)) ||
                             present_string(after_agent_id)
          else
            agent_id = next_worker_id!(state, issue.fetch("id"))
            workspace = resolve_worker_workspace(
              project: project,
              issue: issue,
              requested_workspace_path: requested_workspace_path,
              preview_agent_id: agent_id,
              task_title: worker_display_title(worker_title, issue),
              create: false
            )
            return rejected_result(command_id, command_type, "Worker workspace is invalid.", workspace.fetch("errors")) unless workspace.fetch("errors").empty?

            agent = build_worker_reservation(
              agent_id: agent_id,
              issue: issue,
              project: project,
              workspace: workspace,
              provider: active_provider,
              command_id: command_id,
              prompt: prompt,
              title: worker_title,
              requested_workspace_path: requested_workspace_path,
              follow_up_of_agent_id: follow_up_of_agent_id,
              replace_agent_id: replace_agent_id,
              after_agent_id: present_string(after_agent_id),
              now: now,
              harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i
            )
            state.fetch("agents") << agent
            issue.fetch("agent_ids") << agent_id unless issue.fetch("agent_ids").include?(agent_id)
            issue["status"] = "working"
            issue["updated_at"] = now
            project["status"] = "working"
            project["updated_at"] = now
            append_log(
              state,
              source_type: "kernel",
              source_id: agent_id,
              level: "info",
              message: "Provisioning workspace for worker #{agent_id}.",
              details: { "issue_id" => issue.fetch("id"), "workspace_branch" => workspace.fetch("workspace_branch", nil) }
            )
          end
          touch_state!(state, now)
          store.save(state)

          {
            "agent_id" => agent_id,
            "issue" => deep_copy(issue),
            "project" => deep_copy(project),
            "workspace" => workspace,
            "now" => now,
            "harness" => active_provider,
            "harness_generation" => state.fetch("metadata").fetch("harness_generation", 0).to_i,
            "follow_up_of_agent_id" => present_string(follow_up_of_agent_id),
            "replace_agent_id" => present_string(replace_agent_id),
            "after_agent_id" => present_string(after_agent_id),
            "prompt" => prompt.to_s
          }
        end
        prompt = reservation.fetch("prompt", prompt)

        workspace = resolve_worker_workspace(
          project: reservation.fetch("project"),
          issue: reservation.fetch("issue"),
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: reservation.fetch("agent_id"),
          task_title: worker_display_title(worker_title, reservation.fetch("issue")),
          create: true
        )
        if workspace.fetch("errors", []).any?
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Worker workspace provisioning failed: #{workspace.fetch("errors").join("; ")}",
            errors: workspace.fetch("errors"),
            workspace: workspace
          )
        end
        reservation["workspace"] = workspace
        checkpoint_worker_workspace!(reservation, workspace)

        session_ref = nil
        begin
          session_ref = active_harness_client(provider: reservation.fetch("harness")).spawn_session(
            kind: "worker",
            cwd: workspace.fetch("workspace_path"),
            prompt: prompt.to_s,
            system_prompt: worker_system_prompt(reservation.fetch("issue")),
            session_name: worker_session_name(reservation.fetch("issue"), worker_title: worker_title)
          )
        rescue StandardError => e
          cleanup_worker_workspace_safely(workspace)
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Could not start an agent session for worker #{reservation.fetch("agent_id")}: #{e.message}",
            errors: [e.class.name, e.message],
            workspace: workspace
          )
        end

        synchronized_state do
          state = normalized_state
          issue = find_issue(state, reservation.fetch("issue").fetch("id"))
          project = issue && find_project(state, issue.fetch("project_id"))
          reserved_agent = find_agent(state, reservation.fetch("agent_id"))
          unless issue && project && reserved_agent
            kill_session_safely(session_ref)
            cleanup_worker_workspace_safely(workspace)
            return failed_result(
              command_id,
              command_type,
              "Worker #{reservation.fetch("agent_id")} could not be recorded because its reservation, issue, or project no longer exists.",
              ["reservation_issue_or_project_not_found"]
            )
          end

          follow_up_of_id = reservation.fetch("follow_up_of_agent_id", nil)
          replaces_id = reservation.fetch("replace_agent_id", nil)
          related_agent_id = replaces_id || follow_up_of_id
          related_agent = find_agent(state, related_agent_id) if related_agent_id
          relation_invalid = related_agent_id && (!related_agent || related_agent.fetch("issue_id", nil) != issue.fetch("id"))
          replacement_invalid = replaces_id && !replaceable_worker?(related_agent)
          if relation_invalid || replacement_invalid
            kill_session_safely(session_ref)
            cleanup_worker_workspace_safely(reservation.fetch("workspace"))
            return fail_worker_reservation(
              reservation,
              command_id: command_id,
              command_type: command_type,
              message: "Worker #{reservation.fetch("agent_id")} could not be related because the prior worker is no longer available on this issue.",
              errors: ["related_agent_unavailable"],
              workspace: reservation.fetch("workspace")
            )
          end

          after_agent_value = present_string(reservation.fetch("after_agent_id", nil)) ||
                              present_string(reserved_agent.fetch("after_agent_id", nil))
          agent = build_worker_agent(
            agent_id: reservation.fetch("agent_id"),
            issue: issue,
            project: project,
            workspace: workspace,
            session_ref: session_ref,
            now: reserved_agent.fetch("created_at", reservation.fetch("now")),
            title: worker_title,
            harness_generation: reservation.fetch("harness_generation"),
            follow_up_of_agent_id: follow_up_of_id,
            replaces_agent_id: replaces_id,
            after_agent_id: after_agent_value
          )
          now = timestamp
          agent["harness_metadata"] = (reserved_agent.fetch("harness_metadata", {}) || {}).merge(agent.fetch("harness_metadata", {})).merge(
            "provisioning_state" => "ready",
            "provisioned_at" => now,
            "spawn_command_id" => command_id,
            "rerouted_from_issue_id" => rerouted_from_issue_id,
            "deferred_spawn" => activated_deferred_spawn_metadata(reserved_agent, now)
          ).compact
          state.fetch("agents")[state.fetch("agents").index(reserved_agent)] = agent
          issue.fetch("agent_ids") << reservation.fetch("agent_id") unless issue.fetch("agent_ids").include?(reservation.fetch("agent_id"))
          if related_agent && follow_up_of_id
            related_agent["follow_up_agent_ids"] = (Array(related_agent["follow_up_agent_ids"]) + [agent.fetch("id")]).uniq
            related_agent["updated_at"] = now
          end
          repointed_dependents = { "agent_ids" => [], "log_entry_ids" => [] }
          if related_agent && replaces_id
            mark_agent_killed!(related_agent, now)
            related_agent["replaced_by_agent_id"] = agent.fetch("id")
            # The successor inherits the replaced worker's queue in the same command. Waiting for
            # reconciliation would race the pass that removes the replaced record.
            repointed_dependents = repoint_deferred_dependents_in_state!(
              state,
              from_agent_id: replaces_id,
              to_agent: agent,
              now: now,
              trigger: "replacement"
            )
            kill_session_safely(session_ref_from_agent(related_agent), agent: related_agent) if present_string(related_agent.fetch("harness", nil))
          end
          issue["status"] = "working"
          issue["last_agent_id"] = agent.fetch("id")
          issue["last_routing_action"] = spawn_routing_action(follow_up_of_id, replaces_id)
          issue["last_routed_at"] = now
          issue["updated_at"] = now
          project["status"] = "working"
          project["updated_at"] = now

          log_message = spawn_worker_log_message(agent, issue)
          log_ids = repointed_dependents.fetch("log_entry_ids").dup
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: reservation.fetch("agent_id"),
            level: "info",
            message: log_message,
            details: {
              "issue_id" => issue.fetch("id"),
              "project_id" => project.fetch("id"),
              "agent_id" => agent.fetch("id"),
              "routing_action" => spawn_routing_action(follow_up_of_id, replaces_id),
              "follow_up_of_agent_id" => follow_up_of_id,
              "replaces_agent_id" => replaces_id,
              "after_agent_id" => after_agent_value,
              "workspace_path" => agent.fetch("workspace_path"),
              "workspace_strategy" => agent.fetch("workspace_strategy"),
              "workspace_branch" => agent.fetch("workspace_branch"),
              "title" => agent.fetch("harness_metadata", {}).fetch("title", nil),
              "rerouted_from_issue_id" => rerouted_from_issue_id,
              "repointed_deferred_agent_ids" => repointed_dependents.fetch("agent_ids").empty? ? nil : repointed_dependents.fetch("agent_ids")
            }.compact
          ))
          touch_state!(state, now)
          store.save(state)

          accepted_result(command_id, command_type, reservation.fetch("agent_id"), log_message, agent, log_ids)
        end
      rescue StandardError => e
        kill_session_safely(session_ref) if session_ref
        cleanup_worker_workspace_safely(reservation.fetch("workspace")) if defined?(reservation) && reservation && reservation["workspace"]
        if defined?(reservation) && reservation
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Worker #{reservation.fetch("agent_id")} failed during provisioning: #{e.message}",
            errors: [e.class.name, e.message],
            workspace: reservation.fetch("workspace", {})
          )
        end
        raise e
      end

      def worker_provisioning_in_progress?(agent)
        state = (agent.fetch("harness_metadata", {}) || {}).fetch("provisioning_state", nil)
        %w[allocating_workspace starting_harness].include?(state.to_s)
      end

      def worker_for_spawn_command(state, command_id)
        return nil if blank?(command_id)

        state.fetch("agents").find do |agent|
          agent.fetch("type", nil) == "worker" &&
            (agent.fetch("harness_metadata", {}) || {}).fetch("spawn_command_id", nil).to_s == command_id.to_s
        end
      end

      # --- Deferred (queued-after) workers ------------------------------------------------------
      #
      # Dependency model: a dependent is an ordinary queued worker agent record with a top-level
      # `after_agent_id` plus a `harness_metadata.deferred_spawn` block. The record *is* the whole
      # dependency, so nothing sleeps or polls for it, the AgentTree/GetInfo/Kill/Prune/Recount
      # paths already understand it, and any kernel instance can resolve it after a restart.
      #
      # Settle policy. Every outcome is logged; a dependent is never silently dropped.
      #   completed -> activate, handing the predecessor's final report to the dependent
      #   errored   -> cancel by default, or start anyway with `if_predecessor_fails: "run"`
      #   killed    -> cancel, unless the kill was a replacement, in which case the dependent is
      #                re-pointed at the successor that took the predecessor's place
      #   removed   -> cancel (prune retains a predecessor while a dependent still waits, so this
      #                only happens after an out-of-band removal)
      #   queued/working/idle/blocked -> keep waiting
      def deferred_spawn_metadata(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        deferred = metadata.fetch("deferred_spawn", nil)
        deferred.is_a?(Hash) ? deferred : {}
      end

      # A worker that is deliberately not started yet. Deliberately narrow: it must still be queued
      # with no session, so a half-provisioned worker is never mistaken for a queued dependent.
      def waiting_deferred_worker?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "queued"
        return false if agent_has_session_reference?(agent)

        deferred_spawn_metadata(agent).fetch("state", nil) == DEFERRED_STATE_WAITING
      end

      def pending_deferred_worker?(agent)
        DEFERRED_PENDING_STATES.include?(deferred_spawn_metadata(agent).fetch("state", nil))
      end

      def deferred_worker_after_agent_id(agent)
        present_string(agent.fetch("after_agent_id", nil)) ||
          present_string(deferred_spawn_metadata(agent).fetch("after_agent_id", nil))
      end

      def waiting_deferred_dependents(state, predecessor_ids)
        wanted = Array(predecessor_ids).compact.map(&:to_s).reject(&:empty?)
        return [] if wanted.empty?

        state.fetch("agents").select do |agent|
          next false unless waiting_deferred_worker?(agent)

          after_agent_id = deferred_worker_after_agent_id(agent)
          wanted.any? { |candidate| Ids.same?(candidate, after_agent_id) }
        end
      end

      def normalized_deferred_failure_policy(payload)
        raw = present_string(value_at(payload, *DEFERRED_WORKER_FAILURE_POLICY_KEYS))
        return DEFERRED_WORKER_DEFAULT_FAILURE_POLICY unless raw

        normalized = raw.downcase.tr("-", "_")
        normalized = "run" if %w[run run_anyway continue proceed start].include?(normalized)
        normalized = "cancel" if %w[cancel skip drop abort].include?(normalized)
        DEFERRED_WORKER_FAILURE_POLICIES.include?(normalized) ? normalized : nil
      end

      def deferred_handover_requested?(payload)
        raw = value_at(payload, *DEFERRED_WORKER_HANDOVER_KEYS)
        return true if raw.nil?

        !%w[false 0 no off].include?(raw.to_s.strip.downcase)
      end

      # Validation for one `after_agent_id` at spawn time. Returns a rejection, a deferral, or
      # "start now" when there is nothing left to wait for.
      def deferred_spawn_decision(state, after_agent_id:, failure_policy:)
        requested = present_string(after_agent_id)
        predecessor = find_agent(state, requested)
        unless predecessor
          return deferred_rejection("SpawnWorker cannot wait for #{requested} because that agent does not exist.", ["after_agent_not_found"])
        end
        unless predecessor.fetch("type", nil) == "worker"
          return deferred_rejection(
            "SpawnWorker can only wait for a worker; #{requested} is a #{predecessor.fetch("type", "record")}.",
            ["after_agent_is_not_worker"]
          )
        end

        chain = deferred_pending_chain(state, predecessor)
        if chain.fetch("cycle")
          return deferred_rejection(
            "SpawnWorker cannot wait for #{requested} because its queue already loops (#{chain.fetch("ids").join(" -> ")}).",
            ["deferred_after_agent_cycle"]
          )
        end
        chain_depth = chain.fetch("depth").to_i + 1
        if chain_depth > DEFERRED_WORKER_MAX_CHAIN_DEPTH
          return deferred_rejection(
            "SpawnWorker cannot wait for #{requested} because that would queue #{chain_depth} workers in a row; the limit is #{DEFERRED_WORKER_MAX_CHAIN_DEPTH}.",
            ["deferred_chain_too_deep"]
          )
        end

        status = predecessor.fetch("status", nil).to_s
        unless TERMINAL_AGENT_STATUSES.include?(status)
          return { "kind" => "defer", "predecessor" => deep_copy(predecessor), "chain_depth" => chain_depth }
        end
        return { "kind" => "start_now", "predecessor" => deep_copy(predecessor) } if status == "completed"
        return { "kind" => "start_now", "predecessor" => deep_copy(predecessor) } if status == "errored" && failure_policy == "run"

        deferred_rejection(
          "SpawnWorker cannot wait for #{requested} because it already #{status == "killed" ? "was killed" : "errored"}. " \
            "Spawn the worker without after_agent_id, or set if_predecessor_fails to \"run\" when the follow-up work should happen anyway.",
          ["deferred_predecessor_already_#{status}"]
        )
      end

      def deferred_rejection(message, errors)
        { "kind" => "reject", "message" => message, "errors" => errors }
      end

      # Walks the still-pending part of the chain above `agent`. Only queued/activating links count:
      # an already-activated dependency is history, not scheduled work.
      def deferred_pending_chain(state, agent)
        ids = []
        current = agent
        depth = 0
        while current
          id = current.fetch("id", nil)
          return { "cycle" => true, "depth" => depth, "ids" => ids + [id] } if ids.include?(id)

          ids << id
          break unless pending_deferred_worker?(current)

          next_id = deferred_worker_after_agent_id(current)
          break unless next_id

          depth += 1
          break if depth > DEFERRED_WORKER_MAX_CHAIN_DEPTH + 1

          current = find_agent(state, next_id)
        end
        { "cycle" => false, "depth" => depth, "ids" => ids }
      end

      # Records the dependent without starting anything. Called inside the SpawnWorker state
      # section, so it owns its own log line and save.
      def queue_deferred_worker(state, command_id:, command_type:, issue:, project:, prompt:, title:,
                                requested_workspace_path:, follow_up_of_agent_id:, predecessor:,
                                chain_depth:, failure_policy:, include_predecessor_result:, rerouted_from_issue_id:)
        now = timestamp
        agent_id = next_worker_id!(state, issue.fetch("id"))
        workspace = resolve_worker_workspace(
          project: project,
          issue: issue,
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: agent_id,
          task_title: worker_display_title(title, issue),
          create: false
        )
        return rejected_result(command_id, command_type, "Worker workspace is invalid.", workspace.fetch("errors")) unless workspace.fetch("errors").empty?

        # A queued worker is provisioned by a later command, so it needs a stable spawn command id
        # even when the caller did not supply one. Without it neither activation nor reservation
        # recovery could recognise this record and both would provision a second worker.
        spawn_command_id = present_string(command_id) || "deferred-#{agent_id}-#{SecureRandom.hex(4)}"
        agent = build_worker_reservation(
          agent_id: agent_id,
          issue: issue,
          project: project,
          workspace: workspace,
          provider: active_harness_provider(state),
          command_id: spawn_command_id,
          prompt: prompt,
          title: title,
          requested_workspace_path: requested_workspace_path,
          follow_up_of_agent_id: follow_up_of_agent_id,
          replace_agent_id: nil,
          after_agent_id: predecessor.fetch("id"),
          now: now,
          harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i
        )
        agent["harness_metadata"] = agent.fetch("harness_metadata").merge(
          "provisioning_state" => "deferred",
          "rerouted_from_issue_id" => rerouted_from_issue_id,
          "queue_command_id" => present_string(command_id),
          "deferred_spawn" => {
            "state" => DEFERRED_STATE_WAITING,
            "after_agent_id" => predecessor.fetch("id"),
            "after_agent_issue_id" => predecessor.fetch("issue_id", nil),
            "after_agent_title" => (predecessor.fetch("harness_metadata", {}) || {}).fetch("title", nil),
            "if_predecessor_fails" => failure_policy,
            "include_predecessor_result" => include_predecessor_result,
            "chain_depth" => chain_depth,
            "queued_at" => now,
            "queued_prompt" => prompt.to_s
          }.compact
        ).compact
        state.fetch("agents") << agent
        issue.fetch("agent_ids") << agent_id unless issue.fetch("agent_ids").include?(agent_id)
        issue["updated_at"] = now
        project["updated_at"] = now
        message = deferred_queue_message(agent)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "info",
          message: message,
          details: {
            "issue_id" => issue.fetch("id"),
            "project_id" => project.fetch("id"),
            "agent_id" => agent_id,
            "routing_action" => "queue_deferred_worker",
            "after_agent_id" => predecessor.fetch("id"),
            "after_agent_status" => predecessor.fetch("status", nil),
            "if_predecessor_fails" => failure_policy,
            "include_predecessor_result" => include_predecessor_result,
            "chain_depth" => chain_depth,
            "title" => agent.fetch("harness_metadata", {}).fetch("title", nil)
          }.compact
        )
        touch_state!(state, now)
        store.save(state)
        accepted_result(command_id, command_type, agent_id, message, deep_copy(agent), log_ids)
      end

      # One-line summary for GetInfo output, so "what is P1-I1-W2" says what it is waiting on.
      def deferred_info_line(deferred)
        after = deferred.fetch("after_agent_id", "an unknown agent")
        case deferred.fetch("state", nil).to_s
        when DEFERRED_STATE_WAITING
          "waiting on: #{after} (#{deferred.fetch("after_agent_status", "unknown")}); if it fails: " \
            "#{deferred.fetch("if_predecessor_fails", DEFERRED_WORKER_DEFAULT_FAILURE_POLICY)}"
        when DEFERRED_STATE_ACTIVATING
          "starting now after: #{after}"
        when DEFERRED_STATE_CANCELLED
          "cancelled before starting: #{deferred.fetch("cancel_reason", "predecessor could not settle")} (#{after})"
        else
          "started after: #{after}"
        end
      end

      def deferred_queue_message(agent)
        deferred = deferred_spawn_metadata(agent)
        after_agent_id = deferred.fetch("after_agent_id", "its predecessor")
        "Queued worker #{agent.fetch("id")} on #{agent.fetch("issue_id")} to start after #{after_agent_id} settles."
      end

      def activated_deferred_spawn_metadata(reserved_agent, now)
        deferred = deferred_spawn_metadata(reserved_agent)
        return nil if deferred.empty?

        deferred.merge("state" => DEFERRED_STATE_ACTIVATED, "started_at" => now)
      end

      # Handover is automatic prompt augmentation rather than something the head has to template:
      # the dependent's prompt is composed when it actually starts, so it carries the predecessor's
      # real final report. Heads can opt out with `include_predecessor_result: false`.
      def deferred_handover_prompt(prompt, predecessor, include_predecessor_result)
        return prompt.to_s unless include_predecessor_result && predecessor.is_a?(Hash)

        metadata = predecessor.fetch("harness_metadata", {}) || {}
        title = present_string(metadata.fetch("title", nil))
        status = present_string(predecessor.fetch("status", nil)) || "unknown"
        report = present_string(metadata.fetch("last_assistant_text", nil))
        body = [
          "Status when it settled: #{status}",
          present_string(predecessor.fetch("issue_id", nil)) ? "Issue: #{predecessor.fetch("issue_id")}" : nil,
          present_string(predecessor.fetch("workspace_branch", nil)) ? "Branch: #{predecessor.fetch("workspace_branch")}" : nil,
          "",
          report ? "Final report:" : "Final report: none was captured.",
          report ? truncate_handover_text(report) : nil,
          "",
          if status == "completed"
            "Use that as input for the work described above. Verify anything you rely on instead of assuming it is still true."
          else
            "That agent did not finish cleanly, so treat its output as partial and re-check its conclusions before relying on them."
          end
        ].compact.join("\n")
        header = "--- Handover from #{predecessor.fetch("id")}#{title ? " (#{title})" : ""} ---"
        [prompt.to_s.rstrip, "#{header}\n#{body}"].join("\n\n")
      end

      def truncate_handover_text(text)
        value = text.to_s.strip
        return value if value.length <= DEFERRED_WORKER_HANDOVER_MAX_CHARS

        "#{value[0, DEFERRED_WORKER_HANDOVER_MAX_CHARS].rstrip}\n… [handover truncated]"
      end

      # The one resolution path for queued dependents. It is called from the worker-settle path,
      # from the reconciliation pass, and after a prune, so no dedicated thread is needed. Bounded
      # iteration lets one call settle a whole chain (a cancelled dependent cancels its own
      # dependents) without ever looping on a record it cannot change.
      def resolve_deferred_workers(trigger:)
        results = []
        (DEFERRED_WORKER_MAX_CHAIN_DEPTH + 1).times do
          decisions = synchronized_state do
            state = normalized_state
            state.fetch("agents").filter_map do |agent|
              next unless waiting_deferred_worker?(agent)

              # Deliberately not filtered by instance ownership. Nothing is in flight for a waiting
              # record, so any instance may resolve it; the atomic waiting -> activating flip below is
              # what keeps activation exactly-once. Skipping another instance's records here would
              # instead let a dependency sit forever when that instance never reconciles again.
              deferred_worker_resolution(state, agent)
            end
          end
          break if decisions.empty?

          applied = decisions.filter_map { |decision| apply_deferred_worker_resolution(decision, trigger: trigger) }
          results.concat(applied)
          break if applied.empty?
        end
        results
      end

      def deferred_worker_resolution(state, agent)
        deferred = deferred_spawn_metadata(agent)
        recorded_id = deferred_worker_after_agent_id(agent)
        base = {
          "agent_id" => agent.fetch("id"),
          "issue_id" => agent.fetch("issue_id", nil),
          "after_agent_id" => recorded_id,
          "if_predecessor_fails" => deferred.fetch("if_predecessor_fails", DEFERRED_WORKER_DEFAULT_FAILURE_POLICY)
        }
        unless recorded_id
          return base.merge(
            "kind" => "cancel",
            "reason" => "predecessor_reference_missing",
            "message" => "Cancelled queued worker #{agent.fetch("id")} because it no longer records which agent it was waiting for."
          )
        end

        predecessor = deferred_effective_predecessor(state, recorded_id)
        unless predecessor
          return base.merge(
            "kind" => "cancel",
            "reason" => "predecessor_missing",
            "message" => "Cancelled queued worker #{agent.fetch("id")} because #{recorded_id} is no longer in Meringue state."
          )
        end

        predecessor_id = predecessor.fetch("id")
        repointed = !Ids.same?(predecessor_id, recorded_id)
        status = predecessor.fetch("status", nil).to_s
        activation = base.merge(
          "kind" => "activate",
          "predecessor" => deep_copy(predecessor),
          "predecessor_status" => status,
          "repointed_from_agent_id" => repointed ? recorded_id : nil
        ).compact
        case status
        when "completed"
          activation
        when "errored"
          if base.fetch("if_predecessor_fails") == "run"
            activation
          else
            base.merge(
              "kind" => "cancel",
              "reason" => "predecessor_errored",
              "message" => "Cancelled queued worker #{agent.fetch("id")} because #{predecessor_id} errored before it could start."
            )
          end
        when "killed"
          base.merge(
            "kind" => "cancel",
            "reason" => "predecessor_killed",
            "message" => "Cancelled queued worker #{agent.fetch("id")} because #{predecessor_id} was killed before it could start."
          )
        else
          return nil unless repointed

          base.merge(
            "kind" => "repoint",
            "predecessor" => deep_copy(predecessor),
            "message" => deferred_repoint_message(agent.fetch("id"), recorded_id, predecessor_id)
          )
        end
      end

      # Follows a replacement chain: when the predecessor was killed by a replacement, the successor
      # is the agent that inherited its work, so the dependent follows it instead of being cancelled.
      def deferred_effective_predecessor(state, after_agent_id)
        current = find_agent(state, after_agent_id)
        seen = []
        while current && current.fetch("status", nil) == "killed" && present_string(current.fetch("replaced_by_agent_id", nil))
          break if seen.include?(current.fetch("id"))

          seen << current.fetch("id")
          successor = find_agent(state, current.fetch("replaced_by_agent_id"))
          break unless successor && successor.fetch("type", nil) == "worker"

          current = successor
        end
        current
      end

      def apply_deferred_worker_resolution(decision, trigger:)
        case decision.fetch("kind")
        when "activate" then activate_deferred_worker(decision, trigger: trigger)
        when "cancel" then cancel_deferred_worker(decision, trigger: trigger)
        when "repoint" then repoint_deferred_worker(decision, trigger: trigger)
        end
      end

      # Two steps on purpose: the state flip (and its log line) is committed first so a crash before
      # the harness spawn leaves a normal interrupted reservation that reconciliation resumes.
      def activate_deferred_worker(decision, trigger:)
        agent_id = decision.fetch("agent_id")
        predecessor = decision.fetch("predecessor")
        activation = synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next nil unless agent && waiting_deferred_worker?(agent)

          deferred = deferred_spawn_metadata(agent)
          metadata = agent.fetch("harness_metadata", {}) || {}
          now = timestamp
          prompt = deferred_handover_prompt(
            deferred.fetch("queued_prompt", metadata.fetch("spawn_prompt", "")),
            predecessor,
            deferred.fetch("include_predecessor_result", true)
          )
          updated = metadata.merge(
            "spawn_prompt" => prompt,
            # Claims the record for this instance while the harness session is being started.
            "provisioning_state" => "allocating_workspace",
            "deferred_spawn" => deferred.merge(
              "state" => DEFERRED_STATE_ACTIVATING,
              "after_agent_id" => predecessor.fetch("id"),
              "predecessor_status" => decision.fetch("predecessor_status", nil),
              "activation_trigger" => trigger,
              "activated_at" => now
            ).compact
          ).merge(instance_ownership_metadata)
          agent["after_agent_id"] = predecessor.fetch("id")
          agent["harness_metadata"] = updated
          agent["updated_at"] = now
          failed_predecessor = decision.fetch("predecessor_status", nil) != "completed"
          repointed_from = present_string(decision.fetch("repointed_from_agent_id", nil)) ||
                           present_string(deferred.fetch("repointed_from_agent_id", nil))
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: failed_predecessor ? "warning" : "info",
            message: deferred_activation_message(agent_id, predecessor, decision, repointed_from: repointed_from),
            details: {
              "agent_id" => agent_id,
              "issue_id" => agent.fetch("issue_id", nil),
              "after_agent_id" => predecessor.fetch("id"),
              "after_agent_status" => decision.fetch("predecessor_status", nil),
              "repointed_from_agent_id" => repointed_from,
              "if_predecessor_fails" => decision.fetch("if_predecessor_fails", nil),
              "include_predecessor_result" => deferred.fetch("include_predecessor_result", true),
              "trigger" => trigger
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          { "prompt" => prompt, "agent" => deep_copy(agent), "log_entry_ids" => log_ids }
        end
        return nil unless activation

        agent = activation.fetch("agent")
        metadata = agent.fetch("harness_metadata", {}) || {}
        result = apply(
          "command_id" => metadata.fetch("spawn_command_id", nil),
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => agent.fetch("issue_id"),
            "title" => metadata.fetch("title", nil),
            "prompt" => activation.fetch("prompt"),
            "workspace_path" => metadata.fetch("requested_workspace_path", nil),
            "follow_up_of_agent_id" => metadata.fetch("follow_up_of_agent_id", nil),
            "after_agent_id" => predecessor.fetch("id"),
            "_activate_deferred" => true,
            "_deferred_agent_id" => agent_id
          }
        )
        result.merge(
          "log_entry_ids" => (activation.fetch("log_entry_ids") + Array(result.fetch("log_entry_ids", []))).uniq,
          "deferred_activation" => {
            "agent_id" => agent_id,
            "after_agent_id" => predecessor.fetch("id"),
            "after_agent_status" => decision.fetch("predecessor_status", nil),
            "trigger" => trigger
          }
        )
      end

      def deferred_activation_message(agent_id, predecessor, decision, repointed_from: nil)
        status = decision.fetch("predecessor_status", nil).to_s
        base = "Starting queued worker #{agent_id} because #{predecessor.fetch("id")} settled (#{status.empty? ? "settled" : status})."
        base = "#{base} It was queued behind #{repointed_from}, which that worker replaced." if present_string(repointed_from)
        return base if status == "completed"

        "#{base} Its predecessor did not complete, and if_predecessor_fails is \"run\"."
      end

      # Cancelling removes the dependent the same way Kill does, because it never started and would
      # otherwise linger in the AgentTree as a worker nobody is waiting for. The warning log is the
      # durable record of why it never ran.
      def cancel_deferred_worker(decision, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, decision.fetch("agent_id"))
          next nil unless agent && waiting_deferred_worker?(agent)

          now = timestamp
          issue_ids = [agent.fetch("issue_id", nil)]
          log_ids = cancel_deferred_worker_in_state!(
            state,
            agent,
            reason: decision.fetch("reason"),
            message: decision.fetch("message"),
            trigger: trigger,
            now: now
          )
          cascade = cancel_deferred_dependents_in_state!(
            state,
            [agent.fetch("id")],
            now: now,
            reason: "predecessor_cancelled",
            trigger: trigger
          )
          log_ids.concat(cascade.fetch("log_entry_ids"))
          removed_agent_ids = ([agent.fetch("id")] + cascade.fetch("agent_ids")).uniq
          issue_ids.concat(cascade.fetch("issue_ids"))
          remove_issue_bundles_and_agents!(
            state,
            issue_ids: [],
            extra_agent_ids: removed_agent_ids,
            reason: "deferred_worker_cancelled",
            now: now,
            remove_empty_projects: false
          )
          issue_ids.compact.uniq.each do |issue_id|
            issue = find_issue(state, issue_id)
            next unless issue

            update_issue_status_from_workers!(state, issue, now)
            project = find_project(state, issue.fetch("project_id", nil))
            update_project_status_from_issues!(state, project, now) if project
          end
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "ResolveDeferredWorker",
            decision.fetch("agent_id"),
            decision.fetch("message"),
            {
              "resolution" => "cancelled",
              "reason" => decision.fetch("reason"),
              "agent_id" => decision.fetch("agent_id"),
              "after_agent_id" => decision.fetch("after_agent_id", nil),
              "cancelled_agent_ids" => removed_agent_ids,
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end

      def cancel_deferred_worker_in_state!(state, agent, reason:, message:, trigger:, now:)
        deferred = deferred_spawn_metadata(agent)
        mark_agent_killed!(agent, now)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          "provisioning_state" => "cancelled",
          "deferred_spawn" => deferred.merge(
            "state" => DEFERRED_STATE_CANCELLED,
            "cancel_reason" => reason,
            "cancelled_at" => now,
            "cancel_trigger" => trigger
          ).compact
        )
        append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "warning",
          message: message,
          details: {
            "agent_id" => agent.fetch("id"),
            "issue_id" => agent.fetch("issue_id", nil),
            "after_agent_id" => deferred_worker_after_agent_id(agent),
            "reason" => reason,
            "trigger" => trigger,
            "resolution" => "cancelled"
          }.compact
        )
      end

      # Transitively cancels dependents of records that are going away, bounded by the same chain
      # limit that bounds queueing.
      def cancel_deferred_dependents_in_state!(state, predecessor_ids, now:, reason:, trigger:)
        cancelled_ids = []
        issue_ids = []
        log_ids = []
        frontier = Array(predecessor_ids).compact.uniq
        (DEFERRED_WORKER_MAX_CHAIN_DEPTH + 1).times do |level|
          dependents = waiting_deferred_dependents(state, frontier)
          break if dependents.empty?

          # Past the first level the predecessor was itself a queued worker this pass cancelled, so
          # the reason reported to the user follows the chain instead of repeating the original one.
          level_reason = level.zero? ? reason : "predecessor_cancelled"
          frontier = dependents.map { |dependent| dependent.fetch("id") }
          dependents.each do |dependent|
            predecessor_id = deferred_worker_after_agent_id(dependent)
            log_ids.concat(cancel_deferred_worker_in_state!(
              state,
              dependent,
              reason: level_reason,
              message: deferred_cancellation_message(dependent.fetch("id"), predecessor_id, level_reason),
              trigger: trigger,
              now: now
            ))
            cancelled_ids << dependent.fetch("id")
            issue_ids << dependent.fetch("issue_id", nil)
          end
        end
        { "agent_ids" => cancelled_ids.uniq, "issue_ids" => issue_ids.compact.uniq, "log_entry_ids" => log_ids }
      end

      def deferred_cancellation_message(agent_id, predecessor_id, reason)
        case reason
        when "predecessor_killed"
          "Cancelled queued worker #{agent_id} because #{predecessor_id} was killed before it could start."
        when "predecessor_cancelled"
          "Cancelled queued worker #{agent_id} because #{predecessor_id} was cancelled before it could start."
        when "predecessor_errored"
          "Cancelled queued worker #{agent_id} because #{predecessor_id} errored before it could start."
        else
          "Cancelled queued worker #{agent_id} because #{predecessor_id} can no longer settle."
        end
      end

      # Moves every worker queued behind `from_agent_id` onto the agent that replaced it. Used by the
      # replacement path (atomically, in the same command) and by the resolver as a late fallback.
      def repoint_deferred_dependents_in_state!(state, from_agent_id:, to_agent:, now:, trigger:)
        dependents = waiting_deferred_dependents(state, [from_agent_id])
        log_ids = []
        dependents.each do |dependent|
          log_ids.concat(repoint_deferred_worker_in_state!(
            state,
            dependent,
            predecessor: to_agent,
            now: now,
            trigger: trigger
          ))
        end
        { "agent_ids" => dependents.map { |dependent| dependent.fetch("id") }, "log_entry_ids" => log_ids }
      end

      def repoint_deferred_worker_in_state!(state, agent, predecessor:, now:, trigger:)
        deferred = deferred_spawn_metadata(agent)
        previous_id = deferred_worker_after_agent_id(agent)
        agent["after_agent_id"] = predecessor.fetch("id")
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          "deferred_spawn" => deferred.merge(
            "after_agent_id" => predecessor.fetch("id"),
            "after_agent_issue_id" => predecessor.fetch("issue_id", nil),
            "after_agent_title" => (predecessor.fetch("harness_metadata", {}) || {}).fetch("title", nil),
            "repointed_from_agent_id" => previous_id,
            "repointed_at" => now
          ).compact
        )
        agent["updated_at"] = now
        append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "warning",
          message: deferred_repoint_message(agent.fetch("id"), previous_id, predecessor.fetch("id")),
          details: {
            "agent_id" => agent.fetch("id"),
            "issue_id" => agent.fetch("issue_id", nil),
            "after_agent_id" => predecessor.fetch("id"),
            "repointed_from_agent_id" => previous_id,
            "resolution" => "repointed",
            "trigger" => trigger
          }.compact
        )
      end

      def deferred_repoint_message(agent_id, previous_id, predecessor_id)
        "Queued worker #{agent_id} now waits for #{predecessor_id} because #{previous_id} was replaced."
      end

      def repoint_deferred_worker(decision, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, decision.fetch("agent_id"))
          next nil unless agent && waiting_deferred_worker?(agent)

          predecessor = decision.fetch("predecessor")
          now = timestamp
          previous_id = deferred_worker_after_agent_id(agent)
          log_ids = repoint_deferred_worker_in_state!(state, agent, predecessor: predecessor, now: now, trigger: trigger)
          touch_state!(state, now)
          store.save(state)
          accepted_result(
            nil,
            "ResolveDeferredWorker",
            agent.fetch("id"),
            deferred_repoint_message(agent.fetch("id"), previous_id, predecessor.fetch("id")),
            {
              "resolution" => "repointed",
              "agent_id" => agent.fetch("id"),
              "after_agent_id" => predecessor.fetch("id"),
              "repointed_from_agent_id" => previous_id,
              "trigger" => trigger
            }.compact,
            log_ids
          )
        end
      end

      def build_worker_reservation(agent_id:, issue:, project:, workspace:, provider:, command_id:, prompt:, title:,
                                   requested_workspace_path:, follow_up_of_agent_id:, replace_agent_id:, now:, harness_generation:,
                                   after_agent_id: nil)
        plan = workspace.fetch("plan", nil) || workspace
        {
          "id" => agent_id,
          "type" => "worker",
          "status" => "queued",
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "after_agent_id" => present_string(after_agent_id),
          "workspace_path" => plan.fetch("workspace_path", workspace.fetch("workspace_path", nil)),
          "workspace_strategy" => plan.fetch("strategy", workspace.fetch("workspace_strategy", nil)),
          "workspace_branch" => plan.fetch("workspace_branch", workspace.fetch("workspace_branch", nil)),
          "harness" => provider,
          "pid" => nil,
          "harness_session_id" => nil,
          "harness_session_file" => nil,
          "harness_metadata" => {
            "title" => worker_display_title(title, issue),
            "spawn_command_id" => command_id,
            "spawn_prompt" => prompt.to_s,
            "requested_workspace_path" => present_string(requested_workspace_path),
            "follow_up_of_agent_id" => present_string(follow_up_of_agent_id),
            "replace_agent_id" => present_string(replace_agent_id),
            "provisioning_state" => "allocating_workspace",
            "workspace_plan" => plan,
            "harness_generation" => harness_generation,
            **instance_ownership_metadata,
            "is_streaming" => false
          }.compact,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def workspace_from_reserved_agent(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", {}) || {}
        {
          "workspace_path" => agent.fetch("workspace_path", plan.fetch("workspace_path", nil)),
          "workspace_strategy" => agent.fetch("workspace_strategy", plan.fetch("strategy", nil)),
          "workspace_branch" => agent.fetch("workspace_branch", plan.fetch("workspace_branch", nil)),
          "plan" => plan,
          "created" => plan.fetch("created", false),
          "errors" => []
        }
      end

      def checkpoint_worker_workspace!(reservation, workspace)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, reservation.fetch("agent_id"))
          raise "Worker reservation #{reservation.fetch("agent_id")} disappeared during workspace provisioning." unless agent

          now = timestamp
          agent["workspace_path"] = workspace.fetch("workspace_path")
          agent["workspace_strategy"] = workspace.fetch("workspace_strategy")
          agent["workspace_branch"] = workspace.fetch("workspace_branch", nil)
          agent["status"] = "queued"
          agent["updated_at"] = now
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "cwd" => workspace.fetch("workspace_path"),
            "workspace_plan" => workspace.fetch("plan", nil),
            "provisioning_state" => "starting_harness",
            "workspace_provisioned_at" => now
          ).compact
          touch_state!(state, now)
          store.save(state)
        end
      end

      def fail_worker_reservation(reservation, command_id:, command_type:, message:, errors:, workspace:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, reservation.fetch("agent_id"))
          if agent
            now = timestamp
            agent["status"] = "errored"
            agent["updated_at"] = now
            agent["workspace_path"] = workspace.fetch("workspace_path", agent.fetch("workspace_path", nil))
            agent["workspace_strategy"] = workspace.fetch("workspace_strategy", agent.fetch("workspace_strategy", nil))
            agent["workspace_branch"] = workspace.fetch("workspace_branch", agent.fetch("workspace_branch", nil))
            agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
              "provisioning_state" => "failed",
              "provisioning_failed_at" => now,
              "provisioning_errors" => Array(errors),
              "workspace_plan" => workspace.fetch("plan", nil)
            ).compact
            issue = find_issue(state, agent.fetch("issue_id", nil))
            project = issue && find_project(state, issue.fetch("project_id", nil))
            update_issue_status_from_workers!(state, issue, now) if issue
            update_project_status_from_issues!(state, project, now) if project
            append_log(
              state,
              source_type: "kernel",
              source_id: agent.fetch("id"),
              level: "error",
              message: message,
              details: {
                "issue_id" => agent.fetch("issue_id", nil),
                "errors" => Array(errors),
                "workspace" => workspace
              }
            )
            touch_state!(state, now)
            store.save(state)
          end
          failed_result(command_id, command_type, message, Array(errors))
        end
      end

      def build_head_agent(head_id:, now:, provider:, runner:, harness_generation: 0, user_message: nil, question_id: nil,
                           selected_target: nil, snapshot_issue_ids: [], snapshot_project_ids: [], snapshot_counters: {})
        {
          "id" => head_id,
          "type" => "head",
          "status" => "working",
          "project_id" => nil,
          "issue_id" => nil,
          "workspace_path" => nil,
          "workspace_strategy" => nil,
          "workspace_branch" => nil,
          "harness" => provider,
          "pid" => nil,
          "harness_session_id" => nil,
          "harness_session_file" => nil,
          "harness_metadata" => {
            "runner" => runner.class.name,
            "cwd" => cwd,
            "harness_generation" => harness_generation,
            "head_session_state" => HEAD_SESSION_STATE_PENDING,
            **instance_ownership_metadata,
            # What this head can actually see. A batch command that targets an issue outside this
            # set and outside the head's own batch is a mispredicted id, not a deliberate target,
            # and the counters let the kernel recompute exactly which ids the head would predict.
            "snapshot_issue_ids" => Array(snapshot_issue_ids),
            "snapshot_project_ids" => Array(snapshot_project_ids),
            "snapshot_counters" => (snapshot_counters.is_a?(Hash) ? snapshot_counters : {}),
            "head_request" => {
              "user_message" => user_message,
              "question_id" => question_id,
              "selected_target" => selected_target
            }.compact
          },
          "created_at" => now,
          "updated_at" => now
        }
      end

      def build_worker_agent(agent_id:, issue:, project:, workspace:, session_ref:, now:, title: nil, harness_generation: 0,
                             follow_up_of_agent_id: nil, replaces_agent_id: nil, after_agent_id: nil)
        session_metadata = session_ref.fetch("metadata", {}) || {}
        display_title = worker_display_title(title, issue)
        {
          "id" => agent_id,
          "type" => "worker",
          "status" => "working",
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "follow_up_of_agent_id" => follow_up_of_agent_id,
          "replaces_agent_id" => replaces_agent_id,
          "after_agent_id" => present_string(after_agent_id),
          "workspace_path" => workspace.fetch("workspace_path"),
          "workspace_strategy" => workspace.fetch("workspace_strategy"),
          "workspace_branch" => workspace.fetch("workspace_branch"),
          "harness" => session_ref.fetch("harness", nil),
          "pid" => session_ref.fetch("pid", nil),
          "harness_session_id" => session_ref.fetch("session_id", nil),
          "harness_session_file" => session_ref.fetch("session_file", nil),
          "session_settings" => session_ref.fetch("session_settings", nil).is_a?(Hash) ? deep_copy(session_ref.fetch("session_settings")) : nil,
          "harness_metadata" => session_metadata.merge(
            "title" => display_title,
            "cwd" => session_ref.fetch("cwd", workspace.fetch("workspace_path")),
            "is_streaming" => session_ref.fetch("is_streaming", false),
            "last_event_at" => session_ref.fetch("last_event_at", nil),
            "harness_generation" => harness_generation,
            "workspace_note" => workspace.fetch("note", nil),
            "workspace_plan" => workspace.fetch("plan", nil),
            "delivery_branch" => workspace.fetch("workspace_branch", nil),
            "routing_action" => spawn_routing_action(follow_up_of_agent_id, replaces_agent_id)
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
          "session_settings" => agent.fetch("session_settings", nil),
          "metadata" => metadata
        }
      end

      def apply_session_ref_to_agent!(agent, session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["session_settings"] = deep_copy(session_ref.fetch("session_settings")) if session_ref.fetch("session_settings", nil).is_a?(Hash)
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
        return unless agent.fetch("type", nil) == "head"

        # The caller stops attached harness sessions; only mark the head session terminal here
        # so a killed head can never look like a live or resumable session.
        metadata = agent.fetch("harness_metadata", {}) || {}
        agent["harness_metadata"] = metadata.merge(
          "head_session_state" => HEAD_SESSION_STATE_RELEASED,
          "head_session_released_at" => present_string(metadata.fetch("head_session_released_at", nil)) || now,
          "head_session_release_reason" => present_string(metadata.fetch("head_session_release_reason", nil)) || "killed",
          "is_streaming" => false
        ).compact
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

      def prompt_routing_action(mode)
        {
          "normal" => "resume_session",
          "steer" => "steer_active_session",
          "follow_up" => "queue_follow_up"
        }.fetch(mode.to_s)
      end

      # `requested_mode` is only present when the harness had to deliver the prompt in another mode;
      # the coercion is stated in the same user-visible line so a queued delivery is never silent.
      def prompt_log_message(agent, mode, requested_mode: nil, note: nil)
        base = case mode.to_s
               when "steer"
                 "Steered active worker #{agent.fetch("id")} on #{agent.fetch("issue_id")} with the user's correction."
               when "follow_up"
                 "Queued a follow-up for worker #{agent.fetch("id")} on #{agent.fetch("issue_id")}."
               else
                 "Continued worker #{agent.fetch("id")} on #{agent.fetch("issue_id")} using its existing session."
               end
        return base unless present_string(requested_mode) && requested_mode.to_s != mode.to_s

        explanation = present_string(note) ||
                      "The session could not take a #{requested_mode} prompt right now."
        "#{base} Requested #{requested_mode}, delivered #{mode}: #{explanation}"
      end

      def replaceable_worker?(agent)
        agent && agent.fetch("status", nil) != "killed" && blank?(agent.fetch("replaced_by_agent_id", nil))
      end

      def spawn_routing_action(follow_up_of_agent_id, replaces_agent_id)
        return "replace_worker" if present_string(replaces_agent_id)
        return "spawn_follow_up_worker" if present_string(follow_up_of_agent_id)

        "spawn_worker"
      end

      def spawn_worker_log_message(agent, issue)
        deferred = deferred_spawn_metadata(agent)
        base = if deferred.fetch("state", nil) == DEFERRED_STATE_ACTIVATED
                 "Started queued worker #{agent.fetch("id")} on #{issue.fetch("id")} because " \
                   "#{deferred.fetch("after_agent_id", "its predecessor")} settled (#{deferred.fetch("predecessor_status", "completed")})."
               elsif present_string(agent.fetch("replaces_agent_id", nil))
                 "Replaced worker #{agent.fetch("replaces_agent_id")} with #{agent.fetch("id")} on #{issue.fetch("id")}."
               elsif present_string(agent.fetch("follow_up_of_agent_id", nil))
                 "Spawned follow-up worker #{agent.fetch("id")} after #{agent.fetch("follow_up_of_agent_id")} on #{issue.fetch("id")}."
               else
                 "Spawned worker #{agent.fetch("id")} for #{issue.fetch("id")}."
               end
        rerouted_from = present_string((agent.fetch("harness_metadata", {}) || {}).fetch("rerouted_from_issue_id", nil))
        return base unless rerouted_from

        "#{base} Rerouted from predicted issue #{rerouted_from}."
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

      def append_head_summary_log(state, head_id, head_result)
        return [] unless Array(head_result.fetch("commands", [])).empty?
        return [] unless Array(head_result.fetch("questions", [])).empty?

        summary = head_result.fetch("summary", "").to_s.strip
        return [] if summary.empty?

        head = find_agent(state, head_id.to_s)
        request = (head&.fetch("harness_metadata", nil) || {}).fetch("head_request", {}) || {}
        selected_target = request.fetch("selected_target", nil)
        append_log(
          state,
          source_type: "head",
          source_id: head_id.to_s,
          level: "info",
          message: summary,
          details: { "kind" => "head_summary", **selected_target_log_details(selected_target) }
        )
      end

      # Head batches that accept nothing used to leave only per-command error lines, so a correctly
      # captured user message could disappear from the conversation. This restates the message the
      # kernel stored for that head and says what to do with it, so nothing is silently dropped.
      def append_unrouted_user_message_log(state, head_id, command_results)
        user_message = head_request_user_message(state, head_id)
        failures = Array(command_results).reject { |result| result.fetch("status", nil) == "accepted" }
        quoted = user_message ? ": #{single_line_excerpt(user_message).inspect}" : "."
        reason = if failures.empty?
                   "Head #{head_id} routed nothing for this message, so it still needs handling"
                 else
                   "No command from head #{head_id} was applied, so this message still needs handling"
                 end
        message = "#{reason}#{quoted} Resend it, or route it yourself with /prompt or /worker spawn."
        append_log(
          state,
          source_type: "kernel",
          source_id: head_id,
          level: failures.empty? ? "warning" : "error",
          message: message,
          details: {
            "kind" => "unrouted_user_message",
            "head_id" => head_id,
            "user_message" => user_message,
            "accepted_command_count" => 0,
            "command_count" => Array(command_results).length,
            "command_results" => failures.map do |result|
              {
                "command_type" => result.fetch("command_type", nil),
                "status" => result.fetch("status", nil),
                "message" => result.fetch("message", nil)
              }.compact
            end
          }.compact
        )
      end

      def single_line_excerpt(text, limit: 160)
        collapsed = text.to_s.strip.gsub(/\s+/, " ")
        return collapsed if collapsed.length <= limit

        "#{collapsed[0, limit - 1]}…"
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
            message: "Question #{question.fetch("id")}: #{question.fetch("question")}",
            details: {
              "head_id" => head_id.to_s,
              "project_id" => question.fetch("project_id"),
              "issue_id" => question.fetch("issue_id")
            }
          ))
          question.fetch("id")
        end
      end

      def initialize_head_command_journal(state:, head_id:, head_result:, existing:, recovering:)
        existing_by_id = Array(existing).select { |entry| entry.is_a?(Hash) }.to_h { |entry| [entry["command_id"].to_s, entry] }
        head_result.fetch("commands").each_with_index.map do |proposed_command, index|
          command = command_with_default_id(proposed_command, head_id: head_id, index: index)
          command_id = value_at(command, "command_id", "id").to_s
          prior = existing_by_id[command_id]
          next prior.merge("index" => index) if prior

          inferred = recovering && infer_legacy_head_command_result(state, head_id, command)
          {
            "command_id" => command_id,
            "index" => index,
            "command_type" => canonical_command_type(value_at(command, "type", "command_type")),
            "status" => inferred ? inferred.fetch("status") : "pending",
            "target_id" => inferred && inferred.fetch("target_id", nil),
            "message" => inferred && inferred.fetch("message", nil),
            "result" => inferred && inferred.fetch("result", nil),
            "errors" => inferred ? inferred.fetch("errors", []) : [],
            "log_entry_ids" => inferred ? inferred.fetch("log_entry_ids", []) : [],
            "recovered" => !!inferred,
            "completed_at" => inferred ? timestamp : nil
          }.compact
        end
      end

      def infer_legacy_head_command_result(state, head_id, command)
        command_id = value_at(command, "command_id", "id")
        command_type = canonical_command_type(value_at(command, "type", "command_type"))
        payload = value_at(command, "payload") || {}
        target = case command_type
                 when "AddProject"
                   path = value_at(payload, "path", "Path", "root_path", "RootPath")
                   expanded = present_string(path) && File.expand_path(path.to_s)
                   expanded && state.fetch("projects").find { |project| File.expand_path(project.fetch("root_path")) == expanded }
                 when "CreateIssue"
                   project_id = value_at(payload, "project_id", "ProjectID", "projectId").to_s
                   title = value_at(payload, "title", "Title").to_s.strip
                   state.fetch("issues").find do |issue|
                     issue.fetch("originating_head_id", nil) == head_id ||
                       (issue.fetch("project_id", nil) == project_id && issue.fetch("title", "").to_s.strip == title)
                   end
                 when "SpawnWorker"
                   issue_id = value_at(payload, "issue_id", "IssueID", "issueId").to_s
                   state.fetch("agents").find do |agent|
                     next false unless agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id

                     metadata = agent.fetch("harness_metadata", {}) || {}
                     metadata.fetch("spawn_command_id", nil).to_s == command_id.to_s || blank?(metadata.fetch("spawn_command_id", nil))
                   end
                 end
        return nil unless target

        accepted_result(command_id, command_type, target.fetch("id", nil), "Recovered previously applied #{command_type} command.", deep_copy(target), [])
      end

      def ensure_head_questions!(state, head_id, questions, log_ids)
        Array(questions).map do |question_payload|
          existing = find_duplicate_head_question(state, head_id, question_payload.fetch("question"))
          next existing.fetch("id") if existing

          create_head_questions!(state, head_id, [question_payload], log_ids).first
        end.compact.uniq
      end

      def find_head_question_by_text(state, head_id, question_text)
        normalized = normalized_question_text(question_text)
        return nil if normalized.empty?

        state.fetch("questions").find do |question|
          question.fetch("head_id", nil).to_s == head_id.to_s &&
            normalized_question_text(question.fetch("question", nil)) == normalized
        end
      end

      # Heads sometimes restate one clarification twice: once in the HeadResult `questions`
      # array and once as an `AskQuestion` command, often with slightly reworded text. The
      # kernel records a clarification once per head, so a near-identical restatement resolves
      # to the question that is already stored instead of creating a second record and log line.
      def find_duplicate_head_question(state, head_id, question_text)
        normalized = normalized_question_text(question_text)
        return nil if normalized.empty?

        exact = find_head_question_by_text(state, head_id, question_text)
        return exact if exact

        head_questions = state.fetch("questions").select { |question| question.fetch("head_id", nil).to_s == head_id.to_s }
        scored = head_questions.map do |question|
          [question_text_similarity(normalized_question_text(question.fetch("question", nil)), normalized), question]
        end
        score, question = scored.max_by { |similarity, _question| similarity }
        return nil unless question && score.to_f >= DUPLICATE_QUESTION_SIMILARITY_THRESHOLD

        question
      end

      def normalized_question_text(question_text)
        question_text.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      def question_text_similarity(left, right)
        left_words = question_text_words(left)
        right_words = question_text_words(right)
        return 0.0 if left_words.empty? || right_words.empty?

        union = (left_words | right_words).length
        return 0.0 if union.zero?

        (left_words & right_words).length.to_f / union
      end

      def question_text_words(text)
        text.to_s.downcase.scan(/[a-z0-9]+/).uniq
      end

      def current_head_journal_entry(head_id, index)
        synchronized_state do
          head = find_agent(normalized_state, head_id)
          metadata = head && (head.fetch("harness_metadata", {}) || {})
          entry = metadata && Array(metadata.fetch("head_result_command_journal", []))[index]
          entry && deep_copy(entry)
        end
      end

      def current_head_command_journal(head_id)
        synchronized_state do
          head = find_agent(normalized_state, head_id)
          metadata = head && (head.fetch("harness_metadata", {}) || {})
          journal = metadata ? Array(metadata.fetch("head_result_command_journal", [])) : []
          deep_copy(journal)
        end
      end

      # A head returns its whole batch at once, so a `SpawnWorker` that targets an issue the same
      # batch creates cannot know the real issue id yet. Heads used to predict that id, which
      # silently attached the worker to whatever issue happened to own the predicted id: when two
      # head batches interleaved, the second head's worker landed under the first head's issue.
      #
      # The kernel now resolves the pointer itself. A head may reference the issue-creating command
      # in the same batch (`issue_from_command`, or an `issue_id` like "@H1-C1"/"@index:0"), and a
      # still-predicted id is verified against the issues the head could actually see plus the
      # issues its own batch created. An unverifiable prediction is remapped to this batch's issue
      # when that is unambiguous, and rejected otherwise, so work never routes onto another head's
      # issue. Pre-existing issue ids keep working unchanged.
      def resolve_head_batch_issue_reference(command:, head_id:, index:, commands: [])
        return { "command" => command } unless command.is_a?(Hash)

        command_type = canonical_command_type(value_at(command, "type", "command_type"))
        payload = value_at(command, "payload")
        return { "command" => command } unless payload.is_a?(Hash)

        plan = head_batch_plan(head_id: head_id, commands: commands, index: index)
        if BATCH_PROJECT_REFERENCE_COMMANDS.include?(command_type)
          project_resolution = resolve_batch_project_target(command: command, payload: payload, command_type: command_type, plan: plan)
          return project_resolution if project_resolution
        end
        if command_type == "SpawnWorker"
          # "start this worker after the worker my own batch spawns" cannot predict the worker id, so
          # it points at the SpawnWorker command instead. Resolve that before applying the command.
          after_resolution = resolve_batch_after_agent_target(command: command, payload: payload, plan: plan, index: index)
          if after_resolution
            return after_resolution if after_resolution.fetch("rejection", nil)

            command = after_resolution.fetch("command")
            payload = value_at(command, "payload")
          end

          # Same problem for the lineage fields: "this worker follows up on the worker my own batch
          # spawns" cannot predict the worker id either, so it points at the SpawnWorker command.
          lineage_resolution = resolve_batch_lineage_agent_target(command: command, payload: payload, plan: plan, index: index)
          if lineage_resolution
            return lineage_resolution if lineage_resolution.fetch("rejection", nil)

            command = lineage_resolution.fetch("command")
            payload = value_at(command, "payload")
          end
        end
        return { "command" => command } unless BATCH_ISSUE_REFERENCE_COMMANDS.include?(command_type)

        reference = head_batch_issue_reference(payload)
        if reference
          return resolve_symbolic_batch_issue_reference(
            command: command,
            payload: payload,
            command_type: command_type,
            reference: reference,
            created: plan.fetch("created"),
            index: index
          )
        end

        return { "command" => command } unless BATCH_ISSUE_GUARDED_COMMANDS.include?(command_type)

        # The batch plan, journal, and head snapshot all hold canonical ids, so compare a
        # head-predicted id in canonical form. Nothing else about the command is rewritten here.
        requested = Ids.canonical(present_string(value_at(payload, "issue_id", "IssueID", "issueId")))
        return { "command" => command } if requested.nil?

        resolve_batch_issue_target(
          command: command,
          payload: payload,
          command_type: command_type,
          requested: requested,
          head_id: head_id,
          plan: plan
        )
      end

      # Resolution order for a literal `issue_id` inside a head batch. Every step is a fact about
      # the batch or about what the head could see, never a guess about what it meant:
      #
      #   1. the id is one this head would have predicted for an issue its own batch created
      #      (recomputed from the head's snapshot counters) -> bind to the real created issue,
      #   2. the id is literally one of this batch's created issues -> keep it,
      #   3. the batch left an issue it created with no worker of its own while this command points
      #      somewhere else -> the batch is internally inconsistent, so bind to that orphan issue
      #      (single, same project) or reject rather than silently pile work onto another issue,
      #   4. the id was visible in the head's spawn snapshot -> deliberate pre-existing target,
      #   5. anything else -> reject loudly.
      def resolve_batch_issue_target(command:, payload:, command_type:, requested:, head_id:, plan:)
        aliases = plan.fetch("issue_aliases")
        if plan.fetch("ambiguous_issue_aliases").include?(requested)
          return {
            "rejection" => {
              "message" => "#{command_type} targets predicted issue #{requested}, which matches more than one issue created by this head result. " \
                           "Use issue_from_command to name the CreateIssue command it belongs to.",
              "errors" => ["ambiguous_batch_issue_prediction"]
            }
          }
        end

        if (aliased = aliases[requested])
          return { "command" => command } if aliased == requested

          return batch_issue_remap(command, payload, command_type, requested, aliased, "predicted_issue_id_shifted")
        end

        created_ids = plan.fetch("created_issue_ids")
        orphans = plan.fetch("orphan_created_issue_ids")
        return { "command" => command } if created_ids.include?(requested)

        # Only worker routing is subject to the batch-consistency rule. Modifying some other issue
        # in the same batch is a normal operation and never claims a created issue.
        if command_type == "SpawnWorker" && !orphans.empty? && !batch_target_declared_deliberate?(payload)
          candidates = orphans.select { |issue_id| same_project_issue_ids?(issue_id, requested) }
          if candidates.length == 1
            return batch_issue_remap(command, payload, command_type, requested, candidates.first, "batch_created_issue_left_without_worker")
          end

          return {
            "rejection" => {
              "message" => "SpawnWorker targets issue #{requested}, but this head result created #{orphans.join(", ")} without giving #{orphans.length == 1 ? "it" : "them"} a worker. " \
                           "Use issue_from_command to bind each worker to the issue it belongs to, or mark a deliberate existing-issue worker with follow_up_of_agent_id or existing_issue.",
              "errors" => ["ambiguous_batch_issue_target"]
            }
          }
        end

        return { "command" => command } if head_could_see_issue?(head_id: head_id, issue_id: requested)

        {
          "rejection" => {
            "message" => "#{command_type} targets issue #{requested}, which this head result did not create and the head could not have seen. " \
                         "Reference the issue-creating command with issue_from_command instead of predicting an issue id.",
            "errors" => ["issue_id_not_created_by_this_head_result"]
          }
        }
      end

      def batch_issue_remap(command, payload, command_type, requested, issue_id, reason)
        {
          "command" => command_with_issue_id(command, payload, issue_id, rerouted_from: requested),
          "remap" => {
            "command_type" => command_type,
            "requested_issue_id" => requested,
            "issue_id" => issue_id,
            "reason" => reason
          }
        }
      end

      # A head states that a worker belongs to an already existing issue's session lineage by
      # setting follow_up_of_agent_id, replace_agent_id, or after_agent_id. That is an explicit
      # target, so the batch-consistency check leaves it alone. Intra-batch references are already
      # resolved to real agent ids before this runs, so "@research" never reaches it.
      def batch_target_declared_deliberate?(payload)
        present_string(value_at(payload, "follow_up_of_agent_id", "followUpOfAgentID", "followUpOfAgentId")) ||
          present_string(value_at(payload, "replace_agent_id", "replaceAgentID", "replaceAgentId")) ||
          present_string(value_at(payload, *DEFERRED_WORKER_AFTER_KEYS)) ||
          !!value_at(payload, "existing_issue", "ExistingIssue", "existingIssue")
      end

      def same_project_issue_ids?(left, right)
        project_id_from_issue_id(left) == project_id_from_issue_id(right)
      end

      def project_id_from_issue_id(issue_id)
        issue_id.to_s[/\A(P\d+)-I\d+/, 1]
      end

      def resolve_batch_project_target(command:, payload:, command_type:, plan:)
        reference = head_batch_project_reference(payload)
        added = plan.fetch("added_projects")
        if reference
          described = describe_batch_issue_reference(reference)
          entry = find_batch_issue_reference_entry(reference, added)
          unless entry && entry.fetch("project_id", nil)
            return {
              "rejection" => {
                "message" => "#{command_type} references #{described}, but this head result has no applied AddProject command there.",
                "errors" => ["batch_project_reference_unresolved"]
              }
            }
          end

          return { "command" => command_with_project_id(command, payload, entry.fetch("project_id")) }
        end

        requested = Ids.canonical(present_string(value_at(payload, "project_id", "ProjectID", "projectId")))
        return nil unless requested

        aliased = plan.fetch("project_aliases")[requested]
        return nil if aliased.nil? || aliased == requested

        {
          "command" => command_with_project_id(command, payload, aliased, rerouted_from: requested),
          "remap" => {
            "command_type" => command_type,
            "requested_project_id" => requested,
            "project_id" => aliased,
            "reason" => "predicted_project_id_shifted"
          }
        }
      end

      # Everything the kernel knows about the batch being applied: what it has created so far, which
      # ids the head would have predicted for those creations, and which created issues the batch
      # never gives a worker of their own.
      def head_batch_plan(head_id:, commands:, index:)
        journal = current_head_command_journal(head_id)
        snapshot = head_batch_snapshot(head_id)
        created = head_batch_created_issues(journal)
        added_projects = head_batch_added_projects(journal)
        aliases = head_batch_predicted_aliases(
          commands: commands,
          journal: journal,
          snapshot: snapshot,
          index: index
        )
        created_issue_ids = created.filter_map { |entry| entry.fetch("issue_id", nil) }
        {
          "created" => created,
          "created_issue_ids" => created_issue_ids,
          "added_projects" => added_projects,
          "spawned_workers" => head_batch_spawned_workers(journal),
          "issue_aliases" => aliases.fetch("issues"),
          "ambiguous_issue_aliases" => aliases.fetch("ambiguous_issues"),
          "project_aliases" => aliases.fetch("projects"),
          "orphan_created_issue_ids" => orphan_created_issue_ids(
            commands: commands,
            created: created,
            aliases: aliases.fetch("issues")
          )
        }
      end

      def head_batch_snapshot(head_id)
        synchronized_state do
          head = find_agent(normalized_state, head_id)
          metadata = head ? (head.fetch("harness_metadata", {}) || {}) : {}
          issue_ids = metadata.fetch("snapshot_issue_ids", nil)
          counters = metadata.fetch("snapshot_counters", nil)
          {
            "issue_ids" => issue_ids.is_a?(Array) ? issue_ids.map(&:to_s) : nil,
            "project_ids" => Array(metadata.fetch("snapshot_project_ids", [])).map(&:to_s),
            "counters" => counters.is_a?(Hash) ? counters : {}
          }
        end
      end

      # Recomputes the ids the head would have predicted for its own creations, following the same
      # rule the head contract documents (`counters` or the max existing number, plus one per
      # creation in the batch). Those predictions become aliases for the ids the kernel actually
      # minted, so a batch stays correctly bound even when another head consumed the ids first.
      def head_batch_predicted_aliases(commands:, journal:, snapshot:, index:)
        issues = {}
        ambiguous_issues = []
        projects = {}
        return { "issues" => issues, "ambiguous_issues" => ambiguous_issues, "projects" => projects } unless snapshot.fetch("issue_ids")

        journal_by_index = {}
        Array(journal).each_with_index do |entry, position|
          next unless entry.is_a?(Hash)

          journal_by_index[entry.fetch("index", position).to_i] = entry
        end

        snapshot_issue_ids = snapshot.fetch("issue_ids")
        snapshot_counters = snapshot.fetch("counters")
        issue_counters = snapshot_counters.fetch("issues_by_project", {}) || {}
        project_counter = snapshot_counters.fetch("projects", nil)
        project_counter = snapshot.fetch("project_ids").length if project_counter.nil?
        snapshot_max_issue = snapshot_max_issue_numbers(snapshot_issue_ids)
        added_projects = 0
        created_per_project = Hash.new(0)

        Array(commands).each_with_index do |proposed, position|
          break if position >= index

          entry = journal_by_index[position]
          next unless entry && entry.fetch("status", nil) == "accepted"

          target_id = present_string(entry.fetch("target_id", nil))
          next unless target_id

          command_type = canonical_command_type(value_at(proposed, "type", "command_type"))
          payload = value_at(proposed, "payload")
          payload = {} unless payload.is_a?(Hash)

          case command_type
          when "AddProject"
            added_projects += 1
            predicted = "P#{project_counter.to_i + added_projects}"
            register_batch_alias!(projects, [], predicted, target_id, snapshot.fetch("project_ids"))
          when "CreateIssue"
            requested_project = present_string(value_at(payload, "project_id", "ProjectID", "projectId"))
            resolved_project = projects.fetch(requested_project, requested_project)
            next unless resolved_project

            created_per_project[resolved_project] += 1
            offset = created_per_project[resolved_project]
            counter_base = issue_counters.fetch(resolved_project, nil)
            max_base = snapshot_max_issue.fetch(resolved_project, 0)
            bases = [counter_base, max_base].compact.map(&:to_i).uniq
            bases = [max_base] if bases.empty?
            prefixes = [resolved_project, requested_project].compact.uniq
            prefixes.each do |prefix|
              bases.each do |base|
                register_batch_alias!(issues, ambiguous_issues, "#{prefix}-I#{base + offset}", target_id, snapshot_issue_ids)
              end
            end
          end
        end

        { "issues" => issues, "ambiguous_issues" => ambiguous_issues, "projects" => projects }
      end

      # An alias is only recorded when the head could not already see something with that id, so a
      # prediction never shadows a real pre-existing target. Two creations claiming the same
      # prediction make it ambiguous, and ambiguous predictions are rejected instead of guessed.
      def register_batch_alias!(table, ambiguous, predicted_id, real_id, visible_ids)
        return if blank?(predicted_id)
        return if Array(visible_ids).include?(predicted_id)
        return if ambiguous.include?(predicted_id)

        existing = table[predicted_id]
        if existing && existing != real_id
          table.delete(predicted_id)
          ambiguous << predicted_id
          return
        end

        table[predicted_id] = real_id
      end

      def snapshot_max_issue_numbers(snapshot_issue_ids)
        Array(snapshot_issue_ids).each_with_object({}) do |issue_id, maxima|
          match = issue_id.to_s.match(/\A(P\d+)-I(\d+)\z/)
          next unless match

          project_id = match[1]
          number = match[2].to_i
          maxima[project_id] = number if number > maxima.fetch(project_id, 0)
        end
      end

      # Issues this batch created that no SpawnWorker in the batch claims. Claims are read from the
      # head's declared payloads (explicit reference, predicted id, or the real created id), never
      # from state that earlier commands already mutated, so every command in a large fan-out batch
      # sees the same answer.
      def orphan_created_issue_ids(commands:, created:, aliases:)
        created_ids = created.filter_map { |entry| entry.fetch("issue_id", nil) }
        return [] if created_ids.empty?

        created_by_index = created.to_h { |entry| [entry.fetch("index", -1).to_i, entry.fetch("issue_id", nil)] }
        created_by_command_id = created.to_h { |entry| [entry.fetch("command_id", nil).to_s, entry.fetch("issue_id", nil)] }
        claimed = []
        Array(commands).each_with_index do |proposed, position|
          next unless proposed.is_a?(Hash)
          next unless canonical_command_type(value_at(proposed, "type", "command_type")) == "SpawnWorker"

          payload = value_at(proposed, "payload")
          payload = {} unless payload.is_a?(Hash)
          reference = head_batch_issue_reference(payload)
          if reference
            claimed << if reference.fetch("kind") == "index"
                         created_by_index[reference.fetch("index").to_i]
                       else
                         created_by_command_id[reference.fetch("command_id").to_s]
                       end
            next
          end

          requested = present_string(value_at(payload, "issue_id", "IssueID", "issueId"))
          next unless requested

          claimed << (aliases[requested] || (created_ids.include?(requested) ? requested : nil))
        end

        created_ids.uniq - claimed.compact.uniq
      end

      def resolve_symbolic_batch_issue_reference(command:, payload:, command_type:, reference:, created:, index:)
        described = describe_batch_issue_reference(reference)
        entry = find_batch_issue_reference_entry(reference, created)
        if entry.nil?
          return {
            "rejection" => {
              "message" => "#{command_type} references #{described}, but this head result has no matching CreateIssue command.",
              "errors" => ["batch_issue_reference_not_found"]
            }
          }
        end
        if entry.fetch("index", -1).to_i >= index
          return {
            "rejection" => {
              "message" => "#{command_type} references #{described}, which is not applied before it. List the CreateIssue command first.",
              "errors" => ["batch_issue_reference_out_of_order"]
            }
          }
        end

        issue_id = entry.fetch("issue_id", nil)
        unless issue_id
          return {
            "rejection" => {
              "message" => "#{command_type} references #{described}, but that command did not create an issue (#{entry.fetch("status", "pending")}).",
              "errors" => ["batch_issue_reference_unresolved"]
            }
          }
        end

        {
          "command" => command_with_issue_id(command, payload, issue_id),
          "resolved_reference" => { "reference" => described, "issue_id" => issue_id, "command_type" => command_type }
        }
      end

      def find_batch_issue_reference_entry(reference, entries)
        if reference.fetch("kind") == "index"
          entries.find { |entry| entry.fetch("index", nil).to_i == reference.fetch("index").to_i }
        else
          wanted = reference.fetch("command_id").to_s
          entries.find { |entry| entry.fetch("command_id", nil).to_s == wanted }
        end
      end

      def head_batch_created_issues(journal)
        Array(journal).each_with_index.filter_map do |entry, position|
          next unless entry.is_a?(Hash)
          next unless canonical_command_type(entry.fetch("command_type", nil)) == "CreateIssue"

          {
            "index" => entry.fetch("index", position).to_i,
            "command_id" => entry.fetch("command_id", nil).to_s,
            "status" => entry.fetch("status", nil),
            "issue_id" => entry.fetch("status", nil) == "accepted" ? present_string(entry.fetch("target_id", nil)) : nil
          }
        end
      end

      # Resolves `follow_up_of_command` / `replace_agent_from_command` (and the equivalent
      # `"@<command_id>"` value written straight into the lineage field) against the workers this
      # batch already spawned, the same way `after_from_command` is resolved.
      def resolve_batch_lineage_agent_target(command:, payload:, plan:, index:)
        resolved_payload = payload
        changed = false
        BATCH_AGENT_REFERENCE_FIELDS.each do |definition|
          reference = head_batch_agent_reference(resolved_payload, definition)
          next unless reference

          resolution = resolve_symbolic_batch_agent_reference(
            payload: resolved_payload,
            definition: definition,
            reference: reference,
            spawned: plan.fetch("spawned_workers"),
            index: index
          )
          return resolution if resolution.fetch("rejection", nil)

          resolved_payload = resolution.fetch("payload")
          changed = true
        end
        return nil unless changed

        { "command" => command.merge("payload" => resolved_payload) }
      end

      def head_batch_agent_reference(payload, definition)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *definition.fetch("reference_keys"))
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        agent_id = value_at(payload, *definition.fetch("aliases"))
        return nil unless batch_issue_reference_value?(agent_id)

        parse_batch_issue_reference(agent_id)
      end

      def resolve_symbolic_batch_agent_reference(payload:, definition:, reference:, spawned:, index:)
        field = definition.fetch("field")
        described = describe_batch_issue_reference(reference)
        entry = find_batch_issue_reference_entry(reference, spawned)
        if entry.nil?
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described} for #{field}, but this head result has no matching SpawnWorker command.",
              "errors" => ["batch_agent_reference_not_found"]
            }
          }
        end
        if entry.fetch("index", -1).to_i >= index
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described} for #{field}, which is not applied before it. List the predecessor SpawnWorker command first.",
              "errors" => ["batch_agent_reference_out_of_order"]
            }
          }
        end

        agent_id = entry.fetch("agent_id", nil)
        unless agent_id
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described} for #{field}, but that command did not spawn a worker (#{entry.fetch("status", "pending")}).",
              "errors" => ["batch_agent_reference_unresolved"]
            }
          }
        end

        { "payload" => payload_with_related_agent_id(payload, definition, agent_id) }
      end

      def payload_with_related_agent_id(payload, definition, agent_id)
        dropped = definition.fetch("reference_keys") + definition.fetch("aliases")
        payload.reject { |key, _value| dropped.include?(key.to_s) }.merge(definition.fetch("field") => agent_id)
      end

      def head_batch_added_projects(journal)
        Array(journal).each_with_index.filter_map do |entry, position|
          next unless entry.is_a?(Hash)
          next unless canonical_command_type(entry.fetch("command_type", nil)) == "AddProject"

          {
            "index" => entry.fetch("index", position).to_i,
            "command_id" => entry.fetch("command_id", nil).to_s,
            "status" => entry.fetch("status", nil),
            "project_id" => entry.fetch("status", nil) == "accepted" ? present_string(entry.fetch("target_id", nil)) : nil
          }
        end
      end

      # Resolves `after_from_command` / `after_agent_id: "@<command_id>"` against the workers this
      # batch has already spawned. Same ordering and failure rules as issue_from_command.
      def resolve_batch_after_agent_target(command:, payload:, plan:, index:)
        reference = head_batch_after_agent_reference(payload)
        return nil unless reference

        described = describe_batch_issue_reference(reference)
        entry = find_batch_issue_reference_entry(reference, plan.fetch("spawned_workers"))
        if entry.nil?
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described}, but this head result has no matching SpawnWorker command.",
              "errors" => ["after_agent_reference_not_found"]
            }
          }
        end
        if entry.fetch("index", -1).to_i >= index
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described}, which is not applied before it. List the worker it waits for first.",
              "errors" => ["after_agent_reference_out_of_order"]
            }
          }
        end

        agent_id = entry.fetch("agent_id", nil)
        unless agent_id
          return {
            "rejection" => {
              "message" => "SpawnWorker references #{described}, but that command did not spawn a worker (#{entry.fetch("status", "pending")}).",
              "errors" => ["after_agent_reference_unresolved"]
            }
          }
        end

        {
          "command" => command_with_after_agent_id(command, payload, agent_id),
          "resolved_reference" => { "reference" => described, "after_agent_id" => agent_id, "command_type" => "SpawnWorker" }
        }
      end

      def head_batch_after_agent_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *DEFERRED_WORKER_AFTER_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        value = value_at(payload, *DEFERRED_WORKER_AFTER_KEYS)
        return nil unless batch_issue_reference_value?(value)

        parse_batch_issue_reference(value)
      end

      def command_with_after_agent_id(command, payload, agent_id)
        updated_payload = payload.dup
        DEFERRED_WORKER_AFTER_REFERENCE_KEYS.each { |key| updated_payload.delete(key) }
        DEFERRED_WORKER_AFTER_KEYS.each { |key| updated_payload.delete(key) }
        updated_payload["after_agent_id"] = agent_id
        command.merge("payload" => updated_payload)
      end

      # Workers this batch has spawned so far, so a later command can wait for one of them.
      def head_batch_spawned_workers(journal)
        Array(journal).each_with_index.filter_map do |entry, position|
          next unless entry.is_a?(Hash)
          next unless canonical_command_type(entry.fetch("command_type", nil)) == "SpawnWorker"

          {
            "index" => entry.fetch("index", position).to_i,
            "command_id" => entry.fetch("command_id", nil).to_s,
            "status" => entry.fetch("status", nil),
            "agent_id" => entry.fetch("status", nil) == "accepted" ? present_string(entry.fetch("target_id", nil)) : nil
          }
        end
      end

      def head_batch_project_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *BATCH_PROJECT_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        return nil unless batch_issue_reference_value?(project_id)

        parse_batch_issue_reference(project_id)
      end

      def command_with_project_id(command, payload, project_id, rerouted_from: nil)
        cleaned = payload.reject do |key, _value|
          name = key.to_s
          BATCH_PROJECT_REFERENCE_KEYS.include?(name) || %w[project_id ProjectID projectId].include?(name)
        end
        resolved = { "project_id" => project_id, "_rerouted_from_project_id" => present_string(rerouted_from) }.compact
        command.merge("payload" => cleaned.merge(resolved))
      end

      def head_batch_issue_reference(payload)
        return nil unless payload.is_a?(Hash)

        explicit = value_at(payload, *BATCH_ISSUE_REFERENCE_KEYS)
        return parse_batch_issue_reference(explicit) unless explicit.nil? || (!explicit.is_a?(Integer) && blank?(explicit))

        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        return nil unless batch_issue_reference_value?(issue_id)

        parse_batch_issue_reference(issue_id)
      end

      def batch_issue_reference_value?(value)
        value.is_a?(String) && value.strip.start_with?(BATCH_REFERENCE_PREFIX)
      end

      def parse_batch_issue_reference(value)
        return { "kind" => "index", "index" => value.to_i } if value.is_a?(Integer)

        if value.is_a?(Hash)
          command_id = present_string(value_at(value, "command_id", "commandId", "command"))
          return { "kind" => "command_id", "command_id" => command_id } if command_id

          index = value_at(value, "index", "command_index", "commandIndex")
          return { "kind" => "index", "index" => index.to_i } unless index.nil?

          return nil
        end

        text = value.to_s.strip.delete_prefix(BATCH_REFERENCE_PREFIX).strip
        return nil if text.empty?

        if (match = text.match(/\A(?:command|command_id|commandId)\s*[:=]\s*(.+)\z/))
          return { "kind" => "command_id", "command_id" => match[1].strip }
        end
        if (match = text.match(/\A(?:index|command_index|commandIndex)\s*[:=]\s*(\d+)\z/))
          return { "kind" => "index", "index" => match[1].to_i }
        end
        return { "kind" => "index", "index" => text.to_i } if text.match?(/\A\d+\z/)

        { "kind" => "command_id", "command_id" => text }
      end

      def describe_batch_issue_reference(reference)
        if reference.fetch("kind") == "index"
          "command index #{reference.fetch("index")} in this head result"
        else
          "command #{reference.fetch("command_id")} in this head result"
        end
      end

      def command_with_issue_id(command, payload, issue_id, rerouted_from: nil)
        cleaned = payload.reject do |key, _value|
          name = key.to_s
          BATCH_ISSUE_REFERENCE_KEYS.include?(name) || %w[issue_id IssueID issueId].include?(name)
        end
        resolved = { "issue_id" => issue_id, "_rerouted_from_issue_id" => present_string(rerouted_from) }.compact
        command.merge("payload" => cleaned.merge(resolved))
      end

      # Only remap a predicted id inside the project the head was already routing to. A predicted
      # id that resolves to another project is a routing mistake the kernel should not paper over.
      def batch_issue_remap_compatible?(requested_issue_id:, candidate_issue_id:)
        synchronized_state do
          state = normalized_state
          requested = find_issue(state, requested_issue_id)
          next true unless requested

          candidate = find_issue(state, candidate_issue_id)
          next false unless candidate

          requested.fetch("project_id", nil) == candidate.fetch("project_id", nil)
        end
      end

      # An issue is visible to a head only when the head's spawn snapshot contained it, so an issue
      # another head created after this head was spawned can never be a deliberate target.
      def head_could_see_issue?(head_id:, issue_id:)
        synchronized_state do
          state = normalized_state
          issue = find_issue(state, issue_id)
          next false unless issue
          next true if issue.fetch("originating_head_id", nil).to_s == head_id.to_s

          head = find_agent(state, head_id)
          next true unless head

          metadata = head.fetch("harness_metadata", {}) || {}
          snapshot_issue_ids = metadata.fetch("snapshot_issue_ids", nil)
          next Array(snapshot_issue_ids).include?(issue.fetch("id")) if snapshot_issue_ids.is_a?(Array)

          # Heads recorded before snapshot ids were tracked fall back to creation order.
          issue_created = parse_time_or_nil(issue.fetch("created_at", nil))
          head_created = parse_time_or_nil(head.fetch("created_at", nil))
          next true unless issue_created && head_created

          issue_created <= head_created
        end
      end

      def head_batch_remap_message(remap)
        if remap.key?("project_id")
          "Routed #{remap.fetch("command_type")} to project #{remap.fetch("project_id")} added by this head result instead of predicted project #{remap.fetch("requested_project_id")}."
        elsif remap.fetch("reason", nil) == "batch_created_issue_left_without_worker"
          "Routed #{remap.fetch("command_type")} to issue #{remap.fetch("issue_id")} created by this head result, which would otherwise have had no worker, instead of #{remap.fetch("requested_issue_id")}."
        else
          "Routed #{remap.fetch("command_type")} to issue #{remap.fetch("issue_id")} created by this head result instead of predicted issue #{remap.fetch("requested_issue_id")}."
        end
      end

      def log_head_batch_issue_remap(head_id, resolution)
        remap = resolution.fetch("remap", nil)
        return [] unless remap

        synchronized_state do
          state = normalized_state
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: head_id,
            level: "warning",
            message: head_batch_remap_message(remap),
            details: remap.merge("head_id" => head_id)
          )
          touch_state!(state)
          store.save(state)
          log_ids
        end
      end

      # Returns false when the head or its journal entry is gone, so the caller can
      # stop the batch instead of raising out of the whole apply/reconcile pass.
      def mark_head_command_started!(head_id, index)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          next false unless head

          metadata = head.fetch("harness_metadata", {}) || {}
          journal = Array(metadata.fetch("head_result_command_journal", []))
          entry = journal[index]
          next false unless entry

          now = timestamp
          entry["status"] = "running"
          entry["started_at"] = now
          # The claim identifies this instance so another live instance re-entering the same
          # batch skips a command that is already running here instead of applying it twice.
          entry.merge!(instance_ownership_metadata)
          metadata["head_result_command_journal"] = journal
          head["harness_metadata"] = metadata.merge(head_result_apply_lease(now))
          head["updated_at"] = now
          touch_state!(state)
          store.save(state)
          true
        end
      end

      def checkpoint_head_command_result!(head_id, index, result)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          next false unless head

          metadata = head.fetch("harness_metadata", {}) || {}
          journal = Array(metadata.fetch("head_result_command_journal", []))
          entry = journal[index]
          next false unless entry

          entry.merge!(
            "status" => result.fetch("status", "failed"),
            "target_id" => result.fetch("target_id", nil),
            "message" => result.fetch("message", nil),
            "result" => result.fetch("result", nil),
            "errors" => result.fetch("errors", []),
            "log_entry_ids" => result.fetch("log_entry_ids", []),
            "completed_at" => timestamp
          )
          metadata["head_result_command_journal"] = journal
          head["harness_metadata"] = metadata.merge(head_result_apply_lease(timestamp))
          head["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
          true
        end
      end

      # Identifies this kernel instance so a head command batch is applied exactly once even when
      # more than one Meringue process shares the same state file.
      def kernel_instance_id
        @kernel_instance_id ||= "#{kernel_host_name}:#{Process.pid}:#{object_id}"
      end

      def kernel_host_name
        @kernel_host_name ||= begin
          Socket.gethostname
        rescue StandardError
          "localhost"
        end
      end

      def head_result_apply_lease(now = timestamp)
        {
          "head_result_apply_owner" => kernel_instance_id,
          "head_result_apply_owner_host" => kernel_host_name,
          "head_result_apply_owner_pid" => Process.pid,
          "head_result_apply_heartbeat" => now
        }
      end

      def head_result_apply_lease_held_elsewhere?(head)
        metadata = head.is_a?(Hash) ? (head.fetch("harness_metadata", {}) || {}) : {}
        return false unless metadata.is_a?(Hash)

        owner = present_string(metadata.fetch("head_result_apply_owner", nil))
        return false unless owner
        return false if owner == kernel_instance_id
        return false if present_string(metadata.fetch("head_result_applied_at", nil))

        heartbeat = parse_time_or_nil(metadata.fetch("head_result_apply_heartbeat", nil))
        return false unless heartbeat
        return false if Time.now - heartbeat > HEAD_RESULT_APPLY_LEASE_SECONDS

        owner_host = present_string(metadata.fetch("head_result_apply_owner_host", nil))
        owner_pid = metadata.fetch("head_result_apply_owner_pid", nil).to_i
        return true unless owner_host == kernel_host_name && owner_pid.positive?

        owner_process_alive?(owner_pid)
      end

      def owner_process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue StandardError
        true
      end

      def command_result_from_journal(entry)
        {
          "command_id" => entry.fetch("command_id", nil),
          "command_type" => entry.fetch("command_type", nil),
          "status" => entry.fetch("status", nil),
          "target_id" => entry.fetch("target_id", nil),
          "message" => entry.fetch("message", nil),
          "result" => entry.fetch("result", nil),
          "errors" => entry.fetch("errors", []),
          "log_entry_ids" => entry.fetch("log_entry_ids", [])
        }
      end

      def terminal_command_status?(status)
        %w[accepted rejected failed].include?(status.to_s)
      end

      # Returns the pid of another live Meringue instance that is running this
      # command right now, or nil when the command is free to run here.
      def head_command_claim_owner(entry)
        return nil unless entry.is_a?(Hash)
        return nil unless entry.fetch("status", nil).to_s == "running"

        other_live_instance_pid(
          entry.fetch("owner_instance_id", nil),
          entry.fetch("owner_instance_pid", nil),
          entry.fetch("owner_instance_started_at", nil)
        )
      end

      def kernel_command_result?(value)
        value.is_a?(Hash) && value.key?("status") && value.key?("command_type")
      end

      # Terminal reconcile details for a polled head whose result the kernel rejected or failed.
      # Shaped like the other terminal models so the log-once/no-churn guards apply unchanged.
      def unapplied_head_result_reconcile_model(apply_result, now)
        {
          "state" => RECONCILE_STATE_TERMINAL_ERROR,
          "agent_type" => "head",
          "reason" => "head_result_not_applied",
          "last_error_at" => now,
          "error_message" => present_string(apply_result.fetch("message", nil)) || "Head result was not applied.",
          "apply_status" => apply_result.fetch("status", nil),
          "apply_errors" => Array(apply_result.fetch("errors", []))
        }.compact
      end

      def head_result_fully_applied?(apply_result)
        return false if head_result_apply_skipped?(apply_result)

        command_results = apply_result.dig("result", "command_results")
        Array(command_results).all? { |result| result.fetch("status", nil) == "accepted" }
      end

      # True when this instance deliberately did nothing because another kernel instance holds the
      # apply lease for the batch. The owner finishes the batch and owns the head bookkeeping.
      def head_result_apply_skipped?(apply_result)
        return false unless apply_result.is_a?(Hash)

        apply_result.dig("result", "skipped").to_s == "head_result_apply_in_progress"
      end

      # Head-proposed commands carry the proposing head id so the kernel can attribute the work
      # (`CreateIssue.originating_head_id`) and so commands like `Recount` can tell their own
      # proposer apart from an unrelated in-flight head.
      def command_with_default_id(command, head_id:, index:)
        return command unless command.is_a?(Hash)

        payload = value_at(command, "payload") || {}
        # `_head_id` marks every head-proposed command. CreateIssue uses it for attribution,
        # AnswerQuestion avoids spawning a redundant routing head, and commands such as Recount
        # and SetHarness use it to avoid treating the proposer as its own active-head blocker.
        enriched_command = if payload.is_a?(Hash)
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
          # Head records are removed once their result is applied, so the message that triggered
          # the question is captured here while it is still recoverable. A later answer needs it
          # to route the blocked work.
          "original_user_message" => head_request_user_message(state, head_id),
          "status" => "open",
          "answer" => nil,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def head_request_user_message(state, head_id)
        head = find_agent(state, head_id.to_s)
        return nil unless head && head.fetch("type", nil) == "head"

        metadata = head.fetch("harness_metadata", {}) || {}
        request = metadata.fetch("head_request", {}) || {}
        present_string(request.fetch("user_message", nil))
      end

      def update_issue_status_from_workers!(state, issue, now)
        workers = state.fetch("agents").select do |candidate|
          candidate.fetch("type", nil) == "worker" && candidate.fetch("issue_id", nil) == issue.fetch("id") &&
            candidate.fetch("status", nil) != "killed"
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

      # Records the harness session the head owns for its lifetime. Called for both the
      # polled/async head path and the synchronous head path so head session metadata is
      # inspectable and reconcilable the same way worker session metadata is.
      def record_head_session!(head_id, session_ref)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          raise "Head #{head_id} disappeared before its session could be recorded." unless head

          now = timestamp
          merge_session_ref_into_agent!(head, session_ref)
          head["status"] = "working"
          head["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "harness",
            source_id: head_id.to_s,
            level: "info",
            message: "Started agent session for head #{head_id}.",
            details: {
              "head_id" => head_id.to_s,
              "harness" => head.fetch("harness", nil),
              "pid" => head.fetch("pid", nil),
              "session_id" => head.fetch("harness_session_id", nil),
              "session_file" => head.fetch("harness_session_file", nil),
              "head_session_state" => (head.fetch("harness_metadata", {}) || {}).fetch("head_session_state", nil)
            }.compact
          )
          touch_state!(state, now)
          store.save(state)

          { "agent" => deep_copy(head), "log_entry_ids" => log_ids }
        end
      end

      def mark_head_session_unavailable!(head_id, reason:)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return { "agent" => nil, "log_entry_ids" => [] } unless head

          now = timestamp
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "head_session_state" => HEAD_SESSION_STATE_UNAVAILABLE,
            "head_session_note" => reason
          )
          head["updated_at"] = now
          touch_state!(state, now)
          store.save(state)

          { "agent" => deep_copy(head), "log_entry_ids" => [] }
        end
      end

      def mark_head_session_active!(agent, now: timestamp)
        return unless agent.fetch("type", nil) == "head"
        return unless agent_has_session_reference?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        reactivated = metadata.fetch("head_session_state", nil) == HEAD_SESSION_STATE_RELEASED
        updated = metadata.merge(
          "head_session_state" => HEAD_SESSION_STATE_ACTIVE,
          "head_session_started_at" => present_string(metadata.fetch("head_session_started_at", nil)) || now
        )
        if reactivated
          updated["head_session_restarted_at"] = now
          updated.delete("head_session_released_at")
          updated.delete("head_session_release_reason")
        end
        agent["harness_metadata"] = updated.compact
      end

      # Terminal teardown for a head session. Stops the harness session the head owned and
      # records why it ended so reconciliation never treats a dead head as resumable.
      def release_head_session!(agent, reason:, now: timestamp)
        return { "changed" => false, "reason" => "agent_is_not_head" } unless agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        already_released = metadata.fetch("head_session_state", nil) == HEAD_SESSION_STATE_RELEASED
        killed_session = false
        if !already_released && present_string(agent.fetch("harness", nil))
          kill_session_safely(session_ref_from_agent(agent), agent: agent)
          killed_session = !!agent_has_session_reference?(agent)
        end

        agent["harness_metadata"] = metadata.merge(
          "head_session_state" => HEAD_SESSION_STATE_RELEASED,
          "head_session_released_at" => present_string(metadata.fetch("head_session_released_at", nil)) || now,
          "head_session_release_reason" => present_string(metadata.fetch("head_session_release_reason", nil)) || reason,
          "is_streaming" => false
        ).compact

        {
          "changed" => !already_released,
          "killed_session" => killed_session,
          "reason" => reason
        }
      end

      def mark_head_errored(head_id, error, release_session: false)
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
          released = release_session ? release_head_session!(head, reason: "head_errored", now: now) : nil
          append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "error",
            message: "Head #{head_id} failed: #{error_info.fetch("message")}",
            details: { "class" => error_info.fetch("class") }.merge(released ? { "head_session_released" => true } : {})
          )
          touch_state!(state, now)
          store.save(state)
          release_session
        end
      rescue StandardError
        nil
      end

      def async_heads?
        @async_heads
      end

      def synchronized_state(&block)
        @state_mutex.synchronize { @state_lock.synchronize(&block) }
      end

      def harness_client
        active_harness_client
      end

      def head_runner
        active_head_runner
      end

      def active_harness_client(provider: nil)
        selected_provider = normalize_harness_provider(provider || active_harness_provider)
        @harness_client_provider&.call(selected_provider) || @harness_client
      end

      def active_head_runner(provider: nil)
        selected_provider = normalize_harness_provider(provider || active_harness_provider)
        @head_runner_provider&.call(selected_provider) || @head_runner
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def normalized_state
        state = store.load
        ensure_state_shape!(state)
        state
      end

      def persist_normalized_state_if_changed
        synchronized_state do
          state = store.load
          before = JSON.generate(state)
          ensure_state_shape!(state)
          changed = JSON.generate(state) != before
          store.save(state) if changed
          changed
        end
      end

      def theme_names
        if defined?(Meringue::TUI::Style)
          Meringue::TUI::Style.colorschemes
        else
          %w[catppuccin gruvbox kanagawa meringue rose-pine tokyonight]
        end
      end

      def normalized_theme_name(theme)
        if defined?(Meringue::TUI::Style)
          Meringue::TUI::Style.normalize_colorscheme_name(theme)
        else
          theme.to_s.strip.downcase.tr("_", "-")
        end
      end

      def apply_tui_theme(theme)
        Meringue::TUI::Style.configure!(theme) if defined?(Meringue::TUI::Style)
      end

      def ensure_state_shape!(state)
        State::Models.ensure_state_shape!(state)
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
        internal_harness = normalize_harness_provider(state["metadata"]["active_harness"] || @default_harness_provider)
        state["metadata"]["active_harness"] = selectable_harness_provider?(internal_harness) ? Meringue::Harness::Registry.public_provider_name(internal_harness) : internal_harness
        state["metadata"]["active_harness_label"] = Meringue::Harness::Registry.provider_label(internal_harness) if selectable_harness_provider?(internal_harness)
        state["metadata"]["harness_generation"] ||= 0
        state["metadata"]["pi_session_defaults"] = configured_pi_session_defaults
        # Harness model catalogs are fetched in the background, so state only
        # guarantees the container exists; an empty map means "not fetched yet".
        state["metadata"]["harness_model_catalogs"] = {} unless state["metadata"]["harness_model_catalogs"].is_a?(Hash)
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

      def append_harness_event_logs(state, agent, events)
        visible_events = Array(events).filter_map { |event| visible_harness_event(event) }
        return [] if visible_events.empty?

        log_ids = []
        visible_events.first(HARNESS_EVENT_LOG_LIMIT).each do |event|
          log_ids.concat(append_log(
            state,
            source_type: "harness",
            source_id: agent.fetch("id", nil),
            level: event.fetch("level"),
            message: harness_event_log_message(agent, event),
            details: event.fetch("details")
          ))
        end

        overflow_count = visible_events.length - HARNESS_EVENT_LOG_LIMIT
        if overflow_count.positive?
          log_ids.concat(append_log(
            state,
            source_type: "harness",
            source_id: agent.fetch("id", nil),
            level: "info",
            message: "#{agent.fetch("id", "Agent")} produced #{overflow_count} additional agent event#{overflow_count == 1 ? "" : "s"}.",
            details: {
              "omitted_event_count" => overflow_count,
              "event_types" => visible_events.drop(HARNESS_EVENT_LOG_LIMIT).map { |event| event.fetch("type") }.uniq
            }
          ))
        end

        log_ids
      end

      def visible_harness_event(event)
        return nil unless event.is_a?(Hash)

        event = stringify_keys(event)
        event_type = event.fetch("type", "event").to_s
        return nil if HARNESS_EVENT_IGNORED_TYPES.include?(event_type)
        return nil if internal_harness_event_type?(event_type)
        return nil unless event_type.match?(HARNESS_EVENT_LOG_PATTERN)

        details = compact_harness_event_details(event)
        {
          "type" => event_type,
          "label" => harness_event_label(event),
          "level" => harness_event_error?(event_type) ? "warning" : "info",
          "details" => details
        }
      end

      def internal_harness_event_type?(event_type)
        normalized_type = event_type.to_s
                                    .gsub(/([a-z])([A-Z])/, "\\1_\\2")
                                    .tr("-", "_")
                                    .downcase
        return true if %w[turn message tool_execution tool_call tool_result].include?(normalized_type)

        normalized_type.start_with?("turn_", "message_", "tool_execution_")
      end

      def compact_harness_event_details(event)
        details = {
          "event_type" => event.fetch("type", nil),
          "event_timestamp" => event.fetch("timestamp", nil),
          "tool_name" => harness_event_label(event),
          "status" => harness_event_first_present(event, "status", "state", "result"),
          "role" => event.dig("message", "role"),
          "id" => harness_event_first_present(event, "id", "event_id", "toolCallId", "tool_call_id")
        }.compact
        data = event.fetch("data", nil)
        details["data_type"] = data.fetch("type", nil) if data.is_a?(Hash)
        details["error"] = harness_event_first_present(event, "error", "error_message", "message") if harness_event_error?(event.fetch("type", ""))
        details
      end

      def harness_event_log_message(agent, event)
        label = present_string(event.fetch("label", nil))
        suffix = label ? ": #{label}" : ""
        "#{agent.fetch("id", "Agent")} agent session #{event.fetch("type")}#{suffix}."
      end

      def harness_event_error?(event_type)
        event_type.to_s.match?(/error|failed|failure|parse_error/i)
      end

      def harness_event_label(event)
        data = event.fetch("data", nil)
        data = {} unless data.is_a?(Hash)
        harness_event_first_present(
          event,
          "tool_name", "toolName", "tool", "name", "command", "function", "customType"
        ) || harness_event_first_present(
          data,
          "tool_name", "toolName", "tool", "name", "command", "function", "customType"
        )
      end

      def harness_event_first_present(hash, *keys)
        return nil unless hash.is_a?(Hash)

        keys.each do |key|
          value = hash[key] || hash[key.to_sym]
          next unless value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol) || value == true || value == false

          normalized = present_string(value)
          return normalized if normalized
        end
        nil
      end

      def stringify_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value.is_a?(Hash) ? stringify_keys(value) : value
        end
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

      # Resolve a UI selection against the kernel's current snapshot. The input
      # layer intentionally sends only selected_id, so a worker/agent can never
      # smuggle an arbitrary issue id into head context. Agent selections resolve
      # to their durable owning issue; issue selections target themselves.
      def resolve_selected_head_target(state, requested_target)
        return [nil, nil] if requested_target.nil?

        selected_id = if requested_target.is_a?(Hash)
                        value_at(requested_target, "selected_id", "SelectedID", "selectedId", "id")
                      else
                        requested_target
                      end
        selected_id = selected_id.to_s.strip
        # A blank or shapeless selection carries no destination, so it means the
        # same thing as no selection: route the message normally instead of
        # rejecting it for an empty routing hint.
        return [nil, nil] if selected_id.empty?

        issue = find_issue(state, selected_id)
        agent = nil
        unless issue
          agent = find_agent(state, selected_id)
          unless agent
            return [nil, { "code" => "selected_target_not_found", "message" => "selected target #{selected_id} no longer exists." }]
          end

          issue_id = present_string(agent.fetch("issue_id", nil))
          unless issue_id
            return [nil, { "code" => "selected_target_has_no_issue", "message" => "selected agent #{selected_id} does not own an issue." }]
          end

          issue = find_issue(state, issue_id)
          unless issue
            return [nil, { "code" => "selected_target_issue_not_found", "message" => "owning issue #{issue_id} for selected agent #{selected_id} no longer exists." }]
          end
        end

        if issue.fetch("status", nil) == "killed"
          return [nil, { "code" => "selected_target_issue_unavailable", "message" => "selected issue #{issue.fetch("id")} is no longer available." }]
        end

        project = find_project(state, issue.fetch("project_id", nil))
        unless project
          return [nil, { "code" => "selected_target_project_not_found", "message" => "project for selected issue #{issue.fetch("id")} no longer exists." }]
        end

        target = {
          "selected_id" => selected_id,
          "selected_type" => agent ? "agent" : "issue",
          "issue_id" => issue.fetch("id"),
          "project_id" => issue.fetch("project_id", nil),
          "issue_title" => issue.fetch("title", nil)
        }
        if agent
          metadata = agent.fetch("harness_metadata", {}) || {}
          target.merge!(
            "selected_agent_id" => agent.fetch("id"),
            "selected_agent_type" => agent.fetch("type", nil),
            "selected_agent_title" => metadata.fetch("title", nil)
          )
        end
        [target.compact, nil]
      end

      # Scalar ids make the selected prompt visible under both issue and exact
      # agent log scopes; the nested object preserves the complete audit context.
      def selected_target_log_details(selected_target)
        return {} unless selected_target.is_a?(Hash)

        {
          "selected_target" => deep_copy(selected_target),
          "selected_target_id" => selected_target.fetch("selected_id", nil),
          "selected_target_type" => selected_target.fetch("selected_type", nil),
          "project_id" => selected_target.fetch("project_id", nil),
          "issue_id" => selected_target.fetch("issue_id", nil),
          "agent_id" => selected_target.fetch("selected_agent_id", nil),
          "routing_action" => "selected_target"
        }.compact
      end

      # Ids reach the kernel from typed slash commands, head-proposed command payloads, and TUI
      # selections. Meringue ids are canonically uppercase, so an id that only differs by case is
      # resolved to its canonical record here as a defensive second layer for paths that do not go
      # through `apply`. Lookups still prefer an exact match, so nothing can shadow a real record.
      def find_project(state, project_id)
        Ids.find_record(state.fetch("projects"), project_id)
      end

      def find_issue(state, issue_id)
        Ids.find_record(state.fetch("issues"), issue_id)
      end

      def find_agent(state, agent_id)
        Ids.find_record(state.fetch("agents"), agent_id)
      end

      def find_session_agent(state, agent_id:, session_ref: nil)
        ref = session_ref.is_a?(Hash) ? session_ref : {}
        identities = [
          ["harness_session_id", value_at(ref, "session_id", "harness_session_id")],
          ["harness_session_file", value_at(ref, "session_file", "harness_session_file")],
          ["pid", value_at(ref, "pid")]
        ].select { |_key, value| present_string(value) }
        identities.each do |key, value|
          match = state.fetch("agents").find { |agent| agent.fetch(key, nil).to_s == value.to_s }
          return match if match
        end

        identities.empty? ? find_agent(state, agent_id) : nil
      end

      def find_question(state, question_id)
        Ids.find_record(state.fetch("questions"), question_id)
      end

      # Rewrites record ids in a command payload to their canonical uppercase spelling so state,
      # logs, and the head command journal never store `h83` for `H83`. This is the earliest point
      # where an id can be canonicalized without losing what its author typed: only an id that
      # already resolves to a record in state is recased, so an unknown or malformed id reaches
      # validation (and its rejection message) exactly as it was typed. State is loaded only when
      # the payload actually holds a non-canonical id.
      def canonicalize_payload_record_ids(payload)
        return payload unless Ids.payload_needs_canonicalization?(payload)

        state = synchronized_state { normalized_state }
        Ids.canonicalize_payload(payload, state)
      rescue StandardError
        payload
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
          "session_settings" => agent.fetch("session_settings", nil),
          "metadata" => metadata.merge("kind" => metadata.fetch("kind", agent.fetch("type", nil)))
        }
      end

      def reconcile_candidate?(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return false if agent.fetch("type", nil) == "head" && present_string(metadata.fetch("head_result_applied_at", nil))
        # A head belongs to the instance that spawned it. Completing another live
        # instance's head would apply its result a second time.
        return false if agent.fetch("type", nil) == "head" && owned_by_other_live_instance?(agent)
        return false if blank?(agent.fetch("harness", nil)) || agent.fetch("harness", nil) == "fake"
        return false unless agent_has_session_reference?(agent) || recoverable_untracked_head?(agent)
        return false if %w[completed killed].include?(agent.fetch("status", nil))
        # A record whose failure was already recorded as terminal is settled: `/prompt` refuses
        # to continue it and reconciliation has no repair left to try. Re-polling it would only
        # re-observe the same dead session, rewrite state, and append the same error log on
        # every pass. Recovery resumes only when a command moves the record out of `errored`.
        return false if terminal_reconcile_error_recorded?(agent)
        return false unless harness_client_available_for_agent?(agent)
        return true unless agent.fetch("status", nil) == "errored"

        resumable_worker_reconcile_candidate?(agent) || resumable_head_reconcile_candidate?(agent)
      end

      # The durable "reconciliation is done trying" marker: an errored record whose persisted
      # reconcile details already say `terminal_error`.
      def terminal_reconcile_error_recorded?(agent)
        return false unless agent.fetch("status", nil) == "errored"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile = {} unless reconcile.is_a?(Hash)
        metadata.fetch("reconcile_state", nil) == RECONCILE_STATE_TERMINAL_ERROR ||
          reconcile.fetch("state", nil) == RECONCILE_STATE_TERMINAL_ERROR
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

      def resumable_head_reconcile_candidate?(agent)
        agent.fetch("type", nil) == "head" && head_recovery_attempt_count(agent) < HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS
      end

      def recoverable_untracked_head?(agent)
        agent.fetch("type", nil) == "head" && %w[queued working blocked errored].include?(agent.fetch("status", nil))
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
        return recover_head_session_from_poll_error(agent, client, session_ref, e) if head_reconcile_recovery_eligible?(agent)

        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => agent.fetch("type", nil),
          "state" => "errored",
          "session_ref" => session_ref,
          "error" => error_payload(e),
          "reconcile" => reconcile_error_model(agent, e)
        }
      end

      def apply_poll_result(poll_result)
        poll_result = poll_result_with_current_agent_id(poll_result)
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
              last_assistant_text: poll_result.fetch("last_assistant_text", nil),
              session_ref: poll_result.fetch("session_ref", nil)
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

      def poll_result_with_current_agent_id(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_session_agent(
            state,
            agent_id: poll_result.fetch("agent_id", nil),
            session_ref: poll_result.fetch("session_ref", nil)
          )
          agent ? poll_result.merge("agent_id" => agent.fetch("id")) : poll_result
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
          log_ids = append_harness_event_logs(state, agent, poll_result.fetch("events", []))
          log_ids.concat(append_recovery_success_log(state, agent, poll_result))
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => poll_result.fetch("resumed", false) || log_ids.any?, "log_entry_ids" => log_ids)
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
            "head_result" => head_result,
            "_cleanup_head" => false
          )
        end
        log_ids = record_polled_head_completion(poll_result, head_result, apply_result)
        cleanup_result = cleanup_polled_head_after_apply(poll_result, apply_result)
        log_ids.concat(cleanup_result.fetch("log_entry_ids", []))
        poll_result.merge(
          "changed" => apply_result.fetch("status", nil) == "accepted" || cleanup_result.fetch("changed", false),
          "head_result" => head_result,
          "apply_result" => apply_result,
          "head_cleanup" => cleanup_result.fetch("cleanup", nil),
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
          # Captured before the session merge, which resets `reconcile_state` to `healthy`, so a
          # repeated failure can still be recognised as already recorded.
          previously_terminal = terminal_reconcile_error_recorded?(head)
          previous_signature = reconcile_error_signature((head.fetch("harness_metadata", {}) || {}).fetch("reconcile", {}))
          merge_session_ref_into_agent!(head, poll_result.fetch("session_ref", {}))
          if head_result_apply_skipped?(apply_result)
            log_ids = append_harness_event_logs(state, head, poll_result.fetch("events", []))
            touch_state!(state, now)
            store.save(state)
            return log_ids
          end

          fully_applied = head_result_fully_applied?(apply_result)
          accepted = apply_result.fetch("status", nil) == "accepted"
          head["status"] = if !accepted
                             "errored"
                           elsif fully_applied
                             "completed"
                           else
                             "blocked"
                           end
          head["updated_at"] = now
          # A head result the kernel refused is terminal for this head: reconciliation has no
          # retry for it, so it is recorded like any other terminal reconcile failure. Otherwise
          # the record stays `healthy`, is re-polled every pass, and re-logs the same error every
          # two seconds. The head's session is closed for the same reason it is on other terminal
          # head failures: nothing will use it again. Release first, then snapshot the metadata,
          # so the release markers survive.
          reconcile = accepted ? nil : unapplied_head_result_reconcile_model(apply_result, now)
          repeated = !accepted && previously_terminal && previous_signature == reconcile_error_signature(reconcile)
          release_head_session!(head, reason: "head_result_not_applied", now: now) unless accepted
          metadata = (head.fetch("harness_metadata", {}) || {}).merge(
            "completed_at" => now,
            "head_result" => head_result,
            "head_result_applied_at" => accepted ? now : nil,
            "head_result_apply_status" => fully_applied ? apply_result.fetch("status", nil) : "partial",
            "is_streaming" => false
          ).compact
          unless accepted
            metadata = metadata.merge(
              "errored_at" => metadata.fetch("errored_at", nil) || now,
              "reconcile_state" => RECONCILE_STATE_TERMINAL_ERROR,
              "reconcile" => reconcile
            ).compact
          end
          head["harness_metadata"] = metadata
          log_ids = append_harness_event_logs(state, head, poll_result.fetch("events", []))
          if !accepted && !repeated
            log_ids.concat(append_log(
              state,
              source_type: "head",
              source_id: head.fetch("id"),
              level: "error",
              message: "Polled head #{head.fetch("id")} completed but its HeadResult was not applied.",
              details: {
                "head_result" => head_result,
                "apply_status" => apply_result.fetch("status", nil),
                "apply_message" => apply_result.fetch("message", nil)
              }.merge(reconcile || {})
            ))
          end
          touch_state!(state, now)
          store.save(state)
          log_ids
        end
      end

      def cleanup_polled_head_after_apply(poll_result, apply_result)
        unless apply_result.fetch("status", nil) == "accepted" && head_result_fully_applied?(apply_result)
          return { "changed" => false, "cleanup" => { "changed" => false, "reason" => "head_result_not_fully_applied" }, "log_entry_ids" => [] }
        end

        synchronized_state do
          state = normalized_state
          cleanup = cleanup_applied_head!(state, poll_result.fetch("agent_id"), now: timestamp)
          touch_state!(state)
          store.save(state)
          { "changed" => cleanup.fetch("changed", false), "cleanup" => cleanup, "log_entry_ids" => cleanup.fetch("log_entry_ids", []) }
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
          "session_ref" => session_ref,
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

      def head_reconcile_recovery_eligible?(agent)
        return false unless agent.fetch("type", nil) == "head"
        return false if %w[completed killed].include?(agent.fetch("status", nil))
        return false if head_recovery_attempt_count(agent) >= HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS

        metadata = agent.fetch("harness_metadata", {}) || {}
        reconcile = metadata.fetch("reconcile", {}) || {}
        first_error_at = reconcile.fetch("first_error_at", nil)
        return true if agent.fetch("status", nil) == "errored" && present_string(first_error_at)
        return false unless present_string(first_error_at)

        !head_reconcile_grace_active?(first_error_at, timestamp)
      end

      def head_recovery_attempt_count(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile.fetch("head_recovery_attempt_count", metadata.fetch("head_recovery_attempt_count", 0)).to_i
      end

      def recover_head_session_from_poll_error(agent, client, session_ref, original_error)
        attempt = head_recovery_attempt_count(agent) + 1
        request = head_recovery_request(agent)
        resumed_ref = nil
        attach_error = nil

        if agent_has_session_reference?(agent) && client.respond_to?(:attach_session)
          begin
            resumed_ref = client.attach_session(session_ref)
            resumed_ref = prompt_recovered_head_session(client, resumed_ref)
            return recovered_head_poll_result(
              agent,
              client,
              resumed_ref,
              original_error,
              attempt: attempt,
              mode: "resumed"
            )
          rescue StandardError => e
            attach_error = e
            safely_kill_recovery_session(client, resumed_ref) if resumed_ref
          end
        end

        raise attach_error || RuntimeError.new("persisted head request is unavailable") if request.nil?

        restarted_ref = restart_head_session(agent, request)
        recovered_head_poll_result(
          agent,
          client_for_restarted_head(agent),
          restarted_ref,
          original_error,
          attempt: attempt,
          mode: "restarted",
          attach_error: attach_error
        )
      rescue StandardError => recovery_error
        previous_reconcile = (agent.fetch("harness_metadata", {}) || {}).fetch("reconcile", {}) || {}
        {
          "agent_id" => agent.fetch("id", nil),
          "agent_type" => "head",
          "state" => "errored",
          "session_ref" => session_ref,
          "error" => error_payload(recovery_error),
          "reconcile" => previous_reconcile.merge(
            "state" => RECONCILE_STATE_TRANSIENT_ERROR,
            "head_recovery_attempt_count" => attempt || head_recovery_attempt_count(agent) + 1,
            "head_recovery_attempted_at" => timestamp,
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error),
            "recovery_error_class" => recovery_error.class.name,
            "recovery_error_message" => sanitized_error_message(recovery_error)
          ).compact
        }
      end

      def prompt_recovered_head_session(client, session_ref)
        return session_ref if session_ref.fetch("is_streaming", false)

        client.prompt_session(session_ref, HEAD_RESUME_PROMPT, mode: "normal")
      end

      def restart_head_session(agent, request)
        runner = active_head_runner(provider: agent.fetch("harness", nil))
        unless runner.respond_to?(:spawn_head_session)
          raise RuntimeError, "head runner cannot restart a persisted session"
        end

        snapshot = synchronized_state { deep_copy(normalized_state) }
        context = Heads::Context.new(
          head_id: agent.fetch("id"),
          user_message: request.fetch("user_message"),
          snapshot: snapshot,
          question_id: request.fetch("question_id", nil),
          selected_target: request.fetch("selected_target", nil),
          cwd: cwd,
          state_path: store.path
        )
        runner.spawn_head_session(
          user_message: request.fetch("user_message"),
          snapshot: snapshot,
          question_id: request.fetch("question_id", nil),
          context: context
        )
      end

      def head_recovery_request(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        request = metadata.fetch("head_request", {}) || {}
        user_message = present_string(request.fetch("user_message", nil))
        if user_message
          return {
            "user_message" => user_message,
            "question_id" => present_string(request.fetch("question_id", nil)),
            "selected_target" => request.fetch("selected_target", nil)
          }.compact
        end

        synchronized_state do
          state = normalized_state
          log = state.fetch("logs", []).reverse.find do |entry|
            entry.fetch("source_type", nil) == "user" && entry.dig("details", "head_id").to_s == agent.fetch("id").to_s
          end
          message = log && present_string(log.fetch("message", nil))
          next nil unless message

          {
            "user_message" => message,
            "question_id" => present_string(log.dig("details", "question_id")),
            "selected_target" => log.dig("details", "selected_target")
          }.compact
        end
      end

      def recovered_head_poll_result(agent, client, session_ref, original_error, attempt:, mode:, attach_error: nil)
        metadata = session_ref.fetch("metadata", {}) || {}
        request = head_recovery_request(agent)
        session_ref = session_ref.merge(
          "metadata" => metadata.merge(
            "head_request" => request,
            "head_recovery_attempt_count" => attempt,
            "head_recovery_mode" => mode,
            "head_recovered_at" => timestamp
          ).compact
        )
        completed = completed_session?(session_ref)
        original_identity = session_ref_identity(agent_session_ref(agent))
        result = {
          "agent_id" => agent.fetch("id"),
          "agent_type" => "head",
          "state" => completed ? "completed" : "working",
          "session_ref" => session_ref,
          "events" => client.respond_to?(:read_events) ? client.read_events(session_ref) : [],
          "last_assistant_text" => completed ? safe_last_assistant_text(client, session_ref) : nil,
          "reconcile" => {
            "state" => RECONCILE_STATE_RESUMING,
            "head_recovery_attempt_count" => attempt,
            "head_recovery_attempted_at" => timestamp,
            "head_recovery_mode" => mode,
            "original_pid" => original_identity.fetch("pid", nil),
            "original_session_id" => original_identity.fetch("session_id", nil),
            "original_session_file" => original_identity.fetch("session_file", nil),
            "original_error_class" => original_error.class.name,
            "original_error_message" => sanitized_error_message(original_error),
            "attach_error_class" => attach_error&.class&.name,
            "attach_error_message" => attach_error && sanitized_error_message(attach_error)
          }.compact
        }
        result[mode == "resumed" ? "resumed" : "restarted"] = true
        result
      end

      def session_ref_identity(session_ref)
        {
          "pid" => session_ref.fetch("pid", nil),
          "session_id" => session_ref.fetch("session_id", nil),
          "session_file" => session_ref.fetch("session_file", nil)
        }.compact
      end

      def client_for_restarted_head(agent)
        runner = active_head_runner(provider: agent.fetch("harness", nil))
        return runner.harness_client if runner.respond_to?(:harness_client)

        harness_client_for_agent(agent)
      end

      def safely_kill_recovery_session(client, session_ref)
        client.kill_session(session_ref) if client.respond_to?(:kill_session)
      rescue StandardError
        nil
      end

      def defer_head_reconcile_error_from_poll(poll_result)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, poll_result.fetch("agent_id"))
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "agent_not_found") unless agent
          return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "terminal_status") if %w[completed killed].include?(agent.fetch("status", nil))
          return mark_agent_errored_from_poll(poll_result) unless agent.fetch("type", nil) == "head"

          now = timestamp
          metadata = agent.fetch("harness_metadata", {}) || {}
          previous_reconcile = metadata.fetch("reconcile", {}) || {}
          first_error_at = previous_reconcile.fetch("first_error_at", nil) || existing_error_reference_at(agent) || now
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
              message: "Head #{agent.fetch("id")} had a transient agent session reconciliation error; keeping it working during the startup grace window.",
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
            message: "Worker #{agent.fetch("id")} could not resume its agent session; will retry reconciliation.",
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
          reconcile = terminal_reconcile_error_model(poll_result, now)
          # Recording the same terminal failure twice is not a state change: it would bump
          # `updated_at`, rewrite the state file, and append a duplicate error log on every
          # reconciliation pass. A genuinely different failure still transitions and logs.
          if repeated_terminal_reconcile_error?(agent, reconcile)
            return poll_result.merge("changed" => false, "log_entry_ids" => [], "skipped" => "already_errored")
          end

          agent["status"] = "errored"
          agent["updated_at"] = now
          # AGENTS.md: the kernel closes a head's harness session when the head errors. Without
          # this a terminally failed head keeps an orphaned harness process alive forever.
          session_release = if agent.fetch("type", nil) == "head"
                              release_head_session!(agent, reason: "head_reconcile_error", now: now)
                            end
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

          details = if session_release && session_release.fetch("changed", false)
                      reconcile.merge("head_session_released" => true)
                    else
                      reconcile
                    end
          log_ids = append_log(
            state,
            source_type: agent.fetch("type", nil) == "head" ? "head" : "worker",
            source_id: agent.fetch("id"),
            level: "error",
            message: "#{agent.fetch("type", "Agent").capitalize} #{agent.fetch("id")} errored while reconciling its agent session.",
            details: details
          )
          touch_state!(state, now)
          store.save(state)
          poll_result.merge("changed" => true, "log_entry_ids" => log_ids)
        end
      end

      # Same record, same terminal failure: nothing new to persist or tell the user about.
      # `last_error_at` moves every pass, so identity is the failure itself, not its timestamp.
      def repeated_terminal_reconcile_error?(agent, reconcile)
        return false unless terminal_reconcile_error_recorded?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        reconcile_error_signature(metadata.fetch("reconcile", {})) == reconcile_error_signature(reconcile)
      end

      def reconcile_error_signature(reconcile)
        reconcile = {} unless reconcile.is_a?(Hash)
        {
          "state" => reconcile.fetch("state", nil).to_s,
          "error_class" => reconcile.fetch("error_class", nil).to_s,
          "error_message" => reconcile.fetch("error_message", nil).to_s
        }
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

      # An already-errored head must not earn a fresh startup grace window (and be flipped back
      # to `working`) just because reconciliation noticed it again. Judge the window from when
      # the record actually failed instead of from now.
      def existing_error_reference_at(agent)
        return nil unless agent.fetch("status", nil) == "errored"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        present_string(metadata.fetch("errored_at", nil)) || present_string(agent.fetch("updated_at", nil))
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

      def append_recovery_success_log(state, agent, poll_result)
        return [] unless poll_result.fetch("resumed", false) || poll_result.fetch("restarted", false)

        if agent.fetch("type", nil) == "head"
          restarted = poll_result.fetch("restarted", false)
          append_log(
            state,
            source_type: "head",
            source_id: agent.fetch("id"),
            level: restarted ? "warning" : "info",
            message: restarted ?
              "Restarted agent session for head #{agent.fetch("id")} because its persisted session could not be safely resumed." :
              "Resumed agent session for head #{agent.fetch("id")} and requested its HeadResult.",
            details: poll_result.fetch("reconcile", {})
          )
        else
          append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "info",
            message: "Resumed agent session for worker #{agent.fetch("id")} and prompted it to continue.",
            details: poll_result.fetch("reconcile", {})
          )
        end
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

        if agent.fetch("type", nil) == "head" && active_head_runner(provider: agent.fetch("harness", nil)).respond_to?(:harness_client)
          return active_head_runner(provider: agent.fetch("harness", nil)).harness_client
        end

        active_harness_client(provider: agent.fetch("harness", nil))
      end

      def active_harness_provider(state = nil)
        source_state = state || normalized_state
        normalize_harness_provider(source_state.fetch("metadata", {}).fetch("active_harness", @default_harness_provider))
      end

      def normalize_harness_provider(provider)
        normalized = Meringue::Harness::Registry.normalize_provider(provider)
        selectable_harness_provider?(normalized) || normalized == "fake" ? normalized : @default_harness_provider.to_s
      end

      def normalize_initial_harness_provider(provider)
        normalized = Meringue::Harness::Registry.normalize_provider(provider)
        selectable_harness_provider?(normalized) || normalized == "fake" ? normalized : Meringue::Harness::Registry::DEFAULT_PROVIDER
      end

      def normalize_selectable_harness_provider(provider)
        normalized = Meringue::Harness::Registry.normalize_provider(provider)
        selectable_harness_provider?(normalized) ? normalized : nil
      end

      def selectable_harness_provider?(provider)
        Meringue::Harness::Registry::PROVIDERS.include?(provider.to_s)
      end

      def active_harness_selection_blockers(state)
        state.fetch("agents", []).select do |agent|
          %w[queued working].include?(agent.fetch("status", nil).to_s) ||
            (agent.fetch("harness_metadata", {}) || {}).fetch("is_streaming", false)
        end.map { |agent| agent.fetch("id", nil) }.compact
      end

      def inferred_default_harness_provider
        if @harness_client.respond_to?(:harness_name)
          @harness_client.harness_name
        elsif @head_runner.respond_to?(:harness_client) && @head_runner.harness_client&.respond_to?(:harness_name)
          @head_runner.harness_client.harness_name
        elsif @head_runner.class.name.to_s.end_with?("FakeRunner")
          "fake"
        else
          Meringue::Harness::Registry::DEFAULT_PROVIDER
        end
      end

      def merge_session_ref_into_agent!(agent, session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        agent["harness"] = session_ref.fetch("harness", agent.fetch("harness", nil))
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["workspace_path"] ||= session_ref.fetch("cwd", nil)
        agent["session_settings"] = deep_copy(session_ref.fetch("session_settings")) if session_ref.fetch("session_settings", nil).is_a?(Hash)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          metadata,
          "cwd" => session_ref.fetch("cwd", metadata.fetch("cwd", nil)),
          "is_streaming" => session_ref.fetch("is_streaming", false),
          "last_event_at" => session_ref.fetch("last_event_at", nil),
          "reconcile_state" => RECONCILE_STATE_HEALTHY,
          "reconcile" => nil
        ).compact
        mark_head_session_active!(agent)
      end

      def cleanup_applied_head!(state, head_id, now: timestamp)
        head = find_agent(state, head_id)
        return { "changed" => false, "reason" => "head_not_found" } unless head
        return { "changed" => false, "reason" => "agent_is_not_head" } unless head.fetch("type", nil) == "head"

        session_release = release_head_session!(head, reason: "head_result_applied", now: now)

        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        head["status"] = "killed"
        head["updated_at"] = now
        head["harness_metadata"] = metadata.merge(
          "completed_at" => metadata.fetch("completed_at", nil) || now,
          "head_result_applied_at" => metadata.fetch("head_result_applied_at", nil) || now,
          "killed_at" => now,
          "cleanup_reason" => "head_result_applied",
          "is_streaming" => false
        ).compact

        remove_agent_from_active_state!(state, head_id)

        # Teardown detail rides along with the ApplyHeadResult log instead of adding a
        # second per-message log line to the visible history.
        {
          "changed" => true,
          "removed_agent_id" => head_id,
          "reason" => "head_result_applied",
          "session_release" => session_release,
          "session_id" => head.fetch("harness_session_id", nil),
          "log_entry_ids" => []
        }.compact
      end

      def remove_agent_from_active_state!(state, agent_id)
        state["agents"] = state.fetch("agents").reject { |agent| agent.fetch("id", nil) == agent_id }
        state.fetch("issues").each do |issue|
          next unless issue.key?("agent_ids")

          issue["agent_ids"] = Array(issue["agent_ids"]) - [agent_id]
        end
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
        local_timestamp
      rescue StandardError
        global_timestamp
      end

      def local_timestamp
        Time.now.getlocal.iso8601
      end

      def global_timestamp
        Time.now.utc.iso8601
      end
    end
  end
end
