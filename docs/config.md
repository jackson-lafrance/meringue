# Meringue config

Meringue reads an optional TOML config file from:

```txt
~/.meringue/config.toml
```

Use `--config PATH` to load a different file for a single run.

Run `/config` for the full-screen schema-driven editor covering every supported setting. `/config --text` retains the read-only diagnostic listing. Bare `/theme` (or `/themes`) opens a preview picker; `/theme <name>`, `/model [head|worker] <provider>/<model-id>`, `/thinking [head|worker] <level>`, `/harness [head|worker] <provider>`, `/status-bar`, and setup compatibility commands use the same validated atomic persistence layer. First-run Setup is a curated mode of this same overlay. See [`settings.md`](settings.md) for interaction, responsive layouts, transactional save/cancel behavior, and provenance.

## Settings schema and experiments

The config carries an internal schema version and the opt-in GitHub integration:

```toml
[settings]
schema_version = 1

[experiments]
github_support = false
worker_spawning_guidance = false
# worker_spawning_guidance_prompt = "..."  # shown and applied only when the toggle is true
```

New installations default GitHub support off. Existing installations with a pre-upgrade state file or onboarding marker migrate it on so upgrading does not silently remove PR behavior; an explicit value always wins. Disabling it performs no built-in `gh` subprocess/network lookup, hides GitHub-specific TUI commands and status, and preserves historical PR records. The worker model-selection prompt is editable inline through Settings → Experiments, Setup → Experiments, or `/worker guide \"...\"`, but its input is hidden and ignored while the toggle is off. When enabled, heads receive a privacy-filtered routing snapshot without configured or effective worker model/thinking defaults; guided head spawns must set both selections explicitly. See [`settings.md`](settings.md#github-support) and [`orchestration-experiments.md`](orchestration-experiments.md).

When GitHub support is enabled, **Test GitHub access** appears as a non-persistent action under Settings → Experiments (and in the Setup Experiments step). It checks the current checkout's `origin` remote, then runs bounded read-only `gh auth status --hostname github.com` and `gh repo view OWNER/REPO --json nameWithOwner` checks. It never creates, edits, closes, comments on, or otherwise mutates a GitHub resource. The same check is available as `/github test`; it reports success, unavailable CLI/service, unauthenticated, repository permission denied, timeout, and malformed-remote outcomes. The action is safe to retry.

## First-run setup marker

The first interactive launch opens the shared Settings overlay for a theme,
separate head/worker defaults, status-bar layout, and experiment checkboxes. Finishing or confirming
a first-run skip records one marker here:

```toml
[onboarding]
completed_version = 1
completed_at = "2026-08-06T14:02:11Z"
outcome = "completed"   # or "skipped"
```

The marker lives in the config file rather than in `state.json` so that
`meringue reset-state` and `/clear` do not replay setup. Delete the `[onboarding]`
section to see the flow again on the next launch, or run `/setup` any time.
Interactive Finish writes the reviewed settings and marker in one
`SaveConfiguration` transaction; `/setup complete|skip` remain compatible
`CompleteOnboarding` commands. Both honor `--config PATH`. See
[`onboarding.md`](onboarding.md) for first-run, rerun, cancel, resize, and failure
behavior.

## Selecting a TUI colorscheme

```toml
[tui]
colorscheme = "meringue"
```

Supported colorschemes:

- `meringue` (default yellow/white palette)
- `rose-pine` (the original Meringue palette)
- `tokyonight`
- `gruvbox`
- `catppuccin`
- `kanagawa`

Every colorscheme also defines an eight-color agent palette. Each agent id is hashed to one palette slot, so the same head or worker always renders in the same color for a given theme, and that assignment is used for its rows in the logs pane and its id/harness logo in the AgentTree (in every status, completed rows included). The chat composer also uses the palette while a worker or issue is the selected chat target; heads are log-only and never tint the composer. Heads use a bold `◆`, workers use `✦`, completed results use `✓`, actionable warnings/errors use `!`, and kernel/command logs keep the theme accent with `▪`. Set `NO_COLOR=1` to render the TUI without color; icons, explicit ids, harness logos, status text, the composer title, and the `▌` gutter still separate agent output from kernel logs.

AgentTree rows also show which harness backs each session: `π` Pi and `✳` Claude Code. A harness Meringue does not ship renders a plain ASCII initial and a record with no harness renders `?`, always in exactly one column. Set `MERINGUE_ASCII_GLYPHS=1` to render `p` / `c` instead of the marks when a font cannot draw them.

`color_scheme` is accepted as a compatibility alias for `colorscheme`. Running `/theme <name>` writes a single `colorscheme` value and removes the older `color_scheme` alias from the `[tui]` section.

## Turning off animation

```toml
[tui]
animations = false
```

Animation is an appearance preference for TUI surfaces that support motion. `MERINGUE_NO_ANIMATION=1` overrides the file for the current process. Setup exposes the checkbox because it is a useful first-run preference, but the shared Settings/Setup overlay itself uses immediate redraws and does not depend on animation for navigation or recovery.

## Customizing TUI keybindings

Keybindings live alongside the theme under `[tui.keybindings]`. Each key is an action name and each value is a string or array of strings. Omitted actions keep the built-in defaults; an empty array intentionally unbinds that action; unknown actions or invalid key names are ignored so defaults continue to work.

```toml
[tui.keybindings]
# Vim-style jump navigation while keeping all other defaults.
agent_select_previous = ["k", "up", "left"]
agent_select_next = ["j", "down", "right"]

# Example: submit with Ctrl-X and insert newlines with Ctrl-N.
# submit = ["ctrl-x"]
# newline = ["ctrl-n"]
```

Supported action names:

- `quit`
- `clear_or_quit`
- `undo` (defaults to `ctrl-z`; only active while the chat input is focused)
- `cancel_navigation`
- `open_delivery_pr` (defaults to `ctrl-b`)
- `refresh_model_catalog` (defaults to `ctrl-r`; only active inside the `/models` model picker)
- `focus_next`, `focus_previous`
- `scroll_up`, `scroll_down`, `scroll_page_up`, `scroll_page_down`, `scroll_top`, `scroll_bottom`
- `submit`, `newline`
- `complete_suggestion`, `suggestion_previous`, `suggestion_next`
- `cursor_left`, `cursor_right`, `cursor_up`, `cursor_down`, `cursor_home`, `cursor_end`, `cursor_word_left`, `cursor_word_right`
- `delete_backward`, `delete_forward`, `delete_word_backward`, `delete_word_forward`
- `copy_selection`, `cut_selection`, `paste_clipboard`
- `select_left`, `select_right`, `select_up`, `select_down`, `select_home`, `select_end`, `select_word_left`, `select_word_right`, `select_page_up`, `select_page_down`
- `logs_selection_mode`
- `agent_select_previous`, `agent_select_next`, `open_agent_workspace`
- `workspace_leader`, `workspace_switch_view`, `workspace_cycle_filter`, `workspace_open_agent_session`, `workspace_open_editor`, `workspace_open_pull_request`, `workspace_close`

`copy_selection` defaults to `["ctrl-c", "alt-c"]`. `Ctrl-C` only copies while a selection is active or the logs selection cursor is on, so it keeps clearing the input and quitting an empty prompt otherwise. Mouse drag selection in the logs pane and the composer is always on and is not configurable.

`scroll_top` defaults to `["home"]` and `scroll_bottom` defaults to `["end"]`. They jump the focused non-chat pane to its first or last content line, so the AgentTree and logs panes can be scrolled to either end without paging. While the composer is focused, or while the logs selection cursor is on, `home`/`end` keep their `cursor_home`/`cursor_end` behavior. Mouse wheel scrolling always targets the pane under the pointer and is not configurable.

`cancel_navigation` (default `escape`) also clears the sticky AgentTree selection that filters the logs pane. Selecting an AgentTree node with the mouse, and retargeting the filter with `agent_select_previous` / `agent_select_next` while jump mode is active, are always-on behaviors with no separate action to rebind; see `docs/keybindings.md` for the scoping rules.

`logs_selection_mode` defaults to `["alt-v"]` and toggles the keyboard selection cursor while the logs pane is focused. Inside that mode the `cursor_*` and `scroll_page_*` actions move the cursor and the `select_*` actions extend the selection, so rebinding those actions changes both the composer and the logs pane. See `docs/keybindings.md` for the selection and clipboard behavior.

Common key names include `enter`, `shift-enter`, `tab`, `shift-tab`, `ctrl-tab`, `escape`, arrow keys (`up`, `down`, `left`, `right`), `shift-left`, `shift-right`, `shift-up`, `shift-down`, `shift-home`, `shift-end`, `shift-alt-left`, `shift-alt-right`, `shift-ctrl-left`, `shift-ctrl-right`, `shift-page-up`, `shift-page-down`, `home`, `end`, `page-up`, `page-down`, `backspace`, `delete`, `ctrl-space`, `ctrl-a` through `ctrl-z`, `alt-c`, `alt-v`, `alt-left`, `alt-right`, `ctrl-left`, `ctrl-right`, `alt-backspace`, `ctrl-backspace`, `alt-delete`, `ctrl-delete`, `space`, and single printable characters like `j` or `p`. Advanced users can bind a raw terminal sequence with `raw:<sequence>`; literal `\\e` inside that string is converted to Escape.

Use `/keybind` in the TUI to show the active keybindings after config has been loaded. `/config` opens the editable Keybindings category; `/config --text` prints the diagnostic listing.

## Supported defaults and conflict policy

The config file is intentionally small and only the settings described here are read by Meringue. Omitted values use built-in defaults.

### Choosing a harness

Meringue has no default backend. Nothing runs until a harness is named, and a launch without one reports which harnesses are available rather than picking one:

```toml
[harness]
provider = "claude"            # applies to both roles
# head_provider = "claude"     # optional role override
# worker_provider = "pi"
```

`MERINGUE_HARNESS` overrides both roles; `MERINGUE_HEAD_HARNESS` and `MERINGUE_WORKER_HARNESS` override one. First-run setup and `/config` both write these.

### Model and reasoning defaults

These are harness-neutral: they follow whichever backend is selected rather than belonging to one of them. Each backend renders them in its own vocabulary — Pi receives `--model` and `--thinking`, Claude Code receives `--model` and `--effort` — and a backend that accepts neither simply ignores them.

```toml
[harness]
model = "anthropic/claude-opus-5"        # shared fallback for either omitted role
# head_model = "openai/gpt-5.6-sol"      # optional role override
# worker_model = "anthropic/claude-opus-5"
thinking_level = "max"                   # shared fallback for either omitted role
# head_thinking_level = "low"            # optional role override
# worker_thinking_level = "max"
```

The model is stored as a qualified `provider/model-id` reference because a multi-vendor harness has to disambiguate a bare id. A single-vendor harness such as Claude Code is handed the bare id instead, so one stored value works for both.

A value set under a specific backend still wins for that backend, which is where a model that only exists on one harness belongs:

```toml
[harness.pi]
model = "openai-codex/gpt-5.6-sol"       # used only when the harness is Pi
```

The older `[harness.pi] model` / `thinking_level` keys are still read as fallbacks, so an existing configuration keeps working without being rewritten.

```toml

[conflicts]
# A worker queued after a predecessor is cancelled when that predecessor fails.
# Use "run" to start it anyway. Explicit worker-command flags still win.
predecessor_failure = "cancel"
```

`[conflicts].predecessor_failure` accepts `cancel` or `run`. It applies only when a dependent worker does not provide its own `if_predecessor_fails` value; it does not change the handling of git merge conflicts or overwrite project files. Settings reports the current/default value and provenance; `/keybind` reports only keybindings.

## Worker command blacklists

Meringue can reject selected worker `bash` tool calls before the harness starts the
command. This is enforced by a Pi extension, so it requires the worker harness to be Pi. Configure full-command glob patterns under `[commands]`:

```toml
[commands]
worker_blacklist = [
  "*gh pr comment *",
  "*gh api *pulls/*/comments/*/replies*",
]
```

Matching has intentionally small and predictable semantics:

- Meringue matches each pattern against the **complete raw command string** that
  the worker gave to the `bash` tool. Prefixes such as `cd repo &&` and embedded
  newlines are part of that string.
- `*` matches zero or more characters, including newlines. `?` matches exactly
  one character. Every other character is literal; these are not regular
  expressions. Matching is case-sensitive.
- The first matching pattern blocks the complete tool call. No part of a
  compound shell command runs. Pi returns a tool error such as
  `Command blocked by Meringue worker blacklist pattern "*gh pr comment *".`
  to the worker.
- An omitted key or an empty array disables the blacklist. Empty patterns,
  non-string entries, control characters, more than 100 patterns, and patterns
  longer than 512 characters are configuration errors.

Patterns are intentionally conservative. For example,
`"*gh api *pulls/*/comments/*/replies*"` also blocks a read command that names a
review-reply endpoint. Prefer a narrow pattern when reads to the same endpoint
must stay available. A pattern can also match text inside a quoted string or
heredoc because Meringue does not parse or execute shell syntax before making
the decision. This avoids unsafe shell interpretation and prevents a blocked
compound command from running partially.

This enforcement applies to isolated **Pi worker** sessions and to resumed Pi
workers. Heads do not receive this policy, and shared read-only workers have no
`bash` tool at all. If a worker blacklist is configured while the selected
worker provider is Claude Code, worker startup fails closed with
a clear unsupported-provider error instead of relying on prompt instructions.
Restart Meringue after changing this setting so all future workers use the new
configuration; an already-running worker keeps the policy loaded when its Pi
process started.

## Worker workspace terminal and editor

The optional focused worker workspace has mutually exclusive agent and worktree-terminal views. Commands use a configurable leader sequence so common shell/editor controls are not intercepted while the terminal is active. The default is `Ctrl-Space` followed by `t` to switch between terminal and agent view, `f` to cycle transcript filters, `a` to open the underlying harness session in the established external terminal UI, `b` to open the editor, `p` to open the verified delivery PR, or `q` to quit back to the AgentTree while preserving the worker and terminal. The focused workspace shows exactly this leader line under its chat box, including the active transcript filter. Configure the leader and suffixes under `[tui.keybindings]`:

```toml
[tui.keybindings]
workspace_leader = ["ctrl-space"]
workspace_switch_view = ["t"]
workspace_cycle_filter = ["f"]
workspace_open_agent_session = ["a"]
workspace_open_editor = ["b"]
workspace_open_pull_request = ["p"]
workspace_close = ["q"]
```

Suffixes are interpreted only after the leader while a focused workspace is active. `workspace_close` (leader + `q` by default) is the only return action; the global `cancel_navigation = ["escape"]` binding applies only to dashboard jump mode and cannot close the focused workspace. Outside the workspace, the global `open_delivery_pr = ["ctrl-b"]` action is unchanged. In terminal view, bare `Ctrl-T`, `Ctrl-B`, and `PageUp`/`PageDown` are forwarded to the PTY like other ordinary terminal input.

`workspace_open_agent_session` was previously named `workspace_open_pi_session`. The old name still works in `[tui.keybindings]` and is applied to the same harness-agnostic action, so existing custom bindings keep working.

Configure the shell and editor under `[workspace]`:

```toml
[workspace]
shell_command = ["/bin/zsh", "-l"]
editor_command = ["code", "--reuse-window"]
editor_args = ["."]
# Raw terminal output retained when switching views (default: 4194304).
terminal_buffer_bytes = 4194304
```

## Pluggable worktree provider

Native Git remains the default for isolated worker workspaces:

```toml
[workspace]
worktree_provider = "native_git"
```

A user may opt into a private local adapter executable without adding provider-specific knowledge to
Meringue:

```toml
[workspace]
worktree_provider = "command"
worktree_provider_command = ["/absolute/path/to/private-worktree-adapter"]
worktree_provider_fallback = "native_git" # default; use "none" to fail closed
```

The command setting is argv, not a shell snippet. A string is accepted for compatibility and split
with shell quoting rules, but Meringue always spawns the resulting arguments directly. Task names,
branches, paths, substitutions, semicolons, redirects, and provider output are never evaluated by a
shell. Keep provider-specific commands and configuration in the local adapter and user config; the
public repository only defines this protocol.

### Command protocol

The configured argv prefix receives one of two actions. Provisioning receives:

```txt
<command...> provision \
  --name <stable-name> \
  --branch <reserved-branch> \
  --base-ref <verified-base-ref> \
  --git-root <absolute-common-repository-path> \
  --project-root <absolute-configured-project-path>
```

The provider may choose any destination layout, but must leave exactly one ordinary, non-bare Git
worktree registered on the reserved branch. It writes exactly one JSON object to stdout; progress and
human diagnostics belong on stderr:

```json
{"identifier":"opaque-provider-id"}
```

`identifier` is optional. When omitted, Meringue uses the requested stable name for release. An
adapter must also be able to reconcile release from the stable name and exact worktree path after an
interruption that occurs before an opaque response can be persisted. Meringue does not trust a
provider-reported path: after the command exits it finds the branch through
`git worktree list --porcelain`, derives the configured project's relative path, verifies that the
directory exists, and records ownership of that exact worktree root.

Release receives:

```txt
<command...> release \
  --identifier <opaque-provider-id> \
  --worktree-path <absolute-worktree-root> \
  --branch <reserved-branch> \
  --git-root <absolute-common-repository-path> \
  --project-root <absolute-configured-project-path>
```

Release is called only after Meringue verifies persisted ownership, Git registration, the expected
branch, no lock, no other worker reference, and a clean status. Meringue never adds a force option.
On success the provider writes:

```json
{"released":true,"worktree_retained":false,"branch_retained":true}
```

Set `worktree_retained` to `true` when release keeps a reusable registered worktree but moves it off
the worker branch. Meringue verifies the declared postcondition against Git: a non-retained worktree
must be deregistered, while a retained worktree must still be registered and no longer have the
worker branch checked out. `branch_retained` is optional diagnostic metadata. Regardless of that
value, Meringue checks the local delivery ref and recreates it at its verified pre-release commit if
the provider removed it.

### Lifecycle and failure policy

The provider boundary changes only create/release mechanics. Meringue continues to own:

- deterministic branch/name reservation and cross-process allocation locks;
- exact path ownership, worker occupancy exclusion, and final launch validation;
- continuation adoption only for the same recorded owner and branch;
- non-bare/editable checks, registered branch and lock checks, and bare-source safety;
- dirty-worktree refusal, branch preservation, idempotent release detection, pruning, and cleanup
  diagnostics;
- bounded command output, stall/absolute timeouts, and direct argv spawning.

A bare repository is still a valid source and never a worker `cwd`. The provider receives both the
bare Git root and configured project root, but Meringue launches only when the provider returns a
registered non-bare checkout. Shared read-only workspaces do not invoke the command provider and keep
their existing checkout/cache behavior.

Project-declared sparse patterns and custom path templates require Meringue's native provisioning
sequence, so they use the configured native fallback. A generic synthetic large-bare profile may be
handled by the command provider; project validation commands still run against the resulting
checkout before launch.

Fallback is intentionally limited. Meringue may use native Git when the command is empty/missing or
known to be inapplicable **before** provider mutation. Once a provider command starts and fails,
returns invalid JSON, or leaves ambiguous Git state, Meringue reconciles the exact reserved branch,
cleans up only a checkout it can prove it owns through the same provider, and reports bounded
diagnostics. It does not immediately create a second native worktree. If a configured provider later
becomes unavailable during release, Meringue preserves the checkout rather than guessing whether a
provider-owned reusable directory may be deleted.

The requested/effective provider, opaque identifier, provider working directory, and fallback reason
are persisted in the worker workspace plan. Allocation, launch validation, continuation reuse,
failed-session release, restart recovery, and `/prune` therefore use the same ownership contract.
Changing provider settings affects future manager instances; restart Meringue after editing them.

## Worker workspace provisioning concurrency and timeouts

`SpawnWorker` first writes a durable queued reservation and returns without waiting for workspace
or harness I/O. A bounded background executor provisions independent reservations concurrently:

```toml
[workspace]
# Default: 2. Values above 8 are capped at 8; invalid or non-positive values use the default.
worker_provisioning_concurrency = 2
```

A value of 2 overlaps independent checkouts without turning one head batch into an unbounded burst
of Git and disk work. The durable slot claim applies across Meringue processes sharing the state
file, not just threads in one dashboard. The AgentTree says `waiting for provisioning slot` while a reservation waits
for executor capacity, then changes to `provisioning workspace` when allocation starts. The durable
reservation retains its owner identity, prompt, workspace plan, relationships, and command id; if
Meringue exits, reconciliation lets a new live instance re-enqueue it rather than allocating a
second worker.

Native provisioning runs `git worktree add`, while a command provider runs its configured
provision action. Either may check out a large tree, so provisioning is bounded by how long it goes *quiet*
rather than by how long it runs, with a finite backstop so a bound can never turn into a hang:

```toml
[workspace]
# Budget for short git plumbing (rev-parse, show-ref, worktree list). Default: 60.
git_command_timeout = 60
# Kill a native or external worktree create command after this many seconds with no output at all.
# Git normally reports checkout progress on stderr, so silence this long means the command is stuck
# (an unresponsive file-system monitor, a credential prompt, a lock it will never get) rather
# than slow. Default: 120.
worktree_stall_timeout = 120
# Absolute ceiling for one `git worktree add`, and for one provisioning attempt as a whole,
# no matter how much progress it reports. Default: 1800 (30 minutes).
worktree_checkout_timeout = 1800
```

All three are seconds. A non-numeric or non-positive value falls back to the default, and a stall
bound larger than the checkout ceiling is clamped to it so it can still fire. Raise
`worktree_checkout_timeout` for an unusually large repository on slow storage; lower it if you
would rather a giant checkout fail fast.

While provisioning is queued or runs, its worker stays `queued` and the AgentTree shows live worktree telemetry.
The row first says `provisioning workspace`; once Git emits checkout progress it shows Git's actual
percentage (for example, `provisioning workspace 35%`). Before a percentage is available it shows
the checkout phase and elapsed time instead. This percentage covers only the worktree checkout, not
harness startup, so Meringue does not invent a total-worker percentage. The state record updates
about every 15 seconds, while the durable `Still provisioning worker ...` log is rate-limited to one
line per minute. When the harness starts, the progress marker is cleared and the worker becomes
`working`.

When provisioning does fail, the worker is not thrown away: a stuck attempt is retried once
automatically, and a worker that runs out of automatic attempts stays `blocked` with its prompt
and failure reason intact. Disk exhaustion is detected separately from a timeout or generic Git
failure. Meringue cleans up only the partial worktree/branch created by that failed attempt, does
**not** immediately retry against the same full disk, and leaves the worker blocked with an
actionable `free disk space, then prompt this worker to retry provisioning` diagnosis. It never
removes dirty, unrelated, or user-owned worktrees to manufacture headroom.

Git can print one progress record per checked-out file and repeat `No space left on device` for
thousands of paths. Command capture is therefore bounded to a 16 KiB head/tail diagnostic while
recording the original byte counts and whether output was omitted. The beginning preserves the
operation Git attempted, the tail preserves the terminal errno, and the concise worker error is
not a copy of the per-file failure stream. Prompting a blocked worker after cleanup retries the
same reservation with the new instruction; `/info <worker id>` reports the state, attempts, error,
and next step.

## Project-native sparse provisioning profiles

By default Meringue materializes the full tree per worker with `git worktree add`. For a large
monorepo that is minutes of avoidable checkout time plus slower downstream git operations. A
project may instead declare a **sparse provisioning profile** so Meringue checks out only the
working set the project's own tooling expects, using repository-approved patterns rather than
model-inferred path narrowing.

The profile is generic and project-configured, never hard-coded for a specific project. A project
without a declared profile keeps the current full-checkout behavior unchanged. The profile file
lives at the project root as `.meringue/workspace-profile.toml` and is parsed with Meringue's
existing TOML parser (no new dependencies):

```toml
default_profile = "core"

[profiles.core]
sparse_cone = true
sparse_patterns = ["/src/", "/docs/"]
path_template = "{{root}}/{{project}}/{{task}}-{{suffix}}"
validation_command = ["bin/validate-checkout"]
```

A single-profile file may use the flat `[profile]` table instead of the `[profiles.<name>]` map.
All fields except `sparse_patterns` are optional:

- `sparse_patterns` enables sparse provisioning when non-empty. `sparse_cone` selects cone mode.
- `path_template` declares the project's native checkout layout. Placeholders are `{{root}}`,
  `{{project}}`, `{{task}}`, and `{{suffix}}`; the default is
  `{{root}}/{{project}}/{{task}}-{{suffix}}`. A template that escapes the managed workspace root
  or contains unsafe characters is rejected and the default layout is used.
- `validation_command` is an argv array run inside the checkout after provisioning. A non-zero
  exit fails provisioning so a worker never launches in a checkout its project tooling rejects.

When a sparse profile is active, Meringue provisions with `git worktree add --no-checkout`, writes
per-worktree `core.sparseCheckout` / `core.sparseCheckoutCone` configuration (via the
`extensions.worktreeConfig` extension so sparse settings stay isolated to each worktree and never
leak into the shared repository config), writes the declared patterns to the worktree's
`info/sparse-checkout`, and then materializes only that set with `read-tree -mu HEAD`. Bare
repository sources are supported: a `--no-checkout` worktree created from a bare common
repository additionally flips `core.bare=false` per-worktree so the sparse materialization runs.

The selected profile name, path template, sparse record (cone, patterns, materialized file count),
and validation result are persisted on the workspace plan (`harness_metadata.workspace_plan`) for
reuse on retry and inspection via `/info`. Allocator ownership, exactly-once safety, collision
handling, bare-repository protections, and shared-read-only fallback behavior are preserved: a
shared read-only worker never uses a sparse profile, and a malformed or missing profile file falls
back to the default full checkout.

### Synthetic large-bare default

A project that declares no profile still gets the full checkout on a normal (non-bare) source or
on a small bare source. To stop a large bare repository from materializing the whole tree for every
isolated writable worker, Meringue synthesizes a generic **root-files-only** sparse profile
automatically when the source is bare and its packed object count crosses a threshold. The
synthetic profile carries no project-specific paths: it uses the non-cone patterns `/*` (every
root entry) and `!/*/` (negate all root directories), so only root-level files such as README and
manifests are materialized and every subdirectory is skipped until the worker expands its working
set with `git sparse-checkout add <path>` or `git checkout HEAD -- <path>`. The packed object count
is read from `git count-objects -v` pack `.idx` footers, which is O(number-of-packs) and never
scans every object, so the gate itself stays cheap.

Two `[workspace]` knobs tune the behavior:

- `bare_sparse_object_threshold` (default `1000000`) — the packed object count at which a bare
  source with no declared profile switches to the synthetic sparse default. Raise it to narrow the
  behavior to only the largest sources, or lower it to apply it sooner.
- `default_bare_checkout_mode` (default `sparse`, or `full`) — set to `full` to opt out entirely
  and keep the legacy full checkout on every bare source, regardless of size.

A project that declares any profile (sparse or full-checkout) always overrides the synthetic
default, so a project that wants the full checkout on a large bare repo can declare a full-checkout
profile (no `sparse_patterns`) or an operator can set `default_bare_checkout_mode = "full"`.
Allocator ownership, exactly-once safety, collision handling, and bare-repository protections are
preserved: the synthetic profile flows through the same provisioning path as a declared one.

Commands may be either an argv array (recommended) or a shell-quoted string such as `editor_command = "code --reuse-window"`. Strings are split into arguments, but are **never executed by a shell**: redirects, substitutions, pipes, semicolons, and worktree paths cannot become shell code. `editor_args` is a string or array of strings and defaults to `["."]`.

Defaults, in precedence order:

- shell: `MERINGUE_SHELL`, then `SHELL`, then `/bin/sh`;
- editor: `MERINGUE_EDITOR`, then `VISUAL`, then `EDITOR`, then `code`;
- editor args: `["."]`.

The shell is started in a PTY whose current directory is the worker's real worktree directory. Meringue resolves that directory from the worker record (`workspace_path`, then the harness `cwd`, then the recorded workspace plan/worktree root) and always converts it to an absolute path; a relative value is resolved against the recorded project/git root rather than the Meringue process working directory, so a workspace-relative value can never be nested inside an already workspace-rooted cwd. If the recorded directory is gone but its worktree root still exists, the shell opens there and says so; if nothing usable exists, the workspace shows a clear stale-worktree notice instead of opening a shell at a bogus path. It remains alive while switching views or leaving with the workspace `q` command, receives terminal resize events, and is stopped with its process group when explicitly closed or when Meringue exits. Child-process ANSI/SGR colors are preserved by the embedded screen model. It is separate from the managed coding-agent process; terminal cleanup never signals the worker harness pid. Meringue also removes inherited provider session markers from the shell environment so it cannot accidentally target the enclosing managed agent session.

The editor command is spawned directly with the worktree as both its current directory and, by default, the `.` argument. GUI editor CLIs normally detach or reuse an existing window. For a terminal-only editor, configure a terminal-emulator wrapper as the command (for example, an Alacritty command ending in `-e nvim`) so the editor has its own terminal. A missing executable, invalid command/argument type, malformed quoting, or removed worktree is reported in the workspace rather than crashing Meringue or mutating agent state.

The focused-workspace leader + `a` action reuses Meringue's existing external session opener: it validates the worker's persisted harness session (for Pi, the session file, or discovery from the saved session ID), then launches the configured harness command in Alacritty at the worker worktree. On the dashboard, selecting a head and pressing `a` uses that same opener for the head's persisted session while leaving the dashboard open. `[terminal].alacritty_command`, `[harness.pi].command`, and `[harness.pi].session_dir` apply. The detached external UI does not replace, attach to, signal, or transfer ownership of Meringue's managed RPC process. Worker opening failures are reported in the focused workspace; unavailable head history gets a short-lived dashboard notice. Neither path changes the saved agent record.

Supported workspace action names:

- `open_agent_workspace`
- `workspace_leader`
- `workspace_switch_view`
- `workspace_cycle_filter`
- `workspace_open_agent_session` (legacy alias: `workspace_open_pi_session`)
- `workspace_open_editor`
- `workspace_open_pull_request`
- `workspace_close`

## Selecting harnesses

```toml
[harness]
provider = "pi"              # default for heads and workers
# head_provider = "claude"   # optional override for head agents
# worker_provider = "claude" # optional override for worker agents
```

Supported provider names in this slice:

- `pi`
- `claude` for Claude Code (aliases: `claude_code`, `claude-code`, `cc`)

The `split_defaults` experiment is enabled by default and makes head/worker harness, model, and thinking settings independent. Disable it only for a compatibility migration: role-specific values remain stored, but the shared values are used for both roles. Harness selection re-resolves incompatible future thinking values for each affected role in the same config transaction; it never rewrites an existing session.

CLI flags override `config.toml`:

```bash
bin/meringue tui --harness claude
bin/meringue tui --harness claude_code
bin/meringue tui --head-harness pi --worker-harness claude
```

Environment variables override both config and CLI flags:

```bash
MERINGUE_HARNESS=claude bin/meringue tui
MERINGUE_HEAD_HARNESS=pi MERINGUE_WORKER_HARNESS=claude bin/meringue tui
```

## Provider sections

Each provider can set its executable command and role-specific extra args.

```toml
[harness.pi]
command = "pi"
session_dir = "~/.meringue/pi-sessions"
# Shared model and thinking fallbacks (backward-compatible):
model = "anthropic/claude-opus-5"
thinking_level = "max"
# Optional role-specific overrides:
# head_model = "openai/gpt-5.6-sol"
# worker_model = "anthropic/claude-opus-5"
# head_thinking_level = "low"
# worker_thinking_level = "max"
head_extra_args = ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--tools", "read,bash,grep,find,ls"]
worker_extra_args = ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--tools", "read,bash,grep,find,ls,edit,write"]

[harness.claude]
command = "claude"
use_json_schema = true
head_extra_args = ["--effort", "high", "--permission-mode", "plan"]
worker_extra_args = ["--effort", "high", "--permission-mode", "acceptEdits"]
```

Heads and workers default to `anthropic/claude-opus-5` at the maximum reasoning level. Use `/model head <provider>/<model-id>` and `/model worker <provider>/<model-id>`, or set `head_model` and `worker_model`, for distinct role model defaults; use `/thinking head <level>` and `/thinking worker <level>`, or set `head_thinking_level` and `worker_thinking_level`, for distinct role reasoning defaults. The existing `/model <provider>/<model-id>` command and `model` key, and `/thinking <level>` command and `thinking_level` key, remain the shared form; those commands also clear role overrides. A role key wins over the shared key, and either scalar wins over a `--model`/`--thinking` flag in that role's argument array. A configured role array still replaces that role's default array entirely, so include every other flag you need. Claude Code receives a bare model id and `--effort`; Meringue still reports the stored qualified reference so status and `/config` remain portable across harnesses. Values that are valid references but absent from a catalog remain allowed and are labelled unverified.

A provider `command` may be a bare executable such as `pi`, an absolute path, or a command with arguments. Meringue uses the provider's effective environment—the environment that launched Meringue plus any configured `env` overrides—for harness sessions, catalog probes, and focus. Native focus resolves the executable against that same effective `PATH` before transferring session ownership, rather than trying to find `pi` again in a reduced PTY environment. This keeps focus working when Pi is installed by a version manager or package manager in a non-system directory. For services or GUI launchers whose startup environment has no usable shell `PATH`, configure an absolute path (for example, `command = "/opt/homebrew/bin/pi"`) or add the installation directory explicitly:

```toml
[harness.pi.env]
PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
```

A configured `PATH` replaces, rather than appends to, the inherited value, so include every directory the provider command or its child tools need. If resolution fails, Meringue reports the configured command and the effective `PATH`; installing Pi in a later shell does not change an already-running Meringue process, so restart Meringue after installation or environment changes.

A model reference is `<provider>/<model-id>`, split on the first slash, so the model id may itself contain `/` and `:` (`model = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"` is valid). See [`session-settings.md`](session-settings.md#the-accepted-model-reference-grammar) for the exact grammar and for what is still rejected.

`/config` and the dashboard status line show each future role's model and reasoning level for its configured harness (the shared model when both roles agree, split by role when they differ). `/model` and `/thinking` update only future-session defaults and never rewrite existing sessions. An existing session's own effective pair has no slash command either: it is recorded on the agent record and shown in the focused worker workspace and raw `/state`. See [`session-settings.md`](session-settings.md) for the exact scope and propagation rules.

### Model catalogs and provider resource flags

The `/models` model picker, and the completion list behind `/model`, come from the harness itself rather than a list maintained in Meringue. For Pi, Meringue starts a short-lived ephemeral RPC probe (`pi --mode rpc --no-session`) and reads `get_available_models`.

That probe reuses the configured provider `command`, `env`, `extra_args`, and role `*_extra_args`, minus `--model`/`--thinking`, because provider availability depends on those flags. Claude Code uses an ephemeral `claude --print --output-format json "/model"` command instead, strips `--model`/`--effort`, and parses Claude Code's own aliases and effort levels. Picker and setup rendering use only the persisted snapshot and never make a network request. Two consequences matter when configuring Pi:

- If `worker_extra_args` contains `--no-extensions` and your models come from a Pi extension, the catalog is legitimately empty, and Meringue reports `unavailable` with Pi's own answer instead of inventing entries. Keep the `--extension <path>` flag that registers your provider in the same array (as in the example above) so probes and real sessions agree.
- Model/thinking defaults are dropped from the probe on purpose: an unavailable saved default must not stop Pi from reporting which models exist.

Catalogs are cached in Meringue state under `metadata.harness_model_catalogs.<harness>` and refreshed in the background by reconciliation (about every 10 minutes, retried after about 1 minute when a fetch failed). `/models refresh` (or `Ctrl-R` inside the model picker) forces an immediate re-fetch after you log into a provider, install an extension, or edit `~/.pi/agent/models.json`.

Claude Code runs in its own interactive mode inside a PTY Meringue owns for the life of the session; see [`interactive-harness-backends.md`](interactive-harness-backends.md). Its catalog is `available` only when Claude Code returns a non-empty authoritative answer; missing CLI, auth/exit failure, or an empty/malformed response is `unavailable`, and a failed refresh after a confirmed answer is `stale` with the last confirmed models retained.

Do not store API keys or secrets in the config file. Prefer each provider CLI's normal auth flow or environment setup.

### Status-bar layouts

Use `/status-bar` to open the live dashboard bottom-bar composer. The same composer is rendered directly on the Status bar page in first-run Setup and manual `/setup`; there every move updates only the shared setup draft so Complete can save it with the onboarding marker. Components can be reordered and moved between left/right alignment zones. The focused worker's other two bars remain on their built-in renderers. The saved `tui.status_bar_layout` value is versioned JSON; an absent or invalid value uses the complete default. See [`status_bar_layouts.md`](status_bar_layouts.md) for the keyboard, mouse, cancellation, resize, and version-1 migration workflow.
