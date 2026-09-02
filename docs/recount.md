# Recounting AgentTree IDs

`/recount` compacts user-facing AgentTree numbering after `/prune`, killed-record reconciliation, or another removal leaves gaps. It is a kernel command: the kernel computes the complete mapping in memory and persists the updated state with the state store's atomic file replacement.

Compacting reuses IDs. The worker that was `P2-I2-W1` may be gone, and an unrelated live worker can hold that ID immediately afterwards, so the pass is only correct if **everything already written about a record follows the record**. Renumbering therefore resolves every AgentTree ID in state, including the ones embedded in text, and never leaves a stale spelling behind that a compacted ID inherits *in this pass*. Text that only looks like an ID and names no record before or after the pass (`Prepare Q3 revenue report`) is left exactly as written.

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
- Persisted chat messages: `conversation.messages[].source_id` and the message text. Recount owns the whole snapshot for its write, so this rename is not merged away by the normal chat-buffer preservation, and the TUI reloads its own in-memory copy of the buffer when it sees the accepted result, so a running session cannot write the pre-recount spelling back.
- Free-form harness metadata: `rerouted_from_issue_id`, `retry_of_head_id`, the head command journal and persisted head result payloads (a head retry re-runs those payloads, so they must point at live records), workspace cleanup bookkeeping, pending prompts, and the agent-workspace selection in `ui`.

Worker relationship links whose target was already removed are cleared rather than being allowed to point at a newly reused ID.

### Validation, and what happens when something is missed

The pass runs on a copy of state and is swapped in only after validation passes, so a rename that cannot be completed correctly is never persisted. Validation rejects duplicate IDs, an issue/worker/goal whose project or issue no longer resolves, a queued worker whose two copies of its dependency disagree, and — as a catch-all — **any reference slot or id-shaped hash key in the finished document that names no record, and any prose that still spells an ID this pass renamed away**, naming the value and the path that holds it. A future field that stores an ID under a key the rewriter does not recognise therefore fails the command loudly instead of silently stranding a reference. The audit also inspects hash *keys*, which the rewrite cannot reach because it only visits values: nothing keys by an AgentTree ID today except the counters (rebuilt from the live tree) and the recorded rename mappings (deliberately verbatim), so an id-keyed map added later fails the pass rather than quietly keeping a pre-recount spelling.

For reference slots that catch-all tolerates nothing, including an ID that was *already* dangling before the pass (a log entry about a pruned worker, a lineage link to a removed session). Renumbering cannot resurrect a removed record, but leaving its ID in a slot as a bare ID is worse than dangling: because numbering is compacted, that exact spelling can be handed to a different record by this pass or by the next record created after it, and the old reference then stops dangling and starts naming the wrong record. Such an ID is retired instead, as described below, which is what lets validation stay absolute without making `/recount` unusable.

Prose is audited more narrowly, because a bare prose token that names no record is legal there (see below) and, once the pass is done, an unmarked reused spelling cannot be told apart from the rewrite's own output. What can still be proven after the fact is a token that spells an ID this pass renamed away and gave to no record: nothing legitimate can write it, so its presence means the rewrite skipped a token and the pass fails.

Project, issue, worker, question, and goal counters are rebuilt from the resulting tree, so the next created entity receives the number after the compacted range.

Active worker records may be renumbered. Their PID, harness session ID/file, workspace path, branch, and all other opaque session fields remain unchanged. Completion waits and session reconciliation resolve the worker by its session identity, so an in-flight worker continues to update the renamed record. Recount is serialized behind worker spawning, so it cannot invalidate a reservation while workspace or harness provisioning is in progress.

## Every reference follows the record

The pass makes one walk over the whole state and visits every value exactly once, so nothing is rewritten twice. Each AgentTree ID it finds is resolved one of two ways.

**The record survived**: the ID is rewritten to that record's new ID. This covers structured references and text alike:

- issue project/parent links, issue agent lists and last-agent links, delivery pull-request records;
- worker project/issue links, follow-up/replacement/`after_agent_id` links, and ID-bearing structured `harness_metadata` (deferred-spawn queues, workspace inheritance, session-recovery lineage, reroute lineage, a persisted head result and its per-command journal);
- question ownership links, goal project/issue/worker/question links and iteration history;
- log `source_id` and every ID field inside log `details`;
- agent-workspace presentation state (selection and draft);
- narrative text: log messages, log detail prose (worker reports, applied-command messages, the raw input a command came from), issue titles and descriptions, worker spawn/queued prompts and final reports, question text and context, goal criteria and directives, and persisted chat messages.

**The record is gone**: the ID cannot stay spelled as a bare ID, because that spelling is now free to be handed to a different record. It is resolved instead:

- in a live orchestration slot the kernel acts on, the reference is cleared. This extends the older behavior where only dangling worker relationship links were cleared, and covers dangling lineage in `harness_metadata`, goal attempt workers, question links, and the focused-workspace selection. A queued worker whose predecessor was removed is cancelled with a warning by the deferred-spawn path, exactly as it is for any predecessor that disappears — it is never repointed at whichever worker inherited the ID.
- in a retained history slot (log and chat `source_id`, ID fields inside log `details`), the ID is marked `(old id)`: the line stays attributed to nothing rather than to the wrong record, and the annotated value no longer matches any record ID, so log attribution, `GetInfo`, the focused-workspace transcript filter, and ID completion all stop resolving it.
- in narrative text, the ID is marked `(old id)` only when this pass hands that exact spelling to a surviving record: `Worker P2-I2-W1 (old id) completed.` when the live World worker is being renumbered to `P2-I2-W1`. That is the one case where the bare token would stop being harmless and start reading as the surviving record's history. A token that names no record before or after the pass is left exactly as written, because nothing in state can tell a reference to a pruned `Q3` from the user's own `Prepare Q3 revenue report`, and a recount that renamed nothing near it has no business editing prose. The cost is deliberate: the counters are rewound, so a record created later can take a spelling that untouched text still uses (`Pruned issue P2-I3.` followed by a new `P2-I3`); marking every such token would mis-edit ordinary text on every recount, which was the reported bug.

`(old id)` is deliberately not a claim about *why* the ID stopped resolving. Usually the record was pruned or killed. It can also mean the ID was renamed by a pass that predates this behavior and left the text behind; in that case nothing in state can prove which record the text meant, so the pass marks it rather than guessing.

After renumbering, the pass validates that every AgentTree ID held in a reference slot names a record that exists right now, and that no prose still spells an ID the pass renamed away. If anything is left unresolved the whole recount is aborted and nothing is persisted, because persisting it would mean persisting misattributed history.

Marking is idempotent: an ID already annotated is neither renamed nor annotated again.

## What is not renumbered

- Composite correlation IDs that embed a record ID are preserved verbatim, because they are only ever compared against copies of themselves and never resolved back to a record: pending prompt IDs (`<agent id>-PP1`), goal attempt command IDs (`<goal id>-IT2-ATTEMPT`), and session restart command IDs (`session-restart-<agent id>-1`). Rewriting one copy and not another would break exactly-once dedupe, which is worse than a stale-looking key. Because an embedded ID is only recognised when it stands alone, these composite keys are also left alone inside text.
- Head IDs are transient command-correlation IDs. They and the head counter are not changed, and the counter is never rewound, so a head ID is never reused by a different head. Recount is refused while another head record is awaiting application, because that result was produced against the pre-recount state snapshot. The head that proposed the recount is not counted as a blocker: a head may run `/recount` for the user ("renumber the tree"), and the kernel applies it exactly like the typed command. Because renaming happens immediately, a head should propose `Recount` alone or last, never mixed with commands that reference ids which are about to change.
- Log IDs remain immutable and monotonic (a replaceable status receives a fresh ID), and conversation message IDs remain unchanged. Only the AgentTree IDs *inside* those records are resolved.
- Harness session IDs/files, PIDs, workspace paths/branches, the argv a session was spawned with, raw process output, harness state snapshots, pull-request identifiers/URLs, model references, and other external identifiers remain unchanged. These are byte-exact evidence, not references, and are skipped entirely.
- The old-to-new mapping recorded by a previous recount (in `metadata.last_recount` and in that pass's log entry) keeps both spellings verbatim: it is the record of a rename that happened, not a reference to a record.
- An ID written in lower case inside quoted user text is left as written. Meringue writes IDs in their canonical upper-case form, so `p3-i10` in a quoted request is treated as the user's words rather than as a reference.

An ID used illustratively rather than as a reference (an issue title that spells out `P3 before P3-I10`) is treated like any other prose token: it is renamed if that record exists, marked `(old id)` if this pass gives its spelling to another record, and otherwise left as written. Nothing in state distinguishes the two, so the pass edits an example only when leaving it alone would misattribute history.

The command appends one kernel log containing the old-to-new mappings and stores the latest mapping under `metadata.last_recount`. Its result also returns the mappings and rebuilt counters.

Because the kernel rewrote persisted chat history and the focused-workspace selection, the TUI reloads both from state when a recount is accepted, so its in-memory copy cannot write pre-recount IDs back on the next chat append.

## Usage

Run this in the interactive TUI:

```text
/recount
```

A plain-language request such as "renumber the tree" or "compact the ids after that prune" is routed by a head agent to the same kernel command.

Use `/state` afterward to inspect the mappings and counters, or `/tree` to inspect the compacted hierarchy.
