# Meringue

Meringue is a terminal-first control plane for coordinating many coding agents from one place. It sits above the coding-agent harnesses developers already use, organizes work into projects/issues/agents/questions/logs, and lets the kernel route each task to the configured backend while the TUI keeps progress visible.

The project is intentionally harness-agnostic: Pi is the default MVP backend, but provider-specific behavior lives behind harness clients so Meringue can grow without rewriting the kernel or TUI.

## What Meringue does

- **One chat stream for parallel work.** Natural-language prompts spawn short-lived head agents that inspect context and propose structured kernel commands.
- **Kernel-owned orchestration.** The kernel validates commands, mutates JSON state, allocates worker workspaces, starts harness sessions, and records durable logs.
- **AgentTree visibility.** Projects, issues, heads, workers, questions, statuses, and PR markers are rendered in a filesystem-like terminal view.
- **Safe worker isolation.** Git-backed projects prefer one Meringue-owned worktree/branch per worker so multiple agents can edit safely.
- **Jump-in controls.** `/jump` opens a worker harness session, and `/jumpr` opens a worker pull request when Meringue has verified one.

A typical flow:

```txt
User prompt
  -> fresh head agent proposes KernelCommand[]
  -> kernel validates commands and updates JSON state
  -> kernel allocates a worker workspace and starts a harness session
  -> worker edits in its assigned workspace
  -> AgentTree, logs, questions, and PR state rerender in the TUI
```

## Harnesses

Meringue's current selectable harness providers are defined by the registry and config docs:

- `pi`
- `claude` / `claude_code` / `claude-code` / `cc` for Claude Code
- `antigravity` for the Antigravity CLI (`agy`)

Choose a provider with config, CLI flags, environment variables, or the TUI slash command:

```bash
bin/meringue tui --harness claude
bin/meringue tui --head-harness antigravity --worker-harness pi
MERINGUE_HARNESS=pi bin/meringue tui
```

```txt
/harness <pi|claude|antigravity>
```

## Repository layout

```txt
bin/meringue                       # executable CLI entrypoint
lib/meringue/cli.rb                # CLI commands and runtime setup
lib/meringue/app.rb                # TUI lifecycle wrapper
lib/meringue/kernel/               # command validation and state mutation
lib/meringue/heads/                # head-agent context, runners, and result parsing
lib/meringue/harness/              # Pi, Claude Code, Antigravity, and generic process clients
lib/meringue/tui/                  # terminal rendering, panes, navigation, styles
lib/meringue/state/                # JSON persistence models and store
lib/meringue/workspace/            # worker workspace/worktree allocation
docs/config.md                     # config and harness provider reference
docs/head_agent_kernel_commands.md # compact command contract for head agents
docs/keybindings.md                # TUI controls and jump-mode reference
fixtures/config.example.toml       # example local config
fixtures/demo_state.json           # demo state for the TUI
```

## Setup

Meringue is a Ruby application. The checked-in code does not require a package install step.

```bash
git clone https://github.com/jackson-lafrance/meringue.git
cd meringue
bin/meringue --help
```

Optional local config lives at `~/.meringue/config.toml`:

```bash
mkdir -p ~/.meringue
cp fixtures/config.example.toml ~/.meringue/config.toml
```

Do not store API keys or secrets in this file. Use each harness CLI's normal auth flow or environment variables.

## Usage

```bash
bin/meringue                    # open the interactive TUI
bin/meringue tui                # same as above
bin/meringue demo               # open the fake demo state without spawning agents
bin/meringue demo-state         # print the demo JSON
bin/meringue reset-state        # clear ~/.meringue/state.json
bin/meringue --help             # print CLI help
```

Useful slash commands inside the TUI:

- `/help` — show command syntax.
- `/project add <path> [name]` — register a project.
- `/issue create <project_id> "<title>" ["description"]` — create an issue manually.
- `/worker spawn <issue_id> "<prompt>"` — spawn a worker for an issue.
- `/prompt <agent_id> "<message>"` — follow up with an existing worker session.
- `/jump [agent_id]` — open a worker harness session.
- `/jumpr [agent_id]` — open a worker pull request when available.
- `/theme <name>` — persist a TUI colorscheme.
- `/harness <pi|claude|antigravity>` — select the harness for future agents.
- `/keybind` — show keyboard controls.

## Configuration and state

Default paths:

```txt
~/.meringue/config.toml   # optional TOML config
~/.meringue/state.json    # persisted Meringue state
```

The config supports TUI colorschemes, default/role-specific harness selection, provider command overrides, and provider extra args. See `docs/config.md` for details.

The state file stores projects, issues, agents, questions, logs, counters, and harness session metadata. The kernel is the only layer that should mutate this orchestration state.

## Contributing notes for agents

Before changing this repository, read `AGENTS.md`. It defines the mission, architecture boundaries, terminology, worker workflow, and repository-specific test policy.
