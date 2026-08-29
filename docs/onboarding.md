# First-run setup

The first interactive launch opens **Setup**, a centered welcome card distinct from the dense `/config` editor. It walks someone from a fresh checkout to a dashboard that can actually route work: a harness Meringue can start and a look they chose — before anything is written.

Setup is not a chat prompt and does not maintain a second settings implementation. It uses `Config::Schema`, `Settings::Draft`, the shared editors and hit testing, and the same `SaveConfiguration` transaction as `/config`; only the presentation and navigation are first-run friendly.

## Steps

The centered card shows one dynamic `Step N of 5` indicator:

1. **Welcome** — what Meringue is, in the three nouns the rest of the flow depends on: you describe a goal, a head decides what should happen, workers do the work in their own worktrees. No controls; the navigation action is focused so Enter continues.
2. **Harness** — the one decision Meringue cannot run without, asked once. A first run does not distinguish head from worker: there is a single **Harness** row, and the answer is applied to both roles. Options carry the product name and whether this machine can actually start them (`Claude Code · installed`, `Codex CLI · not found`). **Check harness** runs the selected backend once and reports what it answered. Splitting the roles deliberately is what `/config` is for.
3. **Theme** — theme and animation preference. Theme changes preview immediately in memory.
4. **Meringue Xtras** — experiment controls derived directly from `Experiments::Registry`, all off until chosen. **Customize your status bar** opens a context-rich agent session; the read-only **Test GitHub access** action is completely absent until GitHub support is selected.
5. **Done** — the harness, theme, and experiments the Complete action is about to save, so finishing is checkable rather than hopeful.

Welcome and Done carry no controls at all. The flow derives navigation from the step list, so future setup sections can be appended without introducing a review-only special case.

## The status bar is not asked about here

The dashboard bottom bar is not a first-run decision. It always uses the built-in layout, while the focused worker's status surfaces retain their own built-in information.

## Model and reasoning are not asked here

Neither setting appears in a first run. Every harness ships defaults that work, and the model picker cannot even be answered during setup: its list comes from a catalog the harness reports once a session has run, so on a fresh install `ModelPicker.entries` returns nothing usable and the only entry is the default that was already selected. Offering a picker whose sole option is the current value is worse than not offering it. Both settings live in `/config`, where the catalog exists.

## Harness is required

Setup will not advance past the Harness step until one is chosen, and it will not finish without one. Blocking at the step is what makes the requirement legible: checking only at Complete meant someone could hold Tab — or arrow onto the navigation action and press Enter — through every card and learn five screens later that the second one was mandatory. `SetupFlow::REQUIRED_SETTING_IDS_BY_STEP` names what each step will not let you walk past — only settings that step actually renders, because a refused move lands the cursor on the control that is missing and cannot do that for a row nobody drew. A refused move writes the field error, drops focus off the action, and lands the cursor on that control. `REQUIRED_SETTING_IDS`, the Complete backstop, still lists both role harnesses: the mirror is what makes them equal, and a backstop that checked only the visible half would not notice if the mirror stopped running.

Backwards navigation is never gated — going back to re-read something is not a way to dodge the requirement — and `Esc` still skips the whole flow, because skipping is a deliberate confirmed choice rather than something you can do by leaning on a direction key. Schema validation normally runs only over settings the user actually changed — correct for `/config`, where an unrelated save must not fail on a field nobody edited — but it is also how setup used to reach Complete with `agent.head_harness` and `agent.worker_harness` still empty, write `outcome = "completed"`, and leave a dashboard that rejected the first prompt with "No agent harness is configured."

`Settings::SetupFlow::REQUIRED_SETTING_IDS` names what completion cannot omit, and `Draft#validate(required_ids:)` checks those regardless of whether they changed. A missing harness moves setup to the Harness step and renders the field error, the same recovery path as any other validation failure. A confirmed first-run **skip** stays permissive: it deliberately writes only the marker and explicit experiment defaults.

## Harness availability

`Harness::Availability` resolves the first entry of each provider's configured command argv, through that provider's own environment and `PATH` — the same resolution `Registry#build_client` hands to the launcher, so what setup reports and what a worker will actually run cannot disagree. Locating is a filesystem walk with no subprocess, which is what makes it safe on a render path; `Registry#provider_availability` caches it per launch and `reload_config!` invalidates it.

Setup preselects a harness only when exactly one is installed. With several, or none, it still asks — guessing which backend someone meant is the mistake the registry deliberately refuses to make. A backend Meringue cannot find is never hidden from the picker, because someone may be configuring a machine they are about to install it on; it just says so.

**Check harness** is the only path that runs anything. It starts each selected harness once with `--version`, bounded by `Availability::PROBE_TIMEOUT_SECONDS`, and reports `ready`, `partly ready`, or `not ready` with what the harness said. Locating an executable and running it are different questions, and only the second one answers whether Meringue can start a session.

## Registering a project

Setup registers nothing. Project discovery and registration happen later, when the first goal is routed: registering a project is orchestration state rather than configuration, and a rejected draft must not be able to leave a project behind from a setup that never finished.

## Interaction

- `↑` / `↓`: move through the current card's controls; moving past the last ordinary control focuses the navigation footer. A card with no controls at all (Welcome, Done) focuses its navigation action from the start, so Enter always continues.
- `←` / `→`: change a focused boolean toggle or move focus; they never advance to another setup step.
- `Enter`: begin, toggle a checkbox, open a picker for list-backed values such as theme and models, or activate the single centered **Next** action.
- `Delete` / `Backspace`: go back one setup step.
- `Tab`: next setup step; `Shift-Tab` remains available as a backwards step shortcut.
- `Esc`: first-run skip or manual cancel, as described below.
- Left-click: select controls, choose picker entries, or click the displayed **Next** or **Complete** navigation control.
- Mouse wheel: move the current list selection. Empty space and right-click remain inert.

The navigation action shows when it is focused, as `› [ Next ] ‹` in the selection style (`> [ Next ] <` with `MERINGUE_ASCII_GLYPHS=1`). Without that, arrowing down onto it changed nothing on screen and pressing Enter was a guess.

Focus is in one place at a time. While the action holds it no row is selected — no marker, no highlight, no `· Enter open picker` hint — even though the row index is kept so `↑` returns to the row it left rather than to the top. The line that describes the selected row describes the action instead (`Next: Theme.`); it stays filled rather than collapsing so arrowing onto the action does not reflow the card underneath the cursor.

Every setup screen uses the same **Navigate** footer. The bordered card contains one centered **Begin**, **Next**, or **Complete** action; the redundant Back button is omitted because Backspace, Delete, and Shift-Tab already provide the documented backwards navigation, and the Welcome card's separate in-card "Begin Setup" row is gone because the footer action already started the flow.

Setup makes no model or network lookup of any kind: the only thing it can run is **Check harness**, and only when asked.

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

- **80+ columns:** a spacious centered card with centered Begin and Next/Complete actions.
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
