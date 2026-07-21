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
- `river` / `river-agent`
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
3. The kernel validates those commands, creates or reuses issues, and spawns worker agents.
4. Each worker receives an assigned workspace and runs through the configured harness.
5. The TUI keeps the AgentTree, logs, questions, and delivery state visible so the developer can intervene only when needed.

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
fixtures/config.example.toml       # example local config
fixtures/demo_state.json           # demo state for the TUI
```

## Setup

Meringue is a Ruby application with a checked-in executable and a Bundler setup for local development.

Requirements:

- Ruby 3.1 or newer.
- Bundler, which is included with most Ruby installs.
- At least one supported harness CLI installed and authenticated when you want to spawn real agents. River users need the official `river-agent` launcher available on `PATH` (or configured by absolute command). You can use `demo` first without any harness.

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
bundle exec meringue tui --harness river
bundle exec meringue tui --harness claude
bundle exec meringue tui --head-harness river --worker-harness claude
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
- `/jump [agent_id]` — open a worker harness session; omit the id to navigate issues/workers and open PRs from jump mode.
- `/theme <name>` — persist a TUI colorscheme.
- `/harness <pi|river|claude|antigravity>` — select the harness for future agents.
- `/keybind` — show active TUI keybindings.

See `docs/keybindings.md` for keyboard navigation, customization, and jump-mode details.

## Configuration and state

Default paths:

```txt
~/.meringue/config.toml   # optional TOML config
~/.meringue/state.json    # persisted Meringue state
```

The config supports TUI colorschemes, TUI keybinding overrides, default harness selection, role-specific head/worker harnesses, and provider command overrides. See `docs/config.md` for the full reference.

The state file stores projects, issues, agents, questions, logs, counters, and harness session metadata. The kernel is the only layer that should mutate this orchestration state.

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

Heads orchestrate by creating/reusing issues, prompting workers, and asking questions; they do not deliver substantive task answers directly. Workers carry out assigned implementation, investigation, or informational work, and only need PRs when the assigned delivery calls for repository changes. The kernel owns orchestration state. Harness-specific behavior stays behind the harness client layer.

## Contributing notes for agents

Before changing this repository, read `AGENTS.md`. It defines the mission, architecture boundaries, terminology, workflow, and non-negotiable test policy.

Important constraints:

- keep implementation slices small and aligned to the assigned issue;
- do not add automated test files in this repository;
- use task-specific branches/worktrees for worker changes;
- commit only the assigned issue's changes;
- include manual verification steps in pull requests.
