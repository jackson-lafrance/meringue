# Testing

Meringue has one automated suite: Minitest, driven by Rake, with no dependencies beyond `rake` and `minitest` (both ship with Ruby). Tests replaced the old ad-hoc `scripts/*_smoke.rb` workflow for everything that can be checked without a real harness.

## Running the suite

Everything:

```bash
rake test
```

or, without Rake:

```bash
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require File.expand_path(f) }'
```

One file:

```bash
ruby -Ilib -Itest test/integration/foundation/cli_entrypoint_test.rb
```

One test:

```bash
ruby -Ilib -Itest test/integration/foundation/cli_entrypoint_test.rb --name test_help_flags_describe_the_commands_and_succeed
```

Useful Minitest flags: `--name /pattern/` to filter by regexp, `--seed N` to reproduce an ordering, `--verbose` to list each test.

Inside a bundle, prefix with `bundle exec` (`bundle exec rake test`).

## Layout

```
Rakefile                       # rake test task (libs: lib, test; glob: test/**/*_test.rb)
test/test_helper.rb            # load path setup + require "meringue" + minitest/autorun
test/support/                  # shared, area-scoped helpers (no tests)
test/integration/<area>/       # component/area tests, e.g. foundation, kernel, heads, state, tui
test/e2e/                      # end-to-end flows across the CLI/kernel/heads boundary
test/findings/                 # notes about real bugs found while writing tests
```

## Conventions

- File names end in `_test.rb`; the Rake glob is `test/**/*_test.rb`.
- Each file begins with `require "test_helper"` (never `require_relative`), because the Rake task and the single-file command both put `test/` on the load path.
- Each file defines a uniquely named subclass of `Minitest::Test`, prefixed by its area (for example `class FoundationCliEntrypointTest < Minitest::Test`). Unique names keep parallel work from colliding.
- Tests are hermetic: no network, no real Pi/Claude/Antigravity processes, no dependence on installed harness CLIs, and no reads or writes under `~/.meringue`. Use `Dir.mktmpdir` for any filesystem work, and `Meringue::Harness::FakeClient` / `Meringue::Heads::FakeRunner` for harness behavior.
- Tests are fast and deterministic: no `sleep`-based coordination where an injected clock or a direct call will do, and no reliance on wall-clock ordering.
- No failing tests and no `skip`. If a test reveals a real bug that is out of scope, assert the current actual behavior, say so in a comment, and record the bug in `test/findings/<area>.md`.
- Tests are development-only: `meringue.gemspec` does not package `test/`.

## Not covered on purpose

These need real credentials, real processes, or a real terminal, so they stay manual:

- Real harness backends (Pi, Claude Code, Antigravity): spawning, resuming, or prompting an actual harness process, and anything requiring an authenticated harness CLI.
- Network calls of any kind, including GitHub/forge API access, PR verification against real repositories, and `gh` invocations.
- Interactive terminal behavior that needs a live TTY/PTY: raw-mode key handling, PTY echo timing, mouse events, and true-color rendering fidelity. Rendering logic is tested through the pane/canvas objects instead. For example `test/integration/tui/chat_target_composer_test.rb` and `test/integration/tui/agent_tree_identity_test.rb` assert which styles the composer tint and the AgentTree agent colors/harness logos resolve to in every colorscheme, while judging how those colors and glyphs actually look in your terminal (and whether your font can draw `π`, `✳`, and `↑`) is a manual step: `ruby scripts/chat_target_smoke.rb` prints the composer for every selection state and theme, and `ruby scripts/agent_identity_smoke.rb` prints the AgentTree for every status, harness, and theme.
- Editor and terminal launches into external applications.
- Absolute performance numbers and profiling. The suite keeps a few deliberately generous bounded checks (`test/integration/tui/typing_throughput_test.rb`, `test/integration/workspace/terminal_scroll_performance_test.rb`, and the persistence bounds in `test/integration/state/log_retention_test.rb`) so an accidental O(n) regression fails, but real measurement on a specific machine is still a manual exercise.

Manual verification checklists for these areas live in `docs/agent_workspace_integration.md` and the relevant feature docs.
