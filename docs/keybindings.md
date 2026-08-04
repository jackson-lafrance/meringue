# TUI Keybindings

Use `/keybind` inside the interactive TUI to show the active keybinding list in the logs pane. Defaults can be customized in `~/.meringue/config.toml` under `[tui.keybindings]`; see `docs/config.md` for the full schema.

## Customizing

Add overrides under `[tui.keybindings]` in your Meringue config. Omitted actions keep defaults.

```toml
[tui.keybindings]
agent_select_previous = ["k", "up", "left"]
agent_select_next = ["j", "down", "right"]
```

## Global

- `Ctrl-B`: open a delivery pull request. While a worker/issue is selected (or jump mode is on a row) it opens that node's own kernel-verified PR. With nothing selected it opens the **open pull requests** picker instead, because unscoped chat is not about one worker; `↑`/`↓` move, `Enter` opens the highlighted PR in the browser, and `Esc`, another `Ctrl-B`, a click outside the list, or any other key closes it. Clicking a row opens that row. If a PR is missing, malformed, or its status cannot be refreshed, Meringue reports that state without closing the dashboard or changing the worker.
- `Ctrl-D`: quit.
- `Ctrl-C`: clear input; quit when input is empty.
- `Esc`: cancel the innermost active thing — a text selection or the logs selection cursor first, then the AgentTree selection (which clears the logs filter) and jump mode.

## Focus and scrolling

- Click a dashboard section: move focus to that section (the active outline follows the focused section). The logs pane includes user-visible prompts, agent output, and important kernel events.
- Click a project, issue, head, or worker row in the AgentTree: select/highlight it and filter the logs pane to it. Right-click an agent row to open its associated delivery PR; if none is tracked, Meringue shows a transient notice and leaves the selection unchanged. Issue and worker selections also target subsequent natural-language chat through a fresh head. See [AgentTree selection, log filtering, and chat routing](#agenttree-selection-log-filtering-and-chat-routing).
- Double-click text in the logs pane: select the word under the pointer (see [Text selection and clipboard](#text-selection-and-clipboard)). Double-click tracking is per pane, so tree clicks and text clicks never pair up.
- Double-click a worker (or an issue with a worker): open its focused workspace. A pending head or issue without a worker is a silent no-op instead of adding an unavailable-session message to chat/log history. This is the primary mouse action; PR opening remains an explicit action.
- `Tab` / `Ctrl-Tab`: move focus forward.
- `Shift-Tab`: move focus backward.
- Arrow keys and `PageUp` / `PageDown`: scroll the focused non-chat pane by a line or a page.
- `Home` / `End`: scroll the focused non-chat pane to its first or last content line. With the logs selection cursor on, `Home` / `End` still move the cursor within its line.
- Mouse wheel: scroll whichever pane the pointer is over, without changing focus. Hovering a pane that cannot scroll (or the composer) falls back to scrolling the focused pane.
- When the agent tree or logs pane is focused, `Enter` enters jump mode. Non-agent log entries are skipped during jump navigation.

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

`ruby scripts/agent_identity_smoke.rb` prints the tree with every status, every harness, and every theme, which is the manual way to check how the colors and glyphs look in your terminal.

## AgentTree scrolling

The AgentTree pane scrolls like any other pane, so a long tree of projects, issues, and agents is never silently clipped.

- Focus the AgentTree (`Tab` / `Ctrl-Tab`, or click it), then arrow keys scroll by a line, `PageUp` / `PageDown` by a page, and `Home` / `End` jump to the first or last row.
- The mouse wheel scrolls the tree whenever the pointer is over the pane, including while jump mode is active and while another pane has focus.
- The pane title shows how much is off screen as `agent tree  ↑<above> ↓<below>`; the counts disappear once the whole tree fits, so a clipped tree cannot be mistaken for missing data.
- Offsets are clamped to real content, and are re-clamped when the terminal is resized or when the tree shrinks (issues or workers completing, `/prune`, kills), so scrolling past either end never builds up a dead offset.
- Selecting an item scrolls the minimum amount needed to bring it on screen. This covers jump-mode arrow navigation, clicking a row, opening or closing a focused workspace, and the sticky selection that filters the logs pane (including a selected project, where jump mode is not active), and it uses the same reveal approach as the logs selection cursor. Scrolling by hand is not overridden while the selection stays the same.

## AgentTree selection, log filtering, and chat routing

A single left click on any AgentTree row selects that node. Exactly one node is selected at a time, and while a node is selected the logs pane shows only that node's logs. Right-clicking an agent row opens its associated delivery PR through the configured browser opener; if no PR is tracked, Meringue shows a transient notice and leaves the selection unchanged. An issue or worker selection is also an explicit target for subsequent natural-language chat; project selections and heads without an owning issue remain log-only filters.

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
- Selecting `P1-I9-W3` sends the worker id. The kernel resolves it to owning issue `P1-I9`, includes the selected worker as a context hint, and rejects a stale/unbound selection instead of silently routing elsewhere.
- The fresh head still chooses `PromptAgent` mode (`normal`, `steer`, or `follow_up`), a healthy worker on that issue, a follow-up/replacement, or a clarification. Selection never emits `PromptAgent` directly.
- Slash commands bypass the head as usual and do not inherit selection: `/prune`, `/help`, `/kill`, and the local navigation commands submit identically whether or not a row is selected, and they leave the selection in place. The focused worker workspace also retains its explicit direct-prompt behavior; this section applies to dashboard natural-language chat.
- Selecting a project, or a head with no owning issue, filters logs only. Chat keeps its unscoped routing rather than sending a half-populated target, and clearing the selection restores unscoped routing.

### The composer shows its target by color

The chat box itself changes to match the row it will prompt, so a stale selection cannot be missed while typing.

The destination is named in exactly one place: the composer's pane title, on the border row directly above the chat bar. The hint line below the chat bar never repeats it and carries gestures only, so the same id is not printed twice one row apart and the delivery-PR indicator and interaction hints keep that width on a narrow terminal.

| state | composer title (above the chat bar) | border / title / `›` | hint line (below the chat bar) |
| --- | --- | --- | --- |
| worker or head with an issue (`P1-I9-W3`) | `chat → P1-I9-W3 · <issue title>` | tinted with that agent's own log color | `head routes · Esc clears` |
| issue (`P1-I9`) | `chat → P1-I9 · <issue title>` | tinted with that issue id's color | `head routes · Esc clears` |
| project or unbound head (log-only) | `chat · head routes · P1 logs only` | theme default, never tinted | `head routes · Esc clears` |
| nothing selected | `chat` | theme default, never tinted | nothing — no target to explain, nothing to clear |
| buffer starts with `/` | `chat · slash command · P1-I9-W3 not targeted` | theme default, never tinted | `slash ignores target · Esc clears` |

- A worker id already contains its issue id (`P1-I9-W3` → `P1-I9`), so the title does not repeat it. An agent whose id does not encode its issue (a head bound to one) reads `chat → H12 → P1-I9 · <issue title>` instead, so the resolved issue is still named.
- A slash command with nothing selected also contributes nothing to the hint line; the title already reads `chat · slash command`.

- The tint is the *same* per-id color the logs pane and the AgentTree already give that agent (the active colorscheme's identity palette, `AGENT_PALETTE` in `lib/meringue/tui/style.rb`; see [AgentTree agent colors and harness logos](#agenttree-agent-colors-and-harness-logos)), so a tinted composer visibly belongs to the tree row, the log rows, and the `▌` gutter of the node it prompts. Issue ids hash through the same function, so an issue selection gets a stable color too, and an issue and a worker under it are never the same color.
- Only the composer chrome is tinted: the border, the pane title, and the `›` prompt marker. Typed text, the placeholder, and text selection keep their normal semantic styles, so input contrast does not depend on which palette slot the target hashed into. This holds in all shipped colorschemes (`catppuccin`, `gruvbox`, `kanagawa`, `meringue`, `rose-pine`, `tokyonight`).
- A focused composer stays distinguishable from an unfocused one by using the bold weight of the same hue instead of switching back to the focus border color.
- Color is never the only cue. The title always names the destination, the hint line always says who routes the message and how to clear the selection, and an empty targeted composer's placeholder reads `message P1-I9-W3`. With `NO_COLOR=1`, a 16-color terminal, or a screenshot, the text still says exactly where the prompt is going.
- Typing a slash command removes the tint immediately, because slash commands never inherit the selection. The selection itself is untouched: delete the `/` and the tint (and the routing target) come back.
- A selection the kernel or reconciliation drops (pruned, killed, renumbered) also drops the tint, so a colored composer always refers to a node that still exists.

### What the bottom hint line shows

The single row under the chat bar is shared, left to right, and truncated at the terminal width, so every group has to earn its columns. In order:

1. **Routing gestures** for the current selection (`head routes · Esc clears`, or `slash ignores target · Esc clears`). Never the target id, which the composer title above already names.
2. **Text-selection state** when a selection or the logs cursor is active (`⧉ selection  Ctrl-C copies`, `⧉ copied 3 lines`, or the `Alt-V` hint while the logs pane is focused).
3. **Work in flight**: `● 2W 1H` (working workers and heads) or `2 prompts running`. There is no `active` label; the lit dot and the counts say it.
4. **Open questions**: `? 2`.
5. **Delivery PRs**, which depend on what the dashboard is looking at:

| dashboard state | hint | `Ctrl-B` |
| --- | --- | --- |
| a worker/issue is selected, or jump mode is on a row, and it has a verified PR | `PR #145 open` (`· stale` or `status unavailable` when the last refresh could not confirm it) | opens that PR |
| that node has no verified PR yet | `no PR yet` | reports why it cannot open one |
| that node's tracked PR metadata is not a usable GitHub URL | `PR link unusable` | reports the same |
| nothing is selected and the tree has open PRs | `3 open PRs` | opens the open-PR picker |
| nothing is selected and every tracked PR is merged/closed | `no open PRs` | says nothing is open |
| nothing is selected and no PR has ever been tracked | *(silent)* | says nothing is tracked yet |

6. **Interaction hints**: `Enter send · Ctrl-C clear/quit · Tab focus · / commands · /keybind keys`.

A selected worker shows the PR for **its own** delivery branch, not merely the first PR ever attached to its issue, so a second worker on an issue no longer displays its predecessor's number. An issue selection shows the newest PR that is still live, falling back to the newest settled one so a finished issue still says what it delivered. Every one of these facts comes from state the kernel already persisted (`delivery_pull_requests` on the issue); rendering never runs `gh`.

The open-PR picker opens in the same popup slot as the slash-command list, above the composer, and lists every PR that is not merged or closed, newest number first: `#145  Fix signup validation  P1-I9 · open`. A PR the kernel has not verified yet is listed as `unverified` rather than hidden. Rows are named by their issue title, because delivery records do not carry a PR title of their own.

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
- Drag with the left mouse button in the logs pane: select log text. The highlight uses the active colorscheme's `SELECTION` style and follows the content while you scroll. Releasing the button copies the highlighted text.
- Double-click, then drag without releasing: extend the selection by whole words in either direction, including onto other (soft-wrapped) rows.
- Double-click a word in the chat composer: select that word. Drag from a double-click to extend by word there too. The composer stays copy-on-demand (`Ctrl-C` / `Ctrl-X`), so selecting text you are about to retype never overwrites your clipboard.
- Drag with the left mouse button in the chat composer: select input text. Clicking without dragging just moves the cursor.
- `Ctrl-C` / `Alt-C`: copy the selection to the system clipboard. While a selection is active, `Ctrl-C` copies instead of clearing the input or quitting.
- `Esc`, or a single click anywhere else: clear the selection.

Word boundaries are tuned for what actually shows up in logs: agent ids (`P1-I18-W2`), file references (`lib/meringue/tui/app.rb:643`), and URLs (`https://example.com/pull/12?tab=files`) select whole, while trailing prose punctuation does not (double-clicking `done.` selects `done`, `yes,` selects `yes`). Punctuation runs and brackets are their own selection, and double-clicking blank space selects nothing instead of copying whitespace. Double-click detection needs the second press on the same row within half a second; a slower or further-away second click starts a normal caret/drag selection instead.

A word lives on one wrapped row: log text wraps at whitespace, so only a single token longer than the pane is split, and a word drag then covers each row it crosses.
- `Shift-Left` / `Shift-Right` / `Shift-Up` / `Shift-Down`: extend the composer selection by character or line.
- `Shift-Home` / `Shift-End`: extend the composer selection to the start or end of the current line.
- `Shift-Alt-Left` / `Shift-Ctrl-Left` and `Shift-Alt-Right` / `Shift-Ctrl-Right`: extend the composer selection by word.
- `Ctrl-X`: cut the composer selection to the clipboard.
- `Ctrl-V`: paste the system clipboard into the composer, replacing any selection. Your terminal's own paste (`Cmd-V` / `Ctrl-Shift-V`) still works through bracketed paste.
- Typing, `Backspace`, or `Delete` with an active composer selection replaces or deletes the selected text.

Copy uses a local clipboard command when one is available (`pbcopy` on macOS, then `wl-copy`, `xclip`, or `xsel` on Linux) and falls back to the OSC 52 terminal escape so remote sessions can still reach the local clipboard. Paste reads `pbpaste`, `wl-paste`, `xclip`, or `xsel`. The bottom hint line confirms a copy or reports `clipboard unavailable`.

Paste is composer-only; the logs pane is copy-only.

### Using your terminal's own selection instead

Meringue asks the terminal for mouse reports (`1000`/`1002`/`1006`), which is what makes in-app double-click, drag highlighting, click-to-focus, AgentTree clicks, and hover scrolling possible. While that is on, a plain drag no longer reaches the terminal's own selection, so terminals provide a modifier to bypass mouse reporting when you want their native selection (for example to select across panes or into the borders):

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
- The box shows a window of three entries and holds **commands only**. When the list is longer than the window, a dim caption renders on its own line *below* the box: `1–3 of 27 commands  ·  ↑↓ scroll · keep typing to filter`. It is a caption about the list, not a row in it, so the window never loses an entry to it; a list that fits the window has no caption at all. The same slot and the same caption placement are used by the `Ctrl-B` open-PR picker (`2 open PRs  ·  ↑↓ move · Enter opens · Esc closes`). The focused-workspace `workspace commands` list is unwindowed and has no caption.

## Jump mode

Start jump mode with `/jump` or by focusing the agent tree or logs pane and pressing `Enter`.

- `Up` / `Down` / `Left` / `Right`: select an issue or agent, which also retargets the logs pane filter to the newly selected node and auto-scrolls the AgentTree by the minimum amount needed to keep the selected row visible. In the logs pane, only agent titles are selectable; non-agent events are skipped.
- `PageUp` / `PageDown`, `Home` / `End`, and the mouse wheel: scroll the focused pane while a selection is active, since jump mode owns the arrow keys.
- `Ctrl-B`: open the selected worker's verified delivery pull request (jump mode always has a row selected, so it never opens the picker). The PR remains easy to open when status refresh is temporarily unavailable.
- `Enter`: open the selected agent's pull request when a PR is available.
- `a`: open the selected worker's focused workspace. Selecting an issue opens its newest non-killed worker; heads without a durable worker context stay on the dashboard.
- `Esc`: cancel jump mode and clear the AgentTree selection, including its logs filter.

## Focused worker workspace

The workspace is an optional, issue-specific deep-interaction tool—not a replacement for Meringue's normal head-agent chat. Open it when a worker needs sustained direction, iterative discussion, research, investigation, or closer visibility into responses and tool calls. Keep using the dashboard chat for new goals and routine orchestration through head agents.

The workspace replaces the dashboard while open, so the live worker and terminal never compete in simultaneous subviews. Its header keeps the selected worker, status, issue, harness, worktree, and verified delivery PR visible. The worker view renders the complete available active harness transcript—not the compact dashboard completion log—including user and assistant messages, reasoning output, streaming updates, tool calls/results, errors, retries/compaction notices, and relevant turn/session lifecycle events. Normal output, final output, reasoning, tool calls, and tool results use distinct semantic colors in every TUI colorscheme.

Focused commands use a leader sequence so normal terminal control bindings are not stolen. The default leader is `Ctrl-Space`:

- `Ctrl-Space`, then `T`: switch between the terminal and agent view.
- `Ctrl-Space`, then `F`: cycle transcript filters through `all`, `output`, `final`, `reasoning`, and `tools`.
- `Ctrl-Space`, then `A`: open the worker's underlying agent session with Meringue's existing external session launcher. Missing, malformed, or otherwise unavailable sessions are reported in place.
- `Ctrl-Space`, then `B`: launch the configured external editor in the worker worktree.
- `Ctrl-Space`, then `P`: open the verified delivery pull request when one exists.
- `Ctrl-Space`, then `Q`: quit either focused subview back to the AgentTree without stopping the worker or its workspace terminal.

The composer is titled `chat`, and the helper line under it is exactly this leader line and nothing else:

```txt
Ctrl-Space  T terminal/agent · F filter: all · A agent session · B editor · P PR · Q quit
```

The dashboard's bottom bar uses the same styling — accented keys, muted labels, dim dividers — so both bars read as one product:

```txt
Enter send · Ctrl-C clear/quit · Tab focus · / commands · /keybind keys
```

Key letters and labels come from the active bindings, so custom bindings render accurately. The `F` entry always shows the active transcript filter, which resets scroll to the newest matching entry, persists across restart for the selected worker, and resets to `all` when another worker is selected.

### Workspace slash commands

The focused composer also accepts slash commands, scoped to the selected worker. Typing `/` opens a `workspace commands` list above the composer; `Tab` completes, `Up`/`Down` select, and `Enter` applies a highlighted suggestion or runs the typed command. Anything that does not start with `/` is still a direct follow-up prompt.

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

The leader and each suffix are configurable as `workspace_leader`, `workspace_switch_view`, `workspace_cycle_filter`, `workspace_open_agent_session` (legacy alias `workspace_open_pi_session`), `workspace_open_editor`, `workspace_open_pull_request`, and `workspace_close`. Leader + `q` is the only focused-workspace return command. `cancel_navigation`/`Esc` remains scoped to dashboard jump mode and never closes a focused workspace; Esc is ignored in worker view and forwarded in terminal view. An unknown suffix is passed to the active view rather than silently discarded. In terminal view, every key other than the configured leader—including bare `t`, `f`, `a`, `b`, `p`, `q`, `Ctrl-T`, `Ctrl-B`, `PageUp`/`PageDown`, `Esc`, `Ctrl-C`, and `Ctrl-D`—is sent to the isolated workspace terminal. The external agent-session action validates persisted session history and uses the established detached terminal launcher; it does not replace, signal, or transfer ownership of Meringue's managed harness RPC process. The embedded worktree terminal starts in the worker's real worktree directory, preserves child-process ANSI/SGR colors, consumes charset-designation and DCS/APC/PM/SOS escapes (so `sgr0`-style resets never leak a stray `B` into shell output), keeps multi-byte glyphs intact across PTY read boundaries, and redraws on a low-latency terminal cadence as a viewport (no row is spent on an overflow label); background harness transcript snapshots pause while terminal view is active and resume immediately on return. Press `Ctrl-Space`, then `t` to switch back, or `Ctrl-Space`, then `q` to return directly to the AgentTree while keeping the shell alive. The shell follows terminal resizes and is cleaned up without signaling the managed worker when Meringue exits. Completed or unavailable sessions remain inspectable in worker view, and failures are shown in place without mutating the saved worker record.

Scrolling either focused view reuses the dashboard's frame-diffed rendering: composed lines are cached until the underlying transcript or terminal screen actually changes, offsets are clamped to what the pane can scroll, and the workspace selection is written to the state file on a slow cadence instead of once per scroll step.

Agents with an open pull request are marked `↗` in the AgentTree. Worker selection and focused-workspace view state are restored from the state file after restart; selections for pruned workers are cleared safely.

See [Agent workspace delivery and recovery integration](agent_workspace_integration.md) for persistence, stale PR metadata, and degraded dependency behavior.
