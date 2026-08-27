# Changelog

All notable changes to Meringue will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version headings are added only after the maintainer has chosen a release version and date.

## Unreleased

### Added

- Added Codex CLI as a selectable interactive harness with durable session resumption, focused live-terminal attachment, rollout-based reconciliation, and authoritative model discovery.

### Changed

- Head agents now continue an issue in a fresh worker session by default instead of re-prompting an existing one. The follow-up is spawned with `after_agent_id` and `follow_up_of_agent_id`, so the kernel starts it immediately, hands over the predecessor's final report, and continues it in the predecessor's worktree and branch. `PromptAgent` is reserved for steering a mid-turn worker, recovering one whose turn died mid-flight, and explicit requests to continue a session.
- Goal loops spawn a new session for every iteration. `continuity` now selects the checkout rather than the session: `accumulate` (default) continues in the previous attempt's worktree and branch so work and the metric stay cumulative, and `fresh_attempt` starts each attempt from a clean tree, which is what it always claimed to do.
- The goal session budget is now checked per iteration rather than per session, so a goal never starts an attempt it lacks the budget to judge. The default rose to `2 × max_iterations + 4` to cover a reviewer retry.
- Workers are told their final message is a handover for a successor that never sees their transcript, and must state what they ruled out, what is committed, and what is left.
- `/prune` retains a settled predecessor while a successor that continues its work is still running, not only while one is still queued behind it, and reports that retention.
- Replaced the unsafe push/PR gem publication job with separate CI and tag-only RubyGems trusted-publishing workflows.
- Added strict package-content, isolated-install, and CLI smoke verification.
- Documented the release gates and the recommended future Homebrew tap.
