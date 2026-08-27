# Changelog

All notable changes to Meringue will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version headings are added only after the maintainer has chosen a release version and date.

## Unreleased

### Fixed

- Restored `Kernel::Engine#harness_client` and `#head_runner` as public accessors. Duplicate
  definitions below the class's `private` keyword had shadowed them, so `meringue head-loop`
  raised `NoMethodError` instead of settling the workers it spawned.
- Removed two other silently discarded duplicate definitions in the kernel engine, and restored
  the `message`/`Message` payload aliases on `PromptAgent` that the surviving handler had lost.
- An unbalanced quote in a slash command now produces a usage message instead of raising
  `NameError: uninitialized constant Shellwords::ParseError`. The submission that raised also
  used to sit in the durable queue forever and replay on every start; it now drains, and a
  slash command that fails is reported in the dashboard instead of disappearing.
- An unreadable `state.json` no longer stops Meringue from starting: it is moved to
  `state.json.unreadable-<timestamp>`, kept verbatim, and reported as a warning log entry.
- `/recount` refuses an orphaned issue or worker by name instead of aborting with
  `KeyError: key not found`.
- `AnswerQuestion` no longer revives a dismissed question.
- `meringue reset-state --state PATH` resets that file instead of silently resetting the default.
- A worker path containing a null byte is reported as an unusable workspace instead of raising
  `ArgumentError` into the render loop.
- State saves use a per-write temporary file name, so two writers in one process can no longer
  delete each other's in-flight snapshot.

### Added

- Added a quiet-worker signal. A `working` agent that has produced nothing for longer than
  `[agent] quiet_worker_warning_seconds` (default 900; `0` disables) is marked `quiet 40m` in the
  AgentTree, counted in the bottom status bar, and reported once per quiet stretch as a warning.
  See `docs/quiet-workers.md`.
- Added Codex CLI as a selectable interactive harness with durable session resumption, focused live-terminal attachment, rollout-based reconciliation, and authoritative model discovery.

### Changed

- Head agents now continue an issue in a fresh worker session by default instead of re-prompting an existing one. The follow-up is spawned with `after_agent_id` and `follow_up_of_agent_id`, so the kernel starts it immediately, hands over the predecessor's final report, and continues it in the predecessor's worktree and branch. `PromptAgent` is reserved for steering a mid-turn worker, recovering one whose turn died mid-flight, and explicit requests to continue a session.
- Goal loops spawn a new session for every iteration. `continuity` now selects the checkout rather than the session: `accumulate` (default) continues in the previous attempt's worktree and branch so work and the metric stay cumulative, and `fresh_attempt` starts each attempt from a clean tree, which is what it always claimed to do.
- The goal session budget is now checked per iteration rather than per session, so a goal never starts an attempt it lacks the budget to judge. The default rose to `2 × max_iterations + 4` to cover a reviewer retry.
- Workers are told their final message is a handover for a successor that never sees their transcript, and must state what they ruled out, what is committed, and what is left.
- `/prune` retains a settled predecessor while a successor that continues its work is still running, not only while one is still queued behind it, and reports that retention.
- Split the 20,940-line `Kernel::Engine` into `lib/meringue/kernel/engine/*.rb` by command family,
  and the 7,106-line `TUI::App` into `lib/meringue/tui/app/*.rb` by dashboard surface. Both remain
  one class; every method body, comment, constant, and visibility is unchanged.
- Made `Models.ensure_state_shape!` skip the pull-request migration and the workspace-mode rewrite
  for records that have nothing to migrate. It runs on every state read and every kernel command,
  so a read-only command at 1,000 workers went from ~8ms to ~2.7ms and a reconciliation pass from
  ~119ms to ~38ms.
- Removed `Heads::SimpleLoop`'s unreachable second copy of the worker-wait path and `TUI::App`'s
  compatibility shim for a `handle_key` signature nothing calls.
- `meringue --help` now lists every slash command, rendered from the parser's own table instead of
  a hand-written subset that named 17 of 47. `/issue move`, which shipped without ever reaching
  the in-app `/help`, is documented there too.
- Replaced the unsafe push/PR gem publication job with separate CI and tag-only RubyGems trusted-publishing workflows.
- Added strict package-content, isolated-install, and CLI smoke verification.
- Documented the release gates and the recommended future Homebrew tap.
