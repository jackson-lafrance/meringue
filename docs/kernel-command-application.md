# Exactly-once kernel command application

The kernel is the only layer that mutates Meringue orchestration state, and every
mutation is a load -> mutate -> save cycle against one JSON state file. That makes
"apply this command once" a coordination problem, not just a code path.

This document describes how a head's command batch is applied exactly once, why
that matters, and what happens when the same logical command is delivered twice.

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
`unknown` and retained. The whole prune lookup phase has a five-second budget, each
`gh` subprocess is terminated at the remaining deadline, and repeated URLs are looked
up once. Thus an unavailable forge can delay one prune briefly but cannot freeze the
kernel or cause unsafe removal.

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
id and terminal status. Re-applying a batch replays journaled results instead of
re-running commands, which is how a genuine crash mid-batch resumes without
duplicating the commands that already ran.

## Tolerated failure modes

- **The head disappears mid-batch.** Remaining commands stop, already-applied
  commands are reported as applied, and reconciliation logs a warning instead of
  failing the whole pass.
- **A workspace name collides.** Worker workspace allocation adopts a matching
  existing worktree, checks out an existing `meringue/<slug>` branch left behind by
  a released worktree, cleans up its own half-provisioned attempts, and otherwise
  retries with a uniquified branch and path (`…-2`) instead of failing the spawn.
  See `Meringue::Workspace::Manager`.
- **A session is busy elsewhere.** A transient harness error such as another
  instance being mid-turn (`Harness::TransientSessionError`) queues the prompt on
  the worker instead of failing the command. The wait is logged once as info, the
  delivery is logged only when the harness accepts it, and reconciliation retries
  it up to `PENDING_PROMPT_MAX_ATTEMPTS` times before giving up with a warning.

## Verifying

```bash
ruby scripts/kernel_exactly_once_smoke.rb
```

The script reproduces each symptom above (duplicate head result delivery, both
question channels in one result, branch/worktree collisions, a head killed
mid-batch, a foreign instance reconciling, a mid-turn prompt, and two instances
applying one head result concurrently) and asserts the resulting state, logs, and
side effects.
