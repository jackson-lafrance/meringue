# Commit authorship policy

Meringue must never be the author of a Git commit. A worker may still make a
commit for the assigned issue, but that commit must use the user's repository
identity (`user.name` and `user.email`). Meringue is orchestration and harness
plumbing; it is not a commit identity.

## Enforcement path

Worker sessions are started by the harness clients, not by a Meringue Git
commit command. Immediately before Pi, Claude Code, Codex CLI, or Antigravity starts a managed or
focused external process, `Meringue::Git::CommitIdentity`:

1. reads the repository's local, global, and system Git identities;
2. ignores identities whose name or email contains `Meringue`;
3. exports a valid non-Meringue identity as both the author and committer for
   the worker's child processes; and
4. if no valid identity exists, removes inherited author variables and adds
   empty command-scope `user.name`/`user.email` values. Git then refuses a
   commit with “Author identity unknown” instead of attributing it to
   Meringue.

The same environment is applied to new and resumed process-backed sessions,
and to the external terminal session opener.
The policy does not disable the worker's Git tools or commits. Workers must not
use `Meringue`, `Meringue Worker`, `meringue@example.com`,
`agent@meringue.local`, or a Meringue `--author` override. If the repository
has no user identity, configure one before asking the worker to commit, for
example:

```sh
git config --local user.name "Your Name"
git config --local user.email "you@example.com"
```

An explicit `--author` override is still a worker instruction violation; the
managed environment is designed for ordinary worker `git commit` commands and
fails closed when the configured identity itself is Meringue.

## Regression coverage

`test/integration/harness/commit_identity_test.rb` creates isolated temporary
repositories and verifies both sides of the contract: a worker can commit as
the configured user, while a repository configured only with a Meringue
identity cannot commit through the managed environment. Worker spawning also
asserts that the system prompt carries this rule.

Run the checks with:

```sh
rake test
ruby -Ilib -Itest test/integration/harness/commit_identity_test.rb
```

## History audit (2026-08-06)

The reachable local and `origin/*` refs were searched for authors or committers
matching `Meringue`. The audit found ten commits:

| commits | result |
| --- | --- |
| `12d9cc8` | Meringue author; open PR [#175](https://github.com/jackson-lafrance/meringue/pull/175), intentionally handled separately |
| `d2608dd` | Meringue Worker author; merged public PR #142 |
| `32590b2` | Meringue Worker author; merged public PR #139 |
| `b2e26d0`, `1b02c08`, `f5668d2`, `c035a71`, `65ed73f`, `464fea9`, `762c11d` | Meringue Worker author; merged public PR #112 |

No other safe unmerged Meringue-authored commit was found in the local or
remote refs at audit time. The merged commits are public history and are not
rewritten. The only unmerged finding is PR #175, which this change deliberately
does not rewrite because it is being remediated separately.
