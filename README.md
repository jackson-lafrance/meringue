# Meringue

Meringue is an open-source, terminal agent orchestrator for running many coding agents at once. It is designed to sit above the agent harnesses developers already like, so teams can coordinate work across any backend without rebuilding their workflow around one vendor.

The goal is simple: keep the developer in one place while many agents work in parallel. Meringue organizes that work as projects, issues, agents, questions, and logs, then routes each task to the configured harness behind a small integration layer.

## Quick start

> **Current distribution:** Meringue is not yet published to RubyGems or GitHub Releases. The supported installation is a source checkout.

### 1. Check the prerequisites

You need:

- Git;
- Ruby 3.1 or newer;
- Bundler (included with most Ruby installations);
- for real agent work, a supported harness CLI installed and authenticated. Meringue supports Claude Code (`claude`), Pi (`pi`), and Antigravity (`agy`), and does not assume one: pick a harness during first-run setup, in `/config`, or with `[harness] provider`. A harness is not needed for demo mode.

Confirm the required development tools are available:

```bash
git --version
ruby --version     # must report 3.1 or newer
bundle --version
```

### 2. Install and launch Meringue

```bash
git clone https://github.com/jackson-lafrance/meringue.git
cd meringue
bundle install
bundle exec meringue
```

The first interactive launch opens the guided Setup for head/worker harnesses, shared model/thinking defaults, theme, and Meringue Xtras. The **Split head and worker defaults** experiment is opt-in; enable it in `/config` when heads and workers should use different model/thinking values. To explore the interface without starting or authenticating a harness, run `bundle exec meringue demo` instead. See [first-run onboarding](docs/onboarding.md) and the [configuration reference](docs/config.md) for details.

### 3. Update it later

After exiting Meringue, update the source checkout and refresh its dependencies:

```bash
cd /path/to/meringue
git pull --ff-only
bundle install
```

Your config and state live under `~/.meringue/`, outside the checkout, so this does not replace them.

### Troubleshooting executable discovery

- **`meringue: command not found`:** the source install does not add a global command. Run `bundle exec meringue` from the checkout. If Bundler cannot discover the executable, `./bin/meringue --version` verifies the checked-in entrypoint directly.
- **`bundle: command not found`:** install Bundler for the Ruby you intend to use with `gem install --user-install bundler -v '~> 2.5'`. If RubyGems says its executable directory is not on `PATH`, add it for the current shell with `export PATH="$(ruby -r rubygems -e 'print Gem.user_dir')/bin:$PATH"`, then persist that line in your shell startup file.
- **A harness executable is missing:** check it with `command -v pi` (or `claude` / `agy`). Put the executable's directory on `PATH`, or set that provider's `command` to its absolute path as described in [harness configuration](docs/config.md#provider-sections).

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

- **Interactive** (Claude Code). Meringue starts the agent CLI once, in its own native interactive mode inside a PTY that Meringue owns for the life of the session. It types prompts in and reads the agent's own durable JSONL transcript back out for every state decision. Because that one process serves both the autonomous worker and the focused viewer, opening focus is an attach: no turn is interrupted, no process is replaced, and returning to the dashboard costs nothing.
- **Managed transport** (Pi). Meringue drives a long-lived RPC transport. Focusing a worker hands the session over to a native interactive process and back again, which means an active turn must be settled first.

Supported provider names in the current config surface include:

- `pi`
- `claude` / `claude_code` / `claude-code` / `cc`
- `antigravity`

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
4. Follow-up messages normally continue the best existing worker session so its persisted harness context remains available; the head can instead queue active work, spawn a related worker, or replace an unhealthy worker.
5. Each new worker receives an assigned workspace and runs through the configured harness.
6. The TUI keeps the AgentTree, logs, follow-up/replacement relationships, questions, and delivery state visible so the developer can intervene only when needed.

This repository also uses that workflow while developing Meringue itself, but self-hosting is a proof point rather than the product boundary. The product is a general open orchestration layer for any project and any supported harness.

## Repository layout

```txt
Gemfile                            # Bundler setup for running the executable from a clone
meringue.gemspec                   # local gem metadata that exposes the meringue executable
bin/meringue                       # executable CLI entrypoint
bin/meringue-record                # macOS proof-video helper
lib/meringue/cli.rb                # command parsing and runtime setup
lib/meringue/app.rb                # TUI application lifecycle
lib/meringue/kernel/               # command validation and state mutation
lib/meringue/heads/                # head-agent context, runners, and parsing
lib/meringue/harness/              # harness integrations and the shared transports
lib/meringue/tui/                  # terminal rendering, panes, navigation, styles
lib/meringue/state/                # JSON persistence models and store
lib/meringue/goals/                # goal-loop record, decisions, judge, and metric probe
docs/config.md                     # config and harness provider reference
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
docs/scalability.md                # hermetic process-level responsiveness sweep
docs/testing.md                    # test-suite guide and coverage boundaries
fixtures/config.example.toml       # example local config
fixtures/demo_state.json           # demo state for the TUI
test/integration/                  # hermetic component and area tests
test/e2e/                          # end-to-end flows across CLI/kernel/heads
test/support/                      # shared test helpers and fakes
```

## Usage

The [quick start](#quick-start) covers the normal interactive launch and the harness-free demo. `bundle exec meringue tui` is an explicit equivalent of `bundle exec meringue`.

The first interactive launch opens Setup, a centered first-run mode of the same schema-backed settings system used by `/config`. Choose a theme, review the head and worker harnesses plus shared model/thinking defaults, and opt into Meringue Xtras such as GitHub support. The **Split head and worker defaults** experiment is opt-in and can be enabled later in `/config` when role-specific model/thinking values are needed. Setup proceeds through **Welcome → Theme → Agent defaults → Meringue Xtras**; Back and Next stay inside the card, picker fields accept filtering, and Complete atomically saves the settings with the `[onboarding]` marker. Automatic first-run `Esc` confirms a safe skip; `Esc` on a manual `/setup` rerun cancels without changing the marker. The overlay remains recoverable through resize, validation, and persistence failures. See [`docs/onboarding.md`](docs/onboarding.md).

Print the CLI help:

```bash
bundle exec meringue --help
```

Choose a harness at runtime:

```bash
bundle exec meringue tui --harness claude
bundle exec meringue tui --harness claude
bundle exec meringue tui --head-harness antigravity --worker-harness claude
```

Use a custom state or config file:

```bash
bundle exec meringue tui --state /tmp/meringue-state.json
bundle exec meringue tui --config ./fixtures/config.example.toml
```

Export and import workers without opening the TUI:

```bash
bundle exec meringue workers export ./workers.json
bundle exec meringue workers import ./workers.json --project /path/to/the/checkout
```

See [`docs/worker-transfer.md`](docs/worker-transfer.md) for the portable format and its session limitations.

From the checkout, the checked-in `bin/meringue` entrypoint accepts the same commands when you need to bypass Bundler's executable lookup.

The commands below are available in the interactive TUI. IDs are case-insensitive: `/kill h83`, `/jump p1-i23-w1`, and `/answer q8 "…"` resolve to the same records as their uppercase forms, while Meringue keeps canonical IDs in state, logs, and output. Suggestions match what you type and complete to the canonical ID; unknown IDs are rejected. All other arguments remain case-sensitive, including paths, branch names, model references, and theme or harness names.

Most kernel-backed commands can also be requested in plain language. A head proposes the same command and the kernel produces the same result; it may answer directly when no command or substantive investigation is needed, while questions requiring investigation or synthesis go to an informational worker. Destructive actions such as `/clear` and killing a whole project still require an unambiguous request. `/jump`, `/prs`, `/setup`, `/keybind`, `/config`, and `/quit` are local TUI commands and must be typed. See [`docs/head_agent_kernel_commands.md`](docs/head_agent_kernel_commands.md) for the head command contract and safety rules.

Useful slash commands inside the TUI include:

- `/help` — show command syntax.
- `/project add <path> [name]` — register a project.
- `/project rename <project_id> "<name>"` — rename a project.
- `/issue create <project_id> "<title>" ["description"]` — create an issue manually.
- `/issue rename <issue_id> "<title>"` — rename an issue. For both rename commands, focus the AgentTree, select a row, and press `r` to prefill the one that matches the selected row (a worker resolves to its issue).
- `/worker spawn <issue_id> "<prompt>"` — spawn a worker for an issue.
- `/worker pause <agent_id>` — stop the current worker turn without killing its resumable session.
- `/worker resume <agent_id>` — continue a paused worker from the same session and workspace.
- `/worker export <bundle_path> [agent_id...]` — export current worker context for retry on another computer; paths, session handles, and credentials are not copied.
- `/worker import <bundle_path> --project <path>` — recreate the project/issue context and start fresh destination sessions; source harness sessions cannot be resumed directly.
- `/prompt <agent_id> "<message>"` — follow up with an existing worker, or take over a still-routing head. Use `/retry <head_id>` for a stopped head.
- `/jump [agent_id]` — open an agent's focused workspace; omit the ID to navigate issues and workers and open PRs from jump mode. The focused workspace shows a running agent's effective model and thinking level and offers `/open-session` to open its harness UI; there is no slash command for reading an existing session's settings.
- `/prs` — with **Settings → Experiments → GitHub support** enabled, open the picker for every tracked pull request that is still open. Use `↑`/`↓` to move, `Enter` to open, and `Esc` to close.
- `/setup` — reopen the shared Setup flow for theme, head/worker harnesses, shared model/thinking defaults, and **Meringue Xtras**. Manual cancel writes nothing; the Split head and worker defaults experiment reveals role-specific model/thinking choices when enabled.
- `/questions` — list questions and their statuses.
- `/answer <question_id> "<answer>"` — answer an open question; the kernel records the answer and routes the work it unblocks. See [Answering a head's question](#answering-a-heads-question).
- `/dismiss <question_id>` — close an open question without answering it.
- `/theme [name]` — with no name, open the on-screen theme picker; otherwise persist a TUI colorscheme. The `/themes` alias opens the same picker. The picker previews the highlighted theme; Escape or clicking away restores the original, while Enter persists the selection through the normal command path.
- `/config` — open the full-screen transactional Settings editor for themes, shared agent defaults (or role-specific model/thinking defaults when `split_agent_defaults` is enabled), experiments, harnesses, workspaces, safety, and every keybinding. Use `/config --text` for the read-only diagnostic listing.
- `/harness [head|worker] <pi|claude|antigravity>` — with no arguments, open the on-screen harness picker; otherwise select the harness for future agents; omit the role to update both.
- `/models [harness] [refresh]` — open a searchable picker from the selected harness's own model catalog, including each model's provider/ID, name, and supported thinking levels. With `split_agent_defaults` enabled, it shows Head and Worker tabs; `←`/`→` switches roles, `↑`/`↓` moves, `Enter` applies the selected role's future-session default, `Ctrl-R` re-fetches the catalog, and `Esc` closes. With the experiment disabled (the default), there are no role tabs and the selection updates the shared default for both roles. Add `refresh` to re-fetch the catalog without opening the picker. See [`docs/session-settings.md#authoritative-model-catalog-discovery`](docs/session-settings.md#authoritative-model-catalog-discovery).
- `/model [head|worker] <provider>/<model-id>` — with no arguments, open the same model picker as `/models`. With the Split head and worker defaults experiment disabled (the default), `/model <provider>/<model-id>` updates the shared model for both future heads and workers; role-scoped forms are rejected. When the experiment is enabled, use `/model head <provider>/<model-id>` or `/model worker <provider>/<model-id>` to update one role; the unscoped form is rejected. Existing sessions are unchanged. The reference is split on the first slash, so the model id may itself contain `/` and `:` (`/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`). An ID the catalog does not list is still saved and reported as unverified. Active defaults remain visible in the dashboard status line and `/config`; see [`docs/session-settings.md`](docs/session-settings.md).
- `/thinking [head|worker] <off|minimal|low|medium|high|xhigh|max>` — with no arguments, open the thinking-level picker. With Split head and worker defaults disabled (the default), `/thinking <level>` updates both future roles and role-scoped forms are rejected. When the experiment is enabled, use `/thinking head <level>` or `/thinking worker <level>` and the picker exposes role tabs; the unscoped form is rejected. Existing sessions are unchanged. The picker offers all seven levels, putting the saved default first and labelling the others with what the configured model advertises. See [`docs/session-settings.md#thinking-levels`](docs/session-settings.md#thinking-levels).
- `/keybind` — show active TUI keybindings. See [`docs/keybindings.md`](docs/keybindings.md).
- `/prune` — one cleanup pass that removes resolved (completed/killed) and errored records together and removes their clean, unlocked Meringue-managed worktrees. Unsafe cleanup (dirty, locked, ambiguous, or failed) retains the bundle and logs why it can be retried. A worktree shared by several workers is removed once the last of them is pruned. See [`docs/head_agent_kernel_commands.md`](docs/head_agent_kernel_commands.md) for cleanup safety.
- `/recount` — compact project, issue, worker, question, and goal numbering after records are removed, updating live cross-references safely. See [`docs/recount.md`](docs/recount.md).
- `/goal create "<prompt>" --metric "<command>" --target <n> [--project <project_id>] [flags]` — start a goal loop from a prompt. Meringue creates the issue for it (title from the prompt's first sentence, prompt kept verbatim in the description) and keeps producing attempts until the metric it measures itself reaches the target, or an iteration/session/wall-clock budget, a no-progress guard, an oscillation guard, or a broken metric stops it. Add `--guardrail "rake test"` for anything that must not regress. `--project` picks the project when several are registered; otherwise Meringue uses the one containing your working directory, or the only one registered, and refuses to guess. See [`docs/goal_loops.md`](docs/goal_loops.md).
- `/goal create <issue_id> "<success criteria>" --metric "<command>" --target <n> [flags]` — the same loop attached to an issue that already exists. An id-shaped first token is always read as an id, so a mistyped id is reported instead of quietly becoming a new issue title.
- `/goal status [goal_id]` — show goal loops, iteration accounting, metric progress, verdicts, and stop reasons.
- `/goal pause <goal_id>` / `/goal resume <goal_id>` — stop and restart spawning without ending the loop; the in-flight attempt is untouched.
- `/goal stop <goal_id>` — end the loop for good and keep its current attempt session. `/kill <goal_id>` also stops that session.

There is no command for one existing session's settings: `/model` and `/thinking` only move future-session defaults. The dashboard shows one shared model/thinking pair by default, or separate head and worker values when `split_agent_defaults` is enabled; the effective model and thinking level of a running agent are shown on the `session settings` line of its focused workspace (`/jump <agent_id>`). Focused workspaces advertise `/open-session` for opening the harness UI.

`/model` and `/thinking` complete from the selected harness's own model catalog, so the picker lists every available model rather than only the ones Meringue has seen. `/thinking` always offers all seven levels — the saved default first, the rest labelled with what the configured model advertises — because the catalog explains a level rather than deciding whether you may pick it. See [`docs/session-settings.md#authoritative-model-catalog-discovery`](docs/session-settings.md#authoritative-model-catalog-discovery) for discovery, caching, and unavailable-catalog behavior, and [`docs/session-settings.md#thinking-levels`](docs/session-settings.md#thinking-levels) for the level ladder, labels, and clamping.

See [`docs/head_agent_kernel_commands.md`](docs/head_agent_kernel_commands.md) for the head command contract, destructive-command rules, prune eligibility, and worktree cleanup safety. See [`docs/goal_loops.md`](docs/goal_loops.md) for how goal loops measure progress, judge each iteration, and stop. See [`docs/recount.md`](docs/recount.md) for the renumbering/cross-reference/active-session rules, and [`docs/keybindings.md`](docs/keybindings.md) for keyboard navigation, customization, and jump-mode details.

### Answering a head's question

When a head cannot route a request safely it asks a clarifying question, and the chat shows `Question Q1: …` with the reason and the ways to answer it. Answering is a real routing action, not just bookkeeping:

- `/answer Q1 "<answer>"` records the answer, closes the question, and spawns a fresh head that receives the question text, the question context, the project/issue scope, the message that originally triggered the question, and your answer. That head reuses the question's issue and prompts the worker already working on it whenever that is the right move.
- Replying in plain chat also works. A head reads the open questions in its context; if your message clearly answers exactly one of them, it closes that question and routes the unblocked work in the same step. If several questions could match, or the message is a new goal, the questions stay open and the message is routed as its own request.
- `/dismiss Q1` closes a question you no longer care about without routing any work.

Open questions are visible as a `? <count>` marker in the chat header and through `/questions`, which also prints the exact `/answer` command to use.

### Reading the logs pane

Log rows use compact, color-coded headers so agent output is easy to separate from kernel and command logs:

- `◆ H1` — head-agent progress, bold, in a color derived from its id.
- `✦ P1-I1-W1` — worker progress in that worker's stable color. Click the worker id, its title, or nonblank authored body text to select that worker in the AgentTree and filter the pane to it.
- `✓ P1-I1-W1 · done` — a completed worker result.
- `! P1-I1-W1 · warn/err` — an actionable warning or error.
- `▪ meringue` — kernel and system logs, in the theme accent color. When a head proposed the kernel command, the header reads `▪ meringue · via H127`: Meringue still applied it, and `H127` identifies where it originated.
- `● you` — your own prompts.

### Identifying agents at a glance

Every agent row in the AgentTree reads as `<status> <harness logo> <id>  <title>`:

```txt
HEADS
  └─ ● π H1  Route the request

●   P1  meringue
  └─ ●   I1  Fix signup validation 1/3
    ├─ ● π W1  Add collision check
    ├─ ✓ ✳ W2  Hide password field
    └─ · ↑ W3  Check the migration
```

- **Identity colors:** Each agent's ID and harness logo use a deterministic per-ID color shared by its log header and `▌` gutter; the selected composer uses the same identity color.
- **Status:** Color persists across working, completed, idle, queued, blocked, errored, and killed states. Status glyphs keep their semantic colors, and completed titles are muted.
- **Project rows:** Show only the product name (`meringue`, not `meringue working`); the status glyph supplies lifecycle state. The kernel strips trailing status words and repairs older project names.
- **Harness logos:** `π` is Pi, `✳` is Claude Code, and `↑` is Antigravity. An unsupported harness gets a plain ASCII initial; a record without a harness gets `?`. Every mark is one column wide.
- **Alignment and fallbacks:** Issue and project rows reserve the logo cell so IDs align. Set `MERINGUE_ASCII_GLYPHS=1` for `p`/`c`/`a` when the marks are unavailable; `NO_COLOR=1` keeps glyphs, IDs, statuses, and titles while removing color.
- **Selection and filtering:**
  - Single-click a project, issue, head, or worker to filter logs. Workers show their own logs, issues include their workers and child issues, and projects include their whole subtree.
  - Right-click or double-click an issue to open its delivery PR; worker rows do not duplicate that affordance. A missing PR shows a transient notice without changing the selection.
  - Double-click a worker to open its focused workspace when one exists. Pending heads or issues without a focused workspace are silent no-ops; actual open failures are reported.
  - Issue and worker selections scope later natural-language chat. An issue is the target; a worker resolves to its issue and remains a context hint. Selected prompts retain their issue and worker tags in filtered logs.
  - Head rows are log-only. A stopped head (`errored`, `killed`, or `blocked` after a rejected or failed batch) shows `retry me` and can be retried with `/retry H<n>` or by double-clicking it. A retry reuses accepted commands and records, then removes the old row once the fresh head starts.
  - Selecting a different row changes the filter. Project selections and still-routing heads remain log-only, while clearing the selection returns chat to unscoped routing. See [`docs/keybindings.md`](docs/keybindings.md#agenttree-selection-log-filtering-and-chat-routing).
- **Chat target:** The composer title is the only target label (`chat → P1-I1-W1 · Fix signup validation`). No selection reads plain `chat`; an issue or worker selection tints the border, title, and `›` marker with that node's identity color, while projects and heads show `<id> logs only`. Slash commands never inherit selection: typing one drops the tint and shows `slash ignores target · Esc clears`. Every natural-language message still starts a fresh head.
- **Bottom hint and pull requests:** The hint line prioritizes selection state, `Esc clears`, `● 2W 1H` work counts, questions, and delivery PRs; it omits ordinary send mechanics and the full keybinding list. Its `Ctrl-C clear/quit · Tab focus · / commands` discovery line appears only when the dashboard is idle. A selected worker shows the PR for *its own* delivery branch (`PR #145 open`) or `no PR yet`; `Ctrl-B` opens it. `check stale` describes forge-check freshness, not PR lifecycle. Unscoped chat shows `3 open PRs`; double-click it, press `Ctrl-B`, or run `/prs` for the all-open picker (number, title, issue), even with a tree selection. `↑`/`↓` navigate, `Enter` opens, and `Esc` or clicking away closes it. See [`docs/keybindings.md`](docs/keybindings.md#what-the-bottom-hint-line-shows).
- **Persistent selection and log clicks:** The selected row and filter remain active while focus moves to logs or chat. A worker's border shows lifecycle, effective model, thinking level, and context as `used/capacity (percent)`; unavailable telemetry says `unavailable`, and estimates use `~`. The header adds a turn count when it fits, while issue/project filters use `logs — <selected_id>`. Click a worker ID, title, or nonblank authored message to select it without moving log focus or scroll position. Timestamps, icons, gutters, separators, status rows, whitespace, heads, and kernel/user rows are not targets; removed workers are inert, and text selection wins over activation. Click the selected row again, empty AgentTree space, or press `Esc` to clear it.
- **Rendered agent output:** The header owns the agent ID and title; bodies do not repeat an `<id> output:` label. Agent lines use a colored `▌` gutter, while kernel and user lines use plain indentation. Head and worker output supports terminal-wrapped Markdown (headings, emphasis, lists, blockquotes, code, and links); kernel, command, warning, and error rows retain their semantic presentation.
- **Output safety:** ANSI/control sequences, pasted terminal boxes, duplicate headers or PR URLs, excess whitespace, and other unsafe formatting are removed at render time without changing stored text. Styles come from Canvas metadata, and `/theme <name>` restyles Markdown markers, gutters, and headers through the identity palette. See [`docs/agent-output.md`](docs/agent-output.md) for the rendering path, Markdown behavior, safety constraints, and examples.

## Configuration and state

Default paths:

```txt
~/.meringue/config.toml   # optional TOML config
~/.meringue/state.json    # persisted Meringue state
```

The config supports TUI colorschemes, animations, every TUI keybinding, separate head/worker harnesses, shared model/thinking defaults (or role-specific values when the Split head and worker defaults experiment is enabled), provider commands/environment/arguments, workspace and launcher bounds, safety policy, experiments, and the first-run setup marker. `/config` edits these through one schema-backed atomic transaction. For a file-based starting point, copy [`fixtures/config.example.toml`](fixtures/config.example.toml) to `~/.meringue/config.toml`; keep API keys out of this file and use each harness's normal authentication or environment variables. GitHub support is an opt-in experiment for new installations; disabling it removes built-in `gh` lookups and GitHub-specific commands/status/UI without deleting historical PR records. See [`docs/config.md`](docs/config.md) and [`docs/settings.md`](docs/settings.md). Workers may commit assigned work only under the user's repository identity; see [`docs/commit-authorship.md`](docs/commit-authorship.md) for the enforcement path and history audit. Branches, commits, and pull request metadata must describe only the product task; see [`docs/delivery-artifact-privacy.md`](docs/delivery-artifact-privacy.md).

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
