# Changelog

All notable changes to Meringue will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version headings are added only after the maintainer has chosen a release version and date.

## Unreleased

### Added

- Added Codex CLI as a selectable interactive harness with durable session resumption, focused live-terminal attachment, rollout-based reconciliation, and authoritative model discovery.

### Changed

- Replaced the unsafe push/PR gem publication job with separate CI and tag-only RubyGems trusted-publishing workflows.
- Added strict package-content, isolated-install, and CLI smoke verification.
- Documented the release gates and the recommended future Homebrew tap.
