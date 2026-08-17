# First-run setup

The first interactive launch opens **Setup**, a centered welcome card distinct from the dense `/config` editor. It lets a user review defaults, choose a theme, and opt into experiments before anything is written.

Setup is not a chat prompt and does not maintain a second settings implementation. It uses `Config::Schema`, `Settings::Draft`, the shared editors and hit testing, and the same `SaveConfiguration` transaction as `/config`; only the presentation and navigation are first-run friendly.

## Steps

The centered card shows six numbered steps with a current-step marker and `Step N of 6` progress text:

1. **Welcome** — explains the draft and starts the flow.
2. **Theme** — theme and animation preference. Theme changes preview immediately in memory.
3. **Head defaults** — harness, Pi model, and Pi thinking level for future routing heads.
4. **Worker defaults** — independently chosen harness, Pi model, and Pi thinking level for future workers.
5. **Experiments** — checkboxes derived directly from `Experiments::Registry`. GitHub support is currently the only experiment.
6. **Review** — a compact summary of every setup value. Select a summary row to return to its editing step, or choose **Finish setup**.

The complete `/config` editor remains available for provider commands and environment, workspaces, safety, launchers, keybindings, and read-only provenance. Setup deliberately presents only the decisions useful on a first launch.

## Interaction

- `↑` / `↓`: move through the current card's rows, including its **Continue** action.
- `←` / `→`: change a selector or cached Pi model. On a row without choices, move between steps.
- `Space`: toggle the selected checkbox.
- `Enter`: begin from Welcome, edit/change a value, activate **Continue**, revisit a value from Review, or Finish.
- `Tab` / `Shift-Tab`: next/back through setup steps; the card also provides a visible Continue/Finish action.
- `Ctrl-S`: go to Review; on Review, finish.
- `Esc`: first-run skip or manual cancel, as described below.
- Left-click: select a visible step/row, toggle a checkbox, or use the visible Next/Finish/Cancel buttons on wide terminals.
- Mouse wheel: move the current list. Empty space, chrome, right-click, releases, and drags are inert.

Exact model references can be typed when the catalog is unavailable. When a cached Pi catalog is present, `←` / `→` cycles it without making a harness request. Setup itself performs no model/network lookup.

## One draft, one write

Theme previews and all setting changes remain in `Settings::Draft`. Moving forward or back never writes a command and never loses an edit. Finish validates the whole draft and submits one private `/config save …` command carrying:

- the file fingerprint captured when setup opened;
- all changed schema setting IDs;
- explicit defaults for experiment paths that are still absent; and
- `onboarding_outcome = "completed"`.

`Config::Store` acquires the config lock, rejects a stale fingerprint, validates the settings and cross-field rules, patches settings and onboarding metadata into one document, fsyncs a same-directory temporary file, and atomically renames it. There is no point at which the setup marker is committed without the reviewed settings, or vice versa.

On success, live-safe values apply, the overlay closes, and the dashboard receives a compact summary of the head, worker, theme, and experiment choices. Existing sessions are unchanged.

If validation fails, setup moves to the affected step and renders the field error. If locking, parsing, stale-revision checking, or publication fails, setup stays open with the actionable failure and can be retried or cancelled. A failed publish leaves the previous file and onboarding marker untouched.

## First-run skip versus `/setup` cancel

The origin of the overlay matters:

- **Automatically opened first run:** `Esc` opens **Skip first-run setup?**. `Esc` again returns to the draft. `Enter` confirms skip, discards all setup edits and theme preview, and atomically saves only `outcome = "skipped"` plus explicit new-install experiment defaults. The skipped marker prevents repeated prompting; `/setup` remains available.
- **Manual `/setup` rerun:** `Esc` closes a clean draft immediately. A dirty draft gets the normal discard confirmation. Confirming restores the original theme and writes nothing, including no change to an existing completed/skipped marker.
- **Process quit or interrupt:** the in-memory draft is discarded and its theme preview is restored. No marker is written, so an unfinished first run appears again on the next launch.

The old non-interactive `/setup complete` and `/setup skip` command spellings remain accepted for scripts and compatibility. They write the same version-1 marker through `CompleteOnboarding`; the interactive overlay no longer uses them.

## First run, rerun, and terminal size

Setup automatically opens only when:

- a live kernel backs the TUI (`meringue demo` has none);
- `[onboarding].completed_version` is below `1`;
- stdin is interactive; and
- the terminal is at least `32×10`, large enough to show recovery keys.

`/setup` reopens the overlay from Welcome regardless of the existing marker. A `/setup` request below `32×10` gets an explanatory message instead of an invisible modal. If the terminal shrinks below the minimum while setup is open, a minimal full-screen message keeps `Esc cancel` visible; cancelling writes no outcome. Resizing back simply redraws the draft.

Responsive presentation keeps the setup card centered without requiring a large terminal:

- **80+ columns:** a spacious centered card with a readable progress bar and clickable Begin/Next/Finish/Cancel actions.
- **46–79 columns:** the same card shrinks to the available width while retaining the heading, progress count, and keyboard hints.
- **32–45 columns:** compact card copy and abbreviated progress, with `Esc` recovery always visible.
- **below 32×10:** terminal-too-small message and `Esc cancel` only.

The welcome marker has a restrained four-frame shimmer when Animations is enabled. Disabling Animations freezes it. `NO_COLOR` affects only styling; `MERINGUE_ASCII_GLYPHS=1` replaces progress and welcome glyphs with ASCII markers, so the step number and action text remain understandable in screen readers, plain terminals, and screenshots.

## Marker and compatibility

Completion or confirmed first-run skip records:

```toml
[onboarding]
completed_version = 1
completed_at = "2026-08-16T14:02:11Z"
outcome = "completed" # or "skipped"
```

The marker lives in the config file rather than `state.json`, so `meringue reset-state` and `/clear` do not replay setup. Onboarding version 1 remains accepted; existing users are not forced through the redesigned overlay. Delete `[onboarding]` to simulate a first run.
