# Meringue

Meringue is an open-source, terminal agent orchestrator for running many coding agents at once. It is designed to sit above the agent harnesses developers already like, so teams can coordinate work across any backend without rebuilding their workflow around one vendor.

The goal is simple: keep the developer in one place while many agents work in parallel. Meringue organizes that work as projects, issues, agents, questions, and logs, then routes each task to the configured harness behind a small integration layer.

## Quick start

> **Pre-release:** Meringue is not on RubyGems yet. The installer below uses a source checkout; `gem install meringue` will work after the first announced release. See [Releasing and distribution](docs/releasing.md).

Install it:

```bash
curl -fsSL https://raw.githubusercontent.com/jackson-lafrance/meringue/main/install.sh | sh
```

That clones Meringue to `~/.meringue/src`, installs its dependencies, and puts a `meringue` command on your PATH. It needs Git and Ruby 3.1+, and it never touches anything outside `~/.meringue` and `~/.local/bin`. Re-run it any time to update.

Then, from a repository you want to work on:

```bash
meringue
```

The first launch walks you through setup: which coding agent to drive, the repository to register, and a theme. It reports which harnesses it can actually find on your machine, and it will not finish without one.

**You also need a coding-agent CLI**, installed and signed in. Meringue drives [Claude Code](https://claude.com/claude-code) (`claude`), Codex CLI (`codex`), or Pi (`pi`) — it orchestrates them and never installs one for you. To look around before setting one up:

```bash
meringue demo     # a populated dashboard, no harness and no agents required
```

If something looks wrong:

```bash
meringue doctor   # checks Ruby, git, your harness, config, and state, and names the fix
```

### What you'll see

```txt
╭─ agent tree ─────────────────────────╮ ╭─ logs ───────────────────────────────────────────────╮
│ HEADS                                │ │ [10/07 20:01] ● you                                  │
│   └─ ✓ H2  Classify dotfiles prompt  │ │   Update vim config to use oil instead of mini.      │
│                                      │ │ [10/07 20:04] ◆ H2 · Classify dotfiles prompt        │
│ ● P1  Meringue                       │ │ ▌ Created the dotfiles task                          │
│   ├─ ● I1  Build fake TUI demo 0/2   │ │ [10/07 20:05] ✓ P2-I1-W1 · Update vim config · done  │
│   │ ├─ ● W1  Draw three-pane layout  │ │ ▌ Replaced mini with `oil.nvim`.                     │
│   │ └─ · W2  Polish fixture state    │ │ [10/07 20:07] ▪ meringue                             │
│   └─ ! I3  Reconcile stale sessions  │ │   Question Q1: Which project should get the fix?     │
╰──────────────────────────────────────╯ ╰──────────────────────────────────────────────────────╯
╭─ chat ─────────────────────────────────────────────────────────────────────────────────────────╮
│ › describe a goal, e.g. "fix the flaky signup test"                                            │
╰────────────────────────────────────────────────────────────────────────────────────────────────╯
```

Type a goal in plain English. A **head** agent reads the repository and decides what should happen; it opens an **issue** and starts a **worker** on it, in that worker's own git worktree and branch. You watch the tree and open an agent only when you want to. `/glossary` defines every term Meringue uses; `/help` lists every command, grouped.

### Installing from a clone instead

```bash
git clone https://github.com/jackson-lafrance/meringue.git
cd meringue
bundle install
bundle exec meringue
```

A clone gives you `bundle exec meringue` rather than a global `meringue`. From inside the dashboard, `/update` updates a clean checkout and reloads; `/reload` restarts without updating. Both preserve your configuration and state, which live in `~/.meringue/` outside the source.

### Troubleshooting

Run `meringue doctor` first — it checks each of these and prints the fix. The recurring ones:

- **`meringue: command not found`** — the installer's `~/.local/bin` is not on your PATH. Add `export PATH="$HOME/.local/bin:$PATH"` to your shell startup file. From a clone, the command is `bundle exec meringue`.
- **`bundle: command not found`** — `gem install --user-install bundler -v '~> 2.5'`, then put `$(ruby -r rubygems -e 'print Gem.user_dir')/bin` on your PATH.
- **A harness is missing** — `command -v claude` (or `codex` / `pi`). Put it on PATH, or set that provider's `command` to an absolute path as described in [harness configuration](docs/config.md#provider-sections).


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

Meringue is harness-agnostic: there is no default backend, and harness-specific behavior stays behind provider clients so the kernel and TUI depend only on generic operations — spawning a session, prompting a session, reading events, aborting work, and attaching to a session.

Backends come in two shapes:

- **Interactive** (Claude Code and Codex CLI). Meringue starts the agent CLI once, in its own native interactive mode inside a PTY that Meringue owns for the life of the session. It types prompts in and reads the agent's own durable JSONL transcript back out for every state decision. Because that one process serves both the autonomous worker and the focused viewer, opening focus is an attach: no turn is interrupted, no process is replaced, and returning to the dashboard costs nothing.
- **Managed transport** (Pi). Meringue drives a long-lived RPC transport. Focusing a worker hands the session over to a native interactive process and back again, which means an active turn must be settled first.

Supported provider names in the current config surface include:

- `pi`
- `claude` / `claude_code` / `claude-code` / `cc`
- `codex` / `codex-cli` / `openai-codex`

That provider list should grow over time without changing the core product model.
## Product value

Meringue provides an orchestrator for multi-agent development:

- **Bring your own harness.** Use the coding-agent backend you want while Meringue handles orchestration, state, logs, and navigation.
- **One chat stream for new work.** Natural-language prompts spawn short-lived head agents that decide what should happen next.
- **A kernel-owned state model.** The kernel validates commands, mutates JSON state, allocates worker workspaces, and records logs.
- **An AgentTree view.** Projects, issues, heads, workers, questions, and PR markers are shown in a filesystem-like hierarchy. Every agent row carries its own identity color and its harness logo, in every status, and the same color follows that agent into the logs pane and the chat composer.
- **Structured logs.** Important lifecycle events are captured without flooding the UI with every streamed token.
- **Safe parallelism.** For git-backed projects—even when the registered root is a bare common repository—workers run in dedicated editable worktrees and branches. Candidate ownership is reserved across processes and revalidated before launch; collisions are reallocated rather than shared. Sequential steps of one goal are the exception: a worker that continues a settled predecessor's work carries on in that worktree and branch, so one goal delivers one branch and one PR.

## How Meringue coordinates work

A typical flow looks like this:

1. A developer describes a goal in the Meringue chat.
2. A stateless head agent reads lightweight project context and proposes structured kernel commands.
3. The kernel validates those commands, creates or reuses issues, and prompts or spawns worker agents.
4. Follow-up messages normally continue the goal in a fresh worker chained to the settled one it follows, inheriting its worktree, branch, and final report rather than its transcript; the head can instead steer active work, resume a worker whose turn died mid-flight, or replace an unhealthy worker.
5. Each new worker receives an assigned workspace and runs through the configured harness.
6. The TUI keeps the AgentTree, logs, follow-up/replacement relationships, questions, and delivery state visible so the developer can intervene only when needed.

This repository also uses that workflow while developing Meringue itself, but self-hosting is a proof point rather than the product boundary. The product is a general open orchestration layer for any project and any supported harness.

## Repository layout

```txt
install.sh                         # one-line installer: clone, dependencies, and a meringue shim
Gemfile                            # Bundler setup for running the executable from a clone
meringue.gemspec                   # local gem metadata that exposes the meringue executable
bin/meringue                       # executable CLI entrypoint
bin/meringue-record                # macOS proof-video helper
lib/meringue/cli.rb                # command parsing and runtime setup
lib/meringue/doctor.rb             # meringue doctor: environment checks and their fixes
lib/meringue/app.rb                # TUI application lifecycle
lib/meringue/kernel/engine.rb      # the kernel's constructor and its command table
lib/meringue/kernel/engine/        # one file per command family; all reopen the same class
lib/meringue/heads/                # head-agent context, runners, and parsing
lib/meringue/harness/              # harness integrations and the shared transports
lib/meringue/tui/app.rb            # the dashboard's constructor and its key dispatch
lib/meringue/tui/app/              # one file per dashboard surface; all reopen the same class
lib/meringue/tui/app/setup.rb      # first-run steps, harness availability, project adoption
lib/meringue/tui/first_run.rb      # what an empty dashboard says instead of reporting emptiness
lib/meringue/tui/glossary.rb       # /glossary: the vocabulary the rest of the UI assumes
lib/meringue/harness/availability.rb # whether a backend's executable is present and runnable
lib/meringue/tui/                  # terminal rendering, panes, navigation, styles
lib/meringue/state/                # JSON persistence models and store
lib/meringue/goals/                # goal-loop record, decisions, judge, and metric probe
docs/commands.md                   # the complete slash-command inventory and dashboard reference
docs/config.md                     # config and harness provider reference
docs/releasing.md                  # RubyGems release gates and Homebrew strategy
docs/settings.md                   # full-screen settings, persistence, experiments, and shared setup UI
docs/video-recording.md             # macOS proof-video workflow
docs/commit-authorship.md          # worker commit identity policy and history audit
docs/delivery-artifact-privacy.md  # branch, commit, and PR metadata privacy policy
docs/head_agent_kernel_commands.md # compact head-agent command contract
docs/keybindings.md                # TUI keyboard and jump-mode controls
docs/onboarding.md                 # first-run setup flow, keys, and completion marker
docs/kernel-command-application.md # exactly-once command application invariants
docs/goal_loops.md                 # goal loops: metric, judge, budgets, and interruption
docs/worker-pause-resume.md         # user-directed worker pause and resume semantics
docs/worker-transfer.md             # portable worker export/import and fresh-session retry
docs/quiet-workers.md              # how long an agent has been silent, and what says so
docs/scalability.md                # hermetic process-level responsiveness sweep
docs/testing.md                    # test-suite guide and coverage boundaries
fixtures/config.example.toml       # example local config
fixtures/demo_state.json           # demo state for the TUI
test/integration/                  # hermetic component and area tests
test/e2e/                          # end-to-end flows across CLI/kernel/heads
test/support/                      # shared test helpers and fakes
```

## Using it

Type what you want in plain English. A head reads the repository, opens or
reuses an issue, and starts a worker on it; follow-up messages continue the same
goal. You rarely need a slash command for ordinary work — heads run the same
kernel commands from plain language, so "prune the merged issues" or "kill
P1-I9-W3" do what they say.

When you do want them:

- `/help` — every command, grouped by what you are trying to do.
- `/glossary` — what head, worker, issue, project, and harness mean.
- `/project add <path> [name]` — register a repository as a project.
- `/setup` — reopen first-run setup.
- `/config` — the full settings editor.
- `/jump [agent_id]` — open an agent's focused workspace.

See [`docs/commands.md`](docs/commands.md) for the complete inventory, how to
answer a head's question, and how to read the logs pane and AgentTree.


## Configuration and state

Default paths:

```txt
~/.meringue/config.toml   # optional TOML config
~/.meringue/state.json    # persisted Meringue state
```

The config supports TUI colorschemes, animations, every TUI keybinding, separate head/worker harnesses, shared model/thinking defaults (or role-specific values when the split-defaults experiment is enabled), provider commands/environment/arguments, workspace and launcher bounds, safety policy, experiments, the first-run setup marker, and optional status-bar layouts. `/config` and `/status-bar` edit these through one schema-backed atomic transaction. See [`docs/status_bar_layouts.md`](docs/status_bar_layouts.md). For a file-based starting point, copy [`fixtures/config.example.toml`](fixtures/config.example.toml) to `~/.meringue/config.toml`; keep API keys out of this file and use each harness's normal authentication or environment variables. GitHub support is an opt-in experiment for new installations; disabling it removes built-in `gh` lookups and GitHub-specific commands/status/UI without deleting historical PR records. See [`docs/config.md`](docs/config.md) and [`docs/settings.md`](docs/settings.md). Workers may commit assigned work only under the user's repository identity; see [`docs/commit-authorship.md`](docs/commit-authorship.md) for the enforcement path and history audit. Branches, commits, and pull request metadata must describe only the product task; see [`docs/delivery-artifact-privacy.md`](docs/delivery-artifact-privacy.md).

The state file stores projects, issues, agents, questions, logs, counters, and harness session metadata. The kernel is the only layer that should mutate this orchestration state. Durable logs retain the newest 500 entries so lifecycle history cannot grow without bound. Independent events remain chronological, while explicitly identified evolving statuses—currently per-worker workspace-provisioning elapsed time and checkout percentage—replace only their own preceding entry so the dashboard shows one latest value. See [`docs/log-retention.md`](docs/log-retention.md) for replacement/retention semantics and the measured rationale, and [`docs/scalability.md`](docs/scalability.md) for the hermetic process-level responsiveness sweep.

The dashboard chat remains the primary workflow: describe new goals naturally and let head agents route the work. Double-click an issue to open its delivery PR when one is tracked; when one worker needs sustained direction, iterative plan discussion, research, investigation, or closer transparency, press `a` or double-click that worker to open its optional focused workspace. With a head row selected, the same `a` key instead opens that head's persisted harness session externally for debugging and leaves the dashboard in place; unavailable history is reported as a short-lived notice.

Focus continues that worker's existing context inside the logs pane while the AgentTree and external dashboard chat stay visible, live, and independently focusable. What focusing costs depends on the backend. On an interactive backend the worker's session is already a live process Meringue owns, so focusing attaches to it: a turn that is mid-flight keeps running, and leaving focus releases the view and nothing else. On a managed-transport backend, focusing must first settle an active turn before transferring sole session ownership; if focus closes before a newer final result, dashboard ownership and the prior logs view are restored and the saved assignment continues automatically rather than being marked as a worker error. The provider environment and `PATH` used to launch the harness are preserved either way, including package-manager and version-manager installations; `docs/config.md` covers explicit command and `PATH` configuration for restricted GUI/service environments.

Focused commands use a configurable leader so the agent's own key bindings and shell/editor bindings remain available: by default press `Ctrl-Space`, then `t` to switch views, `f` to cycle transcript filters, `a` to open the worker's saved session with the external launcher, `b` to launch the editor, `p` to open the verified delivery PR, or `q` to close focus and restore normal dashboard logs without stopping the worker or terminal. See `docs/keybindings.md` for the full interaction model.

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

Heads handle messages by answering directly when supplied context is sufficient, creating/reusing issues, prompting workers, running kernel-owned lookups/maintenance, or asking questions. They never perform substantive investigation themselves: if an explanation requires inspecting or synthesizing records, logs, prompts, dependencies, files, or external facts, an informational worker produces it. Every natural-language message still gets a fresh stateless head. Each head owns one tracked harness session for as long as it is alive, so its session id, session file, and pid are visible in state and reconcilable exactly like a worker's; the kernel closes that session and marks it terminal when the head's result is applied, when it errors, or when it is killed. Its routing context is assembled from existing issues, recent lifecycle logs, and generic harness/session metadata rather than a second conversation-state model.

For a follow-up, the head chooses among continuing a settled session (`normal`), correcting active work (`steer`), queuing a next step (`follow_up`), spawning a related worker on the same issue, or replacing an unhealthy/stale worker. The harness's persisted session retains the detailed conversation context. AgentTree worker rows label successors with `after W…` or `replaces W…`, while lifecycle logs state the full relationship. Workers carry out assigned implementation, investigation, or informational work, and only need PRs when the assigned delivery calls for repository changes. The kernel owns orchestration state. Harness-specific behavior stays behind the harness client layer.

## Contributing notes for agents

Before changing this repository, read `AGENTS.md`. It defines the mission, architecture boundaries, terminology, workflow, and non-negotiable test policy.

Important constraints:

- keep implementation slices small and aligned to the assigned issue;
- add or extend hermetic Minitest coverage for behavior changes and run it with `rake test`;
- use task-specific branches/worktrees for worker changes;
- commit only the assigned issue's changes;
- include manual verification steps in pull requests.
