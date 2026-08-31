# Version-control backends

Mutable workers use an isolated workspace when the selected backend can provide one. The built-in
`github_git` backend uses native Git worktrees and a usable base ref; it does not require a GitHub
origin. Projects without Git remain valid for question-only or read-only workers, which report
findings instead of pretending to provide mutable isolation.

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

The command provider setting is a supported extension point for backends such as gitstream.
Meringue does not ship a fake alternate backend or silently fall back to the project root.
Implementations must own locking, isolation evidence, bounded operations, and safe cleanup.
Unknown or dirty workspaces must never be force-removed.

Doctor reports backend capability failures. Project registration records the capability snapshot
without requiring a forge origin; workers choose the strongest safe mode available.
