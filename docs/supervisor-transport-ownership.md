# Persistent harness supervisor

## Problem this solves

Today Pi transport ownership is tied to the interactive dashboard/TUI process:
the dashboard holds a harness session's RPC pipes, and when that process exits
every worker loses its RPC transport until another Meringue process detects the
dead owner, attaches to the durable session, and resumes it. The completed
investigation measured repeated supervisor-recovery episodes and hundreds of
minutes of correlated inactivity across sampled workers, with tens of minutes
of paused runtime per affected worker that was silently conflated with active
working.

The persistent supervisor decouples harness transport ownership from the
dashboard process so a dashboard exit, restart, or upgrade never drops workers'
RPC transport, paused runtime is visible as an explicit lifecycle state with a
downtime metric, and recovery preserves the live session instead of
re-prompting or restarting a turn that can remain alive.

## Harness-agnostic by design

Pi is the current backend, but Claude Code, Codex, and other harnesses are
planned as optional backends. The supervisor never references a specific
backend. It talks to every backend through the
`Meringue::Supervisor::TransportAdapter` contract:

- `transport_key`, `claim`, `release`, `record_for` — durable, cross-process
  ownership of one session's transport.
- `evidence` — harness-neutral proof of whether the recorded owner and harness
  child are still alive, used to distinguish an isolated harness crash from a
  shared supervisor exit.
- `attach`, `prompt`, `abort`, `kill`, `get_state`, `streaming?`,
  `wait_for_settled` — session control through the backend's supported
  boundaries.
- `harness_name` — diagnostics only; the supervisor never branches on it.

Adding a backend means writing a new adapter and registering it with
`Meringue::Supervisor.register_adapter`. It does not require reworking the
supervisor, the kernel, or the TUI. `Meringue::Supervisor::PiAdapter` is the
reference implementation and wraps the existing `PiClient` plus
`Meringue::Harness::TransportOwnership` durable lease.

## The supervisor service

`Meringue::Supervisor::Service` owns transport independently of the dashboard
process. Its identity (the supervisor process pid and start time) is recorded
on the durable ownership lease, not the dashboard's. A dashboard client
(`Meringue::Supervisor::DashboardClient`) attaches to the supervisor and routes
spawn/prompt/state/kill through it; the dashboard never claims a transport
lease directly.

Per-session supervision lifecycle:

- `active` — the supervisor owns the transport and the session is reachable
  through it.
- `supervision_lost` — the recorded owner and harness process are both gone, so
  the session's runtime is paused. The durable session, workspace, worktree,
  branch, queued prompts, and deferred-chain references remain valid. This is
  the explicit state that distinguishes paused runtime from active working.
- `recovered` — a supervisor has re-attached. When the original turn was still
  alive it keeps running without being re-prompted; only a settled session that
  needs to continue receives a continuation prompt.

Durable state lives in `Meringue::Supervisor::StateStore`, a per-session JSON
record published atomically under a cross-process `State::FileLock`. It survives
dashboard exits, restarts, and upgrades: a fresh supervisor process loads it
and sees which sessions were `supervision_lost`.

### Key operations

- `Service#register(session_ref, harness_pid:)` — claim durable ownership for a
  freshly spawned or attached session.
- `Service#evidence(session_ref)` — harness-neutral supervision evidence merged
  with the durable record; generalizes `PiClient#session_supervision_evidence`.
- `Service#detect_loss(session_ref)` — observe a session and transition it to
  `supervision_lost` when the recorded owner and harness child are both gone.
  Idempotent: a repeated observation does not reset the lost timestamp.
- `Service#adopt(session_ref, prompt: nil)` — recover an orphaned session by
  re-attaching. When the resumed session is still streaming, the original turn
  is left running and is NOT re-prompted. Only a settled session that needs to
  continue receives the supplied continuation prompt. Records downtime and
  transitions to `recovered`.
- `Service#prepare_handoff(session_ref)` — graceful handoff for an upgrade or
  restart. An active turn is cancelled through the backend's supported abort
  boundary and observed settled, then the transport lease is released cleanly
  so the next owner attaches to a settled session rather than a half-finished
  one. In-flight turns are never killed.
- `Service#relinquish(session_ref)` — release ownership without handoff
  preparation (graceful supervisor shutdown, or after a kill).
- `Service#kill(session_ref)` — terminate the session, release the transport,
  and drop the supervision record.
- `Service#downtime(session_ref)` — seconds of paused runtime accumulated while
  `supervision_lost`, frozen once `recovered`.

## Preserved safety invariants

- **Exactly one durable owner per session.** The transport lease and the
  supervision state store are each single-writer across processes; a takeover is
  only legitimate when the recorded owner is gone.
- **No duplicate prompting on recovery.** A recovered session whose turn is
  still alive keeps running. A settled session receives its continuation prompt
  exactly once. A second adoption while the recovered turn is live does not
  re-prompt.
- **Session durability and workspace ownership preserved.** Recovery re-attaches
  to the same durable session id, workspace, worktree, and branch; nothing is
  respawned or reallocated.
- **Deferred-chain references and shared-workspace relationships preserved.**
  The supervisor never touches issue/agent graph state; it only owns transport
  and records the supervision lifecycle.
- **Recovery restrictions preserved.** An isolated harness crash (owner alive,
  child gone) is never classified as `supervision_lost` and never auto-resumed
  across workers; only the shared-supervisor failure mode is.
- **Graceful handoff never kills in-flight turns.** `prepare_handoff` cancels
  through the backend's supported abort boundary and waits for settle before
  releasing the lease.

## Configuration

The supervision state directory defaults to `~/.meringue/supervisor-state` and
is overridable with `MERINGUE_SUPERVISOR_STATE_DIR`. The transport lock
directory follows `Meringue::Harness::TransportOwnership` and is overridable
with `MERINGUE_TRANSPORT_LOCK_DIR`.

## Integration scope

This slice delivers the supervisor abstraction, the Pi adapter, the durable
state store, the dashboard client, the `supervision_lost` lifecycle status, and
regression coverage for handoff, dashboard exit/restart, `supervision_lost`
transitions, downtime accounting, and recovery without duplicate prompting.

Routing every kernel transport operation through the supervisor (replacing the
dashboard-owned transport path in `PiClient` reconciliation) and rendering
`supervision_lost` in the AgentTree from live supervision evidence is the next
vertical slice. The contract and durable state above are the foundation for it.
