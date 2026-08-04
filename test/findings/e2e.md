# End-to-end suite findings

Scope: `test/e2e/**` plus `test/support/e2e_support.rb`. Six flows drive real wiring
(`Input::Router` → `Heads::PromptLoop` → `Kernel::Engine` → `State::Store` →
`Workspace::Manager` git worktrees → fake harness sessions → logs → `TUI::Panes::AgentTreePane`
→ JSON reloaded from disk). No production code was changed; where behavior looked wrong the
tests assert what the code actually does today and the gap is recorded below.

## Bugs / gaps observed

1. `Heads::PromptLoop` cannot wait for workers (`wait_for_workers: true` raises).
   `Kernel::Engine` exposes `attr_reader :harness_client` near the top of the class, but
   `lib/meringue/kernel/engine.rb` redefines `def harness_client` *after* the `private`
   keyword (~line 3634), so the public reader is replaced by a private method.
   `PromptLoop#wait_for_worker_results` calls `engine.harness_client.respond_to?(...)` and
   dies with `NoMethodError: private method 'harness_client' called`. This path is unused in
   production (the TUI constructs `PromptLoop` with `wait_for_workers: false`, and
   `meringue head-loop` uses `Heads::SimpleLoop`, which holds its own client), so it is a
   latent bug rather than a user-visible one. The e2e suite therefore settles workers the way
   the running app does: finish the harness session and call `engine.reconcile_sessions`.

2. Answering an open question drives follow-up work.
   `/answer Q1 "..."` records the answer, starts a routing head with the question context,
   and applies the resulting commands. The clarifying-question flow covers the persisted
   question scope and resulting head routing.

3. Head context supports inferring implicit answers.
   `Heads::Context` exposes open-question records and populates
   `routing_context.question_being_answered` for explicit ids and uniquely referenced prose.

4. `Prune` reports removed agent ids that no longer exist. Applying a head result cleans the
   head record out of state immediately, but `remove_issue_bundles_and_agents!` still collects
   `issue["originating_head_id"]`, so `removed_agent_ids` came back as
   `["P1-I1-W1", "H1"]` when pruning one resolved issue. Cosmetic (reporting only); the test
   asserts the worker id is included instead of an exact array.

5. A successful reconcile resume leaves no durable trace on the agent.
   `refresh_agent_session_state` merges the session ref but drops `poll_result["reconcile"]`,
   so `harness_metadata.reconcile` stays absent after `Resumed worker ... from its harness
   session` is logged, and `worker_resume_attempt_count` resets to 0. Only the log line records
   that a resume happened. Repeated resume/failure cycles are consequently not counted across
   successes.

## Behaviors worth knowing (not bugs)

- `completed_session?` treats *any* session ref with `is_streaming == false` as completed, so a
  harness client must report `is_streaming: true` for work that is still running. The fake
  client in `test/support/e2e_support.rb` does this.
- Reconciliation skips agents whose `harness` is `"fake"`, so the e2e fake client reports the
  harness name `"e2e"`. Head agents are deliberately created with the `fake` provider so only
  worker sessions are polled.
- An unresumable worker session is not errored on the first reconcile: it is marked `blocked`
  with a warning and retried, becoming `errored` on the third attempt
  (`WORKER_RECONCILE_RESUME_MAX_ATTEMPTS`).
- `AgentTreePane` renders shortened ids (`P1`, `I1`, `W1`) with titles, not full
  `P1-I1-W1` paths; assertions use the rendered form.
- `Kill` on a worker marks it killed and immediately removes the record, so the worker
  disappears from the AgentTree instead of lingering as a killed row.
