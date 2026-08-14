# Meringue config

Meringue reads an optional TOML config file from:

```txt
~/.meringue/config.toml
```

Use `--config PATH` to load a different file for a single run.

The interactive TUI updates this file with `/theme <name>`, `/model <provider>/<model-id>`, `/thinking <level>`, `/thinking head <level>`, `/thinking worker <level>`, and the first-run setup flow (`/setup`).

## First-run setup marker

The first launch on a machine opens a short setup flow for the harness, model,
thinking level, and theme. Finishing or skipping it records one marker here:

```toml
[onboarding]
completed_version = 1
completed_at = "2026-08-06T14:02:11Z"
outcome = "completed"   # or "skipped"
```

The marker lives in the config file rather than in `state.json` so that
`meringue reset-state` and `/clear` do not replay setup. Delete the `[onboarding]`
section to see the flow again on the next launch, or run `/setup` any time. It is
written by the `CompleteOnboarding` kernel command, so it honors `--config PATH`
like every other config write. See [`onboarding.md`](onboarding.md) for the steps,
keys, and degraded behavior.

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

AgentTree rows also show which harness backs each session: `π` Pi, `✳` Claude Code, `↑` Antigravity. A harness Meringue does not ship renders a plain ASCII initial and a record with no harness renders `?`, always in exactly one column. Set `MERINGUE_ASCII_GLYPHS=1` to render `p` / `c` / `a` instead of the marks when a font cannot draw them.

`color_scheme` is accepted as a compatibility alias for `colorscheme`. Running `/theme <name>` writes a single `colorscheme` value and removes the older `color_scheme` alias from the `[tui]` section.

## Turning off animation

```toml
[tui]
animations = false
```

Animation is opt-out and today it only affects the [first-run setup screen](onboarding.md#animation): the sweep, the eased progress bar, the staggered row reveal, and the breathing selection marker. With `animations = false` (or `MERINGUE_NO_ANIMATION=1`, which wins over the file) setup draws its settled frame immediately and stops asking for animation frames, so nothing about the flow changes except the motion. Any other value, or an absent key, keeps motion on.

Motion also turns itself off without being asked: on a non-interactive stdin, and on any terminal smaller than 60×16, where every row is needed for content.

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

Use `/keybind` in the TUI to show the active keybindings after config has been loaded. `/config` shows the same keybindings together with the active supported defaults, workspace commands, and conflict policy.

## Supported defaults and conflict policy

The config file is intentionally small and only the settings described here are read by Meringue. Omitted values use built-in defaults. Future Pi session defaults live under `[harness.pi]`:

```toml
[harness.pi]
model = "anthropic/claude-opus-5"
thinking_level = "max"        # legacy/shared fallback
# head_thinking_level = "low"  # optional role override
# worker_thinking_level = "max"

[conflicts]
# A worker queued after a predecessor is cancelled when that predecessor fails.
# Use "run" to start it anyway. Explicit worker-command flags still win.
predecessor_failure = "cancel"
```

`[conflicts].predecessor_failure` accepts `cancel` or `run`. It applies only when a dependent worker does not provide its own `if_predecessor_fails` value; it does not change the handling of git merge conflicts or overwrite project files. `/config` reports the effective value and `/keybind` reports only keybindings.

## Worker command blacklists

Meringue can reject selected Pi worker `bash` tool calls before Pi starts the
command. Configure full-command glob patterns under `[commands]`:

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
worker provider is Claude Code or Antigravity, worker startup fails closed with
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

Provisioning a worker runs `git worktree add`, which checks the whole tree out. On a large
monorepo that is minutes of honest work, so the checkout is bounded by how long it goes *quiet*
rather than by how long it runs, with a finite backstop so a bound can never turn into a hang:

```toml
[workspace]
# Budget for short git plumbing (rev-parse, show-ref, worktree list). Default: 60.
git_command_timeout = 60
# Kill `git worktree add` after this many seconds with no output at all. Git reports checkout
# progress on stderr at least once a second, so silence this long means the command is stuck
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

Commands may be either an argv array (recommended) or a shell-quoted string such as `editor_command = "code --reuse-window"`. Strings are split into arguments, but are **never executed by a shell**: redirects, substitutions, pipes, semicolons, and worktree paths cannot become shell code. `editor_args` is a string or array of strings and defaults to `["."]`.

Defaults, in precedence order:

- shell: `MERINGUE_SHELL`, then `SHELL`, then `/bin/sh`;
- editor: `MERINGUE_EDITOR`, then `VISUAL`, then `EDITOR`, then `code`;
- editor args: `["."]`.

The shell is started in a PTY whose current directory is the worker's real worktree directory. Meringue resolves that directory from the worker record (`workspace_path`, then the harness `cwd`, then the recorded workspace plan/worktree root) and always converts it to an absolute path; a relative value is resolved against the recorded project/git root rather than the Meringue process working directory, so a workspace-relative value can never be nested inside an already workspace-rooted cwd. If the recorded directory is gone but its worktree root still exists, the shell opens there and says so; if nothing usable exists, the workspace shows a clear stale-worktree notice instead of opening a shell at a bogus path. It remains alive while switching views or leaving with the workspace `q` command, receives terminal resize events, and is stopped with its process group when explicitly closed or when Meringue exits. Child-process ANSI/SGR colors are preserved by the embedded screen model. It is separate from the managed coding-agent process; terminal cleanup never signals the worker harness pid. Meringue also removes inherited `PI_*` variables so the shell cannot accidentally target the enclosing managed Pi session.

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
# worker_provider = "antigravity" # optional override for worker agents
```

Supported provider names in this slice:

- `pi`
- `claude` for Claude Code (aliases: `claude_code`, `claude-code`, `cc`)
- `antigravity`

CLI flags override `config.toml`:

```bash
bin/meringue tui --harness claude
bin/meringue tui --harness claude_code
bin/meringue tui --head-harness antigravity --worker-harness claude
```

Environment variables override both config and CLI flags:

```bash
MERINGUE_HARNESS=claude bin/meringue tui
MERINGUE_HEAD_HARNESS=antigravity MERINGUE_WORKER_HARNESS=claude bin/meringue tui
```

## Provider sections

Each provider can set its executable command and role-specific extra args.

```toml
[harness.pi]
command = "pi"
session_dir = "~/.meringue/pi-sessions"
# Shared model and backward-compatible thinking fallback:
model = "anthropic/claude-opus-5"
thinking_level = "max"
# Optional role-specific thinking overrides:
# head_thinking_level = "low"
# worker_thinking_level = "max"
head_extra_args = ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--tools", "read,bash,grep,find,ls"]
worker_extra_args = ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--tools", "read,bash,grep,find,ls,edit,write"]

[harness.claude]
command = "claude"
use_json_schema = true
head_extra_args = ["--effort", "high", "--permission-mode", "plan"]
worker_extra_args = ["--effort", "high", "--permission-mode", "acceptEdits"]

[harness.antigravity]
command = "agy"
head_extra_args = []
worker_extra_args = []
```

Pi heads and workers default to `anthropic/claude-opus-5` at Pi's maximum thinking level (`--thinking max`). Use `/thinking head <level>` and `/thinking worker <level>`, or set `head_thinking_level` and `worker_thinking_level`, for distinct role defaults. The existing `/thinking <level>` command and `thinking_level` key remain the shared form; the command also clears role overrides. A role key wins over the shared key, and either scalar wins over a thinking flag in that role's argument array. A configured role array still replaces that role's default array entirely, so include every other flag you need.

A model reference is `<provider>/<model-id>`, split on the first slash, so the model id may itself contain `/` and `:` (`model = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"` is valid). See [`session-settings.md`](session-settings.md#the-accepted-model-reference-grammar) for the exact grammar and for what is still rejected.

`/config` and the dashboard status line show the shared model plus both future Pi thinking levels. `/model` and `/thinking` update only future-session defaults and never rewrite existing sessions. An existing session's own effective pair has no slash command either: it is recorded on the agent record and shown in the focused worker workspace and raw `/state`. See [`session-settings.md`](session-settings.md) for the exact scope and propagation rules.

### Model catalogs and provider resource flags

The `/models` model picker, and the completion list behind `/model`, come from the harness itself rather than a list maintained in Meringue. For Pi, Meringue starts a short-lived ephemeral RPC probe (`pi --mode rpc --no-session`) and reads `get_available_models`.

That probe reuses the configured provider `command`, `env`, `extra_args`, and role `*_extra_args`, minus `--model`/`--thinking`, because provider availability depends on those flags. Two consequences matter when configuring Pi:

- If `worker_extra_args` contains `--no-extensions` and your models come from a Pi extension, the catalog is legitimately empty, and Meringue reports `unavailable` with Pi's own answer instead of inventing entries. Keep the `--extension <path>` flag that registers your provider in the same array (as in the example above) so probes and real sessions agree.
- Model/thinking defaults are dropped from the probe on purpose: an unavailable saved default must not stop Pi from reporting which models exist.

Catalogs are cached in Meringue state under `metadata.harness_model_catalogs.<harness>` and refreshed in the background by reconciliation (about every 10 minutes, retried after about 1 minute when a fetch failed). `/models refresh` (or `Ctrl-R` inside the model picker) forces an immediate re-fetch after you log into a provider, install an extension, or edit `~/.pi/agent/models.json`.

Claude Code runs through `claude --print --output-format stream-json --verbose`; Antigravity runs through `agy --print` and resumes completed turns with `agy --continue` from the worker workspace. Live steer/follow-up prompting is currently Pi-only.

Do not store API keys or secrets in the config file. Prefer each provider CLI's normal auth flow or environment setup.
