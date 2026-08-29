# Commands and the dashboard

The complete slash-command inventory, how to answer a head's question, and how
to read the logs pane and AgentTree. The [README](../README.md) covers install
and first run; this is the reference you come back to.

Inside the dashboard, `/help` lists every command grouped by what you are trying
to do, and `/glossary` defines the vocabulary. `meringue --help` prints the same
inventory from a terminal.

## Usage

The [quick start](#quick-start) covers the normal interactive launch and the harness-free demo. `bundle exec ruby -Ilib bin/meringue tui` is an explicit equivalent of `bundle exec ruby -Ilib bin/meringue`.

The first interactive launch opens Setup as the same polished full-screen overlay used by `/config`. Choose a theme, review separate head and worker defaults, and opt into Meringue Xtras such as GitHub support. Experiments is the final step; the GitHub access test is absent until GitHub support is selected, and Complete atomically saves the settings and `[onboarding]` marker together. Backspace revisits a step without losing edits, while the single centered Next action keeps the page uncluttered. Automatic first-run `Esc` confirms a safe skip; `Esc` on a manual `/setup` rerun cancels without changing the marker. The overlay remains recoverable through resize, validation, and persistence failures. See [`docs/onboarding.md`](docs/onboarding.md).

Print the CLI help:

```bash
bundle exec ruby -Ilib bin/meringue --help
```

Choose a harness at runtime:

```bash
bundle exec ruby -Ilib bin/meringue tui --harness claude
bundle exec ruby -Ilib bin/meringue tui --harness codex
bundle exec ruby -Ilib bin/meringue tui --head-harness claude --worker-harness codex
```

Use a custom state or config file:

```bash
bundle exec ruby -Ilib bin/meringue tui --state /tmp/meringue-state.json
bundle exec ruby -Ilib bin/meringue tui --config ./fixtures/config.example.toml
```

Export and import workers without opening the TUI:

```bash
bundle exec ruby -Ilib bin/meringue workers export ./workers.json
bundle exec ruby -Ilib bin/meringue workers import ./workers.json --project /path/to/the/checkout
```

See [`docs/worker-transfer.md`](docs/worker-transfer.md) for the portable format and its session limitations.

From the checkout, run the checked-in entrypoint directly with `bundle exec ruby -Ilib bin/meringue` when you need to bypass executable lookup.

Useful slash commands inside the TUI include:

- `/help` — show command syntax.
- `/project add <path> [name]` — register a project. A directory can hold more than one: naming a second project at a path you have already registered opens a separate board over the same files, which is how a migration effort and a resiliency effort stay apart while sharing one repository. An unnamed `/project add` still means "the project at this path" and reuses the one already there.
- `/issue move <issue_id> <project_id|issue_id|top>` — move an issue to another project on the same checkout, reparent it beneath another issue, or promote it to the top level. Its child issues and their workers travel with it, keeping their live sessions and worktrees.
- `/project rename <project_id> "<name>"` — rename a project.
- `/issue create <project_id> "<title>" ["description"]` — create an issue manually.
- `/issue rename <issue_id> "<title>"` — rename an issue. For both rename commands, focus the AgentTree, select a row, and press `r` to prefill the one that matches the selected row (a worker resolves to its issue).
- `/worker spawn <issue_id> "<prompt>"` — spawn a worker for an issue.
- `/worker guide "<additional system prompt>"` — persist the opt-in worker model-selection prompt; use `@` for model completion and `#` for thinking-level completion.
- `/worker pause <agent_id>` — stop the current worker turn without killing its resumable session.
- `/worker resume <agent_id>` — continue a paused worker from the same session and workspace.
- `/worker protect <agent_id>` — durably protect an agent, its containing issue, and project from pruning.
- `/worker unprotect <agent_id>` — clear an agent's durable prune protection.
- `/worker export <bundle_path> [agent_id...]` — export current worker context for retry on another computer; paths, session handles, and credentials are not copied.
- `/worker import <bundle_path> --project <path>` — recreate the project/issue context and start fresh destination sessions; source harness sessions cannot be resumed directly.
- `/prompt <agent_id> "<message>"` — follow up with an existing worker, or take over a still-routing head; use `/retry <head_id>` for a stopped head.
- `/jump [agent_id]` — open an agent's focused workspace; omit the id to navigate issues/workers and open PRs from jump mode.
- `/prs` — with **Settings → Experiments → GitHub support** enabled, open the picker for every tracked pull request that is still open. Use `↑`/`↓` to move, `Enter` to open, and `Esc` to close.
- `/github test` — with GitHub support enabled, run the bounded read-only authentication and current-repository access check. It never mutates GitHub.
- `/setup` — reopen the shared full-screen Setup overlay for theme, separate head/worker defaults, and experiment checkboxes. Manual cancel writes nothing.
- `/reload` — restart Meringue with the current source and configuration.
- `/update` — fast-forward the clean source checkout onto the branch it tracks (`main`, or `MERINGUE_BRANCH`), install missing dependencies, and reload automatically. A checkout already on that commit is reported as up to date and left running.
- `/questions` — open the picker for existing open questions; use `↑`/`↓` to move, `Enter` to insert `/answer <question_id>`, and `Esc` to close.
- `/answer <question_id> "<answer>"` — answer an open question; the kernel records the answer and routes the work it unblocks.
- `/dismiss <question_id>` — close an open question without answering it.
- `/theme [name]` — with no name, open the on-screen theme picker; otherwise persist a TUI colorscheme. The `/themes` alias opens the same picker.
- `/config` — open the full-screen transactional Settings editor for themes, separate head/worker defaults, experiments, harnesses, workspaces, safety, and every keybinding. Use `/config --text` for the old read-only diagnostic listing.
- `/harness [head|worker] <pi|claude|codex>` — with no arguments, open the on-screen harness picker; otherwise select the harness for future agents; omit the role to update both.
- `/models [harness]` — open the model picker: a searchable list of the models the selected harness reports, with clear Head/Worker tabs. `←`/`→` switches roles, `↑`/`↓` moves, `Enter` applies the selected role's future-session default, `Ctrl-R` re-asks the harness, and `Esc` closes. `/models refresh [harness]` skips the picker and just re-fetches the catalog.
- `/model [head|worker] <provider>/<model-id>` — with no arguments, open the same Head/Worker picker as `/models`; with a model reference, persist the model for all future agent sessions. Omit the role to update both (the backward-compatible form), or name `head`/`worker` to update only that role. Existing sessions are unchanged. The reference is split on the first slash, so the model id may itself contain `/` and `:` (`/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`). An id the model catalog does not list is still set, and reported as unverified. The values in force are always visible in the dashboard status line (`harness: <harness> · model: <model> · thinking: <level>` when both roles match, or a compact head/worker form when they differ) and in `/config`.
- `/thinking [head|worker] <off|minimal|low|medium|high|xhigh|max>` — with no arguments, open the clear Head/Worker thinking picker; otherwise persist a reasoning level for future agent sessions. Omit the role to update both (the backward-compatible form), or name `head`/`worker` to update only that role; existing sessions are unchanged.
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

There is no command for one existing session's settings: `/model` and `/thinking` only move future-session defaults. The dashboard shows the selected head/worker harnesses plus their separate model and thinking defaults, while the effective model and thinking level of a running agent are shown on the `session settings` line of its focused workspace (`/jump <agent_id>`). Focused workspaces advertise `/open-session` for opening the harness UI.

`/model` and `/thinking` complete from the selected harness's own model catalog, so the selector lists every available model rather than only the ones Meringue has seen. `/thinking` always offers all seven levels — the saved default first, the rest labelled with what the configured model advertises — because the catalog explains a level rather than deciding whether you may pick it. See `docs/session-settings.md#authoritative-model-catalog-discovery` for discovery, caching, and unavailable-catalog behavior, and `docs/session-settings.md#thinking-levels` for the level ladder, labels, and clamping.

See `docs/head_agent_kernel_commands.md` for the head command contract, destructive-command rules, prune eligibility, and worktree cleanup safety. See `docs/goal_loops.md` for how goal loops measure progress, judge each iteration, and stop. See `docs/recount.md` for the renumbering/cross-reference/active-session rules, and `docs/keybindings.md` for keyboard navigation, customization, and jump-mode details.

### Answering a head's question

When a head cannot route a request safely it asks a clarifying question, and the chat shows `Question Q1: …` with the reason and the ways to answer it. Answering is a real routing action, not just bookkeeping:

- `/answer Q1 "<answer>"` records the answer, closes the question, and spawns a fresh head that receives the question text, the question context, the project/issue scope, the message that originally triggered the question, and your answer. That head reuses the question's issue and prompts the worker already working on it whenever that is the right move.
- Replying in plain chat also works. A head reads the open questions in its context; if your message clearly answers exactly one of them, it closes that question and routes the unblocked work in the same step. If several questions could match, or the message is a new goal, the questions stay open and the message is routed as its own request.
- `/dismiss Q1` closes a question you no longer care about without routing any work.

Open questions are visible as a `? <count>` marker in the chat header and through the `/questions` picker, which shows local display numbers and inserts the exact `/answer <question_id>` command to use.

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
    └─ · ◇ W3  Check the migration
```

- The id and logo are drawn in that agent's **identity color** — the same deterministic per-id color its log rows and `▌` gutter already use, and the same color the chat composer takes when the row is selected. One agent is one color in all three places.
- Color is additive and status-independent: a working agent, a completed agent with its `✓`, and idle/queued/blocked/errored/killed agents all keep their color and logo. Status stays legible through the status glyph's own semantic color and the muted title of a completed row.
- A project row is only its product name (`meringue`, not `meringue working`). Lifecycle status is carried by the status glyph on every row, so it is never spelled out beside a name; the kernel strips a trailing status word from any project name it stores and repairs one that an older state file already contains.
- The logo is the agent's harness: `π` Pi, `✳` Claude Code, and `◇` Codex CLI. A harness Meringue does not ship shows a plain ASCII initial, and a record with no harness shows `?`. Every variant is exactly one column wide, and issue/project rows reserve the same cell so all ids stay in one column. Set `MERINGUE_ASCII_GLYPHS=1` for `p`/`c`/`x` if your font cannot draw the marks, or `NO_COLOR=1` to drop color while keeping glyphs, ids, and statuses.
- A protected agent has a small `🔒` lock icon after its id. Protection is durable and keeps the agent, containing issue, and project during `/prune`, even without a pull request. Use `/worker protect` or `/worker unprotect`; `/prune` is inactive when GitHub support is disabled.
- A working agent that has produced nothing for a while is marked **quiet** with how long it has been silent (`quiet 40m`), and the bottom bar's worker count gains `· 2 quiet`. Quiet is not the same as stuck: a long tool call and a long think are both quiet, and from outside the harness Meringue cannot tell them apart, so it reports the one thing it can say honestly. The threshold is `[agent] quiet_worker_warning_seconds` (default 900; `0` turns it off), and the logs pane gets one warning per quiet stretch. See [`docs/quiet-workers.md`](docs/quiet-workers.md).

Single-click a project, issue, head, or worker row in the AgentTree to filter the logs pane to that node: a worker shows its own logs, an issue adds its workers and child issues, and a project covers its whole subtree. Right-click any AgentTree row to open its context menu; the entries depend on what was clicked (a worker offers its workspace, prompt, pause, move, and kill; an issue offers spawn, rename, move, and its PR; a project offers a new issue, rename, and a second board over the same directory; empty space offers tree-wide actions). `Shift-F10` opens the same menu for the selected row without a mouse. An option that cannot apply right now stays visible and says why. Choosing an entry either performs a local view action or pre-fills the composer with the slash command it stands for, so it is reviewable and cancellable before it runs. If no PR is tracked, Meringue shows a transient notice and leaves the current selection unchanged. Issue and worker selections also focus subsequent natural-language chat: an issue targets itself, while a worker resolves to its owning issue and remains a preferred session-context hint. Head rows are log-only: a stranded head (`errored`, `killed`, or `blocked` because the kernel rejected or failed part of its batch) is marked `retry me` and can be retried deliberately with `/retry H<n>` or by double-clicking that row. A partially applied head is retried without re-routing what already landed — the retry head is handed the commands that were accepted and told to reuse those records — and the old head row is removed from the active tree once the fresh retry head starts. Selected prompts are tagged to the issue (and the selected worker when applicable), so they remain visible in the focused logs.

The chat box shows where your next message goes. While an issue or worker is selected, the composer border, title, and `›` prompt marker are tinted with that node's own identity color — the same color the logs pane uses for its rows — and the title above the chat bar reads `chat → P1-I1-W1 · Fix signup validation`. Untargeted states are deliberately plain: no selection reads `chat`, a project or any head reads `chat · <id> logs only`, and typing a slash command drops the tint (`chat · slash command · P1-I1-W1 not targeted`) because slash commands never inherit the selection. The target is named there and nowhere else: a selected target contributes only `Esc clears`, a selected target with a slash command says `slash ignores target · Esc clears`, and an unselected composer stays quiet while its popup explains slash commands. Every message still spawns a fresh head rather than prompting the worker directly. Colors are never the only cue, so the target stays readable with `NO_COLOR=1`.

The line under the chat bar prioritizes changing state and genuinely contextual actions: text-selection state, `Esc clears` for a target, `● 2W 1H` work counts, open questions, and delivery PRs. It shows the small `Ctrl-C clear/quit · Tab focus · / commands` discovery line only when the dashboard is otherwise idle; it never repeats ordinary Enter/send mechanics or the full keybinding list. Delivery PRs follow the selection: a selected worker shows the PR for *its own* delivery branch (`PR #145 open`) or `no PR yet`, and `Ctrl-B` opens it. A `check stale` suffix describes freshness of the last forge status check, not a PR lifecycle state, so a merged PR is never presented as a stale lifecycle. Unscoped chat is not about one worker, so it shows `3 open PRs` instead of pinning an arbitrary number; double-click that count, press `Ctrl-B`, or run `/prs` to open the same picker of every open PR (number, title, issue). `↑`/`↓` navigate, `Enter` opens, and `Esc` or a click outside closes. `/prs` also opens the all-open-PR picker while a tree row is selected. See [`docs/keybindings.md`](docs/keybindings.md#what-the-bottom-hint-line-shows).

The selected row stays highlighted and the filter keeps applying while you move focus to the logs or chat pane. A selected worker's border identifies the worker's lifecycle state, effective model, thinking level, and context as `used/capacity (percent)`; unavailable telemetry is labelled unavailable and estimated context is marked with `~`. The header adds a turn count only when it fits. Issue and project filters keep the shorter `logs — <selected_id>` title. Click another row to change the target. You can also click a worker's id, title, or nonblank authored message in the logs pane; this keeps the logs focus and scroll position while selecting that worker. Timestamps, icons, gutters, separators, status rows, trailing whitespace, heads, and kernel/user rows are not targets, removed workers are inert, and drag/double-/triple-click text selection wins over activation. Click the highlighted row again, click empty AgentTree space, or press `Esc` to clear it and return chat to unscoped routing. Project selections and heads that are still routing are log-only filters. Pending heads or issues with no focused worker workspace are a silent no-op when double-clicked, so expected unavailability never floods or persists in chat; actual workspace/open failures are still reported. See [`docs/keybindings.md`](docs/keybindings.md#agenttree-selection-log-filtering-and-chat-routing) for the exact scoping and routing rules.

The header owns the agent id and title; the body does not repeat an `<id> output:` label. Agent body lines use a colored `▌` gutter, while kernel and user lines keep a plain indent. Conversational head and worker output renders common Markdown—headings, emphasis, ordered/unordered/task lists, blockquotes, inline and fenced code, and links—with terminal-aware wrapping. Kernel/command rows and warnings/errors retain their semantic log presentation instead of being interpreted as chat Markdown.

ANSI sequences, control characters, common pasted terminal boxes, duplicate transcript headers, excess whitespace, and duplicate PR URLs are removed at render time without changing the original text stored in state. Styles are emitted as Canvas metadata rather than accepted from agent text. Agent colors come from the active colorscheme's deterministic identity palette, so `/theme <name>` restyles Markdown markers, gutters, and headers together. Set `NO_COLOR=1` to disable color; icons, ids, status text, gutters, Markdown block markers, and visible link targets keep the output usable.

See [`docs/agent-output.md`](docs/agent-output.md) for the harness-to-TUI rendering path, Markdown behavior, safety constraints, and before/after examples.
