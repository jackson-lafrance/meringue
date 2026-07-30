# Recounting AgentTree IDs

`/recount` compacts user-facing AgentTree numbering after `/prune`, killed-record reconciliation, or another removal leaves gaps. It is a kernel command: the kernel computes the complete mapping in memory and persists the updated state with the state store's atomic file replacement.

## What is renumbered

Records keep their existing numeric creation order within each scope:

- Projects are compacted globally (`P2`, `P4` becomes `P1`, `P2`).
- Issues are compacted independently inside each project (`P1-I2`, `P1-I3` becomes `P1-I1`, `P1-I2`). A project rename also changes the project prefix.
- Workers are compacted independently inside each issue (`...-W2`, `...-W3` becomes `...-W1`, `...-W2`). Project and issue prefix changes flow into worker IDs.
- Questions are compacted globally (`Q2`, `Q4` becomes `Q1`, `Q2`).
- Goals are compacted globally (`G2`, `G4` becomes `G1`, `G2`). A goal's project/issue links, its recorded attempt worker ids, and its iteration history follow the renumbering, and the goal counter is rebuilt with the others.

The command updates issue parent links, issue agent lists and last-agent links, worker follow-up/replacement links, question ownership links, structured log references, and ID-bearing structured harness metadata such as a persisted head result. Worker relationship links whose target was already removed are cleared rather than being allowed to point at a newly reused ID. Project, issue, and worker counters are rebuilt from the resulting tree, so the next created entity receives the number after the compacted range.

Active worker records may be renumbered. Their PID, harness session ID/file, workspace path, branch, and all other opaque session fields remain unchanged. Completion waits and session reconciliation resolve the worker by its session identity, so an in-flight worker continues to update the renamed record. Recount is serialized behind worker spawning, so it cannot invalidate a reservation while workspace or harness provisioning is in progress.

## What is not renumbered

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
