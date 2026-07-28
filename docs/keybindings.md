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

## Text selection and clipboard

Selection is rendered by Meringue itself, so it works without holding `Shift` and without switching the host terminal into its own selection mode. A selection is always scoped to the pane the drag started in: a drag that leaves the logs pane clamps to the logs text area instead of highlighting the AgentTree or the composer.

- Drag with the left mouse button in the logs pane: select log text. The highlight uses the active colorscheme's `SELECTION` style and follows the content while you scroll.
- Drag with the left mouse button in the chat composer: select input text. Clicking without dragging just moves the cursor.
- `Ctrl-C` / `Alt-C`: copy the selection to the system clipboard. While a selection is active, `Ctrl-C` copies instead of clearing the input or quitting.
- `Esc`: clear the selection.
- `Shift-Left` / `Shift-Right` / `Shift-Up` / `Shift-Down`: extend the composer selection by character or line.
- `Shift-Home` / `Shift-End`: extend the composer selection to the start or end of the current line.
- `Shift-Alt-Left` / `Shift-Ctrl-Left` and `Shift-Alt-Right` / `Shift-Ctrl-Right`: extend the composer selection by word.
- `Ctrl-X`: cut the composer selection to the clipboard.
- `Ctrl-V`: paste the system clipboard into the composer, replacing any selection. Your terminal's own paste (`Cmd-V` / `Ctrl-Shift-V`) still works through bracketed paste.
- Typing, `Backspace`, or `Delete` with an active composer selection replaces or deletes the selected text.

Copy uses a local clipboard command when one is available (`pbcopy` on macOS, then `wl-copy`, `xclip`, or `xsel` on Linux) and falls back to the OSC 52 terminal escape so remote sessions can still reach the local clipboard. Paste reads `pbpaste`, `wl-paste`, `xclip`, or `xsel`. The bottom hint line confirms a copy or reports `clipboard unavailable`.

Paste is composer-only; the logs pane is copy-only.

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

- `Ctrl-Space`, then `T`: switch between the terminal and agent view.
- `Ctrl-Space`, then `F`: cycle transcript filters through `all`, `output`, `final`, `reasoning`, and `tools`.
- `Ctrl-Space`, then `A`: open the worker's underlying agent session with Meringue's existing external session launcher. Missing, malformed, or otherwise unavailable sessions are reported in place.
- `Ctrl-Space`, then `B`: launch the configured external editor in the worker worktree.
- `Ctrl-Space`, then `P`: open the verified delivery pull request when one exists.
- `Ctrl-Space`, then `Q`: quit either focused subview back to the AgentTree without stopping the worker or its workspace terminal.

The helper line under the focused chat box is exactly this leader line and nothing else:

```txt
Ctrl-Space  T terminal/agent · F filter: all · A agent session · B editor · P PR · Q quit
```

Key letters and labels come from the active bindings, so custom bindings render accurately. The `F` entry always shows the active transcript filter, which resets scroll to the newest matching entry, persists across restart for the selected worker, and resets to `all` when another worker is selected.

### Workspace slash commands

The focused composer also accepts slash commands, scoped to the selected worker. Typing `/` opens a `workspace commands` list above the composer; `Tab` completes, `Up`/`Down` select, and `Enter` applies a highlighted suggestion or runs the typed command. Anything that does not start with `/` is still a direct follow-up prompt.

| command | effect |
| --- | --- |
| `/help` | List the workspace commands. |
| `/terminal` | Switch between the terminal and agent view. |
| `/filter [all\|output\|final\|reasoning\|tools]` | Set the transcript filter, or cycle it when no value is given. |
| `/session` | Open the worker's underlying agent session externally. |
| `/editor` | Open the worker worktree in the configured editor. |
| `/pr` | Open the verified delivery pull request. |
| `/cwd` | Show the worker's resolved worktree directory. |
| `/cancel` | Cancel the worker's current turn without ending its session. |
| `/quit` | Return to the AgentTree, keeping the worker and its terminal alive. |

`/pi`, `/back`, `/pwd`, `/abort`, and a few other obvious aliases resolve to the same actions. Unknown commands, unknown filters, and stray arguments are reported in the workspace instead of being sent to the worker as a prompt. In terminal view there is no composer, so `/` goes to the shell and the leader keys remain the way to switch views.

`Enter` still sends a direct follow-up into the selected worker's existing context through the kernel-owned `PromptAgent` path, `Shift-Enter` still inserts a newline, and `PageUp`/`PageDown` or the mouse wheel still scroll the agent transcript; those are no longer repeated in the hint line. In terminal view the mouse wheel scrolls the terminal viewport while `PageUp`/`PageDown` go to the shell.

The leader and each suffix are configurable as `workspace_leader`, `workspace_switch_view`, `workspace_cycle_filter`, `workspace_open_agent_session` (legacy alias `workspace_open_pi_session`), `workspace_open_editor`, `workspace_open_pull_request`, and `workspace_close`. Leader + `q` is the only focused-workspace return command. `cancel_navigation`/`Esc` remains scoped to dashboard jump mode and never closes a focused workspace; Esc is ignored in worker view and forwarded in terminal view. An unknown suffix is passed to the active view rather than silently discarded. In terminal view, every key other than the configured leader—including bare `t`, `f`, `a`, `b`, `p`, `q`, `Ctrl-T`, `Ctrl-B`, `PageUp`/`PageDown`, `Esc`, `Ctrl-C`, and `Ctrl-D`—is sent to the isolated workspace terminal. The external agent-session action validates persisted session history and uses the established detached terminal launcher; it does not replace, signal, or transfer ownership of Meringue's managed harness RPC process. The embedded worktree terminal starts in the worker's real worktree directory, preserves child-process ANSI/SGR colors, consumes charset-designation and DCS/APC/PM/SOS escapes (so `sgr0`-style resets never leak a stray `B` into shell output), keeps multi-byte glyphs intact across PTY read boundaries, and redraws on a low-latency terminal cadence as a viewport (no row is spent on an overflow label); background Pi transcript snapshots pause while terminal view is active and resume immediately on return. Press `Ctrl-Space`, then `t` to switch back, or `Ctrl-Space`, then `q` to return directly to the AgentTree while keeping the shell alive. The shell follows terminal resizes and is cleaned up without signaling the managed worker when Meringue exits. Completed or unavailable sessions remain inspectable in worker view, and failures are shown in place without mutating the saved worker record.

Scrolling either focused view reuses the dashboard's frame-diffed rendering: composed lines are cached until the underlying transcript or terminal screen actually changes, offsets are clamped to what the pane can scroll, and the workspace selection is written to the state file on a slow cadence instead of once per scroll step.

Agents with an open pull request are marked `↗` in the AgentTree. Worker selection and focused-workspace view state are restored from the state file after restart; selections for pruned workers are cleared safely.

See [Agent workspace delivery and recovery integration](agent_workspace_integration.md) for persistence, stale PR metadata, and degraded dependency behavior.
