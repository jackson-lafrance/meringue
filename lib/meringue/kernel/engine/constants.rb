# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Every constant the engine reads at runtime: the system prompts a worker or head is given,
      # the vocabularies of workspace modes, prompt modes, and reconcile states, and the budgets and
      # attempt limits that bound each recovery ladder.

      WORKER_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue worker agent. Work only on the assigned issue and workspace.
        Follow the user's prompt and the repository instructions in your working directory.

        You do not directly interface with the user, so do not ask for permission before taking normal implementation or delivery actions requested by the assigned issue. You may edit files, commit, push, and open or update pull requests when the assigned issue asks for those actions.

        Meringue must never be the author of a git commit. If you create a commit, use the repository's configured user.name and user.email identity; never set or use a Meringue, Meringue Worker, agent@meringue.local, or meringue@example.com identity, and never pass a Meringue identity through --author. If no non-Meringue repository identity is available, do not invent one or commit as Meringue; report the identity configuration as a blocker. The worker environment preserves a non-Meringue repository identity while refusing a Meringue fallback, so committing as the user remains supported.

        The Meringue kernel allocates and validates your workspace before you start. Stay in the assigned workspace and current branch; never create a nested or replacement worktree yourself. Before editing, verify that the checkout is editable, on the recorded task branch, and free of unrelated active changes. If those checks fail, stop writing and report the exact ownership or checkout mismatch so the kernel can safely reallocate it.

        Before editing, inspect the repository status and active instructions. Avoid overwriting unrelated active work. Treat the assigned workspace as your task branch/worktree for git-backed projects, commit only the assigned issue's changes, and open a pull request when requested and the environment allows.

        Recover from ordinary environment problems before abandoning implementation or delivery. Read the repository's setup and test guidance, use its documented bootstrap or dependency-repair commands, inspect available environment variables and existing tool installations, and retry transient commands with a bounded attempt. If full verification remains unavailable, run every safe narrower check you can and continue to commit/push/open the requested pull request unless repository guidance explicitly forbids delivery. Report the exact failed commands and remaining limitation; do not turn a recoverable setup problem into an immediate blocker.

        For a user request to implement and deliver a change, successful completion means: make the requested changes, verify them as reasonably as possible, push the delivery branch, and open or update the pull request. Once the pull request is open or updated, stop work and report the delivery status and link. Do not watch CI, review bots, pull-request checks, or reviews; do not run polling or sleep loops after pushing; and do not wait for post-delivery feedback. The user will explicitly retrigger or request follow-up work if needed.

        Do not infer post-delivery work from an ordinary implementation-and-delivery request. If the user specifically asks for CI remediation, review responses, merge/deploy monitoring, or another post-delivery action, perform that explicitly requested action; this exception does not authorize indefinite monitoring or any additional unrequested follow-up.

        Not every worker issue requires a pull request. If the assigned issue is investigation-only or informational and does not require repository changes, return the requested findings or answer without opening a PR unless the issue explicitly asks for one.

        During longer work, keep progress visible by briefly reporting meaningful findings, decisions, and implementation milestones when they occur. Do not narrate routine tool use or invent progress when there is no substantive update.

        Delivery artifacts must describe only the human product task. Never put Meringue branding or a `meringue/` prefix; project, issue, worker, head, agent, harness, provider, or session identifiers; AI confidence scores; or statements about which agents worked on the change into branch/worktree names, commit subjects or bodies, tags, pull request titles or bodies, release notes, or other externally visible delivery text. This includes formatting variants such as `P5-I2-W3`, `p5_i2_w3`, and `P5/I2/W3`, AI-authorship trailers, and "worked on by" disclosures. Do not derive names from the assigned issue id, your identity, session metadata, or orchestration context.

        Derive delivery names and prose only from the product task title and requested change. The current branch was already allocated under this policy; do not rename it unless it is unusable. If you must supply another name, sanitize unsafe supplied/generated values and use a short opaque suffix for uniqueness. Before delivery, inspect commit metadata and the rendered pull request title/body and remove prohibited text; update an existing compliant pull request rather than opening an agent-specific one.

        Your final message is a handover, not a summary for a reader who watched you work. Meringue keeps sessions short: the work that follows yours normally happens in a new session that inherits your worktree and branch but never sees your transcript, so anything you learned and did not write down is lost. End by stating what you changed and where, what is committed versus still uncommitted, what you tried that did not work and why, what you verified and what you could not, and what the next step is. Be specific about approaches you ruled out: that is what stops the next session from repeating them.

        Report true blockers instead of asking for routine approval: missing credentials, authentication or authorization failures, missing or invalid remotes, branch/worktree collisions, unrelated uncommitted work that would be overwritten, or unsafe/destructive operations.
      PROMPT
      READ_ONLY_WORKER_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue read-only worker agent. Work only on the assigned investigation or informational task and shared checkout.
        Follow the user's prompt and the repository instructions in your working directory only where they do not conflict with this read-only contract.

        This is a shared project checkout that may be used by the user and other read-only workers concurrently. You must not mutate it or any repository state. Do not create, edit, overwrite, move, or delete files; do not install dependencies, run generators or formatters, change permissions, or write caches/build artifacts. Do not run git operations that mutate refs, the index, worktrees, remotes, or the working tree, including add, commit, checkout, switch, branch, reset, restore, stash, clean, fetch, pull, push, merge, rebase, tag, or worktree commands. Do not open, update, or merge pull requests or mutate other remote services.

        Your harness intentionally exposes only read, grep, find, and ls tools. Do not try to bypass that restriction through extensions, subprocesses, another checkout, or a nested worktree. If the task turns out to require any repository or external mutation, stop and report that an isolated implementation worker is required.

        Inspect and synthesize with read-only tools, then return findings or an answer. Treat pre-existing uncommitted files as user-owned state: you may read them when relevant but must not alter them. Never claim to have changed, committed, pushed, or delivered anything.

        During longer work, keep progress visible by briefly reporting meaningful findings and decisions. Do not narrate routine tool use or invent progress when there is no substantive update.

        Your final message is a handover, not a summary for a reader who watched you work. The work that follows yours normally happens in a new session that never sees your transcript, so anything you found and did not write down is lost. State your findings, the evidence behind them, what you checked and ruled out, and anything you could not determine.
      PROMPT
      WORKSPACE_MODE_ISOLATED = "isolated"
      WORKSPACE_MODE_SHARED_READ_ONLY = "shared_read_only"
      WORKSPACE_MODES = [WORKSPACE_MODE_ISOLATED, WORKSPACE_MODE_SHARED_READ_ONLY].freeze
      # Every durable phase in which focus handoff, native ownership, or dashboard return still
      # owns worker settlement. Ordinary reconciliation must not poll through any of these phases.
      INTERACTIVE_HANDOFF_STATES = %w[
        preparing interactive_pending interactive resuming resume_failed reclaiming reclaim_failed
      ].freeze
      INTERACTIVE_RETURN_STATES = %w[
        interactive_pending interactive resuming resume_failed reclaiming
      ].freeze

      WORKER_RESUME_PROMPT = <<~PROMPT.freeze
        Continue this Meringue worker session from the existing session history and workspace state.
        First inspect the current repository state, then continue the assigned issue from the last incomplete step.
        If the issue is already complete, summarize the final status and include any pull request link.
      PROMPT
      SUPERVISOR_RECOVERY_PROMPT_ID_LABEL = "Meringue supervisor recovery id".freeze
      HEAD_RESUME_PROMPT = <<~PROMPT.freeze
        Continue the interrupted Meringue head request from this session's existing context.
        Return exactly one valid HeadResult JSON object and no other text. Do not repeat tool work that is already complete.
      PROMPT
      HEAD_RESULT_REPAIR_PROMPT = <<~PROMPT.freeze
        Your previous response was not valid Meringue HeadResult JSON.
        Return exactly one JSON object with string fields "title" and "summary", an optional string field "response" for plain user-visible text, an array field "commands", and an array field "questions".
        Do not include markdown, prose, code fences, or tool calls outside the JSON object.
        The "response" field is optional: omit it or use an empty string when routing only through commands, and never use JSON null. Escape newlines inside every JSON string value as \\n instead of writing literal line breaks, and never embed a ``` code fence inside a string value.
      PROMPT
      PULL_REQUEST_URL_PATTERN = /https?:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/\d+(?:[\/?#][^\s<>"'\])}]*)?/.freeze
      PULL_REQUEST_ASSOCIATING_COMMANDS = %w[
        CreateIssue ModifyIssue SpawnWorker PromptAgent CreateGoal
      ].freeze
      # `/prune` is one combined cleanup pass: resolved (completed/killed) and errored records
      # are eligible together, so an errored record is terminal rather than a retention blocker.
      PRUNE_ELIGIBLE_STATUSES = %w[completed killed errored].freeze
      # Only work that could still move on its own retains a record. An errored worker is
      # settled; a queued, working, or blocked worker is not. A `supervision_lost` worker is
      # paused runtime, not settled: its transport owner disappeared but its durable session,
      # workspace, and queued work remain valid and recoverable, so it retains its record like
      # other live work rather than being pruned. A user-paused worker is equally
      # recoverable and must remain visible until the user resumes or kills it.
      PRUNE_BLOCKING_WORKER_STATUSES = %w[queued working paused blocked supervision_lost].freeze
      # How many times workspace provisioning is attempted for one worker before it stops being
      # retried automatically and starts waiting for a human. Two, not more: a retry of a stuck
      # `git worktree add` is cheap and usually works, but each attempt can legitimately take
      # minutes on a monorepo, and an unbounded retry loop would spend those minutes forever.
      PROVISIONING_ATTEMPT_LIMIT = 2
      # Provisioning states a worker can be resumed from. All of them mean "reservation intact,
      # no session, no workspace".
      PROVISIONING_RESUMABLE_STATES = %w[failed retry_pending retry_exhausted].freeze
      # How often a slow provisioning records a durable progress line. The AgentTree updates more
      # often than this so a checkout does not look frozen between log entries.
      PROVISIONING_PROGRESS_INTERVAL_SECONDS = 60
      PROVISIONING_PROGRESS_UPDATE_INTERVAL_SECONDS = 15
      PROVISIONING_PROGRESS_LOG_REPLACEMENT_KIND = "worker_workspace_provisioning".freeze
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
      # Mid-work worker progress. A worker used to be silent in the main log between
      # "Spawned worker …" and its final report, which made a healthy 40-minute session
      # indistinguishable from a hung one.
      #
      # The volume control is a floor, not a cap on content, and it matters because the retained
      # log window is 500 entries (see docs/log-retention.md): three concurrent workers narrating
      # freely would evict every kernel and user line within an hour. A worker's *first* authored
      # progress line is immediate, then text is floored at one line per 2 minutes per worker
      # (<= 30/hour). Raw tool activity is never turned into Meringue-authored progress; when the
      # agent has not emitted a semantic update, the log truthfully stays quiet.
      # Consecutive identical text is dropped outright, so a repeated message never spends a slot.
      # Content is kept intact here; the log pane wraps it to the available width. Rate limiting
      # bounds log volume without making a worker's report unreadable.
      WORKER_PROGRESS_LOG_INTERVAL_SECONDS = 120
      # How long a `working` worker may produce nothing before the dashboard says so, when the
      # user has not configured `agent.quiet_worker_warning_seconds`. Deliberately generous:
      # quiet is not the same as stuck, and a long tool call or a long think is quiet too. The
      # signal answers "should I go look at this one?", so a false alarm every few minutes would
      # be worse than useless.
      WORKER_QUIET_WARNING_SECONDS = 900
      # A worker is only marked quiet once per quiet stretch. `quiet_warning_at` records that the
      # warning was written; observed activity clears it, so a worker that goes quiet, produces
      # output, and goes quiet again is reported twice rather than once or forever.
      WORKER_QUIET_WARNING_MARKER_KEY = "quiet_warning_at"
      # The timestamp every quiet calculation is measured from. Advanced only by observed
      # activity - drained harness events, session progress, a delivered prompt, or a harness
      # heartbeat that moved - never by Meringue's own bookkeeping writes.
      WORKER_LAST_ACTIVITY_KEY = "last_activity_at"
      # A harness turn that ends is not automatically a turn that finished. These are the
      # harness-reported turn outcomes that mean the work stopped without a result, so the
      # agent must settle as `errored` with a visible reason instead of as `completed`.
      SETTLE_FAILURE_TURN_STATES = %w[failed errored incomplete].freeze
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
      # saved transcript itself. The harness classifies it; this pattern is the kernel's fallback
      # for the same evidence arriving through session events instead of a turn outcome.
      SETTLE_FAILURE_UNREPLAYABLE_KIND = "unreplayable_session"
      SETTLE_FAILURE_UNREPLAYABLE_PATTERN = /
        (?:thinking|redacted_thinking)[^\n]{0,200}?cannot\s+be\s+modified
        |blocks\s+must\s+remain\s+as\s+they\s+were\s+in\s+the\s+original\s+response
        |expected\s+`?thinking`?\s+or\s+`?redacted_thinking`?
      /ix.freeze
      # A worker whose harness process is gone. The harness proves it by raising an error carrying
      # `Harness::SessionProcessGoneError`, so this is evidence rather than a timeout heuristic and
      # a legitimately slow start can never be classified as one.
      SETTLE_FAILURE_PROCESS_EXIT_KIND = "harness_process_exited"
      # Enough stderr to name a crash, not enough to bloat every state write.
      PROCESS_EXIT_STDERR_MAX_BYTES = 600
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
        "move_worker" => "MoveWorker",
        "move" => "MoveWorker",
        "reparent_agent" => "MoveWorker",
        "reparent" => "MoveWorker",
        "move_issue" => "MoveIssue",
        "reparent_issue" => "MoveIssue",
        "prompt_agent" => "PromptAgent",
        "pause_worker" => "PauseWorker",
        "resume_worker" => "ResumeWorker",
        "export_workers" => "ExportWorkers",
        "import_workers" => "ImportWorkers",
        "retry" => "RetryHead",
        "retry_head" => "RetryHead",
        "noop" => "NoOp",
        "no_op" => "NoOp",
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
        "save_configuration" => "SaveConfiguration",
        "set_worker_selection_guidance" => "SetWorkerSelectionGuidance",
        "test_github_access" => "TestGitHubAccess",
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

      # 47 commands in one flat list is complete and unnavigable, which is the
      # same problem `meringue --help` had. Grouping is by what someone is trying
      # to do, and the first group is deliberately the short answer for a reader
      # who has just opened the dashboard for the first time.
      #
      # Membership is matched on the command name, so a command added to
      # HELP_COMMANDS lands in a real group or in "Everything else" - it can
      # never silently vanish from the listing.
      HELP_GROUPS = [
        ["Start here", %w[/help /glossary /setup /project]],
        ["Work", %w[/issue /goal /recount /move]],
        ["Agents", %w[/worker /prompt /retry /jump /open-session /kill /prune]],
        ["Questions", %w[/questions /answer /dismiss]],
        ["Settings", %w[/config /theme /themes /harness /model /models /thinking /status-bar /keybind]],
        ["Session", %w[/prs /github /tree /state /clear /reload /update /quit]]
      ].freeze
      OTHER_HELP_GROUP = "Everything else"

      def self.help_group_for(usage)
        name = usage.to_s.split(/\s+/).first.to_s
        found = HELP_GROUPS.find { |_group, names| names.include?(name) }
        found ? found.first : OTHER_HELP_GROUP
      end

      def self.grouped_help_commands(specs = HELP_COMMANDS)
        by_group = specs.group_by { |usage, _description| help_group_for(usage) }
        order = HELP_GROUPS.map(&:first) + [OTHER_HELP_GROUP]
        order.filter_map do |group|
          entries = by_group[group]
          [group, entries] if entries&.any?
        end
      end

      HELP_COMMANDS = [
        ["/help", "Show slash command help, grouped by what you are trying to do."],
        ["/glossary", "TUI local: show what head, worker, issue, project, and harness mean."],
        ["/quit", "TUI local: quit the interactive TUI."],
        ["/reload", "TUI local: restart Meringue with the current installed source and configuration."],
        ["/update", "TUI local: fast-forward the installed Meringue source onto its tracked branch (main, or MERINGUE_BRANCH), install missing dependencies, and reload."],
        ["/theme [name]", "Open the theme picker, or set and persist a named TUI theme. Available: catppuccin, gruvbox, kanagawa, meringue, rose-pine, tokyonight."],
        ["/themes", "TUI local: open the interactive theme picker."],
        ["/project add <path> [name]", "Register a project directory."],
        ["/project rename <project_id> \"<name>\"", "Rename a project."],
        ["/issue create <project_id> \"<title>\" [\"description\"]", "Create an issue under a project."],
        ["/issue rename <issue_id> \"<title>\"", "Rename an issue."],
        ["/issue move <issue_id> <project_id|issue_id|top>", "Move an issue to another project on the same checkout, reparent it under another issue, or promote it to the top level. Its child issues and their workers move with it."],
        ["/move <agent_id> <issue_id>", "Move an existing worker to a different issue without restarting its harness session. The worker keeps its session, worktree, and branch; only its AgentTree assignment changes."],
        ["/worker spawn <issue_id> \"<prompt>\"", "Spawn a worker for an issue."],
        ["/worker guide \"<additional system prompt>\"", "Persist the additional worker model-selection system prompt when its experiment is enabled."],
        ["/worker pause <agent_id>", "Pause a worker without killing its resumable session."],
        ["/worker resume <agent_id>", "Resume a paused worker session."],
        ["/worker export <bundle_path> [agent_id...]", "Export current workers for a fresh retry on another computer."],
        ["/worker import <bundle_path> --project <path>", "Import workers as fresh sessions in a destination project."],
        ["/prompt <agent_id> \"<message>\"", "Continue a worker session or take over a still-routing head."],
        ["/retry <head_id>", "Retry a blocked, errored, or killed head with a fresh head."],
        ["/harness [head|worker] <pi|claude|codex>", "Select role-aware harness defaults for future agents; omit the role to update both."],
        ["/models [harness] [refresh]", "List every model the selected harness reports, refreshing the catalog when it is stale."],
        ["/model <provider>/<model-id>", "With no arguments, open the same TUI picker as /models; otherwise persist the model used for all future heads and workers. Existing sessions are unchanged. The model id may itself contain / and :."],
        ["/thinking <level>", "Persist the thinking level used for all future heads and workers: off, minimal, low, medium, high, xhigh, or max."],
        ["/goal create [issue_id] \"<prompt>\" --metric \"<command>\" --target <number> [--project <project_id>] [--comparator gte|lte|gt|lt|eq] [--max-iterations <n>] [--guardrail \"<command>\"] [--parse last_number|first_number|exit_status] [--pattern \"<regex>\"] [--title \"<title>\"] [--fresh-attempt] [--paused]", "Start a goal loop: the kernel keeps producing attempts until the metric hits its target or a budget/no-progress guard trips. Name an issue to attach the loop to it, or give only a quoted prompt and Meringue creates the issue itself."],
        ["/goal create [issue_id] \"<prompt>\" --reviewer [--project <project_id>] [--max-iterations <n>] [--guardrail \"<command>\"] [--title \"<title>\"] [--fresh-attempt] [--paused]", "Start a reviewer-judged goal loop for work with no number: each attempt is reviewed against the success criteria, and the loop stops when the reviewer approves or the iteration budget runs out."],
        ["/goal status [goal_id]", "Show goal loops, their iteration accounting, and why a stopped goal stopped."],
        ["/goal pause <goal_id>", "Pause a goal loop after the current attempt; nothing new is spawned while it is paused."],
        ["/goal resume <goal_id>", "Resume a paused goal loop."],
        ["/goal stop <goal_id>", "Stop a goal loop for good, leaving its current attempt session alone."],
        ["/kill <agent_or_issue_id>", "Kill an agent, issue subtree, or project subtree."],
        ["/jump [agent_id]", "TUI local: open an agent's focused workspace, or navigate the AgentTree when no id is provided."],
        ["/prs", "TUI local: open the picker for every tracked pull request that is still open."],
        ["/open-session <agent_id>", "TUI local: open an agent's underlying harness session for debugging."],
        ["/setup", "TUI local: reopen Setup for theme, separate head/worker defaults, status-bar layout, and Meringue Xtras."],
        ["/keybind", "TUI local: show all keybindings."],
        ["/config", "TUI local: open full-screen Settings; /config --text prints diagnostics."],
        ["/github test", "Test read-only GitHub authentication and repository access."],
        ["/status-bar", "TUI local: compose and save the dashboard bottom bar's left/right component layout."],
        ["/tree", "Show the current AgentTree state."],
        ["/state", "Show the raw Meringue state."],
        ["/questions", "Open the picker for existing open questions."],
        ["/answer <question_id> \"<answer>\"", "Answer an open question; the kernel records the answer and routes the work it unblocks."],
        ["/dismiss <question_id>", "Dismiss an open question without answering it."],
        ["/prune", "Remove resolved and errored records plus their safely cleanable managed worktrees."],
        ["/recount", "Compact project, issue, worker, and question IDs after records are removed."],
        ["/clear", "Reset persisted Meringue state and clear the visible logs."]
      ].freeze
      # Every user-facing slash command that maps to a kernel command is proposable by a head, and
      # heads also get NoOp for deliberate no-work routing. Only kernel/parser internals and
      # explicit user recovery actions stay off limits: `ApplyHeadResult` is how the kernel applies
      # a head batch, `RetryHead` is manual recovery, and `InvalidSlashCommand` reports a typing
      # mistake back to the person who typed it.
      HEAD_PROPOSABLE_COMMANDS = %w[
        ListAll GetState GetInfo Help ListQuestions
        GetSessionDefaults GetModelCatalog SetDefaultSessionModel SetDefaultSessionThinkingLevel
        AddProject ModifyProject CreateIssue ModifyIssue MoveWorker MoveIssue SpawnWorker PromptAgent SpawnHead NoOp
        CreateGoal ModifyGoal StopGoal ListGoals
        AskQuestion AnswerQuestion DismissQuestion
        PauseWorker ResumeWorker ExportWorkers ImportWorkers
        Kill Prune Recount ClearState SetTheme SetHarness ReconcileSessions
      ].freeze
      HEAD_BLOCKED_COMMANDS = %w[ApplyHeadResult InvalidSlashCommand RetryHead SaveConfiguration].freeze
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
      GATE_LABEL_MAX_CHARS = 48
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
      # A head batch command the kernel deliberately did not apply because the record it targeted
      # existed in the head's spawn snapshot and was removed (pruned or killed) before the result
      # was applied. Nothing mutated, so it is journaled as `rejected`, but it is not a head
      # mistake: it is counted, worded, and logged as a skip instead of a rejection.
      REMOVED_BATCH_ISSUE_TARGET_ERROR = "issue_removed_before_head_result_applied"
      REMOVED_BATCH_AGENT_TARGET_ERROR = "agent_removed_before_head_result_applied"
      HEAD_BATCH_SKIP_ERROR_CODES = [REMOVED_BATCH_ISSUE_TARGET_ERROR, REMOVED_BATCH_AGENT_TARGET_ERROR].freeze
      # Head-batch commands whose entire target can be removed by a prune or kill while the batch is
      # in flight. `ModifyIssue`/`SpawnWorker` are handled by the issue-target resolver; these two
      # name a record directly and have no intra-batch reference form, so they are checked here.
      BATCH_REMOVABLE_TARGET_COMMANDS = %w[PromptAgent Kill].freeze
      # Bounded ledger of record ids the kernel removed, so a command that arrives after a prune or
      # kill can say what happened to its target instead of guessing. State, not logs, owns this:
      # logs are evicted on their own retention schedule and are not a source of truth. Issues and
      # agents are kept in separate lists so pruning twenty workers cannot evict the issue history
      # an in-flight head result still needs.
      REMOVED_RECORD_LEDGER_LIMIT = 200
      REMOVED_RECORD_LEDGER_KEYS = { "issue" => "removed_issues", "agent" => "removed_agents" }.freeze
      # Same idea for a project created earlier in the same batch: a head can point at the
      # AddProject command instead of predicting `P<n>`.
      BATCH_PROJECT_REFERENCE_KEYS = %w[
        project_from_command ProjectFromCommand projectFromCommand
        project_ref ProjectRef projectRef
      ].freeze
      # `CreateGoal` is here because its prompt form mints its own issue, so a batch that registers
      # a project and starts a goal in it references the AddProject command the same way.
      BATCH_PROJECT_REFERENCE_COMMANDS = %w[CreateIssue CreateGoal].freeze
      # PromptAgent can target a worker spawned earlier in the same batch without predicting the
      # worker id, using the same command-id/index reference form as worker lineage fields.
      BATCH_PROMPT_AGENT_REFERENCE_KEYS = %w[
        agent_from_command AgentFromCommand agentFromCommand
        agent_ref AgentRef agentRef
      ].freeze
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
      # The second kind of gate a queued worker can wait on: a command the kernel runs on a timer
      # until it says "go". It exists for events Meringue cannot observe as an agent settling - a
      # human review landing on a PR, a deploy finishing, an external job turning green.
      DEFERRED_WORKER_GATE_COMMAND_KEYS = %w[
        after_command AfterCommand afterCommand
        wait_for_command WaitForCommand waitForCommand
        gate_command GateCommand gateCommand
      ].freeze
      DEFERRED_WORKER_GATE_LABEL_KEYS = %w[
        after_command_label AfterCommandLabel afterCommandLabel
        wait_for_label WaitForLabel waitForLabel
      ].freeze
      DEFERRED_WORKER_GATE_EXPECT_KEYS = %w[
        after_command_expect AfterCommandExpect afterCommandExpect
        wait_for_expect WaitForExpect waitForExpect
      ].freeze
      DEFERRED_WORKER_GATE_PATTERN_KEYS = %w[
        after_command_pattern AfterCommandPattern afterCommandPattern
        wait_for_pattern WaitForPattern waitForPattern
      ].freeze
      DEFERRED_WORKER_GATE_CWD_KEYS = %w[
        after_command_cwd AfterCommandCwd afterCommandCwd
        wait_for_cwd WaitForCwd waitForCwd
      ].freeze
      DEFERRED_WORKER_GATE_INTERVAL_KEYS = %w[
        after_command_interval_seconds AfterCommandIntervalSeconds afterCommandIntervalSeconds
        wait_for_interval_seconds
      ].freeze
      DEFERRED_WORKER_GATE_TIMEOUT_KEYS = %w[
        after_command_timeout_seconds AfterCommandTimeoutSeconds afterCommandTimeoutSeconds
        wait_for_timeout_seconds
      ].freeze
      DEFERRED_WORKER_GATE_MAX_WAIT_KEYS = %w[
        after_command_max_wait_seconds AfterCommandMaxWaitSeconds afterCommandMaxWaitSeconds
        wait_for_max_wait_seconds
      ].freeze
      DEFERRED_WORKER_GATE_EXPIRY_POLICY_KEYS = %w[
        if_gate_expires IfGateExpires ifGateExpires
        if_after_command_fails IfAfterCommandFails ifAfterCommandFails
        on_gate_expiry OnGateExpiry onGateExpiry
      ].freeze
      # `exit_zero` is the default because it is the shape every shell already speaks and it makes
      # the predicate the author's problem (`... | grep -q APPROVED`). `output_matches` exists for
      # commands whose exit status is uninformative, e.g. `gh pr view --json reviewDecision`.
      DEFERRED_WORKER_GATE_EXPECTATIONS = %w[exit_zero output_matches].freeze
      DEFERRED_WORKER_GATE_DEFAULT_EXPECT = "exit_zero"
      # A queued worker's workspace is only *planned*, not created, so `project_root` is the
      # default: it is the one directory that reliably exists while the worker is still waiting.
      DEFERRED_WORKER_GATE_CWD_MODES = %w[project_root workspace].freeze
      DEFERRED_WORKER_GATE_DEFAULT_CWD = "project_root"
      DEFERRED_WORKER_GATE_DEFAULT_INTERVAL_SECONDS = 60
      DEFERRED_WORKER_GATE_MIN_INTERVAL_SECONDS = 5
      DEFERRED_WORKER_GATE_MAX_INTERVAL_SECONDS = 60 * 60
      # Short on purpose: a gate runs on the reconcile thread, so a slow check delays session
      # reconciliation for everyone. A gate is a poll, not a build.
      DEFERRED_WORKER_GATE_DEFAULT_TIMEOUT_SECONDS = 30
      DEFERRED_WORKER_GATE_MAX_TIMEOUT_SECONDS = 120
      # A human review can take hours, so the default budget is hours; the ceiling stops a gate
      # from becoming a permanent background process.
      DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS = 4 * 60 * 60
      DEFERRED_WORKER_GATE_MAX_WAIT_CEILING_SECONDS = 24 * 60 * 60
      # A gate that cannot even be run (missing cwd, spawn failure, timeout, unusable pattern)
      # can never pass, so it is abandoned loudly after this many consecutive unusable checks
      # instead of polling a broken command until the budget runs out.
      DEFERRED_WORKER_GATE_UNUSABLE_LIMIT = 3
      DEFERRED_WORKER_GATE_COMMAND_MAX_CHARS = 2_000
      # Wall-clock a single reconcile pass may spend running gate commands, mirroring the goal
      # loop's budget. Gates that do not fit are checked on the next pass.
      DEFERRED_WORKER_GATE_BUDGET_SECONDS = 10.0
      DEFERRED_WORKER_GATE_OUTPUT_MAX_CHARS = 2_000
      DEFERRED_GATE_STATE_PENDING = "pending"
      DEFERRED_GATE_STATE_SATISFIED = "satisfied"
      DEFERRED_GATE_STATE_EXPIRED = "expired"
      DEFERRED_GATE_STATE_UNAVAILABLE = "unavailable"
      DEFERRED_GATE_UNRESOLVED_STATES = [DEFERRED_GATE_STATE_EXPIRED, DEFERRED_GATE_STATE_UNAVAILABLE].freeze
      # `cancel` (default) drops the dependent with a warning when its predecessor errors; `run`
      # starts it anyway and says so in the handover. A killed predecessor always cancels.
      DEFERRED_WORKER_FAILURE_POLICIES = %w[cancel run].freeze
      DEFERRED_WORKER_DEFAULT_FAILURE_POLICY = "cancel"
      # Bounds how long a chain of queued workers may be, so one batch cannot schedule work forever.
      DEFERRED_WORKER_MAX_CHAIN_DEPTH = 5
      # A worker can ask the kernel to spawn a fresh head after it completes. That head receives
      # the worker's complete final report in its prompt and routes whatever follow-on kernel
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
      COMPLETION_CONTINUATION_STATE_CANCELLED = "cancelled"
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
        },
        {
          "field" => "reuse_workspace_of_agent_id",
          "aliases" => %w[
            reuse_workspace_of_agent_id ReuseWorkspaceOfAgentID reuseWorkspaceOfAgentID reuseWorkspaceOfAgentId
          ],
          "reference_keys" => %w[
            reuse_workspace_from_command ReuseWorkspaceFromCommand reuseWorkspaceFromCommand
            reuse_workspace_ref reuseWorkspaceRef
          ]
        }
      ].freeze
      WORKSPACE_REUSE_AGENT_KEYS = %w[
        reuse_workspace_of_agent_id ReuseWorkspaceOfAgentID reuseWorkspaceOfAgentID reuseWorkspaceOfAgentId
      ].freeze
      SHARE_WORKSPACE_KEYS = %w[share_workspace ShareWorkspace shareWorkspace].freeze
      # Why a worker is allowed to continue in another worker's worktree instead of getting a fresh
      # one. The source decides how a refusal is handled: a continuation or explicit request falls
      # back to fresh provisioning, while a session restart exists *only* to take over the dead
      # worker's checkout, so it fails loudly rather than silently abandoning that work.
      WORKSPACE_REUSE_SOURCE_EXPLICIT = "explicit"
      WORKSPACE_REUSE_SOURCE_CONTINUATION = "continuation"
      WORKSPACE_REUSE_SOURCE_SESSION_RESTART = "session_restart"
      WORKSPACE_REUSE_STATE_CLAIMED = "claimed"
      WORKSPACE_REUSE_STATE_REUSED = "reused"
      WORKSPACE_REUSE_STATE_REFUSED = "refused"
      # Predicting a worker id is the failure mode this hint exists for: the predecessor's agent id
      # depends on the issue id the kernel mints, so a prediction goes stale as soon as another head
      # creates an issue first.
      RELATED_AGENT_REFERENCE_HINT = "When the predecessor is spawned by this same head result, " \
                                     "reference its SpawnWorker command (follow_up_of_command, " \
                                     "after_from_command, or an \"@<command_id>\" value) instead of " \
                                     "predicting a worker id."
      # Reconciliation redelivery attempts for a prompt that arrived while the session was busy.
      PENDING_PROMPT_MAX_ATTEMPTS = 20
      PROMPT_COMMAND_ID_HISTORY_LIMIT = 50
      HEAD_RESULT_REPAIR_MAX_ATTEMPTS = 1
      HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS = 1
      WORKER_RECONCILE_RESUME_MAX_ATTEMPTS = 3
      # A shared Meringue process exit can strand every managed harness child at once. Each recovery attempt
      # is claimed durably before attach/prompt I/O, and the same bound as ordinary session repair
      # prevents a broken transcript from creating an unbounded restart loop.
      WORKER_SUPERVISOR_RECOVERY_MAX_ATTEMPTS = WORKER_RECONCILE_RESUME_MAX_ATTEMPTS
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
      # A user-requested access check is deliberately short and runs outside the state lock. The
      # forge client shares the same deadline across auth and repository-read checks.
      GITHUB_ACCESS_TEST_BUDGET_SECONDS = 5.0
      # `/prune` verifies PR state conservatively, but forge discovery/status commands are external
      # I/O. Bound the whole lookup phase so one unreachable forge cannot leave the command pending
      # indefinitely. URLs not resolved inside the budget become `unknown` and retain their issue.
      # The budget is a ceiling, not a cost: a healthy forge finishes in well under a second, and a
      # pass only spends the whole budget when the forge is unreachable or slow. Five seconds was
      # too tight for a real backlog (a single pass exhausted it and retained issues whose PRs were
      # already merged, so the user had to run `/prune` repeatedly), and the phase runs outside the
      # state lock on the submission thread, so a longer ceiling delays nothing but this command.
      PRUNE_FORGE_LOOKUP_BUDGET_SECONDS = 15.0
      # Cleanup is retriable and conservative. Bound one user command so a large backlog cannot
      # occupy a submission thread for ten minutes; unvisited worktrees remain claimed only until
      # this pass commits and are retried by the next explicit prune.
      PRUNE_WORKSPACE_CLEANUP_BUDGET_SECONDS = 30.0
      # A prune pass that ran out of budget or timed out mid-cleanup can leave managed worktrees
      # on disk after their worker records are removed. A post-commit retry runs the same safe
      # removal with a fresh budget and never force-removes dirty, locked, or referenced worktrees.
      POST_PRUNE_CLEANUP_BUDGET_SECONDS = 30.0
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
    end
  end
end
