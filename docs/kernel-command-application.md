# Exactly-once kernel command application

The kernel is the only layer that mutates Meringue orchestration state, and every
mutation is a load -> mutate -> save cycle against one JSON state file. That makes
"apply this command once" a coordination problem, not just a code path.

This document describes how a head's command batch is applied exactly once, why
that matters, and what happens when the same logical command is delivered twice.
Dashboard text is first protected by the write-ahead queue described in
[durable input submissions](durable-input-submissions.md), before it reaches this layer.

## What went wrong before

Two `bin/meringue` windows on one machine share `~/.meringue/state.json`. Only
in-process mutexes guarded command application, so both instances could drive the
same records at once. Observed in real logs from a single user message:

- One head clarification became two question records: `Q1` from the head result's
  `questions` array and `Q2` from an `AskQuestion` command in the same result,
  reworded because the two channels were written separately.
- One `SpawnWorker` became two Pi sessions 20 ms apart in the same worktree, two
  identical `Spawned worker P1-I6-W1 for P1-I6.` log lines, and one
  `git worktree add failed: ... branch already exists` error from the attempt that
  lost the race.
- `Failed ReconcileSessions: Head H55 disappeared before command 2 was
  checkpointed.` when one instance cleaned the head up while the other was still
  applying its batch.
- `Failed PromptAgent: Meringue instance 6869 owns this Pi session ... still
  mid-turn.` because the second instance re-applied a `PromptAgent` command that
  the first instance had already delivered.

## How application stays exactly-once

**A cross-process state lock.** `Meringue::State::FileLock` wraps every kernel
read-modify-write section (`Engine#synchronized_state`) in an advisory `flock` on
`<state path>.lock`, so two instances cannot interleave load/mutate/save cycles and
lose each other's updates. The lock is bounded: if it cannot be acquired within its
timeout the section still runs, so a stuck instance can never freeze another one's
TUI.

**External I/O stays outside the state lock.** Commands may need conservative external
facts before mutation. `/prune`, for example, checks GitHub pull-request state before
removing a record. It snapshots state under the lock, performs forge discovery/status
lookups without the lock, then reacquires the lock and applies against current state
using only the per-command lookup cache. A record/PR introduced after the snapshot is
`unknown` and retained. The whole prune lookup phase has a fifteen-second budget
(`Engine::PRUNE_FORGE_LOOKUP_BUDGET_SECONDS`, injectable per engine), each `gh`
subprocess is terminated at the remaining deadline, and repeated URLs are looked up
once. Thus an unavailable forge can delay one prune but cannot freeze the kernel or
cause unsafe removal: the budget is only ever spent when the forge is slow, a healthy
pass finishes in well under a second, and no other command waits on it because the
phase holds neither the state lock nor the prompt-loop mutex.

The cache is seeded from state before any external call: a pull request already verified
as `merged` is terminal on the forge, so prune trusts the persisted record instead of
spending budget to confirm it (`closed` is excluded because it can be reopened). The
remaining lookups are ordered by what retention depends on — statuses of PRs recorded on
an issue, then branch discovery for settled workers with an unknown delivery, then
exploratory candidate URLs — so an exhausted budget degrades discovery instead of turning
a known-merged PR into `unknown` and retaining the whole subtree. Each pass reports
`forge_lookup` counters and every retained record's reason in the prune log details. Workspace
cleanup has a separate 30-second pass budget; remaining worktrees are conservatively retained and
reported for a later pass rather than monopolizing one input delivery thread.

**A batch apply lease.** The instance applying a head result holds a heartbeat lease
on the head record (`head_result_apply_owner`, `head_result_apply_heartbeat`), so a
second instance can tell an in-flight batch from an abandoned one and skips it
instead of restarting it. See `Engine#head_result_apply_lease_held_elsewhere?`.

**Instance ownership.** The lease says "this batch is busy"; ownership says "this
record belongs to that instance". Heads, worker reservations, and in-flight command
journal entries record their owner (`owner_instance_id`, `owner_instance_pid`,
`owner_instance_started_at`), which is what keeps a record from being adopted
between batches (session polling, worker re-provisioning, head completion) and not
only while a batch runs. Recovery is for work whose owner is gone:

- another instance never recovers or completes a head owned by a live instance,
- another instance never re-provisions a worker reservation owned by a live
  instance,
- a command journal entry marked `running` by a live instance is never re-run
  elsewhere.

The recorded start time is checked alongside the pid so a reused pid cannot make a
crashed owner look alive and block recovery forever.

**A canonical head result.** The first result recorded for a head wins. A later or
re-parsed variant of that result is logged once as a duplicate and then ignored,
and a head result whose batch already finished is never applied again. This is what
keeps one clarification to one question and one `SpawnWorker` to one worker.

**A per-command journal.** Each command in a batch is journaled with its command
id, terminal status, and authoring head. Re-applying a batch replays journaled
results instead of re-running commands, which is how a genuine crash mid-batch
resumes without duplicating the commands that already ran. Kernel log entries
emitted by those commands retain the same author as
`details.command_author_type: head` and `details.command_author_id: H<n>`, while
their top-level `source_type` remains `kernel`: the head proposed the command,
but Meringue validated and applied it. The logs pane renders that distinction as
`meringue · via H<n>`. Kernel actions not proposed by a head have no command-author
metadata and keep the ordinary `meringue` header.

**Concurrent project registration.** A head batch carries its head id on each proposed command.
If its `AddProject` reaches the kernel after another head has registered the same normalized root,
the kernel treats that duplicate as an accepted reuse of the existing project and journals the
winning project id. This is intentionally narrower than changing the standalone `/project add`
contract, which still rejects duplicates. Because the reused registration is accepted in the batch
journal, later `CreateIssue` and `SpawnWorker` commands resolve their `project_from_command` or
predicted project/issue references against the real project instead of being rejected as if the
user's request had not routed.

**Concurrent worker routing.** Issue and worker counters are allocated inside the shared state lock,
and worker spawns persist a reservation before workspace or harness I/O. In the dashboard,
`SpawnWorker` is complete for command-journal purposes once that reservation is durable: a bounded
background executor claims the reservation and performs workspace allocation and harness startup,
so independent spawns later in the same head batch are not serialized behind checkout. The
in-memory executor queue is only an optimization; ownership and provisioning state remain durable,
and reconciliation re-enqueues a reservation only when its prior owner is gone. Replaying the
command acknowledges the existing reservation rather than submitting another allocation. A `PromptAgent` may refer to
a worker spawned earlier in its own batch by command id/index, and a prompt aimed at a worker that was
replaced while the head was routing is redirected only to that replacement on the same issue. Prompt
command ids are retained on the worker for bounded replay protection; a stale reconciliation snapshot
therefore acknowledges an already-delivered prompt instead of sending it again.

## Tolerated failure modes

- **The head disappears mid-batch.** Remaining commands stop, already-applied
  commands are reported as applied, and reconciliation logs a warning instead of
  failing the whole pass.
- **A workspace name collides.** Worker workspace allocation adopts a matching
  existing worktree, checks out an existing `<task-slug>-<opaque-suffix>` branch left behind by
  a released worktree, cleans up its own half-provisioned attempts, and otherwise
  retries with a uniquified branch and path (`…-2`) instead of failing the spawn.
  See `Meringue::Workspace::Manager`.
- **A session is busy elsewhere.** A transient harness error such as another
  instance being mid-turn (`Harness::TransientSessionError`) queues the prompt on
  the worker instead of failing the command. The wait is logged once as info, the
  delivery is logged only when the harness accepts it, and reconciliation retries
  it up to `PENDING_PROMPT_MAX_ATTEMPTS` times before giving up with a warning.
- **A session can never be repaired.** Once reconciliation records a failure as
  terminal, the record is logged once, is not re-touched, and is no longer polled, so
  the periodic pass cannot livelock on it or repeat its error line every two seconds.
  See `docs/session-reconciliation.md`.
- **The target session is mid-turn here.** A `PromptAgent` with mode `normal`
  against a streaming session is delivered through the harness's queued-prompt
  behavior (Pi RPC `follow_up`) rather than rejected, so a correctly routed user
  message is never lost to timing. The harness reports the substitution on the
  returned session ref (`requested_prompt_mode`, `delivered_prompt_mode`,
  `prompt_mode_note`) and the kernel states it in the one delivery log line. This
  path does not use the pending-prompt queue, so it cannot double deliver: the
  harness owns the ordering behind the active turn.
- **A batch target is pruned or killed mid-flight.** A head is spawned against a
  snapshot and its result is applied seconds later, so `/prune` or `/kill` can
  remove a record it legitimately read in between. Visibility is therefore decided
  from the head's recorded spawn snapshot, never from "does this issue exist right
  now" (`Engine#head_issue_visibility`): reading live state made the race look like
  a head that had invented an issue id, told it to use `issue_from_command` for an
  issue it never created, marked it blocked, and dropped part of the user's intent
  behind an unactionable warning. Now the command is skipped as a no-op with the
  error code `issue_removed_before_head_result_applied`, an accurate line
  (`Skipped ModifyIssue: issue P4-I4 was removed by a prune at … after head H34 was
  spawned with it in view, so there was nothing left to update. No state was
  changed. Dropped issue update (status → completed, description).`), a separate
  count in the batch summary, and no `blocked` head. An id the head never saw is
  still rejected as a prediction, which is the mistake that check exists for.
  The same race removes agents: one `/prune` pass took 10 issues and 21 agents, so
  a batch `PromptAgent` on a pruned worker, or a `Kill` of a record that is already
  gone, is skipped the same way (`agent_removed_before_head_result_applied`,
  `Engine#resolve_batch_removed_target`) instead of stopping at "Agent P3-I9-W2
  does not exist" with a blocked head. Because the record itself is gone, the
  kernel keeps bounded ledgers of the ids it removed and why
  (`state.metadata.removed_issues` and `state.metadata.removed_agents`, each capped
  at `Engine::REMOVED_RECORD_LEDGER_LIMIT`) so "removed under a command in flight"
  can be told from "never existed" from recorded facts rather than from logs, which
  have their own retention. Kinds are bounded separately so pruning many workers
  cannot evict the issue history an in-flight result still needs. A command that
  genuinely failed (a worker whose `git worktree add` timed out) and a dependent
  command that could not resolve it are a different case and still block the head.
- **A dropped command is never a bare count.** A rejected or skipped
  `ModifyIssue`, `SpawnWorker`, or `PromptAgent` states the intent that did not
  land (`Dropped issue update (status → completed, description).`,
  `Dropped worker "Re-run the cleanup".`), so `1 rejected` is always something the
  user can act on.
- **A head batch accepts nothing.** The user's message is restated once as an
  `unrouted_user_message` log entry (error when commands were proposed and none
  applied, warning when the head proposed neither commands nor questions) with
  the full message in `details`, so a request cannot vanish into command error
  lines. A batch that recorded a clarifying question is already actionable and is
  not reported as unrouted. When the head intentionally finds no work to route
  because current state already satisfies the request, it proposes `NoOp` with a
  reason; that command is accepted and logged at info level, so deliberate
  no-work results do not raise the unrouted warning.

## Verifying

Run the normal test suite, or the focused files for this contract:

```bash
rake test
ruby -Ilib -Itest test/integration/kernel_heads/exactly_once_apply_test.rb
ruby -Ilib -Itest test/integration/kernel_heads/removed_batch_target_test.rb
ruby -Ilib -Itest test/integration/kernel_workers/prompt_agent_test.rb
ruby -Ilib -Itest test/integration/state/store_concurrency_test.rb
ruby -Ilib -Itest test/integration/workspace/manager_collision_test.rb
```

These tests cover duplicate head result delivery, both question channels in one
result, branch/worktree collisions, a head removed mid-batch, foreign-instance
reconciliation, mid-turn prompts, and concurrent state updates through the same
Rake-driven suite as the rest of the project.
