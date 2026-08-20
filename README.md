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
- for real agent work, a supported harness CLI installed and authenticated. Meringue defaults to Pi (`pi`) and also recognizes Claude Code (`claude`) and Antigravity (`agy`). A harness is not needed for demo mode.

Confirm the required development tools are available:

```bash
git --version
ruby --version     # must report 3.1 or newer
bundle --version
```

### 2. Install and verify Meringue

```bash
git clone https://github.com/jackson-lafrance/meringue.git
cd meringue
bundle install
bundle exec meringue --version
```

The last command prints the installed checkout's Meringue version and confirms that Bundler can find its packaged `meringue` executable.

### 3. Launch it

```bash
bundle exec meringue
```

The first interactive launch opens the guided setup for harness, model, thinking, theme, and optional experiments. To explore the interface without starting or authenticating a harness, run `bundle exec meringue demo` instead. See [first-run onboarding](docs/onboarding.md) and the [configuration reference](docs/config.md) for details.

### 4. Update it later

There is no in-app updater yet. After exiting Meringue, update the same checkout and refresh its dependencies:

```bash
cd /path/to/meringue
git pull --ff-only
bundle install
bundle exec meringue --version
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
lib/meringue/harness/              # Pi and other harness integrations
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

The first interactive launch opens Setup as the same polished full-screen overlay used by `/config`. Review separate head and worker harness/model/thinking defaults, preview a theme, and opt into experiments such as GitHub support, then confirm the complete draft on one Review screen. Back never loses edits and nothing is written until Finish atomically saves the settings and `[onboarding]` marker together. Automatic first-run `Esc` confirms a safe skip; `Esc` on a manual `/setup` rerun cancels without changing the marker. The overlay remains recoverable through resize, validation, and persistence failures. See [`docs/onboarding.md`](docs/onboarding.md).

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

From the checkout, the checked-in `bin/meringue` entrypoint accepts the same commands when you need to bypass Bundler's executable lookup.

Useful slash commands inside the TUI include:

- `/help` — show command syntax.
- `/project add <path> [name]` — register a project.
- `/project rename <project_id> "<name>"` — rename a project.
- `/issue create <project_id> "<title>" ["description"]` — create an issue manually.
- `/issue rename <issue_id> "<title>"` — rename an issue. For both rename commands, focus the AgentTree, select a row, and press `r` to prefill the one that matches the selected row (a worker resolves to its issue).
- `/worker spawn <issue_id> "<prompt>"` — spawn a worker for an issue.
- `/worker pause <agent_id>` — stop the current worker turn without killing its resumable session.
- `/worker resume <agent_id>` — continue a paused worker from the same session and workspace.
- `/prompt <agent_id> "<message>"` — follow up with an existing worker, or take over a still-routing head; use `/retry <head_id>` for a stopped head.
- `/jump [agent_id]` — open an agent's focused workspace; omit the id to navigate issues/workers and open PRs from jump mode.
- `/prs` — with **Settings → Experiments → GitHub support** enabled, open the picker for every tracked pull request that is still open. Use `↑`/`↓` to move, `Enter` to open, and `Esc` to close.
- `/setup` — reopen the shared full-screen Setup overlay for theme, separate head/worker defaults, and experiment checkboxes. Manual cancel writes nothing.
- `/questions` — list questions and their statuses.
- `/answer <question_id> "<answer>"` — answer an open question; the kernel records the answer and routes the work it unblocks.
- `/dismiss <question_id>` — close an open question without answering it.
- `/theme <name>` — persist a TUI colorscheme.
- `/config` — open the full-screen transactional Settings editor for themes, separate head/worker defaults, experiments, harnesses, workspaces, safety, and every keybinding. Use `/config --text` for the old read-only diagnostic listing.
- `/harness [head|worker] <pi|claude|antigravity>` — select the harness for future agents; omit the role to update both.
- `/models [harness]` — open the model picker: a searchable list of the models the selected harness reports, with each model's provider/id, name, and supported thinking levels. Type to filter, `↑`/`↓` to move, `Enter` applies the model as the future-session default (exactly like `/model <reference>`), `Ctrl-R` re-asks the harness, `Esc` closes. `/models refresh [harness]` skips the picker and just re-fetches the catalog.
- `/model [head|worker] <provider>/<model-id>` — with no arguments, open the same picker as `/models`; with a model reference, persist the model for all future Pi sessions. Omit the role to update both (the backward-compatible form), or name `head`/`worker` to update only that role. Existing sessions are unchanged. The reference is split on the first slash, so the model id may itself contain `/` and `:` (`/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`). An id the model catalog does not list is still set, and reported as unverified. The values in force are always visible in the dashboard status line (`harness: Pi · model: <model> · thinking: <level>` when both roles match, or a compact head/worker form when they differ) and in `/config`.
- `/thinking [head|worker] <off|minimal|low|medium|high|xhigh|max>` — persist a thinking level for future Pi sessions. Omit the role to update both (the backward-compatible form), or name `head`/`worker` to update only that role; existing sessions are unchanged.
- `/keybind` — show active TUI keybindings.
- `/prune` — one cleanup pass that removes resolved (completed/killed) and errored records together and removes their clean, unlocked Meringue-managed worktrees. Unsafe cleanup (dirty, locked, ambiguous, or failed) retains the bundle and logs why so it can be retried. A worktree shared by several workers is removed once the last of them is pruned.
- `/recount` — compact project, issue, worker, question, and goal numbering after records are removed.
- `/goal create "<prompt>" --metric "<command>" --target <n> [--project <project_id>] [flags]` — start a goal loop from a prompt. Meringue creates the issue for it (title from the prompt's first sentence, prompt kept verbatim in the description) and keeps producing attempts until the metric it measures itself reaches the target, or an iteration/session/wall-clock budget, a no-progress guard, an oscillation guard, or a broken metric stops it. Add `--guardrail "rake test"` for anything that must not regress. `--project` picks the project when several are registered; otherwise Meringue uses the one containing your working directory, or the only one registered, and refuses to guess.
- `/goal create <issue_id> "<success criteria>" --metric "<command>" --target <n> [flags]` — the same loop attached to an issue that already exists. An id-shaped first token is always read as an id, so a mistyped id is reported instead of quietly becoming a new issue title.
- `/goal status [goal_id]` — show goal loops, iteration accounting, metric progress, verdicts, and stop reasons.
- `/goal pause <goal_id>` / `/goal resume <goal_id>` — stop and restart spawning without ending the loop; the in-flight attempt is untouched.
- `/goal stop <goal_id>` — end the loop for good and keep its current attempt session. `/kill <goal_id>` also stops that session.

Ids are not case sensitive. `/kill h83`, `/kill H83`, `/jump p1-i23-w1`, and `/answer q8 "…"` all
reach the same record, and Meringue keeps the canonical uppercase id (`H83`, `P1-I23-W1`, `Q8`) in
state, logs, and command output. Id suggestions match what you typed in any case and complete to
the canonical id. An id that does not exist is still rejected, and the message shows exactly what
you typed. Everything else stays case sensitive, including paths, branch names, model references,
and theme/harness names.

You do not have to type them. Head agents can run the same commands from plain language, so "prune the merged issues", "renumber the tree", "kill P1-I9-W3", or "what is P1-I12" apply the matching kernel command and print the same output as the typed slash command. A head can also answer directly in plain user-visible text when no command or substantive investigation is needed; that response is a complete result and does not need a dummy `NoOp`. Questions that require causal investigation or synthesis are routed to an informational worker instead of being answered with raw record output. Irreversible commands are gated: `/clear` and killing a whole project are only run when your own message unambiguously asks for them, and otherwise the head asks you to confirm. `/jump`, `/prs`, `/setup`, `/keybind`, and `/quit` are local TUI commands and stay typed-only.

There is no command for one existing session's settings: `/model` and `/thinking` only move future-session defaults. The dashboard shows the separate head and worker model and thinking defaults, while the effective model and thinking level of a running agent are shown on the `session settings` line of its focused workspace (`/jump <agent_id>`). Focused workspaces advertise `/open-session` for opening the harness UI.

`/model` and `/thinking` complete from the selected harness's own model catalog, so the selector lists every available model rather than only the ones Meringue has seen. `/thinking` always offers all seven levels — the saved default first, the rest labelled with what the configured model advertises — because the catalog explains a level rather than deciding whether you may pick it. See `docs/session-settings.md#authoritative-model-catalog-discovery` for discovery, caching, and unavailable-catalog behavior, and `docs/session-settings.md#thinking-levels` for the level ladder, labels, and clamping.

See `docs/head_agent_kernel_commands.md` for the head command contract, destructive-command rules, prune eligibility, and worktree cleanup safety. See `docs/goal_loops.md` for how goal loops measure progress, judge each iteration, and stop. See `docs/recount.md` for the renumbering/cross-reference/active-session rules, and `docs/keybindings.md` for keyboard navigation, customization, and jump-mode details.

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

- The id and logo are drawn in that agent's **identity color** — the same deterministic per-id color its log rows and `▌` gutter already use, and the same color the chat composer takes when the row is selected. One agent is one color in all three places.
- Color is additive and status-independent: a working agent, a completed agent with its `✓`, and idle/queued/blocked/errored/killed agents all keep their color and logo. Status stays legible through the status glyph's own semantic color and the muted title of a completed row.
- A project row is only its product name (`meringue`, not `meringue working`). Lifecycle status is carried by the status glyph on every row, so it is never spelled out beside a name; the kernel strips a trailing status word from any project name it stores and repairs one that an older state file already contains.
- The logo is the agent's harness: `π` Pi, `✳` Claude Code, `↑` Antigravity. A harness Meringue does not ship shows a plain ASCII initial, and a record with no harness shows `?`. Every variant is exactly one column wide, and issue/project rows reserve the same cell so all ids stay in one column. Set `MERINGUE_ASCII_GLYPHS=1` for `p`/`c`/`a` if your font cannot draw the marks, or `NO_COLOR=1` to drop color while keeping glyphs, ids, and statuses.

Single-click a project, issue, head, or worker row in the AgentTree to filter the logs pane to that node: a worker shows its own logs, an issue adds its workers and child issues, and a project covers its whole subtree. Right-click an issue row to open its associated delivery PR; worker rows do not duplicate that PR affordance. If no PR is tracked, Meringue shows a transient notice and leaves the current selection unchanged. Issue and worker selections also focus subsequent natural-language chat: an issue targets itself, while a worker resolves to its owning issue and remains a preferred session-context hint. Head rows are log-only: a stranded head (`errored`, `killed`, or `blocked` because the kernel rejected or failed part of its batch) is marked `retry me` and can be retried deliberately with `/retry H<n>` or by double-clicking that row. A partially applied head is retried without re-routing what already landed — the retry head is handed the commands that were accepted and told to reuse those records — and the old head row is removed from the active tree once the fresh retry head starts. Selected prompts are tagged to the issue (and the selected worker when applicable), so they remain visible in the focused logs.

The chat box shows where your next message goes. While an issue or worker is selected, the composer border, title, and `›` prompt marker are tinted with that node's own identity color — the same color the logs pane uses for its rows — and the title above the chat bar reads `chat → P1-I1-W1 · Fix signup validation`. Untargeted states are deliberately plain: no selection reads `chat`, a project or any head reads `chat · <id> logs only`, and typing a slash command drops the tint (`chat · slash command · P1-I1-W1 not targeted`) because slash commands never inherit the selection. The target is named there and nowhere else: a selected target contributes only `Esc clears`, a selected target with a slash command says `slash ignores target · Esc clears`, and an unselected composer stays quiet while its popup explains slash commands. Every message still spawns a fresh head rather than prompting the worker directly. Colors are never the only cue, so the target stays readable with `NO_COLOR=1`.

The line under the chat bar prioritizes changing state and genuinely contextual actions: text-selection state, `Esc clears` for a target, `● 2W 1H` work counts, open questions, and delivery PRs. It shows the small `Ctrl-C clear/quit · Tab focus · / commands` discovery line only when the dashboard is otherwise idle; it never repeats ordinary Enter/send mechanics or the full keybinding list. Delivery PRs follow the selection: a selected worker shows the PR for *its own* delivery branch (`PR #145 open`) or `no PR yet`, and `Ctrl-B` opens it. A `check stale` suffix describes freshness of the last forge status check, not a PR lifecycle state, so a merged PR is never presented as a stale lifecycle. Unscoped chat is not about one worker, so it shows `3 open PRs` instead of pinning an arbitrary number; double-click that count, press `Ctrl-B`, or run `/prs` to open the same picker of every open PR (number, title, issue). `↑`/`↓` navigate, `Enter` opens, and `Esc` or a click outside closes. `/prs` also opens the all-open-PR picker while a tree row is selected. See [`docs/keybindings.md`](docs/keybindings.md#what-the-bottom-hint-line-shows).

The selected row stays highlighted and the filter keeps applying while you move focus to the logs or chat pane. A selected worker's border identifies the worker's lifecycle state, effective model, thinking level, and context as `used/capacity (percent)`; unavailable telemetry is labelled unavailable and estimated context is marked with `~`. The header adds a turn count only when it fits. Issue and project filters keep the shorter `logs — <selected_id>` title. Click another row to change the target. You can also click a worker's id, title, or nonblank authored message in the logs pane; this keeps the logs focus and scroll position while selecting that worker. Timestamps, icons, gutters, separators, status rows, trailing whitespace, heads, and kernel/user rows are not targets, removed workers are inert, and drag/double-/triple-click text selection wins over activation. Click the highlighted row again, click empty AgentTree space, or press `Esc` to clear it and return chat to unscoped routing. Project selections and heads that are still routing are log-only filters. Pending heads or issues with no focused worker workspace are a silent no-op when double-clicked, so expected unavailability never floods or persists in chat; actual workspace/open failures are still reported. See [`docs/keybindings.md`](docs/keybindings.md#agenttree-selection-log-filtering-and-chat-routing) for the exact scoping and routing rules.

The header owns the agent id and title; the body does not repeat an `<id> output:` label. Agent body lines use a colored `▌` gutter, while kernel and user lines keep a plain indent. Conversational head and worker output renders common Markdown—headings, emphasis, ordered/unordered/task lists, blockquotes, inline and fenced code, and links—with terminal-aware wrapping. Kernel/command rows and warnings/errors retain their semantic log presentation instead of being interpreted as chat Markdown.

ANSI sequences, control characters, common pasted terminal boxes, duplicate transcript headers, excess whitespace, and duplicate PR URLs are removed at render time without changing the original text stored in state. Styles are emitted as Canvas metadata rather than accepted from agent text. Agent colors come from the active colorscheme's deterministic identity palette, so `/theme <name>` restyles Markdown markers, gutters, and headers together. Set `NO_COLOR=1` to disable color; icons, ids, status text, gutters, Markdown block markers, and visible link targets keep the output usable.

See [`docs/agent-output.md`](docs/agent-output.md) for the Pi RPC-to-TUI rendering path, Markdown behavior, safety constraints, and before/after examples.

## Configuration and state

Default paths:

```txt
~/.meringue/config.toml   # optional TOML config
~/.meringue/state.json    # persisted Meringue state
```

The config supports TUI colorschemes, animations, every TUI keybinding, separate head/worker harness/model/thinking defaults, provider commands/environment/arguments, workspace and launcher bounds, safety policy, experiments, and the first-run setup marker. `/config` edits these through one schema-backed atomic transaction. For a file-based starting point, copy [`fixtures/config.example.toml`](fixtures/config.example.toml) to `~/.meringue/config.toml`; keep API keys out of this file and use each harness's normal authentication or environment variables. GitHub support is an opt-in experiment for new installations; disabling it removes built-in `gh` lookups and GitHub-specific commands/status/UI without deleting historical PR records. See [`docs/config.md`](docs/config.md) and [`docs/settings.md`](docs/settings.md). Workers may commit assigned work only under the user's repository identity; see [`docs/commit-authorship.md`](docs/commit-authorship.md) for the enforcement path and history audit. Branches, commits, and pull request metadata must describe only the product task; see [`docs/delivery-artifact-privacy.md`](docs/delivery-artifact-privacy.md).

The state file stores projects, issues, agents, questions, logs, counters, and harness session metadata. The kernel is the only layer that should mutate this orchestration state. Durable logs retain the newest 500 entries so lifecycle history cannot grow without bound. Independent events remain chronological, while explicitly identified evolving statuses—currently per-worker workspace-provisioning elapsed time and checkout percentage—replace only their own preceding entry so the dashboard shows one latest value. See [`docs/log-retention.md`](docs/log-retention.md) for replacement/retention semantics and the measured rationale, and [`docs/scalability.md`](docs/scalability.md) for the hermetic process-level responsiveness sweep.

The dashboard chat remains the primary workflow: describe new goals naturally and let head agents route the work. Double-click an issue to open its delivery PR when one is tracked; when one worker needs sustained direction, iterative plan discussion, research, investigation, or closer transparency, press `a` or double-click that worker to open its optional focused workspace. With a head row selected, the same `a` key instead opens that head's persisted harness session externally for debugging and leaves the dashboard in place; unavailable history is reported as a short-lived notice. Native Pi focus continues that worker's existing context inside the logs pane while the AgentTree and external dashboard chat stay visible, live, and independently focusable. Entering native focus settles an active managed turn before transferring sole session ownership; if focus closes before a newer final result, dashboard ownership and the prior logs view are restored and the saved assignment continues automatically rather than being marked as a worker error. The same provider environment and `PATH` used to launch Pi RPC are preserved for native focus, including package-manager/version-manager installations; `docs/config.md` covers explicit command and `PATH` configuration for restricted GUI/service environments. Focused commands use a configurable leader so Pi and shell/editor bindings remain available: by default press `Ctrl-Space`, then `t` to switch views, `f` to cycle transcript filters, `a` to open the worker's saved Pi session with the existing external launcher, `b` to launch the editor, `p` to open the verified delivery PR, or `q` to close focus and restore normal dashboard logs without stopping the worker or terminal. See `docs/keybindings.md` for the full interaction model.

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

For a follow-up, the head chooses among continuing a settled session (`normal`), correcting active work (`steer`), queuing a next step (`follow_up`), spawning a related worker on the same issue, or replacing an unhealthy/stale worker. Pi's persisted session retains the detailed conversation context. AgentTree worker rows label successors with `after W…` or `replaces W…`, while lifecycle logs state the full relationship. Workers carry out assigned implementation, investigation, or informational work, and only need PRs when the assigned delivery calls for repository changes. The kernel owns orchestration state. Harness-specific behavior stays behind the harness client layer.

## Contributing notes for agents

Before changing this repository, read `AGENTS.md`. It defines the mission, architecture boundaries, terminology, workflow, and non-negotiable test policy.

Important constraints:

- keep implementation slices small and aligned to the assigned issue;
- add or extend hermetic Minitest coverage for behavior changes and run it with `rake test`;
- use task-specific branches/worktrees for worker changes;
- commit only the assigned issue's changes;
- include manual verification steps in pull requests.
