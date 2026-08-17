# Pause and resume worker sessions

Workers can be paused without being killed:

```text
/worker pause <agent_id>
/worker resume <agent_id>
```

## Semantics

`PauseWorker` is a kernel command. It validates that the worker has a harness
session, checkpoints a pause request, then calls the harness `abort_session`
operation. It never calls `kill_session`, removes the worker record, removes a
worktree, or creates a replacement session. The worker becomes `paused`, and
its session id, transcript, workspace, branch, queued prompts, and worker
relationships remain persisted.

While paused, reconciliation does not poll the session or classify it as
completed/errored. New prompts are rejected until the worker is resumed. Parent
issues remain non-terminal (`idle` when no sibling is active), so a paused
worker cannot make its issue appear completed.

`ResumeWorker` checkpoints a durable continuation request and delivers the
existing worker prompt through the normal `PromptAgent` delivery path. This
means a provider that needs to reattach after a Meringue restart uses the same
session and workspace recovery rules as any other continuation. A delivery id
and request marker make a retry after a crash idempotent; a prompt accepted by
the harness is not sent twice. If delivery is temporarily unavailable, the
request remains on the worker and reconciliation retries it. A failed resume
leaves the worker paused.

The user-directed `paused` status is separate from `supervision_lost`:
`supervision_lost` means that a supervisor and harness child disappeared and is
recovered by supervision, while `paused` records an explicit user choice.
Neither state is terminal or eligible for pruning.

## Verification

```bash
ruby -Ilib -Itest test/integration/kernel_workers/pause_resume_test.rb
ruby -Ilib -Itest test/integration/input/input_slash_command_parser_test.rb
ruby -Ilib -Itest test/integration/tui/agent_tree_pane_test.rb
rake test
```
