# First-run setup

The first interactive launch opens **Setup**, a centered welcome card distinct from the dense `/config` editor. It lets a user review defaults, choose a theme, and opt into experiments before anything is written.

Setup is not a chat prompt and does not maintain a second settings implementation. It uses `Config::Schema`, `Settings::Draft`, the shared editors and hit testing, and the same `SaveConfiguration` transaction as `/config`; only the presentation and navigation are first-run friendly.

## Steps

The centered card shows one dynamic `Step N of 5` indicator:

1. **Welcome** — starts the flow.
2. **Theme** — theme and animation preference. Theme changes preview immediately in memory.
3. **Head defaults** — harness, Pi model, and Pi thinking level for future routing heads.
4. **Worker defaults** — independently chosen harness, Pi model, and Pi thinking level for future workers.
5. **Experiments** — controls derived directly from `Experiments::Registry`. GitHub support is currently the only experiment; when it is enabled, the page also offers the read-only **Test GitHub access** action.

Experiments is the final page and its navigation action is **Complete**. The access action checks the current `origin` with bounded, non-interactive `gh auth status` and `gh repo view` calls; it does not write GitHub resources and reports its result in the setup card. The flow derives navigation from the step list, so future setup sections can be appended without introducing a review-only special case.

The complete `/config` editor remains available for provider commands and environment, workspaces, safety, launchers, keybindings, and read-only provenance. Setup deliberately presents only the decisions useful on a first launch.

## Interaction

- `↑` / `↓`: move through the current card's controls; moving past the last control focuses the navigation footer.
- `←` / `→`: change a focused boolean toggle or move focus; they never advance to another setup step.
- `Enter`: begin, toggle a checkbox, open a picker for list-backed values such as theme and models, or activate **Next** when the navigation footer is focused.
- `Delete` / `Backspace`: go back one setup step.
- `Tab`: next setup step; `Shift-Tab` remains available as a backwards step shortcut.
- `Esc`: first-run skip or manual cancel, as described below.
- Left-click: select controls, choose picker entries, or click the displayed **Next**, **Back**, or **Complete** navigation controls.

Every setup screen uses the same **Navigate** footer. It displays the current action (`Next` or `Complete`), Enter, and the Delete/Backspace Back action.
- Mouse wheel: move the current list. Empty space, chrome, right-click, releases, and drags are inert.

Exact model references remain supported when the catalog is unavailable. Enter opens the cached Pi model picker without making a harness request; setup itself performs no model/network lookup.

## One draft, one write

Theme previews and all setting changes remain in `Settings::Draft`. Moving forward or back never writes a command and never loses an edit. Complete validates the whole draft and submits one private `/config save …` command carrying:

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

- **80+ columns:** a spacious centered card with a centered, enlarged Begin Setup action and clickable Next/Back/Complete controls.
- **46–79 columns:** the same card shrinks to the available width while retaining the heading, single step indicator, and keyboard hints.
- **32–45 columns:** compact card copy and the single step indicator, with `Esc` recovery always visible.
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
