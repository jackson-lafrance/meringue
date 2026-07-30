# Pi model and thinking settings

Meringue exposes two deliberately separate scopes:

1. **Future Pi defaults** control how every new Pi head and worker is started.
2. **Existing session settings** inspect or change one agent's already-created Pi session.

Changing one scope never silently changes the other.

## Commands

### Harness model catalog

```text
/models [harness] [refresh]
```

Examples:

```text
/models
/models pi
/models refresh
```

`/models` lists every model the selected harness reports, with each model's supported thinking levels and context window. With no argument it uses the active harness; an explicit `pi`, `claude`, or `antigravity` inspects that harness instead. A trailing `refresh` forces a re-fetch instead of reusing the cached snapshot.

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

Model defaults must be an exact `provider/model` reference. Thinking defaults must be one of Pi's known levels. A provider extension can add models dynamically, so Meringue validates the model reference shape when saving it; Pi performs model availability validation when the future session starts. Validation is deliberately independent of the catalog: a valid explicit id is still accepted when the catalog is stale, empty, or unavailable.

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

## Authoritative model catalog discovery

The model selector offers every model the selected harness reports, not just the values Meringue has already observed on a session.

Discovery is harness-neutral. A harness client answers `available_models`, and Meringue normalizes that answer into a `Meringue::Harness::ModelCatalog` snapshot:

```json
{
  "harness": "pi",
  "availability": "available",
  "model_count": 119,
  "source": "pi_rpc_get_available_models",
  "fetched_at": "2026-07-29T18:55:30Z",
  "models": [
    {
      "reference": "anthropic/claude-opus-5",
      "provider": "anthropic",
      "id": "claude-opus-5",
      "name": "Claude Opus 5",
      "thinking_levels": ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
      "reasoning": true,
      "context_window": 1000000,
      "max_tokens": 128000
    }
  ]
}
```

`availability` is one of:

- `available`: the harness answered with at least one model.
- `stale`: a previously confirmed list whose newest refresh failed. The models are kept, `fetched_at` still marks when the harness confirmed them, and `last_attempt_at`/`last_error`/`note` describe the failed attempt.
- `unavailable`: the harness answered with an empty list (`reason: "empty_catalog"`) or could not be reached (`reason: "fetch_failed"`) and there is no earlier list to keep, with `note` carrying the harness's own explanation.
- `unsupported`: the harness has no catalog API yet (Claude Code and Antigravity today), or this Meringue instance was built without a catalog source.

A failed or empty refresh never shrinks a working list. Without that rule one harness hiccup (a restart, a provider auth blip, a sleeping laptop) would replace a full catalog with an empty one, and the selector would silently fall back to the two or three references Meringue remembers from config and existing sessions — which looks exactly like discovery never worked.

### How Pi answers

Pi exposes its catalog per process, not per session, so Meringue starts a short-lived ephemeral probe (`pi --mode rpc --no-session`), sends RPC `get_available_models`, and terminates it. The probe never touches a worker's RPC transport, writes no session file, and reuses the configured Pi `command`, `env`, and role args minus `--model`/`--thinking`. See [`config.md`](config.md#model-catalogs-and-provider-resource-flags) for why those resource flags matter.

Each model's thinking levels are derived with Pi's own rule (`getSupportedThinkingLevels`): a model without reasoning support reports `["off"]`, a level mapped to `null` is excluded, and `xhigh`/`max` appear only when the model explicitly maps them. Meringue keeps no hand-maintained model or level table.

### Caching and refresh

The kernel owns catalog state. Snapshots live in `metadata.harness_model_catalogs.<harness>`, so completion reads a plain hash and never starts a harness process while the user types.

- Session reconciliation refreshes the active harness's snapshot when it is older than 10 minutes, and retries a failed or stale snapshot after 1 minute.
- Cadence is measured from the last fetch *attempt* (`last_attempt_at`), not from `fetched_at`, so a retained list is retried on the failure cadence instead of being re-probed on every 2-second pass because its confirmed timestamp is old.
- Refresh is silent: an expected "not fetched yet" state produces no durable log entries.
- `/models refresh` forces an immediate re-fetch; `/models` alone reuses a fresh snapshot. `/models` reports `availability`, the confirmed timestamp, and the last failed attempt when there is one.

### What completion shows

- `/default-model <Tab>` lists the active harness's whole catalog. `/model <agent_id> <Tab>` lists the catalog of that agent's harness, so a Claude worker is never offered Pi-only ids.
- Ordering puts the target session's current model first, then the saved future-session default, then models other sessions already use. The rest of the catalog is interleaved across providers rather than grouped, because only a few rows are visible at once and a grouped list would fill the first screen with one provider and imply that is all the harness offers. Labels show why an entry is first (`current session model`, `future-session default`), plus the model name, supported thinking levels, and context window.
- The suggestion popup shows a window of three rows, so a long list ends with `1–3 of 119 models · ↑↓ to scroll · keep typing to filter`. Without that line a three-row window over a hundred models reads like a three-item list.
- Queries match the reference, the bare model id, and the display name, so `sol`, `gpt-5.6`, and `openai/` all narrow the same list.
- `/thinking <agent_id> <Tab>` and `/default-thinking <Tab>` offer only the levels the relevant model supports. When the model is unknown to the catalog, Meringue falls back to Pi's full ladder and labels it `model support not verified yet`.
- A `stale` catalog is offered in full, with every entry labelled `last confirmed list` and a trailing note naming the failed refresh, so a temporary harness problem never hides models that exist.
- When no catalog has ever been fetched, completion still offers the references Meringue knows (current session model, saved default, models in use) labelled `catalog unavailable — id not verified`, and appends one non-destructive note row explaining the state and pointing at `/models`. Selecting the note re-inserts only what was already typed, so it can never overwrite a valid explicit id.

Validation is unchanged by catalog state: `/model` and `/default-model` still require an exact `provider/model` shape, and Pi still rejects an unavailable model id or an unsupported thinking level.
