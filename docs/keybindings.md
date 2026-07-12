# TUI Keybindings

Use `/keybind` inside the interactive TUI to show the complete keybinding list in the conversation pane.

## Global

- `Ctrl-D`: quit.
- `Ctrl-C`: clear input; quit when input is empty.
- `Esc`: quit from an empty prompt; cancel jump mode when jump mode is active.

## Focus and scrolling

- `Tab` / `Ctrl-Tab`: move focus forward.
- `Shift-Tab`: move focus backward.
- Arrow keys, `PageUp` / `PageDown`, and mouse wheel: scroll the focused non-chat pane.
- When the agent tree is focused, `Enter` enters jump mode.

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

Start jump mode with `/jump` or by focusing the agent tree and pressing `Enter`.

- `Up` / `Down` / `Left` / `Right`: select an agent.
- `Enter`: open the selected agent session.
- `p`: open the selected agent's pull request when a PR is available. If the agent has no PR or the opener fails, Meringue silently does nothing.
- `Esc`: cancel jump mode.

## PR navigation

Start PR navigation with `/jumpr`.

- `Up` / `Down` / `Left` / `Right`: select an agent with an attached PR.
- `Enter`: open the selected PR.
- `p`: also opens the selected PR.
- `Esc`: cancel PR navigation.
