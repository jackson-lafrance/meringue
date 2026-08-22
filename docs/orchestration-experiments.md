# Orchestration experiments

Meringue has two independent, opt-in orchestration experiments. Both are off by default and can be changed in **Setup → Experiments** or **Settings → Experiments**:

```toml
[experiments]
self_fixing_workers = false
worker_spawning_guidance = false
```

## Self-fixing workers

`self_fixing_workers` watches worker records that settle as `errored` or `blocked`. For each eligible worker it can claim at most one recovery attempt and start a follow-up worker on the same issue and workspace lineage. The recovery prompt asks the worker to diagnose the failure and make the smallest safe correction.

Safety is durable rather than process-local:

- a source worker records the recovery claim, attempt count, outcome, and recovery worker id;
- concurrent reconciliation passes converge on the same claim and cannot create duplicates;
- a recovery worker carries a source marker and is never itself eligible for another recovery;
- the automatic budget is one attempt per source worker, including after restart;
- disabling the experiment stops new automatic recovery but does not alter ordinary worker spawning or existing sessions.

A recovery is not a replacement and does not retry the original session. It is an explicit follow-up worker so the original error remains visible and the recovery has a fresh harness session.

## Worker model selection guidance

`worker_spawning_guidance` appends an additional system prompt to new heads. Its text is persisted at `experiments.worker_spawning_guidance_prompt` and is editable through Settings → Experiments, Setup → Experiments, or:

```text
/worker guide "For implementation use @openai/gpt-5.6-luna #xhigh; for investigation use @openai/gpt-5.6-sol."
```

The command is accepted only while the experiment is enabled. The prompt input row is hidden from both Settings and Setup while it is disabled; the stored value is retained so disabling and re-enabling does not lose it. It only guides model and thinking-level selection for workers; it does not change worker defaults or alter ordinary spawn behavior.

The guidance prefers a fresh worker for each distinct task where practical because worker context grows quickly. It gives task-oriented examples such as using `@openai/gpt-5.6-luna` with `#xhigh` thinking for implementation and `@openai/gpt-5.6-sol` for investigation. The examples are catalog references, not a hard-coded allowlist.

Inline completion in the composer uses the same catalog and validation conventions as `/model` and `/thinking`:

- type `@` followed by a model query to complete a catalog model reference;
- type `#` followed by a thinking query to complete one of `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.

Selecting a completion only changes the current prompt text. It does not save a default or start a worker; the head decides whether a `SpawnWorker` command should carry the resulting model and `thinking_level` fields. The same completion behavior is available while entering the `/worker guide` command.

With the toggle disabled, no additional system prompt or inline model-selection guidance is added. Existing model catalogs, thinking-level validation, and ordinary worker routing remain unchanged.
