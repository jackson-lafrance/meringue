# Meringue config

Meringue reads an optional TOML config file from:

```txt
~/.meringue/config.toml
```

Use `--config PATH` to load a different file for a single run.

The interactive TUI can update this file for theme changes with `/theme <name>`.

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

Every colorscheme also defines an eight-color agent palette used to color agent rows in the logs pane. Each agent id is hashed to one palette slot, so the same head or worker always renders in the same color for a given theme. Heads use a bold `◆`, workers use `✦`, completed results use `✓`, actionable warnings/errors use `!`, and kernel/command logs keep the theme accent with `▪`. Set `NO_COLOR=1` to render the TUI without color; icons, explicit ids, status text, and the `▌` gutter still separate agent output from kernel logs.

`color_scheme` is accepted as a compatibility alias for `colorscheme`. Running `/theme <name>` writes a single `colorscheme` value and removes the older `color_scheme` alias from the `[tui]` section.

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
- `focus_next`, `focus_previous`
- `scroll_up`, `scroll_down`, `scroll_page_up`, `scroll_page_down`
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

`logs_selection_mode` defaults to `["alt-v"]` and toggles the keyboard selection cursor while the logs pane is focused. Inside that mode the `cursor_*` and `scroll_page_*` actions move the cursor and the `select_*` actions extend the selection, so rebinding those actions changes both the composer and the logs pane. See `docs/keybindings.md` for the selection and clipboard behavior.

Common key names include `enter`, `shift-enter`, `tab`, `shift-tab`, `ctrl-tab`, `escape`, arrow keys (`up`, `down`, `left`, `right`), `shift-left`, `shift-right`, `shift-up`, `shift-down`, `shift-home`, `shift-end`, `shift-alt-left`, `shift-alt-right`, `shift-ctrl-left`, `shift-ctrl-right`, `shift-page-up`, `shift-page-down`, `home`, `end`, `page-up`, `page-down`, `backspace`, `delete`, `ctrl-space`, `ctrl-a` through `ctrl-z`, `alt-c`, `alt-v`, `alt-left`, `alt-right`, `ctrl-left`, `ctrl-right`, `alt-backspace`, `ctrl-backspace`, `alt-delete`, `ctrl-delete`, `space`, and single printable characters like `j` or `p`. Advanced users can bind a raw terminal sequence with `raw:<sequence>`; literal `\\e` inside that string is converted to Escape.

Use `/keybind` in the TUI to show the active keybindings after config has been loaded.

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

Commands may be either an argv array (recommended) or a shell-quoted string such as `editor_command = "code --reuse-window"`. Strings are split into arguments, but are **never executed by a shell**: redirects, substitutions, pipes, semicolons, and worktree paths cannot become shell code. `editor_args` is a string or array of strings and defaults to `["."]`.

Defaults, in precedence order:

- shell: `MERINGUE_SHELL`, then `SHELL`, then `/bin/sh`;
- editor: `MERINGUE_EDITOR`, then `VISUAL`, then `EDITOR`, then `code`;
- editor args: `["."]`.

The shell is started in a PTY whose current directory is the worker's real worktree directory. Meringue resolves that directory from the worker record (`workspace_path`, then the harness `cwd`, then the recorded workspace plan/worktree root) and always converts it to an absolute path; a relative value is resolved against the recorded project/git root rather than the Meringue process working directory, so a workspace-relative value can never be nested inside an already workspace-rooted cwd. If the recorded directory is gone but its worktree root still exists, the shell opens there and says so; if nothing usable exists, the workspace shows a clear stale-worktree notice instead of opening a shell at a bogus path. It remains alive while switching views or leaving with the workspace `q` command, receives terminal resize events, and is stopped with its process group when explicitly closed or when Meringue exits. Child-process ANSI/SGR colors are preserved by the embedded screen model. It is separate from the managed coding-agent process; terminal cleanup never signals the worker harness pid. Meringue also removes inherited `PI_*` variables so the shell cannot accidentally target the enclosing managed Pi session.

The editor command is spawned directly with the worktree as both its current directory and, by default, the `.` argument. GUI editor CLIs normally detach or reuse an existing window. For a terminal-only editor, configure a terminal-emulator wrapper as the command (for example, an Alacritty command ending in `-e nvim`) so the editor has its own terminal. A missing executable, invalid command/argument type, malformed quoting, or removed worktree is reported in the workspace rather than crashing Meringue or mutating agent state.

The focused `a` action reuses Meringue's existing external session opener: it validates the worker's persisted harness session (for Pi, the session file, or discovery from the saved session ID), then launches the configured harness command in Alacritty at the worker worktree. `[terminal].alacritty_command`, `[harness.pi].command`, and `[harness.pi].session_dir` apply. The detached external UI does not replace, attach to, signal, or transfer ownership of Meringue's managed RPC process, and opening failures or missing/malformed session history are reported in the focused workspace without changing the worker record.

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

Pi heads and workers default to `anthropic/claude-opus-5` at Pi's maximum thinking level (`--thinking max`). To use a different model or thinking level, set `head_extra_args` / `worker_extra_args` for `[harness.pi]`; a configured array replaces the default array entirely, so include the other flags you still want.

Claude Code runs through `claude --print --output-format stream-json --verbose`; Antigravity runs through `agy --print` and resumes completed turns with `agy --continue` from the worker workspace. Live steer/follow-up prompting is currently Pi-only.

Do not store API keys or secrets in the config file. Prefer each provider CLI's normal auth flow or environment setup.
