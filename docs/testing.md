# Testing

Meringue has one automated suite: Minitest, driven by Rake, with no dependencies beyond `rake` and `minitest` (both ship with Ruby). Assertions belong in this suite so `rake test` is the testing source of truth; do not add one-off check scripts for behavior that can be covered hermetically.

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
test/integration/<area>/       # component/area tests, e.g. foundation, kernel_core, kernel_goals, heads, state, tui
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
- Interactive terminal behavior that needs a live TTY/PTY: raw-mode key handling, PTY echo timing, decoding real SGR mouse reports off the wire, and true-color rendering fidelity. Rendering logic is tested through the pane/canvas objects instead, and already-parsed mouse events (clicks, double-/triple-clicks, drags, wheel) are driven through `TUI::App` in `test/integration/tui/mouse_word_selection_test.rb`.
- Editor and terminal launches into external applications.
- Absolute performance numbers and profiling. The suite keeps a few deliberately generous bounded checks (`test/integration/tui/typing_throughput_test.rb`, `test/integration/workspace/terminal_scroll_performance_test.rb`, and the persistence bounds in `test/integration/state/log_retention_test.rb`) so an accidental O(n) regression fails, but real measurement on a specific machine is still a manual exercise.

Worker workspace provisioning is covered the same way, with one deliberate exception to the
"no sleeping" rule. The provisioning watchdog exists to decide whether a *real child process* is
progressing or stuck, so `test/integration/workspace/manager_checkout_timeout_test.rb` drives real
`sh` processes that print (or refuse to print) output, with the bounds injected as fractions of a
second instead of the shipped 120s/1800s. Nothing waits for a production timeout, and the file runs
in a few seconds. The rest of the behavior is injected rather than timed:
`test/support/workspace_support.rb`'s `TimingOutManager` raises the manager's own `CommandTimeout`
for kernel-level tests, and `test/integration/kernel_workers/workspace_provisioning_retry_test.rb`
fails a scripted number of attempts before provisioning for real.

Goal loops are covered without either of those: `test/integration/kernel_goals/` drives the real reconcile tick with a fake harness and a scripted metric probe, so a whole multi-iteration goal runs in milliseconds. Only `metric_probe_test.rb` runs real commands, and only harmless shell builtins inside `Dir.mktmpdir`. What stays manual there is a goal against a real repository metric (a real coverage or lint run) and its real harness sessions.

Manual verification checklists for these areas live in `docs/agent_workspace_integration.md` and the relevant feature docs.
