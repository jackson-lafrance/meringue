# Findings — kernel worker lifecycle slice

Scope: `Meringue::Kernel::Engine` worker commands (`SpawnWorker`, `PromptAgent`, `Kill`,
worker completion/blocked/errored transitions), `Meringue::Sessions::WorkerSessionService`,
`Meringue::Harness::Registry`/`FakeClient` seams, and `Meringue::Workspace::Manager`
provisioning outcomes.

Test files added by this slice:

- `test/integration/kernel_workers/spawn_worker_test.rb`
- `test/integration/kernel_workers/spawn_worker_relationships_test.rb`
- `test/integration/kernel_workers/workspace_provisioning_test.rb`
- `test/integration/kernel_workers/prompt_agent_test.rb`
- `test/integration/kernel_workers/kill_test.rb`
- `test/integration/kernel_workers/worker_transitions_test.rb`
- `test/integration/kernel_workers/deferred_worker_chaining_test.rb`
- `test/support/kernel_workers_support.rb`

All tests assert **current actual behavior**. No production code was changed.

## Confirmed behavior (now locked by tests)

- Worker ids compose as `P<n>-I<n>-W<n>`, per-issue counters (`P1-I1-W1`, `P1-I1-W2`,
  `P1-I2-W1`).
- The kernel allocates the workspace *before* starting the harness and passes
  `workspace_path` as the harness `cwd`; `workspace_path`, `workspace_strategy`, and
  `workspace_branch` are persisted on the agent record along with
  `harness_metadata.cwd`, `delivery_branch`, `routing_action`, and
  `provisioning_state = "ready"`.
- Harness session identity (`harness`, `pid`, `harness_session_id`,
  `harness_session_file`) is recorded on the agent record after a successful spawn.
- A successful spawn writes exactly one worker-scoped log line (`Spawned worker P1-I1-W1 for
  P1-I1.`), emitted after allocation so its `details` carry the workspace path/branch the
  worker really got, including a uniquified `-2` fallback. There is no preceding
  "Provisioning workspace ..." line; the reservation phase is silent in the log and visible
  only as a `queued` worker plus `harness_metadata.provisioning_state`. A provisioning
  failure is still logged: the worker's only visible line is then the `error`.
- Human-facing naming holds: branch slugs and harness session names strip `P1-I1-W1`,
  `H2`, and `Q3` style orchestration ids (`Workspace::Manager#human_slug` /
  `Engine#human_delivery_title`).
- Relationship spawns set fields on both records: successor gets
  `follow_up_of_agent_id` / `replaces_agent_id`; predecessor gets
  `follow_up_agent_ids` (follow-up) or `replaced_by_agent_id` + `status = "killed"`
  (replacement). For a replacement, the successor's `spawn_session` call is recorded
  **before** the predecessor's `kill_session` call.
- Rejections are validated before any harness call: `issue_not_found`,
  `related_agent_not_found`, `related_agent_issue_mismatch`, `agent_not_replaceable`,
  mutual exclusion of `follow_up_of_agent_id` / `replace_agent_id`, and
  `workspace_path must be an existing directory`.
- `PromptAgent` maps `normal|steer|follow_up` to routing actions
  `resume_session|steer_active_session|queue_follow_up`, increments
  `harness_metadata.prompt_count`, records `last_prompt_mode` / `last_prompted_at`, and
  mirrors the routing action onto the issue (`last_routing_action`, `last_agent_id`).
- The recorded mode is the mode the harness actually delivered. When a client reports a
  substitution (`metadata["delivered_prompt_mode"]`, with `requested_prompt_mode` and
  `prompt_mode_note`), the kernel records `last_prompt_mode` / `routing_action` from the
  delivered mode, keeps `requested_prompt_mode` on the worker, and states the coercion in
  the same delivery log line. A `normal` prompt into a streaming session is therefore
  accepted and queued as a follow-up instead of failing, and is delivered exactly once (no
  `pending_prompts` entry, no redelivery when the session settles).
- `WorkerSessionService::Session#submit(mode: "auto")` selects `steer` when the session
  view reports `session_state == "streaming"` and `normal` otherwise.
- Transient harness errors (anything including `Harness::TransientSessionError`) are not
  failures: the prompt is stored in `harness_metadata.pending_prompts` and redelivered by
  `ReconcileSessions`, which then clears the pending entry and increments
  `prompt_count` exactly once.
- `Kill` stops the harness session, cascades through child issues and workers (and every
  issue of a project), and **never** deletes a workspace directory — the git worktree and
  its `.git` link file survive.
- Worker completion records `last_assistant_text`, `settled_event_count`, `completed_at`,
  and rolls the issue/project up to `completed`.

## Behavioral notes / possible bugs (behavior asserted as-is)

1. **Duplicate `prompt_agent` definition in `lib/meringue/kernel/engine.rb`.** There are
   two private `def prompt_agent` bodies (around lines 799 and 2147). Ruby keeps the last
   one, so the first implementation is dead code. The two differ meaningfully: the dead
   one rejects only `killed` agents (not `errored`), rejects on a blank `harness` with
   `agent_has_no_harness_session`, accepts `message`/`Message` payload aliases, logs
   `"Prompted agent <id>."` with `source_type: "worker"`, and does no
   pending-prompt/mode bookkeeping. Tests assert the live (second) implementation:
   `agent_not_resumable` for killed/errored, `missing_harness_session`, and the
   mode-specific log messages. Deleting the dead copy would be a safe cleanup, but note
   that it also means `PromptAgent` no longer accepts a `message` payload alias.

2. **Every failed/rejected command logs twice.** `fail_worker_reservation` (or the
   equivalent scoped handler) writes a target-scoped log, and `failed_result` /
   `rejected_result` add a second kernel-scoped `"Failed SpawnWorker: …"` /
   `"Rejected …"` entry. Tests assert both entries exist rather than a single one.

3. **`reconcile_candidate?` skips agents whose harness is `"fake"`.** A worker spawned
   through `Harness::FakeClient` can therefore never be reconciled (never completed,
   blocked, or errored by `ReconcileSessions`). This is presumably deliberate, but it
   means the shipped fake client cannot exercise reconciliation at all; the slice's
   recording client reports a selectable provider name (`pi`) while still running
   in-process so those transitions can be covered.

4. **`Kill` removes records instead of retaining a killed row.** After killing an agent,
   issue, or project the records are deleted from `agents`/`issues`/`projects` (and
   scrubbed from `issue.agent_ids`), so the only lasting evidence is the log entry and its
   `details.killed_agent_ids` / `removed_issue_ids`. Killing an issue keeps the parent
   project registered; killing a project removes the project row.

5. **Re-completing a worker keeps the first result.** `mark_worker_completed` on an
   already-completed worker returns `accepted` with `"is already completed"` and does not
   overwrite `last_assistant_text` or emit a second completion log.

6. **Workspace collisions silently uniquify.** A pre-existing non-empty directory at the
   planned worktree path makes the manager retry with `-2` appended to both the branch and
   the path, and the spawn still succeeds (worker gets `meringue/<slug>-<hash>-2`). Only
   after `ALLOCATION_ATTEMPT_LIMIT` (3) collisions does `SpawnWorker` fail; the reserved
   worker record is then kept with `status = "errored"` and
   `harness_metadata.provisioning_state = "failed"` plus `provisioning_errors`, and the
   issue rolls up to `errored`. No half-written session fields are left behind
   (`harness_session_id` and `pid` stay `nil`).

7. **Harness spawn failure releases the fresh worktree.** When the harness raises during
   `spawn_session`, the created worktree directory is removed
   (`cleanup_worker_workspace_safely`) and the worker record is marked `errored`. This is
   the one path where a worker workspace *is* deleted, and it only applies to a workspace
   that this attempt just created.

8. **Non-git project roots fall back to sharing the project root as cwd.** Strategy is
   `project_root`, `workspace_branch` is `nil`, and
   `harness_metadata.workspace_note = "project root is not inside a git repository"`.
   Multiple workers on such a project all get the same cwd, so they are not isolated from
   each other; worth flagging as a product-level risk rather than a code defect.

9. **`cancel_agent_turn` parks the worker in `idle`.** `idle` is a documented lifecycle
   status (`State::Models::LIFECYCLE_STATUSES`), the harness session is preserved, and only
   `abort_session` is called — never `kill_session`.

10. **Worker resume backoff is fixed at three attempts.** With a session that can neither
    be read nor reattached, the first two `ReconcileSessions` runs leave the worker
    `blocked` (`reconcile_state = "resume_failed"`), the third marks it `errored`
    (`reconcile_state = "terminal_error"`), and afterwards the worker is no longer a
    reconcile candidate (`checked_count` drops to 0), so it will never be retried without
    manual intervention.

## Deferred (queued-after) workers

`deferred_worker_chaining_test.rb` covers the `SpawnWorker` `after_agent_id` chaining
primitive. Unlike the rest of this slice, it asserts behavior added by the same change, so
these are contract assertions rather than archaeology:

- A dependent is an ordinary `queued` worker record with `after_agent_id` and
  `harness_metadata.deferred_spawn`, and no harness session is created until it activates.
- Activation happens on the worker-settle path (`mark_worker_completed`) and in
  `ReconcileSessions`. The reconcile hook is what recovers a predecessor that settled while
  Meringue was not running, which the restart test drives with a second engine over the same
  state file.
- The handover block is composed at activation time from the predecessor's
  `harness_metadata.last_assistant_text`, so the dependent's prompt carries the real final
  report rather than a promise of one.
- Failure policy: `errored` cancels by default and starts the dependent when
  `if_predecessor_fails: "run"`; `Kill` cancels the whole queue behind the killed agent in the
  same command; a replacement re-points the queue at the successor; a removed predecessor
  cancels with a warning. Cancellation removes the never-started record and leaves a warning
  log naming both workers.
- `/prune` gains a `pending_deferred_dependents` retention blocker so a settled predecessor
  cannot be removed from under a worker that is still queued behind it.
- `Recount` renames a queued dependent and its predecessor together, and the dependency still
  activates afterwards.

## Test hygiene notes

- Every test runs inside a per-test `Dir.mktmpdir`: state file, workspace root, config
  path, and any git repository used as a project root. `~/.meringue` is never touched and
  the Meringue checkout itself is never used as a project.
- No network access: the engine is constructed with an offline forge client, so delivery
  pull-request refreshes never shell out to `gh`.
- No real harness processes: all harness interaction goes through
  `KernelWorkersSupport::RecordingHarnessClient` (and its broken-session subclass).
- Real `git` is used for worktree provisioning against throwaway repositories, which is
  what makes this slice's runtime (~5s per file) dominated by git rather than Ruby.

## Settle classification (network-aborted turns)

Added by the "mark network-aborted agents errored" slice:

- `test/integration/kernel_workers/settle_classification_test.rb`

This slice changed behavior rather than only recording it. Previously a settled harness
session was treated as a completion, so a turn killed by a dropped connection was logged
`Worker <id> completed.` with an empty `last_assistant_text` and rolled its issue up to
`completed`. `Engine#mark_worker_completed` now classifies the settle first:

- a turn with a real final assistant message still settles as `completed`
- a harness-reported failed turn, or a transport event with no final message at all,
  settles as `errored` with `harness_metadata.settle_failure`, `settle_state = "failed"`,
  `status_reason`, and an `error`-level `Worker <id> errored without finishing: …` log
- `completed_at` is never written for a failed settle, so an issue cannot roll up to
  `completed` behind it

Notes for future slices:

- Re-observing an already-recorded dead turn is a silent no-op (`changed => false`, no log),
  which keeps the 2s reconciliation loop from spamming an already-errored record.
- Failure evidence older than `harness_metadata.last_prompted_at` is treated as stale, so a
  recovered worker is not re-errored from the persisted evidence of the turn it recovered from.
- A worker errored this way stays resumable: `PromptAgent` accepts it while it still has a
  session reference, queued `pending_prompts` are still redelivered, and delivering a prompt
  clears `settle_failure` into `previous_settle_failure`.
- Interaction with deferred workers (`after_agent_id`): a dependent queued behind a worker whose
  turn died mid-flight **keeps waiting** instead of being cancelled, because that predecessor can
  still be continued and a wifi blip must not delete queued work. `if_predecessor_fails: "run"`
  still activates immediately, killing the predecessor still cancels the chain, and an errored
  predecessor with no resumable session still cancels the dependent exactly as before. Spawning
  behind an already settle-failed worker is queued rather than rejected.
