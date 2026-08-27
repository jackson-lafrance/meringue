# Kernel maintenance slice findings

Slice: `kernel_maintenance` — Prune, Kill/ClearState, ReconcileSessions, Recount,
plus the process-identity evidence those paths rely on.

Files added by this slice (plus later prune-worktree lifecycle coverage):

- `test/integration/kernel_maintenance/prune_resolved_test.rb`
- `test/integration/kernel_maintenance/prune_worktree_cleanup_test.rb`
- `test/integration/kernel_maintenance/prune_merged_pull_request_test.rb`
- `test/integration/kernel_maintenance/prune_responsiveness_test.rb`
- `test/integration/workspace/manager_prune_cleanup_test.rb`
- `test/integration/kernel_maintenance/prune_errored_test.rb`
- `test/integration/kernel_maintenance/clear_state_test.rb`
- `test/integration/kernel_maintenance/reconcile_sessions_test.rb`
- `test/integration/kernel_maintenance/recount_test.rb`
- `test/integration/kernel_maintenance/recount_reference_integrity_test.rb`
- `test/integration/kernel_maintenance/recount_history_test.rb`
- `test/integration/kernel_maintenance/process_identity_test.rb`
- `test/support/kernel_maintenance_support.rb`
- shared contract files `Rakefile` and `test/test_helper.rb` (created verbatim)

All tests are hermetic: state lives in a per-test `Dir.mktmpdir`, the forge client
and harness sessions are stubbed in-process, and no real harness process is started.
Verified by running the suite with `HOME` pointed at an empty temp directory: the
suite passes and creates nothing under that fake `HOME`, so `~/.meringue` is never
touched.

## Overlap with concurrent work (resolved during consolidation)

The `/prune` simplification landed on `main` while this slice was being written, so these
tests were updated to the shipped behavior:

- `Prune` takes no options. One pass removes resolved (completed/killed) **and** errored
  records; a legacy `selector` word is recorded as `requested_selector` for traceability and
  changes nothing. The old `selector` / `reason` result keys are gone.
- The summary message is now `"Pruned N issues, M agents, K worktrees, and P projects."` — one line per
  pass. The agent count covers every removed agent record (issue-owned workers and heads plus
  standalone errored heads), the worktree count covers the managed worktrees actually removed, and
  successful worktree cleanups no longer log one `"Removed managed worktree for worker …"` line each.
  Blocked cleanups are still logged individually at `warning`. The killed-record prune inside
  `ReconcileSessions` logs the same counts with a `"Pruned killed records:"` prefix.
- Blocking worker statuses are `queued`, `working`, `blocked` — an `errored` or `idle` worker
  no longer retains its issue.
- The project blocker is named `project_not_terminal`.
- An unknown selector value is no longer rejected by the kernel; `/prune bogus` is rejected by
  the slash-command parser instead (see `test/integration/input/input_slash_command_parser_test.rb`).

## Behaviour worth flagging (tests assert current actual behaviour)

1. ~~**Recount aborts with `KeyError` for an orphaned issue.**~~ **Fixed:** the pass now refuses
   up front with `Recounter::UnrecountableStateError`, naming the orphaned records and their
   missing parents, and the kernel reports it as a `rejected` result rather than an opaque
   `failed` one. State is still never written. Original report:
   **Recount aborts with `KeyError` for an orphaned issue.** An issue whose
   `project_id` no longer exists is not in the id mapping, so building that mapping raises
   `KeyError: key not found: "<issue id>"` before the friendlier `validate_integrity!`
   `ArgumentError` can run. The kernel surfaces this as a
   `failed` command result and, importantly, leaves the persisted state file
   untouched (the pass mutates a copy, so the caller's in-memory state is untouched too). A cleaner error (or a repair step for orphaned records) would be an
   improvement. Asserted in `test_orphaned_issue_aborts_the_recount_before_integrity_validation`
   and `test_orphaned_issue_recount_fails_the_command_without_writing_state`.
2. **Recount is refused whenever any head record exists**, not only when a head
   result is awaiting application. `Engine#recount` rejects with
   "AgentTree IDs were not recounted because a head result is still in flight."
   for any `type == "head"` agent, including one that has already applied its
   result but has not been cleaned up. `docs/recount.md` describes the narrower
   "awaiting application" rule.
3. **ReconcileSessions never assigns `idle`.** `AGENTS.md` says reconciliation
   should "mark missing/crashed processes as `errored` or `idle` depending on
   evidence", but the implementation only ever writes `working`, `completed`,
   `blocked` (resume failed, will retry), or `errored`. `idle` is produced
   elsewhere (`Engine#cancel_agent_turn`). This is behaviour/doc drift, not a
   crash; the tests assert the statuses the kernel actually writes and additionally
   assert that no undocumented status/level ever appears.
4. **The killed-record sweep has no generic summary log.** It does emit per-worker
   worktree cleanup info/warning logs when a managed workspace is present, and returns
   those IDs from reconciliation. Killed records without a managed worktree still
   disappear without a separate sweep summary; the reconcile result reports
   `pruned_issue_ids` / `pruned_agent_ids`.
5. **Questions are never removed by pruning.** Open questions *block* pruning of
   their issue and project, while `answered`/`dismissed` question records survive
   the removal of the issue they point at (their `issue_id` then dangles). Asserted
   in `test_answered_and_dismissed_questions_do_not_block_pruning`.
6. **Prune separates managed worktree cleanup from record removal.** Clean, unlocked,
   ownership-verified Meringue worktrees are removed before their issue/worker records;
   dirty, locked, ambiguous, or failed cleanups preserve the worktree and branch while
   eligible terminal records are still pruned. Each failure remains structured and is
   logged at `warning`; successful removals alone count as worktrees. Missing/already-removed
   worktrees are idempotent, project-root/dedicated directories are untouched, and immediate
   `Kill` retains its existing no-worktree-delete behavior. Covered by the two prune-worktree
   test files listed above.
7. **PR retention rules**: only `merged` and `closed` pull requests are treated as
   settled. `open`, draft (`state == "open"` plus `is_draft`), and unresolvable
   (`state == "unknown"`, e.g. `gh` failing) PRs all block pruning of the issue and
   therefore of its project. A pull request Meringue already verified and persisted as
   `merged` is resolved from state instead of the forge (merging is terminal there), so an
   unreachable or slow `gh` no longer downgrades settled work to `unknown`; `closed` is
   still re-checked because it can be reopened. The bounded lookup phase runs
   retention-critical lookups before exploratory candidate URLs, and every retained record's
   reason plus `forge_lookup` counters are reported in the prune message/log details. Covered
   by `prune_merged_pull_request_test.rb`.
8. **Project removal requires both** a terminal (`completed`/`killed`/`errored`) project status
   and every child issue being eligible; otherwise the eligible issues are removed
   and the project record is retained and refreshed.
9. **Session identity beats the persisted agent id.** `find_session_agent` resolves
   a poll/completion result by `harness_session_id`, then `harness_session_file`,
   then `pid`, and returns `nil` when session evidence exists but matches no agent.
   That is what makes a renumbered (recounted) worker adoptable and stops a stale
   result from being applied to the wrong agent.
10. **Recovery budgets observed by the tests**: a worker gets
    `WORKER_RECONCILE_RESUME_MAX_ATTEMPTS` (3) resume attempts, sitting in `blocked`
    with `reconcile.state == "resume_failed"` in between, and errors afterwards. A
    head keeps `working` inside the 30s transient grace window
    (`reconcile.state == "transient_error"`) and errors once the grace window and
    the single recovery attempt are spent. A resumed session that is already
    streaming is intentionally **not** re-prompted.
11. **Recount counter semantics**: project/question/issue/worker counters are
    rebuilt from the compacted tree, while the head counter and the append-only log
    counter/log ids and conversation message ids are left alone, so log id
    monotonicity survives (`L7` stays `L7`, the recount log becomes `L8`) and the
    next created records continue after the compacted range (`P1-I3`, `P3`).
12. **ClearState** wipes projects/issues/agents/questions/logs, all counters, and
    the persisted visible log buffer (`conversation`), and leaves a valid loadable
    state file with `schema_version` and metadata timestamps.
13. **Recount referential integrity** (`recount_reference_integrity_test.rb`). The rename now
    sweeps the whole state document rather than a per-record field list, and the pass runs on a
    copy that is only swapped in after validation. Two reference classes were genuinely stranded
    before this work: `goals[].last_worker_id` (Kill's only handle on the session a paused goal
    owns, and only incidentally repaired when the goal still had an `active_worker_id`) and
    `conversation.messages[].source_id` (the chat pane resolves it to an agent record and uses it
    to deduplicate a completion message against the kernel log for the same event). The nested
    `harness_metadata.deferred_spawn` copy of a queued worker's dependency was already handled,
    because free-form harness metadata was already swept; it is now locked in by tests.
    Validation additionally fails the command when any ID that resolved before the pass does not
    resolve after it, naming the path, while tolerating references that were already dangling.
    Composite correlation IDs (`<agent>-PP1`, `<goal>-IT1-ATTEMPT`) stay verbatim so exactly-once
    dedupe keeps matching. The other preservation asserted there — IDs inside human-readable text
    staying as history — was **superseded** by item 14, which is why that expectation now lives
    inverted in `recount_history_test.rb`.
14. **Recount resolves ids inside history, and retires ids it cannot resolve** (added with
    `recount_history_test.rb`). Item 13 tolerated an already-dangling id and left ids in text
    alone. Because compacting *reuses* ids, both are how a pruned worker's history ends up
    rendered under whichever live record inherited its id (reported: a live World worker showing a
    completed Meringue worker's report and PR). The pass now resolves every id it can rename:
    references *and* narrative text follow a surviving record, dangling references are cleared in
    the live orchestration slots the kernel acts on, and a dangling id in append-only history or
    prose is marked `(old id)` so the line stays readable but resolves to nothing. Validation is
    correspondingly strict: after the pass, every id still spelled in state must name a live
    record, or the whole recount is refused rather than persisting misattributed history. Opaque
    evidence (paths, branches, argv, URLs, harness snapshots, composite correlation ids, a previous
    pass's `mappings`/`last_recount`) and lower-case ids quoted from user text are skipped.

14. **A harness process that exits was only discovered by trying to resume it**
    (`test/integration/kernel_workers/dead_harness_process_test.rb`,
    `test/integration/harness/pi_client_process_exit_test.rb`). `poll_agent_session`'s rescue
    treated every poll failure the same, so a `PiClient::ProcessExitedError` ("has no live process
    and no completed assistant response") entered the resume ladder and spent all three
    `WORKER_RECONCILE_RESUME_MAX_ATTEMPTS` on `prompt` RPCs that could only hit the 30s command
    timeout. The user-visible failure was therefore `RpcTimeoutError` on `"prompt"`, with the real
    `ProcessExitedError` demoted to `original_error_*`, and each attempt left the harness process
    its `attach_session` had just started running untracked against the same session file. Fixed
    here: the harness marks the error (`Harness::SessionProcessGoneError`), the kernel settles on
    the first pass that sees it (`settle_failure.kind: "harness_process_exited"`), and a resume that
    fails after attaching kills what it started.

    Two related evidence bugs were fixed with it: `PiClient#read_events` required a *live* process,
    so the `process_exit` event the client journals on its way out (with exit status) was never
    drained - and could not be, because `get_state` raises first for a dead session. Nothing in
    Meringue ever printed the exit. `PiClient#session_exit_evidence` now reports the same evidence
    in a harness-neutral shape.

Two real gaps found while investigating this and deliberately left out of scope, because neither is
what the reported incident was:

- **No progress signal for a worker that is genuinely quiet.** Meringue records `is_streaming` and
  `prompt_count`, but nothing warns when a `working` worker produces no session events for a long
  time while its process is still alive. In the incident the worker really did work for ~36 of its
  ~37 silent minutes, so a stall warning would not have caught it any earlier than the process-exit
  detection does. A heartbeat/idle-warning mechanism is a separate design (it needs a per-harness
  notion of "expected quiet", and it must not punish long tool calls).
- **`PiClient::DEFAULT_COMMAND_TIMEOUT` (30s) is spent per failed RPC.** Skipping the resume ladder
  removes the three timeouts this incident paid, but any *other* unreachable-but-alive session still
  costs 30s per attempt inside a serial reconcile pass. Changing that timeout affects every Pi RPC
  and belongs with the reconcile-pass budget work, not here.

The original maintenance test slice did not change production code. Later prune-worktree
lifecycle work updated the behavior called out in items 4 and 6, and the reference-integrity work
in item 13 changed `State::Recounter` and the Recount save path in `Kernel::Engine`. 
The dead-harness-process work in item 14 changed `Kernel::Engine`, `Harness::PiClient`, and 
`Harness::Client`.

## Pruning a shared worktree

Worktree sharing between related workers broke the one-worker-one-path assumption that
`cleanup_pruned_worker_workspaces!` was written against. Two rules now keep both halves honest:

- A pruned worker whose worktree another *retained* worker still shares skips cleanup with
  `status: "skipped"`, `reason: "workspace_shared_with_retained_worker"`, and `success: true`. The
  record goes immediately; failing instead would retain a record prune can never clear and warn
  about it on every pass.
- Workers being pruned in the same pass no longer contribute to `protected_paths`. Without that, a
  shared worktree whose every sharer was pruned together would deadlock: each sharer would refuse
  on account of the others and the directory would never be removed.

The net effect is that a shared worktree is removed exactly once, on the pass that prunes the last
worker using it, and its delivery branch survives as before. Covered by
`test/integration/kernel_maintenance/prune_worktree_cleanup_test.rb` and the lifecycle tests in
`test/integration/kernel_workers/workspace_reuse_test.rb`.
in items 13 and 14 changed `State::Recounter`, the Recount save path in `Kernel::Engine`, and (for
item 14) the TUI's post-recount reload of its own presentation buffers.
