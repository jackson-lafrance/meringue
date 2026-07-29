# Pi model and thinking settings

Meringue exposes two deliberately separate scopes:

1. **Future Pi defaults** control how every new Pi head and worker is started.
2. **Existing session settings** inspect or change one agent's already-created Pi session.

Changing one scope never silently changes the other.

## Commands

### Future Pi defaults

```text
/defaults
/default-model <provider/model>
/default-thinking <off|minimal|low|medium|high|xhigh|max>
```

Examples:

```text
/defaults
/default-model openai/gpt-5.6-sol
/default-thinking xhigh
```

`/defaults` shows the current future-session pair. `/default-model` and `/default-thinking` save scalar values under `[harness.pi]` in Meringue's configured TOML file (normally `~/.meringue/config.toml`). The values are applied to both future Pi heads and future Pi workers, including sessions spawned later in the currently running Meringue process.

A default change does **not** mutate, reconnect, restart, or terminate an existing Pi session. It also strips spawn-only model/thinking defaults when later resuming an existing session, so a resumable session keeps its persisted effective pair. The result and durable kernel log explicitly list existing Pi agent ids left unchanged. Use the targeted commands below if an existing session should move to the same value.

Model defaults must be an exact `provider/model` reference. Thinking defaults must be one of Pi's known levels. A provider extension can add models dynamically, so Meringue validates the model reference shape when saving it; Pi performs model availability validation when the future session starts.

### One existing Pi session

```text
/session-settings <agent_id>
/model <agent_id> <provider/model>
/thinking <agent_id> <off|minimal|low|medium|high|xhigh|max>
```

Examples:

```text
/session-settings P1-I18-W1
/model P1-I18-W1 openai/gpt-5.6-sol
/thinking P1-I18-W1 xhigh
```

`/session-settings` refreshes and displays the effective pair reported by one existing agent's active or resumable Pi session. This clearer name replaces the ambiguous dashboard `/session`; `/session <agent_id>` remains a hidden compatibility alias, but help and completion advertise `/session-settings`. Inside a focused worker workspace, the separate command for opening the selected harness UI is now advertised as `/open-session`; its old argumentless `/session` spelling is also only a compatibility alias.

`/model` and `/thinking` update only that existing session. They do not edit Meringue config or future-session defaults. Updates use Pi RPC `set_model` and `set_thinking_level`, re-read `get_state`, and persist the effective values Pi reports. Thinking changes are checked against Pi's `get_available_thinking_levels`, so an unsupported level is rejected instead of silently clamped. Pi rejects unavailable model ids.

Settings cannot be changed while the target Pi turn is streaming or while another Meringue process owns its RPC transport. A settled persisted Pi session is resumed automatically before applying an update. Missing, killed, and non-Pi sessions return explicit errors.

## Persistence and precedence

The dedicated default fields are:

```toml
[harness.pi]
model = "openai/gpt-5.6-sol"
thinking_level = "xhigh"
```

Meringue appends these scalar values after configured `head_extra_args` and `worker_extra_args`, making the saved app-wide defaults authoritative while preserving role-specific tools, extensions, and other Pi flags. Older configs that specify model/thinking only inside role argument arrays continue to work. If those arrays disagree by role and no scalar values are set, `/defaults` reports the role-specific values as mixed; setting either dedicated default begins converging that field for both roles.

The dashboard status line shows `Pi defaults: <model> · <thinking>` separately from the active harness. A focused worker workspace labels the effective per-session line as `session settings · model … · thinking …`, so a user can distinguish what a future worker will get from what the selected worker is actually using.

## Authoritative existing-session discovery

Meringue records effective session settings in a harness-neutral `session_settings` object on each agent:

```json
{
  "model": {
    "provider": "openai",
    "id": "gpt-5.6-sol",
    "reference": "openai/gpt-5.6-sol",
    "name": "GPT-5.6 Sol"
  },
  "thinking_level": "xhigh",
  "availability": "available",
  "source": "live_session_state"
}
```

For a live Pi RPC process, Meringue reads `model` and `thinkingLevel` from Pi's `get_state` response. It never substitutes spawn arguments or Meringue defaults for an effective session value.

For a resumable process whose RPC transport is unavailable, Pi's persisted JSONL session is authoritative. Meringue walks the current branch and reads `model_change` and `thinking_level_change` entries. An assistant message's provider/model is only a fallback for older session files. If Pi persisted no thinking level, Meringue reports `unknown` rather than guessing.

Codex, Claude Code, and other harnesses can implement the same generic client operations later. They currently return an explicit unsupported result; Meringue does not infer their session settings from command-line arguments.
