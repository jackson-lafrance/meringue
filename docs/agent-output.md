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

Streaming token/delta events are deliberately excluded from durable logs by the kernel. A sentence such as `Now creating the shared timestamp module:` is therefore harness-owned assistant text returned by `get_last_assistant_text`, not text invented by Meringue and not a raw Pi TUI stream. The source text stays unchanged in state; cleanup is display-only.

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

`TUI::AgentOutput` removes ANSI/control sequences, duplicate rendered headers and `<agent-id> output:` labels, common outer box borders and hard wrapping, trailing whitespace, excess blank lines, and duplicate PR URLs. It preserves ordinary prose, Markdown, lists, and meaningful paragraph breaks.

Agent identity colors remain deterministic per id and theme. The icon, explicit id, status text, and `▌` gutter provide non-color cues when `NO_COLOR` is set.

## Manual regression fixture

`fixtures/demo_state.json` includes a completed worker whose stored assistant text contains ANSI styling, a duplicate Meringue header, an `output:` label, empty padding, and a titled box. `bin/meringue demo` must show the normalized result without those artifacts. The fixture exercises the same durable-log rendering path used for real completed workers.
