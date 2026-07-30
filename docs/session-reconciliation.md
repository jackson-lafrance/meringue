# Session reconciliation and terminal failures

`ReconcileSessions` runs at startup and then every `Meringue::App::RECONCILE_INTERVAL`
seconds (2.0) for as long as Meringue is open (`lib/meringue/app.rb`). Each pass looks
at the harness sessions Meringue tracks and updates lifecycle state from the evidence
it can observe: live vs dead pids, readable vs missing session files, resumable vs
unresumable transports, settled vs streaming sessions.

Because the pass repeats forever, the important property is not "did it notice the
failure" but "does it stop noticing the same failure". A record reconciliation can
never repair must be recorded once and then left alone.

## What went wrong before

A head session whose model never produced a parseable `HeadResult` (provider
overload returns empty assistant messages) was marked `errored`, but the errored
record stayed a reconciliation candidate. Every pass re-polled the still-running Pi
process, re-parsed the same unparseable answer, re-marked the record `errored`, bumped
`updated_at`, rewrote `state.json`, and appended another error log:

```txt
! H91 · head session · err / Head H91 errored while reconciling its agent session.
```

Seven such heads produced 7 identical error lines every ~2 seconds. Log retention is
bounded (`State::Models::LOG_RETENTION_LIMIT`, 500 entries), so the repeats also
evicted the user's real history, and the failed heads kept orphaned Pi RPC processes
alive because their head sessions were never released.

## The contract now

**One logical failure, one log line.** `Engine#mark_agent_errored_from_poll` compares
the failure it is about to record (`state`, `error_class`, `error_message`; not the
moving `last_error_at`) with what is already on the record. An unchanged terminal
failure on an already-`errored` record is not a state change: no status write, no
`updated_at` bump, no `touch_state!`, no `store.save`, no log entry. A genuinely
different failure still transitions and still logs.

**Terminal records stop being polled.** `Engine#reconcile_candidate?` skips any record
whose persisted reconcile details already say `terminal_error`
(`Engine#terminal_reconcile_error_recorded?`). The periodic loop therefore cannot
livelock on a record it can never repair: after the ladder below is exhausted, the
record costs one pass, not one pass every two seconds. Reconciliation picks the record
back up only if a command moves it out of `errored`.

**A terminally failed head releases its session.** Marking a head terminally errored
now calls `Engine#release_head_session!` with reason `head_reconcile_error`, matching
the `AGENTS.md` rule that the kernel closes a head's harness session when the head
errors. Without that the failed head leaked a live harness process forever.

**A refused head result is terminal too.** There are two ways a polled head fails: its
answer cannot be parsed as a `HeadResult`, or it parses and the kernel refuses to apply
it (`Engine#record_polled_head_completion`). The second case used to leave the record
`errored` with `reconcile_state: healthy`, so it was re-polled, re-applied, re-rejected,
and re-logged (`Polled head Hn completed but its HeadResult was not applied.`) on every
pass. It now records the same terminal reconcile details (`reason:
"head_result_not_applied"`) and releases the head session, so it is logged once and left
alone. The in-flight batch recovery path (`head_result_apply_state == "applying"`) is
unaffected: it does not consult `reconcile_state`, so a genuine mid-batch crash is still
resumed through the command journal.

**An already-errored head does not earn a fresh grace window.** The head startup grace
window (`HEAD_RECONCILE_ERROR_GRACE_SECONDS`) is measured from when the record
actually failed (`errored_at`, else `updated_at`) rather than from the moment
reconciliation noticed it again, so a stale errored head is never flipped back to
`working` pass after pass.

## The repair ladder before a failure is terminal

Terminal is the last rung, not the first:

1. **Head transient error inside the grace window** — the head stays `working`, one
   warning is logged (`warning_logged_at` makes it once, not per pass), and the pass
   retries.
2. **Head recovery** — up to `HEAD_RECONCILE_RECOVERY_MAX_ATTEMPTS` attempts to
   re-attach the persisted session, or restart it from the persisted head request.
3. **Head result repair** — an unparseable `HeadResult` is challenged up to
   `HEAD_RESULT_REPAIR_MAX_ATTEMPTS` times before it counts as a failure. A result the
   kernel refuses to apply has no retry and is terminal immediately.
4. **Worker resume** — a worker whose session cannot be polled is re-attached and
   re-prompted up to `WORKER_RECONCILE_RESUME_MAX_ATTEMPTS` times, staying `blocked`
   (with one warning per attempt) rather than `errored` while attempts remain.
5. **Terminal error** — recorded once, per the contract above.

## Cleanup of terminal records

Reconciliation records terminal failures; it does not delete records. Standalone
errored heads are removed by `/prune`, which also releases their harness sessions and
worker worktrees (`Engine#prune_records`). This is deliberate: the failed head is the
only user-visible evidence that a message was dropped, so it stays in the AgentTree
until the user asks for housekeeping. `/prune` is the supported way to clear leftover
errored heads.

`PromptAgent` rejects an `errored` agent (`agent_not_resumable`), so skipping terminal
records in reconciliation cannot lose recoverable work: nothing else in Meringue would
have continued them either.

## Verifying

```bash
ruby -Ilib -Itest test/integration/kernel_maintenance/reconcile_terminal_errors_test.rb
ruby -Ilib -Itest test/integration/kernel_maintenance/reconcile_sessions_test.rb
ruby scripts/reconcile_terminal_error_smoke.rb
```

The smoke script drives eleven reconciliation passes over one unrepairable head and one
unrepairable worker and prints the log-line count, so the spam is easy to see or refute by
hand: two error lines total instead of two per pass.

The first test file covers the log-once/no-churn contract: an unrepairable worker session,
a head that cannot return a result, and a head whose result the kernel refuses each log
exactly one error across repeated passes, the state file is byte-identical after repeat
passes, live sessions in the same pass still reconcile, an errored record without recorded
reconcile details is still polled and still reports its failure once, and a settled errored
head is retained until `/prune` removes it.
