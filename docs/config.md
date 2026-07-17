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

`color_scheme` is accepted as a compatibility alias for `colorscheme`. Running `/theme <name>` writes a single `colorscheme` value and removes the older `color_scheme` alias from the `[tui]` section.

## Customizing TUI keybindings

Keybindings live alongside the theme under `[tui.keybindings]`. Each key is an action name and each value is a string or array of strings. Omitted actions keep the built-in defaults; an empty array intentionally unbinds that action; unknown actions or invalid key names are ignored so defaults continue to work.

```toml
[tui.keybindings]
# Vim-style jump navigation while keeping all other defaults.
agent_select_previous = ["k", "up", "left"]
agent_select_next = ["j", "down", "right"]
open_pr = ["o"]

# Example: submit with Ctrl-X and insert newlines with Ctrl-N.
# submit = ["ctrl-x"]
# newline = ["ctrl-n"]
```

Supported action names:

- `quit`
- `clear_or_quit`
- `cancel_navigation`
- `focus_next`, `focus_previous`
- `scroll_up`, `scroll_down`, `scroll_page_up`, `scroll_page_down`
- `submit`, `newline`
- `complete_suggestion`, `suggestion_previous`, `suggestion_next`
- `cursor_left`, `cursor_right`, `cursor_up`, `cursor_down`, `cursor_home`, `cursor_end`, `cursor_word_left`, `cursor_word_right`
- `delete_backward`, `delete_forward`, `delete_word_backward`, `delete_word_forward`
- `agent_select_previous`, `agent_select_next`, `open_pr`

Common key names include `enter`, `shift-enter`, `tab`, `shift-tab`, `ctrl-tab`, `escape`, arrow keys (`up`, `down`, `left`, `right`), `home`, `end`, `page-up`, `page-down`, `backspace`, `delete`, `ctrl-a` through `ctrl-z`, `alt-left`, `alt-right`, `ctrl-left`, `ctrl-right`, `alt-backspace`, `ctrl-backspace`, `alt-delete`, `ctrl-delete`, `space`, and single printable characters like `j` or `p`. Advanced users can bind a raw terminal sequence with `raw:<sequence>`; literal `\\e` inside that string is converted to Escape.

Use `/keybind` in the TUI to show the active keybindings after config has been loaded.

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
head_extra_args = ["--thinking", "high", "--tools", "read,bash,grep,find,ls"]
worker_extra_args = ["--thinking", "high", "--tools", "read,bash,grep,find,ls,edit,write"]

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

Claude Code runs through `claude --print --output-format stream-json --verbose`; Antigravity runs through `agy --print` and resumes completed turns with `agy --continue` from the worker workspace. Live steer/follow-up prompting is currently Pi-only.

Do not store API keys or secrets in the config file. Prefer each provider CLI's normal auth flow or environment setup.
