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
- `workspace_switch_view`, `workspace_open_editor`
- `scroll_up`, `scroll_down`, `scroll_page_up`, `scroll_page_down`
- `submit`, `newline`
- `complete_suggestion`, `suggestion_previous`, `suggestion_next`
- `cursor_left`, `cursor_right`, `cursor_up`, `cursor_down`, `cursor_home`, `cursor_end`, `cursor_word_left`, `cursor_word_right`
- `delete_backward`, `delete_forward`, `delete_word_backward`, `delete_word_forward`
- `agent_select_previous`, `agent_select_next`

Common key names include `enter`, `shift-enter`, `tab`, `shift-tab`, `ctrl-tab`, `escape`, arrow keys (`up`, `down`, `left`, `right`), `home`, `end`, `page-up`, `page-down`, `backspace`, `delete`, `ctrl-a` through `ctrl-z`, `alt-left`, `alt-right`, `ctrl-left`, `ctrl-right`, `alt-backspace`, `ctrl-backspace`, `alt-delete`, `ctrl-delete`, `space`, and single printable characters like `j` or `p`. Advanced users can bind a raw terminal sequence with `raw:<sequence>`; literal `\\e` inside that string is converted to Escape.

Use `/keybind` in the TUI to show the active keybindings after config has been loaded.

## Worker workspace terminal and editor

The focused worker workspace has mutually exclusive agent and terminal views. `Ctrl-T` switches between them; terminal input goes only to the workspace shell while that view is active. `Ctrl-E` opens the selected worker's assigned worktree in an external editor. Both actions can be rebound:

```toml
[tui.keybindings]
workspace_switch_view = ["ctrl-t"]
workspace_open_editor = ["ctrl-e"]
```

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

The shell is started in a PTY whose current directory is the worker's persisted `workspace_path`. It remains alive while switching back to the agent view, receives terminal resize events, and is stopped with its process group when Meringue exits. It is separate from the managed coding-agent process; terminal cleanup never signals the worker harness pid.

The editor command is spawned directly with the worktree as both its current directory and, by default, the `.` argument. GUI editor CLIs normally detach or reuse an existing window. For a terminal-only editor, configure a terminal-emulator wrapper as the command (for example, an Alacritty command ending in `-e nvim`) so the editor has its own terminal. A missing executable, invalid command/argument type, malformed quoting, or removed worktree is reported in the workspace rather than crashing Meringue or mutating agent state.

Supported workspace action names:

- `workspace_switch_view`
- `workspace_open_editor`

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
