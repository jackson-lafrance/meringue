# Durable dashboard submissions

The dashboard clears its composer only after the submitted text has been appended and fsynced to
`<state path>.submissions.jsonl`. This sidecar is intentionally independent of `state.json` and its
cross-process orchestration lock: input acceptance cannot queue behind a long prune, reconciliation
write, or state serialization.

Each record has a random `input-<uuid>` id. Delivery carries that id into the kernel command id and
payload. Natural-language delivery stores it on the head request before starting the harness; a
second delivery therefore reuses the existing head. Prune stores it in the terminal prune log; a
replay returns that receipt rather than repeating cleanup. The queue appends a completion marker only
after the handler returns. On startup, pending records are replayed, so a supervising-process exit
between composer clearing and kernel application cannot lose the user's text.

This is write-ahead recovery, not a second orchestration state model. The kernel remains the only
layer that changes projects, issues, agents, questions, goals, and logs. The sidecar contains only
input text, optional selected-target routing context, timestamps, and completion markers.

Prune cleanup also has a 30-second per-command budget. Worktrees not reached inside that budget are
reported as `prune_cleanup_budget_exhausted`, conservatively preserved, and eligible for a later
explicit prune. Each individual git command receives the remaining pass deadline, so one expensive
checkout cannot turn one submission thread into another ten-minute operation.
