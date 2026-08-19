# Focused worker workspace: delivery and recovery

The focused workspace is an auxiliary, issue-specific deep-interaction tool. The dashboard's natural-language chat and stateless head agents remain Meringue's default orchestration path. Open a worker workspace only when an issue benefits from sustained direction, iterative planning, research, investigation, or direct visibility into worker responses and tool calls. Direct workspace follow-ups continue the selected worker's existing harness context through kernel-owned prompting; they do not create a second conversation model or expose raw Pi process controls.

This document describes the persistence and degraded-state contracts used by that workspace. The renderer and terminal/editor adapters consume these contracts rather than copying delivery metadata or deleting records when a dependency disappears.

## Durable selection

Agent-workspace presentation state is stored under `ui.agent_workspace` in the normal Meringue state file:

```json
{
  "ui": {
    "agent_workspace": {
      "selected_agent_id": "P1-I1-W1",
      "view": "agent",
      "filter": "all",
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

`TUI::DeliveryPullRequest.for_id(state, issue_or_worker_id)` resolves a worker through its owning issue and returns presentation data for the kernel-verified `delivery_pull_request`. Candidate and worker-reported URLs are intentionally not actionable. Use:

- `TUI::DeliveryPullRequest.openable?` before invoking a URL opener;
- `TUI::DeliveryPullRequest.status_label` for `open`, `merged`, `closed`, stale, unavailable, invalid, and not-yet-tracked labels;
- the returned `url` and `number` for the prominent workspace link.

Outside a focused workspace, `Ctrl-B` (`open_delivery_pr`) opens the selected issue's verified delivery PR (a worker selection resolves to its owning issue); with nothing selected it opens a picker over every open PR in the tree instead of guessing one (see [`docs/keybindings.md`](keybindings.md#what-the-bottom-hint-line-shows)). Inside either focused view, use the configurable workspace leader followed by `workspace_open_pull_request` (`Ctrl-Space`, then `p` by default). The bottom status line keeps the issue's PR number/status and sequence visible. Bare terminal `Ctrl-B` is forwarded to the PTY rather than stolen from shells, multiplexers, or editors.

Reconciliation refreshes old verified PR status at most once every five minutes. A forge/auth/network failure records `availability: unavailable` and an error while preserving the last known PR state and URL; a later successful refresh clears that error instead of leaving it attached to a healthy record. This is intentional: `/prune` still performs fresh conservative checks and will not prune an unknown PR. The one status it does not re-check is a record already verified as `merged`, because merging is terminal on the forge — that record stays authoritative even while the forge is unreachable, so settled work is still prunable.

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

The terminal/editor adapters should return structured results rather than raising through the render/input loop. The existing URL and external harness-session openers follow the same pattern (`opened`, `rejected`, or `failed`). The focused agent-session action must reuse that opener rather than attaching to or taking ownership of the kernel-managed RPC process.

## Focused workspace rendering layers

The focused workspace is split so each layer has one job:

- `TUI::WorkspaceTranscript` turns whatever the harness session view provides (assembled history, live events, harness message lists, local echoes, durable logs) into one deduplicated, chronological entry list. It emits no styles and knows no backend.
- `TUI::Panes::AgentWorkspacePane` renders those entries, the live terminal screen, the composer, and the leader line, and caches composed rows per content revision.
- `TUI::WorkspaceCommands` owns the composer's slash command registry, aliases, and argument validation.
- `TUI::HintLine` owns the shared bottom-bar styling used by both the dashboard and the workspace.
- `Workspace::PathResolver`, `Workspace::Controller`, and `Workspace::TerminalManager` own UI-side shell/editor processes; the kernel still owns all orchestration state.

## Shared read-only worker workspaces

`SpawnWorker.workspace_mode` is a persisted execution contract, not a guess based on phrases such as “investigate” or “findings only”:

- `isolated` is the default and remains mandatory for implementation, delivery, dependency setup, and tests/builds that may write artifacts;
- `shared_read_only` is for investigation/informational work that can finish with file reads and searches only;
- the agent record stores both the requested `workspace_mode` and `effective_workspace_mode`; a safe fallback also stores `workspace_mode_fallback_reason`;
- the workspace manager accepts only an existing readable, registered, unlocked, non-bare checkout on `main` or `master`. For a bare registered root it searches existing linked worktrees and never uses the bare repository as `cwd`;
- concurrent readers may use the same checkout. It is not a Meringue-owned workspace and prune/cleanup never removes it;
- Pi enforces the mode with `--tools read,grep,find,ls` on initial spawn, RPC resume, and native focus. Prompt guidance is defense in depth, not the enforcement boundary;
- if checkout validation or harness enforcement is unavailable, the kernel provisions the usual isolated workspace before launch.

A queued worker retains the request through activation and reconciliation. A read-only follow-up does not inherit a predecessor's editable worktree, while a later implementation follow-up must be a newly spawned isolated worker.

## Workspace directory resolution

`Workspace::PathResolver` is the single place that decides where a UI-owned shell or editor starts. It is used by the terminal manager, the workspace controller, the editor launcher, and the external session opener so all four agree.

- candidates, in order: `workspace_path`, harness `cwd`, then the recorded workspace plan's `workspace_path`/`workspace_root_path`/`worktree_root_path`;
- every candidate is made absolute; a relative value is resolved against the recorded project/git root, never against the Meringue process working directory (that is what produced nested `.meringue/workspaces/<project>/<task>/...` paths);
- the first existing directory wins, so a worker whose recorded subdirectory disappeared still opens at its worktree root, with a notice explaining the fallback;
- when nothing usable exists, callers receive a `rejected` result naming the missing worktree instead of starting a shell at a bogus path.

## Cross-instance harness transport ownership

A harness process only answers the Meringue instance holding its stdin/stdout pipes, so prompting must never produce two writers on one session. `Harness::TransportOwnership` records the owning instance per session under `~/.meringue/transport-locks` (override with `MERINGUE_TRANSPORT_LOCK_DIR`) and guards takeover with an advisory file lock. Each claim persists both the harness and owner PID plus their process-start timestamps, so PID reuse cannot make a dead owner look current.

`PiClient#prompt_session` uses it whenever the local process registry has no transport for the session:

- `Harness::ProcessIdentity` first confirms the recorded pid is still a live process that matches the configured harness command and recorded start time. A reused pid is treated as dead and is never signaled, so prompting simply resumes from the session file.
- if the previous owner is gone, the orphaned harness process is stopped and the session is resumed from its session file (a single writer, with history preserved);
- if another *live* Meringue instance owns the session, takeover waits briefly for its turn to settle and then takes over; the previous owner observes its process exit and can take the session back the same way on its next prompt;
- only a live owner that is still mid-turn is refused, with an actionable message naming the owning instance pid and stating that prompting takes over once the turn settles;
- a takeover records `transport_reclaimed_at`, `transport_reclaimed_pid`, `transport_previous_owner_pid`, and a `transport_note` on the worker, and `abort_session` reports the owning instance instead of a bare missing-process error.

The lease is also durable supervision evidence. Pi RPC processes are direct children using anonymous pipes; if the dashboard exits, every child can exit together when its stdin closes. When both the recorded harness identity and its Meringue owner identity are gone, `PiClient#session_supervision_evidence` proves this shared-supervisor failure to reconciliation. The kernel then durably claims one continuation per worker, reattaches the same saved Pi session on the same workspace, and records the replacement PID. A live owner still means an isolated child exit and is never auto-prompted. See [Session reconciliation](session-reconciliation.md#a-meringue-supervisor-exit).

The kernel remains the only mutator of orchestration state; the client only reports the resulting session ref and supervision evidence.

## Native Pi focus handoff

Pi does not expose an embeddable `InteractiveMode` renderer or an atomic live-token transfer. Meringue therefore uses a **coordinated process handoff**, not a claim that streaming bytes move between runtimes:

1. The kernel durably claims the worker's `interactive_handoff` before process I/O. The claim includes the worker/issue ids, issue title and description, original assignment, workspace path/branch, session identity, and owner process identity. A repeated request—whether from the same dashboard or a second instance—is rejected while this claim is live, so cancellation and ownership transfer happen exactly once.
2. `PiClient` refreshes authoritative RPC state and snapshots retained events, session-file context, and the latest turn outcome. If a prompt or tool call is active, it uses Pi's supported `abort` RPC and observes the turn settled before stopping the managed process. A timeout or refusal leaves that writer in place and fails the handoff instead of killing an unknown in-flight operation.
3. Meringue records that an interrupted turn still owes a final result, resolves the native environment, releases transport ownership, and terminates the now-settled RPC process. No native process starts while a managed writer is alive. A resumable worker that already has no RPC process is treated as quiesced. Executable discovery uses the provider's effective `PATH`—including inherited and `[harness.pi.env]` values—and returns an absolute executable to the workspace controller before ownership changes.
4. The workspace controller launches the real `pi --session …` InteractiveMode process in a PTY that occupies the dashboard logs pane. It prefers the same persisted JSONL session and supplies a bounded continuation prompt when entry settled an active turn. That prompt carries assignment, issue, latest-intent, assistant-progress, path, and branch context and tells Pi to inspect existing files before repeating tools. If the original file is unavailable but RPC can still export entries, Pi writes a version-3 replacement JSONL session and both owners use it thereafter.
5. While the PTY owns the session, reconciliation and managed prompting for that worker stand down. AgentTree and external dashboard chat continue refreshing and accepting mouse/keyboard input. Meringue consumes the workspace leader before routing input; all other bytes go to Pi only when its logs pane has keyboard focus. The PTY receives each logs-pane resize.
6. On focus close, Meringue closes the native process first, then reattaches the dashboard RPC client to the same session file and restores the previous logs-pane mode. If native focus produced a newer final assistant result, dashboard ownership returns settled. If it exited with a pending tool call or no newer final result, the dashboard automatically sends the saved continuation and returns the worker to `working` before reconciliation can classify the intentionally interrupted turn. No manual recovery prompt is required.
7. The marker is cleared only after reattachment and any required continuation succeed. A failed resume remains retryable, a launch that never starts restores RPC ownership, and the bounded claim is retained as `last_interactive_handoff` for diagnostics after active ownership is released.

If Meringue crashes after native focus starts, the persisted marker records the interactive pid and start time. A later owner verifies that pid still matches the configured command, reclaims it, and only then resumes the same session; a reused or unrelated pid is never signaled. This closes the PTY-launch race as well as the ordinary focus lifecycle without allowing a second writer.

This preserves the single-writer invariant and protects strict settle classification: a genuine provider/transport failure or abandoned tool call still errors, while a focus-induced interruption stays under the handoff marker until it has a newer final result or an active automatic continuation. Pi still has no public live provider-request checkpoint, so the transition uses its supported abort boundary and may require the continuation to inspect work already written before repeating a tool.

The former external session opener remains available only when native focus is not active. It is never used as a second writer against a focused worker. Non-Pi providers continue to use the existing read-only session view because they do not expose the native handoff capability.

## Manual integration verification

Start with the automated suite: `rake test` covers the parts of this integration that do not need a live terminal, a real harness process, or network access (see `docs/testing.md`). Put any repeatable assertions in `test/` and run the suite rather than a one-off script.

The checks below still require the interactive TUI, real worktrees, or real harness processes, so verify them by hand:

1. Register a large repository at a normal main checkout, spawn a `shared_read_only` informational worker, and confirm it starts immediately in that checkout without a new directory/branch. Start a second reader and confirm both use the same path. Confirm Pi exposes only read/grep/find/ls and refuses write/edit/bash calls. Repeat with a bare registered root: confirm an existing linked main checkout is selected, then remove it and confirm Meringue falls back to an isolated non-bare worktree rather than launching in the bare repository.
2. Select a worker with a verified open PR, restart Meringue, and confirm the worker selection and workspace view recover.
2. Press the workspace leader followed by `p` and confirm the tracked PR opens from both focused views; confirm bare `Ctrl-B` still reaches the PTY. Replace the PR URL with malformed metadata and confirm a useful unavailable notice is shown instead.
3. Remove/rename the worktree and harness session file, then render the workspace. Confirm notices are shown and state is not pruned or rewritten.
4. Configure missing terminal/editor executables and confirm those actions fail in place without closing Meringue.
5. Run `/prune` with open, closed, merged, and forge-unavailable PRs. Confirm only bundles whose PRs are settled (merged or closed) are eligible. For an eligible worker, confirm a clean managed worktree is removed while its branch remains; then repeat with dirty, locked, and metadata-mismatched worktrees and confirm the worktree/branch remain safely while the eligible records are pruned with a warning log. Confirm a manually missing or already-removed worktree is handled idempotently.
6. Run `/recount` and confirm the durable selected worker follows its new ID.
7. Render a Pi session containing repeated assistant messages, streaming deltas, reasoning, tool calls/results, direct bash output, failures, and lifecycle events. Confirm all transcript entries—not only the compact completion log—remain visible and scrollable while live updates continue; cycle every transcript filter and verify category colors apply to the role/type-and-timestamp header, that assistant/reasoning/user bodies use the normal foreground while tool call/result bodies are dimmed, that wrapped bodies keep every character, and that streaming reasoning deltas never appear as a duplicate assistant fragment.
8. Run a colorized zsh child process and confirm SGR colors survive the embedded screen model. Type quickly in terminal view and confirm PTY echo remains responsive, the initial prompt appears in the viewport, and ordinary keys are forwarded. Repeatedly switch worker/terminal views and use leader + `q`; confirm each dashboard return is an immediate full redraw, the read refresher exits, no thread/CPU leak or exception occurs, and both worker and terminal continue running. Confirm Esc neither closes worker view nor takes a stale return path (and still reaches the PTY in terminal view).
9. Exercise the complete native Pi flow. First launch Meringue with `pi` available only in its inherited `PATH`; then repeat with an intentionally restricted inherited `PATH` and Pi available only through `[harness.pi.env] PATH`; finally use an absolute `[harness.pi] command`. In each case open native focus while a managed prompt/tool call is active and confirm Pi receives one abort, the managed turn settles before its RPC writer exits, and native focus becomes the only session owner. Confirm Pi occupies only the logs pane; type a prompt and a Pi slash command there, resize the terminal, and verify interaction and wrapping remain correct. While Pi is responding, click/tab through AgentTree and dashboard chat, change selection, route an external chat message, and monitor other worker/log/status updates; confirm those panes stay live and their keystrokes never reach Pi. Return focus to logs and confirm Pi still accepts input. Leave with leader + `q` before the continuation finishes; confirm the prior logs mode returns, keyboard focus is usable, the dashboard reattaches once, automatically continues the saved assignment, keeps the worker `working`, and reconciliation does not mark the pending tool turn errored. Repeat after allowing native focus to produce a final result and confirm the dashboard does not send a duplicate continuation. Finally, repeat with a completed worker whose RPC process is already gone, with cancellation during pending handoff, and with an unavailable command; confirm saved-session focus opens in the first case and the other cases restore the previous dashboard without a second owner or frozen input.
10. Open terminal view for a worker whose worktree exists and confirm the shell prompt shows the worktree path exactly once and stays stable across redraws. Remove that worktree and confirm the workspace shows the stale-worktree notice instead of a nested or invented path.
11. Scroll both focused views with the wheel and `PageUp`/`PageDown` on a long transcript. Confirm scrolling stays responsive, scrolling past either end does not build up dead offsets, and scrolling stays smooth. The bounded regression check for per-step scroll cost lives in `test/integration/workspace/terminal_scroll_performance_test.rb`.
12. In the focused composer, type `/` and confirm the workspace command list appears, that `Tab` completes and `Up`/`Down` select, that `/filter tools` and `/cwd` apply immediately, that `/bogus` and `/filter nope` report in place without prompting the worker, and that ordinary text is still sent as a follow-up.
13. Start two Meringue instances against the same state file. Prompt the same settled worker from each in turn and confirm both succeed, that the worker's pid changes to the prompting instance's process, that only one harness process for the session is alive at a time, and that the harness session file keeps one continuous history. Prompt from the second instance while the first is mid-turn and confirm the actionable owner message appears and that prompting succeeds once the turn settles.
5. Queue a real worker behind a real worker on one issue (`after_from_command`). Confirm the second session starts in the first one's worktree with the first one's uncommitted changes present, that its prompt carries the shared-workspace block, and that only one branch and one PR exist for the issue. Then `/prune` the issue and confirm the shared worktree is removed exactly once, with no repeated "could not be removed" warning. Repeat with the predecessor still mid-turn and confirm the successor gets its own worktree and one log line explaining why.
6. Run `/prune` with open, closed, merged, and forge-unavailable PRs. Confirm only bundles whose PRs are settled (merged or closed) are eligible. For an eligible worker, confirm a clean managed worktree is removed while its branch remains; then repeat with dirty and locked worktrees and confirm the bundle/worktree remain with a warning log until cleaned/unlocked and retried. Confirm a manually missing or already-removed worktree is handled idempotently.
7. Run `/recount` and confirm the durable selected worker follows its new ID.
8. Render a Pi session containing repeated assistant messages, streaming deltas, reasoning, tool calls/results, direct bash output, failures, and lifecycle events. Confirm all transcript entries—not only the compact completion log—remain visible and scrollable while live updates continue; cycle every transcript filter and verify category colors apply to the role/type-and-timestamp header, that assistant/reasoning/user bodies use the normal foreground while tool call/result bodies are dimmed, that wrapped bodies keep every character, and that streaming reasoning deltas never appear as a duplicate assistant fragment.
9. Run a colorized zsh child process and confirm SGR colors survive the embedded screen model. Type quickly in terminal view and confirm PTY echo remains responsive, the initial prompt appears in the viewport, and ordinary keys are forwarded. Repeatedly switch worker/terminal views and use leader + `q`; confirm each dashboard return is an immediate full redraw, the read refresher exits, no thread/CPU leak or exception occurs, and both worker and terminal continue running. Confirm Esc neither closes worker view nor takes a stale return path (and still reaches the PTY in terminal view).
10. Outside native Pi focus, press leader + `a` and confirm the external launcher receives the selected worker record. During native focus it should show the already-open notice rather than create a second writer.
11. Open terminal view for a worker whose worktree exists and confirm the shell prompt shows the worktree path exactly once and stays stable across redraws. Remove that worktree and confirm the workspace shows the stale-worktree notice instead of a nested or invented path.
12. Scroll both focused views with the wheel and `PageUp`/`PageDown` on a long transcript. Confirm scrolling stays responsive, scrolling past either end does not build up dead offsets, and scrolling stays smooth. The bounded regression check for per-step scroll cost lives in `test/integration/workspace/terminal_scroll_performance_test.rb`.
13. In the focused composer, type `/` and confirm the workspace command list appears, that `Tab` completes and `Up`/`Down` select, that `/filter tools` and `/cwd` apply immediately, that `/bogus` and `/filter nope` report in place without prompting the worker, and that ordinary text is still sent as a follow-up.
14. Start two Meringue instances against the same state file. Prompt the same settled worker from each in turn and confirm both succeed, that the worker's pid changes to the prompting instance's process, that only one harness process for the session is alive at a time, and that the harness session file keeps one continuous history. Prompt from the second instance while the first is mid-turn and confirm the actionable owner message appears and that prompting succeeds once the turn settles.
