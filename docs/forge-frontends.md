# Forge frontends

The code-hosting frontend is the thing Meringue asks about pull requests: their
URLs for a branch, their state, and read-only access for the delivery workflow.
The built-in frontend is GitHub (`[forge] frontend = "github"`, the default),
backed by bounded, read-only `gh` CLI calls. GitHub support is default behavior;
nothing needs to be enabled for it.

The git backend that provisions isolated workspaces is a separate, independent
axis under `[version_control]`; see
[`version-control-backends.md`](version-control-backends.md). The two axes are
unrelated: an installation can keep the GitHub frontend while provisioning
workspaces through an alternate backend, or the reverse.

## Selecting an alternate frontend

```toml
[forge]
frontend = "command"
command = ["/absolute/path/to/private-frontend-adapter"]
```

A `command` value is only a configuration extension point. Meringue does not
ship an alternate frontend and does not silently fall back to GitHub once one is
selected: pull-request lookups fail closed (no lookups run, no GitHub-specific
UI is shown, historical PR records are preserved) until an implementation
exists. Selecting `command` is therefore a deliberate opt-out of the built-in
GitHub workflow, not a way to disable PR behavior.

## The frontend contract

Applications embedding Meringue may supply a frontend object implementing the
same methods as `Meringue::Forge::GitHubClient`:

```ruby
id
test_access(repository:, timeout:)                    # read-only access check
pull_request_urls_for_branch(repository:, branch:, timeout:)
pull_request_status(url, timeout:)                    # state: open | merged | closed | unknown
```

`test_access` reports an `outcome` of `success`, `unavailable`,
`missing_tooling`, `unauthenticated`, `permission_denied`,
`repository_read_failure`, `timeout`, or `malformed_remote`, with a
human-readable `message`. `pull_request_status` returns at least `provider`,
`url`, `state`, and `merged_at`; an unanswered question is `unknown`, never a
guess. All operations must be bounded and read-only with respect to the remote
service; Meringue's delivery workflow never mutates a pull request through the
frontend.

An embedding application supplies its object as the kernel's `forge_client:`
dependency; an explicitly injected client always wins over the `[forge]`
selection. A private adapter (for example around a frontend such as meteorite)
keeps its own commands and configuration in user config; the public repository
only defines this contract.

Doctor reports frontend capability failures the same way it reports backend
capability failures, and `/github test` reports the configured frontend's own
access-check outcome.
