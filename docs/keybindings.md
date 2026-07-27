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

- `Up` / `Down` / `Left` / `Right`: select an agent. In the logs pane, only the selected agent title is highlighted; non-agent events are not selected.
- `Enter`: open the selected agent's pull request when a PR is available.
- `a`: open the selected agent's focused workspace. Selecting an issue opens its newest non-killed worker.
- `Esc`: cancel jump mode.

## Focused agent workspace

The focused workspace replaces the dashboard while it is open, so the live agent and terminal never compete in simultaneous subviews. The header keeps the selected agent, status, issue, harness, working directory, and PR visible.

- `Enter`: send the focused agent a direct follow-up through the normal kernel `PromptAgent` path.
- `Shift-Enter`: insert a newline in that follow-up.
- `Ctrl-T`: switch between the live agent and terminal experiences.
- `Ctrl-E`: open the agent workspace in the configured editor.
- `Ctrl-B`: open the attached pull request when one exists.
- `Esc`: return to the selected item in the AgentTree. This only changes TUI navigation; it does not abort, kill, or otherwise change the worker session.

In terminal view, all other keys—including `Ctrl-C` and `Ctrl-D`—are sent to the workspace terminal instead of quitting Meringue. Completed or unavailable sessions remain inspectable in agent view, and failures are shown in the workspace without closing the dashboard or mutating the saved worker record.

Agents with an open pull request are marked `↗` in the AgentTree.
