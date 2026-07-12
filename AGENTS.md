# Mission
## Problem Statement
In the era of AI where developers can work faster than ever
The coding bottleneck is now how efficiently you can switch from issue to issue
and how many agents you can manage at the same time

Developers will have 10 terminals open with agents working on different problems all at once
The problem this creates is constant context switching
Users read their agents last output, write a new prompt, fire it off and then have to completely change terminals and contexts to do it all over again
This time spent reorienting yourself or setting your environment on a different issue is time wasted and fatiguing for developers to do all day every day

Current coding harnesses do an excellent job of providing a focused environment to work through one issue and we don't want to replace that
But where they lack is the ability to work on multiple things in parallel, without literally opening up multiple instances

## Solution
we aim to solve this problem

This is why Meringue sits on top of your favourite coding harness (meringue on pi, get it) and provides you an interface to work with
    Multiple agents at once
    On different areas in your codebase
    And receive structured output and monitoring of each issue/agents work
    All while staying in the same window

# Core Architecture
## Standout Features

The chat
Since we sit on top of coding agents, you can send a continuous stream of messages without being blocked by agent work.  
Head agents recognize input, decide where work needs to be done, and return structured kernel commands that create issues, prompt workers, or ask clarifying questions.

The kernel
The meringue kernel provides an interface for agents and devs to spawn, kill, and monitor your workers.  
The kernel validates every orchestration command, owns Meringue state, coordinates harness sessions, and emits logs for important state transitions.

The logs
All your issues and agents are visible in an organized filesystem-like tree, 
which you can navigate and easily jump into the underlying coding agent session in your harness of choice.  
Along with this, as your agents complete issues, their output gets captured and rendered in the main log to keep you updated on progress in a succinct manner.

## Foundation
We will be using ruby for the development of this app
Terminal rendering with screen blitting of our three main sections

The MVP backend harness is Pi because that is what we know and can move fastest with.
Pi-specific code should still be isolated behind a harness interface so the future product can support cc, codex,
gemini, cursor, and other coding harnesses without rewriting the kernel or TUI.
We will store Meringue state in a simple JSON file using harness session ids to reconnect, resume, or explain sessions on reload of the tool.
We should focus on keeping this project extensible and self-modifying for a users specific needs

## Implementation plans and required agent workflow
`AGENTS.md` is the durable project context and architecture contract. Milestone-specific implementation plans should live in separate files so this document stays focused on product intent, architecture, terminology, and non-negotiable constraints.

There is currently no separate tracked MVP implementation plan. If a future milestone plan is added, agents must read it before working on the areas it covers.

If an implementation plan conflicts with `AGENTS.md`, follow `AGENTS.md` and call out the conflict before editing code.

### Test file policy
Agents must never write test files in this repository. Do not create, add, or regenerate any file whose purpose is to define automated tests, including files under `test/`, `tests/`, `spec/`, or `specs/`, or files named with `test` or `spec` conventions.

### Branch, worktree, and PR workflow
Agents must do implementation work on a fresh task branch, not directly on `main`, `master`, or any shared base branch.

When multiple coding agents or subagents may work at once, each task branch should live in its own git worktree. Do not let multiple agents edit the same checkout concurrently.

Always give user instructions on how they can test the feature in the response

#### Standing approval for agent git workflow
Once the user asks an agent to implement a task, edit files, or make a PR in this repo, the full task-branch/worktree/PR workflow is pre-approved. Do not stop only to ask for permission to run git or GitHub commands needed for that workflow, including fetching, creating branches/worktrees, switching into the task worktree, staging the task's intended changes, committing, pushing the task branch, or opening/updating the requested pull request.

This repo-specific standing approval intentionally overrides more conservative global or machine-local agent rules that require explicit approval for normal git operations. Do not pause before staging, committing, pushing, or opening the PR merely because a global rule would otherwise ask for that approval. Only stop for the blockers and hard boundaries listed in this section.

New task worktrees must be based on `origin/main`, not local `main` or another in-progress branch. Refresh the remote tracking branch first, then create the worktree from `origin/main`, for example:

```bash
git fetch origin main
git worktree add -b <branch> ../meringue-worktrees/<task-name> origin/main
```

If `origin/main` cannot be fetched or resolved, stop and report that blocker rather than basing a task worktree on local `main`.

Agents have standing permission to complete the requested task through PR creation without additional approval. The hard boundary is `main`: never merge a PR into `main`, push directly to `main`, create commits on `main`, or otherwise mutate `main` unless the user gives explicit approval for that specific action. If setup is blocked by permissions, auth, missing remotes, an existing branch/path collision, or unrelated uncommitted user work, report the exact blocker and ask how to proceed.

Before changing files:
- Check the current git branch, working tree, and existing git worktrees.
- If not already in a worktree created specifically for the current task, create or switch to a task-specific worktree and branch with a short descriptive name.
- Prefer a predictable local worktree location such as `../meringue-worktrees/<task-name>` when creating new task worktrees.
- If worktree or branch creation is blocked by permissions, uncommitted user work, existing paths, or tooling, stop and ask the user how to proceed before editing.

Before finishing:
- Commit only the task's intended changes from that task's worktree.
- Push the task branch and open a pull request.
- Include a `How to test this change` section in the PR description with exact reviewer commands for manually testing the change, including the task worktree path, a `cd <worktree>` command, and the command to run or open the changed slice.
- Do not rely on a generated PR body that may be truncated. Prefer writing the complete PR description to a markdown file or heredoc and creating/updating the PR with `gh pr create --body-file <file>` or `gh pr edit --body-file <file>`.
- After opening or updating the PR, inspect the rendered PR body or `gh pr view --json body` output enough to confirm the testing section is present and not cut off.
- Include the PR link in the final response.
- If the PR cannot be opened because of missing auth, network access, or unavailable tooling, report the exact blocker and provide the PR title, description, and command the user can run.

### Required self-review before completing implementation tasks
Before returning a final implementation summary, agents must review their changes against this prompt:

```txt
Review the changes against AGENTS.md and any relevant implementation plan.

Focus on:
- Did this stay within the requested MVP slice?
- Did all file changes happen on a fresh task branch/worktree rather than a shared base checkout?
- Did this avoid implementing real Pi behavior unless explicitly requested?
- Is harness-specific behavior isolated behind the harness layer?
- Is the kernel still the only layer that mutates Meringue orchestration state?
- Are TUI, input routing, state, kernel, heads, and harness responsibilities separated?
- Are file names, namespaces, and IDs consistent with the project conventions?
- Can the app or changed slice be run with a simple command?
- What verification was actually run?
- Was a PR opened from the task branch/worktree, and is the PR link included in the final response?
- What should be the next smallest vertical slice?
```

Agents should include the outcome of this review in their final response, especially any scope creep, architectural risk, skipped verification, or recommended next slice.

## Terminology
AgentTree means the UI hierarchy of projects, issues, heads, and workers.
Workspace means the filesystem directory where a worker harness session runs. To support multiple workers/subagents editing safely at the same time, prefer a dedicated git worktree per worker when the managed project is a git repository. A workspace may fall back to the project root or a dedicated directory only when worktrees are unavailable or explicitly disabled.
Harness means the underlying coding agent backend. Pi is the only required harness for the MVP, but the core architecture should not hard-code Pi outside the harness integration layer.
Do not use WorkTree to mean AgentTree.

## Statuses
Lifecycle statuses apply to projects, issues, and agents:
- `queued`
- `working`
- `idle`
- `blocked`
- `completed`
- `errored`
- `killed`

Question statuses are separate because questions are not executable work:
- `open`
- `answered`
- `dismissed`

Log entries do not have lifecycle statuses. They use log levels:
- `info`
- `warning`
- `error`

The TUI should never invent new lifecycle statuses, question statuses, or log levels. If a new value is needed, add it here first and update the kernel state model, persistence schema, and TUI rendering.

## Persistence
Store Meringue state in JSON.

Default path:

```txt
~/.meringue/state.json
```

State should include:
- `schema_version`
- projects
- issues
- agents
- questions
- logs
- counters for id generation

Use ISO8601 timestamps.
Write state atomically where practical.

# Agents
## Heads
We will be following a similar pattern to the node.js event loop
Where users should never be blocked from sending a prompt.
Heads should be stateless, spawning a new one for each user message and killing them after each completion
They should not modify files themselves, only read/research and return structured KERNEL commands.

If a head is unsure of a users request, they can ask a question to them, but they will still be killed.  
Instead this question and its prior prompt/thought process will be stored in json for a future head agent whenever the user so chooses to answer that question.
Don't assume the users next prompt will be an answer to that question though

On spawn the head should have access to 
- the kernel state and commands
- the agent tree status
- users message
- other active heads
- active workers
- unresolved questions
- the current working directory and enough local read-only tooling to inspect nearby repositories

An example flow:
user message
   -> kernel snapshots state
   -> spawn head harness session
   -> head returns commands
   -> kernel validates commands
   -> kernel mutates JSON state
   -> kernel spawns/prompts workers
   -> TUI updates
   -> head agent is killed

Head agents main purpose is to decide, what project to spawn the agent in, if we already have an issue for it, if a previously used agent should be used or if a new one should be spawned.

### Head project discovery
Project discovery is a head responsibility, not a kernel responsibility.

Heads may inspect the local machine with read-only tools before returning their JSON result. This is how they should understand local projects, git repositories, remotes, and working directories well enough to choose an existing project or propose `AddProject`.

Allowed head discovery examples:
- `pwd`
- `ls`
- `find` for nearby directories and `.git` folders
- `rg` for project names, package manifests, READMEs, and repo hints
- `git rev-parse --show-toplevel`
- `git remote -v`
- `git status --short --branch`
- reading lightweight files such as `README.md`, `AGENTS.md`, `package.json`, `Gemfile`, `pyproject.toml`, or similar manifests

Heads must not mutate files, git state, Meringue state, dependencies, databases, credentials, or remote services while doing discovery. Do not run commands such as `git checkout`, `git switch`, `git worktree add`, `git pull`, `git fetch`, package installs, generators, formatters that write files, or destructive shell commands from a head. If a head cannot confidently choose between multiple matching local repositories, it should return a clarifying question instead of guessing.

The kernel still validates `AddProject` paths and owns all Meringue state mutation. The kernel also still owns worker workspace allocation and git worktree creation for accepted `SpawnWorker` commands.

### Head result format
Heads should return structured JSON only.

Shape:

```json
{
  "title": "Short display title",
  "summary": "Short user-visible summary",
  "commands": [],
  "questions": []
}
```

The Ruby kernel validates this output before applying it.
The `commands` array should contain structured kernel commands, not prose instructions.
The `questions` array should contain clarifying questions only when ambiguity would likely cause bad work.

## Workers
Workers are real harness sessions. For the MVP, that means real Pi sessions.
They run in a specific workspace decided by the kernel from the head agent's proposed issue/project context.
The preferred worker workspace is a dedicated git worktree so multiple workers/subagents can edit concurrently without trampling the same checkout.
Workers do not directly interface with the user, so normal implementation and delivery privileges are pre-approved by the assigned issue: when requested they should edit files, use a separate branch/worktree, commit, push, and open or update a PR without asking for additional permission. They should still inspect git status and repository instructions before editing, avoid overwriting unrelated active work, and report true blockers such as missing credentials/auth, remote setup problems, branch/worktree collisions, unrelated work that would be overwritten, or unsafe/destructive operations.
They are attached to one specific issue, but multiple agents can be attached to one issue.
They may follow up, but should not be used many times.
They should automatically be pruned if they complete over 50% context full.
They will never know about the entire Meringue kernel and should be unaware of other workers, since they will be isolated in their assigned workspace.

# Output
We will render three main sections in the terminal separately.

## Chat Window
The chat window will be very simple, users should be able to type prompts and it should auto resize, just use the standard method all harnesses use for this but in ruby
We also want to allow for a small set of commands for users to clutch up if the agents mess up (they are not perfect)
Do the same thing as coding harnesses for these aswell we want it to be familiar

/help
/project add <path> [name]
/issue create <project_id> "<title>" ["description"]
/worker spawn <issue_id> "<prompt>"
/prompt <agent_id> "<message>"
/kill <agent_or_issue_id>
/tree
/state
/questions
/answer <question_id> "<answer>"

### User input routing
If input starts with `/`, parse it as a slash command and bypass the head agent.
If input explicitly answers a pending question, route it through `AnswerQuestion` and spawn a fresh head with the original question context plus the answer when useful.
Otherwise, treat the input as natural language and spawn a fresh stateless head agent.

Plain natural language should be the default path. Slash commands are a clutch/fallback interface for precise control, debugging, and recovery.

## AgentTree
the agenttree represents the philosphy we organize agents and the way we display them to the user
we will follow a similar pattern to that of a filesystem, with issues being folders and agents being files (metaphorically)
this will take up the left shelf of the terminal and is paramount for a developers understanding of how their agents are working

issues should have a title that is short and sweet and a check/empty box/x depending on completion/error status
agents should have a similar thing, but instead focused on if they have completed their issue, if they are working, or if they have error'd out, or if they have run into a blocker
Heads should be on the highest level and they basically morph into issues as they figure out what they want to spawn.  
The worker agents title should be decided by the head agent and a head agents own issue title should be computed as their first task to display to the user in the AgentTree

Issues should be a composite key by their project and their issue number, 
projects should be a primary key based on their project number (ordered by creation), 
agents should be a composite key of their project number, issue number, and agent number

Example timestates (we will make it prettier than this):
# state 1
H1 - Update vim config to use oil instead of mini
H2 - Fix the password not submitting to the database

MeringueIphoneApp
    I1 - Fix signup screen - 1/2
        W1 - Add email collision check - error
        W2 - Hide password field - checkmark
    I2W1 - Change navigation tabs to stack

# state 2
MeringueIphoneApp
    I1 - Fix signup screen - 1/2
        W1 - Add email collision check - error
        W2 - Hide password field - checkmark
        W3 - Fix the password not submitting to the database
    I2W1 - Change navigation tabs to stack
config 
    I1W1 - Update vim config to use oil instead of mini

Users should be able to navigate to the agent tree using a keybind and JUMP into a coding harness session, which will just open it in a new terminal/tmux/whatever they use 
(for now we will just use pi session and new terminal)

## Logs
Logs are the user-visible history of what Meringue, the kernel, heads, and workers have done.
They should be concise enough to scan during a hackathon demo, but structured enough that the TUI can render them differently by source and severity.

Logs should be append-only. Do not use logs as the source of truth for state.
The JSON state owns projects, issues, agents, questions, and harness session metadata.
Logs explain how that state changed.

A log entry should include:
- `id`
- `timestamp`
- `source_type`: `user`, `kernel`, `head`, `worker`, `harness`, or `system`
- `source_id`: the related Meringue id when available
- `level`: `info`, `warning`, or `error`
- `message`: short user-visible text
- `details`: optional structured data for expanded views

The logs pane should show:
- user prompts received
- head agents spawned and completed
- kernel commands proposed by heads
- kernel commands accepted/rejected by validation
- issues created, modified, completed, blocked, or killed
- workers spawned, prompted, completed, blocked, errored, or killed
- important harness events such as Pi RPC `agent_start`, `agent_end`, tool execution start/end, and process exits
- clarifying questions created and answered

Do not persist every streamed token from the harness as a log entry.
Streaming output can be rendered live in the TUI, while durable logs should store important lifecycle events,
final summaries, errors, and kernel state changes.

Logs come from the Ruby kernel, harness process events, and worker final messages. For the MVP, harness process events are Pi RPC events.

# KERNEL
The kernel is the only part of Meringue that mutates orchestration state.
Heads and slash commands should return structured kernel commands. The kernel validates those commands, applies accepted commands to JSON state, and emits logs describing what happened.

Natural language and slash commands should converge into the same command layer:

```txt
Natural language -> fresh head agent -> KernelCommand[]
Slash command    -> command parser    -> KernelCommand[]
                                      -> kernel validates
                                      -> kernel mutates JSON state / harness sessions
                                      -> logs are appended
                                      -> TUI rerenders
```

Heads should not directly edit Meringue JSON state or project files. They propose commands. Workers may edit assigned project files through their harness sessions.

## Workspace management
Worker isolation is a kernel-owned responsibility.

The kernel should allocate worker workspaces before spawning harness sessions, then pass the resolved workspace path to the harness client as `cwd`.
For git-backed projects, the preferred allocation strategy is one git worktree per worker using a Meringue-owned, human-facing branch name derived from the issue/task title, such as `meringue/fix-signup-validation-a1b2c3d4`. Do not expose Meringue agent ids, worker ids, Pi ids, or subagent implementation details in workspace branch names.
Workspace metadata should be persisted on the agent record so sessions can be reconciled, resumed, killed, or cleaned up later.
The TUI, heads, and harness clients should not directly create, prune, or mutate worktrees.

## Harness integration
Meringue must be designed as harness-independent orchestration software, even though the MVP only needs Pi.

All harness-specific behavior belongs behind a harness client/process manager. The TUI and kernel should depend on generic harness operations, not Pi-specific commands.

The harness client should expose operations shaped like:
- `spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)`
- `prompt_session(session_ref, prompt, mode:)`
- `abort_session(session_ref)`
- `kill_session(session_ref)`
- `get_state(session_ref)`
- `read_events(session_ref)`
- `attach_session(session_ref)`

The generic session reference should track:
- `harness`, such as `pi`
- `pid`
- `cwd`
- `session_id`
- `session_file`
- `is_streaming`
- `last_event_at`

### Pi harness rules for MVP
Use real Pi sessions only.

Long-lived workers should use:

```bash
pi --mode rpc
```

The Ruby Pi harness client should communicate with Pi over JSONL stdin/stdout.
Parse stdout as newline-delimited JSON and never rely on human-formatted text when structured events are available.

After spawning a Pi process, call `get_state` and store Pi's `sessionId` and `sessionFile` in the generic harness session fields.
Use `set_session_name` to label Pi worker sessions with a concise human-facing task title, such as `Fix signup validation`; avoid embedding Meringue agent ids, worker ids, Pi ids, or subagent implementation details in worker session names.

When prompting an active worker, use Pi RPC `steer`, `follow_up`, or `prompt` with `streamingBehavior` instead of sending a normal prompt blindly.

Short-lived heads may use Pi RPC or Pi JSON mode, but that choice must stay inside the Pi harness client.
The kernel should only know that it spawned a `head` session and received a structured `HeadResult`.

## Core objects returned by commands
Commands should return simple serializable Ruby objects/hashes.

### Project
A managed codebase.

Fields should include:
- `id`, such as `P1`
- `name`
- `root_path`
- `status`
- `created_at`
- `updated_at`

### Issue
A unit of work under a project.

Fields should include:
- `id`, such as `P1-I1`
- `project_id`
- `parent_issue_id`
- `title`
- `description`
- `status`
- `agent_ids`
- `created_at`
- `updated_at`

### Agent
A real harness-backed process or historical session.

Fields should include:
- `id`, such as `H1` or `P1-I1-W1`
- `type`: `head` or `worker`
- `status`
- `project_id`
- `issue_id`
- `workspace_path`
- `workspace_strategy`: `git_worktree`, `project_root`, or `dedicated_directory`
- `workspace_branch`: git branch used by the worktree when relevant
- `harness`: `pi` for the MVP
- `pid`
- `harness_session_id`: Pi `sessionId` for the MVP
- `harness_session_file`: Pi `sessionFile` for the MVP
- `harness_metadata`: optional harness-specific details
- `created_at`
- `updated_at`

### Question
A clarifying question from a head agent.

Fields should include:
- `id`, such as `Q1`
- `head_id`
- `project_id`
- `issue_id`
- `question`
- `context`
- `status`: `open`, `answered`, or `dismissed`
- `answer`
- `created_at`
- `updated_at`

### LogEntry
A durable user-visible event.

Fields should include:
- `id`
- `timestamp`
- `source_type`
- `source_id`
- `level`
- `message`
- `details`

## Kernel commands and expected returns
These are the MVP kernel commands. More can be added later, but new commands should follow the same shape:
validate input, mutate state only inside the kernel, return a serializable result, and append a log entry.

### `ListAll() -> AgentTree`
Returns the current AgentTree for rendering.

Should include all projects, issues, workers, active heads, pending questions, and status counts.

### `AddProject(Path, Name?) -> Project`
Registers a project root with Meringue.

The kernel should validate that `Path` exists and is a directory. The returned project should have an id like `P1`.

### `GetInfo(TargetID) -> Project | Issue | Agent | Question`
Returns detailed information about a project, issue, agent, or question.

For agents, include harness metadata, recent logs, status, session file, and recent assistant/user messages when available.

### `SpawnHead(UserMessage, QuestionID?) -> Agent`
Spawns a fresh stateless head harness session for one user message. For the MVP, this is a Pi-backed session.

The head receives a kernel snapshot, current AgentTree, active workers, active heads,
unresolved questions, and the user message.
If `QuestionID` is provided, the head should also receive the prior question context and answer.

The returned agent should be a head id like `H1`, plus harness session metadata once available.

### `ApplyHeadResult(HeadID, HeadResult) -> KernelCommandResult[]`
Validates and applies commands proposed by a head.

The head result should include:
- `title`: short display title for the head in the AgentTree
- `summary`: short user-visible summary
- `commands`: structured kernel commands
- `questions`: optional clarifying questions

Each accepted or rejected command should produce a `KernelCommandResult` and a log entry.

### `CreateIssue(ProjectID, Title, Description, ParentIssueID?) -> Issue`
Creates an issue under a project.

Titles should be short. Descriptions should be detailed and include relevant user prompts, context, links, previous decisions, and worker instructions.

### `ModifyIssue(IssueID, Title?, Description?, ParentIssueID?, Status?) -> Issue`
Updates an existing issue.

This supports title/description edits, reparenting, and status changes such as `working`, `blocked`, `completed`, or `errored`.

### `SpawnWorker(IssueID, Prompt, WorkspacePath?) -> Agent`
Spawns a real worker harness session for an issue. For the MVP, this is a Pi worker session.

Workers are usually one-to-one with issues.
If `WorkspacePath` is omitted, the kernel should allocate a worker-specific workspace through the workspace manager.
Prefer a dedicated git worktree for git-backed projects so concurrent workers/subagents can edit safely.
The harness should receive the allocated workspace as its `cwd`; harness clients should not create or mutate worktrees directly.
The returned agent should include a Meringue id like `P1-I1-W1`, workspace metadata, pid, harness session id,
and harness session file when available.

### `PromptAgent(AgentID, Prompt, Mode?) -> Agent`
Sends a prompt to an existing harness session.

`Mode` should support:
- `normal`: send if idle
- `steer`: queue during active work and deliver before the next LLM call
- `follow_up`: queue until the worker finishes current work

If a harness session is streaming, the kernel should use the harness client's queued prompt behavior.
For Pi, use RPC `steer`, `follow_up`, or `prompt` with `streamingBehavior` instead of blindly sending a normal prompt.

### `AskQuestion(HeadID, Question, Context?) -> Question`
Stores a clarifying question from a head agent.

Questions should not block unrelated work.
The next user prompt should not be assumed to answer the question unless it explicitly references the question
or the routing logic determines it is an answer.

### `AnswerQuestion(QuestionID, Answer) -> Question`
Marks a question as answered and stores the answer.

Answering a question may spawn a fresh head with the original question context plus the new answer.

### `Kill(TargetID) -> Project | Issue | Agent`
Kills an agent, issue, or project subtree.

Killing should cascade downward. Killing an issue should kill or mark killed all child issues and attached workers. Killing a project should do the same for every issue and worker under it.

### `ReconcileSessions() -> ReconcileResult`
Runs at startup and periodically while Meringue is active.

It should load JSON state, inspect tracked PIDs and harness session files,
reconnect or mark sessions as resumable when possible,
and mark missing/crashed processes as `errored` or `idle` depending on evidence.

## Kernel command results
Every command should return a result object shaped like:

```txt
KernelCommandResult
- command_id
- command_type
- status: accepted | rejected | failed
- target_id
- message
- result
- errors
- log_entry_ids
```

Rejected commands should not mutate state. Failed commands may partially mutate state only when unavoidable, and the failure should be logged clearly.
