# Custom bottom status-bar layouts

Only the dashboard's bottom status bar is configurable. The agent-information strip on an embedded worker and the focused-worker command/status bar always retain their hand-tuned built-in layouts.

The composer appears directly on the **Status bar** page during first-run Setup and every manual `/setup` rerun; moving components never opens another page. It is also available full-screen with `/status-bar` (plus the `/statusbar` and `/layout` aliases).

## Components and live preview

The centered preview renders the real bottom bar from the current draft and current AgentTree state. Its palette contains:

- **Context** — what is true right now rather than a standing count: the pinned log scope, the gesture that clears a selected chat target, unanswered questions, and the selected target's own pull request. With nothing selected it shows the standing discovery hints instead;
- **Open PRs** — the number of currently open delivery pull requests;
- **Workers** and **Heads** — current working counts;
- **Harness** — one shared harness or explicit head/worker values;
- **Model** — one shared model or explicit head/worker values; and
- **Thinking** — one shared thinking level or explicit head/worker values.

Each component can be absent or placed once in either the **left aligned** or **right aligned** drop zone. Dragging within a zone reorders it; dragging across zones changes its alignment; dragging back to the palette removes it. The default puts context, PR, and agent counts on the left and harness, model, and thinking on the right, so future-session defaults remain visible. Split head/worker values are never collapsed into a misleading shared label.

Context is a component rather than a fixed part of the bar, but removing it also removes the affordances it carries, so it leads the default left zone. It deliberately omits the worker and head counts that the **Workers** and **Heads** components render, so placing all three prints each count once.

Preview changes stay in memory. Setup folds them into its existing settings draft; `/status-bar` owns a separate draft. Neither path writes while the user moves an item.

## Keyboard workflow

In the full-screen `/status-bar` composer:

- `Up` / `Down` selects a palette component.
- `Left` / `Right` moves it through the visible bar, crossing the center to change alignment.
- `Home` / `End` moves it to the outer left/right edge.
- `Space` cycles it from the palette to left, left to right, and right back to the palette. `X`, Backspace, or Delete removes it.
- `R` restores the useful default.
- `Enter` or `Ctrl-S` saves; `Esc` cancels without writing.

On the inline Setup page the component keys are the same, except `Enter`, `Ctrl-S`, and `Tab` activate the centered **Next** action. `Shift-Tab`, Backspace, and Delete retain the documented previous-step keybinding. `X` removes a component.

A direct Save is one atomic configuration transaction. If the file changed after the composer opened, the save is rejected and the draft remains visible. In Setup, **Next** only keeps the layout in memory; final **Complete** persists it with every other setup choice and the onboarding marker in one transaction.

## Mouse workflow

Drag any palette or placed component into either drop zone. Hovering a placed component while dragging chooses that insertion point, so the same gesture supports alignment changes and reordering. The direct composer footer also exposes Reset, Save, and Cancel. Mouse-wheel movement changes the selected component.

The composer remains recoverable after terminal resizing. A full-screen composer below `48×12` shows an explicit warning and keeps `Esc` visible; the inline Setup page follows Setup's responsive card and always retains its navigation/recovery footer.

## Persistence and migration

The saved `tui.status_bar_layout` value is versioned JSON inside TOML:

```toml
[tui]
status_bar_layout = "{\"version\":2,\"bottom\":{\"left\":[\"context\",\"open_pull_requests\",\"workers\",\"heads\"],\"right\":[\"harness\",\"model\",\"thinking\"]}}"
```

Version 2 accepts only known components, rejects duplicates across zones, and rejects malformed or unknown versions as a whole. Invalid or absent data falls back to the complete default instead of drawing a blank footer. Reset followed by Save removes a custom value.

Version-1 documents are migrated from their old bottom `context`/`status` blocks. Their agent-information and focused-worker entries are intentionally ignored, restoring those two bars to their prior defaults.

No layout is read from or written to orchestration `state.json`. `_status_bar_layout` and the inline composer snapshot are presentation-only; the config store and kernel remain the sole durable writers.
