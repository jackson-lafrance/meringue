# TUI Keybindings

Use `/keybind` inside the interactive TUI to show the active keybinding list in the logs pane. Defaults can be customized in `~/.meringue/config.toml` under `[tui.keybindings]`; see `docs/config.md` for the full schema.

## Customizing

Add overrides under `[tui.keybindings]` in your Meringue config. Omitted actions keep defaults.

```toml
[tui.keybindings]
agent_select_previous = ["k", "up", "left"]
agent_select_next = ["j", "down", "right"]
```

## Global

- `Ctrl-B`: open the selected worker's kernel-verified delivery pull request. If the PR is missing, malformed, or its status cannot be refreshed, Meringue reports that state without closing the dashboard or changing the worker.
- `Ctrl-D`: quit.
- `Ctrl-C`: clear input; quit when input is empty.
- `Esc`: cancel jump mode when navigation is active.

## Focus and scrolling

- Click a dashboard section: move focus to that section (the active outline follows the focused section). The logs pane includes user-visible prompts, agent output, and important kernel events.
- Click an issue or agent in the AgentTree: select/highlight it, matching jump mode selection.
- Double-click an agent (or an issue with a worker): open its focused workspace. This is the primary mouse action; PR opening remains an explicit action.
- `Tab` / `Ctrl-Tab`: move focus forward.
- `Shift-Tab`: move focus backward.
- Arrow keys, `PageUp` / `PageDown`, and mouse wheel: scroll the focused non-chat pane.
- When the agent tree or logs pane is focused, `Enter` enters jump mode. Non-agent log entries are skipped during jump navigation.

## Chat input

- `Enter`: send the prompt as typed, or apply the slash suggestion once one is selected.
- `Shift-Enter`: insert a newline.
- Arrow keys: move the cursor.
- `Home` / `Ctrl-A`: move to the start of the current line.
- `End` / `Ctrl-E`: move to the end of the current line.
- `Alt-Left` / `Ctrl-Left`: move left by word.
- `Alt-Right` / `Ctrl-Right`: move right by word.
- `Backspace` / `Delete`: delete characters.
- `Alt-Backspace` / `Ctrl-Backspace` / `Ctrl-W`: delete backward by word.
- `Alt-Delete` / `Ctrl-Delete`: delete forward by word.

## Slash suggestions

- Type `/` to show command suggestions. Nothing is selected until you navigate the list, so `Enter` still sends what you typed.
- `Up` / `Down`: select a suggestion; `Down` starts at the first entry and `Up` starts at the last.
- `Enter`: insert the selected suggestion into the input. Press `Enter` again to run it.
- `Tab`: complete the selected suggestion, or the first one when nothing is selected.

## Jump mode

Start jump mode with `/jump` or by focusing the agent tree or logs pane and pressing `Enter`.

- `Up` / `Down` / `Left` / `Right`: select an issue or agent. In the logs pane, only agent titles are selectable; non-agent events are skipped.
- `Ctrl-B`: open the selected worker's verified delivery pull request. The PR remains easy to open when status refresh is temporarily unavailable.
- `Enter`: open the selected agent's pull request when a PR is available.
- `a`: open the selected worker's focused workspace. Selecting an issue opens its newest non-killed worker; heads without a durable worker context stay on the dashboard.
- `Esc`: cancel jump mode.

## Focused worker workspace

The workspace is an optional, issue-specific deep-interaction tool—not a replacement for Meringue's normal head-agent chat. Open it when a worker needs sustained direction, iterative discussion, research, investigation, or closer visibility into responses and tool calls. Keep using the dashboard chat for new goals and routine orchestration through head agents.

The workspace replaces the dashboard while open, so the live worker and terminal never compete in simultaneous subviews. Its header keeps the selected worker, status, issue, harness, worktree, and verified delivery PR visible. The worker view renders the complete available active Pi transcript—not the compact dashboard completion log—including user and assistant messages, reasoning output, streaming updates, tool calls/results, errors, retries/compaction notices, and relevant turn/session lifecycle events. Normal output, final output, reasoning, tool calls, and tool results use distinct semantic colors in every TUI colorscheme.

Focused commands use a leader sequence so normal terminal control bindings are not stolen. The default leader is `Ctrl-Space`:

- `Ctrl-Space`, then `t`: switch between the live worker and worktree terminal.
- `Ctrl-Space`, then `f`: cycle transcript filters through `all`, `output`, `final`, `reasoning`, and `tools`. The current filter is shown in the worker-view hint, resets scroll to the newest matching entry, persists across restart for the selected worker, and resets to `all` when selecting another worker.
- `Ctrl-Space`, then `p`: open the worker's saved Pi session with Meringue's existing external session launcher. Missing, malformed, non-Pi, or otherwise unavailable sessions are reported in place.
- `Ctrl-Space`, then `e`: launch the configured external editor in the worker worktree.
- `Ctrl-Space`, then `b`: open the verified delivery pull request when one exists.
- `Ctrl-Space`, then `q`: leave either focused subview and return to the AgentTree without stopping the worker or its workspace terminal.
- `Enter`: send a direct follow-up into the selected worker's existing context through the kernel-owned `PromptAgent` path.
- `Shift-Enter`: insert a newline in that follow-up.
- `PageUp` / `PageDown` or mouse wheel: scroll the worker transcript; mouse wheel also scrolls terminal history.
- `Esc` in worker view: return to the selected AgentTree item. This only changes TUI navigation; it never aborts, kills, detaches, or replaces the worker session.

The leader and each suffix are configurable as `workspace_leader`, `workspace_switch_view`, `workspace_cycle_filter`, `workspace_open_pi_session`, `workspace_open_editor`, `workspace_open_pull_request`, and `workspace_close`. An unknown suffix is passed to the active view rather than silently discarded. In terminal view, every key other than the configured leader—including bare `t`, `f`, `p`, `e`, `b`, `q`, `Ctrl-T`, `Ctrl-E`, `Ctrl-B`, `Esc`, `Ctrl-C`, and `Ctrl-D`—is sent to the isolated workspace terminal. The external Pi action validates persisted session history and uses the established detached terminal launcher; it does not replace, signal, or transfer ownership of Meringue's managed Pi RPC process. The embedded worktree terminal preserves child-process ANSI/SGR colors and redraws on a low-latency terminal cadence; background Pi transcript snapshots pause while terminal view is active and resume immediately on return. Press `Ctrl-Space`, then `t` to switch back, or `Ctrl-Space`, then `q` to return directly to the AgentTree while keeping the shell alive. The shell follows terminal resizes and is cleaned up without signaling the managed worker when Meringue exits. Completed or unavailable sessions remain inspectable in worker view, and failures are shown in place without mutating the saved worker record.

Agents with an open pull request are marked `↗` in the AgentTree. Worker selection and focused-workspace view state are restored from the state file after restart; selections for pruned workers are cleared safely.

See [Agent workspace delivery and recovery integration](agent_workspace_integration.md) for persistence, stale PR metadata, and degraded dependency behavior.
