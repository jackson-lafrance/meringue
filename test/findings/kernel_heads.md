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
  `head_result_apply_state: "partially_applied"` for inspection.
- Predicted-id chaining works inside one batch (`AddProject` -> `CreateIssue` -> `SpawnWorker`
  with `P1` / `P1-I1`), and a wrong prediction is rejected with `project_not_found` /
  `issue_not_found` without creating records.
- Commands get default ids `<HeadID>-C<n>` and are applied in the proposed order.
- Unknown command types are rejected with `unknown_command`; snake_case aliases
  (`create_issue`) are canonicalized.
- Re-applying the same head result, recovering an interrupted batch, and a second kernel
  instance racing the same batch all produce exactly one issue, one worker, one question,
  and one "Spawned worker ..." log line.
- One clarification is one question record: a HeadResult `questions` entry plus a matching
  (or reworded) `AskQuestion` command resolves to the already stored question, and the
  duplicate command result carries no new log ids.
- Open questions never block unrelated routing, and questions outlive the head that asked
  them.

## Real-behavior notes / possible bugs (asserted as-is, not fixed here)

1. **`AnswerQuestion` records the answer and nothing else** (matches the P1-I9 report).
   Answering an open question marks it `answered`, stores the answer, and logs
   `Answered question Q1.` — it does not spawn a head, does not reuse the question's
   `project_id`/`issue_id` to route work, and does not prompt or create any worker.
   Asserted in `questions_test.rb#test_answering_a_question_does_not_route_any_work_today`.
   If the answer flow starts driving a head, that test is the one to update.

2. **`AnswerQuestion` has no status guard.** `DismissQuestion` rejects a non-open question
   with `question_not_open`, but `AnswerQuestion` accepts an already answered *or already
   dismissed* question and overwrites the stored answer, flipping a dismissed question back
   to `answered`. Asserted in
   `questions_test.rb#test_answering_twice_overwrites_the_stored_answer` and
   `#test_answering_a_dismissed_question_is_currently_accepted`.

3. **A rejected command does not stop the rest of the batch.** `ApplyHeadResult` keeps
   applying later commands, so a `SpawnWorker` that depended on a rejected `CreateIssue`
   is rejected with `issue_not_found` rather than skipped as unreachable. That is the
   current contract (`apply_head_result_test.rb#test_wrong_predicted_issue_id_rejects_only_the_dependent_command`),
   but it means one bad predicted id produces two rejection log lines.

4. **Head-batch recovery is only reachable through `ReconcileSessions`.**
   `recover_unapplied_head_results` and `recover_worker_reservations` are private, so the
   exactly-once recovery tests drive them via `apply("type" => "ReconcileSessions")` and read
   `result["result"]["recovered_head_results"]`.

5. **Question dedupe is scoped per head.** Two different heads asking the identical question
   produce `Q1` and `Q2`. That is intended for independent heads, but it means a re-spawned
   head answering/asking the same clarification will add another record.

6. **The head snapshot already contains full open-question records** (`id`, `question`,
   `context`, `status`, `head_id`, `project_id`, `issue_id`, `created_at`), so the
   implicit-answer inference described in P1-I9 has the data it needs at the snapshot level;
   what is missing is the kernel-side follow-through in item 1.
   Asserted in `spawn_head_test.rb#test_head_runner_snapshot_includes_open_question_records`.

7. **`ApplyHeadResult` on a head whose runner has no session** marks the head session
   `unavailable` with note `head_runner_has_no_session` instead of failing — useful seam for
   tests, and the behavior any non-session head runner gets.
