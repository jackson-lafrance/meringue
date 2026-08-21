# Exporting workers for retry on another computer

Meringue can move current worker context to another computer without pretending that a
harness session is portable:

```text
meringue workers export ./workers.json
meringue workers import ./workers.json --project /path/to/the/checkout
```

The same operations are available in the TUI/kernel command path:

```text
/worker export ./workers.json [agent_id...]
/worker import ./workers.json --project /path/to/the/checkout
```

Export defaults to current workers (`queued`, `working`, `idle`, `blocked`, `paused`,
`errored`, and `supervision_lost`). Completed and killed workers are not retry candidates.
Worker IDs may be supplied after the bundle path to export a selected subset.

## What the bundle contains

A bundle is a versioned JSON document containing an allowlisted record for each worker:

- project name and source ID;
- issue title, description, parent issue summary, and source ID;
- the original assignment, queued follow-up prompts, and last recorded report;
- harness/model-thinking context, delivery branch, pull-request references, and worker lineage;
- the source worker status; and
- an explicit session result saying that the harness session cannot be resumed directly.

Import requires a local destination project directory. Meringue creates or reuses the
registered project for that directory, recreates the issue context, and uses the ordinary
workspace manager and `SpawnWorker` path to allocate a local workspace and start a fresh
session. It records the source worker ID and bundle ID so importing the same bundle again
does not spawn a duplicate worker.

The source harness process, session transcript, session ID, session file, PID, cwd, project
root path, workspace path, and transport metadata are intentionally excluded. Branch names
and delivery references are context only; import does not blindly reuse a source-machine
path or claim that a source session was resumed. The destination harness is the configured
worker harness on that computer. If a source model or setting is unavailable, normal
`SpawnWorker` validation reports that instead of silently claiming equivalence.

Bundle text is redacted for common credential-shaped values (for example `token=...`,
`password=...`, bearer credentials, and URL userinfo). Prompts and reports are user content,
not a security boundary: inspect the JSON before transferring it and remove anything
sensitive that automated redaction cannot recognize. Do not put secrets in worker prompts.

## Retry procedure

1. Export while the source workers are visible in the AgentTree. Exporting does not kill or
   pause them, so decide separately whether the source workers should keep running.
2. Transfer the JSON through a channel appropriate for its contents.
3. On the destination computer, check out or clone the project and pass that local directory
   to `--project`.
4. Configure the desired worker harness, then import the bundle.
5. Review the newly created worker prompts and the destination workspaces. The import log and
   worker metadata state that this is a fresh session and preserve why direct session
   resumption was unavailable.

The JSON format is intended for transfer and review, not for merging complete Meringue state
files. It is safe to keep the source state and destination state independent.
