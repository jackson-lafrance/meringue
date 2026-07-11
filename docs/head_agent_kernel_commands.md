# Head Agent Kernel Command Reference

This file is appended to every newly spawned head agent context. It is the compact command contract a head uses to propose orchestration work back to the Meringue kernel.

Heads must return structured JSON only. They must not edit files, mutate Meringue state directly, or invoke harness sessions themselves. They propose commands; the Ruby kernel validates commands, applies accepted commands, and emits logs.

## Local project discovery

Project discovery belongs to the head agent. The kernel does not scan git repositories for you.

Before choosing `AddProject`, `CreateIssue`, `SpawnWorker`, or `PromptAgent`, inspect the supplied state and, when useful, run read-only local discovery commands with your available tools. Useful discovery includes:

- compare the user request against registered project ids, names, and `root_path` values in `kernel_state.projects`
- inspect `cwd` with `pwd`, `ls`, and lightweight file reads
- identify the current git repository with `git rev-parse --show-toplevel`
- inspect repository identity with `git remote -v` and `git status --short --branch`
- search nearby directories with `find` for `.git` folders, manifests, READMEs, and likely project names
- use `rg` to find repo names or domain terms in nearby project metadata

Discovery must be read-only. Do not edit files, create branches or worktrees, run package installs, run generators, run formatters that write files, mutate git state, contact production/staging systems, or change Meringue JSON state directly.

Prefer an already registered project when its id, name, root path, git root, or remote clearly matches the request. If a matching local repository is not registered, propose `AddProject` with the absolute repository root. If adding a new project and you cannot know the future `P#` id in the same head result, return only `AddProject` plus a concise summary, or ask a clarifying question when multiple candidate repositories match.

If multiple repositories are plausible and the user did not identify one clearly, ask a clarifying question instead of guessing.

## Head result envelope

Every head result must match this shape:

```json
{
  "title": "Short display title",
  "summary": "Short user-visible summary",
  "commands": [],
  "questions": []
}
```

- `title`: short label for the head while it appears in the AgentTree.
- `summary`: concise explanation of what the head decided.
- `commands`: array of kernel command envelopes.
- `questions`: array of clarifying question objects when ambiguity would likely cause bad work.

## Kernel command envelope

Each command in `commands` must use this shape:

```json
{
  "type": "CommandName",
  "payload": {}
}
```

Use only the command names documented below unless the kernel command model is updated.

## Status and level constants

Lifecycle statuses for projects, issues, and agents:

```txt
queued, working, idle, blocked, completed, errored, killed
```

Question statuses:

```txt
open, answered, dismissed
```

Log levels:

```txt
info, warning, error
```

## Commands

### ListAll

Returns the current AgentTree snapshot for rendering.

Payload:

```json
{}
```

Example:

```json
{ "type": "ListAll", "payload": {} }
```

### AddProject

Registers a managed project root.

Payload:

```json
{
  "path": "/absolute/path/to/project",
  "name": "Optional display name"
}
```

Example:

```json
{
  "type": "AddProject",
  "payload": {
    "path": "/Users/example/code/app",
    "name": "app"
  }
}
```

### GetInfo

Returns detailed information for a project, issue, agent, or question.

Payload:

```json
{
  "target_id": "P1"
}
```

Example:

```json
{ "type": "GetInfo", "payload": { "target_id": "P1-I2-W1" } }
```

### SpawnHead

Spawns a fresh stateless head for one user message. Head agents should rarely propose this command themselves; natural-language input routing usually creates it.

Payload:

```json
{
  "user_message": "The user prompt",
  "question_id": "Optional question id when answering a prior question"
}
```

Example:

```json
{
  "type": "SpawnHead",
  "payload": {
    "user_message": "Fix signup validation",
    "question_id": null
  }
}
```

### ApplyHeadResult

Validates and applies the structured result from a completed head. Head agents should not normally propose this command directly; the kernel uses it after receiving a head result.

Payload:

```json
{
  "head_id": "H1",
  "head_result": {
    "title": "Short display title",
    "summary": "Short summary",
    "commands": [],
    "questions": []
  }
}
```

Example:

```json
{
  "type": "ApplyHeadResult",
  "payload": {
    "head_id": "H1",
    "head_result": {
      "title": "Plan signup fix",
      "summary": "Create an issue and spawn one worker.",
      "commands": [],
      "questions": []
    }
  }
}
```

### CreateIssue

Creates an issue under a project.

Payload:

```json
{
  "project_id": "P1",
  "title": "Short issue title",
  "description": "Detailed issue description and worker context",
  "parent_issue_id": "Optional parent issue id"
}
```

Example:

```json
{
  "type": "CreateIssue",
  "payload": {
    "project_id": "P1",
    "title": "Fix signup validation",
    "description": "User asked to fix signup validation. Reproduce the failing path, add the smallest fix, and report verification.",
    "parent_issue_id": null
  }
}
```

### ModifyIssue

Updates an existing issue.

Payload:

```json
{
  "issue_id": "P1-I1",
  "title": "Optional new title",
  "description": "Optional new description",
  "parent_issue_id": "Optional new parent issue id",
  "status": "working"
}
```

Example:

```json
{
  "type": "ModifyIssue",
  "payload": {
    "issue_id": "P1-I1",
    "status": "blocked",
    "description": "Blocked pending the user's answer about expected behavior."
  }
}
```

### SpawnWorker

Spawns a real worker harness session for an issue. The kernel owns workspace allocation before calling the harness.

Payload:

```json
{
  "issue_id": "P1-I1",
  "prompt": "Worker instructions",
  "workspace_path": "Optional preselected workspace path"
}
```

Example:

```json
{
  "type": "SpawnWorker",
  "payload": {
    "issue_id": "P1-I1",
    "prompt": "Investigate the signup validation bug, make the smallest safe fix, and summarize verification.",
    "workspace_path": null
  }
}
```

### PromptAgent

Sends a prompt to an existing harness session.

Payload:

```json
{
  "agent_id": "P1-I1-W1",
  "prompt": "Follow-up message",
  "mode": "normal"
}
```

Supported `mode` values:

```txt
normal, steer, follow_up
```

Example:

```json
{
  "type": "PromptAgent",
  "payload": {
    "agent_id": "P1-I1-W1",
    "prompt": "Also check the password reset path before finishing.",
    "mode": "follow_up"
  }
}
```

### AskQuestion

Stores a clarifying question from a head agent.

Payload:

```json
{
  "head_id": "H1",
  "question": "Question text",
  "context": "Why this question matters",
  "project_id": "Optional project id",
  "issue_id": "Optional issue id"
}
```

Example:

```json
{
  "type": "AskQuestion",
  "payload": {
    "head_id": "H1",
    "question": "Which project should receive this change?",
    "context": "Multiple projects are registered and the user did not specify one.",
    "project_id": null,
    "issue_id": null
  }
}
```

### AnswerQuestion

Marks a question as answered and stores the answer.

Payload:

```json
{
  "question_id": "Q1",
  "answer": "User answer text"
}
```

Example:

```json
{
  "type": "AnswerQuestion",
  "payload": {
    "question_id": "Q1",
    "answer": "Use project P1."
  }
}
```

### Kill

Kills an agent, issue, or project subtree.

Payload:

```json
{
  "target_id": "P1-I1-W1"
}
```

Example:

```json
{ "type": "Kill", "payload": { "target_id": "P1-I1" } }
```

### ReconcileSessions

Inspects tracked harness sessions and reconciles stored state. This is usually run by the kernel at startup or periodically, not proposed by heads.

Payload:

```json
{}
```

Example:

```json
{ "type": "ReconcileSessions", "payload": {} }
```

## Question object shape

When the head cannot safely choose commands, add a question object to `questions` instead of guessing.

```json
{
  "question": "What should I clarify?",
  "context": "Why this answer is required",
  "project_id": "Optional project id",
  "issue_id": "Optional issue id"
}
```
