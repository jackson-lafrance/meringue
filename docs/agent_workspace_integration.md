# Agent workspace delivery and recovery integration

This document describes the persistence and degraded-state contracts used by the focused worker workspace. The workspace renderer and terminal/editor adapters should consume these contracts rather than copying delivery metadata or deleting records when a dependency disappears.

## Durable selection

Agent-workspace presentation state is stored under `ui.agent_workspace` in the normal Meringue state file:

```json
{
  "ui": {
    "agent_workspace": {
      "selected_agent_id": "P1-I1-W1",
      "view": "agent",
      "draft": "",
      "agent_scroll_offset": 0,
      "terminal_scroll_offset": 0,
      "updated_at": "2026-07-27T20:00:00Z"
    }
  }
}
```

Use `State::Store#save_agent_workspace` to persist this data. It reloads the latest state under the store mutex before writing, so a stale TUI frame cannot overwrite kernel reconciliation or pruning. `State::Models.agent_workspace_state` normalizes loaded values. A selected worker that was killed, pruned, or otherwise removed is cleared on load; recount rewrites a selected worker ID.

The presentation record must not become a second source of harness truth. PIDs, streaming state, session IDs/files, and worktree paths remain on the agent record and are owned by kernel reconciliation.

## Delivery pull requests

`TUI::DeliveryPullRequest.for_id(state, worker_id)` resolves a worker through its issue and returns presentation data for the kernel-verified `delivery_pull_request`. Candidate and worker-reported URLs are intentionally not actionable. Use:

- `TUI::DeliveryPullRequest.openable?` before invoking a URL opener;
- `TUI::DeliveryPullRequest.status_label` for `open`, `merged`, `closed`, stale, unavailable, invalid, and not-yet-tracked labels;
- the returned `url` and `number` for the prominent workspace link.

`Ctrl-B` (`open_delivery_pr`) opens the selected worker's verified delivery PR. The bottom status line shows the PR number/status and shortcut. The binding is configurable under `[tui.keybindings]`, but Ctrl-B is the default and should remain documented in workspace help.

Reconciliation refreshes old verified PR status at most once every five minutes. A forge/auth/network failure records `availability: unavailable` and an error while preserving the last known PR state and URL. This is intentional: `/prune merged` still performs fresh conservative checks and will not prune an unknown PR.

## Degraded runtime dependencies

Use `TUI::WorkspaceHealth.notices(agent)` to render non-destructive notices when the harness process, worktree, or saved session history is missing. Use `TUI::WorkspaceHealth.command_unavailable(kind, command:)` when terminal/editor commands are absent or cannot be executed.

Required behavior:

- keep the worker, logs, workspace metadata, and delivery PR visible;
- disable only the action whose dependency is unavailable;
- display the notice and recovery suggestion in the workspace;
- do not recreate/delete worktrees from the TUI;
- do not mark agents errored from the TUI;
- let kernel reconciliation decide whether a harness session is resumable, blocked, or terminally errored;
- command launch failures must not close the dashboard.

The terminal/editor adapters should return structured results rather than raising through the render/input loop. The existing URL opener follows the same pattern (`opened`, `rejected`, or `failed`).

## Manual integration verification

Repository policy forbids automated test files, so integration should be checked with focused Ruby smoke commands plus the interactive TUI:

1. Select a worker with a verified open PR, restart Meringue, and confirm the worker selection and workspace view recover.
2. Press Ctrl-B and confirm the tracked PR opens. Replace the PR URL with malformed metadata and confirm a useful unavailable notice is shown instead.
3. Remove/rename the worktree and harness session file, then render the workspace. Confirm notices are shown and state is not pruned or rewritten.
4. Configure missing terminal/editor executables and confirm those actions fail in place without closing Meringue.
5. Run `/prune merged` with open, closed, merged, and forge-unavailable PRs. Confirm only bundles satisfying the existing conservative merged semantics are removed.
6. Run `/recount` and confirm the durable selected worker follows its new ID.
