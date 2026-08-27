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

- Added Codex CLI as a selectable interactive harness with durable session resumption, focused live-terminal attachment, rollout-based reconciliation, and authoritative model discovery.

### Changed

- Replaced the unsafe push/PR gem publication job with separate CI and tag-only RubyGems trusted-publishing workflows.
- Added strict package-content, isolated-install, and CLI smoke verification.
- Documented the release gates and the recommended future Homebrew tap.
