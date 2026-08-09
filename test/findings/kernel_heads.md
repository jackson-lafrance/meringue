# Findings — kernel heads / head results / questions slice

Scope covered: `Meringue::Kernel::Engine` `SpawnHead`, `ApplyHeadResult`, the head command
journal / apply lease / recovery path, the question lifecycle (`AskQuestion`,
`AnswerQuestion`, `DismissQuestion`, HeadResult `questions`), and the log trail those
commands produce.

Test files:

- `test/integration/kernel_heads/spawn_head_test.rb`
- `test/integration/kernel_heads/apply_head_result_test.rb`
- `test/integration/kernel_heads/exactly_once_apply_test.rb`
- `test/integration/kernel_heads/questions_test.rb`
- `test/integration/kernel_heads/logging_test.rb`
- `test/integration/kernel_heads/unrouted_user_message_test.rb`
- `test/integration/kernel_heads/head_retry_test.rb`
- `test/integration/kernel_heads/removed_batch_target_test.rb`
- `test/support/kernel_heads_support.rb` (fake head runners, fake harness clients, stub
  workspace manager, stub forge client, tmpdir-scoped engine builder)

All tests are hermetic: no real Pi/harness processes, no `git`, no `gh`, no network, and
every state/config file lives under a per-test `Dir.mktmpdir`.

## Confirmed behavior (locked in by tests)

- Head ids are kernel-assigned and monotonic (`H1`, `H2`, ...); cleanup of an applied head
  does not rewind the counter.
- A head never mutates state: commands returned by the runner only take effect through
  `ApplyHeadResult`.
- A fully accepted batch removes (cleans up) the head record and releases its session;
  a batch with any rejected/failed command keeps the head with `status: "blocked"` and
  `head_result_apply_state: "partially_applied"` for inspection. A command skipped because
  its target was removed mid-flight is not a rejection for any of these purposes.
- A `blocked` head is retryable, because a rejected or failed command means the work behind it
  never happened. Retry is explicit (`/retry H<n>` or the TUI's retryable-head double-click),
  always starts a fresh head, never resumes or messages the old head session, and removes the old
  head row from the active tree while preserving lineage in logs/metadata. Selecting the head and
  typing is ordinary unscoped chat, and `/prompt` is worker-only. The retry head's prompt names
  the batch's accepted commands (reuse, never re-propose) and its rejected/failed ones (still
  unrouted), so a partially applied batch is recovered without routing the same work twice. Only a
  head that is still routing, or that applied every command it proposed, is refused. See
  `head_retry_test.rb`.
- Batch issue visibility is decided from the head's recorded spawn snapshot, not from live
  state. An issue the head saw at spawn and that a `/prune` or `/kill` removed before the
  result was applied is skipped as a no-op (`issue_removed_before_head_result_applied`,
  `Skipped ModifyIssue: …`, `info` for `ModifyIssue` and `warning` for `SpawnWorker`), counted
  separately in the batch summary, and leaves the head `completed`. An id the head never saw
  is still rejected as a prediction, and an id removed *before* the head was spawned is
  rejected with that removal named. Every rejected/skipped `ModifyIssue`, `SpawnWorker`, and
  `PromptAgent` message states the intent it dropped. See `removed_batch_target_test.rb`.
- The same skip covers a batch `PromptAgent` whose worker the prune removed and a batch `Kill`
  of a record that is already gone (`agent_removed_before_head_result_applied`, `warning` for
  the dropped prompt, `info` for the redundant kill). A typed `PromptAgent` for a pruned worker
  is still rejected, but names the removal (`Agent P3-I9-W2 no longer exists: it was removed by
  a prune at …`). Removal is read from `state.metadata.removed_issues` / `removed_agents`.
- A batch where *every* command was skipped leaves nothing applied, so the user's message is
  restated once as a `warning` (`Every command from head H36 targeted a record that was removed
  before its result was applied…`) and the head is cleaned up like any other head that routed
  nothing — not left `blocked`.
- A genuinely failed command (worker workspace provisioning timing out) plus the dependent
  command that cannot resolve it (`after_agent_reference_unresolved`) is a *different* cause and
  still yields `1 accepted, 1 rejected, 1 failed` with a `blocked` head.
- Predicted-id chaining works inside one batch (`AddProject` -> `CreateIssue` -> `SpawnWorker`
  with `P1` / `P1-I1`); symbolic issue references and unambiguous predicted ids are remapped
  to the batch-created issue so workers cannot land on another head's issue.
- Commands get default ids `<HeadID>-C<n>` and are applied in the proposed order.
- A batch that accepts nothing and records no question restates the user's message once as
  an `unrouted_user_message` log entry (`error` when commands were proposed and none
  applied, `warning` when the head proposed neither commands nor questions), with the full
  message in `details.user_message`. A batch that recorded a question is not reported as
  unrouted, because the question is already an actionable record. A deliberate no-work result uses
  an accepted `NoOp` command with a reason, which suppresses the unrouted warning and logs at info
  level. See `unrouted_user_message_test.rb`.
- One batch may put two workers on one issue it just created (research step, then the
  implementation step that consumes the report). Both bind the issue with `issue_from_command`;
  the later worker names its predecessor with `follow_up_of_command` for the visible lineage and
  `after_from_command` for the ordering, and neither worker is rerouted or rejected. A *predicted*
  predecessor worker id (`P1-I7-W1`) is still rejected once another head shifts the issue number,
  which is why the reference forms exist. Asserted in
  `test/integration/head_batch_target_binding_test.rb`.
- Unknown command types are rejected with `unknown_command`; snake_case aliases
  (`create_issue`) are canonicalized.
- Re-applying the same head result, recovering an interrupted batch, and a second kernel
  instance racing the same batch all produce exactly one issue, one worker, one question,
  and one "Spawned worker ..." log line.
- A head-routed spawn logs one worker-scoped line, the "Spawned worker ..." line itself.
  The old "Provisioning workspace for worker ..." line that preceded it was redundant and
  has been removed; failure paths still log their own error line.
- One clarification is one question record: a HeadResult `questions` entry plus a matching
  (or reworded) `AskQuestion` command resolves to the already stored question, and the
  duplicate command result carries no new log ids.
- Open questions never block unrelated routing, and questions outlive the head that asked
  them.

## Real-behavior notes / possible bugs (asserted as-is, not fixed here)

1. **`AnswerQuestion` has no status guard.** `DismissQuestion` rejects a non-open question
   with `question_not_open`, but `AnswerQuestion` accepts an already answered *or already
   dismissed* question and overwrites the stored answer, flipping a dismissed question back
   to `answered`. Asserted in
   `questions_test.rb#test_answering_twice_overwrites_the_stored_answer` and
   `#test_answering_a_dismissed_question_is_currently_accepted`.

2. **A rejected command does not stop the rest of the batch.** `ApplyHeadResult` keeps
   applying later commands, so a genuinely unreachable worker target is rejected rather
   than skipped as unreachable. Unambiguous predicted issue ids are remapped to the batch
   issue (`apply_head_result_test.rb#test_wrong_predicted_issue_id_is_remapped_to_the_batch_issue`).

3. **Head-batch recovery is only reachable through `ReconcileSessions`.**
   `recover_unapplied_head_results` and `recover_worker_reservations` are private, so the
   exactly-once recovery tests drive them via `apply("type" => "ReconcileSessions")` and read
   `result["result"]["recovered_head_results"]`.

4. **Question dedupe is scoped per head.** Two different heads asking the identical question
   produce `Q1` and `Q2`. That is intended for independent heads, but it means a re-spawned
   head answering/asking the same clarification will add another record.

5. **The head snapshot and prompt context contain full open-question records** (`id`,
   `question`, `context`, `status`, `head_id`, `project_id`, `issue_id`, `created_at`),
   allowing implicit-answer inference and follow-up routing. Asserted in
   `spawn_head_test.rb#test_head_runner_snapshot_includes_open_question_records` and the
   head/input question-answering integration tests.

6. **`ApplyHeadResult` on a head whose runner has no session** marks the head session
   `unavailable` with note `head_runner_has_no_session` instead of failing — useful seam for
   tests, and the behavior any non-session head runner gets.

7. **Intra-batch worker references reuse the issue-reference machinery.**
   `deferred_worker_batch_reference_test.rb` covers `after_from_command` /
   `after_agent_id: "@<command_id>"` on `SpawnWorker`: it resolves against the workers this
   batch already spawned, is rejected with `after_agent_reference_out_of_order` when it names
   a later command and `after_agent_reference_not_found` when it names no command in the
   batch, and marks the worker as a deliberate existing-issue target so the
   created-issue-needs-a-worker rerouting rule leaves it alone.
