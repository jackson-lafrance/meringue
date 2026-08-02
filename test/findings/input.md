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

## Question-answering behavior now covered

`/answer <id> "<text>"` records the answer, closes the question, and spawns a
fresh head to route the work the answer unblocks. The input tests now assert the
nested routing result and the head-runner call that receives the synthesized
answer prompt (`test_answering_a_question_spawns_a_head_that_routes_follow_up_work`).

Natural-language replies that clearly reference one open question populate
`routing_context.question_being_answered`, and head context embeds the full
`routing_context.open_questions` records so the head can infer whether to propose
`AnswerQuestion` plus the command that acts on the answer.

## Confirmed real bugs / gaps

### 1. `Shellwords::ParseError` does not exist on modern Ruby

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

### 2. `SlashCommandParser.command_suggestion_records` requires a state hash

With an argument-suggestion prefix (`"/answer "`, `"/prompt "`, …) and the default
`state: nil`, `records_for_context` calls `state["questions"]` on `nil` and raises
`NoMethodError`. Callers must always pass `state:`. Not covered by an assertion
(a raising test here would just pin a crash), recorded for awareness.

### 3. `meringue --help` does not mention the question flow

The CLI help lists only the TUI-local commands (`/help`, `/quit`, `/theme`,
`/harness`, `/keybind`, `/jump`, `/recount`). `/questions`, `/answer`, `/dismiss`,
`/tree`, `/state`, `/project`, `/issue`, `/worker`, `/prompt`, `/kill`, `/prune`,
and `/clear` are only discoverable from in-app `/help`
(`InputCLITest#test_help_does_not_yet_document_the_question_answer_slash_commands`
pins this so the doc/help update for issue P1-I9 has to update the test too).

### 4. `reset-state` ignores `--state`

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
- **Question answering**: explicit `/answer` and clear prose answers now drive routing through normal tests. `test_help_does_not_yet_document_the_question_answer_slash_commands` remains the CLI-help follow-up for exposing that flow outside in-app `/help`.
- The kernel-side result shape (`command_id`, `command_type`, `status`,
  `target_id`, `message`, `result`, `errors`, `log_entry_ids`) is asserted here
  only as a convergence contract; deeper engine coverage belongs to the kernel
  slice.
