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
- `test/integration/kernel_maintenance/process_identity_test.rb`
- `test/support/kernel_maintenance_support.rb`
- shared contract files `Rakefile` and `test/test_helper.rb` (created verbatim)

All tests are hermetic: state lives in a per-test `Dir.mktmpdir`, the forge client
and harness sessions are stubbed in-process, and no real Pi process is started.
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

1. **Recount aborts with `KeyError` for an orphaned issue.** An issue whose
   `project_id` no longer exists makes `State::Recounter.worker_id_map` raise
   `KeyError: key not found: "<issue id>"` (recounter.rb:58) before the friendlier
   `validate_integrity!` `ArgumentError` can run. The kernel surfaces this as a
   `failed` command result and, importantly, leaves the persisted state file
   untouched. A cleaner error (or a repair step for orphaned records) would be an
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
6. **Prune now couples managed worktree cleanup to record removal.** Clean, unlocked,
   ownership-verified Meringue worktrees are removed before their issue/worker records;
   dirty, locked, ambiguous, or failed cleanups retain both the worktree and state bundle
   for retry. Missing/already-removed worktrees are idempotent, project-root/dedicated
   directories are untouched, and immediate `Kill` retains its existing no-worktree-delete
   behavior. Covered by the two prune-worktree test files listed above.
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
    Two deliberate preservations are asserted: IDs inside human-readable text stay as history, and
    composite correlation IDs (`<agent>-PP1`, `<goal>-IT1-ATTEMPT`) stay verbatim so exactly-once
    dedupe keeps matching.

The original maintenance test slice did not change production code. Later prune-worktree
lifecycle work updated the behavior called out in items 4 and 6, and the reference-integrity work
in item 13 changed `State::Recounter` and the Recount save path in `Kernel::Engine`.
