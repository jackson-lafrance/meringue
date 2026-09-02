# Changelog

All notable changes to Meringue will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version headings are added only after the maintainer has chosen a release version and date.

## Unreleased

### Fixed

- Pi heads and workers no longer show as blocked, `needs input`, or `retry me` because an
  extension drew a status widget. Pi emits every `ctx.ui.*` call as an `extension_ui_request`,
  and Meringue read all of them as a dialog waiting for a person, so a `setWidget` from an
  extension such as Precognition pinned every new session as `blocked`, kept it from ever
  settling, and made heads look like failed transport. Only the dialog methods (`select`,
  `confirm`, `input`, `editor`) count now, markers already saved for fire-and-forget calls are
  read as answered, killed agents drop their pending marker, and the status-bar
  `agents need input` counter skips killed and completed workers instead of only ever climbing.
- Setup no longer has a Status bar step. Activating its **Customize layout** control set a flag
  that emptied the card: the inline drag surface behind that flag had no draft, no snapshot, and
  no key routing, so the step went blank and no composer ever appeared. Arranging the bar stays
  where it already worked — the **Customize your status bar** action in Meringue Xtras, and the
  standalone `/status-bar` composer — and the unreachable inline scaffolding is gone.
- First-run setup asks for one harness and applies it to both roles, instead of asking twice and
  then offering model and reasoning behind a reveal. The model picker could not be answered during
  a first run anyway: its list comes from a catalog the harness reports once a session has run, so
  on a fresh install it is empty by construction and the only entry is the default already
  selected. Both settings live in `/config`, where the catalog exists.
- Setup will not advance past the Harness step until one is chosen. Checking only at Complete meant
  someone could hold Tab through every card and learn five screens later that the second one was
  mandatory. A refused move writes the field error and lands the cursor on the control that is
  missing; going backwards is never gated, and `Esc` still skips the flow.
- Clicking a picker option now commits the same way pressing Enter on it does. The mouse path
  skipped the harness mirror, so a first run driven by the mouse set one role and left the other
  empty, and it ignored the editor's "custom command…" entry.
- The role suffix in the model-picker lookup was stripped with `/_model\z/` — a literal backslash
  and a `z` rather than the end anchor — so the head model row resolved its catalog through the
  worker harness.
- The dashboard resolves its state path the way every other subcommand does, so
  `MERINGUE_STATE_PATH` applies to `meringue` itself. It read `State::Store::DEFAULT_PATH`, which
  also let the schema migration judge "is this a new install?" from a file the user had pointed
  away from.
- The setup completion card reports a mode as the mode it is. It tested every experiment against
  `true`, so agent defaults read as "off" one screen after the setup card showed it as "By role".
- Escape works again across the settings and setup UI. The app turns on kitty CSI-u and xterm
  modifyOtherKeys at startup, and the point of both is that Escape stops arriving as a bare `\e`
  — kitty sends `\e[27u`, xterm `\e[27;1~` — but only the bare byte was bound, so a picker could
  be opened and not closed. All the encodings are bound now, as every other key already was.
- The setup navigation action shows when it has focus, as `> [ Next ] <` in the selection style,
  and the row list deselects while it does: focus is in one place at a time. The line that
  describes the selected row describes the action instead once the action has focus, rather than
  explaining a row nobody selected, and stays filled so the card does not reflow underneath the
  cursor. The row index is still kept, so arrowing back up returns to the row it left.
- The advanced-settings reveal in `/config` closes again. Opening it used to remove the row that
  opened it, so nothing was left to press to put the rows away; it now keeps its place, toggles
  both ways under the same cursor, and `A` opens and closes it from anywhere in the category, as
  the footer says.
- `/update` follows the branch the installation tracks (`main`, or `MERINGUE_BRANCH`) instead of
  pulling whatever branch happened to be checked out. An installation parked on a stale branch
  used to fast-forward nothing, report success, and restart into the same code; it is now moved
  back onto the tracked branch. A checkout that is already current says so and keeps running
  rather than reloading, and a successful update names the commit it landed on.
- Restored `Kernel::Engine#harness_client` and `#head_runner` as public accessors. Duplicate
  definitions below the class's `private` keyword had shadowed them, so `meringue head-loop`
  raised `NoMethodError` instead of settling the workers it spawned.
- Removed two other silently discarded duplicate definitions in the kernel engine, and restored
  the `message`/`Message` payload aliases on `PromptAgent` that the surviving handler had lost.
- An unbalanced quote in a slash command now produces a usage message instead of raising
  `NameError: uninitialized constant Shellwords::ParseError`. The submission that raised also
  used to sit in the durable queue forever and replay on every start; it now drains, and a
  slash command that fails is reported in the dashboard instead of disappearing.
- An unreadable `state.json` no longer stops Meringue from starting: it is moved to
  `state.json.unreadable-<timestamp>`, kept verbatim, and reported as a warning log entry.
- `/recount` refuses an orphaned issue or worker by name instead of aborting with
  `KeyError: key not found`.
- `AnswerQuestion` no longer revives a dismissed question.
- `meringue reset-state --state PATH` resets that file instead of silently resetting the default.
- A worker path containing a null byte is reported as an unusable workspace instead of raising
  `ArgumentError` into the render loop.
- State saves use a per-write temporary file name, so two writers in one process can no longer
  delete each other's in-flight snapshot.

### Added

- Added a quiet-worker signal. A `working` agent that has produced nothing for longer than
  `[agent] quiet_worker_warning_seconds` (default 900; `0` disables) is marked `quiet 40m` in the
  AgentTree, counted in the bottom status bar, and reported once per quiet stretch as a warning.
  See `docs/quiet-workers.md`.
- Added Codex CLI as a selectable interactive harness with durable session resumption, focused live-terminal attachment, rollout-based reconciliation, and authoritative model discovery.

### Changed

- Head agents now continue an issue in a fresh worker session by default instead of re-prompting an existing one. The follow-up is spawned with `after_agent_id` and `follow_up_of_agent_id`, so the kernel starts it immediately, hands over the predecessor's final report, and continues it in the predecessor's worktree and branch. `PromptAgent` is reserved for steering a mid-turn worker, recovering one whose turn died mid-flight, and explicit requests to continue a session.
- Goal loops spawn a new session for every iteration. `continuity` now selects the checkout rather than the session: `accumulate` (default) continues in the previous attempt's worktree and branch so work and the metric stay cumulative, and `fresh_attempt` starts each attempt from a clean tree, which is what it always claimed to do.
- The goal session budget is now checked per iteration rather than per session, so a goal never starts an attempt it lacks the budget to judge. The default rose to `2 × max_iterations + 4` to cover a reviewer retry.
- Workers are told their final message is a handover for a successor that never sees their transcript, and must state what they ruled out, what is committed, and what is left.
- `/prune` retains a settled predecessor while a successor that continues its work is still running, not only while one is still queued behind it, and reports that retention.
- Split the 20,940-line `Kernel::Engine` into `lib/meringue/kernel/engine/*.rb` by command family,
  and the 7,106-line `TUI::App` into `lib/meringue/tui/app/*.rb` by dashboard surface. Both remain
  one class; every method body, comment, constant, and visibility is unchanged.
- Made `Models.ensure_state_shape!` skip the pull-request migration and the workspace-mode rewrite
  for records that have nothing to migrate. It runs on every state read and every kernel command,
  so a read-only command at 1,000 workers went from ~8ms to ~2.7ms and a reconciliation pass from
  ~119ms to ~38ms.
- Removed `Heads::SimpleLoop`'s unreachable second copy of the worker-wait path and `TUI::App`'s
  compatibility shim for a `handle_key` signature nothing calls.
- `meringue --help` now lists every slash command, rendered from the parser's own table instead of
  a hand-written subset that named 17 of 47. `/issue move`, which shipped without ever reaching
  the in-app `/help`, is documented there too.
