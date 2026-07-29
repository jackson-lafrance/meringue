# Findings — input slice (router, slash commands, CLI, config)

Slice paths: `test/integration/input/**`, `test/support/input_support.rb`, `test/findings/input.md`.

Everything below was observed against the code in this worktree
(`meringue/integration-tests-for-input-routing-slash-comman-2d752ddd`, branched from `main`).
No production code was changed. Where behavior does not match the intended product
behavior, the tests assert the **current actual** behavior and the gap is recorded here.

## How to run

```bash
rake test
ruby -Ilib -Itest test/integration/input/input_router_test.rb
ruby -Ilib -Itest test/integration/input/input_slash_command_parser_test.rb
ruby -Ilib -Itest test/integration/input/input_question_answer_flow_test.rb
ruby -Ilib -Itest test/integration/input/input_kernel_convergence_test.rb
ruby -Ilib -Itest test/integration/input/input_cli_test.rb
ruby -Ilib -Itest test/integration/input/input_config_test.rb
```

All tests are hermetic: state/config/project directories live in `Dir.mktmpdir`,
heads are stubbed plain Ruby objects (`InputSupport::StubHeadRunner`), the harness
is `Meringue::Harness::FakeClient`, and no test reads or writes `~/.meringue`
(verified by comparing `~/.meringue/config.toml` and `~/.meringue/state.json`
mtimes across a full `rake test` run). No TTY is required.

## Confirmed real bugs / gaps

### 1. Answering an open question is a dead end (matches issue P1-I9)

`/answer <id> "<text>"` parses to a single `AnswerQuestion` kernel command. The
engine records the answer, flips the question to `answered`, and appends
`Answered question <id>.` — and that is all. No head is spawned with the answer,
so the answer never drives the work the question was blocking.

Evidence (`InputQuestionAnswerFlowTest#test_answering_a_question_does_not_yet_drive_follow_up_work`):
after answering, the applied command list is exactly `["AnswerQuestion"]`, the
payload has no `apply_head_result`, the stub head runner call count is unchanged,
and no issue or worker is created.

The plumbing needed for the fix already exists and is covered by tests:

- `SpawnHead` accepts `question_id`, rejects an unknown one (`question_not_found`),
  and passes it to the head runner.
- `Heads::Context#to_prompt_h` exposes `question_id` and
  `routing_context.question_being_answered` with `id`, `head_id`, `project_id`,
  `issue_id`, `question`, `context`, `status`, `answer`, `created_at`,
  `updated_at`.
- A single `HeadResult` may contain `AnswerQuestion` **and** routing commands
  (`SpawnWorker` on the question's issue); both are accepted in one batch
  (`test_head_result_may_pair_answer_question_with_routing_commands`).

Missing link: nothing in the input layer ever sets `question_id`. Both the router
and `Heads::PromptLoop` route `/answer` to `AnswerQuestion` only, and natural
language always routes to `SpawnHead` with `{"user_message" => text}` and no
`question_id` — so `question_being_answered` is `null` for every head spawned from
user input, including prose such as `ANSWERING Q1 I meant staging`
(`test_input_layer_never_populates_question_being_answered`).

### 2. Head context exposes only `open_question_count`

`Heads::Context` surfaces `current_state_summary.open_question_count` and a
suggested read-only command that dumps `open_questions` from the state file, but it
does **not** embed the open-question records. A head asked to infer an implicit
answer has to read the state file to see the candidates
(`test_head_context_surfaces_open_questions_only_as_a_count`). Adding full
open-question records to the context is part of issue P1-I9.

### 3. `Shellwords::ParseError` does not exist on modern Ruby

`Input::SlashCommandParser#parse` ends with `rescue Shellwords::ParseError => e`.
On Ruby 4.0.6 (and any Ruby where `Shellwords` does not define `ParseError`),
`Shellwords.split` raises `ArgumentError` for an unbalanced quote and evaluating
the rescue class raises `NameError: uninitialized constant Shellwords::ParseError`,
so the intended `InvalidSlashCommand` fallback is unreachable. Typing
`/answer Q1 "unterminated` therefore raises out of the parser instead of showing a
usage error.

`test_unbalanced_quotes_never_produce_a_normal_kernel_command` accepts either
outcome (raise, or `InvalidSlashCommand` on a Ruby that defines the constant) so it
stays green everywhere while still proving that malformed quoting never becomes a
normal kernel command. Suggested fix: `rescue ArgumentError`.

### 4. `SlashCommandParser.command_suggestion_records` requires a state hash

With an argument-suggestion prefix (`"/answer "`, `"/prompt "`, …) and the default
`state: nil`, `records_for_context` calls `state["questions"]` on `nil` and raises
`NoMethodError`. Callers must always pass `state:`. Not covered by an assertion
(a raising test here would just pin a crash), recorded for awareness.

### 5. `meringue --help` does not mention the question flow

The CLI help lists only the TUI-local commands (`/help`, `/quit`, `/theme`,
`/harness`, `/keybind`, `/jump`, `/recount`). `/questions`, `/answer`, `/dismiss`,
`/tree`, `/state`, `/project`, `/issue`, `/worker`, `/prompt`, `/kill`, `/prune`,
and `/clear` are only discoverable from in-app `/help`
(`InputCLITest#test_help_does_not_yet_document_the_question_answer_slash_commands`
pins this so the doc/help update for issue P1-I9 has to update the test too).

### 6. `reset-state` ignores `--state`

`reset-state` never parses runtime options, so `meringue reset-state --state PATH`
silently resets `MERINGUE_STATE_PATH` (or `~/.meringue/state.json`) instead of
`PATH`. Pinned in `test_reset_state_ignores_a_state_flag`.

## Notable-but-intentional behaviors pinned by these tests

- `/answer`, `/prompt`, `/kill`, `/project add`, `/issue create`, `/worker spawn`
  are lenient parsers: missing arguments still produce the kernel command with an
  empty/partial payload and the kernel rejects it (`question_id is required`,
  `answer is required`, `agent_not_found`, …). `/theme`, `/harness`, `/dismiss`,
  `/recount`, `/prune` reject locally with `InvalidSlashCommand`.
- `/project add /tmp` yields `{"path" => "/tmp", "name" => ""}` (empty string, not
  nil) because trailing tokens are joined; the kernel then falls back to the
  directory basename.
- Answering an already-answered question is **accepted** again and overwrites the
  stored answer; dismissing an answered question is rejected with
  `question_not_open`.
- The router is stateless: leading `/` (after `strip`) always bypasses the head,
  everything else becomes `SpawnHead`. Empty/whitespace/nil input still produces
  `SpawnHead`, which the kernel then rejects with `user_message is required`.
  Natural-language routing preserves raw text (including newlines and leading
  whitespace); the slash route stores the stripped input for the kernel log.
- Merely mentioning a question id (`what about Q1?`) is never treated as an answer.
- Env precedence for harnesses is `MERINGUE_*_HARNESS` > CLI flags > config >
  `pi`, because CLI flags are applied as config overrides while env vars are read
  last inside `Harness::Registry#provider_for`. This matches `docs/config.md`.
- `/theme <name>` writes only the engine's `config_path` and mutates the global
  `TUI::Style`; the tests wrap it in `with_preserved_tui_style` so the process-wide
  colorscheme is restored for sibling slices.

## Cross-slice overlap notes

- **`/prune`** (resolved during consolidation): the no-option `/prune` landed on `main`,
  so these tests now assert the shipped surface. `/prune` parses to `Prune` with an empty
  payload; the legacy words in `SlashCommandParser::PRUNE_COMPATIBILITY_ARGUMENTS`
  (`all`, `resolved`, `errored`, `completed`, `merged`) still parse and are passed through as
  an inert `selector`; anything else, or two words, is `InvalidSlashCommand` with the short
  usage message; and `/prune ` offers no argument suggestions
  (`test_prune_offers_no_argument_suggestions`,
  `test_legacy_prune_selector_words_are_accepted_as_no_op_aliases`).
- **P1-I9 implementation**: when explicit/implicit answer routing is implemented,
  `test_answering_a_question_does_not_yet_drive_follow_up_work`,
  `test_input_layer_never_populates_question_being_answered`,
  `test_head_context_surfaces_open_questions_only_as_a_count`, and
  `test_help_does_not_yet_document_the_question_answer_slash_commands` are the
  tests that must be flipped to the new expected behavior.
- The kernel-side result shape (`command_id`, `command_type`, `status`,
  `target_id`, `message`, `result`, `errors`, `log_entry_ids`) is asserted here
  only as a convergence contract; deeper engine coverage belongs to the kernel
  slice.
