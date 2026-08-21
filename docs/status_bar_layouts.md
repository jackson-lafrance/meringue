# Custom status-bar layouts

Meringue keeps the hand-tuned status bars until a layout is explicitly saved. To
open the composer, type `/status-bar` (the `/statusbar` and `/layout` spellings
are aliases). The composer edits three surfaces:

- **Bottom status bar** — the dashboard context/actions and live status.
- **Agent-information bar** — the focused worker's identity and workspace controls.
- **Focused-worker bar** — the focused worker's commands and session status.

The right side of the composer is a live preview of the selected bar. Preview
changes are in memory only. They are not written when the composer opens, while
items are moved, or when the preview is cancelled.

## Keyboard workflow

- `Tab` / `Shift-Tab` selects the next or previous bar.
- `Up` / `Down` selects an item in that bar.
- `Left` / `Right` moves the selected item one position. `Home` and `End` move
  it to the first or last position; Space moves it one position to the right.
- `R` restores all three bars to their built-in order.
- `Enter` or `Ctrl-S` saves. `Esc` cancels the preview without saving.
- A save is one atomic configuration transaction. If the configuration changed
  elsewhere first, the save is rejected and the composer remains open so the
  user can review the draft against the newer file.

## Mouse workflow

Click a bar in the left rail to select it. Click and drag an item in the preview
list to its new position. The item follows the pointer while the button is held;
releasing the button completes the move. The footer also exposes save, reset,
and cancel targets. Mouse wheel movement changes the selected bar or item when
it is over the corresponding list.

The composer remains usable after a terminal resize. Small terminals show an
explicit size warning and keep `Esc` available so a preview cannot trap the
user.

## Persistence and recovery

The saved value is the versioned `tui.status_bar_layout` setting. It is a JSON
string so it can be written by the existing TOML configuration writer without
introducing a second persistence format:

```toml
[tui]
status_bar_layout = "{\"version\":1,\"bars\":{\"bottom\":[\"status\",\"context\"],\"agent_information\":[\"identity\",\"controls\"],\"focused_worker\":[\"status\",\"controls\"]}}"
```

The composer canonicalizes supported legacy bar names and item aliases, removes
duplicates, and restores a bar's defaults when an old list is empty. Unknown
versions, malformed JSON, wrong types, and invalid item names are ignored as a
whole; Meringue falls back to the existing renderer rather than drawing a blank
bar. Removing the layout (using `R` followed by Save) writes an empty setting,
which restores the built-in rendering path on the next frame.

No layout is read from or written to Meringue's orchestration `state.json`.
The temporary `_status_bar_layout` snapshot used by the TUI is presentation-only;
the config store and kernel remain the sole durable writers.
