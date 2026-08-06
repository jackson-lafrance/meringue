# First-run setup

The first time you launch `meringue` on a machine, a short flow **takes over the
whole terminal** and walks you through four choices: theme, harness, model, and
thinking level. Theme comes first so the rest of setup renders in the colors you
picked. It ends with one card in the logs pane that names what you picked and
teaches the core loop, so the very next thing you type can be a real goal.

Before this existed, a new user landed on two empty boxes and a prompt, and
`/harness`, `/model`, `/thinking`, `/theme` and the AgentTree gestures were all
undiscoverable.

## Design rules

- **It owns the screen.** Setup is not a popup competing with the logs pane for
  rows: while it runs the dashboard is not drawn at all. There is one thing on
  screen and one thing to answer.
- **Mouse-safe.** Visible option rows can be clicked, but empty-space clicks and
  dashboard mouse gestures cannot advance, select, or dismiss setup. `Esc` is
  still the only skip affordance.
- **Never a trap.** `Esc` exits from any step, keeps everything already applied,
  and never reopens by itself. Setup is always reachable again with `/setup`.
- **Never blocking.** Reading the flow only reads persisted state, so it never
  starts a harness process and never waits on a model catalog. A missing, stale,
  unsupported, or still-loading catalog explains itself and still offers a row.
- **The kernel is the only writer.** Each choice is applied as the ordinary slash
  command for it, so validation, journaling, and the visible log line are exactly
  what a typed command produces. The flow writes nothing itself.
- **One visual language.** The card, border, selection highlight, caption, and
  bottom hint line are the dashboard's own primitives (`Canvas`, `Style`,
  `Keybindings`), so setup looks like the app it is introducing.

## The screen

```txt
                       meringue · first-run setup                  ← title
   ────────────────────────────────────────────────  ← rule (sweeps out)

   ✓ theme gruvbox   ✓ harness pi   ▸ model   · thinking           ← step rail
   step 3 of 4  ━━━━━━━━━━━━━━━━━━━╬╬╬╬╬╬╬╬╬╬╬  50%       ← progress (eases)

 ╭─ setup · 3/4 · model (pi) ─────────────────────────────╮
 │ The default model for new Pi sessions. Type to filter,        │  ← what the step changes
 │ Ctrl-R re-asks the harness.                                  │
 │                                                              │
 │ ▸ openai/gpt-5.6-sol  current default · GPT-5.6 Sol          │  ← rows (staggered reveal)
 │   anthropic/claude-opus-5  Claude Opus 5 · thinking: xhigh    │
 ╰──────────────────────────────────────────────────╯
   step 3 of 4  ·  ↑↓ move · click row · Enter applies · ← back · Esc skip

 click rows or use keys · empty-space clicks cannot skip setup
```

The card is centered horizontally and vertically, capped at 88 columns so long
model references fit without prose turning into a wall. Everything is recomputed
from the viewport every frame, so a resize is just a redraw.

## Animation

Animation is chrome, and it is a **pure function of how long the current step has
been on screen**. Nothing is buffered, queued, or replayed, so a dropped frame, a
resize, or a forced full redraw all recompute the same picture for the same
instant, and a terminal that cannot animate renders the settled frame instead of
a half-finished one.

| Motion | What it does |
| --- | --- |
| Rule sweep | The rule under the title draws out from the left in 0.3s with an eased head. |
| Progress bar | Eases (cubic ease-out, 0.4s) from the fraction the previous step left to this step's, so advancing and going back both read as movement. Going back animates in reverse. |
| Row reveal | Prose and rows appear in a staggered cascade (45ms apart, capped at 0.36s total) and slide two columns in as they land, so a long list tightens its stagger instead of taking seconds. |
| Selection | The highlighted row carries the AgentTree's selection palette as a full-width band, and its marker breathes between `▸` and `▹` on a 1.2s period — it does not blink or strobe. |
| Refresh spinner | `Ctrl-R` on the model step is the only place that waits on something outside the flow, so it is the only spinner. It stops as soon as the catalog snapshot on screen is a different one, and gives up after 12s rather than spinning forever. |

Cost is bounded: setup asks for a 20fps frame only **while a step still has motion
left in it**. Once the step settles it falls back to a 0.3s idle tick for the
breathing marker and transient notices, which is cheaper than the dashboard's own
refresh. It reuses the existing render loop and frame diffing — there is no second
renderer, no background thread, and no cursor trickery.

### How it degrades

| Condition | Behavior |
| --- | --- |
| Non-interactive stdin (a pipe, a recorded frame, the test suite) | No animation; the settled frame is rendered once. |
| Terminal smaller than 60×16 | No animation: every row is needed for content, so the settled frame is drawn immediately. Setup still runs. |
| `MERINGUE_NO_ANIMATION=1`, or `animations = false` under `[tui]` | No animation anywhere in setup, and the idle tick drops back to the normal refresh interval. |
| Slow terminal | Frames are skipped, not queued: each frame asks "what does this instant look like", so a stall lands on a later value and never replays the animation. |
| Resize or full redraw mid-animation | Recomputed from the new size at the same instant. Chrome drops in a fixed, decorative-first order (the rule, then the title, then the step rail, then the progress bar, then the caption); the card and the bottom hint that names `Esc` are the last things standing. |
| Not drawing UTF-8 (`MERINGUE_ASCII_GLYPHS=1`, or a locale that is not UTF-8) | The whole screen switches to one ASCII glyph set (`=`/`-` bar, `>` marker, `*` done, `|/-\` spinner) and the wordmark is replaced by the plain word, rather than a half-broken mix. It is the same flag the AgentTree's harness marks already honor. |
| Short card | The wordmark is dropped before the pitch that explains the product; prose is trimmed before a choice list loses rows. |

## The steps

| Screen | What it does | Applied as |
| --- | --- | --- |
| `setup · welcome` | One paragraph on what Meringue is and how work flows through it, plus a begin row. | — |
| `setup · 1/4 · theme` | The six colorschemes. Moving the highlight repaints setup live; applying it keeps the rest of setup in that theme. | `/theme <name>` |
| `setup · 2/4 · harness` | `pi`, `claude`, `antigravity`, each with the logo the AgentTree uses. | `/harness <name>` |
| `setup · 3/4 · model (pi)` | The models the harness itself reported, searchable, current default first. | `/model <provider>/<model-id>` |
| `setup · 4/4 · thinking` | Every level the kernel accepts, labelled by what the catalog knows. | `/thinking <level>` |

Every step starts on the value that is already in effect, and re-applying a value
is accepted by the kernel, so holding `Enter` through the flow accepts every
default and finishes in about a second without changing anything.

Choosing a harness other than Pi drops the model and thinking steps, because both
write `[harness.pi]` and the other harnesses report them as unsupported. Because
theme has already been chosen, applying the non-Pi harness finishes setup.

## Keys

Setup adds no new keybindings; it reuses the ones the pickers already use.

| Key | Action |
| --- | --- |
| `Enter` | apply the highlighted row and continue; finish on the last step |
| `↑` / `↓` | move the highlight (it wraps) |
| `←` | go back one step |
| `Esc` | exit setup now, keeping what was already applied |
| printable / `Backspace` / `Ctrl-W` | filter — model step only |
| `Ctrl-R` | re-fetch the model catalog (`/models <harness> refresh`) — model step only |
| left-click a visible row | apply that row and continue; finish on the last step |

`←` is the `cursor_left` action, so rebinding `cursor_left` in
`[tui.keybindings]` also changes setup's back key.

Keys the flow does not own pass through, so `Ctrl-C` still quits and setup is
never a trap. Pasting is swallowed except on the model step, where it filters:
it can never land in the composer hidden behind the screen.

## The mouse cannot skip setup

While setup is on screen, a left-click on a visible option row applies that row
just like `Enter`. Other mouse reports — right click, middle click, release, drag,
both wheel directions, and left-clicks on chrome or empty space — are inert. They
do not move the highlight, advance a step, dismiss the flow, or reach the
dashboard underneath.

This is a deliberate change. Setup used to render in the shared popup slot, where
a click on a row applied it and a click anywhere else was a click-away dismiss — so
a single stray click during a first launch silently skipped onboarding, which is
exactly the moment a user is least likely to know that `/setup` would bring it
back. Empty-space clicks are now inert, with `Esc` as the one skip affordance.

A missed click is answered rather than swallowed silently, so it can never be
mistaken for a frozen screen: the bottom line of the screen shows `Click an
option row, press Enter to continue, or Esc to skip setup.` for a few seconds
(shortened on a narrow terminal), and it clears when the step changes.

## Back, skip, and resume

- **Back** is non-destructive. It returns to a step without un-applying anything
  (there are no inverse kernel commands), and the finish card reports what is
  really in effect. Backing off the theme step also rolls back its live preview.
- **Skip** applies nothing further, prints `Setup skipped — run /setup any time.`
  with the settings that are in effect, and records the marker so setup does not
  open by itself again.
- **Quitting mid-flow** (`Ctrl-C`, `/quit`) records nothing, so setup appears once
  more on the next launch. Choices already applied persist and are preselected.
  There is deliberately no saved mid-flow position: setup is transient UI, like
  the pickers, and is never written to `state.json`.
- **Resume** with `/setup` at any time. It always restarts from the welcome
  screen.

## When it does not open

| Condition | Behavior |
| --- | --- |
| The config already carries the `[onboarding]` marker | Never opens by itself; `/setup` still works. |
| `meringue demo` | Never opens: there is no kernel to apply a choice, and `/setup` says so. |
| Non-interactive stdin | Never opens; the TUI renders one frame and exits. |
| Terminal narrower than 46 columns or shorter than 12 rows | Does not auto-open. If the terminal is resized under a running flow, setup closes with `Setup needs a bigger terminal (at least 46×12) — run /setup after resizing.` and records nothing. |

## The marker

Completion is recorded in the config file, not in `state.json`, because
`meringue reset-state` and `/clear` legitimately wipe state and re-onboarding
after every reset would be a nag:

```toml
[onboarding]
completed_version = 1
completed_at = "2026-08-06T14:02:11Z"
outcome = "completed"   # or "skipped"
```

Delete the section to see setup again on the next launch. `completed_version`
leaves room for a future revision of the flow to replay setup without a second
key.

The marker is written by the `CompleteOnboarding` kernel command, which the flow
submits as `/setup complete` or `/setup skip` when it ends. It honors
`--config PATH` like every other config write. It is deliberately not proposable
by a head agent: it is UI lifecycle, and a head has no way to know whether a
human saw the flow.

## Degraded model catalog

The model step reads the kernel's cached catalog snapshot (see
[session-settings.md](session-settings.md)) and never fetches one itself. When
there is nothing to list, it shows the picker's own explanation for that exact
state — never fetched, unavailable, unsupported, or a filter that matched nothing
— plus one row:

```txt
▸ keep the default  anthropic/claude-opus-5 · Ctrl-R asks pi for its model list
```

`Enter` on that row applies nothing and moves on, so a slow catalog can never
trap the flow. Rows appear on their own once the background refresh lands,
because state is re-read every frame. A stale catalog is still the harness's own
answer, so it is listed in full rather than hidden.
