# Harness slice findings

Automated coverage added by the harness slice of the first Meringue test suite.
Everything here is asserted by `test/integration/harness/**` against scripted
JSONL stubs generated inside `Dir.mktmpdir`: no real `pi`, `claude`, or `gh`
binary is executed, no network call is made, and nothing is written outside
the per-test temp directory (`~/.meringue` is never touched, because every client
receives an explicit `session_dir`, `transport_ownership`, or `claude_home`).

## What is covered

| Area | File |
| --- | --- |
| Harness interface contract (all clients agree on methods, signatures, session-ref shape) | `client_contract_test.rb` |
| Harness selection, aliases, defaults, unknown-harness errors, per-kind argv | `registry_test.rb` |
| Pi RPC JSONL protocol, prompt modes, abort/kill, crash handling | `pi_client_protocol_test.rb` |
| Single-writer transport, takeover rules, reattach from a session file | `pi_client_transport_test.rb` |
| Bounded event journal: ordering, per-reader cursors, truncation | `event_journal_test.rb` |
| pid + start-time liveness/identity gate | `process_identity_test.rb` |
| Cross-instance ownership records and advisory locking | `transport_ownership_test.rb` |
| Session views (live, history, malformed lines, read-only handle) | `session_view_test.rb` |
| Generic process transport via Claude (argv, stream parsing, lifecycle) | `process_client_test.rb` |
| Terminal session opening validation | `terminal_session_opener_test.rb` |
| Forge `gh` request/response mapping and error handling | `forge_github_client_test.rb` |

## Behaviours worth knowing (asserted as current behaviour, not bugs fixed here)

1. **`FakeClient` session refs omit `metadata["kind"]`.** `PiClient` and every
   `ProcessClient` backend record the agent kind in metadata, but `FakeClient`
   records only `prompt`, `system_prompt`, and `session_name`. The seven
   top-level contract keys (`harness`, `pid`, `cwd`, `session_id`,
   `session_file`, `is_streaming`, `last_event_at`) are identical everywhere, so
   the kernel stays harness independent; only the optional metadata differs.
   Asserted in `client_contract_test.rb`.

2. **A silent reattach is not visible on the returned session ref.** When
   `PiClient#prompt_session` finds no live RPC process it takes the transport
   over and calls `attach_session`, which sets
   `metadata["resumed_from_session"]`. The value it returns, however, comes from
   a later `get_state`, which rebuilds metadata from the live process. If the
   takeover action was `"none"` (nothing to reclaim) there is no recovery
   metadata to re-apply, so the returned ref carries no trace of the reattach.
   Reclaimed takeovers *are* recorded (`transport_reclaimed_pid`,
   `transport_previous_owner_pid`, `transport_note`). Asserted in
   `pi_client_transport_test.rb`.

3. **`attach_session` uses the key `resumed_from_session`, not
   `resumed_from_session_file`,** even though the value it stores is the resolved
   session file path (`resume_session`).

4. **`read_events` returns `[]` as soon as the transport process dies.**
   `process_for` filters on `alive?`, so the `process_exit` event published by
   the exit watcher can only be observed by a reader that already holds the
   process (for example `wait_for_event`/`wait_for_settled`), never by a
   post-mortem `read_events` call. Asserted in `pi_client_protocol_test.rb`.

5. **Mid-turn conflicts are queued, not failed.** Only
   `PiClient::SessionBusyError` includes `Harness::TransientSessionError`
   (`transient? == true`), so the kernel retries it. Its sibling
   `SessionTransportUnavailableError`, `ProcessNotFoundError`, and
   `InvalidModeError` are hard errors. A normal-mode prompt during streaming is
   **not** an error: it is delivered as Pi RPC `follow_up` so it queues behind the
   active turn, and the substitution is reported on the returned ref as
   `metadata["requested_prompt_mode"]`, `metadata["delivered_prompt_mode"]`, and
   `metadata["prompt_mode_note"]` (the kernel logs those). A steer/follow-up
   against a settled-but-unattached session is downgraded to a normal prompt and
   recorded as `metadata["prompt_mode_downgraded_from"]` plus the same three
   generic keys. `steer` and `follow_up` are never rewritten against a live
   mid-turn session.

6. **Takeover only signals a process that still looks like the harness.**
   `ProcessIdentity.matches?` compares the `ps` executable basename and, when a
   `started_at` was recorded, the OS start time (120s tolerance), so a reused pid
   is never signalled. A live process owned by a live Meringue instance is never
   killed: prompting raises the transient `SessionBusyError` instead.
   `get_state` on such a session reports persisted history with
   `transport_available == false` and an explanatory `transport_note`.

7. **Non-JSON stdout is not fatal.** Interleaved noise from Pi becomes
   `rpc_parse_error` transport events (surfaced in session views as
   `kind == "transport"`, `phase == "error"`), and responses split across reads
   are reassembled by the line buffer. `ProcessClient` backends silently skip
   non-JSON lines but keep them in `metadata["stdout_tail"]`.

8. **The journal is bounded, by both event count and bytes.** Trimming drops the
   oldest entries and readers whose cursor predates the retained window get
   `"gap" => true` instead of silently losing history. This is the mechanism that
   keeps streamed token deltas from accumulating; durable worker output comes
   from `get_last_assistant_text`, matching `docs/agent-output.md`.

9. **`GitHubClient` degrades to `state == "unknown"` instead of raising** for a
   missing `gh` binary, a non-zero exit, or unparseable output, and
   `pull_request_urls_for_branch` degrades to `[]` in the same situations. Nil
   fields are compacted away, so a failed lookup has no `merged_at` key at all.

10. **Terminal opening validates the saved session before launching.** A
    missing, empty, headerless, malformed, or id-mismatched Pi session file is
    `rejected` with an explanation plus the "record, logs, and captured worker
    output remain unchanged" note, and no terminal is spawned. Successful opens
    return `{"status" => "opened"}` with no user-visible message, matching
    `docs/agent-output.md`.

## Test-harness notes for future slices

- `test/support/harness_support.rb` provides `HarnessIntegrationTest` (temp dirs,
  tracked child processes, env restore) plus generators for the Pi RPC stub, the
  generic JSONL process stub, Pi session-file fixtures, and scoped
  `TransportOwnership`/`Config` objects.
- Stub-driven clients use `command: [RbConfig.ruby, script]` so
  `ProcessIdentity` sees a real `ruby` executable name, which is what the
  takeover identity check compares against.
- Helper-spawned placeholder processes are `Process.detach`ed: a zombie child
  still answers `kill(0)`, which would otherwise make liveness assertions (and
  the 5s takeover kill/wait loop) misbehave.

## Turn outcome (added by the network-aborted settle slice)

- `test/integration/harness/pi_client_turn_outcome_test.rb`

`Harness::Client#turn_outcome(session_ref)` is the harness-neutral answer to "did the last
turn finish, or did it die?". The base client returns `nil` ("no evidence"), which keeps
every other backend on its existing behavior. `PiClient` implements it by reading the tail
of the session file (64 KiB) and inspecting the last assistant message:

- `stopReason: "error"` → `state: "failed"`, `kind: "network_failure"` when the error text
  looks like a connectivity failure, otherwise `provider_error`
- `stopReason: "toolUse"` → `state: "incomplete"` (not a failure)
- anything else → `state: "completed"` with the final text
- unreadable/missing/assistant-free session file → `nil`

`turn_ended_at` is included so the kernel can tell a fresh failure from evidence that
predates the prompt which already recovered the worker. Only the tail is read because
reconciliation polls every two seconds and real session files reach megabytes.
