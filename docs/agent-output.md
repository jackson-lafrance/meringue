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

Focused transcript entries retain semantic categories. Reasoning, tool calls, tool results, normal output, and final assistant output use distinct theme-aware styles on each role/type header, alongside the retained timestamp; message bodies use the theme's normal foreground so color emphasizes structure rather than long output blocks. Categories can be filtered with the workspace filter command (`Ctrl-Space`, then `f` by default). Filters never discard transcript data: they change only presentation, reset the transcript scroll to the newest matching entry, and remain durable for the selected worker.

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

## Manual regression fixture

`fixtures/demo_state.json` includes a completed worker whose stored assistant text contains ANSI styling, a duplicate Meringue header, an `output:` label, a titled box, and representative headings, emphasis, lists, a blockquote, inline code, a fenced code block, and a link. `bin/meringue demo` must show normalized, wrapped terminal Markdown without the transcript artifacts. The fixture exercises the same durable-log rendering path used for real completed workers.
