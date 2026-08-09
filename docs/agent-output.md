# Agent output in the logs pane

## Where the text comes from

Meringue does not paste Pi's interactive terminal UI into the logs pane.

For Pi workers, the path is:

```txt
Pi RPC JSONL stdout
  -> Harness::PiClient::RpcProcess parses structured responses/events
  -> PromptLoop or the reconciler waits for agent_settled
  -> PiClient#get_last_assistant_text returns the last assistant message
  -> Kernel::Engine#mark_worker_completed stores that text in
     agent.harness_metadata.last_assistant_text and the worker completion log details
  -> TUI::Panes::ChatPane normalizes and renders the completion log
```

Streaming token/delta events are deliberately excluded from durable dashboard logs by the kernel. A sentence such as `Now creating the shared timestamp module:` is therefore harness-owned assistant text returned by `get_last_assistant_text`, not text invented by Meringue and not a raw Pi TUI stream. The source text stays unchanged in state; cleanup is display-only.

The optional focused worker workspace has a separate, non-destructive session-view path. It reads the active Pi transcript through `get_entries` (incrementally after the current leaf, with `get_messages` compatibility fallback), polls its own independent event cursor, and renders user/assistant text, reasoning, streaming partial messages, tool calls and results, direct-bash output, errors, queue/retry/compaction notices, and relevant turn/session lifecycle events. Persisted session history provides the same active-branch transcript after restart. Compact durable worker logs are shown only when no session transcript can be recovered, so a completion summary cannot replace or push the real Pi output offscreen.

Focused transcript entries retain semantic categories. Reasoning, tool calls, tool results, normal output, and final assistant output use distinct theme-aware styles on each role/type header, alongside the retained timestamp. Assistant, reasoning, and user bodies use the theme's normal foreground; tool call and tool result bodies are dimmed, and lifecycle bodies dimmer still, so supporting detail reads as background while conversation text stays prominent. Categories can be filtered with the workspace filter command (`Ctrl-Space`, then `F` by default). Filters never discard transcript data: they change only presentation, reset the transcript scroll to the newest matching entry, and remain durable for the selected worker.

Entry bodies are rendered with the same Markdown renderer the dashboard log uses, so fenced code blocks, inline code, lists, headings, and links look identical in both places. Code blocks keep their own framed gutter and preserve leading whitespace.

Tool traffic is rendered as a labelled block instead of an inspected hash: a shell tool shows its command as a shell code block, a file tool shows its content with the language inferred from the path, other tools show `key: value` arguments, and secondary arguments are listed beside the block rather than inside it. Tool payloads are the only place escape sequences are normalized, so an encoded `\n` becomes a real line break there while authored backslashes inside assistant prose are left untouched. Tool results are framed as preformatted output, and a result is only labelled `diff` when its content actually looks like one.

The same message is often visible in assembled history, the live event stream, and a harness message list at once. Each entry records its origin, so identical content observed from two origins collapses to one entry while a genuinely repeated message from a single origin is preserved. Tool traffic prefers assembled history when it is available and falls back to the event stream while a call is still streaming.

Entry bodies are wrapped to the indented body width, so no character is pushed past the pane edge mid-word. Streaming deltas are fragments of a message that is still being assembled: a reasoning delta stays in the reasoning category instead of appearing as assistant output, and any fragment already contained in an assembled entry is dropped rather than rendered as a duplicate tail.

The surrounding transcript chrome is Meringue-owned:

- `[14:30:01] ✦ agent P1-I9-W1 — …` was assembled by `ChatPane#role_line` from the durable log timestamp, source id, and agent title.
- `P1-I9-W1 output:` was assembled by the worker-completion branches in `ChatPane` and `TUI::App`.
- Borders and layout characters can arrive inside assistant text when an agent quotes terminal output, but the outer logs-pane border is drawn separately by `TUI::Layout` and `TUI::Canvas`.

Meringue ingests important harness failures as durable harness logs, but it does not persist every streamed token. This keeps state and scrollback bounded while preserving worker results and actionable errors.

## Compact presentation

Worker results now render as one compact block:

```txt
Before
[14:30:01] ✦ worker P1-I9-W1 — Create shared timestamp module
▌ P1-I9-W1 output:
▌ ╭──────── progress ────────╮
▌ │ Now creating the shared  │
▌ │ timestamp module:        │
▌ ╰──────────────────────────╯

After
[14:30] ✓ P1-I9-W1 · Create shared timestamp module · done
▌ Now creating the shared timestamp module:
```

The header owns the agent id, title, timestamp, and state; the body does not repeat them. `✓ … · done` marks a final worker result, `! … · warn/err` keeps actionable problems visually distinct, and `✦` / `◆` remain progress markers for workers / heads. PR URLs render as compact `PR  <url>` actions.

`TUI::AgentOutput` removes ANSI/control sequences, duplicate rendered headers and `<agent-id> output:` labels, common outer box borders and hard wrapping, trailing whitespace, excess blank lines, and duplicate PR URLs. Cleanup is structure-aware: fenced code keeps its indentation and blank rows, while headings, lists, quotes, and paragraph boundaries survive normalization for the renderer.

## Timestamps and transient UI actions

Durable timestamps are written by several layers: the kernel prefers local ISO8601, while the state layer and harness clients store UTC ISO8601. Rendering never assumes one of those formats. `TUI::Timestamps` parses either form, converts to the user's local timezone for display (`[14:30]`), and produces a numeric sort key so UTC-stored and local-stored entries interleave in true chronological order. Timestamp comparisons such as the `TUI::App` start-time gate go through the same parser, so filtering stays correct across offsets.

Opening a PR or an agent session is transient UI feedback, not orchestration history, so successful opens no longer append a log entry. `TUI::PullRequestOpener` and `Harness::TerminalSessionOpener` return `{"status" => "opened"}` with no user-visible message, while rejected and failed opens keep their explanatory message and are still logged.

## One visible line per lifecycle event

A successful lifecycle event writes one log line, not a progress narration of its internal phases. Spawning a worker is the canonical case: the kernel reserves the record, allocates the workspace, and starts the agent session, and the user sees only `Spawned worker P1-I1-W1 for P1-I1.` (or its follow-up/replacement/queued-activation variant) once the session exists. That line carries the routing details plus the workspace path, strategy, and branch the worker actually received, which a line emitted before allocation could not, since a planned branch may still be uniquified or adopted.

This applies to success only. Phases that fail still speak for themselves: `Worker workspace provisioning failed: …` and `Could not start an agent session for worker …` are logged as errors against the worker. Phase telemetry stays structured on the record (`harness_metadata.provisioning_state`, `workspace_provisioned_at`, `provisioning_errors`) for reconciliation and `GetInfo`, and in-progress work stays visible in the AgentTree as a `queued` worker rather than as chat noise.

Provisioning is the one phase allowed to speak while it is still running, because it can legitimately take minutes on a large repository and silence is indistinguishable from a hang. The AgentTree persists checkout telemetry every 15 seconds, so a queued row changes from `provisioning workspace` to `provisioning workspace 35%` as Git reports its actual checkout progress (or `provisioning workspace checkout 17s` before Git has reported a percentage). The percentage is only Git's worktree checkout percentage; it is not a made-up percentage for the complete workspace-and-harness lifecycle. A periodic `Still provisioning worker …` line is written every minute carrying the elapsed time and git's own progress, while the same structured data lives in `harness_metadata.provisioning_progress`. A provisioning failure that is recoverable is a warning rather than an error and says what happens next (`Retrying automatically (attempt 2 of 2).`); one that has run out of automatic attempts is an error that says what the user can do (`Prompt this worker to retry provisioning, or kill it.`). Cleanup that could not finish safely (a worktree registration that survived, a branch kept because it carries commits) is reported on its own warning line rather than being swallowed.

## Mid-work worker progress

A worker session is not one lifecycle event; it is tens of minutes of work between `Spawned worker P1-I1-W1 for P1-I1.` and the worker's final report. That stretch used to be completely silent in the main log, which made a healthy 40-minute session indistinguishable from a hung one. It now speaks, under tight volume rules.

**Where the lines come from.** Reconciliation already drains each live session's events once per tick and hands them to the kernel. The same array is passed straight back to the harness client as `Harness::Client#session_progress(events)`, a *pure* transform that returns harness-neutral, assistant-authored updates:

```txt
{ "kind" => "assistant_text", "text" => "The root cause is the shared drain cursor." }
```

It is deliberately not a second read. `ProcessClient::ManagedProcess` keeps a single shared drain cursor, so a second `read_events` call for progress would take events away from settle classification and corrupt how a worker is recorded as finishing. Deriving progress therefore costs no extra harness round trip, adds no I/O to the reconcile tick, and runs entirely on the existing background reconciler thread — never on the UI thread.

**What each backend contributes.**

| Harness | Source | Progress |
| --- | --- | --- |
| Pi | raw RPC events (`PiSessionView.progress_items`) | `message_end` carries the complete assistant message, including its text blocks, *before* its tool calls execute. Per-token `message_update` and every `tool_execution_*` event are ignored outright. |
| Claude Code and other `ProcessClient` backends | wrapped stdout records (`SessionProgress.from_process_events`) | assistant records' text blocks only. `tool_use` blocks are ignored, and the terminal `result` record is skipped because the kernel already logs it as the worker's completion output. |
| Antigravity | plain-text `--print` stdout | no JSON records, so no progress. |
| Fake, and any client that does not override the contract | — | `[]`. |

The default on `Harness::Client` is `[]`, so a backend that cannot describe its own activity simply stays quiet; nothing else about it degrades. A client that raises is caught and treated the same way, because progress must never be able to break a reconcile pass.

**What reaches the log, and how little of it.** At most one progress line per worker per poll, and it must be complete assistant-authored text. The worker system prompt asks for brief updates only when there is a meaningful finding, decision, or implementation milestone. Raw tool events are deliberately excluded: they prove that a process invoked something, but tool names and call counts cannot truthfully say what the agent learned or accomplished. If no authored semantic update is available, Meringue emits no progress line instead of fabricating one. On top of that:

- the *first* authored line a worker produces is never delayed;
- authored text is then floored at one line per **2 minutes** per worker (at most 30/hour);
- consecutive identical text is dropped outright, so a repeated sentence never spends a slot;
- each update is normalized to one readable line, but its authored content is retained; the logs pane wraps the complete line to the available width.

The time floor exists because the retained log window is bounded at 500 entries (see [`log-retention.md`](log-retention.md)). Without it, three concurrent narrating workers would evict every kernel and user line within the hour. The content is not shortened for the dashboard: the complete authored update is retained and the logs pane wraps it to the available width. Harness/state safety limits still apply at their own boundaries.

**Persistence and lifecycle.** Progress lines are ordinary durable log entries: `source_type: "worker"`, `source_id` the worker id, `level: "info"`, and `details.kind == "worker_progress"` (plus `progress_kind`, `issue_id`, and `project_id`). They are attributed to the worker exactly like its completion line, so the logs pane renders them with the worker's own colour and the `✦` progress marker, the AgentTree log scope filters them with the rest of that worker's history, and `details.kind` makes them identifiable for any future filter. They age out through the normal 500-entry window; `/prune` does not remove log entries at all, and `/recount` rewrites their `source_id` and `details` ids through the same reference walk it applies to every other record.

The newest observation is also kept on the worker record at `harness_metadata.progress` (`text`, `kind`, `observed_at`, plus the `logged_text`/`logged_at`/`logged_count` throttle marker). That field is a fixed size rather than a growing history, it is what makes the rate limit survive a restart or a second Meringue instance, and it means `GetInfo` and raw state can show current activity even while the log line itself is throttled.

Heads are excluded: they are short-lived routers that already log their own summary, so narrating them would be pure noise. Settled polls are excluded too, because a settled turn is about to log its real result. The worker prompt requests semantic milestones, but the log still contains only text the agent actually emitted through the harness event stream.

## Harness-neutral log copy

User-visible log lines, status strings, and notices describe the coding agent, never the harness backend that runs it. The kernel logs `Started agent session for head H68.`, `Resumed agent session for worker P1-I9-W3 and prompted it to continue.`, and `Could not start an agent session for worker P1-I9-W3: …` rather than naming Pi, Claude, or Antigravity. `agent session` is the standing vocabulary for the human-readable session noun; `harness` stays in structured data (the `harness` field, log `details`, config keys such as `[harness.pi]`, and the `/harness` selection command, where naming the backend is deliberate).

## Terminal Markdown

Conversational `head` and `worker` entries are passed to `TUI::Markdown`, a dependency-free renderer that emits styled Canvas segments rather than terminal escape sequences. It handles the structures agents use most often:

- headings have emphasized text while retaining their `#` level marker;
- unordered, ordered, and task lists use stable bullets, numbers, and checkbox glyphs with aligned wrapped continuations;
- blockquotes use a `│` marker;
- emphasis uses bold/italic terminal attributes;
- inline code retains visible backticks;
- fenced and indented code use a labeled `┌─ code` / `│` / `└─` frame and preserve code whitespace;
- links become an underlined label followed by the visible target, so the URL remains useful without terminal hyperlink support.

Markdown soft line breaks are reflowed to the current pane width. Every wrapped continuation accounts for the agent gutter and block marker, including narrow panes and long unbroken tokens. Kernel, command, warning, and error bodies stay on the plain semantic log path rather than being interpreted as conversational Markdown.

Before parsing, the renderer normalizes invalid UTF-8 and strips CSI, OSC, other escape sequences, and control characters. Styles are supplied separately to `Canvas`; untrusted agent text is never treated as ANSI. `Canvas` performs a final control-character sanitization and clips every segment to its pane.

Agent identity colors remain deterministic per id and active theme. Markdown headings and structural markers reuse the same agent palette entry as the header and `▌` gutter. The explicit agent id, head/worker/result icon, Markdown markers, status text, and gutter remain present when `NO_COLOR` is set, so identity and document structure do not depend on color alone.

Two other surfaces reuse that same identity assignment, so one agent is one color everywhere:

- **The AgentTree.** Each agent row draws its harness logo and its id in the agent's palette entry, in every lifecycle status, including completed rows. Status keeps its own semantic glyph color and completed titles stay muted, so color is additive. See [`docs/keybindings.md`](keybindings.md#agenttree-agent-colors-and-harness-logos).
- **The chat composer.** While an AgentTree issue/agent is selected, the composer border, pane title, and `›` prompt marker take the selected node's palette entry, so the box you type into matches the tree row and log rows it will prompt. Typed input keeps its normal text style, and the composer pane title still names the target in plain text (the hint line below the chat bar carries gestures only, never the id). See [`docs/keybindings.md`](keybindings.md#the-composer-shows-its-target-by-color).

Both cues survive `NO_COLOR` and limited color support: ids, harness glyphs, status glyphs, and the composer title text carry the same information without color.

## Manual regression fixture

`fixtures/demo_state.json` includes a completed worker whose stored assistant text contains ANSI styling, a duplicate Meringue header, an `output:` label, a titled box, and representative headings, emphasis, lists, a blockquote, inline code, a fenced code block, and a link. `bin/meringue demo` must show normalized, wrapped terminal Markdown without the transcript artifacts. The fixture exercises the same durable-log rendering path used for real completed workers.
