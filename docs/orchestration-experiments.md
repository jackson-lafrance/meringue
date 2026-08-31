# Orchestration experiments

Meringue has two orchestration experiments, both changed in **Setup → Experiments** or **Settings → Experiments**:

```toml
[experiments]
self_fixing_workers = false
agent_defaults_mode = "role-specific"   # shared | role-specific | guided
```

## Self-fixing workers

`self_fixing_workers` watches worker records that settle as `errored` or `blocked`. For each eligible worker it can claim at most one recovery attempt and start a follow-up worker on the same issue and workspace lineage. The recovery prompt asks the worker to diagnose the failure and make the smallest safe correction. A focus-preparation failure marker alone is not a worker failure, so it never starts self-fixing recovery; a separate settle failure remains eligible.

Safety is durable rather than process-local:

- a source worker records the recovery claim, attempt count, outcome, and recovery worker id;
- concurrent reconciliation passes converge on the same claim and cannot create duplicates;
- a recovery worker carries a source marker and is never itself eligible for another recovery;
- the automatic budget is one attempt per source worker, including after restart;
- disabling the experiment stops new automatic recovery but does not alter ordinary worker spawning or existing sessions.

A recovery is not a replacement and does not retry the original session. It is an explicit follow-up worker so the original error remains visible and the recovery has a fresh harness session.

## Guided model selection

Guided selection is the third mode of `agent_defaults_mode` rather than a separate toggle. Guidance asks a head to choose each worker's model and reasoning level, which is only meaningful when heads and workers can hold different values, so the two were never independent: `guided` implies role-specific values, and the retired `worker_spawning_guidance` boolean migrates to it.

In guided mode Meringue appends an additional system prompt to new heads. Its text is persisted at `experiments.worker_spawning_guidance_prompt` and is editable through Settings → Experiments, Setup → Experiments, or:

```text
/worker guide "Choose lighter models for routine work and stronger models for ambiguous or high-impact work. Set both model and thinking_level explicitly on every SpawnWorker."
```

The command is accepted only in guided mode. The prompt input row is hidden from both Settings and Setup in the other two modes; the stored value is retained so switching away and back does not lose it. It only guides model and thinking-level selection for workers; it does not change worker defaults or alter ordinary spawn behavior.

The built-in guidance is intentionally task-based rather than tied to one configured model: use lighter choices for routine, bounded work and stronger choices for ambiguous or high-impact work. In guided mode, heads receive a privacy-filtered routing snapshot: configured and effective worker model/thinking defaults are withheld, and the persisted state path is not supplied. Heads must choose from the supplied catalog and set both `model` and `thinking_level` on every guided `SpawnWorker`; the kernel rejects omissions. Direct user-issued worker spawns retain ordinary default behavior.

Inline completion in the composer uses the same catalog and validation conventions as `/model` and `/thinking`:

- type `@` followed by a model query to complete a catalog model reference;
- type `#` followed by a thinking query to complete one of `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.

Selecting a completion only changes the current prompt text. It does not save a default or start a worker; the head decides whether a `SpawnWorker` command should carry the resulting model and `thinking_level` fields. The same completion behavior is available while entering the `/worker guide` command.

With the toggle disabled, no additional system prompt or inline model-selection guidance is added. Existing model catalogs, thinking-level validation, and ordinary worker routing remain unchanged.
