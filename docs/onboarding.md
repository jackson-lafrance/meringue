# First-run setup

The first interactive launch opens **Setup**, a centered welcome card distinct from the dense `/config` editor. It walks someone from a fresh checkout to a dashboard that can actually route work: a harness Meringue can start, a registered project for work to land in, and a look they chose — before anything is written.

Setup is not a chat prompt and does not maintain a second settings implementation. It uses `Config::Schema`, `Settings::Draft`, the shared editors and hit testing, and the same `SaveConfiguration` transaction as `/config`; only the presentation and navigation are first-run friendly.

## Steps

The centered card shows one dynamic `Step N of 7` indicator:

1. **Welcome** — what Meringue is, in the three nouns the rest of the flow depends on: you describe a goal, a head decides what should happen, workers do the work in their own worktrees. No controls; the navigation action is focused so Enter continues.
2. **Harness** — the one decision Meringue cannot run without. Both role harnesses are listed with the product name and whether this machine can actually start them (`Claude Code · installed`, `Codex CLI · not found`). Choosing either role fills the other while it is still unset, so the common case is one selection. **Check harness** runs each selected backend once and reports what it answered. Model and reasoning sit behind a single **Model and reasoning** reveal, because every harness ships defaults that work.
3. **Project** — offers the repository Meringue was started in, named from its README heading by the same `ProjectNaming` the heads use. Ticked by default; unticking registers nothing. Without a project there is nowhere for issues and workers to go, which is why the offer is here rather than left for the user to discover.
4. **Theme** — theme and animation preference. Theme changes preview immediately in memory.
5. **Status bar** — shows the default bottom-bar layout as it currently reads. **Customize layout** opens the live drag-and-drop composer inline; leaving the step closes it. The other two worker bars retain their built-in defaults.
6. **Meringue Xtras** — experiment controls derived directly from `Experiments::Registry`, all off until chosen. The read-only **Test GitHub access** action is completely absent until GitHub support is selected.
7. **Done** — the harness, project, theme, and experiments the Complete action is about to save, so finishing is checkable rather than hopeful.

Welcome and Done carry no controls at all. The flow derives navigation from the step list, so future setup sections can be appended without introducing a review-only special case.

## Harness is required

Setup will not finish without a harness. Schema validation normally runs only over settings the user actually changed — correct for `/config`, where an unrelated save must not fail on a field nobody edited — but it is also how setup used to reach Complete with `agent.head_harness` and `agent.worker_harness` still empty, write `outcome = "completed"`, and leave a dashboard that rejected the first prompt with "No agent harness is configured."

`Settings::SetupFlow::REQUIRED_SETTING_IDS` names what completion cannot omit, and `Draft#validate(required_ids:)` checks those regardless of whether they changed. A missing harness moves setup to the Harness step and renders the field error, the same recovery path as any other validation failure. A confirmed first-run **skip** stays permissive: it deliberately writes only the marker and explicit experiment defaults.

## Harness availability

`Harness::Availability` resolves the first entry of each provider's configured command argv, through that provider's own environment and `PATH` — the same resolution `Registry#build_client` hands to the launcher, so what setup reports and what a worker will actually run cannot disagree. Locating is a filesystem walk with no subprocess, which is what makes it safe on a render path; `Registry#provider_availability` caches it per launch and `reload_config!` invalidates it.

Setup preselects a harness only when exactly one is installed. With several, or none, it still asks — guessing which backend someone meant is the mistake the registry deliberately refuses to make. A backend Meringue cannot find is never hidden from the picker, because someone may be configuring a machine they are about to install it on; it just says so.

**Check harness** is the only path that runs anything. It starts each selected harness once with `--version`, bounded by `Availability::PROBE_TIMEOUT_SECONDS`, and reports `ready`, `partly ready`, or `not ready` with what the harness said. Locating an executable and running it are different questions, and only the second one answers whether Meringue can start a session.

## Registering the launch directory

The Project step's offer is applied as an ordinary `/project add <path> "<name>"` command, submitted only after the `SaveConfiguration` transaction has been accepted. Registering a project is orchestration state rather than configuration, so it stays a separate command owned by the kernel; sequencing it behind the accepted save means a rejected draft cannot leave a project behind from a setup that never finished.

## Interaction

- `↑` / `↓`: move through the current card's controls; moving past the last ordinary control focuses the navigation footer. A card with no controls at all (Welcome, Done) focuses its navigation action from the start, so Enter always continues. On the status-bar composer these keys select a component.
- `←` / `→`: change a focused boolean toggle or move focus; they never advance to another setup step. On the status-bar page they reorder the selected component and move it across the center alignment boundary.
- `Enter`: begin, toggle a checkbox, open a picker for list-backed values such as theme and models, or activate the single centered **Next** action. On the status-bar page `Space` places/removes the selected component and `X` removes it.
- `Delete` / `Backspace`: go back one setup step.
- `Tab`: next setup step; `Shift-Tab` remains available as a backwards step shortcut.
- `Esc`: first-run skip or manual cancel, as described below.
- Left-click: select controls, choose picker entries, or click the displayed **Next** or **Complete** navigation control. On the status-bar page, drag components within or between its left/right drop zones.
- Mouse wheel: move the current list or status-bar component selection. Empty space and right-click remain inert.

Every setup screen uses the same **Navigate** footer. The bordered card contains one centered **Begin**, **Next**, or **Complete** action; the redundant Back button is omitted because Backspace, Delete, and Shift-Tab already provide the documented backwards navigation, and the Welcome card's separate in-card "Begin Setup" row is gone because the footer action already started the flow.

Exact model references remain supported when the catalog is unavailable. Enter opens the cached model picker for the selected harness without making a harness request; setup itself performs no model/network lookup.

## One draft, one write

Theme previews and all setting changes remain in `Settings::Draft`. Moving forward or back never writes a command and never loses an edit. Complete validates the whole draft and submits one private `/config save …` command carrying:

- the file fingerprint captured when setup opened;
- all changed schema setting IDs, including the bottom-bar layout composed inline during Setup;
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

- **80+ columns:** a spacious centered card with centered Begin and Next/Complete actions plus, once asked for, the inline status-bar drag-and-drop surface.
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
