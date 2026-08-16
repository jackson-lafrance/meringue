# Pi model and thinking settings

Meringue exposes future Pi defaults for how every new head and worker is started. Existing sessions retain their effective settings.

First-run setup (`/setup`, and automatically on a first launch) walks a new user through the same two defaults plus the harness and theme, and applies each choice as the ordinary slash command for it. It reads the cached catalog snapshot only and never blocks on a fetch; see [`onboarding.md`](onboarding.md).

## Commands

### Harness model catalog: the model picker

```text
/models [harness] [refresh]
```

Examples:

```text
/models
/models claude
/models refresh
/models pi refresh
```

`/models` is a **local TUI command** that opens the model picker: a searchable, keyboard-navigable list of the models the selected harness itself reports, showing each model's provider/id reference, display name, and supported thinking levels. With no argument it shows the active harness; an explicit `pi`, `claude`, or `antigravity` scopes the picker (and its refresh) to that harness instead.

It replaced the old behavior, where `/models` printed the entire catalog into the visible log. A harness that reports 120 models produced 120 log lines nobody could act on, truncated with a hint that pointed at a different command.

Picker keys:

| Key | Effect |
| --- | --- |
| any printable character | filter; space separated tokens all have to match (`openai high`) |
| `Backspace` / `Ctrl-W` | delete one character of the filter / clear it |
| `↑` / `↓` | move the highlight (it wraps) |
| `Enter` | apply the highlighted model, exactly as `/model <provider>/<model-id>` |
| `Ctrl-R` | re-fetch the catalog (`GetModelCatalog` with `refresh`), keeping the picker open |
| `Esc`, click away, or any unhandled control key | close the picker without changing anything |

Selecting a row is applied through the normal slash path, so the picker itself writes nothing: `SetDefaultSessionModel` stays the only writer of the future-session default, with the same validation, journaling, and log line as typing `/model` by hand.

A trailing `refresh` word keeps `/models` on the kernel path instead of opening the picker: it forces a re-fetch and reports the snapshot's state (harness, availability, model count, confirmed timestamp, note) in the log. That is also what the picker's `Ctrl-R` submits and what a head proposes for "what models can I use", so `GetModelCatalog` remains the only way the catalog is read.

### Future Pi defaults

```text
/model <provider>/<model-id>
/model head <provider>/<model-id>
/model worker <provider>/<model-id>
/thinking <off|minimal|low|medium|high|xhigh|max>
/thinking head <off|minimal|low|medium|high|xhigh|max>
/thinking worker <off|minimal|low|medium|high|xhigh|max>
```

Examples:

```text
/model openai/gpt-5.6-sol
/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast
/model head openai/gpt-5.6-sol       # only future heads
/model worker anthropic/claude-opus-5 # only future workers
/thinking xhigh          # both roles (backward-compatible shared form)
/thinking head low       # only future heads
/thinking worker max     # only future workers
```

There is no command that only prints the defaults. The dashboard status line keeps `harness: Pi` followed by the compact model/thinking summary described below, and `/config` prints each role's model and thinking level next to the config file they came from. A head can still answer "which model and thinking levels will future agents use" by proposing `GetSessionDefaults`.

`/model` and `/thinking` save values under `[harness.pi]` in Meringue's configured TOML file (normally `~/.meringue/config.toml`). The one-argument `/model <provider>/<model-id>` and `/thinking <level>` forms keep their historical behavior: they update both roles and clear role-specific overrides. The `head` and `worker` forms update only that role, including sessions spawned later in the currently running Meringue process.

A default change does **not** mutate, reconnect, restart, or terminate an existing Pi session. It also strips spawn-only model/thinking defaults when later resuming an existing session, so a resumable session keeps its persisted effective pair. The result and durable kernel log explicitly list existing Pi agent ids left unchanged.

Model defaults must be an exact `<provider>/<model-id>` reference. Thinking defaults must be one of Pi's known levels. A provider extension can add models dynamically, so Meringue validates the model reference *shape* when saving it; the harness performs availability validation when the future session starts. Validation is deliberately independent of the catalog: a valid explicit id is still accepted when the catalog is stale, empty, or unavailable, and an id the catalog does not list is saved and labelled unverified rather than refused.

### Per-worker overrides

A head may put optional `model` and `thinking_level` fields on a `SpawnWorker` payload. They use the same model-reference grammar and thinking-level ladder documented below, but their scope is only the new worker session: they do not update `[harness.pi]`, another worker, a head session, or an existing session. The Pi client removes the configured `--model`/`--thinking` spawn arguments and substitutes only the supplied values for that process.

Omission is meaningful. An omitted field remains late-bound to the configured future-session default when the worker actually starts. This applies to queued workers too, so a worker queued without overrides uses the defaults in force at activation rather than freezing a copy when it was queued. Explicit overrides are persisted as reservation intent and survive deferred activation and provisioning recovery. Before activation a queued worker has no effective `session_settings`; after launch the harness-reported effective pair is stored on the worker record and shown through the existing focused-workspace and `GetInfo` surfaces.

### The accepted model-reference grammar

One place owns this rule (`Meringue::Harness::ModelReference`), and it is the harness's own rule rather than a stricter Meringue invention. Pi resolves a reference by splitting on the **first** slash (`resolveModel` / `findExactModelReferenceMatch`), so Meringue does too:

```text
<provider>/<model-id>
```

- the provider is everything before the first `/`
- the model id is everything after it, and **may itself contain `/` and `:`**

That last point is the whole point. A real Fireworks router model is `fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`: provider `fireworks`, model id `fireworks:accounts/fireworks/routers/glm-5p2-fast`. Meringue used to encode "exactly one slash" twice — a kernel regex (`%r{\A[^/\s]+/[^/\s]+\z}`) and a three-way `split("/", 3)` in the Pi client — which made every such model unsettable from `/model` and unusable from the picker even though Pi lists it, accepts it on `--model`, and reports it back from `get_state`.

What is still rejected is limited to shapes that cannot be a model reference at all, so a typo or a shell-mangled argument cannot silently become the default model:

| Rejected | Reason in the message |
| --- | --- |
| *(empty)* | `a model id is required` |
| `gpt-5.6-sol` | `has no provider prefix` (a bare id is ambiguous across providers) |
| `openai/gpt 5.6`, `openai model` | `contains whitespace, so it is not a single model id` |
| `/gpt-5.6-sol` | `has an empty provider` |
| `openai/` | `has an empty model id` |
| `--model` | `looks like a command-line flag, not a model id` |
| `./models/foo` | `looks like a filesystem path, not a model id` |

Validation is a shape check only; it never consults the catalog. Whether a well-formed id names a model that exists is the harness's answer, and it is reported, not enforced:

```text
Set the default Pi model to openai/gpt-5.6-sol for all future Pi heads and workers. Existing Pi sessions were not changed. Pi's model list (confirmed 2026-07-29T18:55:30Z) does not include openai/gpt-5.6-sol, so the id is unverified; run /models refresh if it should be there. Pi validates it when the next Pi session starts.
```

With no usable catalog at all the same accepted line says `Meringue has no confirmed Pi model list right now, so <reference> is unverified`, which is the degraded/unverified state the picker and completion already describe. A catalog that does not list a model can never make that model unsettable.

Every rejection states its reason in the line the user reads, in the same shape as an invalid thinking level:

```text
Default Pi model was not changed: "glm-5p2-fast" has no provider prefix. Use <provider>/<model-id>, for example openai/gpt-5.6-sol; the model id may itself contain / and :, as in fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast.
```

The old bare `Rejected SetDefaultSessionModel: Default Pi model was not changed.` kept the reason in the `errors` detail only, so a malformed id, an unknown id, and an over-strict rule all looked identical.

### Thinking levels

The accepted ladder is exactly `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, in that order, and it is the same set on every surface: the `/thinking` completion list, kernel validation, and the rejection message all read `Meringue::Harness::PiClient::THINKING_LEVELS`. A completion list that is narrower than what the kernel accepts is a bug — it was the reported one: a proxy provider that omits `max` from its model's `thinkingLevelMap` made `/thinking` hide `max` while `/thinking max` still set the default, so the level in force was missing from its own picker.

The model catalog therefore *labels* levels; it never removes them:

- The saved default is listed first and labelled `current default`, so the three-row popup always shows the level in force.
- A level the model advertises is labelled `supported by <provider/model>`.
- A level it does not advertise stays selectable and is labelled `not listed for <provider/model> · Pi clamps it to <level>`, because Pi clamps an unknown level (up the ladder first, then down, mirroring Pi's `clampThinkingLevel`) rather than failing, and a provider extension can under-declare what its model really supports.
- When the catalog knows nothing about the configured model, every level is labelled `model support not verified yet`.

Setting a level the catalog does not list for the configured default model is accepted and the result says what Pi will actually run:

```text
Set the default Pi thinking level to max for all future Pi heads and workers. Existing Pi sessions were not changed.
Pi's catalog does not list max for anthropic-250k-proxy/claude-opus-5, so future Pi sessions run xhigh instead.
```

A head-proposed `GetSessionDefaults` repeats that caveat for the saved pair, so an inspected default never reads as honoured when Pi will clamp it.

An invalid level names the valid ones instead of only saying nothing changed, and points at the obvious near-miss:

```text
Default Pi thinking level was not changed: "xhi" is not a Pi thinking level. Did you mean xhigh? Valid levels: off, minimal, low, medium, high, xhigh, max.
```

There is no slash command for inspecting one existing session's effective settings. `/session-settings <agent_id>` and its old dashboard `/session <agent_id>` alias were removed, along with the `GetSessionSettings` kernel command they dispatched to, so typing either is now an unknown command. Existing sessions keep their own model and thinking values, and Meringue still records them: see [Authoritative existing-session discovery](#authoritative-existing-session-discovery) for where they are read and displayed.

## Persistence and precedence

The dedicated default fields are:

```toml
[harness.pi]
model = "openai/gpt-5.6-sol"        # compatibility fallback for either omitted role
head_model = "openai/gpt-5.6-sol"
worker_model = "anthropic/claude-opus-5"
thinking_level = "high"        # compatibility fallback for either omitted role
head_thinking_level = "low"
worker_thinking_level = "xhigh"
```

For each role, its dedicated key wins over the shared `model`/`thinking_level` fallback; the shared key then wins over a `--model`/`--thinking` value in that role's extra-argument array. This preserves old configs that use only the shared keys or only role argument arrays. `/model <provider>/<model-id>` and `/thinking <level>` write the shared key and remove both role keys, while the `head` and `worker` forms write only the selected role key. When an older `state.json` has only the shared model in `metadata.pi_session_defaults`, state normalization materializes that value into both role entries while retaining the legacy field.

The dashboard keeps the active harness separate from a compact role-aware summary. It shows `harness: Pi · model: <model> · thinking: <level>` when both roles match; `head model: … · worker model: … · thinking: …` when only models differ; `model: … · head thinking: … · worker thinking: …` when only thinking differs; and `head model: <model> (thinking: <level>) · worker model: <model> (thinking: <level>)` when both differ. The explicit labels keep model ids containing `/` unambiguous. A focused worker workspace labels the effective per-session line as `session settings · model … · thinking …`, so a user can distinguish what a future worker will get from what the selected worker is actually using.

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

That object is refreshed by the normal session paths rather than by a user command: spawning, prompting, and each reconcile poll merge the harness's reported settings back onto the agent record. It is visible in the focused worker workspace (`session settings · model … · thinking …`), in the raw `/state` output, and in the `GetInfo` record for an agent.

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

That list is the model's own declaration, so treat it as description, not permission. A proxy or extension provider can wrap Claude Opus 5 and omit `max` from its `thinkingLevelMap`; Pi then clamps `max` to the closest level it does map instead of failing. Meringue mirrors that clamp (`Meringue::Harness::PiClient.clamp_thinking_level`) to explain what a future session will run, and never uses it to filter the `/thinking` list.

### Caching and refresh

The kernel owns catalog state. Snapshots live in `metadata.harness_model_catalogs.<harness>`, so completion reads a plain hash and never starts a harness process while the user types.

- Session reconciliation refreshes the active harness's snapshot when it is older than 10 minutes, and retries a failed or stale snapshot after 1 minute.
- Cadence is measured from the last fetch *attempt* (`last_attempt_at`), not from `fetched_at`, so a retained list is retried on the failure cadence instead of being re-probed on every 2-second pass because its confirmed timestamp is old.
- Refresh is silent: an expected "not fetched yet" state produces no durable log entries.
- `/models refresh` forces an immediate re-fetch and reports `availability`, the model count, the confirmed timestamp, and the last failed attempt when there is one. `/models` alone opens the picker over the cached snapshot without starting a harness process; `Ctrl-R` in the picker submits the same refresh command.
- The picker never renders an empty box. An unavailable catalog, an unsupported harness, a snapshot Meringue has never fetched, and a filter that matched nothing are four different sentences, each naming what to do next (`Ctrl-R`, or an exact `provider/model` id with `/model`).
- First-run setup reuses those same four sentences on its model step, and adds a permanent `keep the default` row so a catalog that has not arrived yet can never dead-end the flow. Rows appear on their own once a background refresh lands, because state is re-read every frame.

### What completion shows

- `/model <Tab>` lists the active harness's whole catalog.
- Ordering puts the target session's current model first, then the saved future-session default, then models other sessions already use. The rest of the catalog is interleaved across providers rather than grouped, because only a few rows are visible at once and a grouped list would fill the first screen with one provider and imply that is all the harness offers. Labels show why an entry is first (`current session model`, `future-session default`), plus the model name, supported thinking levels, and context window.
- The suggestion popup shows a window of three rows, so a long list is captioned with `1–3 of 119 models · ↑↓ scroll · keep typing to filter`. Without that line a three-row window over a hundred models reads like a three-item list. The caption renders dim on its own row *below* the popup box, so the box itself lists models only and the window keeps all three of its rows.
- Queries match the reference, the bare model id, and the display name, so `sol`, `gpt-5.6`, and `openai/` all narrow the same list.
- `/thinking <Tab>` offers every level the kernel accepts, ordered with the saved default first, and uses the configured default model's catalog entry for the per-level labels described in [Thinking levels](#thinking-levels). It never hides a level a user is allowed to set.
- A `stale` catalog is offered in full, with every entry labelled `last confirmed list` and a trailing note naming the failed refresh, so a temporary harness problem never hides models that exist.
- When no catalog has ever been fetched, completion still offers the references Meringue knows (current session model, saved default, models in use) labelled `catalog unavailable — id not verified`, and appends one non-destructive note row explaining the state and pointing at `/models refresh`. Selecting the note re-inserts only what was already typed, so it can never overwrite a valid explicit id.

Validation is unchanged by catalog state: `/model` requires an exact `<provider>/<model-id>` shape (see [The accepted model-reference grammar](#the-accepted-model-reference-grammar)), and `/thinking` requires one of the seven levels on the ladder. An id the catalog does not list is accepted and labelled unverified. Pi still rejects an unavailable model id at spawn time, and clamps a thinking level the chosen model does not map.
