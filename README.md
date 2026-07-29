# Meringue

Meringue is an open-source, terminal-first control plane for running many coding agents at once. It is designed to sit above the coding-agent harnesses developers already like, so teams can coordinate work across Pi, Claude Code, Antigravity, or future backends without rebuilding their workflow around one vendor.

The goal is simple: keep the developer in one place while many agents work in parallel. Meringue organizes that work as projects, issues, agents, questions, and logs, then routes each task to the configured harness behind a small integration layer.

## The problem

Modern coding harnesses are excellent at giving one agent a focused environment for one task. The new bottleneck is what happens when a developer wants ten agents moving in parallel:

- each issue lives in a different terminal or harness session;
- the developer has to reread the last output before every prompt;
- prompts, blockers, PRs, and status updates are spread across windows;
- switching contexts all day becomes tiring and error-prone;
- switching harnesses can mean switching the entire way work is managed.

Meringue keeps that parallel work in one place. The developer can keep typing, monitor structured progress, jump into a specific worker only when needed, and stay oriented around the product goals instead of terminal bookkeeping.

## Why open source and harness agnostic

Meringue is meant to be infrastructure that developers can adapt, inspect, and extend. Coding-agent harnesses will keep changing, and different teams will prefer different backends. Meringue should make those choices pluggable rather than forcing a single blessed agent runtime.

The MVP backend is Pi because it is the fastest path for this project today. The architecture still keeps harness-specific behavior behind provider clients so the kernel and TUI can depend on generic operations such as spawning a session, prompting a session, reading events, aborting work, and attaching to a session.

Supported provider names in the current config surface include:

- `pi`
- `claude` / `claude_code` / `claude-code` / `cc`
- `antigravity`

That provider list should grow over time without changing the core product model.

## Product value

Meringue provides a single control plane for multi-agent development:

- **Bring your own harness.** Use the coding-agent backend you want while Meringue handles orchestration, state, logs, and navigation.
- **One chat stream for new work.** Natural-language prompts spawn short-lived head agents that decide what should happen next.
- **A kernel-owned state model.** The kernel validates commands, mutates JSON state, allocates worker workspaces, and records logs.
- **An AgentTree view.** Projects, issues, heads, workers, questions, and PR markers are shown in a filesystem-like hierarchy.
- **Structured logs.** Important lifecycle events are captured without flooding the UI with every streamed token.
- **Safe parallelism.** For git-backed projects, workers should run in dedicated worktrees and branches so multiple agents can edit safely at once.

## How Meringue coordinates work

A typical flow looks like this:

1. A developer describes a goal in the Meringue chat.
2. A stateless head agent reads lightweight project context and proposes structured kernel commands.
3. The kernel validates those commands, creates or reuses issues, and prompts or spawns worker agents.
4. Follow-up messages normally continue the best existing worker session so its persisted harness context remains available; the head can instead queue active work, spawn a related worker, or replace an unhealthy worker.
5. Each new worker receives an assigned workspace and runs through the configured harness.
6. The TUI keeps the AgentTree, logs, follow-up/replacement relationships, questions, and delivery state visible so the developer can intervene only when needed.

This repository also uses that workflow while developing Meringue itself, but self-hosting is a proof point rather than the product boundary. The product is a general open orchestration layer for any project and any supported harness.

## Repository layout

```txt
Gemfile                            # Bundler setup for running the executable from a clone
meringue.gemspec                   # local gem metadata that exposes the meringue executable
bin/meringue                       # executable CLI entrypoint
lib/meringue/cli.rb                # command parsing and runtime setup
lib/meringue/app.rb                # TUI application lifecycle
lib/meringue/kernel/               # command validation and state mutation
lib/meringue/heads/                # head-agent context, runners, and parsing
lib/meringue/harness/              # Pi and other harness integrations
lib/meringue/tui/                  # terminal rendering, panes, navigation, styles
lib/meringue/state/                # JSON persistence models and store
docs/config.md                     # config and harness provider reference
docs/head_agent_kernel_commands.md # compact head-agent command contract
docs/keybindings.md                # TUI keyboard and jump-mode controls
docs/kernel-command-application.md # exactly-once command application invariants
fixtures/config.example.toml       # example local config
fixtures/demo_state.json           # demo state for the TUI
scripts/head_session_smoke.rb      # prints the head harness session lifetime without a real harness
scripts/kernel_exactly_once_smoke.rb # checks exactly-once command application across instances
scripts/question_answer_smoke.rb   # checks that answering a question routes real work, with no harness
scripts/agent_tree_scroll_smoke.rb # checks AgentTree pane scrolling, clamping, and selection reveal
```

## Setup

Meringue is a Ruby application with a checked-in executable and a Bundler setup for local development.

Requirements:

- Ruby 3.1 or newer.
- Bundler, which is included with most Ruby installs.
- At least one supported harness CLI installed and authenticated when you want to spawn real agents. You can use `demo` first without any harness.

Clone and install:

```bash
git clone https://github.com/jackson-lafrance/meringue.git
cd meringue
bundle install
bundle exec meringue --help
```

You can also run the repository executable directly without installing anything beyond Ruby:

```bash
bin/meringue --help
```

Optional local config lives at `~/.meringue/config.toml`. Start from the fixture if you want to customize colors, harness commands, or role-specific harness arguments:

```bash
mkdir -p ~/.meringue
cp fixtures/config.example.toml ~/.meringue/config.toml
```

Do not store API keys or secrets in this file. Use each harness CLI's normal authentication flow or environment variables.

## Usage

Open the interactive TUI:

```bash
bundle exec meringue
# or
bundle exec meringue tui
```

Open a safe demo state without spawning real agents:

```bash
bundle exec meringue demo
```

Print the CLI help:

```bash
bundle exec meringue --help
```

Choose a harness at runtime:

```bash
bundle exec meringue tui --harness pi
bundle exec meringue tui --harness claude
bundle exec meringue tui --head-harness antigravity --worker-harness claude
```

Use a custom state or config file:

```bash
bundle exec meringue tui --state /tmp/meringue-state.json
bundle exec meringue tui --config ./fixtures/config.example.toml
```

If you skip Bundler, replace `bundle exec meringue` with `bin/meringue` in the commands above.

Useful slash commands inside the TUI include:

- `/help` — show command syntax.
- `/project add <path> [name]` — register a project.
- `/issue create <project_id> "<title>" ["description"]` — create an issue manually.
- `/worker spawn <issue_id> "<prompt>"` — spawn a worker for an issue.
- `/prompt <agent_id> "<message>"` — follow up with an existing agent.
- `/jump [agent_id]` — open an agent's focused workspace; omit the id to navigate issues/workers and open PRs from jump mode.
- `/questions` — list questions and their statuses.
- `/answer <question_id> "<answer>"` — answer an open question; the kernel records the answer and routes the work it unblocks.
- `/dismiss <question_id>` — close an open question without answering it.
- `/theme <name>` — persist a TUI colorscheme.
- `/harness <pi|claude|antigravity>` — select the harness for future agents.
- `/defaults` — inspect the model and thinking level for all future Pi heads and workers.
- `/default-model <provider/model>` — persist the model for all future Pi sessions; existing sessions are unchanged.
- `/default-thinking <level>` — persist the thinking level for all future Pi sessions; existing sessions are unchanged.
- `/session-settings <agent_id>` — refresh and inspect one existing agent's effective Pi model and thinking level (the old dashboard `/session` spelling remains a compatibility alias; focused workspaces advertise `/open-session` for opening the harness UI).
- `/model <agent_id> <provider/model>` — change only one active/resumable Pi session's model; future defaults are unchanged.
- `/thinking <agent_id> <level>` — change only one active/resumable Pi session's thinking level; future defaults are unchanged.
- `/keybind` — show active TUI keybindings.
- `/prune` — one cleanup pass that removes resolved (completed/killed) and errored records together and removes their clean, unlocked Meringue-managed worktrees. Unsafe cleanup (dirty, locked, ambiguous, or failed) retains the bundle and logs why so it can be retried.
- `/recount` — compact project, issue, worker, and question numbering after records are removed.

See `docs/head_agent_kernel_commands.md#prune` for prune eligibility and worktree cleanup safety, `docs/recount.md` for the renumbering/cross-reference/active-session rules, and `docs/keybindings.md` for keyboard navigation, customization, and jump-mode details.

### Answering a head's question

When a head cannot route a request safely it asks a clarifying question, and the chat shows `Question Q1: …` with the reason and the ways to answer it. Answering is a real routing action, not just bookkeeping:

- `/answer Q1 "<answer>"` records the answer, closes the question, and spawns a fresh head that receives the question text, the question context, the project/issue scope, the message that originally triggered the question, and your answer. That head reuses the question's issue and prompts the worker already working on it whenever that is the right move.
- Replying in plain chat also works. A head reads the open questions in its context; if your message clearly answers exactly one of them, it closes that question and routes the unblocked work in the same step. If several questions could match, or the message is a new goal, the questions stay open and the message is routed as its own request.
- `/dismiss Q1` closes a question you no longer care about without routing any work.

Open questions are visible as a `? <count>` marker in the chat header and through `/questions`, which also prints the exact `/answer` command to use.

### Reading the logs pane

Log rows use compact, color-coded headers so agent output is easy to separate from kernel and command logs:

- `◆ H1` — head-agent progress, bold, in a color derived from its id.
- `✦ P1-I1-W1` — worker progress in that worker's stable color.
- `✓ P1-I1-W1 · done` — a completed worker result.
- `! P1-I1-W1 · warn/err` — an actionable warning or error.
- `▪ meringue` — kernel, command, and system logs, in the theme accent color.
- `● you` — your own prompts.

Single-click a project, issue, head, or worker row in the AgentTree to filter the logs pane to that node: a worker shows its own logs, an issue adds its workers and child issues, and a project covers its whole subtree. Issue and worker selections also focus subsequent natural-language chat: an issue targets itself, while a worker resolves to its owning issue and remains a preferred session-context hint. The composer title becomes `chat → <issue_id>` and the bottom chip says that the head routes the message, because every message still spawns a fresh head rather than prompting the worker directly. Selected prompts are tagged to the issue (and the selected worker when applicable), so they remain visible in the focused logs.

The selected row stays highlighted and the filter keeps applying while you move focus to the logs or chat pane; the logs title becomes `logs — <selected_id>`. Click another row to change the target. Click the highlighted row again, click empty AgentTree space, or press `Esc` to clear it and return chat to unscoped routing. Project selections and heads without an owning issue are log-only filters. Pending heads or issues with no focused worker workspace are a silent no-op when double-clicked, so expected unavailability never floods or persists in chat; actual workspace/open failures are still reported. See [`docs/keybindings.md`](docs/keybindings.md#agenttree-selection-log-filtering-and-chat-routing) for the exact scoping and routing rules.

The header owns the agent id and title; the body does not repeat an `<id> output:` label. Agent body lines use a colored `▌` gutter, while kernel and user lines keep a plain indent. Conversational head and worker output renders common Markdown—headings, emphasis, ordered/unordered/task lists, blockquotes, inline and fenced code, and links—with terminal-aware wrapping. Kernel/command rows and warnings/errors retain their semantic log presentation instead of being interpreted as chat Markdown.

ANSI sequences, control characters, common pasted terminal boxes, duplicate transcript headers, excess whitespace, and duplicate PR URLs are removed at render time without changing the original text stored in state. Styles are emitted as Canvas metadata rather than accepted from agent text. Agent colors come from the active colorscheme's deterministic identity palette, so `/theme <name>` restyles Markdown markers, gutters, and headers together. Set `NO_COLOR=1` to disable color; icons, ids, status text, gutters, Markdown block markers, and visible link targets keep the output usable.

See [`docs/agent-output.md`](docs/agent-output.md) for the Pi RPC-to-TUI rendering path, Markdown behavior, safety constraints, and before/after examples.

## Configuration and state

Default paths:

```txt
~/.meringue/config.toml   # optional TOML config
~/.meringue/state.json    # persisted Meringue state
```

The config supports TUI colorschemes, TUI keybinding overrides, default harness selection, role-specific head/worker harnesses, and provider command overrides. See `docs/config.md` for the full reference.

The state file stores projects, issues, agents, questions, logs, counters, and harness session metadata. The kernel is the only layer that should mutate this orchestration state. Durable logs retain the newest 500 entries so lifecycle history cannot grow without bound; see [`docs/log-retention.md`](docs/log-retention.md) for the measured rationale, compatibility behavior, and benchmark.

The dashboard chat remains the primary workflow: describe new goals naturally and let head agents route the work. When one issue needs sustained direction, iterative plan discussion, research, investigation, or closer transparency, press `a` or double-click its worker to open the optional focused workspace. It continues that worker's existing context and shows the complete available Pi transcript, with distinct role/type header colors and filters for normal output, final output, reasoning, and tools/results while message bodies stay in the normal foreground. Focused commands use a configurable leader so shell/editor bindings remain available: by default press `Ctrl-Space`, then `t` to switch views, `f` to cycle transcript filters, `p` to open the worker's saved Pi session with the existing external launcher, `e` to launch the editor, `b` to open the verified delivery PR, or `q` to return to the AgentTree without stopping the worker or terminal. See `docs/keybindings.md` for the full interaction model.

## Current architecture in one flow

```txt
User prompt
  -> fresh head agent reads context and proposes KernelCommand[]
  -> kernel validates commands and mutates JSON state
  -> kernel allocates worker workspaces and starts harness sessions
  -> configured harness backend runs the agent work
  -> AgentTree and logs rerender in the TUI
  -> developer jumps into worker sessions or PRs only when needed
```

Heads orchestrate by creating/reusing issues, prompting workers, and asking questions; they do not deliver substantive task answers directly. Every natural-language message still gets a fresh stateless head. Each head owns one tracked harness session for as long as it is alive, so its session id, session file, and pid are visible in state and reconcilable exactly like a worker's; the kernel closes that session and marks it terminal when the head's result is applied, when it errors, or when it is killed. Its routing context is assembled from existing issues, recent lifecycle logs, and generic harness/session metadata rather than a second conversation-state model.

For a follow-up, the head chooses among continuing a settled session (`normal`), correcting active work (`steer`), queuing a next step (`follow_up`), spawning a related worker on the same issue, or replacing an unhealthy/stale worker. Pi's persisted session retains the detailed conversation context. AgentTree worker rows label successors with `after W…` or `replaces W…`, while lifecycle logs state the full relationship. Workers carry out assigned implementation, investigation, or informational work, and only need PRs when the assigned delivery calls for repository changes. The kernel owns orchestration state. Harness-specific behavior stays behind the harness client layer.

## Contributing notes for agents

Before changing this repository, read `AGENTS.md`. It defines the mission, architecture boundaries, terminology, workflow, and non-negotiable test policy.

Important constraints:

- keep implementation slices small and aligned to the assigned issue;
- add or extend hermetic Minitest coverage for behavior changes and run it with `rake test`;
- use task-specific branches/worktrees for worker changes;
- commit only the assigned issue's changes;
- include manual verification steps in pull requests.
