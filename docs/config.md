# Meringue harness config

Meringue reads an optional TOML config file from:

```txt
~/.meringue/config.toml
```

Use `--config PATH` to load a different file for a single run.

## Selecting harnesses

```toml
[harness]
provider = "pi"              # default for heads and workers
# head_provider = "claude"   # optional override for head agents
# worker_provider = "antigravity" # optional override for worker agents
```

Supported provider names in this slice:

- `pi`
- `claude`
- `antigravity`

CLI flags override `config.toml`:

```bash
bin/meringue tui --harness claude
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
command = "antigravity"
head_extra_args = []
worker_extra_args = []
```

Do not store API keys or secrets in the config file. Prefer each provider CLI's normal auth flow or environment setup.
