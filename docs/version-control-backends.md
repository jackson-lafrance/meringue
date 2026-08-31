# Version-control backends

Mutable workers always run in an isolated workspace. The built-in `github_git`
backend uses Git worktrees and requires a GitHub origin and usable base ref.
There is deliberately no fallback to the registered project directory.

The git backend is one of the two axes in the Alternate backend section; the
other, the code-hosting frontend that answers pull-request questions, is
independent and documented in [`forge-frontends.md`](forge-frontends.md).

Applications embedding Meringue may supply a backend object implementing:

```ruby
id
inspect_project(root_path:) # capability snapshot
provision_workspace(project:, worker:, task_title:, unavailable_paths:, progress:)
validate_workspace(workspace:, worker_id:) # final gate immediately before launch
release_workspace(workspace:, preserve_delivery:)
```

`inspect_project` must report `available` and
`capabilities.isolated_workspaces`. Provisioning responses must include an
absolute `workspace_path`, an opaque `identifier`, and an `isolation` object
with an owner token and `concurrent_mutable_workers_supported: true`.
Validation must prove ownership, occupancy, editability, and isolation every
time; structured failures are safer than guessing from a directory.

A command setting is only a configuration extension point. Meringue does not
ship a fake alternate backend or silently fall back to Git or the project root.
Implementations must own locking, isolation evidence, bounded operations, and
safe cleanup. Unknown or dirty workspaces must never be force-removed.

Doctor reports backend capability failures, and project registration rejects a
project until its selected backend is capable of isolated mutable workspaces.
