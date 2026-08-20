# TUI Keybindings

Use `/keybind` inside the interactive TUI to show the active keybinding list in the logs pane, or `/config` to edit every action in the full-screen Keybindings category. Defaults can also be customized in `~/.meringue/config.toml` under `[tui.keybindings]`; see `docs/config.md` for the full schema.

In `/config`, reveal the Keybindings category's advanced rows, select an action, and press `Enter` to enter dedicated key capture. The next single keyboard input is captured as the replacement binding, including arrows, function/control sequences, and `Enter`; navigation and editor controls do not pass through to the settings list. `Esc` cancels without changing the binding. `Backspace` or `Delete` clears it (an empty list intentionally unbinds the action). Mouse events, pastes, and other invalid multi-character input are rejected in place. Press `Enter` on the row again to capture a replacement; changes remain draft-only until Save succeeds.

## Customizing

Add overrides under `[tui.keybindings]` in your Meringue config. Omitted actions keep defaults.

```toml
[tui.keybindings]
agent_select_previous = ["k", "up", "left"]
agent_select_next = ["j", "down", "right"]
```

## Global

- `Ctrl-B`: open a delivery pull request. While an issue/worker is selected (or jump mode is on a row) it opens the owning issue's kernel-verified PR. With nothing selected it opens the **open pull requests** picker instead, because unscoped chat is not about one issue; `↑`/`↓` move, `Enter` opens the highlighted PR in the browser, and `Esc`, another `Ctrl-B`, a click outside the list, or any other key closes it. Clicking a row opens that row. If a PR is missing, malformed, or its status cannot be refreshed, Meringue reports that state without closing the dashboard or changing the selection. `/prs` opens this same all-open-PR picker directly, regardless of the current AgentTree selection.
- `Ctrl-R`: while the `/models` **model picker** is open, re-fetch the harness model catalog (`refresh_model_catalog`). It has no effect anywhere else, so it stays available for normal typing.
- `Ctrl-D`: quit.
- `Ctrl-C`: clear input; quit when input is empty.
- `Esc`: cancel the innermost active thing — a text selection or the logs selection cursor first, then the AgentTree selection (which clears the logs filter) and jump mode.

## Focus and scrolling

- Click a dashboard section: move focus to that section (the active outline follows the focused section). The logs pane includes user-visible prompts, agent output, and important kernel events.
- Click a project, issue, head, or worker row in the AgentTree: select/highlight it and filter the logs pane to it. Right-click an issue row to open its associated delivery PR; worker rows do not duplicate that affordance, and an issue without a PR gets a transient notice. Issue and worker selections also target subsequent natural-language chat through a fresh head. See [AgentTree selection, log filtering, and chat routing](#agenttree-selection-log-filtering-and-chat-routing).
- Click a worker id, worker title, or nonblank worker-authored message text in the logs pane: select/highlight that worker in the AgentTree and scope the logs to it. The exact targets exclude timestamps, icons, gutters, separators, status rows, trailing whitespace, head output, and kernel/user rows. A removed worker is inert. The logs pane keeps focus and its scroll position; an already-active jump cursor follows the worker without changing keyboard mode.
- Double-click text in the logs pane: select the word under the pointer. Triple-click: select the complete displayed paragraph, including all of its soft-wrapped rows (see [Text selection and clipboard](#text-selection-and-clipboard)). Drag, double-click, and triple-click selection take precedence over worker activation, and text-click tracking is per pane, so tree clicks and text clicks never pair up.
- Double-click an issue to open its delivery PR; without a PR it shows a transient notice and does not open a worker workspace. Double-click a worker with an assigned workspace to open its focused workspace; a worker without a workspace is a silent no-op.
- `Tab` / `Ctrl-Tab`: move focus forward.
- `Shift-Tab`: move focus backward.
- Arrow keys and `PageUp` / `PageDown`: scroll the focused non-chat pane by a line or a page.
- `Home` / `End`: scroll the focused non-chat pane to its first or last content line. With the logs selection cursor on, `Home` / `End` still move the cursor within its line.
- Mouse wheel: scroll whichever pane the pointer is over, without changing focus. Hovering a pane that cannot scroll (or the composer) falls back to scrolling the focused pane.
- While [first-run setup](#first-run-setup) is on screen, mouse input is setup-owned: visible setup rows can be clicked, but dashboard mouse actions and empty-space click-away dismissal are disabled.
- When the agent tree or logs pane is focused, `Enter` enters jump mode. Non-agent log entries are skipped during jump navigation.
- `r` in the focused AgentTree starts a quick rename for the selected project or issue by pre-filling `/project rename <project_id>` or `/issue rename <issue_id>` in the composer; type the new name and press Enter. A worker selection resolves to its owning issue.

## AgentTree agent colors and harness logos

Every agent row is rendered as `<status> <harness logo> <id>  <title>`, so an agent can be identified without reading its title:

```txt
HEADS
  └─ ● π H1  Route the request

●   P1  meringue working
  └─ ●   I1  Fix signup validation 1/3
    ├─ ● π W1  Add collision check
    ├─ ✓ ✳ W2  Hide password field
    └─ · ↑ W3  Check the migration
```

- **Identity color.** The logo and the id use that agent's deterministic per-id color from the active colorscheme's identity palette (`AGENT_PALETTE` in `lib/meringue/tui/style.rb`, assigned by `Style.agent_palette_index`). It is the same color as that agent's log header, its `▌` log gutter, and the composer tint it produces when selected — one palette, one color per agent, everywhere. Heads draw their logo bold, exactly like their log headers, so two sessions in the same palette slot still separate.
- **Every status keeps it.** Working agents, completed agents with a `✓`, and idle, queued, blocked, errored, and killed agents all keep their color and logo. Color is additive, never a replacement for status: the status glyph keeps its own semantic color (`○` queued, `●` working, `·` idle, `!` blocked, `✓` completed, `×` errored, `∅` killed) and a completed row still dims its title.
- **Harness logos.** `π` Pi, `✳` Claude Code, `↑` Antigravity, taken from the agent's own recorded harness (provider aliases such as `cc` or `agy` resolve to the same mark). The glyphs live with the other provider presentation in the harness registry, so panes never hard-code a backend.
- **Graceful degradation.** A harness Meringue does not ship (for example the `fake` harness used by tests) renders a plain ASCII initial rather than borrowing a shipped mark, and a record with no harness at all renders `?`, matching the unknown-status convention. Every branch is exactly one column wide. `MERINGUE_ASCII_GLYPHS=1` renders `p` / `c` / `a` instead of the marks for fonts that cannot draw them, and `NO_COLOR=1` drops color while keeping glyphs, ids, statuses, and titles.
- **No reflow.** Issue and project rows have no harness of their own, so they reserve the same logo cell. Every id in the tree therefore starts in one column — including a child issue and a worker that are siblings at the same depth — and wrapped title rows hang under the title column.
- **Selected rows.** The highlighted row keeps its logo but hands its foreground to the selection palette, which guarantees contrast on the highlight background in every theme. Its identity color is still visible: it is what the composer is tinted with while that row is selected.

Run `ruby -Ilib -Itest test/integration/tui/agent_tree_identity_test.rb` for automated coverage of agent identity rendering; use `bundle exec meringue demo` when you need a manual visual pass in your own terminal.

## AgentTree scrolling

The AgentTree pane scrolls like any other pane, so a long tree of projects, issues, and agents is never silently clipped.

- Focus the AgentTree (`Tab` / `Ctrl-Tab`, or click it), then arrow keys scroll by a line, `PageUp` / `PageDown` by a page, and `Home` / `End` jump to the first or last row.
- The mouse wheel scrolls the tree whenever the pointer is over the pane, including while jump mode is active and while another pane has focus.
- The pane title shows how much is off screen as `agent tree  ↑<above> ↓<below>`; the counts disappear once the whole tree fits, so a clipped tree cannot be mistaken for missing data.
- Offsets are clamped to real content, and are re-clamped when the terminal is resized or when the tree shrinks (issues or workers completing, `/prune`, kills), so scrolling past either end never builds up a dead offset.
- Selecting an item scrolls the minimum amount needed to bring it on screen. This covers jump-mode arrow navigation, clicking a row, opening or closing a focused workspace, and the sticky selection that filters the logs pane (including a selected project, where jump mode is not active), and it uses the same reveal approach as the logs selection cursor. Scrolling by hand is not overridden while the selection stays the same.

## AgentTree selection, log filtering, and chat routing

A single left click on any AgentTree row selects that node. Clicking a worker id, title, or authored message in the logs pane selects the same worker without moving focus or resetting the logs viewport. Exactly one node is selected at a time, and while a node is selected the logs pane shows only that node's logs. Right-clicking an issue row opens its associated delivery PR through the configured browser opener; worker rows do not duplicate that affordance, and an issue without a PR gets a transient notice. Double-clicking an issue opens its PR; double-clicking a worker opens its focused workspace only when that workspace exists. An issue or worker selection is also an explicit target for subsequent natural-language chat. Head rows are log-only filters; a head that stopped without routing its whole request (`errored`, `killed`, or `blocked` with commands the kernel rejected or failed) carries a visible `retry me` marker and can be retried explicitly with `/retry H<n>` or by double-clicking that row. Once retried, the old head is removed from the active tree and lineage stays in logs/metadata. Select a head and press `a` to open its saved harness session for debugging, or use `/open-session <agent_id>` for any saved head or worker session; neither action makes a head a chat target.

What each node type scopes, mirroring the AgentTree hierarchy:

| selected row | logs shown |
| --- | --- |
| worker (`P1-I9-W3`) | that worker's own logs |
| head (`H2`) | that head's logs, including the user prompt it routed. Heads are top-level rows, so their logs never appear under a project or issue. |
| issue (`P1-I9`) | the issue plus every worker attached to it and to its child issues |
| project (`P1`) | that project and its whole subtree of issues and workers |

Membership comes from each log record's `source_type`/`source_id` plus the routing ids the kernel already stores in `details` (`project_id`, `issue_id`, `agent_id`, `head_id`, and cascading id lists such as killed/removed ids). Log entries with no attributable node — for example transient status lines — are hidden while a filter is active. A selected user prompt records the resolved issue id and, for a worker selection, the selected worker id, so the prompt remains visible in that focused log view.

Chat routing uses the same selection without turning the dashboard into a direct worker terminal:

- Selecting `P1-I9` sends its id with the next natural-language `SpawnHead`; the kernel resolves and supplies `P1-I9` as `routing_context.selected_target.issue_id`.
- Selecting `P1-I9-W3` sends the worker id. The kernel resolves it to owning issue `P1-I9`, includes the selected worker as a context hint, and rejects a stale selection instead of silently routing elsewhere.
- Selecting a head filters its logs only. A stopped head is retried explicitly with `/retry H13` (or by double-clicking its `retry me` row), which starts a fresh head carrying the unrouted request and applied-command journal forward. Typing a new message while a head row is selected remains unscoped. See [Retrying a failed head](head_agent_kernel_commands.md#retrying-a-failed-head).
- The fresh head still chooses `PromptAgent` mode (`normal`, `steer`, or `follow_up`), a healthy worker on that issue, a follow-up/replacement, or a clarification. Selection never emits `PromptAgent` directly.
- Slash commands bypass the head as usual and do not inherit selection: `/prune`, `/help`, `/kill`, and the local navigation commands submit identically whether or not a row is selected, and they leave the selection in place. The focused worker workspace also retains its explicit direct-prompt behavior; this section applies to dashboard natural-language chat.
- Selecting a project or head filters logs only. Chat keeps its unscoped routing rather than sending a half-populated target, and clearing the selection restores unscoped routing.

### The composer shows its target by color

The chat box itself changes to match the row it will prompt, so a stale selection cannot be missed while typing.

The destination is named in exactly one place: the composer's pane title, on the border row directly above the chat bar. The hint line below the chat bar never repeats it. It gives a selected target only the useful `Esc clears` action, leaving changing status and delivery information room on narrow terminals.

| state | composer title (above the chat bar) | border / title / `›` | hint line (below the chat bar) |
| --- | --- | --- | --- |
| worker (`P1-I9-W3`) | `chat → P1-I9-W3 · <issue title>` | tinted with that agent's own log color | `Esc clears` |
| issue (`P1-I9`) | `chat → P1-I9 · <issue title>` | tinted with that issue id's color | `Esc clears` |
| failed head (`H13`) | `chat · H13 logs only` | theme default, never tinted | `Esc clears` |
| project or still-routing head (log-only) | `chat · P1 logs only` | theme default, never tinted | `Esc clears` |
| nothing selected | `chat` | theme default, never tinted | nothing — no target to explain, nothing to clear |
| buffer starts with `/` | `chat · slash command · P1-I9-W3 not targeted` | theme default, never tinted | `slash ignores target · Esc clears` |

- A worker id already contains its issue id (`P1-I9-W3` → `P1-I9`), so the title does not repeat it. An agent whose id does not encode its issue (a head bound to one) reads `chat → H12 → P1-I9 · <issue title>` instead, so the resolved issue is still named.
- A slash command with nothing selected also contributes nothing to the hint line; the title already reads `chat · slash command`.

- The tint is the *same* per-id color the logs pane and the AgentTree already give that agent (the active colorscheme's identity palette, `AGENT_PALETTE` in `lib/meringue/tui/style.rb`; see [AgentTree agent colors and harness logos](#agenttree-agent-colors-and-harness-logos)), so a tinted composer visibly belongs to the tree row, the log rows, and the `▌` gutter of the node it prompts. Issue ids hash through the same function, so an issue selection gets a stable color too, and an issue and a worker under it are never the same color.
- Only the composer chrome is tinted: the border, the pane title, and the `›` prompt marker. Typed text, the placeholder, and text selection keep their normal semantic styles, so input contrast does not depend on which palette slot the target hashed into. This holds in all shipped colorschemes (`catppuccin`, `gruvbox`, `kanagawa`, `meringue`, `rose-pine`, `tokyonight`).
- A focused composer stays distinguishable from an unfocused one by using the bold weight of the same hue instead of switching back to the focus border color.
- Color is never the only cue. The title always names the destination, the hint line only explains how to clear a selection, and an empty targeted composer's placeholder reads `message P1-I9-W3`. With `NO_COLOR=1`, a 16-color terminal, or a screenshot, the text still says exactly where the prompt is going.
- Typing a slash command removes the tint immediately, because slash commands never inherit the selection. The selection itself is untouched: delete the `/` and the tint (and the routing target) come back.
- A selection the kernel or reconciliation drops (pruned, killed, renumbered) also drops the tint, so a colored composer always refers to a node that still exists.

### What the bottom hint line shows

The single row under the chat bar is shared, left to right, and truncated at the terminal width, so every group has to earn its columns. In order:

1. **Selection actions**: `Esc clears` for a selected target, or `slash ignores target · Esc clears` while a slash command bypasses the selection. Never the target id, which the composer title above already names.
2. **Text-selection state** when a selection or the logs cursor is active (`⧉ selection  Ctrl-C copies`, `⧉ copied 3 lines`, or the `Alt-V` hint while the logs pane is focused).
3. **Work in flight**: `● 2W 1H` (working workers and heads) or `2 prompts running`. There is no `active` label; the lit dot and the counts say it.
4. **Open questions**: `? 2`.
5. **Delivery PRs**, which depend on what the dashboard is looking at:

| dashboard state | hint | `Ctrl-B` |
| --- | --- | --- |
| a worker/issue is selected, or jump mode is on a row, and it has a verified PR | `PR #145 open` (`· stale` or `status unavailable` when the last refresh could not confirm it) | opens that PR |
| that node has no verified PR yet | `no PR yet` | reports why it cannot open one |
| that node's tracked PR metadata is not a usable GitHub URL | `PR link unusable` | reports the same |
| nothing is selected and the tree has open PRs | `3 open PRs` | opens the open-PR picker; double-clicking the count does too |
| nothing is selected and every tracked PR is merged/closed | `no open PRs` | says nothing is open |
| nothing is selected and no PR has ever been tracked | *(silent)* | says nothing is tracked yet |

6. **Idle discovery**: `Ctrl-C clear/quit · Tab focus · / commands`, shown only when no selection, text-selection state, activity, questions, PR summary, or slash popup needs the row.

Delivery PR records are owned by issues, so an issue selection shows the newest PR that is still live, falling back to the newest settled one so a finished issue still says what it delivered. A worker selection resolves to that owning issue for the same action and never gets a second worker-owned marker or record. Every one of these facts comes from state the kernel already persisted (`delivery_pull_requests` on the issue); rendering never runs `gh`.

The open-PR picker opens in the same popup slot as the slash-command list, above the composer, and lists every PR that is not merged or closed, newest number first: `#145  Fix signup validation  P1-I9 · open`. Open it with `/prs` from any dashboard selection, with `Ctrl-B` while chat is unscoped, or by double-clicking the unscoped `1 open PR` / `N open PRs` summary. Only the count is clickable: a single click and neighboring summary controls keep their existing behavior, and `no open PRs` or a tree that has never tracked one stays inert. A PR the kernel has not verified yet is listed as `unverified` rather than hidden. Rows are named by their issue title, because delivery records do not carry a PR title of their own.

The selection is sticky and independent of focus:

- The selected row stays highlighted while the logs pane, the chat pane, or the composer is focused, so the filter is always visible. When the selection changes it is scrolled back into view by the minimum amount, exactly like a jump-mode selection.
- Scrolling the AgentTree (arrows, page keys, `Home` / `End`, or the mouse wheel) never changes or clears the selection, and the offset you chose by hand is not yanked back while the selection stays the same.
- The logs pane title becomes `logs — <id>` (for example `logs — P1-I9-W3`). The composer title, its tint, and the hint line's clear gesture follow the same selection; see [The composer shows its target by color](#the-composer-shows-its-target-by-color).
- A filtered pane with nothing to show says so and repeats how to change or clear the filter, so it never looks broken.
- Double-clicking a pending head or an issue without a worker does not open a focused workspace and does not add or persist repetitive `has no agent session to open yet` messages. Explicit unavailable actions may use a short-lived hint; unexpected workspace/launcher failures remain visible errors.

Clearing or retargeting:

- Click a different row: the selection and the filter move to that row.
- Click the highlighted row again, or click empty space inside the AgentTree: deselect and show all logs again.
- `Esc`: clear the selection (and jump mode). A text selection or logs cursor is cleared first, so a second `Esc` clears the filter.
- Clicking the logs pane, the chat pane, or scrolling never clears the selection. That is the point of the feature.
- Projects are selectable rows but not jump targets, so selecting a project also leaves jump mode; it filters logs but does not target chat.
- A head without `issue_id` can be selected for its logs, but does not target chat. If a selected node cannot be resolved when the message reaches the kernel, head spawn is rejected rather than silently losing the scope.
- If the selected node disappears (pruned, killed, or renumbered), the filter clears itself instead of hiding every log line.

The filter follows explicit selection actions only: a click, or moving the jump-mode cursor with `agent_select_previous` / `agent_select_next`. Entering jump mode does not retarget the filter by itself; it starts on the already-selected node when that node is a jump target. Scrolling, focus changes, and typing never change it.

This selection is separate from text selection: it decides which log entries are rendered, not which characters are highlighted, so `Ctrl-C` copy, the logs selection cursor, and composer selection keep working unchanged while a filter is active.

## Text selection and clipboard

Selection is rendered by Meringue itself, so it works without holding `Shift` and without switching the host terminal into its own selection mode. A selection is always scoped to the pane the drag started in: a drag that leaves the logs pane clamps to the logs text area instead of highlighting the AgentTree or the composer.

- Double-click a word in the logs pane: select and highlight that word, and copy it to the system clipboard. The bottom hint line echoes what was copied, for example `⧉ copied "P1-I18-W2"`.
- Triple-click a logs paragraph: select and highlight the complete paragraph under the pointer, including every soft-wrapped row but not an adjacent paragraph or log entry, and copy it to the system clipboard.
- Drag with the left mouse button in the logs pane: select log text. The highlight uses the active colorscheme's `SELECTION` style and follows the content while you scroll. Releasing the button copies the highlighted text.
- Double-click, then drag without releasing: extend the selection by whole words in either direction, including onto other (soft-wrapped) rows. Triple-click, then drag extends by complete paragraphs.
- Double-click a word in the chat composer: select that word. Drag from a double-click to extend by word there too. The composer stays copy-on-demand (`Ctrl-C` / `Ctrl-X`), so selecting text you are about to retype never overwrites your clipboard.
- Drag with the left mouse button in the chat composer: select input text. Clicking without dragging just moves the cursor.
- `Ctrl-C` / `Alt-C`: copy the selection to the system clipboard. While a selection is active, `Ctrl-C` copies instead of clearing the input or quitting.
- `Esc`, or a single click anywhere else: clear the selection.

Word boundaries are tuned for what actually shows up in logs: agent ids (`P1-I18-W2`), file references (`lib/meringue/tui/app.rb:643`), and URLs (`https://example.com/pull/12?tab=files`) select whole, while trailing prose punctuation does not (double-clicking `done.` selects `done`, `yes,` selects `yes`). Punctuation runs and brackets are their own selection, and double-clicking blank space selects nothing instead of copying whitespace. Multi-click detection needs each successive press on the same row within half a second; a slower or further-away click starts a normal caret/drag selection instead. The composer retains its existing single/double-click cycle and does not add paragraph selection.

A word lives on one wrapped row: log text wraps at whitespace, so only a single token longer than the pane is split, and a word drag then covers each row it crosses.
- `Shift-Left` / `Shift-Right` / `Shift-Up` / `Shift-Down`: extend the composer selection by character or line.
- `Shift-Home` / `Shift-End`: extend the composer selection to the start or end of the current line.
- `Shift-Alt-Left` / `Shift-Ctrl-Left` and `Shift-Alt-Right` / `Shift-Ctrl-Right`: extend the composer selection by word.
- `Ctrl-X`: cut the composer selection to the clipboard.
- `Ctrl-V`: paste the system clipboard into the composer, replacing any selection. Your terminal's own paste (`Cmd-V` / `Ctrl-Shift-V`) still works through bracketed paste.
- Typing, `Backspace`, or `Delete` with an active composer selection replaces or deletes the selected text.

Copy uses a local clipboard command when one is available (`pbcopy` on macOS, then `wl-copy`, `xclip`, or `xsel` on Linux) and falls back to the OSC 52 terminal escape so remote sessions can still reach the local clipboard. Paste reads `pbpaste`, `wl-paste`, `xclip`, or `xsel`. The bottom hint line confirms a copy or reports `clipboard unavailable`.

Logs copy authored/rendered content rather than pane chrome. The colored `▌ ` beside agent body rows and the equivalent plain body indent remain visible and selectable on screen, but they are omitted from mouse-release, double-/triple-click, and keyboard-caret clipboard text. Bullets, inline-code backticks, block markers, commands, paragraph gaps, and selected line breaks remain intact. This is segment metadata, not a glyph-based cleanup rule, so an authored `▌` inside log content is still copied.

Paste is composer-only; the logs pane is copy-only.

### Large pastes collapse to a placeholder

A paste over 10 lines or 1000 characters does not enter the composer as text. It is parked in memory and the composer shows a single placeholder chunk instead, the same shape Pi uses:

```txt
› [paste #1 +3000 lines] please review this
```

A paste that is long but on one line reports characters instead (`[paste #2 4110 chars]`). Smaller pastes are still inserted inline and unchanged.

- The placeholder behaves as one unit: `Left`/`Right`, word motion, and selection step over it, and `Backspace`/`Delete` remove the whole chunk (which also forgets its content).
- Submitting expands every placeholder back to the exact pasted text, so the head or worker receives the full body. Several large pastes in one message each get their own number and all round-trip.
- Copying a selection that covers a placeholder copies the pasted content, not the placeholder text.
- `Ctrl-C` (clear input) drops the stored pastes with the text it clears, and a draft restored from a previous session drops placeholders it can no longer expand.

This is a responsiveness feature, not only a display one: wrapping, cursor math, slash completion, composer height, and frame diffing all run over the ~22-character placeholder, so a 3000-line paste no longer makes every keystroke re-wrap a quarter megabyte of text.

### Using your terminal's own selection instead

Meringue asks the terminal for mouse reports (`1000`/`1002`/`1006`), which is what makes in-app double-/triple-click selection, drag highlighting, click-to-focus, AgentTree clicks, and hover scrolling possible. While that is on, a plain drag no longer reaches the terminal's own selection, so terminals provide a modifier to bypass mouse reporting when you want their native selection (for example to select across panes or into the borders):

| terminal | hold while dragging |
| --- | --- |
| iTerm2 | `Option` |
| macOS Terminal.app | `Fn` |
| xterm, kitty, Alacritty, WezTerm, GNOME Terminal / VTE, Windows Terminal | `Shift` |

Those terminals handle the modified drag locally and never forward it, so Meringue's own selection stays out of the way. If your terminal does forward it instead, Meringue treats it as a normal drag and still highlights the text, so the gesture is never dead.

## Keyboard selection in the logs pane

The logs pane has a keyboard-driven selection cursor, so log text can be selected and copied without a mouse. It is pane-scoped: it only reacts while the logs pane is focused, it never extends into the AgentTree or the composer, and it does not take keys away from jump mode, slash suggestions, or typing.

Focus the logs pane first (`Tab` / `Ctrl-Tab` until the logs outline is active), then:

- `Alt-V`: toggle the logs selection cursor. The cursor is one cell drawn with the colorscheme's `SELECTION` colors plus bold/underline, so it stays visible inside a highlight and on blank lines. Any `Shift`+movement below also turns the cursor on, so `Alt-V` is optional.
- Arrow keys: move the cursor by character and line while the cursor is on. Moving without `Shift` collapses the selection, exactly like a text editor caret. Vertical movement keeps the column you last chose, and the pane scrolls automatically to keep the cursor visible.
- `Home` / `Ctrl-A` and `End` / `Ctrl-E`: move the cursor to the start or end of the current log line.
- `Alt-Left` / `Ctrl-Left` and `Alt-Right` / `Ctrl-Right`: move the cursor by word, continuing onto the previous/next line at the line edges.
- `PageUp` / `PageDown`: move the cursor a screenful at a time.
- `Shift-Left` / `Shift-Right` / `Shift-Up` / `Shift-Down`, `Shift-Home` / `Shift-End`, `Shift-Alt-Left` / `Shift-Ctrl-Left`, `Shift-Alt-Right` / `Shift-Ctrl-Right`, and `Shift-PageUp` / `Shift-PageDown`: extend the selection from the anchor. The highlight is the same `SELECTION` style mouse drags use.
- `Ctrl-C` / `Alt-C`: copy the selection to the system clipboard. With the cursor on but nothing extended, this copies the whole cursor line. `Ctrl-C` never quits while the logs cursor is on.
- `Esc`: clear the selection and turn the cursor off, which returns arrow keys and `PageUp` / `PageDown` to scrolling the logs pane.

Selection points are stored in logs content coordinates, so a highlight keeps covering the same text while the pane scrolls or new log entries arrive. Moving focus off the logs pane (or entering jump mode) turns the cursor off, and typing a printable character sends it to the composer and clears the highlight.

On macOS terminals, `Alt-V` requires Option to be sent as Meta (Terminal.app: "Use Option as Meta key"). If your terminal does not send Meta, start the selection with any `Shift`+movement key instead, or rebind `logs_selection_mode` under `[tui.keybindings]`.

## Chat input

- `Enter`: send the prompt as typed, or apply the slash suggestion once one is selected. When the composer is tinted, the message is routed by a fresh head with the titled target as `routing_context.selected_target`; see [AgentTree selection, log filtering, and chat routing](#agenttree-selection-log-filtering-and-chat-routing).
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

- Type `/` to show command suggestions. Nothing is selected until you navigate the list, so `Enter` still sends what you typed.
- `Up` / `Down`: select a suggestion; `Down` starts at the first entry and `Up` starts at the last.
- `Enter`: insert the selected suggestion into the input. Press `Enter` again to run it.
- `Tab`: complete the selected suggestion, or the first one when nothing is selected.
- Commands that take a record id (`/kill`, `/prompt`, `/jump`, `/issue rename`, and friends) suggest matching ids **shortest first**: an id is offered before the ids nested under it. Typing `/kill p3` lists `P3`, then `P3-I10`, then `P3-I10-W1`, and typing `/kill i10` lists `P3-I10` above `P3-I10-W1`, so killing an issue never means arrowing past its own workers. Same depth sorts numerically (`P3-I2` before `P3-I10`), an exactly typed id stays on top, and with nothing typed after the command each list keeps its own order (`/prompt ` offers live workers before the failed heads it can retry).
- The box shows a window of three entries and holds **commands only**. When the list is longer than the window, a dim caption renders on its own line *below* the box: `1–3 of 27 commands  ·  ↑↓ scroll · keep typing to filter`. It is a caption about the list, not a row in it, so the window never loses an entry to it; a list that fits the window has no caption at all. The same slot and the same caption placement are used by the `/prs` / unscoped-`Ctrl-B` open-PR picker (`2 open PRs  ·  ↑↓ move · Enter opens · Esc closes`) and by the `/models` model picker. The focused-workspace `workspace commands` list is unwindowed and has no caption.

## First-run setup

The first interactive launch opens Setup as a curated mode of the full-screen
Settings overlay, and `/setup` reopens it any time.

- `↑` / `↓`: move through rows.
- `←` / `→`: change a selector/cached model; on rows without choices, change steps.
- `Space`: toggle a checkbox.
- `Enter`: edit/change a value, begin from Welcome, return from Review to a value, or Finish.
- `Tab` / `Shift-Tab`: next/back through Welcome, Theme, Head defaults, Worker defaults, Experiments, and Review.
- `Ctrl-S`: jump to Review; on Review, Finish.
- First-run `Esc`: open a skip confirmation. Confirming discards the draft and saves only the skipped marker plus explicit experiment defaults.
- Manual `/setup` `Esc`: cancel a clean draft, or open the ordinary discard confirmation for a dirty draft. It never changes the existing marker.

Setup owns the whole screen and the mouse. Left-click selects a visible step or
row, toggles a checkbox, or presses Next/Finish/Cancel on wide terminals. The
wheel moves the visible list. Empty space, chrome, right-click, release, and drag
reports are inert and never reach the dashboard underneath.

See [`onboarding.md`](onboarding.md) for transactional persistence, resize and
failure recovery, first-run versus rerun behavior, and the completion marker.

## Model picker

Open it with `/models` (optionally `/models claude` to scope it to another harness). It is a modal list in the same popup slot as the slash-command suggestions, but it is browsed rather than glanced at, so it shows up to ten rows and captions them with `1–10 of 122 models  ·  type to filter · ↑↓ move · Enter sets the default · Ctrl-R refreshes · Esc closes`.

- Any printable character: filter the list. Space separated tokens all have to match, so `openai high` narrows by provider and thinking level at once.
- `Backspace`: delete one character of the filter. `Ctrl-W`: clear the filter.
- `↑` / `↓`: move the highlight; it wraps. The mouse wheel scrolls it and clicking a row picks that row.
- `Enter`: apply the highlighted model as the future-session default. This is exactly `/model <provider>/<model-id>`, so the kernel validates, journals, and logs it the same way.
- `Ctrl-R`: re-fetch the catalog through the kernel (`/models refresh`) without closing the picker.
- `Esc`, a click outside the list, or any unhandled control key: close it without changing anything.
- The list is never blank: an unavailable catalog, an unsupported harness, a snapshot that has never been fetched, and a filter that matched nothing each render their own explanation and say what to do next.

## Jump mode

Start jump mode with `/jump` or by focusing the agent tree or logs pane and pressing `Enter`.

- `Up` / `Down` / `Left` / `Right`: select an issue or agent, which also retargets the logs pane filter to the newly selected node and auto-scrolls the AgentTree by the minimum amount needed to keep the selected row visible. In the logs pane, only agent titles are selectable; non-agent events are skipped.
- `PageUp` / `PageDown`, `Home` / `End`, and the mouse wheel: scroll the focused pane while a selection is active, since jump mode owns the arrow keys.
- `Ctrl-B`: open the selected issue's verified delivery pull request (a worker selection resolves to its owning issue; jump mode always has a row selected, so it never opens the picker). The PR remains easy to open when status refresh is temporarily unavailable.
- `Enter`: open the selected issue's pull request when a PR is available; a worker row is routed to its owning issue.
- `a`: open the selected worker's focused workspace. Selecting an issue opens its newest non-killed worker; selecting a head opens that head's saved harness session externally for debugging and keeps the dashboard open. A missing, malformed, or otherwise unavailable head session produces only a short-lived notice and never crashes or changes the saved agent record.
- `Esc`: cancel jump mode and clear the AgentTree selection, including its logs filter.

## Focused worker workspace

The workspace is an optional, issue-specific deep-interaction tool—not a replacement for Meringue's normal head-agent chat. Open it when a worker needs sustained direction, iterative discussion, research, investigation, or closer visibility into responses and tool calls. Keep using the dashboard chat for new goals and routine orchestration through head agents.

For Pi workers, Agent session replaces only the logs pane with Pi's interactive terminal. The AgentTree, external dashboard chat, status line, and bottom hint remain visible and live, so you can monitor other workers, change the selected log/chat target, route new work through a head, and use dashboard mouse actions without leaving Pi. Its top border keeps the leader visible and exposes clickable terminal, editor, and dashboard controls (compacted to their key labels when space is tight); an unfinished leader sequence expires instead of leaving the pane armed. Click the Pi pane or move focus to logs with `Tab` to send keys to Pi; click or tab to chat/tree to use those panes without leaking their keys into the terminal. `Ctrl-C`, `Esc`, Pi slash commands, and other ordinary keys reach Pi only while its pane has keyboard focus, while the wheel follows the hovered Pi pane and is translated to its local PTY coordinates. The PTY tracks pane resizes.

When Agent session is requested during a managed prompt or tool call, Meringue uses Pi's abort boundary and waits for the turn to settle before stopping the RPC writer; Agent session then becomes the sole owner of the same session and worktree with a continuation handoff. Repeated opens cannot create a second owner, and launch failure restores the managed session and the previous logs view. If you leave before that continuation produces a final result, dashboard ownership is restored and the continuation starts automatically, so strict reconciliation does not mistake the intentional pending-tool handoff for a failed worker. During the brief ownership handoff, the same embedded dashboard layout stays visible and the Pi pane reports its preparation state.

Harnesses without Agent session continue to use the full focused worker view. Its header keeps the selected worker, status, issue, harness, worktree, and verified delivery PR visible. The worker view renders the complete available active harness transcript—not the compact dashboard completion log—including user and assistant messages, reasoning output, streaming updates, tool calls/results, errors, retries/compaction notices, and relevant turn/session lifecycle events. Normal output, final output, reasoning, tool calls, and tool results use distinct semantic colors in every TUI colorscheme.

Focused commands use a leader sequence so normal terminal control bindings are not stolen. The default leader is `Ctrl-Space`:

- `Ctrl-Space`, then `T`: switch between the terminal and agent view.
- `Ctrl-Space`, then `F`: cycle transcript filters through `all`, `output`, `final`, `reasoning`, and `tools`.
- `Ctrl-Space`, then `A`: open the worker's underlying agent session with Meringue's existing external session launcher. Missing, malformed, or otherwise unavailable sessions are reported in place.
- `Ctrl-Space`, then `B`: launch the configured external editor in the worker worktree.
- `Ctrl-Space`, then `P`: open the verified delivery pull request when one exists.
- `Ctrl-Space`, then `Q`: close native Pi or quit either focused subview, restoring the normal logs pane without stopping the worker or its workspace terminal. If you invoke it while another dashboard pane has focus during native Pi, Meringue still closes the focused session safely.

The composer is titled `chat`, and the helper line under it is exactly this leader line and nothing else:

```txt
Ctrl-Space  T terminal/agent · F filter: all · A agent session · B editor · P PR · Q quit
```

The dashboard's bottom bar uses the same styling — accented keys, muted labels, dim dividers — so both bars read as one product. It stays quiet while changing state or a transient selection needs attention; in an otherwise idle dashboard it offers only:

```txt
Ctrl-C clear/quit · Tab focus · / commands
```

Key letters and labels come from the active bindings, so custom bindings render accurately. The `F` entry always shows the active transcript filter, which resets scroll to the newest matching entry, persists across restart for the selected worker, and resets to `all` when another worker is selected.

### Workspace slash commands

The transcript-focused worker composer accepts slash commands scoped to the selected worker. Native Pi does not show that composer: type into the embedded Pi pane for Pi's own commands, or move focus to the still-visible dashboard chat to route external work. In the transcript composer, typing `/` opens a `workspace commands` list above the composer; `Tab` completes, `Up`/`Down` select, and `Enter` applies a highlighted suggestion or runs the typed command. Anything that does not start with `/` is still a direct follow-up prompt.

| command | effect |
| --- | --- |
| `/help` | List the workspace commands. |
| `/terminal` | Switch between the terminal and agent view. |
| `/filter [all\|output\|final\|reasoning\|tools]` | Set the transcript filter, or cycle it when no value is given. |
| `/open-session` | Open the worker's underlying agent session externally. |
| `/editor` | Open the worker worktree in the configured editor. |
| `/pr` | Open the verified delivery pull request. |
| `/cwd` | Show the worker's resolved worktree directory. |
| `/cancel` | Cancel the worker's current turn without ending its session. |
| `/quit` | Return to the AgentTree, keeping the worker and its terminal alive. |

The old argumentless `/session`, plus `/agent`, `/back`, `/pwd`, `/abort`, and a few other obvious aliases resolve to the same actions. Aliases never name a specific harness backend, so nothing here is Pi-specific. Unknown commands, unknown filters, and stray arguments are reported in the workspace instead of being sent to the worker as a prompt. In terminal view there is no composer, so `/` goes to the shell and the leader keys remain the way to switch views.

`Enter` still sends a direct follow-up into the selected worker's existing context through the kernel-owned `PromptAgent` path, `Shift-Enter` still inserts a newline, and `PageUp`/`PageDown` or the mouse wheel still scroll the agent transcript; those are no longer repeated in the hint line. In terminal view the mouse wheel scrolls the terminal viewport while `PageUp`/`PageDown` go to the shell.

The leader and each suffix are configurable as `workspace_leader`, `workspace_switch_view`, `workspace_cycle_filter`, `workspace_open_agent_session` (legacy alias `workspace_open_pi_session`), `workspace_open_editor`, `workspace_open_pull_request`, and `workspace_close`. Leader + `q` is the focused-session return command. `cancel_navigation`/`Esc` remains scoped to dashboard jump mode and never closes a focused workspace; Esc is ignored in worker view and forwarded in terminal and native Pi views. An unknown suffix is passed to the active view rather than silently discarded. In terminal or native Pi view, every key other than the configured leader—including bare `t`, `f`, `a`, `b`, `p`, `q`, `Ctrl-T`, `Ctrl-B`, `PageUp`/`PageDown`, `Esc`, `Ctrl-C`, and `Ctrl-D`—is sent to the PTY when that pane is focused. Dashboard chat/tree input remains owned by the focused dashboard pane. The external agent-session action validates persisted session history and uses the established detached terminal launcher; it does not replace, signal, or transfer ownership of Meringue's managed harness RPC process. The embedded worktree terminal starts in the worker's real worktree directory, preserves child-process ANSI/SGR colors, consumes charset-designation and DCS/APC/PM/SOS escapes (so `sgr0`-style resets never leak a stray `B` into shell output), keeps multi-byte glyphs intact across PTY read boundaries, and redraws on a low-latency terminal cadence as a viewport (no row is spent on an overflow label); background harness transcript snapshots pause while terminal view is active and resume immediately on return. Press `Ctrl-Space`, then `t` to switch back, or `Ctrl-Space`, then `q` to restore the normal dashboard logs while keeping the shell alive. The shell follows terminal resizes and is cleaned up without signaling the managed worker when Meringue exits. Completed or unavailable sessions remain inspectable in worker view, and failures are shown in place without mutating the saved worker record.

Scrolling either focused view reuses the dashboard's frame-diffed rendering: composed lines are cached until the underlying transcript or terminal screen actually changes, offsets are clamped to what the pane can scroll, and the workspace selection is written to the state file on a slow cadence instead of once per scroll step.

Issues with an open pull request are marked `↗` in the AgentTree; worker rows never repeat their issue's marker. An issue driven by a goal loop carries a goal-colored `<iteration>/<budget> <percent complete>` chip beside that PR marker, and no badge glyph of its own; see [Goal loops](goal_loops.md#how-a-goal-reads-in-the-agenttree). Worker selection and focused-workspace view state are restored from the state file after restart; selections for pruned workers are cleared safely.

See [Agent workspace delivery and recovery integration](agent_workspace_integration.md) for persistence, stale PR metadata, and degraded dependency behavior.
