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
# worker_provider = "gemini" # optional override for worker agents
```

Supported provider names in this slice:

- `pi`
- `claude`
- `gemini`

CLI flags override `config.toml`:

```bash
bin/meringue tui --harness claude
bin/meringue tui --head-harness gemini --worker-harness claude
```

Environment variables override both config and CLI flags:

```bash
MERINGUE_HARNESS=claude bin/meringue tui
MERINGUE_HEAD_HARNESS=gemini MERINGUE_WORKER_HARNESS=claude bin/meringue tui
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

[harness.gemini]
command = "gemini"
output_format = "json"   # passed as --output-format; set to "" to omit
prompt_flag = "-p"        # Gemini CLI prompt option
resume_flag = "--resume" # Gemini CLI session resume option
head_extra_args = []
worker_extra_args = []
```

The Gemini backend uses one non-interactive Gemini CLI process per turn. Meringue stores the generic harness session id reported by the CLI when available and uses `resume_flag` for follow-up prompts and `/jump` terminal resumes. Live steering while a Gemini process is still running is not supported yet; prompt after the current turn settles.

Do not store API keys or secrets in the config file. Prefer each provider CLI's normal auth flow or environment setup.
