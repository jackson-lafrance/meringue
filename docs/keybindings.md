# TUI Keybindings

Use `/keybind` inside the interactive TUI to show the active keybinding list in the conversation pane. Defaults can be customized in `~/.meringue/config.toml` under `[tui.keybindings]`; see `docs/config.md` for the full schema.

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

- Click a dashboard section: move focus to that section (the active outline follows the focused section). Conversation includes timestamped kernel log events alongside chat-style entries.
- Click a worker in the agent tree: select/highlight that worker, matching jump mode selection.
- Double-click a worker in the agent tree: open that worker's pull request when one is available.
- `Tab` / `Ctrl-Tab`: move focus forward.
- `Shift-Tab`: move focus backward.
- Arrow keys, `PageUp` / `PageDown`, and mouse wheel: scroll the focused non-chat pane.
- When the agent tree or conversation pane is focused, `Enter` enters jump mode. Kernel log entries are skipped during jump navigation.

## Chat input

- `Enter`: send the prompt or apply the selected slash completion.
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

- Type `/` to show command suggestions.
- `Tab`: complete the selected suggestion.
- `Up` / `Down`: change the selected suggestion.

## Jump mode

Start jump mode with `/jump` or by focusing the agent tree or combined conversation/kernel pane and pressing `Enter`.

- `Up` / `Down` / `Left` / `Right`: select an agent. In the combined conversation/kernel pane, only the selected agent title is highlighted; kernel events are not selected.
- `Enter`: open the selected agent's pull request when a PR is available.
- `a`: open the selected agent session.
- `Esc`: cancel jump mode.

Agents with an open pull request are marked `↗` in the AgentTree.
