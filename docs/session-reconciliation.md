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

## A background pass must stay in the background

A reconcile tick is work nobody asked for. It runs every two seconds whether or not the
user is doing anything, so its cost is not paid once: it is paid against every prompt the
user sends while it is running. Two rules follow, and both were learned from a reported
"Meringue is slow right now".

**Never hold the state lock across external I/O.** `Engine#refresh_stale_delivery_pull_requests`
used to run one blocking `gh pr view` per stale delivery PR inside `synchronized_state`,
which holds both the in-process state mutex and the cross-process `state.json.lock`. With
eleven tracked PRs one measured tick spent **5.85 s** inside that lock, and every kernel
command in every Meringue instance queued behind it: submitting a prompt, applying a
`HeadResult`, settling a worker. The refresh is now three phases, the same shape `/prune`
already used (`Engine#prepare_prune_forge_lookups`):

1. `Engine#due_delivery_pull_request_urls` — locked, cheap, read-only. Which URLs are due.
2. `Engine#fetch_delivery_pull_request_statuses` — **unlocked**. Talks to the forge.
3. `Engine#apply_delivery_pull_request_statuses` — locked again, and against *current*
   state rather than the snapshot the URLs came from, so an issue pruned or a record
   replaced during the forge call is simply skipped.

**Bound the tick, and do not let the herd re-synchronize.** One tick starts at most
`DELIVERY_PULL_REQUEST_REFRESH_BATCH_LIMIT` (3) lookups and shares a single
`DELIVERY_PULL_REQUEST_REFRESH_BUDGET_SECONDS` (5.0) deadline across the whole batch, so an
unreachable forge costs one budget rather than one timeout per URL. Whatever is left over
stays due and is picked up by a later tick: a backlog becomes many cheap ticks instead of
one long one.

A fixed refresh interval alone was not enough. Every record refreshed in one burst is
stamped with the same `last_checked_at`, so a fixed interval makes them all fall due again
on the same later tick, forever. `Engine#delivery_pull_request_refresh_interval` adds a
deterministic per-URL offset (`Zlib.crc32(url) % DELIVERY_PULL_REQUEST_REFRESH_SPREAD_SECONDS`)
to the base interval, which spreads the herd without storing any extra scheduling state.
The spread only ever delays a refresh; it never cancels one.

## The repair ladder before a failure is terminal

Terminal is the last rung, not the first. These are in-flight session-repair steps before a head becomes terminal; they are not the user-facing retry of an `errored`/`blocked` head row, which is manual via `/retry` and always starts a fresh head.

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
   (with one warning per attempt) rather than `errored` while attempts remain. A session
   the provider has already refused to replay is skipped here (see [A session that cannot
   be replayed](#a-session-that-cannot-be-replayed)): resuming it would send the same
   rejected transcript. So is a session whose *process* is gone (see [A harness process that
   is gone](#a-harness-process-that-is-gone)): there is nothing left to attach or prompt.
   A resume attempt that fails *after* attaching kills the session it started
   (`safely_kill_recovery_session`), so a failed rung never leaves an untracked harness
   process writing to the session file.
5. **Worker session restart** — a worker whose saved transcript the provider refuses is
   continued once in a *fresh* session on that same worktree and branch, instead of being
   resumed.
6. **Terminal error** — recorded once, per the contract above.

## Cleanup of terminal records

Reconciliation records terminal failures; it does not delete records. Standalone
errored heads are removed by `/prune`, which also releases their harness sessions and
worker worktrees (`Engine#prune_records`). This is deliberate: the failed head is the
only user-visible evidence that a message was dropped, so it stays in the AgentTree
until the user asks for housekeeping. `/prune` is the supported way to clear leftover
errored heads.

`PromptAgent` rejects an `errored` agent (`agent_not_resumable`) unless that agent is a
worker whose turn was cut short by a transport failure (see below), so skipping terminal
records in reconciliation cannot lose recoverable work: nothing else in Meringue would
have continued them either.

A leftover errored head is retryable rather than only prunable, and so is a head left
`blocked` because the kernel rejected or failed part of its batch. Retry is explicit:
`/retry H<n>` (or double-clicking the TUI's `retry me` row) starts a fresh head from the
old head's recorded request and command journal. The old head/session is not prompted or
resumed; the kernel releases any stale head session, removes the old row from the active
AgentTree, and records lineage on the retry head plus the retry log. Reconciliation is
unchanged by this because polling follows the fresh head. See [Retrying a failed
head](head_agent_kernel_commands.md#retrying-a-failed-head).

## Settled is not finished

A harness state call can only report that a session is no longer streaming, and that is
true both for a turn that finished and for a turn that died mid-flight. Treating the second
as the first is how a dropped wifi connection produced five `Worker <id> completed.` lines
with empty results and flipped five in-flight issues to `completed`.

Each pass therefore classifies a settled worker session instead of assuming it finished
(`Engine#settle_failure_from_evidence`), in order of authority:

1. the harness's own `turn_outcome` (Pi reads the stop reason of the turn's final assistant
   message, so the failure is still visible after the fact)
2. a `turn_outcome` a harness attached to the session ref metadata
3. session events proving the transport died — but only when the settled turn produced no
   final assistant message at all, so a real result followed by a clean process exit is
   still a completion

A classified failure settles the worker as `errored` with the reason on the record
(`harness_metadata.settle_failure`, `settle_state`, `status_reason`), in one `error` log line
(`Worker <id> errored without finishing: …`), and in the AgentTree and focused pane. No
`completed_at` is written, so the issue and project cannot roll up to `completed` behind it.

These records deliberately keep `reconcile_state: healthy` and are **not** marked
`terminal_error`: reconciliation did its job, and the worker is still recoverable. That means
they stay poll candidates, so the two log-once rules that matter here are its own:

- re-observing the same dead turn is a silent no-op (compared by failure signature, not by
  the moving `detected_at`), so an already-errored record is never re-logged pass after pass
- failure evidence older than `harness_metadata.last_prompted_at` is stale, so a worker that
  was prompted back to work is not re-errored from the persisted evidence of the turn it
  already recovered from

A settle-failed worker stays recoverable in every direction: its harness session reference,
workspace, worktree, and branch are untouched, queued `pending_prompts` are still
redelivered, `PromptAgent` accepts it while it still has a session reference, and a session
that starts streaming again (for example because the user jumped into it) clears the recorded
reason on the next pass. A worker whose session reference is gone remains terminal.

The same reasoning applies to a worker queued behind it with `after_agent_id`: an `errored`
predecessor normally cancels its dependent, but a predecessor that only stopped because its turn
was cut short keeps the dependent waiting, because *reconciliation itself* resumes that session and
the chain continues without anyone doing anything. That is the whole test
(`deferred_predecessor_can_still_finish?`): waiting is only correct when Meringue is the one who
will make the predecessor finish. A predecessor whose harness process is gone fails it, because
nothing revives that worker without a user prompt, so its dependents are resolved by their
`if_predecessor_fails` policy instead of waiting for a human for an unbounded time.
`if_predecessor_fails: "run"` still activates the dependent immediately, and killing the
predecessor still cancels the chain.

Completion-triggered heads use the same kernel-owned settle/reconcile shape. A worker may carry a
`harness_metadata.completion_continuation` record from `SpawnWorker`'s `completion_head` payload.
When that worker reaches `completed`, the settle path either claims the continuation immediately or,
when the nested object has an `after_command`, arms its persisted gate and leaves the routing queued.
The eventual head receives a bounded copy of the worker's final report (and gate output when present)
in the prompt. If Meringue is down in the window after completion, the next reconciliation pass
resumes the same gate/claim instead. Workers never poll state or sleep for this workflow.

## A harness process that is gone

A harness session is a process, and a process can leave. When it does, that session's transport is
finished: every later RPC can only time out, because there is nothing on the other end of the pipe.

This is what that used to look like from the outside. A worker was spawned, its Pi process later
exited mid-tool-call, and the first thing Meringue said about it was that a *resume* had failed:

```txt
state:                  resume_failed
resume_attempt_count:   1
original_error_class:   Meringue::Harness::PiClient::ProcessExitedError
original_error_message: "Pi session … has no live process and no completed assistant response"
error_class:            Meringue::Harness::PiClient::RpcTimeoutError
error_message:          "Timed out waiting for Pi RPC response to \"prompt\""
```

Two things were wrong there. The exit was only *discovered* by trying to resume the session, and
each of the three resume attempts then spent a `prompt` RPC on a process that could not answer it -
so the failure the user finally read named the RPC timeout instead of the exit that actually
happened, ~70 seconds and three orphaned harness processes later.

- **Proved, not guessed.** The harness raises an error carrying the marker
  `Harness::SessionProcessGoneError` (`Harness.session_process_gone_error?`), the way
  `TransientSessionError` marks the opposite case. Pi includes it in
  `PiClient::ProcessExitedError`, which is raised only where the process is known to be gone: a
  dead pid with no completed assistant response in the session file, an exit that failed the RPCs
  in flight, or a closed stdin. Nothing here is a timing heuristic, so a legitimately slow start -
  a worktree that takes a minute to check out, a first turn that thinks for ten - can never be
  classified as a dead process.
- **Classified on the first pass that sees it.** `Engine#worker_harness_process_gone?` is checked
  *before* the resume ladder, so the worker settles as `errored` with
  `settle_failure.kind: "harness_process_exited"`, `source: "harness_process_exit"`, and a reason
  that names the exit (`… (exit code 1)`, `… (terminated by signal 9)`). Detection latency is one
  reconcile pass - `RECONCILE_INTERVAL` is 2.0s - instead of "whenever a resume happened to be
  attempted".
- **Never re-prompted.** No `attach_session`, no `prompt_session`, no resume attempt counter, and
  therefore no `RpcTimeoutError` standing in front of the real cause. The `error_class` and
  `error_message` on the record are the harness's own process-exit error.
- **Reported with the evidence the exit left behind.** `Client#session_exit_evidence` (implemented
  by `PiClient`) reports the exit status, the stderr tail, and when the process was last heard from;
  `read_events` now also drains the journal of an exited process, which is what finally puts the
  harness's own `process_exit` event in the log. Both used to be unreachable, because reading them
  required a live process while `get_state` raised first. A client that never owned the process (a
  Meringue restart, another instance) reports nothing and the record's own recorded evidence is
  reused, so the failure keeps one wording and is logged once.
- **Still recoverable.** Unlike a transcript the provider refuses, this session is intact: only its
  process is gone. The record keeps its session reference, worktree, and branch,
  `worker_resumable_after_settle_failure?` stays true, and `/prompt` continues the work in a new
  process from the saved session. The log line says so.
- **Not something to queue behind.** Because that revival needs a user, queued dependents are
  resolved by their `if_predecessor_fails` policy instead of waiting (see "Settled is not
  finished" above).

Meringue does not restart the session by itself here, deliberately. The session file is a valid
resumable transcript, and a fresh session would throw away the turn the worker was in the middle
of - the opposite trade from the unreplayable case below, where the transcript is the thing that is
broken.

A follow-up prompt remains valid recovery input after that process exit. Pi cannot queue a
`follow_up` RPC until a live turn exists, so `PiClient` reattaches the saved transcript and delivers
the follow-up as a normal continuation. `steer` remains rejected in this state because it
specifically promises to interrupt an active turn.

## A session that cannot be replayed

One dead turn is different: the model provider rejects the *saved transcript* itself, not the
request. Anthropic-style routes refuse a replayed assistant turn whose `thinking` /
`redacted_thinking` blocks are not byte-identical to what they originally returned:

```txt
400 messages.1.content.44: `thinking` or `redacted_thinking` blocks in the latest assistant
message cannot be modified. These blocks must remain as they were in the original response.
```

Resuming replays the same turn, so every attempt fails identically. This is what dead-ended a
real worker: it errored, the kernel resumed its session, and three seconds later it errored
again with the same 400, while the worker queued behind it with `if_predecessor_fails: "cancel"`
could never start. Meringue does not own that transcript and does not rewrite harness session
files, so it treats the session as spent and recovers the *work*:

- **Classified apart from a transport blip.** `kind: "unreplayable_session"` (the harness
  reports it - `PiClient::UNREPLAYABLE_SESSION_PATTERN` - and the kernel recognises the same
  rejection in session events through `SETTLE_FAILURE_UNREPLAYABLE_PATTERN`). The record's
  `status_reason` and its one error log line say the session cannot be replayed and that the
  worktree and branch still hold the work; the log details carry `recoverable: false`.
- **Never resumed.** `worker_resumable_after_settle_failure?` is false for these records, so
  reconciliation does not re-attach them, `/prompt` does not deliver into them, and a queued
  dependent is resolved by its `if_predecessor_fails` policy instead of waiting forever.
- **Restarted once, in place.** The kernel spawns a replacement worker whose session is fresh
  but whose workspace is the dead worker's *existing* worktree and branch
  (`_inherit_workspace_from_agent_id`). This is the same workspace-sharing path any continuation
  worker takes (see "Sharing one worktree between related workers" in
  `docs/head_agent_kernel_commands.md`) with one deliberate difference: a restart that cannot take
  the worktree over fails the spawn (`inherited_workspace_unavailable`) rather than quietly
  starting somewhere else, because a fresh checkout would not contain the work being recovered.
  Nothing re-creates, re-branches, or cleans up that checkout: the inherited workspace plan is
  recorded with `created: false`, which is what keeps every failure path from deleting the only
  copy of the work. The successor's prompt carries the
  original assignment plus a handover note telling it to re-establish state with `git status`
  before continuing.
- **Bounded.** One restart per worker (`WORKER_SESSION_RESTART_MAX_ATTEMPTS`) and a chain cap
  (`WORKER_SESSION_RESTART_MAX_CHAIN_DEPTH`), tracked in `harness_metadata.session_recovery`
  with a deterministic restart command id so a repeated observation cannot spawn a second
  successor. When the budget is spent, the worker stays `errored` with a reason the user can act
  on and `/prompt` answers with which worker holds the work now.
- **Queue-preserving.** The restart is a replacement, so `SpawnWorker` repoints the dead
  worker's queued dependents at the successor in the same command.
- **Prune-safe.** A worker whose worktree was taken over no longer owns it
  (`worker_workspace_handed_over?`): pruning the replaced record removes only the record, and it
  neither deletes the shared checkout nor warns once per pass about a worktree it handed over.

Ownership note: the mutation the provider objects to happens inside the harness's own model
request path (Pi replays the interrupted assistant turn from its session file, including a
synthesized tool result for the tool call that never completed) and the provider route that
validates it. Meringue's contribution to a resumed request is one plain user message. The
behavior above is therefore resilience, not a transcript fix, and it applies to any harness
that reports the same class of failure.

## Kernel wait gates

A queued worker can wait on a shell condition (top-level `after_command` on `SpawnWorker`; see
"Chaining a worker after a script or command" in `docs/head_agent_kernel_commands.md`). A worker's
completion continuation can wait on the same condition (`completion_head.after_command`) when the
follow-on *routing decision* must not happen yet. Both are persisted kernel wait predicates, not
checker sessions. One reconcile step, `check_kernel_wait_gates`, evaluates both owner types and then
the ordinary owner-specific resolver either starts the queued worker or spawns the completion head.
A condition that passes can therefore release its work in the same reconciliation pass.

The step is bounded in every direction, because it runs a user- or head-supplied command on a
timer. It is the same discipline "A background pass must stay in the background" states above,
applied to a second kind of external I/O:

- **Never under the state lock.** Like the delivery-PR refresh, the step is three phases: it
  claims the gates that are due inside the lock (by moving `next_check_at` forward, which also
  stops a second Meringue instance from running the same check), releases the lock, runs the
  commands, and reacquires to write the outcomes back against *current* state. No user command
  ever executes while the state file is held.
- **Never for long.** Each check runs in its own process group and is killed at
  `after_command_timeout_seconds` (default 30s, max 120s), and one pass spends at most
  `DEFERRED_WORKER_GATE_BUDGET_SECONDS` (10s) starting checks. Gates that do not fit are checked
  on the next pass, the same way `advance_goal_loops` defers goals it cannot fit.
- **Never forever.** A gate is polled at most every `after_command_interval_seconds` (default
  60s, minimum 5s), gives up at `after_command_max_wait_seconds` (default 4h, max 24h), and is
  abandoned after three consecutive checks that could not be evaluated at all. Expiry and
  abandonment cancel the queued worker or completion continuation with a warning by default, or
  release it anyway with `if_gate_expires: "run"`.
- **Never in memory only.** The whole condition, its budget, and its next check time live on the
  worker record: `harness_metadata.deferred_spawn.command_gate` for a queued worker, or
  `harness_metadata.completion_continuation.command_gate` for deferred head routing. A wait that
  outlives the process resumes on the next start, and an in-flight completion claim still uses the
  existing owner/head lookup to avoid spawning the eventual head twice.

The step never activates or cancels anything itself. It only updates a gate's state;
`resolve_deferred_workers` remains the one place a queued worker starts or is cancelled, and
`resolve_completion_continuations` remains the one place a completion head is claimed, spawned, or
cancelled. That separation is what lets both kinds share polling and timeout policy without sharing
their lifecycle side effects.

## Verifying

```bash
ruby -Ilib -Itest test/integration/kernel_maintenance/reconcile_terminal_errors_test.rb
ruby -Ilib -Itest test/integration/kernel_maintenance/reconcile_sessions_test.rb
ruby -Ilib -Itest test/integration/kernel_maintenance/reconcile_delivery_pull_request_test.rb
ruby -Ilib -Itest test/integration/kernel_workers/settle_classification_test.rb
ruby -Ilib -Itest test/integration/kernel_workers/unreplayable_session_recovery_test.rb
ruby -Ilib -Itest test/integration/kernel_workers/dead_harness_process_test.rb
ruby -Ilib -Itest test/integration/harness/pi_client_turn_outcome_test.rb
ruby -Ilib -Itest test/integration/harness/pi_client_process_exit_test.rb
ruby -Ilib -Itest test/integration/kernel_workers/command_gated_worker_test.rb
```

The first test file covers the log-once/no-churn contract: an unrepairable worker session,
a head that cannot return a result, and a head whose result the kernel refuses each log
exactly one error across repeated passes, the state file is byte-identical after repeat
passes, live sessions in the same pass still reconcile, an errored record without recorded
reconcile details is still polled and still reports its failure once, and a settled errored
head is retained until `/prune` removes it.

The settle-classification, unreplayable-session, and Pi client files cover the unreplayable-session
contract: the harness classifies the provider's rejection of a replayed `thinking` block as
`unreplayable_session` with a `fresh_session` recovery hint, and the kernel records it with
actionable reporting, never resumes it, continues the work in a fresh session on the same worktree
and branch without allocating a second worktree, repoints the queued dependent at the successor,
spends at most one restart, and keeps the shared worktree when the replaced record is pruned.

The dead-harness-process files cover the process-exit contract: the harness marks its own
process-gone error and keeps the exit status, stderr, and journalled `process_exit` event readable
after the process is gone; the kernel settles the worker on the first pass that sees that evidence
with the exit as the reason, never attaches or re-prompts it, records it once across repeated
passes, keeps it promptable on its own workspace, resolves a queued dependent by policy instead of
waiting on it, and leaves the ordinary transport-failure resume ladder unchanged.

The delivery-PR file covers the background-pass contract: a delivery PR refresh records forge state
and never lets an unavailable forge overwrite the last known state, a blocked forge lookup does
not stop another instance from running `ListAll` or `CreateIssue`, one tick honours both the
batch limit and the shared budget, and refresh schedules are spread so records do not all fall
due on the same tick.

The command-gated worker file covers current top-level `after_command` users: a gate is polled no
faster than its interval, passes and starts its worker through the ordinary queued-worker path,
hands the command's output over, expires into a cancellation (or a start under
`if_gate_expires: "run"`), is abandoned after three unevaluable checks, and survives a restart with
its budget intact. `completion_triggered_head_test.rb` covers the other owner: no head/checker worker
churn before the condition changes, restart-safe release, exactly-once head routing, gate output
handover, and both expiry policies.
