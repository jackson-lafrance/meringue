# Recounting AgentTree IDs

`/recount` compacts user-facing AgentTree numbering after `/prune`, killed-record reconciliation, or another removal leaves gaps. It is a kernel command: the kernel computes the complete mapping in memory and persists the updated state with the state store's atomic file replacement.

## What is renumbered

Records keep their existing numeric creation order within each scope:

- Projects are compacted globally (`P2`, `P4` becomes `P1`, `P2`).
- Issues are compacted independently inside each project (`P1-I2`, `P1-I3` becomes `P1-I1`, `P1-I2`). A project rename also changes the project prefix.
- Workers are compacted independently inside each issue (`...-W2`, `...-W3` becomes `...-W1`, `...-W2`). Project and issue prefix changes flow into worker IDs.
- Questions are compacted globally (`Q2`, `Q4` becomes `Q1`, `Q2`).
- Goals are compacted globally (`G2`, `G4` becomes `G1`, `G2`). A goal's project/issue links, its recorded attempt worker ids, and its iteration history follow the renumbering, and the goal counter is rebuilt with the others.

## Referential integrity

A rename is only correct if every place that stores a renamed ID moves with it, so the rewrite walks the **whole state document** and rewrites every reference-shaped field it finds (`id`, `*_id`, `*_ids`, in any casing, at any nesting depth) instead of maintaining a per-record list of known fields. That covers, among others:

- Queued/deferred worker chains: the flat `after_agent_id` **and** the nested `harness_metadata.deferred_spawn` copy (`after_agent_id`, `after_agent_issue_id`), so a worker queued behind another worker still activates after a renumber.
- Worker lineage: `follow_up_of_agent_id`, `follow_up_agent_ids`, `replaces_agent_id`, `replaced_by_agent_id`, plus the `replace_agent_id`/`follow_up_of_agent_id` copies inside `harness_metadata`.
- Issues: `project_id`, `parent_issue_id`, `agent_ids`, `last_agent_id`, `originating_head_id`, and delivery pull-request records.
- Questions: `head_id` (never renamed), `project_id`, `issue_id`.
- Goals: `project_id`, `issue_id`, `active_worker_id`, `last_worker_id`, `question_id`, and every iteration's `attempt_worker_id`.
- Logs: `source_id` and the structured routing hash in `details` (`project_id`, `issue_id`, `agent_id`, `after_agent_id`, and friends), which is what groups a log line under its record in the AgentTree, the focused pane, and `GetInfo`.
- Persisted chat messages: `conversation.messages[].source_id`. Recount owns the whole snapshot for its write, so this rename is not merged away by the normal chat-buffer preservation. A running TUI keeps its own in-memory copy of that buffer and does not reload it after a recount, so its live chat rows can still carry pre-recount routing until it restarts; that is a rendering concern, not a state concern.
- Free-form harness metadata: `rerouted_from_issue_id`, `retry_of_head_id`, the head command journal and persisted head result payloads (a head retry re-runs those payloads, so they must point at live records), workspace cleanup bookkeeping, pending prompts, and the agent-workspace selection in `ui`.

Worker relationship links whose target was already removed are cleared rather than being allowed to point at a newly reused ID. Project, issue, and worker counters are rebuilt from the resulting tree, so the next created entity receives the number after the compacted range.

### Validation, and what happens when something is missed

The pass runs on a copy of state and is swapped in only after validation passes, so a rename that cannot be completed correctly is never persisted. Validation rejects duplicate IDs, an issue/worker/goal whose project or issue no longer resolves, a queued worker whose two copies of its dependency disagree, and — as a catch-all — **any stored ID that resolved before the pass but does not resolve after it**, naming the value and the path that holds it. A future field that stores an ID under a key the rewriter does not recognise therefore fails the command loudly instead of silently stranding a reference.

References that were *already* dangling before the pass (a log entry about a pruned worker, a lineage link to a removed session) are the only tolerated unresolved values: renumbering cannot resurrect a removed record, and refusing to run would make `/recount` permanently unusable. Because numbering is compacted, such a stale reference can coincidentally match a reused ID afterwards; that is inherent to renumbering, which is why the mapping is recorded in state and in the log.

Active worker records may be renumbered. Their PID, harness session ID/file, workspace path, branch, and all other opaque session fields remain unchanged. Completion waits and session reconciliation resolve the worker by its session identity, so an in-flight worker continues to update the renamed record. Recount is serialized behind worker spawning, so it cannot invalidate a reservation while workspace or harness provisioning is in progress.

## What is not renumbered

- Human-readable text is history and is left verbatim, including IDs embedded in log messages, chat text, prompts, worker titles, and question/answer text. A line such as "Queued worker P2-I2-W3 to start after P2-I2-W2 settles" was true when it was written; the pass records the old-to-new mapping (in the recount log entry and `metadata.last_recount`) so an old line can be translated, rather than rewriting the record of what happened. Only structured references are rewritten.
- The record of a *previous* rename is history too: `metadata.last_recount` and any `mappings` hash in log details are never renumbered again, so their old-to-new pairs stay readable.
- Composite correlation IDs that embed a record ID are preserved verbatim, because they are only ever compared against copies of themselves and never resolved back to a record: pending prompt IDs (`<agent id>-PP1`), goal attempt command IDs (`<goal id>-IT2-ATTEMPT`), and session restart command IDs (`session-restart-<agent id>-1`). Rewriting one copy and not another would break exactly-once dedupe, which is worse than a stale-looking key.
- Head IDs are transient command-correlation IDs. They and the head counter are not changed. Recount is refused while another head record is awaiting application, because that result was produced against the pre-recount state snapshot. The head that proposed the recount is not counted as a blocker: a head may run `/recount` for the user ("renumber the tree"), and the kernel applies it exactly like the typed command. Because renaming happens immediately, a head should propose `Recount` alone or last, never mixed with commands that reference ids which are about to change.
- Log IDs remain append-only. Existing log messages remain historical text; only structured `source_id` and ID fields in `details` are updated when they refer to a retained record.
- Conversation message IDs remain unchanged.
- Harness session IDs/files, PIDs, workspace paths/branches, pull-request identifiers/URLs, and other external identifiers remain unchanged.

The command appends one kernel log containing the old-to-new mappings and stores the latest mapping under `metadata.last_recount`. Its result also returns the mappings and rebuilt counters.

## Usage

Run this in the interactive TUI:

```text
/recount
```

A plain-language request such as "renumber the tree" or "compact the ids after that prune" is routed by a head agent to the same kernel command.

Use `/state` afterward to inspect the mappings and counters, or `/tree` to inspect the compacted hierarchy.
