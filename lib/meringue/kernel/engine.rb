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
require_relative "../ids"

module Meringue
  module Kernel
    class Engine
      WORKER_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue worker agent. Work only on the assigned issue and workspace.
        Follow the user's prompt and the repository instructions in your working directory.

        You do not directly interface with the user, so do not ask for permission before taking normal implementation or delivery actions requested by the assigned issue. You may edit files, commit, push, and open or update pull requests when the assigned issue asks for those actions.

        Meringue must never be the author of a git commit. If you create a commit, use the repository's configured user.name and user.email identity; never set or use a Meringue, Meringue Worker, agent@meringue.local, or meringue@example.com identity, and never pass a Meringue identity through --author. If no non-Meringue repository identity is available, do not invent one or commit as Meringue; report the identity configuration as a blocker. The worker environment preserves a non-Meringue repository identity while refusing a Meringue fallback, so committing as the user remains supported.

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
      # How many times workspace provisioning is attempted for one worker before it stops being
      # retried automatically and starts waiting for a human. Two, not more: a retry of a stuck
      # `git worktree add` is cheap and usually works, but each attempt can legitimately take
      # minutes on a monorepo, and an unbounded retry loop would spend those minutes forever.
      PROVISIONING_ATTEMPT_LIMIT = 2
      # Provisioning states a worker can be resumed from. All of them mean "reservation intact,
      # no session, no workspace".
      PROVISIONING_RESUMABLE_STATES = %w[failed retry_pending retry_exhausted].freeze
      # How often a slow provisioning reports that it is still working.
      PROVISIONING_PROGRESS_INTERVAL_SECONDS = 60
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
      # A harness turn that ends is not automatically a turn that finished. These are the
      # harness-reported turn outcomes that mean the work stopped without a result, so the
      # agent must settle as `errored` with a visible reason instead of as `completed`.
      SETTLE_FAILURE_TURN_STATES = %w[failed errored].freeze
      # Session events that prove the turn died rather than finished. Only consulted when the
      # settled turn produced no final assistant message, so a genuine completion that happens
      # to be followed by a clean process exit is still a completion.
      SETTLE_FAILURE_EVENT_STOP_REASONS = %w[error].freeze
      SETTLE_FAILURE_TRANSPORT_EVENT_TYPES = %w[process_exit process_error process_failed rpc_parse_error].freeze
      SETTLE_FAILURE_NETWORK_PATTERN = /
        connection|network|socket|dns|offline|unreachable|refused|reset
        |econn|etimedout|enotfound|epipe|timeout|timed\s?out
        |tls|ssl|certificate|handshake|proxy|gateway|fetch\sfailed
        |overloaded|502|503|504
      /ix.freeze
      # A dead turn that resuming can never repair, because what the provider rejected is the
      # saved transcript itself. The harness classifies it (Pi:
      # `PiClient::UNREPLAYABLE_SESSION_PATTERN`); this pattern is the kernel's fallback for the
      # same evidence arriving through session events instead of a turn outcome.
      SETTLE_FAILURE_UNREPLAYABLE_KIND = "unreplayable_session"
      SETTLE_FAILURE_UNREPLAYABLE_PATTERN = /
        (?:thinking|redacted_thinking)[^\n]{0,200}?cannot\s+be\s+modified
        |blocks\s+must\s+remain\s+as\s+they\s+were\s+in\s+the\s+original\s+response
        |expected\s+`?thinking`?\s+or\s+`?redacted_thinking`?
      /ix.freeze
      # How many times one worker's poisoned session is restarted in place. Exactly one: the
      # restart is a fresh session on the same worktree, so if that session dies the same way the
      # cause is not the transcript and another identical restart would only spend tokens.
      WORKER_SESSION_RESTART_MAX_ATTEMPTS = 1
      # How long a chain of in-place restarts may get before Meringue stops recovering by itself
      # and leaves the work to the user. Guards the pathological case where every successor's own
      # first turn is also cut short mid-tool-call.
      WORKER_SESSION_RESTART_MAX_CHAIN_DEPTH = 2

      COMMAND_ALIASES = {
        "add_project" => "AddProject",
        "modify_project" => "ModifyProject",
        "create_issue" => "CreateIssue",
        "spawn_worker" => "SpawnWorker",
        "spawn_head" => "SpawnHead",
        "apply_head_result" => "ApplyHeadResult",
        "ask_question" => "AskQuestion",
        "answer_question" => "AnswerQuestion",
        "dismiss_question" => "DismissQuestion",
        "modify_issue" => "ModifyIssue",
        "prompt_agent" => "PromptAgent",
        "create_goal" => "CreateGoal",
        "goal" => "CreateGoal",
        "modify_goal" => "ModifyGoal",
        "stop_goal" => "StopGoal",
        "list_goals" => "ListGoals",
        "goals" => "ListGoals",
        "kill" => "Kill",
        "set_harness" => "SetHarness",
        "harness" => "SetHarness",
        "help" => "Help",
        "complete_onboarding" => "CompleteOnboarding",
        "theme" => "SetTheme",
        "set_theme" => "SetTheme",
        "get_state" => "GetState",
        "get_session_defaults" => "GetSessionDefaults",
        "get_model_catalog" => "GetModelCatalog",
        "models" => "GetModelCatalog",
        "list_models" => "GetModelCatalog",
        "set_default_session_model" => "SetDefaultSessionModel",
        "set_default_session_thinking_level" => "SetDefaultSessionThinkingLevel",
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
        ["/project rename <project_id> \"<name>\"", "Rename a project."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/issue rename <issue_id> \"<title>\"", "Rename an issue."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/prompt <agent_id> \"<message>\"", "Prompt an existing worker agent session, or retry a failed head (H<n>)."],
        ["/harness <pi|claude|antigravity>", "Select the active harness backend for future heads and workers."],
        ["/models [harness] [refresh]", "List every model the selected harness reports, refreshing the catalog when it is stale."],
        ["/model <provider>/<model-id>", "Persist the model used for all future Pi heads and workers; existing sessions are unchanged. The model id may itself contain / and :."],
        ["/thinking <level>", "Persist the thinking level used for all future Pi heads and workers: off, minimal, low, medium, high, xhigh, or max."],
        ["/goal create [issue_id] \"<prompt>\" --metric \"<command>\" --target <number> [--project <project_id>] [--comparator gte|lte|gt|lt|eq] [--max-iterations <n>] [--guardrail \"<command>\"] [--parse last_number|first_number|exit_status] [--pattern \"<regex>\"] [--title \"<title>\"] [--fresh-attempt] [--paused]", "Start a goal loop: the kernel keeps producing attempts until the metric hits its target or a budget/no-progress guard trips. Name an issue to attach the loop to it, or give only a quoted prompt and Meringue creates the issue itself."],
        ["/goal status [goal_id]", "Show goal loops, their iteration accounting, and why a stopped goal stopped."],
        ["/goal pause <goal_id>", "Pause a goal loop after the current attempt; nothing new is spawned while it is paused."],
        ["/goal resume <goal_id>", "Resume a paused goal loop."],
        ["/goal stop <goal_id>", "Stop a goal loop for good, leaving its current attempt session alone."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/jump [agent_id]", "TUI local: open an agent's focused workspace, or navigate the AgentTree when no id is provided."],
        ["/setup", "TUI local: reopen first-run setup for the theme, harness, model, and thinking level."],
        ["/keybind", "TUI local: show all keybindings."],
        ["/config", "TUI local: show the active config, supported defaults, conflict policy, and keybindings."],
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
        AddProject ModifyProject CreateIssue ModifyIssue SpawnWorker PromptAgent SpawnHead
        CreateGoal ModifyGoal StopGoal ListGoals
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
      # A goal loop advances at most this many phases per goal per reconcile pass. One pass can
      # therefore measure, judge, and start the next attempt, but it can never run away: after a
      # spawn the goal's own single-flight invariant makes the next decision "wait".
      GOAL_MAX_STEPS_PER_TICK = 4
      # Metric commands are external I/O on the reconcile thread, so one pass spends at most this
      # long advancing goals. Goals that do not fit wait for the next tick instead of delaying
      # session reconciliation for every goal in the state file. A single metric command can still
      # exceed this on its own; it is bounded by the goal's own `metric.timeout_seconds`.
      GOAL_ADVANCE_BUDGET_SECONDS = 30.0
      # Longest issue title `CreateGoal` derives on its own from a prompt. The AgentTree renders
      # an issue title on one line, so a paragraph-long prompt is cut to its first sentence and
      # kept verbatim in the issue description instead.
      GOAL_ISSUE_TITLE_LIMIT = 72
      GOAL_COMPARATOR_TEXT = { "gte" => ">=", "lte" => "<=", "gt" => ">", "lt" => "<", "eq" => "==" }.freeze
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
      # `CreateGoal` is here because its prompt form mints its own issue, so a batch that registers
      # a project and starts a goal in it references the AddProject command the same way.
      BATCH_PROJECT_REFERENCE_COMMANDS = %w[CreateIssue CreateGoal].freeze
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
      # A worker can ask the kernel to spawn a fresh head after it completes. That head receives
      # the worker's bounded final report in its prompt and routes whatever follow-on kernel
      # commands are appropriate. This is a durable continuation record on the worker, not a
      # worker-side poll/sleep loop.
      COMPLETION_CONTINUATION_KEYS = %w[
        completion_continuation CompletionContinuation completionContinuation
        completion_head CompletionHead completionHead
        on_completion OnCompletion onCompletion
        route_on_completion RouteOnCompletion routeOnCompletion
        spawn_head_on_completion SpawnHeadOnCompletion spawnHeadOnCompletion
      ].freeze
      COMPLETION_CONTINUATION_PROMPT_KEYS = %w[
        prompt Prompt user_message UserMessage userMessage
        message Message instruction Instruction continuation_prompt continuationPrompt
      ].freeze
      COMPLETION_CONTINUATION_STATE_WAITING = "waiting"
      COMPLETION_CONTINUATION_STATE_TRIGGERING = "triggering"
      COMPLETION_CONTINUATION_STATE_TRIGGERED = "triggered"
      COMPLETION_CONTINUATION_STATE_APPLIED = "applied"
      COMPLETION_CONTINUATION_STATE_FAILED = "failed"
      COMPLETION_CONTINUATION_HANDOVER_MAX_CHARS = 4_000
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
      # Refreshing a batch stamps every record with the same `last_checked_at`, which would make
      # them all fall due together on one later tick. Each URL gets a deterministic extra delay
      # inside this window so the herd spreads out instead of re-synchronizing every interval.
      DELIVERY_PULL_REQUEST_REFRESH_SPREAD_SECONDS = 5 * 60
      # A reconcile tick is background work nobody asked for. Cap how many forge lookups one tick
      # may start and how long it may spend on them in total, so a large backlog costs many cheap
      # ticks instead of one long one. Leftover records stay due and are picked up next tick.
      DELIVERY_PULL_REQUEST_REFRESH_BATCH_LIMIT = 3
      DELIVERY_PULL_REQUEST_REFRESH_BUDGET_SECONDS = 5.0
      # `/prune` verifies PR state conservatively, but forge discovery/status commands are external
      # I/O. Bound the whole lookup phase so one unreachable forge cannot leave the command pending
      # indefinitely. URLs not resolved inside the budget become `unknown` and retain their issue.
      # The budget is a ceiling, not a cost: a healthy forge finishes in well under a second, and a
      # pass only spends the whole budget when the forge is unreachable or slow. Five seconds was
      # too tight for a real backlog (a single pass exhausted it and retained issues whose PRs were
      # already merged, so the user had to run `/prune` repeatedly), and the phase runs outside the
      # state lock on the submission thread, so a longer ceiling delays nothing but this command.
      PRUNE_FORGE_LOOKUP_BUDGET_SECONDS = 15.0
      # Harness model catalogs change when a user logs into a provider, installs an
      # extension, or edits models.json, so a persisted snapshot is refreshed
      # periodically in the background instead of on every completion keystroke.
      MODEL_CATALOG_REFRESH_INTERVAL_SECONDS = 10 * 60
      # A catalog that could not be read is retried sooner, but not on every
      # 2-second reconciliation pass.
      MODEL_CATALOG_RETRY_INTERVAL_SECONDS = 60
      # How many example references a catalog result names in the log. The full
      # list belongs in the TUI model picker (`/models`), not in the log: a
      # hundred-plus lines of models nobody can act on used to bury every other
      # event in the pane.
      MODEL_CATALOG_OUTPUT_EXAMPLE_LIMIT = 3
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
                  :config, :state_lock, :instance_pid, :instance_id, :prune_forge_lookup_budget, :metric_probe,
                  :goal_advance_budget, :delivery_pull_request_refresh_budget

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
                     metric_probe: Goals::MetricProbe.new,
                     config_path: Config::DEFAULT_PATH,
                     config: nil,
                     prune_forge_lookup_budget: PRUNE_FORGE_LOOKUP_BUDGET_SECONDS,
                     delivery_pull_request_refresh_budget: DELIVERY_PULL_REQUEST_REFRESH_BUDGET_SECONDS,
                     goal_advance_budget: GOAL_ADVANCE_BUDGET_SECONDS,
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
        @metric_probe = metric_probe
        @config_path = File.expand_path(config_path.to_s)
        @config = config || Config.load(path: @config_path)
        @deferred_worker_default_failure_policy = @config.conflict_predecessor_failure
        @prune_forge_lookup_budget = Float(prune_forge_lookup_budget)
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
        elsif command_type == "PromptAgent"
          prompt_agent_command(command_id, command_type, payload)
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
        when "SpawnWorker"
          spawn_worker(command_id, command_type, payload)
        when "PromptAgent"
          prompt_agent(command_id, command_type, payload)
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

      # Settling a worker is a classification, not a rubber stamp. A turn that ended because the
      # transport or provider request died (a dropped wifi connection is the common case), or a
      # session that disappeared without ever producing a final message, settles as `errored`
      # with a human-readable reason. Only a turn that really finished settles as `completed`.
      def mark_worker_completed(agent_id:, harness_events: [], last_assistant_text: nil, session_ref: nil, settle_failure: nil)
        settle_failure ||= worker_settle_failure(
          agent_id: agent_id,
          session_ref: session_ref,
          events: harness_events,
          last_assistant_text: last_assistant_text
        )
        result = if settle_failure
                   record_worker_settle_failure(
                     agent_id: agent_id,
                     settle_failure: settle_failure,
                     harness_events: harness_events,
                     last_assistant_text: last_assistant_text,
                     session_ref: session_ref
                   )
                 else
                   record_worker_completion(
                     agent_id: agent_id,
                     harness_events: harness_events,
                     last_assistant_text: last_assistant_text,
                     session_ref: session_ref
                   )
                 end
        return result unless result.fetch("status", nil) == "accepted"

        # A session the provider refuses to replay is recovered here, before dependents are
        # resolved, so the successor exists in time to inherit the dead worker's queue instead of
        # letting `if_predecessor_fails: "cancel"` dead-end it.
        restart = recover_unreplayable_worker_session(result)
        return restart if restart

        # Completion continuations run from the same settle hook as deferred workers: the worker
        # records its final report, then the kernel can spawn a fresh head to route follow-on work.
        # Reconciliation is the recovery hook for the crash window between recording completion and
        # spawning that head.
        result = with_completion_continuation_resolution(result, trigger: "worker_completed")

        # First of the two activation hooks for queued dependents. Reconciliation is the second, so
        # a dependent cannot be lost if this process dies between A finishing and B starting.
        # A failed settle resolves dependents too: `if_predecessor_fails: "run"` starts them anyway,
        # and a dependent behind a still-recoverable dead turn keeps waiting instead of cancelling.
        with_deferred_worker_resolution(result)
      end

      # Public settle entry point for a worker whose harness turn ended without finishing. Mirrors
      # `mark_worker_completed`, including the queued-dependent hook.
      def mark_worker_settle_failed(agent_id:, settle_failure:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        result = record_worker_settle_failure(
          agent_id: agent_id,
          settle_failure: settle_failure,
          harness_events: harness_events,
          last_assistant_text: last_assistant_text,
          session_ref: session_ref
        )
        return result unless result.fetch("status", nil) == "accepted"

        restart = recover_unreplayable_worker_session(result)
        return restart if restart

        with_deferred_worker_resolution(result)
      end

      # The settle-time half of the unreplayable-session recovery. Returns the accepted result of
      # the settle when the successor was spawned (SpawnWorker already repointed the dead worker's
      # dependents at it), or nil when there is nothing to recover, so the caller falls back to the
      # normal dependent resolution.
      def recover_unreplayable_worker_session(settle_result)
        return nil unless settle_result.fetch("command_type", nil) == "MarkWorkerSettleFailed"

        agent_id = present_string(settle_result.fetch("target_id", nil))
        return nil unless agent_id

        agent = agent_record_snapshot(agent_id)
        return nil unless agent && worker_session_restart_eligible?(agent)

        restart = restart_unreplayable_worker_session(agent_id, trigger: "settle")
        return nil unless restart.is_a?(Hash) && restart.fetch("claimed", false)
        # The restart could not be spawned: fall through so dependents still get resolved (and
        # cancelled if that is their policy) rather than waiting on a worker that cannot continue.
        return nil unless restart.fetch("restarted", false)

        merge_result_log_entry_ids(settle_result, restart.fetch("log_entry_ids", []))
      end

      def merge_result_log_entry_ids(result, log_entry_ids)
        return result if Array(log_entry_ids).empty?

        result.merge("log_entry_ids" => (Array(result.fetch("log_entry_ids", [])) + Array(log_entry_ids)).uniq)
      end

      def agent_record_snapshot(agent_id)
        synchronized_state do
          agent = find_agent(normalized_state, agent_id)
          agent.is_a?(Hash) ? deep_copy(agent) : nil
        end
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

      # Records a worker whose harness turn ended without finishing. The worker becomes `errored`
      # with the failure reason on its record, in its log line, and in the UI, and its issue is
      # never rolled up to `completed` on the back of it. The harness session, worktree, branch,
      # and any queued prompt are all left intact so the worker stays recoverable.
      def record_worker_settle_failure(agent_id:, settle_failure:, harness_events: [], last_assistant_text: nil, session_ref: nil)
        synchronized_state do
          state = normalized_state
          agent = find_session_agent(state, agent_id: agent_id, session_ref: session_ref)
          return rejected_result(nil, "MarkWorkerSettleFailed", "Agent #{agent_id} does not exist.", ["agent_not_found"]) unless agent
          unless agent.fetch("type", nil) == "worker"
            return rejected_result(nil, "MarkWorkerSettleFailed", "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"])
          end
          if %w[completed killed].include?(agent.fetch("status", nil))
            return accepted_result(nil, "MarkWorkerSettleFailed", agent.fetch("id"), "Worker #{agent.fetch("id")} is already #{agent.fetch("status")}.", agent, [])
          end

          raw_failure = settle_failure.is_a?(Hash) ? stringify_keys(settle_failure) : {}
          failure = settle_failure_record(raw_failure)
          # Reconciliation keeps polling a settled session, so re-observing the same dead turn
          # must be a silent no-op instead of another error log every pass. Evidence older than
          # the last delivered prompt is stale for the same reason: the user already recovered.
          if settle_failure_already_recorded?(agent, failure) || stale_settle_failure_evidence?(agent, failure)
            return accepted_result(
              nil,
              "MarkWorkerSettleFailed",
              agent.fetch("id"),
              "Worker #{agent.fetch("id")} is already errored: #{failure.fetch("reason")}",
              agent,
              []
            )
          end

          merge_session_ref_into_agent!(agent, session_ref) if session_ref
          now = timestamp
          failure = failure.merge("detected_at" => now)
          agent["status"] = "errored"
          agent["updated_at"] = now
          metadata_updates = {
            "is_streaming" => false,
            "errored_at" => now,
            "settled_event_count" => Array(harness_events).length,
            "settle_state" => "failed",
            "settle_failure" => failure,
            "status_reason" => settle_failure_status_reason(failure),
            "error_message" => failure.fetch("reason")
          }
          # A session the provider refuses to replay is not resumable, so the record says what the
          # user can act on: the work is intact in the worktree, and continuing means a fresh
          # session there rather than another attempt at the same transcript.
          if unreplayable_session_failure?(failure)
            metadata_updates["session_recovery"] = unreplayable_session_recovery_record(agent, now)
            metadata_updates["status_reason"] = "#{settle_failure_status_reason(failure)}. #{unreplayable_session_recovery_advice(agent)}"
          end
          # Never overwrite a partial result the worker did manage to produce.
          partial_text = present_string(last_assistant_text) || present_string(raw_failure.fetch("last_assistant_text", nil))
          metadata_updates["last_assistant_text"] = partial_text if partial_text
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(metadata_updates).compact

          issue = find_issue(state, agent.fetch("issue_id", nil))
          refresh_worker_parent_statuses!(state, agent, now)

          details = {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "settled_event_count" => Array(harness_events).length,
            "settle_failure" => failure,
            "recoverable" => worker_resumable_after_settle_failure?(agent)
          }.compact
          details["session_recovery"] = metadata_updates["session_recovery"] if metadata_updates.key?("session_recovery")
          log_ids = append_harness_event_logs(state, agent, harness_events)
          log_ids.concat(append_log(
            state,
            source_type: "worker",
            source_id: agent.fetch("id"),
            level: "error",
            message: settle_failure_log_message(agent, failure),
            details: details
          ))
          touch_state!(state, now)
          store.save(state)

          accepted_result(
            nil,
            "MarkWorkerSettleFailed",
            agent.fetch("id"),
            "Marked worker #{agent.fetch("id")} errored: #{failure.fetch("reason")}",
            worker_completion_result(agent, issue),
            log_ids
          )
        end
      end

      private :record_worker_completion, :record_worker_settle_failure

      # A completed worker may carry a kernel-owned continuation that spawns a fresh head with the
      # worker's final report. Merge those nested results into the completion command so callers can
      # see which head routed the follow-on work and which log lines were written.
      def with_completion_continuation_resolution(result, trigger:)
        agent_id = present_string(result.fetch("target_id", nil))
        return result unless agent_id

        continuations = resolve_completion_continuations(trigger: trigger, only_agent_id: agent_id)
        return result if continuations.empty?

        result.merge(
          "log_entry_ids" => (
            Array(result.fetch("log_entry_ids", [])) +
              continuations.flat_map { |entry| Array(entry.fetch("log_entry_ids", [])) }
          ).uniq,
          "completion_continuation_results" => continuations
        )
      end

      private :with_completion_continuation_resolution

      # Both settle paths share the queued-dependent hook: a dependent must be resolved from the
      # settle that actually happened, whether the predecessor finished or died mid-turn.
      def with_deferred_worker_resolution(result)
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

      private :with_deferred_worker_resolution

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
        # Completion-triggered heads are resolved after polls so a worker that completed during
        # this pass can route follow-on commands immediately. The settle path does the same work;
        # this reconciliation hook recovers the crash window where completion was recorded but the
        # continuation head was not spawned yet.
        completion_continuation_results = reconcile_step("resolve_completion_continuations", []) { resolve_completion_continuations(trigger: "reconcile") }
        # Second activation hook for queued dependents. It runs after the polls so a predecessor
        # that settled in this same pass is honoured immediately, and it is the hook that recovers
        # a dependency whose predecessor settled, errored, or disappeared while Meringue was down.
        deferred_worker_results = reconcile_step("resolve_deferred_workers", []) { resolve_deferred_workers(trigger: "reconcile") }
        # Goal loops run after the poll results are applied so this pass already sees the attempt
        # worker that just settled, instead of waiting a full tick to notice it. They also run after
        # deferred activation, so a goal whose attempt was queued behind another agent observes the
        # activated worker rather than a record that is still waiting.
        goal_steps = reconcile_step("advance_goal_loops", []) { advance_goal_loops }
        changed_count = applied_results.count { |result| result.fetch("changed", false) }
        changed_count += completion_continuation_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += deferred_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += recovered_worker_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += pending_prompt_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += recovered_results.count { |result| result.fetch("status", nil) == "accepted" }
        changed_count += 1 if normalized_state_changed
        changed_count += 1 if prune_result.fetch("changed", false)
        changed_count += delivery_pr_refreshes.count { |refresh| refresh.fetch("changed", false) }
        changed_count += 1 if model_catalog_refresh.fetch("changed", false)
        changed_count += goal_steps.count { |step| step.fetch("changed", false) }
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
            "completion_continuation_results" => completion_continuation_results,
            "deferred_worker_results" => deferred_worker_results,
            "goal_loop_steps" => goal_steps,
            "poll_results" => applied_results
          },
          (recovered_worker_results.flat_map { |result| result.fetch("log_entry_ids", []) } + pending_prompt_results.flat_map { |result| result.fetch("log_entry_ids", []) } + recovered_results.flat_map { |result| result.fetch("log_entry_ids", []) } + prune_result.fetch("log_entry_ids", []) + applied_results.flat_map { |result| result.fetch("log_entry_ids", []) } + completion_continuation_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + deferred_worker_results.flat_map { |result| Array(result.fetch("log_entry_ids", [])) } + goal_steps.flat_map { |step| step.fetch("log_entry_ids", []) }).uniq
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

      # Same question for a goal record. Goals are not agents: their driver ownership lives at
      # the top level of the record, not in harness metadata.
      def goal_owned_by_other_live_instance?(goal)
        !other_live_instance_pid(
          goal.fetch("owner_instance_id", nil),
          goal.fetch("owner_instance_pid", nil),
          goal.fetch("owner_instance_started_at", nil)
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
            next unless prompt

            {
              "command_id" => command_id,
              "type" => "SpawnWorker",
              "payload" => {
                "issue_id" => agent.fetch("issue_id"),
                # The record itself, so recovery resumes this reservation instead of depending on
                # a spawn command id the original request may never have had.
                "_reservation_agent_id" => agent.fetch("id"),
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
          already_removed = cleanup_outcomes.count { |outcome| outcome["status"] == "already_removed" }
          [
            "  removed issues: #{Array(prune_result["removed_issue_ids"]).length}",
            "  removed agents: #{Array(prune_result["removed_agent_ids"]).length}",
            "  removed worktrees: #{cleanup_outcomes.count { |outcome| outcome["status"] == "removed" }}",
            "  removed projects: #{Array(prune_result["removed_project_ids"]).length}",
            already_removed.positive? ? "  worktrees already gone: #{already_removed}" : nil,
            "  blocked worktree cleanups: #{cleanup_outcomes.count { |outcome| !outcome.fetch("success", false) }}",
            "  retained issues: #{Array(prune_result["retained_issue_ids"]).length}",
            *retained.first(PRUNE_RETENTION_REPORT_LIMIT).map do |reason|
              "    #{reason["issue_id"]}: #{Array(reason["blockers"]).join(", ")}"
            end
          ].compact
        when "ListGoals"
          goal_output_lines(result)
        when "CreateGoal", "ModifyGoal", "StopGoal"
          goal = result.is_a?(Hash) ? result : {}
          return [] if goal.empty?

          [
            "  #{Goals::Record.summary(goal)}",
            goal["success_criteria"] ? "  criteria: #{goal["success_criteria"]}" : nil,
            goal.dig("metric", "command") ? "  metric: #{goal.dig("metric", "command")}" : nil
          ].compact
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

      # A catalog read is reported as a status, not as a listing. The browsable
      # list is the TUI model picker (`/models`), which reads this same persisted
      # snapshot, so the log only has to say which harness answered, how fresh the
      # answer is, and how many models it holds.
      def model_catalog_output_lines(result)
        catalog = result.is_a?(Hash) ? result : {}
        models = Array(catalog["models"])
        lines = ["  harness: #{catalog.fetch("harness", "unknown")}", "  availability: #{catalog.fetch("availability", "unknown")}"]
        lines << "  models: #{models.length}" unless models.empty?
        lines << "  source: #{catalog.fetch("source")}" if catalog["source"]
        lines << "  confirmed: #{catalog.fetch("fetched_at")}" if catalog["fetched_at"]
        lines << "  last refresh attempt: #{catalog.fetch("last_attempt_at")}" if catalog["last_attempt_at"]
        lines << "  note: #{catalog.fetch("note")}" if catalog["note"]
        return lines if models.empty?

        examples = models.first(MODEL_CATALOG_OUTPUT_EXAMPLE_LIMIT).map { |model| model.fetch("reference", "?") }
        lines << "  for example: #{examples.join(", ")}"
        lines << "  Run /models to pick one in the model picker, or /model <provider>/<model-id> to set it directly."
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
          log_ids = prune_result.fetch("workspace_cleanup_log_entry_ids", []).dup
          log_ids.concat(append_killed_records_prune_log(state, prune_result))
          touch_state!(state, now)
          store.save(state)
          prune_result.merge(
            "changed" => true,
            "removed_project_ids" => removed_project_ids,
            "log_entry_ids" => log_ids.uniq
          )
        end
      end

      # Reconciliation removes killed records with the same helper `/prune` uses, so it also lost
      # the per-worker "Removed managed worktree" line. It reports the same consolidated counts
      # instead, which keeps the filesystem side effect visible without spending a line per worker.
      # It stays silent when the pass removed nothing (a killed record whose worktree is still
      # dirty is retried every tick and already warns), so this never becomes tick noise.
      def append_killed_records_prune_log(state, prune_result)
        return [] if prune_removed_counts(prune_result).values.sum.zero?

        append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: prune_summary_message(prune_result, prefix: "Pruned killed records:"),
          details: prune_result
        )
      end

      def get_state(command_id, command_type)
        accepted_result(command_id, command_type, nil, "Loaded Meringue state.", store.load, [])
      end

      # Reports the model/thinking pair future Pi heads and workers will use.
      # There is no slash command for it any more: the dashboard status line
      # already shows `Pi defaults: <model> · <thinking>` and `/config` prints
      # the same pair, so the typed `/defaults` was redundant surface. The
      # command stays because a head still proposes it for "show the defaults"
      # or "which model will future agents use", where the answer has to reach
      # the log with the clamp caveat attached.
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
            "Use /model <provider>/<model-id> to set the default for future sessions."
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

      # Shape validation only, and deliberately catalog-independent: a model the
      # cached catalog does not list is still settable (the catalog can be stale,
      # empty, unavailable, or simply behind a provider extension that added the
      # model), it is just labelled unverified in the accepted message.
      def set_default_session_model(command_id, command_type, payload)
        model_reference = value_at(payload, "model", "model_reference", "Model", "ModelReference")
        reason = Meringue::Harness::ModelReference.rejection_reason(model_reference)
        if reason
          return rejected_result(
            command_id,
            command_type,
            invalid_model_reference_message("Default Pi model", reason),
            ["model must be a provider/model id: #{reason}"]
          )
        end

        update_pi_session_defaults(
          command_id,
          command_type,
          model: Meringue::Harness::ModelReference.normalize(model_reference),
          changed_field: "model"
        )
      end

      def set_default_session_thinking_level(command_id, command_type, payload)
        requested = value_at(payload, "level", "thinking_level", "Level", "ThinkingLevel")
        level = requested.to_s.strip.downcase
        unless Meringue::Harness::PiClient::THINKING_LEVELS.include?(level)
          return rejected_result(
            command_id,
            command_type,
            invalid_thinking_level_message("Default Pi thinking level", requested),
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
        clamp_note = clamped_default_thinking_note(defaults, changed_field)
        unverified_note = unverified_default_model_note(defaults, changed_field)
        message = "Set the default Pi #{label} to #{value} for all future Pi heads and workers. " \
                  "Existing Pi sessions were not changed#{unchanged_ids.empty? ? "." : ": #{unchanged_ids.join(", ")}."}" \
                  "#{unverified_note ? " #{unverified_note}" : ""}" \
                  "#{clamp_note ? " #{clamp_note}" : ""}"
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

      # A level the model's catalog entry does not advertise is still saved: Pi
      # clamps it at spawn time, and a provider extension can under-declare what
      # its model really supports. Saying which level Pi will actually run keeps
      # the accepted result honest without refusing a level the user may set.
      def clamped_default_thinking_note(defaults, changed_field)
        return nil unless %w[thinking_level model].include?(changed_field)

        reference = defaults.fetch("model", nil).to_s.strip
        level = defaults.fetch("thinking_level", nil).to_s.strip.downcase
        return nil if reference.empty? || level.empty?

        snapshot = persisted_model_catalog(Meringue::Harness::Registry.public_provider_name("pi"))
        return nil unless snapshot

        supported = Meringue::Harness::ModelCatalog.coerce(snapshot, harness: "pi").thinking_levels_for(reference)
        supported = Array(supported).map { |value| value.to_s.downcase }
        return nil if supported.empty? || supported.include?(level)

        clamped = Meringue::Harness::PiClient.clamp_thinking_level(level, supported)
        "Pi's catalog does not list #{level} for #{reference}, so future Pi sessions run #{clamped} instead."
      end

      # `/model` used to reject with a bare "Default Pi model was not changed.",
      # so the reason lived only in the `errors` details and the user could not
      # tell a typo from an unknown id from an over-strict rule. This mirrors
      # `invalid_thinking_level_message`: the visible line names the reason and
      # the accepted grammar.
      def invalid_model_reference_message(subject, reason)
        "#{subject} was not changed: #{reason}. #{Meringue::Harness::ModelReference::FORMAT_HINT}"
      end

      # A well-formed id the cached catalog does not confirm is saved, not
      # refused: the catalog can be stale, empty, unavailable, or behind a
      # provider extension that added the model after the last fetch. Say so,
      # reusing the "unverified" wording the picker and completion already use
      # for a degraded catalog.
      def unverified_default_model_note(defaults, changed_field)
        return nil unless changed_field == "model"

        reference = defaults.fetch("model", nil).to_s.strip
        return nil if reference.empty?

        snapshot = persisted_model_catalog(Meringue::Harness::Registry.public_provider_name("pi"))
        catalog = Meringue::Harness::ModelCatalog.coerce(snapshot, harness: "pi")
        unless catalog.usable?
          return "Meringue has no confirmed Pi model list right now, so #{reference} is unverified; " \
                 "run /models refresh to check it. Pi validates it when the next Pi session starts."
        end
        return nil if catalog.entry_for(reference)

        "Pi's model list (confirmed #{catalog.fetched_at}) does not include #{reference}, so the id is unverified; " \
          "run /models refresh if it should be there. Pi validates it when the next Pi session starts."
      end

      # A bare "was not changed" left the user guessing which words are legal, so
      # the visible log line carries the ladder itself plus the obvious near-miss
      # for a truncated level such as "xhi". The valid set is the one the kernel
      # validates against, which is deliberately independent of the model catalog.
      def invalid_thinking_level_message(subject, requested)
        levels = Meringue::Harness::PiClient::THINKING_LEVELS
        typed = requested.to_s.strip
        reason = typed.empty? ? "a level is required" : "#{typed.inspect} is not a Pi thinking level"
        near_miss = closest_thinking_levels(typed)
        did_you_mean = near_miss.empty? ? nil : "Did you mean #{near_miss.join(" or ")}?"
        [
          "#{subject} was not changed: #{reason}.",
          did_you_mean,
          "Valid levels: #{levels.join(", ")}."
        ].compact.join(" ")
      end

      # Only an unambiguous near-miss is worth naming; the full ladder follows in
      # the same message, so "m" does not need "minimal or medium or max".
      def closest_thinking_levels(typed)
        candidate = typed.to_s.strip.downcase
        return [] if candidate.empty?

        matches = Meringue::Harness::PiClient::THINKING_LEVELS.select do |level|
          level.start_with?(candidate) || candidate.start_with?(level) || level.include?(candidate)
        end
        matches.length > 2 ? [] : matches
      end

      def pi_session_defaults_message(defaults)
        model = defaults.fetch("model", nil) || "mixed by role"
        thinking = defaults.fetch("thinking_level", nil) || "mixed by role"
        clamp_note = clamped_default_thinking_note(defaults, "thinking_level")
        [
          "Future Pi heads and workers use #{model} with thinking #{thinking}.",
          clamp_note,
          "Existing sessions keep their own effective settings."
        ].compact.join(" ")
      end

      def set_session_model(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "target_id", "AgentID", "TargetID")
        model_reference = value_at(payload, "model", "model_reference", "Model", "ModelReference")
        reason = Meringue::Harness::ModelReference.rejection_reason(model_reference)
        if reason
          return rejected_result(
            command_id,
            command_type,
            invalid_model_reference_message("Session model", reason),
            ["model must be a provider/model id: #{reason}"]
          )
        end

        model_reference = Meringue::Harness::ModelReference.normalize(model_reference)
        state = normalized_state
        agent, rejection = session_settings_target(state, command_id, command_type, agent_id)
        return rejection if rejection

        previous = deep_copy(agent.fetch("session_settings", {}) || {})
        client = harness_client_for_agent(agent)
        outcome = client.set_session_model(agent_session_ref(agent), model_reference)
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
        if blank?(level)
          return rejected_result(
            command_id,
            command_type,
            invalid_thinking_level_message("Session thinking level", level),
            ["thinking level must be one of: #{Meringue::Harness::PiClient::THINKING_LEVELS.join(", ")}"]
          )
        end

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

      # Records that first-run setup finished (or was skipped) so the TUI stops
      # opening it by itself. The flow itself writes nothing: it applies each
      # choice as an ordinary kernel command and ends with this one, so the kernel
      # stays the only writer of the config file and the marker is journaled and
      # logged like every other command.
      #
      # Deliberately not head-proposable: it is UI lifecycle, like `/jump` and the
      # pickers, and a head has no way to know whether a human saw the flow.
      def complete_onboarding(command_id, command_type, payload)
        requested = value_at(payload, "outcome", "Outcome")
        outcome = requested.to_s.strip.downcase
        outcome = "completed" if outcome.empty?
        unless Config::ONBOARDING_OUTCOMES.include?(outcome)
          return rejected_result(
            command_id,
            command_type,
            "First-run setup was not recorded.",
            ["outcome must be one of: #{Config::ONBOARDING_OUTCOMES.join(", ")}"]
          )
        end

        version = Config::ONBOARDING_VERSION
        Config.save_onboarding!(outcome: outcome, version: version, path: config_path)

        state = normalized_state
        message = if outcome == "skipped"
                    "Skipped first-run setup. It will not open again; run /setup any time."
                  else
                    "Completed first-run setup."
                  end
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: message,
          details: { "outcome" => outcome, "onboarding_version" => version, "config_path" => config_path }
        )
        touch_state!(state)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          outcome,
          "#{message} Saved to #{config_path}.",
          { "outcome" => outcome, "onboarding_version" => version, "config_path" => config_path },
          log_ids
        )
      rescue Config::ParseError => e
        rejected_result(command_id, command_type, "First-run setup was not recorded because config could not be read.", [e.message])
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
        target = find_agent(state, target_id) || find_goal(state, target_id) || find_issue(state, target_id) || find_project(state, target_id)
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

      def unapplied_head_ids_for_issue_visibility(state)
        state.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "head" && !State::Models.head_result_applied?(agent) &&
            !%w[blocked errored killed].include?(agent.fetch("status", nil).to_s)
        end.map { |agent| agent.fetch("id", nil) }.compact
      end

      def spawn_head(command_id, command_type, payload)
        user_message = value_at(payload, "user_message", "UserMessage", "message")
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        requested_selected_target = value_at(payload, "selected_target", "SelectedTarget", "selectedTarget")
        # Internally routed heads (for example the head spawned for an answered question) carry a
        # long structured prompt. The visible chat log should stay short and human-facing.
        log_message = present_string(value_at(payload, "log_message", "LogMessage"))
        log_source_type = present_string(value_at(payload, "_log_source_type", "log_source_type"))
        log_source_type = "user" unless %w[user kernel system].include?(log_source_type)
        log_source_id = present_string(value_at(payload, "_log_source_id", "log_source_id"))
        retry_of = head_retry_lineage(payload)
        completion_trigger = head_completion_trigger_lineage(payload)
        errors = []

        errors << "user_message is required" if blank?(user_message)
        return synchronized_state { rejected_result(command_id, command_type, "Head was not spawned.", errors) } unless errors.empty?

        # Selecting a failed head in the AgentTree and typing a message is a retry of that head,
        # not an unrelated new goal. Resolved before the spawn so the retry owns the whole command
        # (it may resume the failed head's own session instead of starting a new one).
        if retry_of.nil? && (retry_target = selected_head_retry_target(requested_selected_target))
          return retry_head(command_id, command_type, retry_target, instruction: user_message.to_s, log_message: log_message)
        end

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
            retry_of: retry_of,
            completion_trigger: completion_trigger,
            snapshot_issue_ids: state.fetch("issues").map { |issue| issue.fetch("id", nil) }.compact,
            snapshot_project_ids: state.fetch("projects").map { |project| project.fetch("id", nil) }.compact,
            snapshot_unapplied_head_ids: unapplied_head_ids_for_issue_visibility(state),
            snapshot_counters: deep_copy(state.fetch("counters", {}))
          )
          state.fetch("agents") << agent

          log_ids = append_log(
            state,
            source_type: log_source_type,
            source_id: log_source_type == "user" ? nil : log_source_id,
            level: "info",
            message: log_message || user_message.to_s.strip,
            details: {
              "head_id" => head_id,
              "question_id" => present_string(question_id),
              "retry_of_head_id" => retry_of && retry_of.fetch("head_id", nil),
              **selected_target_log_details(selected_target)
            }.compact
          )
          # Lineage is recorded next to the prompt that caused it, so the log reads
          # "<your message>" then "Retrying head H13 as H14 ..." in order.
          log_ids.concat(record_head_retry_respawn!(state, retry_of, head_id)) if retry_of
          log_ids.concat(log_unretryable_head_selection(state, selected_target, head_id))
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

      # Retrying a head re-runs the request it never finished routing. Heads stay stateless per
      # user message, so a retry is either the same session finishing its interrupted turn (when
      # the head errored mid-turn and its harness session is still there) or a fresh head carrying
      # the original request plus whatever the user just typed. The head contract is unchanged:
      # the retry still returns HeadResult JSON and is never turned into a worker by this path.
      #
      # Both user entry points land here: selecting a failed head in the AgentTree and typing a
      # message (SpawnHead with that selection) and `/prompt H13 "..."` (PromptAgent on a head id).
      def retry_head(command_id, command_type, head, instruction: nil, log_message: nil)
        head_id = head.is_a?(Hash) ? head.fetch("id", nil).to_s : head.to_s
        plan = synchronized_state { head_retry_plan(normalized_state, head_id, instruction: instruction) }
        unless plan.fetch("eligible")
          return synchronized_state do
            rejected_result(command_id, command_type, plan.fetch("message"), [plan.fetch("code")])
          end
        end

        if plan.fetch("strategy") == "resume"
          resumed = resume_head_retry(command_id, command_type, plan, instruction: instruction, log_message: log_message)
          return resumed if resumed
        end

        respawn_head_retry(command_id, command_type, plan, instruction: instruction, log_message: log_message)
      end

      # What a retry of this head would do right now, or why it cannot happen. Pure: it reads the
      # supplied state and never locks, so it can be called from inside a synchronized section.
      def head_retry_plan(state, head_id, instruction: nil)
        head = find_agent(state, head_id.to_s)
        unless head
          return { "eligible" => false, "code" => "agent_not_found", "message" => missing_agent_prompt_message(head_id) }
        end
        unless head.fetch("type", nil) == "head"
          return { "eligible" => false, "code" => "agent_is_not_head", "message" => "Agent #{head.fetch("id")} is not a head." }
        end

        resolved_id = head.fetch("id").to_s
        status = head.fetch("status", nil).to_s
        unless State::Models.head_retry_target?(head)
          return {
            "eligible" => false,
            "code" => head_retry_rejection_code(head),
            "message" => head_retry_rejection_message(resolved_id, status, head)
          }
        end

        request = head_request_in_state(state, head) || {}
        original_message = present_string(request.fetch("user_message", nil))
        if original_message.nil? && blank?(instruction)
          return {
            "eligible" => false,
            "code" => "head_request_unavailable",
            "message" => "Head #{resolved_id} has no recorded request to retry; send your message as a new prompt instead."
          }
        end

        failure = head_retry_failure_case(head)
        {
          "eligible" => true,
          "head_id" => resolved_id,
          "status" => status,
          "case" => failure.fetch("case"),
          "reason" => failure.fetch("reason"),
          "strategy" => failure.fetch("resumable") ? "resume" : "respawn",
          "user_message" => original_message,
          "question_id" => present_string(request.fetch("question_id", nil)),
          # What the failed batch already did, straight from its command journal. The retry head
          # is told both halves so it can route what is missing without re-proposing work that
          # already landed.
          "applied_commands" => head_retry_command_digest(State::Models.head_applied_commands(head)),
          "unrouted_commands" => head_retry_command_digest(State::Models.head_unrouted_commands(head))
        }
      end

      # The distinct ways a head stops without routing, each of which needs a different recovery:
      #   transport_failure  its turn died mid-flight and its session is still open -> resume it
      #   session_released   it failed and the kernel already closed its session    -> fresh head
      #   never_started      no harness session was ever opened for it              -> fresh head
      #   killed             the user stopped it on purpose, so its session is gone -> fresh head
      #   nothing_routed     its batch was applied and not one command landed       -> fresh head
      #   partially_routed   its batch was applied and only part of it landed       -> fresh head
      #
      # The two applied cases are never resumed, even when the head's harness session is still
      # open: that session already delivered a result, the kernel journaled and sealed the batch,
      # and the exactly-once guard in `apply_head_result` would ignore a second result from it.
      # Their retry is always a fresh head that routes what the batch left unrouted.
      def head_retry_failure_case(head)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        detail = head_failure_detail(metadata)
        suffix = detail ? " (#{detail})" : ""

        return applied_batch_retry_failure_case(head) if State::Models.head_result_applied?(head)

        if head.fetch("status", nil) == "killed"
          return { "case" => "killed", "reason" => "you killed it before it routed this request", "resumable" => false }
        end
        unless agent_has_session_reference?(head)
          return { "case" => "never_started", "reason" => "it never started an agent session#{suffix}", "resumable" => false }
        end
        if metadata.fetch("head_session_state", nil) == HEAD_SESSION_STATE_RELEASED
          return { "case" => "session_released", "reason" => "it failed before returning a result#{suffix}", "resumable" => false }
        end

        {
          "case" => "transport_failure",
          "reason" => "its agent turn ended before it returned a result#{suffix}",
          "resumable" => head_retry_session_resumable?(head)
        }
      end

      # A head whose result was applied is `blocked` because the kernel rejected or failed part of
      # its batch. That is not a head failure at all: the head routed, the kernel refused, and the
      # user's request is the thing left stranded. The reason says how much of it survived, because
      # that is what the user reads in the retry log line.
      def applied_batch_retry_failure_case(head)
        applied = State::Models.head_applied_commands(head)
        unrouted = State::Models.head_unrouted_commands(head)
        total = applied.length + unrouted.length
        if applied.any?
          return {
            "case" => "partially_routed",
            "reason" => "only #{applied.length} of its #{total} commands landed, so the rest of this request was never routed",
            "resumable" => false
          }
        end

        reason = if total.zero?
                   "its result routed nothing"
                 else
                   "none of its #{total} #{total == 1 ? "command" : "commands"} landed, so this request was never routed"
                 end
        { "case" => "nothing_routed", "reason" => reason, "resumable" => false }
      end

      # Compact per-command history for the retry head's prompt. A journal entry carries the whole
      # command result, so only the parts that explain what happened are carried over.
      def head_retry_command_digest(entries)
        Array(entries).map do |entry|
          {
            "command_type" => entry.fetch("command_type", nil),
            "status" => entry.fetch("status", nil),
            "target_id" => present_string(entry.fetch("target_id", nil)),
            "message" => present_string(entry.fetch("message", nil)) && single_line_excerpt(entry.fetch("message"), limit: 240),
            "errors" => Array(entry.fetch("errors", [])).map { |error| single_line_excerpt(error, limit: 120) }
          }.compact
        end
      end

      def head_retry_command_line(entry)
        line = "#{entry.fetch("command_type", nil) || "command"} #{entry.fetch("status", nil) || "unknown"}"
        target = present_string(entry.fetch("target_id", nil))
        line += " -> #{target}" if target
        detail = present_string(entry.fetch("message", nil)) || present_string(Array(entry.fetch("errors", [])).join("; "))
        line += ": #{detail}" if detail
        line
      end

      def head_failure_detail(metadata)
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile = {} unless reconcile.is_a?(Hash)
        detail = present_string(metadata.fetch("error_message", nil)) || present_string(reconcile.fetch("error_message", nil))
        detail && truncate_for_state(detail, 200)
      end

      # A head session is only resumable while it still exists: a released session was killed by
      # the kernel when the head failed, and an unavailable one was never backed by a harness.
      def head_retry_session_resumable?(head)
        return false unless agent_has_session_reference?(head)

        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        session_state = metadata.fetch("head_session_state", nil).to_s
        return false if [HEAD_SESSION_STATE_RELEASED, HEAD_SESSION_STATE_UNAVAILABLE].include?(session_state)

        client = begin
          harness_client_for_agent(head)
        rescue StandardError
          nil
        end
        !!client && client.respond_to?(:prompt_session)
      end

      def head_retry_rejection_code(head)
        case head.fetch("status", nil).to_s
        when "queued", "working", "idle" then "head_still_working"
        else "head_already_routed"
        end
      end

      # A refusal must leave the user with a next action, and reaching one should be rare. Only two
      # refusals survive: a head that has not stopped routing yet, and a head that really did route
      # everything it proposed (so there is nothing left to re-run).
      def head_retry_rejection_message(head_id, status, head)
        if %w[queued working idle].include?(status)
          return "Head #{head_id} is still #{status} on its request, so there is nothing to retry yet. " \
                 "Send your message on its own, or kill #{head_id} first."
        end

        applied = State::Models.head_applied_commands(head)
        if applied.any?
          "Head #{head_id} already routed this request: all #{applied.length} of its commands were applied. Prompt the worker it created, or send your message as a new prompt."
        elsif State::Models.head_result_applied?(head)
          "Head #{head_id} answered this request with a question instead of routing it, so there is nothing to re-run. Answer it with /answer, or send your message as a new prompt."
        else
          "Head #{head_id} is #{status} and cannot be retried. Send your message as a new prompt instead."
        end
      end

      # Resume path: the head's own session is still there, so the cheapest correct retry is to let
      # it finish the turn that died. Returns nil when resuming is impossible, which makes the
      # caller fall back to a fresh head instead of losing the user's message.
      def resume_head_retry(command_id, command_type, plan, instruction: nil, log_message: nil)
        head_id = plan.fetch("head_id")
        head = synchronized_state do
          record = find_agent(normalized_state, head_id)
          record ? deep_copy(record) : nil
        end
        return nil unless head

        client = harness_client_for_agent(head)
        return nil unless client.respond_to?(:prompt_session)

        session_ref = client.prompt_session(
          agent_session_ref(head),
          head_retry_resume_prompt(plan, instruction),
          mode: "normal"
        )

        synchronized_state do
          state = normalized_state
          current = find_agent(state, head_id)
          return nil unless current

          now = timestamp
          merge_session_ref_into_agent!(current, session_ref)
          current["status"] = "working"
          current["updated_at"] = now
          mark_head_session_active!(current, now: now)
          current["harness_metadata"] = clear_head_failure_metadata(current.fetch("harness_metadata", {}) || {}).merge(
            "retry_strategy" => "resume",
            "retry_case" => plan.fetch("case"),
            "head_retry_count" => head_retry_count(current) + 1,
            "head_retried_at" => now
          )
          message = "Retried head #{head_id} by resuming its agent session; it will return a new HeadResult."
          log_ids = append_head_retry_prompt_log(state, head_id, instruction: instruction, log_message: log_message)
          log_ids.concat(append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "info",
            message: message,
            details: {
              "head_id" => head_id,
              "retry_strategy" => "resume",
              "retry_case" => plan.fetch("case"),
              "reason" => plan.fetch("reason"),
              "routing_action" => "head_retry"
            }
          ))
          touch_state!(state, now)
          store.save(state)

          accepted_result(command_id, command_type, head_id, message, deep_copy(current), log_ids)
        end
      rescue StandardError => e
        synchronized_state do
          state = normalized_state
          append_log(
            state,
            source_type: "head",
            source_id: plan.fetch("head_id"),
            level: "warning",
            message: "Could not resume head #{plan.fetch("head_id")}'s agent session (#{sanitized_error_message(e)}); retrying it with a fresh head.",
            details: { "head_id" => plan.fetch("head_id"), "error" => error_payload(e), "routing_action" => "head_retry" }
          )
          touch_state!(state)
          store.save(state)
        end
        nil
      end

      # Respawn path: a fresh head runs the failed head's original request plus whatever the user
      # typed. This is the normal outcome, because the kernel closes a head's session when it fails.
      def respawn_head_retry(command_id, command_type, plan, instruction: nil, log_message: nil)
        head_id = plan.fetch("head_id")
        result = spawn_head(
          command_id,
          command_type,
          {
            "user_message" => head_retry_user_message(plan, instruction),
            "log_message" => log_message || present_string(instruction) || "Retry head #{head_id}.",
            "question_id" => plan.fetch("question_id", nil),
            "_retry_of_head_id" => head_id,
            "_retry_case" => plan.fetch("case"),
            "_retry_reason" => plan.fetch("reason")
          }.compact
        )
        return result unless result.fetch("status", nil) == "accepted"

        result.merge("message" => "Retried head #{head_id} as head #{result.fetch("target_id", nil)}.")
      end

      # The retry head is a fresh stateless head, so everything it needs has to be in its message:
      # the request that was never routed, what the failed batch already applied (which it must not
      # propose again), what never landed and why, the new instruction, and why it is running again.
      def head_retry_user_message(plan, instruction)
        original = present_string(plan.fetch("user_message", nil))
        extra = present_string(instruction)
        extra = nil if original && extra && extra.strip == original.strip
        return extra.to_s if original.nil?

        applied = Array(plan.fetch("applied_commands", []))
        lines = [
          "Retry of head #{plan.fetch("head_id")}, which stopped before routing this request because #{plan.fetch("reason")}.",
          "",
          "Original user message:",
          original
        ]
        lines.concat(head_retry_landed_command_lines(applied))
        lines.concat(head_retry_unrouted_command_lines(Array(plan.fetch("unrouted_commands", []))))
        lines.concat(["", "New instruction from the user:", extra]) if extra
        lines.concat(["", head_retry_closing_instruction(applied)])
        lines.join("\n")
      end

      # Retrying a partially applied batch must not route the same work twice, and the kernel does
      # not re-run journal entries: a retry re-routes the request. So the records that already exist
      # are named for the retry head, which reuses them the same way it reuses any existing issue or
      # worker it can see in state.
      def head_retry_landed_command_lines(applied)
        return [] if applied.empty?

        [
          "",
          "Its previous attempt already applied these commands, and that work exists in state now. " \
            "Reuse those records and never propose them again:",
          *applied.map { |entry| "- #{head_retry_command_line(entry)}" }
        ]
      end

      def head_retry_unrouted_command_lines(unrouted)
        return [] if unrouted.empty?

        [
          "",
          "These commands never landed, so that part of the request is still unrouted. Read current " \
            "state first, then fix what the kernel objected to instead of resending the same command:",
          *unrouted.map { |entry| "- #{head_retry_command_line(entry)}" }
        ]
      end

      def head_retry_closing_instruction(applied)
        return "Route this request now." if applied.empty?

        "Route only the part of this request that is still unrouted, reusing the records above."
      end

      def head_retry_resume_prompt(plan, instruction)
        extra = present_string(instruction)
        extra = nil if extra && present_string(plan.fetch("user_message", nil))&.strip == extra.strip
        prompt = HEAD_RESUME_PROMPT.dup
        prompt << "\nNew instruction from the user: #{extra}\n" if extra
        prompt
      end

      # Retry lineage handed from `respawn_head_retry` to `spawn_head` through the payload.
      def head_retry_lineage(payload)
        head_id = present_string(value_at(payload, "_retry_of_head_id", "retry_of_head_id"))
        return nil unless head_id

        {
          "head_id" => head_id,
          "case" => present_string(value_at(payload, "_retry_case", "retry_case")),
          "reason" => present_string(value_at(payload, "_retry_reason", "retry_reason"))
        }.compact
      end

      # Completion-triggered heads are spawned internally by the kernel, but the head record should
      # still explain why it exists so reconciliation can recover without spawning a duplicate.
      def head_completion_trigger_lineage(payload)
        trigger = value_at(payload, "_completion_trigger", "completion_trigger")
        return nil unless trigger.is_a?(Hash)

        trigger.each_with_object({}) do |(key, value), result|
          next if value.nil?

          result[key.to_s] = value
        end.compact
      end

      # Links the failed head to its successor and says so once, in the log, at the point the
      # retry happened.
      def record_head_retry_respawn!(state, retry_of, new_head_id)
        previous_id = retry_of.fetch("head_id")
        previous = find_agent(state, previous_id)
        now = timestamp
        if previous
          previous["harness_metadata"] = (previous.fetch("harness_metadata", {}) || {}).merge(
            "retried_by_head_id" => new_head_id,
            "head_retry_count" => head_retry_count(previous) + 1,
            "head_retried_at" => now
          )
          previous["updated_at"] = now
        end

        # A head that already delivered a result can never deliver another one the kernel would
        # accept: its batch is journaled and sealed by the exactly-once guard, and reconciliation
        # stops polling it once `head_result_applied_at` is set. The harness session it still owns
        # is therefore dead weight, so the retry hands the request to a fresh head and closes it
        # instead of leaving a live session behind for every blocked head in the tree.
        session_release = if previous && State::Models.head_result_applied?(previous)
                            release_head_session!(previous, reason: "head_retried", now: now)
                          end

        reason = retry_of.fetch("reason", nil)
        append_log(
          state,
          source_type: "kernel",
          source_id: previous_id,
          level: "info",
          message: "Retrying head #{previous_id} as head #{new_head_id}#{reason ? ": #{reason}" : ""}. Re-running its original request.",
          details: {
            "head_id" => new_head_id,
            "retry_of_head_id" => previous_id,
            "retry_strategy" => "respawn",
            "retry_case" => retry_of.fetch("case", nil),
            "head_record_missing" => previous ? nil : true,
            "previous_head_session_released" => session_release && session_release.fetch("changed", false) ? true : nil,
            "routing_action" => "head_retry"
          }.compact
        )
      end

      # A selected head that cannot be retried must not silently swallow the user's message. The
      # message is routed as a new request and the log says why the selection was not a retry.
      def log_unretryable_head_selection(state, selected_target, head_id)
        return [] unless selected_target.is_a?(Hash)
        return [] unless selected_target.fetch("selected_type", nil) == "head"

        note = present_string(selected_target.fetch("head_retry_note", nil))
        return [] unless note

        append_log(
          state,
          source_type: "kernel",
          source_id: selected_target.fetch("selected_id"),
          level: "warning",
          message: "#{note} Routed this message to new head #{head_id} instead.",
          details: {
            "head_id" => head_id,
            "selected_target_id" => selected_target.fetch("selected_id"),
            "routing_action" => "selected_target"
          }
        )
      end

      def head_retry_count(head)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        metadata.fetch("head_retry_count", 0).to_i
      end

      # A resumed head is working again, so the failure that stopped it is history. Clearing the
      # terminal reconcile marker is what lets reconciliation poll the session and apply its result.
      def clear_head_failure_metadata(metadata)
        metadata = {} unless metadata.is_a?(Hash)
        cleared = metadata.dup
        previous = {
          "error_class" => cleared.delete("error_class"),
          "error_message" => cleared.delete("error_message"),
          "errored_at" => cleared.delete("errored_at"),
          "reconcile" => cleared.delete("reconcile")
        }.compact
        cleared.delete("reconcile_state")
        cleared["previous_head_failure"] = previous unless previous.empty?
        cleared
      end

      # The user's own words still belong in the visible chat log on the resume path, where no new
      # head record (and therefore no `SpawnHead` prompt log) is created.
      def append_head_retry_prompt_log(state, head_id, instruction:, log_message:)
        message = present_string(log_message) || present_string(instruction)
        return [] unless message

        append_log(
          state,
          source_type: "user",
          source_id: nil,
          level: "info",
          message: message,
          details: {
            "head_id" => head_id,
            "agent_id" => head_id,
            "retry_of_head_id" => head_id,
            "routing_action" => "head_retry"
          }
        )
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
                when "PromptAgent" then prompt_agent_head_guard(head, payload)
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

      # Prompting a head retries it by spawning another head. That is a user recovery action, not
      # something a head may trigger: a head spawning heads is exactly the loop the stateless head
      # contract exists to prevent.
      def prompt_agent_head_guard(head, payload)
        target_id = present_string(value_at(payload, "agent_id", "AgentID", "agentId"))
        return nil unless target_id

        target = synchronized_state { find_agent(normalized_state, target_id) }
        return nil unless target && target.fetch("type", nil) == "head"

        {
          "message" => "Head #{head.fetch("id", nil)} may not prompt head #{target.fetch("id")}; only the user can retry a head.",
          "errors" => ["head_cannot_prompt_head"]
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
        kind, record = %w[agent issue project question goal].filter_map do |candidate_kind|
          found = case candidate_kind
                  when "agent" then find_agent(state, target_id)
                  when "issue" then find_issue(state, target_id)
                  when "project" then find_project(state, target_id)
                  when "goal" then find_goal(state, target_id)
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
          provisioning = worker_provisioning_info(record)
          info["provisioning"] = provisioning if provisioning
        end
        if kind == "issue"
          info["goals"] = goals_for_issue_ids(state, [record.fetch("id", target_id)]).map { |goal| goal_status_summary(goal) }
        end
        info["goal_summary"] = goal_status_summary(record) if kind == "goal"

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

      # One prune pass is one visible line. The counts cover every record class the pass touched:
      # issues, *every* agent record removed with them (workers bundled with an issue plus
      # standalone/head records, not just the standalone ones), the managed worktrees actually
      # removed, and projects. Counting only standalone agents used to report "0 standalone agents"
      # for a pass that had just deleted five workers and their worktrees, while the worktree
      # removals printed one info line each.
      def prune_summary_message(prune_result, prefix: "Pruned")
        issues, agents, worktrees, projects = prune_count_phrases(prune_result)
        "#{prefix} #{issues}, #{agents}, #{worktrees}, and #{projects}."
      end

      def prune_count_phrases(prune_result)
        prune_removed_counts(prune_result).map { |noun, count| count_phrase(count, noun) }
      end

      def prune_removed_counts(prune_result)
        {
          "issue" => Array(prune_result.fetch("removed_issue_ids", [])).length,
          "agent" => Array(prune_result.fetch("removed_agent_ids", [])).length,
          "worktree" => removed_worktree_agent_ids(prune_result).length,
          "project" => Array(prune_result.fetch("removed_project_ids", [])).length
        }
      end

      # Only worktrees this pass actually deleted are counted. `already_removed` is a confirmation,
      # not a removal, and `skipped` workspaces (project root, dedicated directory) were never
      # Meringue-managed worktrees.
      def removed_worktree_agent_ids(prune_result)
        recorded = prune_result.fetch("removed_worktree_agent_ids", nil)
        return Array(recorded) if recorded

        Array(prune_result.fetch("workspace_cleanup_outcomes", [])).filter_map do |outcome|
          outcome.fetch("agent_id", nil) if outcome.fetch("status", nil) == "removed"
        end
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
      #
      # This runs on every ~2s reconcile tick, so it must never behave like a batch job. The same
      # rule `/prune` follows applies here and matters more, because nothing asked for this work:
      # read which URLs are due under the lock, talk to the forge with the lock released, then
      # reacquire it to merge. Holding the state lock across `gh` froze every kernel command
      # (submitting a prompt, applying a HeadResult, settling a worker) for the length of the
      # whole burst.
      def refresh_stale_delivery_pull_requests
        # Capped so a long backlog costs several cheap ticks instead of one long stall.
        due_urls = due_delivery_pull_request_urls.first(DELIVERY_PULL_REQUEST_REFRESH_BATCH_LIMIT)
        return [] if due_urls.empty?

        statuses = fetch_delivery_pull_request_statuses(due_urls)
        return [] if statuses.empty?

        apply_delivery_pull_request_statuses(statuses)
      end

      # Locked, cheap, and read-only: which verified delivery PR URLs are due right now.
      def due_delivery_pull_request_urls
        synchronized_state do
          now = timestamp
          normalized_state.fetch("issues").flat_map do |issue|
            State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).filter_map do |record|
              url = present_string(State::Models.pull_request_record_url(record))
              next if blank?(url) || !delivery_pull_request_refresh_due?(record, now)

              url
            end
          end.uniq
        end
      end

      # Unlocked and bounded. One shared deadline covers the whole batch, so an unreachable forge
      # costs one budget instead of one timeout per URL. URLs left over when the budget runs out are
      # simply not refreshed this tick; they stay due and are retried on a later tick.
      def fetch_delivery_pull_request_statuses(urls)
        deadline = monotonic_time + [delivery_pull_request_refresh_budget, 0.0].max
        urls.each_with_object({}) do |url, statuses|
          remaining = deadline - monotonic_time
          break statuses unless remaining.positive?

          statuses[url] = delivery_pull_request_status(url, timeout: remaining)
        end
      end

      # A raising lookup is answered as `unknown` rather than aborting the batch. The apply phase
      # already treats `unknown` as "forge unavailable, keep the last known state", and stamping
      # `last_checked_at` is what stops one permanently broken URL from occupying a batch slot on
      # every tick and starving the records behind it.
      def delivery_pull_request_status(url, timeout:)
        invoke_forge_status_lookup(url, timeout: timeout)
      rescue StandardError => e
        {
          "provider" => "github",
          "url" => url.to_s,
          "state" => "unknown",
          "error" => sanitized_error_message(e)
        }
      end

      # Locked again, and against current state rather than the snapshot the URLs came from: an
      # issue pruned or a record replaced during the forge call is simply skipped.
      def apply_delivery_pull_request_statuses(statuses)
        synchronized_state do
          state = normalized_state
          now = timestamp
          refreshes = state.fetch("issues").flat_map do |issue|
            State::Models.merge_pull_request_records(State::Models.pull_request_records_from(issue)).filter_map do |record|
              url = present_string(State::Models.pull_request_record_url(record))
              next if blank?(url) || !statuses.key?(url)

              status = statuses.fetch(url)
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

        Time.iso8601(now) - Time.iso8601(checked_at.to_s) >= delivery_pull_request_refresh_interval(record)
      rescue ArgumentError, TypeError
        true
      end

      # Records refreshed together are stamped with the same `last_checked_at`, so a fixed interval
      # makes them all fall due on the same tick forever: one synchronized burst every interval
      # instead of a trickle. A deterministic per-URL spread keeps each record on its own schedule
      # without storing extra scheduling state.
      def delivery_pull_request_refresh_interval(record)
        url = record.is_a?(Hash) ? State::Models.pull_request_record_url(record).to_s : ""
        DELIVERY_PULL_REQUEST_REFRESH_INTERVAL_SECONDS +
          (Zlib.crc32(url) % DELIVERY_PULL_REQUEST_REFRESH_SPREAD_SECONDS)
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
          # (possibly on another issue) with nothing to wait for. The same applies to a completed
          # worker whose completion still has a head-routing continuation to fire.
          deferred_dependents = waiting_deferred_dependents(state, workers.map { |worker| worker.fetch("id", nil) })
          completion_continuations = workers.select { |worker| pending_completion_continuation?(worker) }
          # A live goal loop is retained work: pruning its issue would delete the loop, its
          # iteration history, and the worktrees it is still measuring.
          active_goals = goals_for_issue_ids(state, subtree_ids).select { |goal| Goals::Record.loop_active?(goal) }
          blockers = []
          blockers << "nonterminal_issues" if nonterminal_issue_ids.any?
          blockers << "unresolved_workers" if blocking_workers.any?
          blockers << "open_questions" if open_questions.any?
          blockers << "unsettled_pull_requests" if pull_request_blockers.any?
          blockers << "pending_deferred_dependents" if deferred_dependents.any?
          blockers << "pending_completion_continuations" if completion_continuations.any?
          blockers << "active_goals" if active_goals.any?

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
            "completion_continuation_worker_ids" => completion_continuations.map { |worker| worker.fetch("id", nil) }.compact,
            "open_question_ids" => open_questions.map { |question| question.fetch("id", nil) }.compact,
            "active_goal_ids" => active_goals.map { |goal| goal.fetch("id", nil) }.compact,
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
        # A goal cannot outlive the issue it controls, or it would keep driving a record that
        # no longer exists.
        removed_goal_ids = goals_for_issue_ids(state, issue_ids_to_remove).map { |goal| goal.fetch("id", nil) }.compact
        state["goals"] = state.fetch("goals", []).reject { |goal| removed_goal_ids.include?(goal.fetch("id", nil)) }
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
          "removed_goal_ids" => removed_goal_ids,
          "removed_standalone_agent_ids" => standalone_agent_ids,
          "removed_project_ids" => removed_project_ids,
          "updated_project_ids" => updated_project_ids,
          "released_head_session_agent_ids" => released_head_ids,
          "workspace_cleanup_outcomes" => workspace_cleanups,
          "removed_worktree_agent_ids" => workspace_cleanups.filter_map do |outcome|
            outcome.fetch("agent_id", nil) if outcome.fetch("status", nil) == "removed"
          end,
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

          # A worker whose worktree was taken over by a successor no longer owns it, so pruning it
          # removes only its record. Without this, the shared checkout would either be deleted from
          # under the successor or block the predecessor's record forever, one warning per pass.
          if worker_workspace_handed_over?(state, worker)
            outcome = handed_over_workspace_cleanup_outcome(worker, now)
            worker["harness_metadata"] = (worker.fetch("harness_metadata", {}) || {}).merge("workspace_cleanup" => outcome)
            next outcome.merge("log_entry_ids" => [])
          end

          protected_paths = state.fetch("agents").filter_map do |other|
            next unless other.fetch("type", nil) == "worker" && other.fetch("id", nil) != agent_id
            # The successor is listed separately, so a handed-over predecessor must not protect a
            # path it no longer owns: that would leak the worktree when the issue is pruned.
            next if worker_workspace_handed_over?(state, other)

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

      def worker_workspace_handed_over?(state, worker)
        successor_id = present_string(worker.fetch("replaced_by_agent_id", nil)) ||
                       present_string(worker_session_recovery(worker).fetch("restarted_by_agent_id", nil))
        return false unless successor_id

        successor = find_agent(state, successor_id)
        return false unless successor.is_a?(Hash) && successor.fetch("type", nil) == "worker"

        root = worker_worktree_root_path(worker)
        !!present_string(root) && worker_worktree_root_path(successor) == root
      end

      def handed_over_workspace_cleanup_outcome(worker, now)
        {
          "agent_id" => worker.fetch("id", nil),
          "issue_id" => worker.fetch("issue_id", nil),
          "project_id" => worker.fetch("project_id", nil),
          "status" => "skipped",
          "reason" => "workspace_handed_over_to_successor",
          "success" => true,
          "attempted" => false,
          "worktree_root_path" => worker_worktree_root_path(worker),
          "workspace_branch" => worker.fetch("workspace_branch", nil),
          "successor_agent_id" => present_string(worker.fetch("replaced_by_agent_id", nil)) ||
            present_string(worker_session_recovery(worker).fetch("restarted_by_agent_id", nil)),
          "checked_at" => now
        }.compact
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

      # Only cleanups the user may have to act on get their own line. A successful removal (or a
      # confirmation that the worktree was already gone, or a workspace that was never a managed
      # worktree) is counted by the pass summary instead, so one prune of five workers is one log
      # line rather than six. The per-worker outcome is not lost: it is written to the worker's
      # `harness_metadata.workspace_cleanup` and returned in the pass's `workspace_cleanup_outcomes`,
      # which the prune log details and the command result both carry.
      def append_workspace_cleanup_log(state, worker, outcome)
        return [] if outcome.fetch("success", false)
        return [] if outcome.fetch("status", "failed") == "skipped"

        message = "Retained worker #{worker.fetch("id")} because its managed worktree could not be " \
                  "removed: #{outcome.fetch("reason", "unknown_error")}."
        append_log(
          state,
          source_type: "kernel",
          source_id: worker.fetch("id"),
          level: "warning",
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
          "name" => project_display_name(name) || default_project_name(expanded_path),
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

      # ModifyProject is the only command that renames a project (ModifyIssue retitles an issue).
      # A `Rename` wrapper used to sit above this method and sniff whether a bare target id was a
      # project or an issue, but it existed only to back the removed `/rename <id> "<name>"` slash
      # command, so renaming is now always the explicit command for the record kind being changed.
      def modify_project(command_id, command_type, payload)
        project_id = value_at(payload, "project_id", "ProjectID", "projectId", "target_id", "TargetID", "targetId")
        name = value_at(payload, "name", "Name", "title", "Title")
        errors = []

        errors << "project_id is required" if blank?(project_id)
        errors << "name is required" if blank?(name)
        return rejected_result(command_id, command_type, "Project was not renamed.", errors) unless errors.empty?

        state = normalized_state
        project = find_project(state, project_id)
        return rejected_result(command_id, command_type, "Project #{project_id} does not exist.", ["project_not_found"]) unless project

        now = timestamp
        previous_name = project.fetch("name", "")
        project["name"] = project_display_name(name) || name.to_s.strip
        project["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: project.fetch("id"),
          level: "info",
          message: "Renamed project #{project.fetch("id")}: #{previous_name} -> #{project.fetch("name")}",
          details: {
            "changed_fields" => ["name"],
            "previous_name" => previous_name,
            "name" => project.fetch("name")
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, project.fetch("id"), "Renamed project #{project.fetch("id")}.", project, log_ids)
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

      # `/prompt <id>` accepts a worker id and a head id. A worker id prompts that harness session;
      # a head id retries the head, which may spawn a fresh head session, so it is dispatched here
      # rather than inside the state lock every other kernel section shares.
      def prompt_agent_command(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        agent = present_string(agent_id) ? agent_record_snapshot(agent_id.to_s) : nil
        head = agent && agent.fetch("type", nil) == "head" ? agent : nil
        unless head
          prompt = value_at(payload, "prompt", "Prompt", "message", "Message")
          # Continuing a worker whose session the provider refuses to replay cannot be a prompt: the
          # resume would send the same rejected transcript. It is the same intent though, so it is
          # honoured as a fresh session on the worker's own worktree instead of a dead end.
          if agent && worker_session_unreplayable?(agent) && present_string(prompt)
            return continue_unreplayable_worker_session(command_id, command_type, agent, prompt.to_s)
          end

          return synchronized_state { prompt_agent(command_id, command_type, payload) }
        end

        prompt = value_at(payload, "prompt", "Prompt", "message", "Message")
        if blank?(prompt)
          return synchronized_state { rejected_result(command_id, command_type, "Agent was not prompted.", ["prompt is required"]) }
        end

        retry_head(command_id, command_type, head, instruction: prompt.to_s)
      end

      # `/prompt` (or a head's PromptAgent) aimed at a worker whose session cannot be replayed. The
      # instruction is carried into a fresh session on the same worktree and branch. When the
      # restart was already spent, the reply names the successor that holds the work.
      def continue_unreplayable_worker_session(command_id, command_type, agent, instruction)
        restart = restart_unreplayable_worker_session(agent.fetch("id"), trigger: "prompt", instruction: instruction)
        if restart.fetch("claimed", false) && restart.fetch("restarted", false)
          successor = agent_record_snapshot(restart.fetch("successor_agent_id"))
          return accepted_result(
            command_id,
            command_type,
            restart.fetch("successor_agent_id"),
            restart.fetch("message"),
            successor || restart.fetch("result", nil),
            restart.fetch("log_entry_ids", [])
          )
        end

        synchronized_state do
          rejected_result(command_id, command_type, unreplayable_prompt_rejection_message(agent, restart), ["session_unreplayable"])
        end
      end

      def unreplayable_prompt_rejection_message(agent, restart)
        current = agent_record_snapshot(agent.fetch("id")) || agent
        recovery = worker_session_recovery(current)
        successor_id = present_string(current.fetch("replaced_by_agent_id", nil)) ||
                       present_string(recovery.fetch("restarted_by_agent_id", nil))
        base = "Agent #{agent.fetch("id")} cannot be continued because its agent session can no longer be " \
               "replayed to the model."
        if successor_id
          return "#{base} Worker #{successor_id} already took over its workspace, so prompt #{successor_id} instead."
        end
        if restart.is_a?(Hash) && restart.fetch("claimed", false)
          return "#{base} Restarting it in a fresh session failed: #{result_failure_summary(restart.fetch("result", nil))}. " \
                 "#{unreplayable_session_recovery_advice(current)}"
        end

        "#{base} #{unreplayable_session_recovery_advice(current)} Meringue has already used its automatic " \
          "restart for this worker, so spawn a worker on this issue (or continue in the worktree yourself) " \
          "instead of prompting this record."
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
        return rejected_result(command_id, command_type, missing_agent_prompt_message(agent_id), ["agent_not_found"]) unless agent
        # Heads are handled by `prompt_agent_command`, which retries them. Reaching this branch
        # means a caller bypassed that dispatch, so the head contract is restated instead of
        # turning the head into a worker session.
        if agent.fetch("type", nil) == "head"
          return rejected_result(
            command_id,
            command_type,
            "Agent #{agent_id} is a head; prompting a head retries it and cannot be delivered as a worker prompt.",
            ["agent_is_not_worker"]
          )
        end
        return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
        # A worker whose workspace provisioning failed has no session to prompt, but it is not
        # dead either: prompting it is how the user retries provisioning with a fresh instruction,
        # instead of losing the reservation and having to recreate the worker by hand.
        if worker_awaiting_provisioning_retry?(agent)
          return requeue_worker_provisioning(state, command_id, command_type, agent, prompt.to_s)
        end
        # An errored worker is normally not resumable, but a worker whose turn was cut short by a
        # transport failure still owns its session, worktree, and branch: prompting it is how the
        # user recovers the work instead of losing it.
        if %w[killed errored].include?(agent.fetch("status", nil)) && !worker_resumable_after_settle_failure?(agent)
          return rejected_result(command_id, command_type, "Agent #{agent_id} cannot be continued because it is #{agent.fetch("status")}.", ["agent_not_resumable"])
        end
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
        # The prompt landed, so a recorded dead-turn reason is history. Cleared after the merge
        # because the session ref carries the agent's own metadata back in.
        clear_settle_failure!(agent)
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

      # A head id that no longer resolves is the common case after a kill or a prune, and the
      # generic "does not exist" line leaves the user guessing why their retry target vanished.
      def missing_agent_prompt_message(agent_id)
        id = agent_id.to_s
        return "Agent #{id} does not exist." unless id.match?(/\AH\d+\z/i)

        "Head #{id.upcase} no longer exists. Heads are removed when they are killed, cleaned up " \
          "after routing, or pruned, so send your message as a new prompt instead."
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
            # A prompt queued while the worker was mid-turn must not be dropped just because that
            # turn then died from a transport failure; that session is still resumable.
            if TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil)) && !worker_resumable_after_settle_failure?(agent)
              next []
            end

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

      # --- goal loops ------------------------------------------------------------
      #
      # A goal is the durable controller for "keep working until this measurable criterion
      # is met". It is attached to exactly one issue, owns its own budgets, and is advanced
      # by the reconcile tick rather than by a long-lived agent session.

      # `CreateGoal` has two entry shapes and one outcome. `issue_id` attaches the loop to an
      # issue that already exists; `prompt` describes the outcome and the kernel mints the issue
      # itself, so a goal-driven request never has to be split into "create an issue, then attach
      # a goal to it". Both shapes end at the same record, and the minted issue is written in the
      # same save as the goal: validation runs first, so a rejected goal can never leave an
      # orphan issue behind.
      def create_goal(command_id, command_type, payload)
        issue_id = present_string(value_at(payload, "issue_id", "IssueID", "issueId"))
        prompt = present_string(value_at(payload, "prompt", "Prompt", "issue_prompt", "IssuePrompt", "issuePrompt"))
        success_criteria = present_string(value_at(payload, "success_criteria", "SuccessCriteria", "successCriteria", "criteria")) || prompt
        title = value_at(payload, "title", "Title")
        metric = goal_metric_from_payload(payload)
        budget = goal_budget_from_payload(payload)
        judge_mode = present_string(value_at(payload, "judge_mode", "judgeMode")) || value_at(payload, "judge", "Judge")&.then { |judge| judge.is_a?(Hash) ? value_at(judge, "mode", "Mode") : judge }
        continuity = present_string(value_at(payload, "continuity", "Continuity"))
        attempt_prompt_template = present_string(value_at(payload, "attempt_prompt_template", "attemptPromptTemplate"))
        paused = truthy?(value_at(payload, "paused", "Paused"))
        errors = []

        errors << "issue_id or prompt is required" if issue_id.nil? && prompt.nil?
        errors << "success_criteria is required" if blank?(success_criteria)
        errors << "metric.command is required" if blank?(metric["command"])
        errors << "metric.target must be a number" if metric["target"].nil?
        if present_string(value_at(payload, "comparator", "Comparator")) && !Goals::Record::COMPARATORS.include?(value_at(payload, "comparator", "Comparator").to_s)
          errors << "comparator must be one of #{Goals::Record::COMPARATORS.join(", ")}"
        end
        if present_string(continuity) && !Goals::Record::CONTINUITY_MODES.include?(continuity)
          errors << "continuity must be one of #{Goals::Record::CONTINUITY_MODES.join(", ")}"
        end
        if present_string(judge_mode) && !Goals::Record::JUDGE_MODES.include?(judge_mode.to_s)
          errors << if Goals::Record::DEFERRED_JUDGE_MODES.include?(judge_mode.to_s)
                      "judge mode #{judge_mode} is not implemented yet; only #{Goals::Record::JUDGE_MODES.join(", ")} is available"
                    else
                      "judge mode must be one of #{Goals::Record::JUDGE_MODES.join(", ")}"
                    end
        end
        return rejected_result(command_id, command_type, "Goal was not created.", errors) unless errors.empty?

        state = normalized_state
        if issue_id
          issue = find_issue(state, issue_id)
          return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) unless issue

          project = find_project(state, issue.fetch("project_id"))
          return rejected_result(command_id, command_type, "Project #{issue.fetch("project_id")} does not exist.", ["project_not_found"]) unless project

          mismatch = goal_project_conflict(state, payload, issue, project)
          return rejected_result(command_id, command_type, mismatch.fetch("message"), mismatch.fetch("errors")) if mismatch

          # One loop per issue. Two loops on one issue would race for the same branch and
          # double the sessions the budgets are supposed to bound.
          existing = active_goal_for_issue(state, issue.fetch("id"))
          if existing
            return rejected_result(
              command_id,
              command_type,
              "Issue #{issue.fetch("id")} already has an active goal (#{existing.fetch("id")}).",
              ["issue_already_has_active_goal"]
            )
          end
        else
          resolution = resolve_goal_project(state, payload)
          project = resolution.fetch("project", nil)
          return rejected_result(command_id, command_type, resolution.fetch("message"), resolution.fetch("errors")) unless project
        end

        now = timestamp
        goal_id = next_goal_id!(state)
        minted = issue.nil?
        minted_log_ids = []
        if minted
          issue = mint_goal_issue!(
            state,
            project: project,
            prompt: prompt || success_criteria,
            success_criteria: success_criteria,
            issue_title: present_string(value_at(payload, "issue_title", "IssueTitle", "issueTitle")),
            originating_head_id: value_at(payload, "originating_head_id", "originatingHeadId", "_head_id"),
            goal_id: goal_id,
            metric: metric,
            now: now
          )
          minted_log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: issue.fetch("id"),
            level: "info",
            message: "Created issue #{issue.fetch("id")} for goal #{goal_id}: #{issue.fetch("title")}",
            details: {
              "project_id" => project.fetch("id"),
              "parent_issue_id" => nil,
              "goal_id" => goal_id,
              "created_for_goal" => true
            }
          )
        end
        goal = {
          "id" => goal_id,
          "project_id" => project.fetch("id"),
          "issue_id" => issue.fetch("id"),
          "title" => present_string(title) || issue.fetch("title", "Goal"),
          "success_criteria" => success_criteria.to_s.strip,
          "kind" => Goals::Record::DEFAULT_KIND,
          "status" => "queued",
          "stop_reason" => nil,
          "paused" => paused,
          "metric" => metric,
          "judge" => { "mode" => present_string(judge_mode) || Goals::Record::DEFAULT_JUDGE_MODE },
          "budget" => budget,
          "continuity" => continuity || Goals::Record::DEFAULT_CONTINUITY,
          "attempt_prompt_template" => attempt_prompt_template,
          "baseline_metric" => nil,
          "last_metric" => nil,
          "best_metric" => nil,
          "current_iteration" => 0,
          "workers_spawned" => 0,
          "consecutive_no_progress" => 0,
          "consecutive_probe_failures" => 0,
          "iterations" => [],
          "active_worker_id" => nil,
          "question_id" => nil,
          "next_tick_at" => nil,
          "created_at" => now,
          "updated_at" => now
        }
        Goals::Record.normalize!(goal)
        state.fetch("goals") << goal
        issue["status"] = "working" unless TERMINAL_AGENT_STATUSES.include?(issue.fetch("status", nil))
        issue["updated_at"] = now

        log_ids = minted_log_ids + append_log(
          state,
          source_type: "kernel",
          source_id: goal.fetch("id"),
          level: "info",
          message: "Created goal #{goal.fetch("id")} on #{minted ? "new issue " : ""}#{issue.fetch("id")}: #{goal.fetch("success_criteria")}",
          details: goal_log_details(goal).merge("created_issue" => minted)
        )
        touch_state!(state, now)
        store.save(state)

        message = if minted
                    "Created issue #{issue.fetch("id")} (#{issue.fetch("title")}) and goal #{goal.fetch("id")}. #{Goals::Record.summary(goal)}"
                  else
                    "Created goal #{goal.fetch("id")}. #{Goals::Record.summary(goal)}"
                  end
        accepted_result(command_id, command_type, goal.fetch("id"), message, goal, log_ids)
      end

      # The issue a prompt-form goal needs. It is a perfectly ordinary issue: same id counter,
      # same shape, prunable and recountable like any other. Only its provenance differs, which
      # is recorded in the log details rather than in a new field.
      def mint_goal_issue!(state, project:, prompt:, success_criteria:, issue_title:, originating_head_id:, goal_id:, metric:, now:)
        issue = {
          "id" => next_issue_id!(state, project.fetch("id")),
          "project_id" => project.fetch("id"),
          "parent_issue_id" => nil,
          "originating_head_id" => present_string(originating_head_id),
          "title" => issue_title || goal_issue_title(prompt),
          "description" => goal_issue_description(prompt: prompt, success_criteria: success_criteria, goal_id: goal_id, metric: metric),
          "status" => "queued",
          "agent_ids" => [],
          "created_at" => now,
          "updated_at" => now
        }
        state.fetch("issues") << issue
        project["updated_at"] = now
        issue
      end

      def goal_issue_title(prompt)
        text = prompt.to_s.strip.gsub(/\s+/, " ")
        return "Goal loop" if text.empty?

        sentence = text.split(/(?<=[.!?])\s/, 2).first.to_s.strip.sub(/[.]\z/, "")
        sentence = text if sentence.empty?
        return sentence if sentence.length <= GOAL_ISSUE_TITLE_LIMIT

        truncated = sentence[0, GOAL_ISSUE_TITLE_LIMIT]
        boundary = truncated.rindex(" ")
        truncated = truncated[0, boundary] if boundary && boundary > GOAL_ISSUE_TITLE_LIMIT / 2
        "#{truncated.rstrip}…"
      end

      # The prompt is kept verbatim, because it is what the attempt workers are ultimately
      # working from, and the measurable finish line is spelled out underneath it.
      def goal_issue_description(prompt:, success_criteria:, goal_id:, metric:)
        lines = [prompt.to_s.strip]
        lines << ""
        lines << "Goal loop #{goal_id} drives this issue: Meringue keeps producing attempts until the criterion below is met or a budget guard stops the loop."
        lines << "Success criteria: #{success_criteria}" unless success_criteria.to_s.strip == prompt.to_s.strip
        comparator = GOAL_COMPARATOR_TEXT.fetch(metric["comparator"].to_s, metric["comparator"].to_s)
        lines << "Metric (measured by the kernel, never self-reported): #{metric["command"]} #{comparator} #{Goals::Record.format_number(metric["target"])}"
        guardrails = Array(metric["guardrails"]).map { |guardrail| guardrail.is_a?(Hash) ? guardrail["command"] : guardrail }.compact
        lines << "Guardrails that must keep passing: #{guardrails.join(", ")}" unless guardrails.empty?
        lines.join("\n")
      end

      # Which project a prompt-form goal's issue lands in. Explicit beats local beats sole,
      # and an ambiguous choice is rejected with the candidates rather than guessed at, because
      # an issue minted under the wrong project is invisible work in the wrong tree.
      def resolve_goal_project(state, payload)
        requested = present_string(value_at(payload, "project_id", "ProjectID", "projectId", "project", "Project"))
        if requested
          project = find_project(state, requested) || project_by_name_or_root(state, requested)
          return { "project" => project } if project

          return {
            "message" => "Project #{requested} does not exist.#{registered_project_hint(state)}",
            "errors" => ["project_not_found"]
          }
        end

        candidates = state.fetch("projects", []).reject { |project| project.fetch("status", nil) == "killed" }
        if candidates.empty?
          return {
            "message" => "No project is registered, so there is nowhere to create the goal's issue. Run /project add <path> first.",
            "errors" => ["no_registered_project"]
          }
        end

        local = project_for_directory(candidates, cwd)
        return { "project" => local } if local
        return { "project" => candidates.first } if candidates.length == 1

        {
          "message" => "Several projects are registered and this directory is not inside one of them, " \
                       "so /goal create cannot tell where the new issue belongs. Add --project <project_id> " \
                       "(or name an existing issue).#{registered_project_hint(state)}",
          "errors" => ["project_ambiguous"]
        }
      end

      # `project_id` alongside `issue_id` is redundant, so it is only worth a rejection when the
      # two disagree: that is a head or a user pointing at two different places at once.
      def goal_project_conflict(state, payload, issue, project)
        requested = present_string(value_at(payload, "project_id", "ProjectID", "projectId", "project", "Project"))
        return nil unless requested

        requested_project = find_project(state, requested) || project_by_name_or_root(state, requested)
        return nil if requested_project && requested_project.fetch("id") == project.fetch("id")

        {
          "message" => "Issue #{issue.fetch("id")} belongs to #{project.fetch("id")}, not #{requested}. " \
                       "Drop the project when you name an issue.",
          "errors" => ["project_issue_mismatch"]
        }
      end

      def project_by_name_or_root(state, value)
        needle = value.to_s.strip
        state.fetch("projects", []).find { |project| project.fetch("name", "").to_s.casecmp?(needle) } ||
          state.fetch("projects", []).find { |project| same_path?(project.fetch("root_path", ""), needle) }
      end

      # The deepest registered project root that contains `path`, so a nested checkout wins over
      # its parent instead of both matching.
      def project_for_directory(projects, path)
        expanded = File.expand_path(path.to_s)
        projects.select { |project| directory_contains?(project.fetch("root_path", nil), expanded) }
                .max_by { |project| File.expand_path(project.fetch("root_path").to_s).length }
      end

      def directory_contains?(root_path, expanded_path)
        return false if blank?(root_path)

        root = File.expand_path(root_path.to_s)
        expanded_path == root || expanded_path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def registered_project_hint(state)
        ids = state.fetch("projects", []).map { |project| project.fetch("id", nil) }.compact
        return "" if ids.empty?

        " Registered projects: #{ids.join(", ")}."
      end

      def modify_goal(command_id, command_type, payload)
        goal_id = value_at(payload, "goal_id", "GoalID", "goalId", "id")
        return rejected_result(command_id, command_type, "Goal was not modified.", ["goal_id is required"]) if blank?(goal_id)

        state = normalized_state
        goal = find_goal(state, goal_id)
        return rejected_result(command_id, command_type, "Goal #{goal_id} does not exist.", ["goal_not_found"]) unless goal
        if %w[killed].include?(goal.fetch("status", nil))
          return rejected_result(command_id, command_type, "Goal #{goal.fetch("id")} was stopped and cannot be modified.", ["goal_not_modifiable"])
        end

        requested_status = present_string(value_at(payload, "status", "Status"))
        if requested_status && !Goals::Record::ACTIVE_STATUSES.include?(requested_status)
          return rejected_result(
            command_id,
            command_type,
            "ModifyGoal can only set a goal back to #{Goals::Record::ACTIVE_STATUSES.join(" or ")}; use StopGoal or Kill to end one.",
            ["invalid_goal_status"]
          )
        end

        now = timestamp
        changed_fields = []
        if payload_has?(payload, "paused", "Paused")
          goal["paused"] = truthy?(value_at(payload, "paused", "Paused"))
          changed_fields << "paused"
        end
        if payload_has?(payload, "success_criteria", "SuccessCriteria", "successCriteria", "criteria")
          goal["success_criteria"] = value_at(payload, "success_criteria", "SuccessCriteria", "successCriteria", "criteria").to_s.strip
          changed_fields << "success_criteria"
        end
        if payload_has?(payload, "title", "Title")
          goal["title"] = present_string(value_at(payload, "title", "Title")) || goal.fetch("title")
          changed_fields << "title"
        end
        if payload_has?(payload, "attempt_prompt_template", "attemptPromptTemplate")
          goal["attempt_prompt_template"] = present_string(value_at(payload, "attempt_prompt_template", "attemptPromptTemplate"))
          changed_fields << "attempt_prompt_template"
        end
        target = Goals::Record.float_or_nil(value_at(payload, "target", "Target", "metric_target", "metricTarget"))
        if target
          goal["metric"]["target"] = target
          changed_fields << "target"
        end
        budget_updates = goal_budget_updates_from_payload(payload)
        unless budget_updates.empty?
          goal["budget"] = Goals::Record.normalized_budget(goal.fetch("budget").merge(budget_updates))
          changed_fields.concat(budget_updates.keys)
        end

        if requested_status
          # Restarting a guard-stopped goal clears the stop reason and the no-progress
          # counters, otherwise the same guard would trip again on the next tick.
          goal["status"] = requested_status
          goal["stop_reason"] = nil
          goal["settled_at"] = nil
          goal["consecutive_no_progress"] = 0
          goal["consecutive_probe_failures"] = 0
          goal["next_tick_at"] = nil
          changed_fields << "status"
        end

        Goals::Record.normalize!(goal)
        goal["updated_at"] = now
        message = "Modified goal #{goal.fetch("id")}: #{changed_fields.empty? ? "no fields changed" : changed_fields.uniq.join(", ")}. #{Goals::Record.summary(goal)}"
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: goal.fetch("id"),
          level: "info",
          message: message,
          details: goal_log_details(goal).merge("changed_fields" => changed_fields.uniq)
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, goal.fetch("id"), message, goal, log_ids)
      end

      # A user-facing stop. The loop ends for good, but the attempt session that is already
      # running is left alone: it owns a real branch and worktree, and killing it would throw
      # that work away. `Kill <goal_id>` is the destructive variant.
      def stop_goal(command_id, command_type, payload)
        goal_id = value_at(payload, "goal_id", "GoalID", "goalId", "id", "target_id")
        return rejected_result(command_id, command_type, "Goal was not stopped.", ["goal_id is required"]) if blank?(goal_id)

        state = normalized_state
        goal = find_goal(state, goal_id)
        return rejected_result(command_id, command_type, "Goal #{goal_id} does not exist.", ["goal_not_found"]) unless goal

        if Goals::Record::ACTIVE_STATUSES.include?(goal.fetch("status", nil))
          now = timestamp
          settle_goal_record!(goal, status: "killed", stop_reason: "user_stopped", now: now)
          message = "Stopped goal #{goal.fetch("id")} at the user's request. #{Goals::Record.summary(goal)}"
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: goal.fetch("id"),
            level: "info",
            message: message,
            details: goal_log_details(goal).merge("retained_agent_id" => goal.fetch("last_worker_id", nil)).compact
          )
          touch_state!(state, now)
          store.save(state)
          return accepted_result(command_id, command_type, goal.fetch("id"), message, goal, log_ids)
        end

        accepted_result(
          command_id,
          command_type,
          goal.fetch("id"),
          "Goal #{goal.fetch("id")} is already #{goal.fetch("status")}#{goal.fetch("stop_reason", nil) ? " (#{goal.fetch("stop_reason")})" : ""}.",
          goal,
          []
        )
      end

      def list_goals(command_id, command_type, payload)
        goal_id = present_string(value_at(payload, "goal_id", "GoalID", "goalId", "id", "target_id"))
        state = normalized_state
        goals = state.fetch("goals")
        if goal_id
          goal = find_goal(state, goal_id)
          return rejected_result(command_id, command_type, "Goal #{goal_id} does not exist.", ["goal_not_found"]) unless goal

          goals = [goal]
        end

        summaries = goals.map { |record| goal_status_summary(record) }
        # One log line: the per-goal lines are rendered as command output detail, like
        # ListQuestions, so a visible log entry stays one scannable line.
        message = if summaries.empty?
                    "No goal loops."
                  elsif summaries.length == 1
                    summaries.first.fetch("line")
                  else
                    "#{summaries.length} goal loops."
                  end
        accepted_result(command_id, command_type, goal_id, message, { "goals" => summaries }, [])
      end

      def goal_output_lines(result)
        summaries = Array(result.is_a?(Hash) ? result["goals"] : nil)
        return ["  No goal loops."] if summaries.empty?

        summaries.flat_map do |summary|
          lines = ["  #{summary.fetch("line", summary.fetch("id", "goal"))}"]
          next lines unless summaries.length == 1

          lines + Array(summary.fetch("iterations", [])).map do |iteration|
            "    it#{iteration.fetch("number", 0)}: #{iteration.fetch("verdict", "?")} metric #{Goals::Record.format_number(iteration.fetch("metric", nil))}"
          end
        end
      end

      def goal_status_summary(goal)
        iterations = Goals::Record.settled_iterations(goal).last(5).map do |iteration|
          {
            "number" => iteration.fetch("number", 0),
            "verdict" => iteration.fetch("verdict", nil),
            "metric" => Goals::Record.metric_value(iteration.fetch("metric", nil)),
            "metric_delta" => iteration.fetch("metric_delta", nil),
            "attempt_worker_id" => iteration.fetch("attempt_worker_id", nil),
            "next_directive" => iteration.fetch("next_directive", nil)
          }
        end
        {
          "id" => goal.fetch("id"),
          "issue_id" => goal.fetch("issue_id", nil),
          "status" => goal.fetch("status", nil),
          "stop_reason" => goal.fetch("stop_reason", nil),
          "paused" => goal.fetch("paused", false),
          "line" => "#{Goals::Record.summary(goal)} — #{goal.fetch("success_criteria", "")}",
          "iterations" => iterations
        }
      end

      def goal_metric_from_payload(payload)
        nested = value_at(payload, "metric", "Metric")
        nested = {} unless nested.is_a?(Hash)
        parse = value_at(nested, "parse", "Parse")
        parse = {} unless parse.is_a?(Hash)
        pattern = present_string(value_at(payload, "pattern", "metric_pattern", "metricPattern")) || present_string(value_at(parse, "pattern", "Pattern"))
        parse_type = present_string(value_at(payload, "parse", "parse_type", "parseType")) || present_string(value_at(parse, "type", "Type"))
        parse_type = "regex" if parse_type.nil? && pattern

        Goals::Record.normalized_metric(
          "command" => present_string(value_at(payload, "metric_command", "metricCommand", "command")) || present_string(value_at(nested, "command", "Command")),
          "cwd" => present_string(value_at(payload, "metric_cwd", "metricCwd")) || present_string(value_at(nested, "cwd", "Cwd")),
          "comparator" => present_string(value_at(payload, "comparator", "Comparator")) || present_string(value_at(nested, "comparator", "Comparator")),
          "target" => Goals::Record.float_or_nil(value_at(payload, "target", "Target", "metric_target", "metricTarget") || value_at(nested, "target", "Target")),
          "timeout_seconds" => value_at(payload, "metric_timeout_seconds", "metricTimeoutSeconds") || value_at(nested, "timeout_seconds", "timeoutSeconds"),
          "parse" => {
            "type" => parse_type,
            "pattern" => pattern,
            "capture" => value_at(payload, "capture") || value_at(parse, "capture", "Capture"),
            "path" => present_string(value_at(payload, "json_path", "jsonPath")) || present_string(value_at(parse, "path", "Path"))
          },
          "guardrails" => Array(
            value_at(payload, "guardrails", "Guardrails") ||
            value_at(nested, "guardrails", "Guardrails") ||
            value_at(payload, "guardrail", "Guardrail")
          )
        )
      end

      def goal_budget_from_payload(payload)
        Goals::Record.normalized_budget(goal_budget_updates_from_payload(payload))
      end

      def goal_budget_updates_from_payload(payload)
        nested = value_at(payload, "budget", "Budget")
        nested = {} unless nested.is_a?(Hash)
        {
          "max_iterations" => value_at(payload, "max_iterations", "maxIterations") || value_at(nested, "max_iterations", "maxIterations"),
          "max_wall_clock_seconds" => value_at(payload, "max_wall_clock_seconds", "maxWallClockSeconds") || value_at(nested, "max_wall_clock_seconds", "maxWallClockSeconds"),
          "max_workers" => value_at(payload, "max_workers", "maxWorkers") || value_at(nested, "max_workers", "maxWorkers"),
          "max_consecutive_no_progress" => value_at(payload, "max_consecutive_no_progress", "maxConsecutiveNoProgress") || value_at(nested, "max_consecutive_no_progress", "maxConsecutiveNoProgress"),
          "min_metric_delta" => value_at(payload, "min_metric_delta", "minMetricDelta") || value_at(nested, "min_metric_delta", "minMetricDelta"),
          "min_seconds_between_iterations" => value_at(payload, "min_seconds_between_iterations", "minSecondsBetweenIterations") || value_at(nested, "min_seconds_between_iterations", "minSecondsBetweenIterations")
        }.compact
      end

      def goal_log_details(goal)
        {
          "goal_id" => goal.fetch("id"),
          "issue_id" => goal.fetch("issue_id", nil),
          "project_id" => goal.fetch("project_id", nil),
          "status" => goal.fetch("status", nil),
          "stop_reason" => goal.fetch("stop_reason", nil),
          "paused" => goal.fetch("paused", false),
          "current_iteration" => goal.fetch("current_iteration", 0),
          "max_iterations" => goal.dig("budget", "max_iterations"),
          "metric_command" => goal.dig("metric", "command"),
          "comparator" => goal.dig("metric", "comparator"),
          "target" => goal.dig("metric", "target"),
          "last_metric" => Goals::Record.metric_value(goal.fetch("last_metric", nil)),
          "best_metric" => Goals::Record.metric_value(goal.fetch("best_metric", nil)),
          "workers_spawned" => goal.fetch("workers_spawned", 0)
        }.compact
      end

      def find_goal(state, goal_id)
        return nil if blank?(goal_id)

        Ids.find_record(state.fetch("goals", []), goal_id)
      end

      def active_goal_for_issue(state, issue_id)
        state.fetch("goals", []).find do |goal|
          goal.fetch("issue_id", nil).to_s == issue_id.to_s && Goals::Record.loop_active?(goal)
        end
      end

      def issue_has_active_goal?(state, issue_id)
        !active_goal_for_issue(state, issue_id).nil?
      end

      def goals_for_issue_ids(state, issue_ids)
        ids = Array(issue_ids).compact.map(&:to_s)
        state.fetch("goals", []).select { |goal| ids.include?(goal.fetch("issue_id", nil).to_s) }
      end

      def next_goal_id!(state)
        state.fetch("counters")["goals"] = state.fetch("counters").fetch("goals", 0).to_i + 1
        "G#{state.fetch("counters").fetch("goals")}"
      end

      def truthy?(value)
        return false if value.nil?
        return value if [true, false].include?(value)

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end

      # One reconcile pass over every goal this instance may drive. Each goal advances at
      # most GOAL_MAX_STEPS_PER_TICK phases, and the loop's own single-flight invariant
      # means at most one attempt session can exist per goal at any time.
      def advance_goal_loops
        steps = []
        @goal_mutex.synchronize do
          goal_ids = synchronized_state do
            normalized_state.fetch("goals").filter_map do |goal|
              next unless Goals::Record.loop_active?(goal)
              next if goal.fetch("paused", false)
              # A goal driven by another live Meringue instance is that instance's to advance.
              next if goal_owned_by_other_live_instance?(goal)

              goal.fetch("id")
            end
          end

          deadline = monotonic_time + goal_advance_budget
          goal_ids.each do |goal_id|
            # Out of pass budget: the remaining goals are advanced by the next tick, so a slow
            # metric on one goal cannot starve session reconciliation.
            break if monotonic_time > deadline

            GOAL_MAX_STEPS_PER_TICK.times do
              step = advance_goal_loop_step(goal_id)
              break unless step

              steps << step
              break unless step.fetch("continue", false)
              break if monotonic_time > deadline
            end
          end
        end
        steps
      end

      # Performs exactly one phase transition for one goal: it asks the pure decision
      # function what to do, does it, and writes the outcome back. State is written before
      # every side effect so an interrupted step resumes instead of repeating.
      def advance_goal_loop_step(goal_id)
        context = synchronized_state do
          state = normalized_state
          goal = find_goal(state, goal_id)
          return nil unless goal
          return nil unless Goals::Record.loop_active?(goal)
          return nil if goal.fetch("paused", false)
          return nil if goal_owned_by_other_live_instance?(goal)

          claimed = claim_goal!(state, goal)
          if claimed
            touch_state!(state)
            store.save(state)
          end
          {
            "goal" => deep_copy(goal),
            "agents" => state.fetch("agents").map { |agent| goal_agent_snapshot(agent) }
          }
        end
        goal = context.fetch("goal")
        action = Goals::Loop.next_action(goal: goal, agents: context.fetch("agents"), now: Time.now.utc)

        case action.fetch("action")
        when "measure_baseline" then measure_goal_baseline(goal, action)
        when "start_iteration" then start_goal_iteration(goal, action)
        when "measure" then measure_goal_iteration(goal, action)
        when "judge" then judge_goal_iteration(goal, action)
        when "stop" then stop_goal_loop(goal, action)
        else nil
        end
      end

      # Records this instance as the goal's driver and flips a freshly created goal to
      # working. Returns true when state changed so the caller only saves when needed.
      def claim_goal!(state, goal)
        changed = false
        now = timestamp
        ownership = instance_ownership_metadata
        if goal.fetch("owner_instance_id", nil).to_s != ownership.fetch("owner_instance_id").to_s
          goal.merge!(ownership)
          changed = true
        end
        if goal.fetch("status", nil) == "queued"
          goal["status"] = "working"
          goal["started_at"] ||= now
          changed = true
        end
        goal["started_at"] ||= goal.fetch("created_at", now)
        goal["updated_at"] = now if changed
        changed
      end

      def goal_agent_snapshot(agent)
        agent.slice("id", "type", "status", "issue_id", "pid", "harness_session_id", "harness_session_file", "workspace_path", "workspace_branch")
      end

      # The baseline is measured before the first attempt so "progress" means something.
      def measure_goal_baseline(goal, _action)
        cwd = goal_metric_cwd(goal, worker_id: nil)
        measurement = run_goal_metric(goal, cwd: cwd)

        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          now = timestamp
          current["baseline_metric"] = measurement
          current["last_metric"] ||= measurement
          current["best_metric"] ||= measurement
          probe_ok = Goals::Evaluator.probe_ok?(current, measurement)
          current["consecutive_probe_failures"] = probe_ok ? 0 : current.fetch("consecutive_probe_failures", 0).to_i + 1
          current["updated_at"] = now
          message = if probe_ok
                      "Goal #{current.fetch("id")} baseline metric is #{Goals::Record.format_number(Goals::Record.metric_value(measurement))} (target #{current.dig("metric", "comparator")} #{Goals::Record.format_number(current.dig("metric", "target"))})."
                    else
                      "Goal #{current.fetch("id")} could not measure its baseline metric: #{goal_measurement_problem(measurement)}"
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: probe_ok ? "info" : "warning",
            message: message,
            details: goal_log_details(current).merge("phase" => "baseline", "measurement" => measurement)
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "measure_baseline", message, log_ids, continue: probe_ok)
        end
      end

      # Starts one attempt: checkpoint the iteration first, then issue the spawn/prompt.
      # The deterministic command id makes a repeated spawn idempotent, so a crash between
      # the checkpoint and the spawn resumes the same iteration instead of adding a worker.
      def start_goal_iteration(goal, action)
        number = action.fetch("number")
        mode = action.fetch("mode")
        command_id = action.fetch("command_id")
        checkpoint = synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          now = timestamp
          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          unless iteration
            iteration = {
              "number" => number,
              "phase" => "attempting",
              "mode" => mode,
              "attempt_command_id" => command_id,
              "attempt_worker_id" => mode == "prompt" ? action.fetch("worker_id", nil) : nil,
              "started_at" => now
            }
            current.fetch("iterations") << iteration
          end
          iteration["phase"] = "attempting"
          iteration["attempt_command_id"] ||= command_id
          current["current_iteration"] = number
          # Budget is consumed at the attempt, not at success: a spawn that keeps failing
          # must still exhaust the budget rather than retry forever.
          current["workers_spawned"] = current.fetch("workers_spawned", 0).to_i + 1 if mode == "spawn"
          current["active_worker_id"] = iteration.fetch("attempt_worker_id", nil)
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          { "goal" => deep_copy(current), "iteration_number" => number }
        end

        current_goal = checkpoint.fetch("goal")
        prompt = Goals::AttemptPrompt.render(goal: current_goal, iteration_number: number, mode: mode)
        result = if mode == "prompt"
                   apply(
                     "command_id" => command_id,
                     "type" => "PromptAgent",
                     "payload" => { "agent_id" => action.fetch("worker_id"), "prompt" => prompt, "mode" => "normal" }
                   )
                 else
                   apply(
                     "command_id" => command_id,
                     "type" => "SpawnWorker",
                     "payload" => {
                       "issue_id" => current_goal.fetch("issue_id"),
                       "prompt" => prompt,
                       "title" => "#{current_goal.fetch("id")} iteration #{number}",
                       "follow_up_of_agent_id" => goal_follow_up_agent_id(current_goal)
                     }.compact
                   )
                 end

        record_goal_attempt_result(current_goal.fetch("id"), number, mode, result)
      end

      def record_goal_attempt_result(goal_id, number, mode, result)
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal_id)
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          accepted = result.fetch("status", nil) == "accepted"
          if accepted
            worker_id = result.fetch("target_id", nil)
            worker = find_agent(state, worker_id)
            iteration["attempt_worker_id"] = worker_id
            iteration["attempt_branch"] = worker && worker.fetch("workspace_branch", nil)
            iteration["attempt_workspace_path"] = worker && worker.fetch("workspace_path", nil)
            current["active_worker_id"] = worker_id
            message = "Goal #{current.fetch("id")} started iteration #{number} of #{current.dig("budget", "max_iterations")} on #{worker_id}."
            level = "info"
          else
            # A failed attempt is settled immediately as inconclusive: the no-progress guard
            # then stops the goal instead of the kernel retrying a broken spawn forever.
            iteration["phase"] = "settled"
            iteration["verdict"] = "inconclusive"
            iteration["settled_at"] = now
            iteration["evidence"] = ["attempt could not be started: #{result.fetch("message", "unknown error")}"]
            iteration["next_directive"] = nil
            current["consecutive_no_progress"] = current.fetch("consecutive_no_progress", 0).to_i + 1
            current["active_worker_id"] = nil
            current["next_tick_at"] = goal_next_tick_at(current, now)
            message = "Goal #{current.fetch("id")} could not start iteration #{number}: #{result.fetch("message", "unknown error")}"
            level = "warning"
          end
          current["updated_at"] = now
          trim_goal_iterations!(current)
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: level,
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "attempt",
              "iteration" => number,
              "mode" => mode,
              "attempt_worker_id" => iteration.fetch("attempt_worker_id", nil),
              "attempt_command_id" => iteration.fetch("attempt_command_id", nil)
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          # After a started attempt the only legal next decision is "wait", so this pass stops.
          goal_step(current, "start_iteration", message, log_ids, continue: !accepted)
        end
      end

      # Measures the metric and guardrails on the attempt's own branch, outside the state
      # lock, with the probe's timeout and output caps.
      def measure_goal_iteration(goal, action)
        number = action.fetch("iteration_number")
        prepared = synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          iteration["phase"] = "measuring"
          iteration["attempt_worker_status"] = action.fetch("attempt_worker_status", iteration.fetch("attempt_worker_status", nil))
          worker = find_agent(state, iteration.fetch("attempt_worker_id", nil))
          iteration["attempt_branch"] ||= worker && worker.fetch("workspace_branch", nil)
          iteration["attempt_workspace_path"] ||= worker && worker.fetch("workspace_path", nil)
          current["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          { "goal" => deep_copy(current), "workspace_path" => iteration.fetch("attempt_workspace_path", nil) }
        end

        current_goal = prepared.fetch("goal")
        cwd = goal_metric_cwd(current_goal, workspace_path: prepared.fetch("workspace_path", nil))
        measurement = run_goal_metric(current_goal, cwd: cwd)
        guardrails = run_goal_guardrails(current_goal, cwd: cwd)
        fingerprint = goal_workspace_fingerprint(cwd)

        synchronized_state do
          state = normalized_state
          current = find_goal(state, current_goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          now = timestamp
          iteration["metric"] = measurement
          iteration["guardrails"] = guardrails
          iteration["workspace_fingerprint"] = fingerprint
          iteration["measured_at"] = now
          iteration["phase"] = "judging"
          current["updated_at"] = now
          message = "Goal #{current.fetch("id")} measured iteration #{number}: #{Goals::Record.format_number(Goals::Record.metric_value(measurement))}#{guardrails.empty? ? "" : ", guardrails #{guardrails.count { |guardrail| guardrail.fetch("passed", false) }}/#{guardrails.length} passing"}."
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: "info",
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "measure",
              "iteration" => number,
              "measurement" => measurement,
              "guardrails" => guardrails,
              "metric_cwd" => cwd
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "measure", message, log_ids, continue: true)
        end
      end

      # The judge step. Deterministic today: it scores the measurement against the metric
      # and guardrails, records the verdict, and writes the directive the next attempt gets.
      def judge_goal_iteration(goal, action)
        number = action.fetch("iteration_number")
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current

          iteration = Goals::Record.iterations(current).find { |entry| entry.fetch("number", nil).to_i == number.to_i }
          return nil unless iteration

          judgement = Goals::Evaluator.evaluate(goal: current, iteration: iteration)
          now = timestamp
          iteration["verdict"] = judgement.fetch("verdict")
          iteration["score"] = judgement.fetch("score")
          iteration["metric_delta"] = judgement.fetch("metric_delta")
          iteration["evidence"] = judgement.fetch("evidence")
          iteration["gaming_suspected"] = judgement.fetch("gaming_suspected")
          iteration["next_directive"] = judgement.fetch("next_directive")
          iteration["judged_by"] = current.dig("judge", "mode")
          iteration["phase"] = "settled"
          iteration["settled_at"] = now
          iteration["duration_seconds"] = goal_duration_seconds(iteration.fetch("started_at", nil), now)

          measurement = iteration.fetch("metric", nil)
          if judgement.fetch("probe_ok")
            current["last_metric"] = measurement
            current["best_metric"] = Goals::Record.better_measurement(current, current.fetch("best_metric", nil), measurement)
            current["consecutive_probe_failures"] = 0
          else
            current["consecutive_probe_failures"] = current.fetch("consecutive_probe_failures", 0).to_i + 1
          end
          current["consecutive_no_progress"] = judgement.fetch("progress") ? 0 : current.fetch("consecutive_no_progress", 0).to_i + 1
          current["active_worker_id"] = nil
          current["last_worker_id"] = iteration.fetch("attempt_worker_id", nil)
          current["next_tick_at"] = goal_next_tick_at(current, now)
          current["updated_at"] = now
          trim_goal_iterations!(current)

          message = "Goal #{current.fetch("id")} iteration #{number} verdict #{judgement.fetch("verdict")}: #{judgement.fetch("evidence").first || "no evidence"}."
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: judgement.fetch("gaming_suspected") ? "warning" : "info",
            message: message,
            details: goal_log_details(current).merge(
              "phase" => "judge",
              "iteration" => number,
              "verdict" => judgement.fetch("verdict"),
              "score" => judgement.fetch("score"),
              "metric_delta" => judgement.fetch("metric_delta"),
              "evidence" => judgement.fetch("evidence"),
              "gaming_suspected" => judgement.fetch("gaming_suspected"),
              "next_directive" => judgement.fetch("next_directive"),
              "judge_mode" => current.dig("judge", "mode")
            ).compact
          )
          touch_state!(state, now)
          store.save(state)
          goal_step(current, "judge", message, log_ids, continue: true)
        end
      end

      # Terminal transition for a goal loop. Every stop is durable, logged with its reason,
      # and reflected on the owning issue; a guard stop also asks the user a question so a
      # stalled goal surfaces in the questions list instead of going quiet.
      def stop_goal_loop(goal, action)
        synchronized_state do
          state = normalized_state
          current = find_goal(state, goal.fetch("id"))
          return nil unless current
          return nil unless Goals::Record.loop_active?(current)

          now = timestamp
          stop_reason = action.fetch("stop_reason")
          settle_goal_record!(current, status: action.fetch("status"), stop_reason: stop_reason, now: now)
          issue = find_issue(state, current.fetch("issue_id", nil))
          if issue
            issue["status"] = stop_reason == "goal_met" ? "completed" : "blocked"
            issue["updated_at"] = now
            project = find_project(state, issue.fetch("project_id", nil))
            update_project_status_from_issues!(state, project, now) if project
          end

          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: current.fetch("id"),
            level: stop_reason == "goal_met" ? "info" : "warning",
            message: action.fetch("message"),
            details: goal_log_details(current).merge("phase" => "stop", "iterations_settled" => Goals::Record.settled_iterations(current).length)
          )

          unless %w[goal_met user_stopped killed].include?(stop_reason)
            question = build_question(
              state: state,
              head_id: nil,
              question_text: goal_stop_question(current, action),
              context: "#{action.fetch("message")} #{Goals::Record.summary(current)}",
              project_id: current.fetch("project_id", nil),
              issue_id: current.fetch("issue_id", nil)
            )
            state.fetch("questions") << question
            current["question_id"] = question.fetch("id")
            log_ids.concat(append_log(
              state,
              source_type: "kernel",
              source_id: question.fetch("id"),
              level: "info",
              message: "Question #{question.fetch("id")}: #{question.fetch("question")}",
              details: { "goal_id" => current.fetch("id"), "stop_reason" => stop_reason }
            ))
          end

          touch_state!(state, now)
          store.save(state)
          goal_step(current, "stop", action.fetch("message"), log_ids, continue: false)
        end
      end

      def goal_stop_question(goal, action)
        case goal.fetch("stop_reason", nil)
        when "no_progress"
          "Goal #{goal.fetch("id")} stopped after #{goal.fetch("consecutive_no_progress")} iteration(s) with no measurable progress (metric #{Goals::Record.format_number(Goals::Record.metric_value(goal.fetch("last_metric", nil)))} vs target #{Goals::Record.format_number(Goals::Record.target(goal))}). Change the approach, adjust the goal, or stop it?"
        when "oscillation"
          "Goal #{goal.fetch("id")} stopped because its attempts started repeating the same workspace state. Should it try a different approach, or stop?"
        when "probe_unavailable"
          "Goal #{goal.fetch("id")} stopped because its metric command `#{goal.dig("metric", "command")}` keeps failing. Fix the command, change the metric, or stop the goal?"
        when "max_iterations"
          "Goal #{goal.fetch("id")} used its #{goal.dig("budget", "max_iterations")} iteration budget and reached #{Goals::Record.format_number(Goals::Record.metric_value(goal.fetch("last_metric", nil)))} of #{Goals::Record.format_number(Goals::Record.target(goal))}. Raise the budget, accept the result, or stop?"
        else
          "#{action.fetch("message")} How should this goal continue?"
        end
      end

      def goal_step(goal, phase, message, log_entry_ids, continue:)
        {
          "goal_id" => goal.fetch("id"),
          "phase" => phase,
          "status" => goal.fetch("status", nil),
          "stop_reason" => goal.fetch("stop_reason", nil),
          "iteration" => goal.fetch("current_iteration", 0),
          "message" => message,
          "changed" => true,
          "continue" => continue,
          "log_entry_ids" => Array(log_entry_ids)
        }
      end

      def run_goal_metric(goal, cwd:)
        metric = goal.fetch("metric", {}) || {}
        measurement = metric_probe.measure(
          command: metric.fetch("command", nil),
          cwd: cwd,
          parse: metric.fetch("parse", {}),
          timeout: metric.fetch("timeout_seconds", Goals::Record::DEFAULT_METRIC_TIMEOUT_SECONDS)
        )
        (measurement.is_a?(Hash) ? measurement : {}).merge(
          "measured_at" => timestamp,
          "cwd" => cwd,
          "command" => metric.fetch("command", nil)
        )
      rescue StandardError => e
        { "value" => nil, "error" => sanitized_error_message(e), "exit_status" => nil, "timed_out" => false, "measured_at" => timestamp, "cwd" => cwd }
      end

      def run_goal_guardrails(goal, cwd:)
        Array(goal.dig("metric", "guardrails")).first(Goals::Record::MAX_GUARDRAILS).map do |guardrail|
          begin
            metric_probe.check_guardrail(
              command: guardrail.fetch("command", nil),
              cwd: cwd,
              timeout: goal.dig("metric", "timeout_seconds") || Goals::Record::DEFAULT_METRIC_TIMEOUT_SECONDS
            )
          rescue StandardError => e
            { "command" => guardrail.fetch("command", nil), "passed" => false, "error" => sanitized_error_message(e) }
          end
        end
      end

      def goal_workspace_fingerprint(cwd)
        metric_probe.workspace_fingerprint(cwd: cwd)
      rescue StandardError
        nil
      end

      # The metric runs on the attempt's own workspace by default, so it measures the branch
      # the attempt actually produced. `project_root` metrics and the pre-attempt baseline
      # fall back to the registered project root.
      def goal_metric_cwd(goal, worker_id: :unset, workspace_path: nil)
        return project_root_for_goal(goal) if goal.dig("metric", "cwd").to_s == "project_root"

        path = present_string(workspace_path)
        path ||= synchronized_state do
          state = normalized_state
          worker = find_agent(state, worker_id == :unset ? goal.fetch("active_worker_id", nil) : worker_id)
          worker && present_string(worker.fetch("workspace_path", nil))
        end
        return path if path && Dir.exist?(path)

        project_root_for_goal(goal)
      end

      def project_root_for_goal(goal)
        synchronized_state do
          state = normalized_state
          project = find_project(state, goal.fetch("project_id", nil))
          project && present_string(project.fetch("root_path", nil))
        end
      end

      def goal_follow_up_agent_id(goal)
        worker_id = Goals::Record.settled_iterations(goal).reverse.filter_map { |iteration| iteration.fetch("attempt_worker_id", nil) }.first
        return nil unless present_string(worker_id)

        synchronized_state do
          state = normalized_state
          worker = find_agent(state, worker_id)
          next nil unless worker
          next nil unless worker.fetch("issue_id", nil).to_s == goal.fetch("issue_id", nil).to_s

          worker.fetch("id")
        end
      end

      def goal_next_tick_at(goal, now)
        seconds = goal.dig("budget", "min_seconds_between_iterations").to_i
        return nil unless seconds.positive?

        (Time.parse(now.to_s) + seconds).utc.iso8601
      rescue ArgumentError, TypeError
        nil
      end

      def goal_duration_seconds(started_at, now)
        return nil if blank?(started_at)

        (Time.parse(now.to_s) - Time.parse(started_at.to_s)).round
      rescue ArgumentError, TypeError
        nil
      end

      def goal_measurement_problem(measurement)
        return "the metric command timed out" if measurement.fetch("timed_out", false)
        return measurement.fetch("error") if present_string(measurement.fetch("error", nil))
        return measurement.fetch("parse_error") if present_string(measurement.fetch("parse_error", nil))

        "the metric command exited #{measurement.fetch("exit_status", "non-zero")}"
      end

      def trim_goal_iterations!(goal)
        iterations = Goals::Record.iterations(goal)
        return if iterations.length <= Goals::Record::ITERATION_HISTORY_LIMIT

        goal["iterations"] = iterations.last(Goals::Record::ITERATION_HISTORY_LIMIT)
      end

      def settle_goal_record!(goal, status:, stop_reason:, now:)
        goal["status"] = status
        goal["stop_reason"] = stop_reason
        goal["settled_at"] = now
        goal["updated_at"] = now
        goal["last_worker_id"] = goal.fetch("active_worker_id", nil) if present_string(goal.fetch("active_worker_id", nil))
        goal["active_worker_id"] = nil
        goal
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
        # Set by the kernel when it re-runs provisioning for a reservation that already exists.
        # Naming the record directly is what lets a worker be recovered or retried even when its
        # original spawn carried no command id, instead of silently spawning a second worker.
        reservation_agent_id = present_string(value_at(payload, "_reservation_agent_id", "reservation_agent_id"))
        requested_workspace_path = value_at(payload, "workspace_path", "WorkspacePath", "workspacePath")
        # Set by the kernel when it corrected a head's predicted issue id; kept on the worker and
        # in its spawn log so a corrected route is visible instead of silent.
        rerouted_from_issue_id = present_string(value_at(payload, "_rerouted_from_issue_id", "rerouted_from_issue_id"))
        # Set by the kernel when it restarts a worker whose session can no longer be replayed. The
        # successor takes over the dead worker's existing worktree and branch instead of allocating
        # a new one, because that is where the unfinished work already lives.
        inherit_workspace_agent_id = present_string(value_at(payload, "_inherit_workspace_from_agent_id", "inherit_workspace_from_agent_id"))
        session_restart_of_agent_id = present_string(value_at(payload, "_session_restart_of_agent_id", "session_restart_of_agent_id"))
        errors = []
        completion_continuation = normalized_completion_continuation(payload, errors: errors)

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
          existing ||= reserved_worker_for_retry(state, reservation_agent_id, issue)
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
                  completion_continuation: completion_continuation,
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
            # A retry of an inherited-workspace reservation must not allocate a new worktree: the
            # predecessor's checkout is the whole point of the restart.
            inherited_workspace = inherited_workspace_reservation?(workspace) ? workspace : nil
            active_provider = existing.fetch("harness", active_provider)
            # This is a fresh provisioning attempt for a reservation whose last attempt failed, so
            # the record says "allocating" again instead of still showing the previous failure.
            mark_worker_provisioning_attempt!(existing, now)
            existing_metadata = existing.fetch("harness_metadata", {}) || {}
            follow_up_of_agent_id = existing_metadata.fetch("follow_up_of_agent_id", follow_up_of_agent_id)
            replace_agent_id = existing_metadata.fetch("replace_agent_id", replace_agent_id)
            completion_continuation ||= worker_completion_continuation(existing)
            after_agent_id = present_string(existing.fetch("after_agent_id", nil)) ||
                             present_string(deferred_spawn_metadata(existing).fetch("after_agent_id", nil)) ||
                             present_string(after_agent_id)
          else
            agent_id = next_worker_id!(state, issue.fetch("id"))
            inherited_workspace = inherited_worker_workspace(state, inherit_workspace_agent_id) if inherit_workspace_agent_id
            if inherit_workspace_agent_id && !inherited_workspace
              return rejected_result(
                command_id,
                command_type,
                "Worker cannot take over #{inherit_workspace_agent_id}'s workspace because that workspace is no longer on disk.",
                ["inherited_workspace_unavailable"]
              )
            end

            workspace = inherited_workspace || resolve_worker_workspace(
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
              completion_continuation: completion_continuation,
              now: now,
              harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i
            )
            if inherit_workspace_agent_id || session_restart_of_agent_id
              # Persisted on the reservation so a provisioning retry inherits the same workspace and
              # keeps counting the restart chain instead of starting the recovery over.
              agent["harness_metadata"] = agent.fetch("harness_metadata").merge(
                "inherit_workspace_from_agent_id" => inherit_workspace_agent_id,
                "session_recovery" => session_restart_of_agent_id ? successor_session_recovery(state, session_restart_of_agent_id, now) : nil
              ).compact
            end
            state.fetch("agents") << agent
            issue.fetch("agent_ids") << agent_id unless issue.fetch("agent_ids").include?(agent_id)
            issue["status"] = "working"
            issue["updated_at"] = now
            project["status"] = "working"
            project["updated_at"] = now
            # The reservation is deliberately silent: the queued worker is already visible in the
            # AgentTree, and the "Spawned worker ..." log emitted once the harness session exists
            # carries the same routing details plus the *actual* workspace path/branch (a plan can
            # still be uniquified or adopted before creation). Provisioning that fails is reported
            # by fail_worker_reservation as an error log, so nothing goes unreported.
            # harness_metadata.provisioning_state remains the structured telemetry for this phase.
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
            "inherited_workspace" => inherited_workspace,
            "session_restart_of_agent_id" => session_restart_of_agent_id,
            "prompt" => prompt.to_s
          }
        end
        prompt = reservation.fetch("prompt", prompt)

        # An inherited workspace is already provisioned by definition: it is the predecessor's live
        # worktree, so it is adopted as-is and never re-created, re-branched, or cleaned up.
        workspace = reservation.fetch("inherited_workspace", nil) || resolve_worker_workspace(
          project: reservation.fetch("project"),
          issue: reservation.fetch("issue"),
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: reservation.fetch("agent_id"),
          task_title: worker_display_title(worker_title, reservation.fetch("issue")),
          create: true,
          progress_agent_id: reservation.fetch("agent_id")
        )
        if workspace.fetch("errors", []).any?
          return fail_worker_reservation(
            reservation,
            command_id: command_id,
            command_type: command_type,
            message: "Worker workspace provisioning failed: #{workspace.fetch("errors").join("; ")}",
            errors: workspace.fetch("errors"),
            workspace: workspace,
            recovery: workspace.fetch("recovery", nil)
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

      # What GetInfo says about a worker that is being provisioned, is waiting for a retry, or
      # gave up: what happened, how many attempts it has had, and what the user can do next.
      def worker_provisioning_info(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        state = metadata.fetch("provisioning_state", nil).to_s
        return nil if state.empty? || state == "ready"

        errors = Array(metadata.fetch("provisioning_errors", []))
        resumable = worker_awaiting_provisioning_retry?(agent)
        {
          "state" => state,
          "attempts" => metadata.fetch("provisioning_attempts", nil),
          "attempt_limit" => PROVISIONING_ATTEMPT_LIMIT,
          "failed_at" => metadata.fetch("provisioning_failed_at", nil),
          "errors" => errors.empty? ? nil : errors,
          "progress" => metadata.fetch("provisioning_progress", nil),
          "workspace_branch" => agent.fetch("workspace_branch", nil),
          "resumable" => resumable,
          "next_step" => provisioning_next_step(state, metadata, agent, resumable)
        }.compact
      end

      def provisioning_next_step(state, metadata, agent, resumable)
        recorded = present_string(metadata.fetch("provisioning_next_step", nil))
        case state
        when "allocating_workspace" then recorded || "Provisioning this worker's workspace; it starts once the checkout finishes."
        when "retry_pending" then recorded || "Meringue is retrying provisioning automatically."
        else
          return recorded unless resumable

          "Prompt #{agent.fetch("id")} to retry workspace provisioning, or kill it."
        end
      end

      def mark_worker_provisioning_attempt!(agent, now)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return unless PROVISIONING_RESUMABLE_STATES.include?(metadata.fetch("provisioning_state", nil).to_s)

        agent["status"] = "queued"
        agent["updated_at"] = now
        agent["harness_metadata"] = metadata.merge(
          "provisioning_state" => "allocating_workspace",
          "provisioning_attempt_started_at" => now
        )
      end

      # A worker whose workspace never got provisioned: the reservation, prompt, and issue are all
      # intact, there is no session to prompt, and provisioning can simply be run again.
      def worker_awaiting_provisioning_retry?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false if agent.fetch("status", nil) == "killed"
        return false if agent_has_session_reference?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        return false unless PROVISIONING_RESUMABLE_STATES.include?(metadata.fetch("provisioning_state", nil).to_s)

        !blank?(metadata.fetch("spawn_prompt", nil))
      end

      # Re-queues a worker whose provisioning failed, with the user's latest instruction as its
      # spawn prompt. Reconciliation owns the actual retry (`recover_worker_reservations`), so
      # this never runs a multi-minute checkout inside a kernel command.
      def requeue_worker_provisioning(state, command_id, command_type, agent, prompt)
        now = timestamp
        metadata = agent.fetch("harness_metadata", {}) || {}
        agent["status"] = "queued"
        agent["updated_at"] = now
        agent["harness_metadata"] = metadata.merge(
          "spawn_prompt" => prompt.to_s,
          "provisioning_state" => "retry_pending",
          # An explicit ask resets the automatic budget: the user decided this is worth retrying.
          "provisioning_attempts" => 0,
          "provisioning_retry_requested_at" => now,
          "provisioning_next_step" => nil,
          **instance_ownership_metadata
        ).compact
        refresh_worker_parent_statuses!(state, agent, now)
        agent_id = agent.fetch("id")
        message = "Retrying workspace provisioning for worker #{agent_id}; it starts as soon as its workspace is ready."
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "info",
          message: message,
          details: {
            "agent_id" => agent_id,
            "issue_id" => agent.fetch("issue_id", nil),
            "previous_provisioning_errors" => Array(metadata.fetch("provisioning_errors", []))
          }.compact
        )
        touch_state!(state, now)
        store.save(state)
        accepted_result(command_id, command_type, agent_id, message, deep_copy(agent), log_ids)
      end

      # Only an unstarted reservation on the named issue may be re-provisioned through
      # `_reservation_agent_id`; anything else would let a payload point provisioning at a
      # worker that is already running.
      def reserved_worker_for_retry(state, agent_id, issue)
        return nil unless agent_id

        agent = find_agent(state, agent_id)
        return nil unless agent && agent.fetch("type", nil) == "worker"
        return nil unless agent.fetch("issue_id", nil) == issue.fetch("id")
        return nil if agent_has_session_reference?(agent)

        agent
      end

      def worker_for_spawn_command(state, command_id)
        return nil if blank?(command_id)

        state.fetch("agents").find do |agent|
          agent.fetch("type", nil) == "worker" &&
            (agent.fetch("harness_metadata", {}) || {}).fetch("spawn_command_id", nil).to_s == command_id.to_s
        end
      end

      # --- Completion-triggered head continuations ----------------------------------------------
      #
      # A worker can carry a small continuation record telling the kernel to spawn a fresh head once
      # that worker completes. The continuation lives on the worker record, is claimed before the
      # head is spawned, and is also resolved from reconciliation so it survives restarts without a
      # sleeping worker session.
      def normalized_completion_continuation(payload, errors:)
        raw = value_at(payload, *COMPLETION_CONTINUATION_KEYS)
        return nil if raw.nil? || raw == false

        record = case raw
                 when String
                   { "prompt" => raw }
                 when Hash
                   raw.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
                 else
                   errors << "completion_continuation must be a string prompt or object"
                   return nil
                 end
        prompt = present_string(value_at(record, *COMPLETION_CONTINUATION_PROMPT_KEYS))
        unless prompt
          errors << "completion_continuation.prompt is required"
          return nil
        end

        include_result = value_at(record, "include_worker_result", "IncludeWorkerResult", "includeWorkerResult")
        {
          "prompt" => prompt,
          "include_worker_result" => include_result.nil? ? true : truthy?(include_result)
        }
      end

      def completion_continuation_record(continuation, now:, spawn_command_id: nil)
        return nil unless continuation.is_a?(Hash)

        {
          "state" => COMPLETION_CONTINUATION_STATE_WAITING,
          "prompt" => continuation.fetch("prompt"),
          "include_worker_result" => continuation.fetch("include_worker_result", true),
          "created_at" => now,
          "spawn_command_id" => present_string(spawn_command_id)
        }.compact
      end

      def worker_completion_continuation(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        continuation = metadata.fetch("completion_continuation", nil)
        continuation.is_a?(Hash) ? continuation : nil
      end

      def pending_completion_continuation?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "completed"

        state = worker_completion_continuation(agent)&.fetch("state", nil).to_s
        [COMPLETION_CONTINUATION_STATE_WAITING, COMPLETION_CONTINUATION_STATE_TRIGGERING].include?(state)
      end

      def resolve_completion_continuations(trigger:, only_agent_id: nil)
        decisions = claim_completion_continuations(trigger: trigger, only_agent_id: only_agent_id)
        decisions.map { |decision| trigger_completion_continuation_head(decision, trigger: trigger) }
      end

      def claim_completion_continuations(trigger:, only_agent_id: nil)
        synchronized_state do
          state = normalized_state
          now = timestamp
          decisions = []
          changed = false
          state.fetch("agents").each do |agent|
            next unless agent.fetch("type", nil) == "worker"
            next if only_agent_id && !Ids.same?(agent.fetch("id", nil), only_agent_id)

            continuation = worker_completion_continuation(agent)
            next unless continuation
            next unless agent.fetch("status", nil) == "completed"

            state_value = continuation.fetch("state", nil).to_s
            existing_head = existing_completion_continuation_head(state, agent)
            if existing_head
              next if continuation_terminal_state?(state_value)

              updated = continuation.merge(
                "state" => COMPLETION_CONTINUATION_STATE_TRIGGERED,
                "head_id" => existing_head.fetch("id"),
                "recovered_existing_head_at" => now
              ).compact
              agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
              agent["updated_at"] = now
              decisions << completion_continuation_decision(agent, updated, existing_head: deep_copy(existing_head))
              changed = true
              next
            end

            next unless state_value == COMPLETION_CONTINUATION_STATE_WAITING ||
                        (state_value == COMPLETION_CONTINUATION_STATE_TRIGGERING && !completion_continuation_owned_by_other_live_instance?(continuation))

            updated = continuation.merge(
              "state" => COMPLETION_CONTINUATION_STATE_TRIGGERING,
              "trigger" => trigger,
              "triggered_at" => continuation.fetch("triggered_at", nil) || now,
              "trigger_attempts" => continuation.fetch("trigger_attempts", 0).to_i + 1,
              **instance_ownership_metadata
            ).compact
            agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
            agent["updated_at"] = now
            decisions << completion_continuation_decision(agent, updated)
            changed = true
          end
          if changed
            touch_state!(state, now)
            store.save(state)
          end
          decisions
        end
      end

      def continuation_terminal_state?(state)
        [
          COMPLETION_CONTINUATION_STATE_TRIGGERED,
          COMPLETION_CONTINUATION_STATE_APPLIED,
          COMPLETION_CONTINUATION_STATE_FAILED
        ].include?(state.to_s)
      end

      def completion_continuation_owned_by_other_live_instance?(continuation)
        !other_live_instance_pid(
          continuation.fetch("owner_instance_id", nil),
          continuation.fetch("owner_instance_pid", nil),
          continuation.fetch("owner_instance_started_at", nil)
        ).nil?
      end

      def existing_completion_continuation_head(state, worker)
        worker_id = worker.fetch("id", nil).to_s
        state.fetch("agents").find do |agent|
          next false unless agent.fetch("type", nil) == "head"

          trigger = (agent.fetch("harness_metadata", {}) || {}).fetch("completion_trigger", nil)
          trigger.is_a?(Hash) && trigger.fetch("worker_agent_id", nil).to_s == worker_id
        end
      end

      def completion_continuation_decision(agent, continuation, existing_head: nil)
        {
          "agent" => deep_copy(agent),
          "continuation" => deep_copy(continuation),
          "existing_head" => existing_head
        }.compact
      end

      def trigger_completion_continuation_head(decision, trigger:)
        agent = decision.fetch("agent")
        continuation = decision.fetch("continuation")
        existing_head = decision.fetch("existing_head", nil)
        spawn_result = if existing_head
                         accepted_result(
                           nil,
                           "SpawnCompletionHead",
                           existing_head.fetch("id"),
                           "Completion head #{existing_head.fetch("id")} already exists for worker #{agent.fetch("id")}",
                           existing_head,
                           []
                         )
                       else
                         spawn_completion_head(agent, continuation, trigger: trigger)
                       end
        head_id = present_string(spawn_result.fetch("target_id", nil))
        apply_result = apply_completion_head_result(head_id) if spawn_result.fetch("status", nil) == "accepted" && head_id
        finalize_completion_continuation(agent.fetch("id"), spawn_result: spawn_result, apply_result: apply_result, trigger: trigger)
      rescue StandardError => e
        record_completion_continuation_failure(agent.fetch("id"), e, trigger: trigger)
      end

      def spawn_completion_head(agent, continuation, trigger:)
        spawn_head(
          nil,
          "SpawnHead",
          {
            "user_message" => completion_continuation_user_message(agent, continuation),
            "log_message" => "Worker #{agent.fetch("id")} completed; routing follow-on work.",
            "_log_source_type" => "kernel",
            "_log_source_id" => agent.fetch("id"),
            "_completion_trigger" => {
              "kind" => "worker_completion",
              "worker_agent_id" => agent.fetch("id"),
              "issue_id" => agent.fetch("issue_id", nil),
              "project_id" => agent.fetch("project_id", nil),
              "trigger" => trigger
            }.compact
          }
        )
      end

      def apply_completion_head_result(head_id)
        head = agent_record_snapshot(head_id)
        return nil unless head

        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", nil)
        return nil unless head_result.is_a?(Hash)
        return already_applied_head_result(nil, "ApplyHeadResult", head_id, metadata) if present_string(metadata.fetch("head_result_applied_at", nil))

        @head_result_mutex.synchronize do
          apply_head_result(nil, "ApplyHeadResult", "head_id" => head_id, "head_result" => head_result)
        end
      end

      def finalize_completion_continuation(agent_id, spawn_result:, apply_result:, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return spawn_result unless agent

          continuation = worker_completion_continuation(agent) || {}
          now = timestamp
          head_id = present_string(spawn_result.fetch("target_id", nil))
          spawn_accepted = spawn_result.fetch("status", nil) == "accepted"
          apply_status = apply_result&.fetch("status", nil)
          state_value = if !spawn_accepted
                          COMPLETION_CONTINUATION_STATE_FAILED
                        elsif apply_result && apply_status != "accepted"
                          COMPLETION_CONTINUATION_STATE_FAILED
                        elsif apply_status == "accepted"
                          COMPLETION_CONTINUATION_STATE_APPLIED
                        else
                          COMPLETION_CONTINUATION_STATE_TRIGGERED
                        end
          updated = continuation.merge(
            "state" => state_value,
            "head_id" => head_id,
            "trigger" => trigger,
            "spawn_head_status" => spawn_result.fetch("status", nil),
            "spawn_head_message" => spawn_result.fetch("message", nil),
            "apply_head_result_status" => apply_status,
            "apply_head_result_message" => apply_result&.fetch("message", nil),
            "completed_at" => now
          ).compact
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
          agent["updated_at"] = now
          level = state_value == COMPLETION_CONTINUATION_STATE_FAILED ? "error" : "info"
          message = if state_value == COMPLETION_CONTINUATION_STATE_FAILED
                      "Completion continuation for worker #{agent_id} failed#{head_id ? " after spawning #{head_id}" : ""}."
                    else
                      "Spawned head #{head_id} after worker #{agent_id} completed."
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: level,
            message: message,
            details: {
              "agent_id" => agent_id,
              "head_id" => head_id,
              "trigger" => trigger,
              "state" => state_value,
              "spawn_head_status" => spawn_result.fetch("status", nil),
              "apply_head_result_status" => apply_status
            }.compact
          )
          touch_state!(state, now)
          store.save(state)

          status = state_value == COMPLETION_CONTINUATION_STATE_FAILED ? "failed" : "accepted"
          result_payload = {
            "agent_id" => agent_id,
            "head_id" => head_id,
            "continuation" => updated,
            "spawn_head_result" => spawn_result,
            "apply_head_result" => apply_result
          }.compact
          if status == "accepted"
            accepted_result(nil, "SpawnCompletionHead", head_id, message, result_payload, (Array(spawn_result.fetch("log_entry_ids", [])) + Array(apply_result&.fetch("log_entry_ids", [])) + log_ids).uniq)
          else
            failure = failed_result(nil, "SpawnCompletionHead", message, [spawn_result.fetch("message", nil), apply_result&.fetch("message", nil)].compact)
            failure.merge("log_entry_ids" => (Array(failure.fetch("log_entry_ids", [])) + log_ids).uniq)
          end
        end
      end

      def record_completion_continuation_failure(agent_id, error, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return failed_result(nil, "SpawnCompletionHead", "Completion continuation failed: #{sanitized_error_message(error)}", [error.class.name, sanitized_error_message(error)]) unless agent

          now = timestamp
          continuation = worker_completion_continuation(agent) || {}
          updated = continuation.merge(
            "state" => COMPLETION_CONTINUATION_STATE_FAILED,
            "trigger" => trigger,
            "error_class" => error.class.name,
            "error_message" => sanitized_error_message(error),
            "failed_at" => now
          ).compact
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge("completion_continuation" => updated)
          agent["updated_at"] = now
          message = "Completion continuation for worker #{agent_id} failed: #{sanitized_error_message(error)}"
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: "error",
            message: message,
            details: { "agent_id" => agent_id, "trigger" => trigger, "error" => error_payload(error) }
          )
          touch_state!(state, now)
          store.save(state)
          failure = failed_result(nil, "SpawnCompletionHead", message, [error.class.name, sanitized_error_message(error)])
          failure.merge("log_entry_ids" => (Array(failure.fetch("log_entry_ids", [])) + log_ids).uniq)
        end
      end

      def completion_continuation_user_message(agent, continuation)
        metadata = agent.fetch("harness_metadata", {}) || {}
        lines = [
          "Meringue kernel continuation: worker #{agent.fetch("id")} completed and requested follow-on head routing.",
          "Use the worker's final result as context, then return a HeadResult with any follow-on kernel commands that should run now.",
          "Do not ask any worker to poll Meringue state, sleep, or wait for another worker; use kernel commands such as SpawnWorker, PromptAgent, after_agent_id, or questions instead.",
          "",
          "Worker:",
          "- id: #{agent.fetch("id")}",
          "- issue_id: #{agent.fetch("issue_id", nil)}",
          "- project_id: #{agent.fetch("project_id", nil)}",
          "- title: #{metadata.fetch("title", nil)}",
          "- workspace_branch: #{agent.fetch("workspace_branch", nil)}",
          "",
          "Continuation request:",
          continuation.fetch("prompt").to_s
        ]
        if continuation.fetch("include_worker_result", true)
          lines.concat([
            "",
            "Worker final result:",
            truncate_for_state(present_string(metadata.fetch("last_assistant_text", nil)) || "(no final assistant text was recorded)", COMPLETION_CONTINUATION_HANDOVER_MAX_CHARS)
          ])
        end
        lines.join("\n")
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

      def deferred_worker_default_failure_policy
        @deferred_worker_default_failure_policy || DEFERRED_WORKER_DEFAULT_FAILURE_POLICY
      end

      def normalized_deferred_failure_policy(payload)
        raw = present_string(value_at(payload, *DEFERRED_WORKER_FAILURE_POLICY_KEYS))
        return deferred_worker_default_failure_policy unless raw

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
        # A worker whose turn was cut short by a transport failure is `errored` but not finished: it
        # can still be continued, so queueing work behind it is legitimate rather than a rejection.
        if status == "errored" && failure_policy != "run" && worker_resumable_after_settle_failure?(predecessor)
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
                                chain_depth:, failure_policy:, include_predecessor_result:, completion_continuation:,
                                rerouted_from_issue_id:)
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
          completion_continuation: completion_continuation,
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
            "#{deferred.fetch("if_predecessor_fails", deferred_worker_default_failure_policy)}"
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
          "if_predecessor_fails" => deferred.fetch("if_predecessor_fails", deferred_worker_default_failure_policy)
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
        waiting = if repointed
                    base.merge(
                      "kind" => "repoint",
                      "predecessor" => deep_copy(predecessor),
                      "message" => deferred_repoint_message(agent.fetch("id"), recorded_id, predecessor_id)
                    )
                  end
        case status
        when "completed"
          activation
        when "errored"
          if base.fetch("if_predecessor_fails") == "run"
            activation
          elsif worker_resumable_after_settle_failure?(predecessor)
            # The predecessor did not fail its work: its turn was cut short by a transport failure
            # and can still be continued, so a dropped connection must not permanently cancel the
            # work queued behind it. Keep waiting; killing the predecessor still cancels the chain.
            waiting
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
          waiting
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
                                   after_agent_id: nil, completion_continuation: nil)
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
            "completion_continuation" => completion_continuation_record(completion_continuation, now: now, spawn_command_id: command_id),
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

      # The predecessor's workspace, adopted verbatim for a successor that continues its work.
      # `created` is forced to false so no failure path can ever delete a worktree this kernel did
      # not create - the commits in it are the only copy of the work being recovered.
      def inherited_worker_workspace(state, agent_id)
        predecessor = find_agent(state, agent_id)
        return nil unless predecessor.is_a?(Hash)

        workspace_path = present_string(predecessor.fetch("workspace_path", nil))
        return nil unless workspace_path && Dir.exist?(File.expand_path(workspace_path))

        metadata = predecessor.fetch("harness_metadata", {}) || {}
        plan = metadata.fetch("workspace_plan", nil)
        plan = plan.is_a?(Hash) ? deep_copy(plan) : {}
        plan = plan.merge(
          "created" => false,
          "inherited_from_agent_id" => predecessor.fetch("id"),
          "workspace_path" => workspace_path,
          "strategy" => plan.fetch("strategy", predecessor.fetch("workspace_strategy", nil)),
          "workspace_branch" => predecessor.fetch("workspace_branch", plan.fetch("workspace_branch", nil))
        ).compact
        {
          "workspace_path" => workspace_path,
          "workspace_strategy" => predecessor.fetch("workspace_strategy", nil),
          "workspace_branch" => predecessor.fetch("workspace_branch", nil),
          "note" => "took over #{predecessor.fetch("id")}'s existing workspace",
          "plan" => plan,
          "created" => false,
          "errors" => []
        }
      end

      def inherited_workspace_reservation?(workspace)
        plan = workspace.is_a?(Hash) ? workspace.fetch("plan", nil) : nil
        !!(plan.is_a?(Hash) && present_string(plan.fetch("inherited_from_agent_id", nil)))
      end

      # The successor's copy of the recovery record: it remembers which worker it took over and how
      # deep the restart chain is, which is what stops an endless chain of restarts.
      def successor_session_recovery(state, predecessor_id, now)
        predecessor = find_agent(state, predecessor_id)
        depth = predecessor ? worker_session_restart_chain_depth(predecessor) : 0
        {
          "state" => "restarted_session",
          "restarted_from_agent_id" => predecessor_id,
          "restarted_at" => now,
          "restart_chain_depth" => depth + 1
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

      # A failed provisioning attempt must not end the worker's existence. The reservation, its
      # prompt, its issue, and its routing are all still valid; only the workspace is missing. So
      # a failure the workspace manager classified as recoverable degrades the worker instead of
      # erroring it into a dead end with no session, nothing to prompt, and nothing to replace:
      #
      #   retry  -> the worker stays `queued` in `retry_pending`. `recover_worker_reservations`
      #             (reconciliation, every 2s) provisions it again with no user action, at most
      #             PROVISIONING_ATTEMPT_LIMIT times in total.
      #   resume -> the worker becomes `blocked` in `retry_exhausted`. It keeps its record, its
      #             prompt, and its failure reason, and prompting it re-queues provisioning.
      #   none   -> today's behavior: `errored`, because another identical attempt would fail
      #             identically. Prompting it still re-queues provisioning rather than rejecting.
      #
      # The reason always stays in harness_metadata (`provisioning_errors`, `provisioning_state`,
      # `provisioning_attempts`, `workspace_plan`) so the AgentTree and GetInfo can explain it.
      def fail_worker_reservation(reservation, command_id:, command_type:, message:, errors:, workspace:, recovery: nil)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, reservation.fetch("agent_id"))
          degradation = nil
          if agent
            now = timestamp
            degradation = provisioning_degradation(agent, recovery)
            message = [message, degradation.fetch("next_step", nil)].compact.join(" ")
            agent["status"] = degradation.fetch("status")
            agent["updated_at"] = now
            agent["workspace_path"] = workspace.fetch("workspace_path", agent.fetch("workspace_path", nil))
            agent["workspace_strategy"] = workspace.fetch("workspace_strategy", agent.fetch("workspace_strategy", nil))
            agent["workspace_branch"] = workspace.fetch("workspace_branch", agent.fetch("workspace_branch", nil))
            agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
              "provisioning_state" => degradation.fetch("provisioning_state"),
              "provisioning_failed_at" => now,
              "provisioning_errors" => Array(errors),
              "provisioning_attempts" => degradation.fetch("attempts"),
              "provisioning_attempt_limit" => PROVISIONING_ATTEMPT_LIMIT,
              "provisioning_recovery" => degradation.fetch("recovery"),
              "provisioning_next_step" => degradation.fetch("next_step", nil),
              "provisioning_progress" => nil,
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
              level: degradation.fetch("log_level"),
              message: message,
              details: {
                "issue_id" => agent.fetch("issue_id", nil),
                "errors" => Array(errors),
                "provisioning_state" => degradation.fetch("provisioning_state"),
                "provisioning_attempts" => degradation.fetch("attempts"),
                "workspace" => workspace
              }
            )
            log_workspace_cleanup_warnings(state, agent.fetch("id"), workspace)
            touch_state!(state, now)
            store.save(state)
          end
          failed_result(command_id, command_type, message, Array(errors))
        end
      end

      def provisioning_degradation(agent, recovery)
        metadata = agent.fetch("harness_metadata", {}) || {}
        attempts = metadata.fetch("provisioning_attempts", 0).to_i + 1
        case recovery.to_s
        when Workspace::Manager::RECOVERY_RETRY
          if attempts < PROVISIONING_ATTEMPT_LIMIT
            {
              "status" => "queued",
              "provisioning_state" => "retry_pending",
              "recovery" => Workspace::Manager::RECOVERY_RETRY,
              "attempts" => attempts,
              "log_level" => "warning",
              "next_step" => "Retrying automatically (attempt #{attempts + 1} of #{PROVISIONING_ATTEMPT_LIMIT})."
            }
          else
            provisioning_resumable_degradation(attempts)
          end
        when Workspace::Manager::RECOVERY_RESUME
          provisioning_resumable_degradation(attempts)
        else
          {
            "status" => "errored",
            "provisioning_state" => "failed",
            "recovery" => Workspace::Manager::RECOVERY_NONE,
            "attempts" => attempts,
            "log_level" => "error",
            "next_step" => nil
          }
        end
      end

      def provisioning_resumable_degradation(attempts)
        {
          "status" => "blocked",
          "provisioning_state" => "retry_exhausted",
          "recovery" => Workspace::Manager::RECOVERY_RESUME,
          "attempts" => attempts,
          "log_level" => "error",
          "next_step" => "Prompt this worker to retry provisioning, or kill it."
        }
      end

      # Cleanup that could not finish safely is reported, never swallowed: a leftover worktree
      # registration or a branch Meringue refused to delete is something the user has to know
      # about, and the warning names the git command that clears it.
      def log_workspace_cleanup_warnings(state, agent_id, workspace)
        cleanup = workspace.is_a?(Hash) ? (workspace["cleanup"] || workspace.dig("plan", "cleanup")) : nil
        warnings = cleanup.is_a?(Hash) ? Array(cleanup["warnings"]).compact : []
        return [] if warnings.empty?

        append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "warning",
          message: "Workspace cleanup for #{agent_id} could not finish: #{warnings.join("; ")}",
          details: { "agent_id" => agent_id, "cleanup" => cleanup }
        )
      end

      def build_head_agent(head_id:, now:, provider:, runner:, harness_generation: 0, user_message: nil, question_id: nil,
                           selected_target: nil, retry_of: nil, completion_trigger: nil,
                           snapshot_issue_ids: [], snapshot_project_ids: [], snapshot_unapplied_head_ids: [], snapshot_counters: {})
        retry_of = nil unless retry_of.is_a?(Hash)
        completion_trigger = nil unless completion_trigger.is_a?(Hash)
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
            # A follow-up head can be spawned while an earlier head is still routing. If that
            # earlier, already-visible head creates an issue before this head's result applies,
            # this head may legitimately read it from state and refine or staff it even though the
            # issue id was not in snapshot_issue_ids yet.
            "snapshot_unapplied_head_ids" => Array(snapshot_unapplied_head_ids),
            "snapshot_counters" => (snapshot_counters.is_a?(Hash) ? snapshot_counters : {}),
            # Lineage for a head that retries a failed head. `retry_of_head_id` is what makes the
            # log line, the AgentTree, and a later recovery say "this is H13's request again".
            "retry_of_head_id" => retry_of && retry_of.fetch("head_id", nil),
            "retry_case" => retry_of && retry_of.fetch("case", nil),
            "retry_strategy" => retry_of ? "respawn" : nil,
            "completion_trigger" => completion_trigger,
            "head_request" => {
              "user_message" => user_message,
              "question_id" => question_id,
              "selected_target" => selected_target,
              "retry_of_head_id" => retry_of && retry_of.fetch("head_id", nil)
            }.compact
          }.compact,
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

        # Killing a goal is the destructive stop: the loop ends and the attempt session it
        # currently owns is killed with it. `StopGoal` is the variant that keeps the session.
        if (goal = find_goal(state, target_id))
          return kill_goal!(state, goal, now)
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

      def kill_goal!(state, goal, now)
        settle_goal_record!(goal, status: "killed", stop_reason: "killed", now: now)
        worker_id = present_string(goal.fetch("last_worker_id", nil))
        worker = worker_id && find_agent(state, worker_id)
        return [] unless worker && !TERMINAL_AGENT_STATUSES.include?(worker.fetch("status", nil))

        mark_agent_killed!(worker, now)
        [worker.fetch("id")]
      end

      # A killed issue must not leave its goal ticking, so goals settle with the subtree.
      def kill_goals_for_issues!(state, issue_ids, now)
        goals_for_issue_ids(state, issue_ids).each do |goal|
          next unless Goals::Record.loop_active?(goal)

          settle_goal_record!(goal, status: "killed", stop_reason: "killed", now: now)
        end
      end

      def kill_issue_subtree!(state, issue, now)
        issue["status"] = "killed"
        issue["updated_at"] = now
        kill_goals_for_issues!(state, [issue.fetch("id")], now)
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

      def resolve_worker_workspace(project:, issue:, requested_workspace_path:, preview_agent_id:, task_title:, create: false,
                                   progress_agent_id: nil)
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
                 allocate_worker_workspace_with_progress(
                   project_root: project.fetch("root_path"),
                   project_id: project.fetch("id"),
                   issue_id: issue.fetch("id"),
                   agent_id: preview_agent_id,
                   task_title: task_title,
                   progress_agent_id: progress_agent_id
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
            "errors" => plan.fetch("errors"),
            # How the manager classified the failure. The kernel turns this into the worker's
            # degraded state instead of guessing from the error text.
            "recovery" => plan.fetch("recovery", nil),
            "failure_kind" => plan.fetch("failure_kind", nil),
            "cleanup" => plan.fetch("cleanup", nil)
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

      # Provisioning a monorepo worktree is minutes of honest work. It runs off the render thread
      # and holds no state lock, but a user watching a queued worker still deserves to know the
      # difference between "checking out 478k files" and "wedged", so a long allocation reports
      # progress into the worker record and the log instead of going silent.
      def allocate_worker_workspace_with_progress(project_root:, project_id:, issue_id:, agent_id:, task_title:, progress_agent_id:)
        arguments = {
          project_root: project_root,
          project_id: project_id,
          issue_id: issue_id,
          agent_id: agent_id,
          task_title: task_title
        }
        return workspace_manager.allocate_worker_workspace(**arguments) unless progress_agent_id
        unless workspace_manager.method(:allocate_worker_workspace).parameters.any? { |(_kind, name)| name == :progress }
          # A workspace manager double (or an older implementation) may not accept `progress`.
          # Provisioning must never fail because progress reporting is unavailable.
          return workspace_manager.allocate_worker_workspace(**arguments)
        end

        workspace_manager.allocate_worker_workspace(
          **arguments,
          progress: worker_provisioning_progress_reporter(progress_agent_id)
        )
      end

      def worker_provisioning_progress_reporter(agent_id)
        last_reported = 0.0
        lambda do |progress|
          elapsed = progress.fetch("elapsed", 0).to_f
          next if elapsed - last_reported < PROVISIONING_PROGRESS_INTERVAL_SECONDS

          last_reported = elapsed
          record_worker_provisioning_progress(agent_id, progress)
        end
      end

      def record_worker_provisioning_progress(agent_id, progress)
        detail = present_string(progress.fetch("detail", nil))
        elapsed = progress.fetch("elapsed", 0).to_f
        command = present_string(progress.fetch("command", nil)) || "workspace provisioning"
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next unless agent

          now = timestamp
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "provisioning_progress" => {
              "command" => command,
              "elapsed_seconds" => progress.fetch("elapsed", nil),
              "quiet_for_seconds" => progress.fetch("quiet_for", nil),
              "detail" => detail,
              "observed_at" => now
            }.compact
          )
          agent["updated_at"] = now
          append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: "info",
            message: "Still provisioning worker #{agent_id}: #{command} has been running for " \
                     "#{elapsed.round}s#{detail ? " (#{detail})" : ""}.",
            details: { "agent_id" => agent_id, "elapsed_seconds" => progress.fetch("elapsed", nil), "detail" => detail }.compact
          )
          touch_state!(state, now)
          store.save(state)
        end
      rescue StandardError
        nil
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
      # issues its own batch created. "Could see" includes the spawn snapshot and issues created by
      # heads that were already visible and still unapplied when this head spawned, because a
      # refinement head may read the updated state file after that earlier head lands. An
      # unverifiable prediction is remapped to this batch's issue when that is unambiguous, and
      # rejected otherwise, so work never routes onto another head's issue. Pre-existing issue ids
      # keep working unchanged.
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

      # An issue is visible to a head when the head's spawn snapshot contained it, when this head's
      # own batch created it, or when a head already visible and still unapplied at spawn time
      # created it before this head returned its result. The last case covers natural-language
      # refinements that arrive while the original routing head is still landing: the refinement
      # head may read the updated state file and route to that just-minted issue without leaving a
      # spurious "could not have seen it" rejection.
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
          snapshot_ids_tracked = snapshot_issue_ids.is_a?(Array)
          next true if snapshot_ids_tracked && Array(snapshot_issue_ids).include?(issue.fetch("id"))

          originating_head_id = present_string(issue.fetch("originating_head_id", nil))
          snapshot_unapplied_head_ids = metadata.fetch("snapshot_unapplied_head_ids", nil)
          if originating_head_id && snapshot_unapplied_head_ids.is_a?(Array)
            next true if snapshot_unapplied_head_ids.map(&:to_s).include?(originating_head_id)
          end
          next false if snapshot_ids_tracked

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
        # An issue that owns a live goal loop is not finished just because the workers it has
        # spawned so far are: the goal decides completion, and a `completed` issue between
        # iterations would also make the issue prunable mid-goal.
        active_goal = issue_has_active_goal?(state, issue.fetch("id", nil))
        workers = state.fetch("agents").select do |candidate|
          candidate.fetch("type", nil) == "worker" && candidate.fetch("issue_id", nil) == issue.fetch("id") &&
            candidate.fetch("status", nil) != "killed"
        end
        return if workers.empty?

        issue["status"] = if workers.all? { |worker| worker.fetch("status", nil) == "completed" }
                            active_goal ? "working" : "completed"
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
        state["counters"]["goals"] ||= max_numeric_suffix(state.fetch("goals", []), Goals::Record::ID_PATTERN)
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
      # to their durable owning issue; issue selections target themselves; a head
      # is a top-level node that resolves to itself (see `head_selected_target`).
      def resolve_selected_head_target(state, requested_target)
        return [nil, nil] if requested_target.nil?

        selected_id = selected_target_id(requested_target)
        # A blank or shapeless selection carries no destination, so it means the
        # same thing as no selection: route the message normally instead of
        # rejecting it for an empty routing hint.
        return [nil, nil] if selected_id.nil?

        issue = find_issue(state, selected_id)
        agent = nil
        unless issue
          agent = find_agent(state, selected_id)
          unless agent
            return [nil, { "code" => "selected_target_not_found", "message" => "selected target #{selected_id} no longer exists." }]
          end

          # A head owns no issue, so it is its own target. A failed head is retried before the
          # spawn ever gets here; a head that is still routing keeps its identity on the message
          # instead of the message being dropped for having "no issue".
          return [head_selected_target(state, agent, selected_id), nil] if agent.fetch("type", nil) == "head"

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

      def selected_target_id(requested_target)
        selected_id = if requested_target.is_a?(Hash)
                        value_at(requested_target, "selected_id", "SelectedID", "selectedId", "id")
                      else
                        requested_target
                      end
        selected_id = selected_id.to_s.strip
        selected_id.empty? ? nil : selected_id
      end

      # The head record a selection names when that head can be retried right now, or nil. Used to
      # turn "select the failed head and type a message" into a retry before a new head is spawned.
      def selected_head_retry_target(requested_target)
        selected_id = selected_target_id(requested_target)
        return nil unless selected_id

        synchronized_state do
          agent = find_agent(normalized_state, selected_id)
          next nil unless agent && agent.fetch("type", nil) == "head"
          next nil unless State::Models.head_retry_target?(agent)

          deep_copy(agent)
        end
      end

      def head_selected_target(state, head, selected_id)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        plan = head_retry_plan(state, head.fetch("id"))
        {
          "selected_id" => selected_id,
          "selected_type" => "head",
          "selected_agent_id" => head.fetch("id"),
          "selected_agent_type" => "head",
          "selected_agent_title" => metadata.fetch("title", nil),
          "selected_head_status" => head.fetch("status", nil),
          "head_retry_eligible" => plan.fetch("eligible"),
          "head_retry_note" => plan.fetch("eligible") ? nil : plan.fetch("message", nil)
        }.compact
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
        settled = completed_session?(state_ref)
        assistant_text = settled ? safe_last_assistant_text(client, state_ref) : nil
        # A settled session is only a completion when nothing says its turn died.
        settle_failure = if settled && agent.fetch("type", nil) == "worker"
                           settle_failure_from_evidence(
                             session_ref: state_ref,
                             events: events,
                             last_assistant_text: assistant_text,
                             client: client
                           )
                         end

        result = {
          "agent_id" => agent.fetch("id"),
          "agent_type" => agent.fetch("type", nil),
          "state" => settle_poll_state(settled: settled, settle_failure: settle_failure),
          "session_ref" => state_ref,
          "events" => events,
          "last_assistant_text" => assistant_text
        }
        result["settle_failure"] = settle_failure if settle_failure
        result
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
        when "settle_failed"
          apply_settle_failure_from_poll(poll_result)
        when "errored"
          apply_reconcile_error_from_poll(poll_result)
        else
          poll_result.merge("changed" => false, "log_entry_ids" => [])
        end
      end

      def settle_poll_state(settled:, settle_failure: nil)
        return "working" unless settled
        return "settle_failed" if settle_failure

        "completed"
      end

      # A dead turn is recorded once. Re-observing it on the next 2s reconciliation pass changes
      # nothing and logs nothing.
      def apply_settle_failure_from_poll(poll_result)
        result = mark_worker_settle_failed(
          agent_id: poll_result.fetch("agent_id"),
          settle_failure: poll_result.fetch("settle_failure", {}),
          harness_events: poll_result.fetch("events", []),
          last_assistant_text: poll_result.fetch("last_assistant_text", nil),
          session_ref: poll_result.fetch("session_ref", nil)
        )
        log_entry_ids = result.fetch("log_entry_ids", [])
        poll_result.merge(
          "changed" => result.fetch("status", nil) == "accepted" && log_entry_ids.any?,
          "settle_failure_result" => result,
          "log_entry_ids" => log_entry_ids
        )
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
          # The session is streaming again, so a recorded dead-turn reason is stale.
          clear_settle_failure!(agent)
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
          # A session the provider already refused to replay is not retried: the resume would send
          # the same rejected transcript. It is recovered by a fresh session instead.
          !worker_session_unreplayable?(agent) &&
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
        head_request_from_metadata(agent) || synchronized_state { head_request_from_logs(normalized_state, agent) }
      end

      # Same lookup for callers that already hold the state lock (head retry planning).
      def head_request_in_state(state, agent)
        head_request_from_metadata(agent) || head_request_from_logs(state, agent)
      end

      def head_request_from_metadata(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        request = metadata.fetch("head_request", {}) || {}
        request = {} unless request.is_a?(Hash)
        user_message = present_string(request.fetch("user_message", nil))
        return nil unless user_message

        {
          "user_message" => user_message,
          "question_id" => present_string(request.fetch("question_id", nil)),
          "selected_target" => request.fetch("selected_target", nil)
        }.compact
      end

      # Older head records (and records written before `head_request` existed) still have the
      # user's own prompt in the log the kernel wrote when it spawned them.
      def head_request_from_logs(state, agent)
        log = state.fetch("logs", []).reverse.find do |entry|
          entry.fetch("source_type", nil) == "user" && entry.dig("details", "head_id").to_s == agent.fetch("id").to_s
        end
        message = log && present_string(log.fetch("message", nil))
        return nil unless message

        {
          "user_message" => message,
          "question_id" => present_string(log.dig("details", "question_id")),
          "selected_target" => log.dig("details", "selected_target")
        }.compact
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

      # "Not streaming any more" is the only thing a harness state call can tell us, and it is
      # true both for a finished turn and for a turn that died mid-flight. Callers must pair this
      # with `settle_failure_from_evidence` before recording a completion.
      def completed_session?(session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        return true if metadata.fetch("completed", false)

        pi_state = metadata.fetch("pi_state", {}) || {}
        return true if pi_state["completed"]

        !session_ref.fetch("is_streaming", false)
      end

      # Evidence that a settled turn ended without finishing, in order of authority:
      #   1. the harness's own turn outcome (Pi reads the stop reason of the turn's final
      #      assistant message, so a dropped connection is still visible after the fact)
      #   2. a turn outcome a harness already attached to the session ref metadata
      #   3. session events proving the transport died, but only when the settled turn produced
      #      no final assistant message at all
      # Returns nil when there is no failure evidence, which keeps genuine completions intact.
      def settle_failure_from_evidence(session_ref: nil, events: [], last_assistant_text: nil, client: nil)
        failure = settle_failure_from_turn_outcome(turn_outcome_evidence(client, session_ref))
        return failure if failure
        return nil if present_string(last_assistant_text)

        settle_failure_from_events(events)
      end

      def worker_settle_failure(agent_id:, session_ref:, events:, last_assistant_text:)
        settle_failure_from_evidence(
          session_ref: session_ref,
          events: events,
          last_assistant_text: last_assistant_text,
          client: session_ref ? settle_evidence_client(agent_id) : nil
        )
      end

      def settle_evidence_client(agent_id)
        agent = synchronized_state { find_agent(normalized_state, agent_id.to_s) }
        return nil unless agent

        harness_client_for_agent(agent)
      rescue StandardError
        nil
      end

      def turn_outcome_evidence(client, session_ref)
        from_client = safe_turn_outcome(client, session_ref)
        return from_client if from_client.is_a?(Hash)

        metadata = session_ref.is_a?(Hash) ? (session_ref["metadata"] || session_ref[:metadata] || {}) : {}
        outcome = metadata.is_a?(Hash) ? (metadata["turn_outcome"] || metadata[:turn_outcome]) : nil
        outcome.is_a?(Hash) ? stringify_keys(outcome) : nil
      end

      def safe_turn_outcome(client, session_ref)
        return nil unless client && session_ref
        return nil unless client.respond_to?(:turn_outcome)

        outcome = client.turn_outcome(session_ref)
        outcome.is_a?(Hash) ? stringify_keys(outcome) : nil
      rescue StandardError
        nil
      end

      def settle_failure_from_turn_outcome(outcome)
        return nil unless outcome.is_a?(Hash)
        return nil unless SETTLE_FAILURE_TURN_STATES.include?(outcome.fetch("state", nil).to_s)

        error_message = present_string(outcome.fetch("error_message", nil))
        {
          "kind" => present_string(outcome.fetch("kind", nil)) || settle_failure_kind(error_message),
          "reason" => present_string(outcome.fetch("reason", nil)) || settle_failure_reason(error_message),
          "source" => "harness_turn_outcome",
          "stop_reason" => present_string(outcome.fetch("stop_reason", nil)),
          "error_message" => error_message,
          "last_assistant_text" => present_string(outcome.fetch("last_assistant_text", nil))
        }.compact
      end

      def settle_failure_from_events(events)
        Array(events).each do |event|
          next unless event.is_a?(Hash)

          failure = settle_failure_from_event(stringify_keys(event))
          return failure if failure
        end

        nil
      end

      def settle_failure_from_event(event)
        event_type = event.fetch("type", "").to_s
        message = event.fetch("message", nil)
        message = message.is_a?(Hash) ? message : {}
        stop_reason = message["stopReason"] || message["stop_reason"] || event["stopReason"] || event["stop_reason"]
        error_message = present_string(
          message["errorMessage"] || message["error_message"] ||
            event["errorMessage"] || event["error_message"] || event["error"]
        )

        if SETTLE_FAILURE_EVENT_STOP_REASONS.include?(stop_reason.to_s)
          return {
            "kind" => settle_failure_kind(error_message),
            "reason" => settle_failure_reason(error_message),
            "source" => "harness_events",
            "event_type" => event_type,
            "stop_reason" => stop_reason.to_s,
            "error_message" => error_message
          }.compact
        end

        return nil unless SETTLE_FAILURE_TRANSPORT_EVENT_TYPES.include?(event_type)

        {
          "kind" => "transport_failure",
          "reason" => "its agent session ended before it produced a result",
          "source" => "harness_events",
          "event_type" => event_type,
          "error_message" => error_message
        }.compact
      end

      def settle_failure_kind(error_message)
        return SETTLE_FAILURE_UNREPLAYABLE_KIND if SETTLE_FAILURE_UNREPLAYABLE_PATTERN.match?(error_message.to_s)

        SETTLE_FAILURE_NETWORK_PATTERN.match?(error_message.to_s) ? "network_failure" : "provider_error"
      end

      def settle_failure_reason(error_message)
        detail = error_message.to_s.strip
        if SETTLE_FAILURE_UNREPLAYABLE_PATTERN.match?(detail)
          "its saved session can no longer be replayed to the model, so resuming it fails the same way every time (#{detail})"
        elsif SETTLE_FAILURE_NETWORK_PATTERN.match?(detail)
          "its model request failed mid-turn (network error: #{detail})"
        elsif detail.empty?
          "its agent turn ended without finishing"
        else
          "its agent turn ended without finishing (#{detail})"
        end
      end

      def settle_failure_record(settle_failure)
        failure = settle_failure.is_a?(Hash) ? stringify_keys(settle_failure) : {}
        reason = present_string(failure.fetch("reason", nil)) || "its agent turn ended without finishing"
        # The worker's own final text is stored once, on the record; do not duplicate it here.
        failure.reject { |key, _| key == "last_assistant_text" }.merge(
          "kind" => present_string(failure.fetch("kind", nil)) || "turn_failed",
          "reason" => truncate_for_state(reason, ERROR_MESSAGE_MAX_BYTES),
          "source" => present_string(failure.fetch("source", nil)) || "kernel"
        ).compact
      end

      def settle_failure_status_reason(failure)
        "errored without finishing: #{failure.fetch("reason")}"
      end

      def settle_failure_signature(failure)
        return nil unless failure.is_a?(Hash)

        %w[kind reason source stop_reason error_message event_type].map { |key| failure.fetch(key, nil).to_s }.join("|")
      end

      def settle_failure_already_recorded?(agent, failure)
        return false unless agent.fetch("status", nil) == "errored"

        existing = (agent.fetch("harness_metadata", {}) || {}).fetch("settle_failure", nil)
        return false unless existing.is_a?(Hash)

        settle_failure_signature(existing) == settle_failure_signature(failure)
      end

      # A prompt that landed after the turn died is the recovery. Persisted evidence of that old
      # turn must not error the worker again while it is working on the new prompt.
      def stale_settle_failure_evidence?(agent, failure)
        metadata = agent.fetch("harness_metadata", {}) || {}
        prompted_at = parse_time_or_nil(metadata.fetch("last_prompted_at", nil))
        return false unless prompted_at

        turn_ended_at = parse_time_or_nil(failure.fetch("turn_ended_at", nil))
        return turn_ended_at <= prompted_at if turn_ended_at

        # Harnesses that cannot timestamp the turn fall back to "this exact failure was already
        # recorded and then prompted past".
        previous = metadata.fetch("previous_settle_failure", nil)
        return false unless previous.is_a?(Hash) && settle_failure_signature(previous) == settle_failure_signature(failure)

        detected_at = parse_time_or_nil(previous.fetch("detected_at", nil))
        detected_at ? detected_at <= prompted_at : false
      end

      # A worker whose turn died still owns a live, resumable harness session, its worktree, and
      # its branch, so it can be prompted to continue. That is what separates this errored state
      # from a worker whose session is gone.
      def worker_resumable_after_settle_failure?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "errored"
        # The one dead turn that resuming can never repair: the provider rejected the saved
        # transcript, so sending it again is the same request. Such a worker is recovered by
        # restarting its work in a fresh session on the same worktree, never by a resume.
        return false if worker_session_unreplayable?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.fetch("settle_failure", nil).is_a?(Hash) && agent_has_session_reference?(agent)
      end

      # --- sessions the provider refuses to replay -------------------------------------------
      #
      # A worker's turn can die in a way no resume can fix: the model provider rejects the saved
      # transcript itself (an interrupted assistant turn whose `thinking` blocks it will not accept
      # back). Resuming replays exactly the same turn, so every attempt fails identically and the
      # worker - plus everything queued behind it - is dead-ended.
      #
      # The transcript belongs to the harness, so Meringue does not try to repair it. What it owns
      # is the workspace: the worktree, the branch, and the work already committed there. So the
      # recovery is a fresh session on the *same* worktree and branch, spawned as a replacement so
      # queued dependents follow the successor instead of waiting on a session that cannot start.
      def unreplayable_session_failure?(failure)
        return false unless failure.is_a?(Hash)
        return true if failure.fetch("kind", nil).to_s == SETTLE_FAILURE_UNREPLAYABLE_KIND

        SETTLE_FAILURE_UNREPLAYABLE_PATTERN.match?(failure.fetch("error_message", nil).to_s)
      end

      def worker_session_unreplayable?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        unreplayable_session_failure?(metadata.fetch("settle_failure", nil))
      end

      def worker_session_recovery(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        metadata = {} unless metadata.is_a?(Hash)
        recovery = metadata.fetch("session_recovery", {}) || {}
        recovery.is_a?(Hash) ? recovery : {}
      end

      def worker_session_restart_chain_depth(agent)
        worker_session_recovery(agent).fetch("restart_chain_depth", 0).to_i
      end

      # Everything that must be true before the kernel spends a fresh session on this recovery.
      def worker_session_restart_eligible?(agent)
        return false unless worker_session_unreplayable?(agent)
        return false if agent.fetch("status", nil) == "killed"

        recovery = worker_session_recovery(agent)
        return false if present_string(recovery.fetch("restarted_by_agent_id", nil))
        return false if recovery.fetch("restart_attempts", 0).to_i >= WORKER_SESSION_RESTART_MAX_ATTEMPTS
        return false if worker_session_restart_chain_depth(agent) >= WORKER_SESSION_RESTART_MAX_CHAIN_DEPTH
        return false if present_string(agent.fetch("replaced_by_agent_id", nil))

        workspace_path = present_string(agent.fetch("workspace_path", nil))
        !!workspace_path && Dir.exist?(File.expand_path(workspace_path))
      end

      def unreplayable_session_recovery_record(agent, now, extra = {})
        recovery = worker_session_recovery(agent)
        recovery.merge(
          "state" => "session_unreplayable",
          "detected_at" => recovery.fetch("detected_at", nil) || now,
          "recommended_action" => "restart_session_in_place",
          "workspace_path" => agent.fetch("workspace_path", nil),
          "workspace_branch" => agent.fetch("workspace_branch", nil),
          "restart_attempts" => recovery.fetch("restart_attempts", 0).to_i,
          "restart_chain_depth" => worker_session_restart_chain_depth(agent)
        ).merge(extra).compact
      end

      # What the record, the log line, and the focused pane tell the user. Deliberately concrete:
      # the branch is what they care about, because it is where the work already is.
      def unreplayable_session_recovery_advice(agent)
        branch = present_string(agent.fetch("workspace_branch", nil))
        location = branch ? "worktree and branch #{branch}" : "worktree"
        "Its #{location} still hold the work, so Meringue does not resume this session: continuing " \
          "means a fresh session on the same workspace."
      end

      def settle_failure_log_message(agent, failure)
        base = "Worker #{agent.fetch("id")} errored without finishing: #{failure.fetch("reason")}"
        return base unless unreplayable_session_failure?(failure)

        "#{base}. #{unreplayable_session_recovery_advice(agent)}"
      end

      def worker_session_restart_command_id(agent_id, attempt)
        "session-restart-#{agent_id}-#{attempt}"
      end

      # Reserves this worker's single in-place restart under the state lock, so two reconcile passes
      # (or two kernel instances sharing one state file) cannot both spend it.
      def claim_worker_session_restart(agent_id, trigger:)
        synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          return { "claimed" => false, "reason" => "agent_not_found" } unless agent
          return { "claimed" => false, "reason" => "not_eligible" } unless worker_session_restart_eligible?(agent)

          now = timestamp
          attempt = worker_session_recovery(agent).fetch("restart_attempts", 0).to_i + 1
          metadata = agent.fetch("harness_metadata", {}) || {}
          agent["harness_metadata"] = metadata.merge(
            "session_recovery" => unreplayable_session_recovery_record(
              agent,
              now,
              "restart_attempts" => attempt,
              "restart_claimed_at" => now,
              "restart_trigger" => trigger.to_s
            )
          )
          agent["updated_at"] = now
          touch_state!(state, now)
          store.save(state)
          {
            "claimed" => true,
            "agent" => deep_copy(agent),
            "attempt" => attempt,
            "restart_command_id" => worker_session_restart_command_id(agent_id.to_s, attempt)
          }
        end
      end

      # The recovery itself: a replacement worker with a fresh session on the dead worker's own
      # worktree and branch. Spawning it as a replacement is what unblocks the queue - dependents
      # waiting on the dead worker are repointed at the successor by SpawnWorker itself.
      #
      # Must be called *outside* `synchronized_state`: it applies a SpawnWorker command.
      def restart_unreplayable_worker_session(agent_id, trigger:, instruction: nil)
        claim = claim_worker_session_restart(agent_id, trigger: trigger)
        return claim unless claim.fetch("claimed", false)

        agent = claim.fetch("agent")
        result = apply(
          "command_id" => claim.fetch("restart_command_id"),
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => agent.fetch("issue_id", nil),
            "prompt" => unreplayable_session_restart_prompt(agent, instruction: instruction),
            "title" => worker_session_restart_title(agent),
            "replace_agent_id" => agent.fetch("id"),
            "_inherit_workspace_from_agent_id" => agent.fetch("id"),
            "_session_restart_of_agent_id" => agent.fetch("id")
          }.compact
        )
        record_worker_session_restart_outcome(agent, claim, result, trigger: trigger)
      rescue StandardError => e
        # The record still has to say what happened, and the log line still has to be written under
        # the state lock, so the failure is reported through the same outcome path.
        record_worker_session_restart_outcome(
          (claim.is_a?(Hash) && claim.fetch("agent", nil)) || { "id" => agent_id.to_s },
          claim.is_a?(Hash) ? claim : {},
          {
            "command_type" => "SpawnWorker",
            "status" => "failed",
            "message" => "Restarting worker #{agent_id} failed: #{e.message}",
            "errors" => [e.class.name, e.message]
          },
          trigger: trigger
        )
      end

      def worker_session_restart_title(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        present_string(metadata.fetch("title", nil)) || "Continue #{agent.fetch("id")}"
      end

      # The successor is told three things a fresh session cannot know: the assignment, that its
      # predecessor's transcript is gone for good, and that the workspace already holds real work.
      def unreplayable_session_restart_prompt(agent, instruction: nil)
        metadata = agent.fetch("harness_metadata", {}) || {}
        original = present_string(metadata.fetch("spawn_prompt", nil))
        branch = present_string(agent.fetch("workspace_branch", nil))
        location = branch ? "The worktree at #{agent.fetch("workspace_path")} and its branch #{branch} are" : "The worktree at #{agent.fetch("workspace_path")} is"
        header = [
          "You are continuing work that agent #{agent.fetch("id")} started. Its agent session could " \
          "no longer be replayed to the model, so its transcript is unavailable and this is a fresh " \
          "session on the same workspace.",
          "#{location} unchanged, so any work it already committed or left uncommitted is still there.",
          "Start by re-establishing what is already done (for example `git status` and `git log`) " \
          "before continuing, and do not redo work that is already committed."
        ].join("\n\n")
        sections = [header]
        sections << "--- Original assignment ---\n\n#{original}" if original
        sections << "--- New instruction ---\n\n#{present_string(instruction)}" if present_string(instruction)
        sections.join("\n\n")
      end

      def record_worker_session_restart_outcome(agent, claim, result, trigger:)
        agent_id = agent.fetch("id", nil).to_s
        accepted = result.is_a?(Hash) && result.fetch("status", nil) == "accepted"
        successor_id = accepted ? present_string(result.fetch("target_id", nil)) : nil
        synchronized_state do
          state = normalized_state
          record = find_agent(state, agent_id)
          now = timestamp
          if record
            recovery = worker_session_recovery(record).merge(
              "state" => accepted ? "restarted" : "restart_failed",
              "restarted_by_agent_id" => successor_id,
              "restarted_at" => accepted ? now : nil,
              "restart_error" => accepted ? nil : result_failure_summary(result)
            ).compact
            record["harness_metadata"] = (record.fetch("harness_metadata", {}) || {}).merge("session_recovery" => recovery)
            record["updated_at"] = now
          end
          branch = present_string(agent.fetch("workspace_branch", nil))
          message = if accepted
                      "Worker #{agent_id}'s session could not be replayed, so worker #{successor_id} took over its " \
                        "workspace#{branch ? " on branch #{branch}" : ""} in a fresh session."
                    else
                      "Worker #{agent_id}'s session could not be replayed and restarting it failed: " \
                        "#{result_failure_summary(result)}. Its workspace is untouched, so the work can be continued by hand."
                    end
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent_id,
            level: accepted ? "info" : "error",
            message: message,
            details: {
              "agent_id" => agent_id,
              "successor_agent_id" => successor_id,
              "trigger" => trigger.to_s,
              "attempt" => claim.fetch("attempt", nil),
              "workspace_path" => agent.fetch("workspace_path", nil),
              "workspace_branch" => agent.fetch("workspace_branch", nil)
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          {
            "claimed" => true,
            "restarted" => accepted,
            "agent_id" => agent_id,
            "successor_agent_id" => successor_id,
            "message" => message,
            "log_entry_ids" => log_ids,
            "result" => result
          }
        end
      end

      def result_failure_summary(result)
        return "unknown error" unless result.is_a?(Hash)

        present_string(result.fetch("message", nil)) ||
          present_string(Array(result.fetch("errors", [])).join("; ")) ||
          "unknown error"
      end

      # Once a prompt lands the worker is working again, so the dead-turn reason must not linger
      # on the record or in the UI.
      def clear_settle_failure!(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        return unless metadata.is_a?(Hash)
        return unless metadata.key?("settle_failure") || metadata.key?("settle_state") || metadata.key?("status_reason")

        cleared = metadata.dup
        previous = cleared.delete("settle_failure")
        cleared.delete("settle_state")
        cleared.delete("status_reason")
        cleared.delete("error_message") if previous.is_a?(Hash) && cleared["error_message"] == previous["reason"]
        cleared["previous_settle_failure"] = previous if previous.is_a?(Hash)
        agent["harness_metadata"] = cleared
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
        fallback = basename.empty? || basename == "/" ? path : basename
        project_display_name(fallback) || fallback
      end

      # A project's name is its product name. A lifecycle status is what Meringue is
      # currently doing to it, so a status word can never be stored as part of the name
      # no matter who proposed it: a head echoing a rendered label, a slash command, or
      # the directory basename fallback.
      def project_display_name(name)
        ProjectNaming.without_status_suffix(present_string(name))
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
