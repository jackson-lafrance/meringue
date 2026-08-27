# Foundation slice findings

Notes from building the test-suite foundation (Rakefile, `test/test_helper.rb`, boot/CLI/layout tests). Tests in this slice assert current actual behavior; nothing here is a test failure.

## 1. ~~Duplicate method definitions in `lib/meringue/kernel/engine.rb`~~ **Fixed.**

All four duplicates are gone: the dead `prompt_agent` body was deleted (and its `message`/`Message`
payload aliases restored on the surviving one), the dead `issue_subtree_ids` copy was deleted, and
`harness_client`/`head_runner` are defined once above `private`. `test_verbose_load_emits_no_warnings`
now fails on *any* warning from this repo's files rather than tolerating redefinitions.

Original report:

## 1. Duplicate method definitions in `lib/meringue/kernel/engine.rb` (real bug risk)

Loading the library with warnings enabled shows that the kernel engine defines the same methods twice, so the earlier definitions are silently discarded:

```
$ ruby -w -Ilib -e 'require "meringue"'
lib/meringue/kernel/engine.rb:2147: warning: method redefined; discarding old prompt_agent
lib/meringue/kernel/engine.rb:799: warning: previous definition of prompt_agent was here
lib/meringue/kernel/engine.rb:3634: warning: method redefined; discarding old harness_client
lib/meringue/kernel/engine.rb:3638: warning: method redefined; discarding old head_runner
```

- `prompt_agent` exists at line 799 and again at line 2147. The two bodies are not identical (the first accepts `"message"`/`"Message"` aliases for the prompt payload key; the second only accepts `"prompt"`/`"Prompt"` and coerces `mode` with `to_s`). Ruby keeps the second one, so the first is dead code and the alias handling it implements is effectively gone. Any caller or head that sends `message` instead of `prompt` gets a validation error even though a definition for that behavior is present in the file.
- `harness_client` (3634) and `head_runner` (3638) override the `attr_reader :harness_client, :head_runner` on line 134 with provider-aware accessors. That is probably intentional, but relying on definition order in a 5k-line file is fragile; the readers should be removed from the `attr_reader` list instead.

Not fixed here because this slice must not change `lib/`. `test/integration/foundation/library_boot_test.rb#test_verbose_load_emits_no_unexpected_warnings` documents the current state: it fails only if a *new kind* of warning appears, and keeps passing once these duplicates are removed.

## 2. `lib/meringue/kernel/engine.rb` is 5,087 lines

Not a bug, but it makes area-scoped testing awkward and is the likely reason the duplicate definitions above went unnoticed. Worth splitting per command family.

## 3. No-op checks that were intentionally not automated

- `meringue reset-state` and the default `meringue`/`meringue tui`/`meringue demo` commands are not exercised: they write to `~/.meringue/state.json` or boot a TUI against the real terminal. The CLI test only covers `--version`, `--help`, unknown commands, and `demo-state`.
- The retired head-loop walkthrough script ran a full fake head loop through `Heads::SimpleLoop`. This slice replaced its boot-level value (library loads, CLI answers, entrypoint works); the head/kernel loop behavior itself belongs to the kernel and heads slices.

## 4. Several git-backed tests are not hermetic against the developer's git config (pre-existing)

Found while running the full suite for the worker-progress-log slice, on a machine whose
global git config sets `commit.gpgSign = true` (Shopify `dev` gitconfig) and `core.fsmonitor = true`.

`rake test` hangs indefinitely, with no failure and no output, inside test `setup`:

```
HeadBatchTargetBindingTest#setup
  -> git_repo!  ->  system("git", "commit", "-q", "-m", "initial", chdir: path)
     -> /opt/dev/bin/gpg-auto-pin ... -> gpg --pinentry-mode loopback ...   # never returns
```

`test/support/kernel_workers_support.rb#run_git` already does the right thing: it runs git with
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, `GIT_TERMINAL_PROMPT=0`, and explicit
author/committer identity. `test/integration/head_batch_target_binding_test.rb#git_repo!` (and any
other fixture that shells out to git with a bare `system`/`Open3` call and no env) inherits the
developer's configuration instead, so a signing hook, a credential helper, or an fsmonitor daemon
can block the suite forever. This violates the "no reliance on a developer's machine state" rule in
`AGENTS.md` and `docs/testing.md`.

Workaround for running the suite today, without weakening the identity the commit-authorship tests
need:

```bash
printf '[include]\n\tpath = %s\n[core]\n\tfsmonitor = false\n[commit]\n\tgpgSign = false\n[tag]\n\tgpgSign = false\n' "$HOME/.gitconfig" > /tmp/meringue_test_gitconfig
GIT_CONFIG_GLOBAL=/tmp/meringue_test_gitconfig rake test
```

Not fixed here because the fix belongs to the test-hermeticity slice, not to the worker-progress
slice: it means auditing every fixture that shells out to git and routing them through one shared
isolated-git helper. Follow-up: extract `run_git` into a shared support module and use it from every
test that builds a git fixture.
