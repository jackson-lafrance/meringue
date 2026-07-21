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
- `agent_select_previous`, `agent_select_next`

Common key names include `enter`, `shift-enter`, `tab`, `shift-tab`, `ctrl-tab`, `escape`, arrow keys (`up`, `down`, `left`, `right`), `home`, `end`, `page-up`, `page-down`, `backspace`, `delete`, `ctrl-a` through `ctrl-z`, `alt-left`, `alt-right`, `ctrl-left`, `ctrl-right`, `alt-backspace`, `ctrl-backspace`, `alt-delete`, `ctrl-delete`, `space`, and single printable characters like `j` or `p`. Advanced users can bind a raw terminal sequence with `raw:<sequence>`; literal `\\e` inside that string is converted to Escape.

Use `/keybind` in the TUI to show the active keybindings after config has been loaded.

## Selecting harnesses

```toml
[harness]
provider = "pi"              # default for heads and workers
# head_provider = "river"    # optional override for head agents
# worker_provider = "claude" # optional override for worker agents
```

Supported provider names in this slice:

- `pi`
- `river` (aliases: `river-agent`, `river_agent`)
- `claude` for Claude Code (aliases: `claude_code`, `claude-code`, `cc`)
- `antigravity`

CLI flags override `config.toml`:

```bash
bin/meringue tui --harness river
bin/meringue tui --harness claude_code
bin/meringue tui --head-harness river --worker-harness claude
```

Environment variables override both config and CLI flags:

```bash
MERINGUE_HARNESS=river bin/meringue tui
MERINGUE_HEAD_HARNESS=river MERINGUE_WORKER_HARNESS=claude bin/meringue tui
```

## Provider sections

Each provider can set its executable command and role-specific extra args.

```toml
[harness.pi]
command = "pi"
session_dir = "~/.meringue/pi-sessions"
head_extra_args = ["--thinking", "high", "--tools", "read,bash,grep,find,ls"]
worker_extra_args = ["--thinking", "high", "--tools", "read,bash,grep,find,ls,edit,write"]

[harness.river]
command = "river-agent"
session_dir = "~/.meringue/river-sessions"
head_extra_args = ["--tools", "read,bash,grep,find,ls", "--no-context-files"]
worker_extra_args = ["--no-context-files"]

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

Claude Code runs through `claude --print --output-format stream-json --verbose`; Antigravity runs through `agy --print` and resumes completed turns with `agy --continue` from the worker workspace. Pi and River support live steer/follow-up prompts through Pi RPC.

### River setup and behavior

River's official `river-agent` launcher configures and then execs Pi. It deliberately passes trailing Pi arguments through, so Meringue uses River's own model, system prompts, skills, and extensions while adding Pi RPC mode and a dedicated `session_dir`. Session IDs, persisted JSONL files, reconnects, aborts, queued prompts, and terminal resume therefore have the same behavior as the Pi integration, but agents are recorded with `harness = "river"`.

The default head args use a read-only tool allowlist. Worker args intentionally do not set `--tools`, because River applies that flag to extension and custom tools as well as built-ins; omitting it preserves River's configured worker capabilities.

Install River using its normal distribution and verify the launcher is on `PATH`:

```bash
river-agent --version
river-agent --dry-run
```

For Shopify's TEC distribution, River's official documentation uses the zone runner:

```bash
tec run //system/river/agent -- --version
tec run //system/river/agent -- --dry-run
```

You can configure that runner directly when `river-agent` is not installed on `PATH`. This is slower because TEC resolves the package for every spawned process:

```toml
[harness.river]
command = ["tec", "run", "-q", "//system/river/agent", "--"]
session_dir = "~/.meringue/river-sessions"
```

If your River distribution provides an install command or stable wrapper, prefer placing that `river-agent` executable on `PATH` and keeping `command = "river-agent"`.

`extra_args`, `head_extra_args`, and `worker_extra_args` are Pi passthrough arguments. Put River launcher options such as `--feature`, `--model`, `--thinking`, or `--isolate-skills` in `command` so they appear before Meringue's `--mode rpc` passthrough begins:

```toml
[harness.river]
command = ["river-agent", "--feature", "debug"]
```

Meringue does not copy River credentials. Keep using River's normal authentication/environment setup. Do not store API keys or secrets in this config file.
