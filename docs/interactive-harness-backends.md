# Interactive harness backends

Meringue drives some backends by running the agent CLI in its own **native interactive mode**, inside a pseudo-terminal that Meringue owns for the whole life of the session. Claude Code and Codex CLI are the first backends built this way.

The point of the design is that one running process serves two jobs that used to need two:

- Meringue types prompts into it to drive a head or a worker autonomously, and
- the focused session viewer renders that same process's screen.

Because there is only ever one process and one writer, **focusing a worker is an attach, not a handoff**. A turn that is mid-flight keeps running. Nothing is aborted, quiesced, replaced, or killed, and leaving focus releases the view and nothing else.

## The two halves

An interactive backend reads and writes through two channels, and the split between them is the load-bearing idea.

**The PTY carries input and pixels.** Prompts go in as keystrokes; what comes back is a TUI drawn for a human. Meringue keeps that screen continuously rendered (`Harness::InteractiveProcess` feeds a `TerminalScreen` from its reader thread) so a viewer that attaches sees the agent's real current state immediately rather than a blank pane that fills in as new output happens to arrive.

**The transcript carries meaning.** Every state decision — is this turn still running, what did the agent answer, did the turn fail and why — is read from the harness's own durable JSONL transcript (`Harness::TranscriptTail`), never scraped from the screen. A TUI's layout is presentation that can change with any release; the transcript is a structured record with an explicit stop reason. Reading the durable file also means a session survives a Meringue restart, because the same decisions can be made about a session this process did not start.

Only bytes appended since the previous poll are parsed. A worker can run for an hour and produce a multi-megabyte transcript; re-parsing all of it on every reconciliation tick would make polling cost grow with session age.

## What a backend supplies

`Harness::InteractiveClient` implements the whole `Harness::Client` contract on top of those two channels. A provider subclass supplies only what is genuinely provider-specific:

| Hook | What it answers |
| --- | --- |
| `spawn_argv` / `resume_argv` | how to start a new session, and how to reopen a durable one |
| `transcript_path` | where this provider writes the session's transcript |
| `capture_session_identity` / `discover_session_identity` | how a provider that assigns its own id after first input identifies the exact durable session |
| `prepare_workspace!` | one-time setup a workspace needs before the CLI will run in it |
| `wait_until_ready` | when the prompt box is actually accepting input |
| `submit_prompt` / `interrupt` | how a prompt is entered and how a turn is cancelled |
| a `TranscriptSchema` | how to read that provider's records |

Everything else — delivery receipts, settle classification, session views, the live terminal, restart-on-resume — is inherited, so a second interactive backend is a small file.

## Things that are easy to get wrong

**Typing before the prompt box exists.** Agent CLIs print a banner, load plugins, and start language servers before they will accept input. `wait_until_ready` blocks until the prompt box is drawn; a spawn that never gets there fails with the last screen attached rather than silently typing into nothing.

**Submitting a multi-line prompt as several prompts.** A prompt box submits on Enter, so a literal newline would send a fragment. Prompts are entered with bracketed paste and submitted as a separate keystroke afterwards.

**Settling a turn on the previous turn's answer.** Between the keystroke that submits a prompt and the transcript record that proves it landed, the session legitimately still looks settled — from the *last* turn. Every prompt Meringue sends carries a delivery marker, and the session reports `streaming` until that marker appears in the transcript. The same marker doubles as the prompt-delivery receipt, so a write that appeared to fail can still be proven delivered instead of being sent twice.

**Cancelling with the wrong key.** The interrupt key is the one the CLI itself uses to stop a turn. Claude Code and Codex both use Escape. In Codex, Tab submits a queued follow-up while a task is active; Enter is ordinary submission.

**Mistaking a subagent's turn for the session's.** Sidechain records are a subagent's own conversation. The parent's turn is not finished because a subagent's was, and a subagent's answer is not the worker's report, so those records are excluded from state.

## Claude Code specifics

- **Transcript location.** `~/.claude/projects/<slug>/<session-id>.jsonl`, where the slug is the resolved workspace path with every non-alphanumeric character replaced by `-`. Getting this wrong is silent — the session runs fine and Meringue simply reads an empty transcript — so the client also falls back to finding the file by session id.
- **Workspace trust.** Claude Code asks once per directory whether the folder is trusted, and it asks *before* accepting any input, including under `--dangerously-skip-permissions` (which governs tool permissions, not workspace trust). Every Meringue worker gets a brand new worktree path, so without handling this every worker would start by blocking on a modal nobody is watching. `Harness::ClaudeWorkspaceTrust` records the same flag the modal writes, and the client also answers the modal on screen in case a concurrent Claude Code write to that shared config drops the flag.
- **Inherited session markers.** A Claude Code process started from inside another one disables its own transcript and adopts the parent's identity. Since the transcript is Meringue's entire read path, those variables are scrubbed and persistence is forced on.
- **Permissions for unattended work.** A worker runs in its own worktree with nobody to answer a permission prompt, so workers run with `--permission-mode bypassPermissions`. The isolation that makes that safe is the worktree, not the prompt. Heads are read-only: `--permission-mode plan` with a read-only tool set, and slash commands disabled so a project's own commands cannot redirect an orchestration decision.

## Codex CLI specifics

- **Provider-assigned identity.** Codex does not accept a caller-supplied thread id for a new interactive session and creates its rollout only after the first prompt. Meringue snapshots the existing rollout paths before launch and puts a unique delivery marker in that initial prompt. It then matches a newly created rollout by marker and canonical workspace, persists Codex's real `session_id` and path, and only returns spawn success after that identity is known. Concurrent starts in one checkout therefore cannot claim each other's rollout.
- **Transcript location and schema.** Codex rollouts live under `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<session-id>.jsonl` (`CODEX_HOME` defaults to `~/.codex`). `CodexTranscript` reads `task_started`, `task_complete`, `turn_aborted`, user/agent messages, and tool response items. A `task_complete.error` is a failed turn, not a completion; `last_agent_message` is the final result.
- **Workspace trust.** Codex's directory trust modal appears before the composer. The client answers the preselected “Yes, continue” option, then waits for the real `› Ask Codex…` composer before entering a prompt.
- **Prompt modes.** Escape interrupts an active turn for `steer`. A Codex `follow_up` is pasted into the composer and submitted with Tab, which is Codex's native queue command. Normal settled prompts use Enter.
- **Permissions.** Heads use `--sandbox read-only --ask-for-approval never`. Isolated workers use `--dangerously-bypass-approvals-and-sandbox` so unattended implementation and delivery do not stop at a modal inside their dedicated worktree. A `shared_read_only` worker strips that flag and enforces the head-style read-only settings.
- **Resumption.** A lost PTY is restarted with `codex resume <session-id>` in the recorded workspace. The same rollout, worktree, branch, model/reasoning settings, and Meringue agent record continue. Opening focused view while the PTY is live attaches to it without a restart.
- **Models.** `codex debug models` is the authoritative catalog probe. Meringue keeps only model slug/name, supported reasoning levels, and context size; Codex's large prompt/instruction payloads never enter Meringue state.

## Focus, concretely

`Harness::Client#live_terminal_supported?` is what the rest of Meringue branches on; nothing above the client layer checks a harness name.

1. The pane asks `Workspace::Controller#focus_mode`, which asks the kernel, which asks the client.
2. `live_terminal` returns a handle onto the already-running process. The handle carries input and screen only — `write`, `snapshot`, `resize`, `alive?` — so a UI holding one can type and watch but cannot detach, signal, or kill the session. Ownership stays with the kernel.
3. A durable `live_focus` marker records that a person owns the prompt box, so dashboard-issued prompts are refused with an explanation rather than interleaved with what the user is typing.
4. Reconciliation keeps polling normally, because there is no second writer to stand down for. It does not *settle* a focused worker: the turn the user just watched finish is the end of their exchange, not the end of the worker's assignment.
5. Detaching clears the marker. The session keeps running, so this cannot fail in a way that leaves a worker without a supervisor.

Backends that cannot do this — Pi, today — keep the older handoff path (`prepare_interactive_session`), which must settle an active turn and release the managed transport before a separate interactive process can take over the session file. See [`agent_workspace_integration.md`](agent_workspace_integration.md).

## Testing

`test/integration/harness/interactive_client_test.rb` drives a real PTY against `test/fixtures/fake_interactive_agent.rb`, a stand-in agent CLI. `test/integration/harness/codex_interactive_client_test.rb` adds a Codex-shaped stand-in that assigns its own session id after first input and writes rollout records below a temporary `CODEX_HOME`. It is deliberately unhelpful — it renders a banner before it is ready, echoes pasted text, takes visible time to "think", and writes its transcript incrementally — because those are the behaviours the transport has to cope with against a real agent. No network call, no vendor install.

`test/e2e/claude_interactive_proof.rb` is the live Claude counterpart. Codex provider behavior remains covered hermetically so the automated suite never needs Codex credentials or spends tokens. It talks to a real `claude` install and spends real tokens, so it is not part of `rake test`; run it directly when changing the transport:

```bash
ruby -Ilib test/e2e/claude_interactive_proof.rb
```

It proves the properties the design rests on: a session spawns and answers with no per-turn process, a second prompt reuses the same pid, the viewer attaches **mid-turn** without stopping the work, a prompt typed in the viewer lands in the same session Meringue is reading, and the whole exchange happens on one process.
