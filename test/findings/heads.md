# Findings — heads slice (head context, result parser, prompt/simple loops, runners)

Scope: `lib/meringue/heads/*` plus the kernel entry points those loops drive
(`SpawnHead`, `ApplyHeadResult`, `AnswerQuestion`). Tests live in
`test/integration/heads/` with shared doubles in `test/support/heads_support.rb`.
They replace the manual head-loop walkthrough.

All tests assert **current** behaviour. Where current behaviour looks wrong, the
test says so in a comment and the bug is recorded below. No production code was
changed in this slice.

## Bugs found

### 1. ~~`Engine#harness_client` is private, so the worker-wait path raises~~ **Fixed.**

The duplicate `harness_client`/`head_runner` definitions below the `private` keyword are gone;
the provider-aware accessors are now defined once, above `private`, and the `attr_reader` no
longer lists them. `HeadPromptLoopTest#test_worker_waiting_works_against_the_real_engine` and
`HeadSimpleLoopTest#test_waiting_for_workers_settles_the_spawned_worker` cover the working path,
and `FoundationLibraryBootTest#test_verbose_load_emits_no_warnings` fails the suite if any
redefinition warning comes back. The `HarnessAccessibleEngine` shim was deleted.

Original report:

### 1. `Engine#harness_client` is private, so the worker-wait path raises

`lib/meringue/kernel/engine.rb:134` declares `attr_reader :harness_client`, but
`lib/meringue/kernel/engine.rb:3634` redefines `harness_client` (and
`head_runner`) *after* the `private` keyword at line 493. The public reader is
therefore replaced by a private method.

`Heads::PromptLoop#wait_for_worker_results` (`prompt_loop.rb:173`) and
`Heads::SimpleLoop#wait_for_spawned_workers` (`simple_loop.rb:83`) both call
`engine.harness_client`, so any run with `wait_for_workers: true` raises:

```
NoMethodError: private method 'harness_client' called for an instance of Meringue::Kernel::Engine
```

Impact: `meringue heads` (`lib/meringue/cli.rb:140` passes
`wait_for_workers: true`) applies the head batch, then blows up before it can
settle the spawned worker; `SimpleLoop#run` swallows it into an `event: "error"`
payload on stderr. The TUI path is unaffected because `lib/meringue/cli.rb:78`
uses `wait_for_workers: false`, which returns early before touching the reader.

Likely fix: move the `harness_client` / `head_runner` overrides above the
`private` keyword (or re-expose them with `public :harness_client, :head_runner`).

Covered by:
- `HeadPromptLoopTest#test_worker_waiting_against_the_real_engine_raises_because_harness_client_is_private`
- `HeadSimpleLoopTest#test_waiting_for_workers_surfaces_the_private_harness_client_error`

The happy path of the wait/settle/complete flow is still exercised through a
test-only shim (`HeadsSupport::HarnessAccessibleEngine`) in
`HeadPromptLoopTest#test_waiting_for_workers_settles_them_and_records_pull_requests`.
Those two tests should start failing (and can be simplified) once the visibility
bug is fixed.

### 2. Question-answer routing is now covered (resolved P1-I9)

`/answer <question_id> <answer>` now records the answer and spawns a fresh head
with a prompt that includes the question, answer, original user message, and
scope. The prompt loop test asserts that the second head applies its routing
commands (`HeadPromptLoopTest#test_answering_a_question_spawns_a_head_to_route_the_unblocked_work`).

The head contract now also exposes the data needed for implicit answers:

- `routing_context.open_questions` embeds the open question records alongside
  `current_state_summary.open_question_count`
  (`HeadContextTest#test_open_question_records_are_surfaced_for_answer_inference`).
- `routing_context.question_being_answered` is populated for a clear prose
  reference such as `ANSWERING Q4 ...`, even when the head was not spawned with
  an explicit `question_id`
  (`HeadContextTest#test_question_being_answered_is_inferred_from_a_clear_prose_reference`).
- A single `HeadResult` may still pair `AnswerQuestion` with `PromptAgent` or
  `SpawnWorker`, and both commands are applied in one batch
  (`HeadQuestionAnsweringTest#test_head_result_can_answer_a_question_and_route_work_in_one_batch`).

## Rough edges (not clearly bugs, but surprising)

- A head runner that returns `nil` produces an *accepted* `SpawnHead` result, a
  head left in state with status `completed`, an empty `summary`, and
  `state_mutated: true` even though nothing was applied
  (`HeadPromptLoopTest#test_runner_returning_nothing_produces_an_empty_summary`).
  Nothing ever cleans that head up.
- A rejected/unknown command inside an otherwise valid batch leaves the head
  `blocked` and skips cleanup with reason `partially_applied`
  (`HeadPromptLoopTest#test_unknown_command_types_are_rejected_and_block_head_cleanup`).
  Intentional, but the head record stays in state indefinitely from the loop's
  point of view.
- `Heads::SimpleLoop` carries a private copy of the worker-wait helpers
  (`wait_for_spawned_workers`, `wait_for_worker`, `state_summary`,
  `head_result_from`, …) that `PromptLoop` already implements. The copies are
  dead code today; `handle_input` delegates to `PromptLoop`.
- `SimpleLoop#state_summary` and `PromptLoop#state_summary` return different
  shapes (`working_worker_count`/`active_head_count` only exist in the latter),
  so the stderr error payload from `SimpleLoop` is not comparable to the payload
  from a normal iteration.

## Verified-good behaviour worth keeping

- Head context excludes harness transcripts and secrets: worker candidates are
  built from an allow-list, so `harness_events`, `prompt`, `system_prompt`,
  `api_key`, and `pi_state` never reach the head
  (`HeadContextTest#test_context_never_embeds_harness_transcripts_or_secrets`).
  Long text is truncated at `ROUTING_TEXT_LIMIT` and activity at
  `ROUTING_ACTIVITY_LIMIT`.
- Heads cannot mutate state or files: mutations to the snapshot handed to a
  runner never reach the store, and only kernel-applied commands change state
  (`HeadPromptLoopTest#test_head_cannot_mutate_state_or_project_files_itself`).
- `ResultParser` accepts fenced and prose-wrapped JSON, rejects malformed JSON
  and bad envelope shapes with indexed error messages, and leaves unknown command
  names for the kernel to reject.
- Two heads can be in flight while a slash command runs to completion, because
  `SpawnHead` is applied outside the shared engine mutex
  (`HeadPromptLoopTest#test_multiple_concurrent_heads_do_not_block_user_input`).
- `FakeRunner`, `HarnessRunner`, and `PiRunner` all satisfy the same `#run`
  signature, and `HarnessRunner`'s split lifecycle
  (`spawn_head_session` / `await_head_result` / `close_head_session`) is what the
  kernel drives when a runner owns a session
  (`HeadRunnerParityTest`).
