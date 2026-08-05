# First-run setup

The first time you launch `meringue` on a machine, a short modal flow opens over
the dashboard and walks you through four choices: harness, model, thinking level,
and theme. It ends with one card in the logs pane that names what you picked and
teaches the core loop, so the very next thing you type can be a real goal.

Before this existed, a new user landed on two empty boxes and a prompt, and
`/harness`, `/model`, `/thinking`, `/theme` and the AgentTree gestures were all
undiscoverable.

## Design rules

- **Never a trap.** `Esc` exits from any step, keeps everything already applied,
  and never reopens by itself. Setup is always reachable again with `/setup`.
- **Never blocking.** Reading the flow only reads persisted state, so it never
  starts a harness process and never waits on a model catalog. A missing, stale,
  unsupported, or still-loading catalog explains itself and still offers a row.
- **The kernel is the only writer.** Each choice is applied as the ordinary slash
  command for it, so validation, journaling, and the visible log line are exactly
  what a typed command produces. The flow writes nothing itself.
- **One visual language.** It uses the same popup slot, border, caption, and keys
  as the `/models` picker; the dashboard stays visible behind it.

## The steps

| Screen | What it does | Applied as |
| --- | --- | --- |
| `setup · welcome` | One paragraph on what Meringue is and how work flows through it. | — |
| `setup · 1/4 · harness` | `pi`, `claude`, `antigravity`, each with the logo the AgentTree uses. | `/harness <name>` |
| `setup · 2/4 · model (pi)` | The models the harness itself reported, searchable, current default first. | `/model <provider/model>` |
| `setup · 3/4 · thinking` | Every level the kernel accepts, labelled by what the catalog knows. | `/thinking <level>` |
| `setup · 4/4 · theme` | The six colorschemes. Moving the highlight repaints the dashboard live. | `/theme <name>` |

Every step starts on the value that is already in effect, and re-applying a value
is accepted by the kernel, so holding `Enter` through the flow accepts every
default and finishes in about a second without changing anything.

Choosing a harness other than Pi drops the model and thinking steps, because both
write `[harness.pi]` and the other harnesses report them as unsupported. The step
counter becomes `1/2`, `2/2`.

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
| click a row / click away | apply that row / exit setup |

`←` is the `cursor_left` action, so rebinding `cursor_left` in
`[tui.keybindings]` also changes setup's back key.

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
| Terminal narrower than 64 columns or shorter than 20 rows | Does not auto-open. If the popup collapses while setup is up, it closes with `Setup needs a taller terminal — run /setup after resizing.` |

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
› keep the default  anthropic/claude-opus-5 · Ctrl-R asks pi for its model list
```

`Enter` on that row applies nothing and moves on, so a slow catalog can never
trap the flow. Rows appear on their own once the background refresh lands,
because state is re-read every frame. A stale catalog is still the harness's own
answer, so it is listed in full rather than hidden.
