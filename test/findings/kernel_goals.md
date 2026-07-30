# Findings — goal loop slice

Scope: `Meringue::Goals::{Record, Loop, Evaluator, AttemptPrompt, MetricProbe}`, the
`CreateGoal` / `ModifyGoal` / `StopGoal` / `ListGoals` kernel commands, the
`advance_goal_loops` reconcile step, and the goal-related behaviour of `Kill`, `Prune`,
`Recount`, `GetInfo`, and the worker→issue status rollup.

Test files added by this slice:

- `test/integration/kernel_goals/goal_decision_test.rb` (pure loop/judge decisions)
- `test/integration/kernel_goals/goal_loop_test.rb` (tick-driven loop)
- `test/integration/kernel_goals/goal_termination_test.rb` (every stop reason)
- `test/integration/kernel_goals/goal_maintenance_test.rb` (kill/prune/recount/rollup)
- `test/integration/kernel_goals/metric_probe_test.rb` (real commands, temp dir only)
- `test/integration/input/input_goal_command_test.rb` (`/goal` parsing and suggestions)
- `test/integration/tui/agent_tree_goal_test.rb` (issue-row goal suffix)
- `test/integration/kernel_goals/goal_deferred_worker_test.rb` (goal loops vs deferred workers)
- `test/support/kernel_goals_support.rb`

## Behaviour locked by these tests

- One reconcile pass measures the baseline and starts exactly one attempt. Repeated passes
  while that attempt is live add no further sessions (single flight).
- An unmet, settled iteration is measured, judged, and followed by the next attempt inside
  one pass; a met verdict completes the goal and its issue instead.
- `accumulate` (the default) re-prompts the same worker, so one worktree/branch grows across
  iterations and the session budget is not consumed. `fresh_attempt` spawns a new worker per
  iteration and links it with `follow_up_of_agent_id`.
- The metric is measured in the attempt's workspace; the pre-attempt baseline and
  `metric.cwd: "project_root"` measure the project root.
- Reaching the target with a red guardrail is `not_met` + `gaming_suspected`, and it does not
  count as progress, so the no-progress guard stops such a loop early.
- Every stop reason is reachable and durable: `goal_met`, `max_iterations`, `no_progress`,
  `oscillation`, `budget_exhausted` (sessions and wall clock), `probe_unavailable`,
  `user_stopped`, `killed`. Guard stops also raise a question.
- An issue that owns a live goal is not rolled up to `completed`, is not prunable
  (`blockers` includes `active_goals`), and its goal is removed only with its issue bundle.

## Interaction with deferred (dependent) workers

Deferred spawning landed upstream while this slice was in review, and both features touch the
reconcile tick, the prune blockers, and the kill cascade. `goal_deferred_worker_test.rb` pins the
merged behaviour: a dependent is activated (by the completion hook, with the reconcile step as its
recovery path) before goal loops advance in the same pass; killing a goal cancels workers queued
behind its attempt; `active_goals` and `pending_deferred_dependents` are independent prune blockers
that can both appear on one issue; a dependent queued by someone else does not consume the goal's
session budget; and goal attempts themselves are never deferred.

## Pre-existing issues observed while writing these tests (not fixed here)

1. **`rake test` is already red on `origin/main`.** A clean worktree at `origin/main`
   (`910229c`) fails 35 tests across `heads`, `input`, `kernel_heads`, `kernel_maintenance`,
   `kernel_workers`, `harness`, `workspace`, `tui`, and `foundation`, most of them around
   head question-answering context sections and session reconciliation. They are unrelated to
   goals and reproduce without this branch's changes. This slice adds no new failures, and the
   two shape assertions it did break (`state.keys` and the `ListAll` snapshot keys, which now
   include `goals`) were updated in place.
2. **`Engine#prompt_agent` is still defined twice** (`lib/meringue/kernel/engine.rb:1607` and
   `:4102`). Ruby keeps the later definition, so the earlier one is dead code and the earlier
   body lacks the `PROMPT_MODES` validation and the transient-prompt queue. The goal loop
   deliberately routes through `apply("PromptAgent", …)` so it uses the live definition. Left
   alone because deleting it is unrelated to this slice.
3. **`PromptAgent` has no command-id dedupe** (unlike `SpawnWorker`'s
   `worker_for_spawn_command`). A redelivered `PromptAgent` can therefore double-prompt. The
   goal loop compensates by checkpointing the iteration phase before issuing the prompt, so a
   re-tick sees an `attempting` iteration and waits rather than prompting again; a general fix
   belongs with `PromptAgent` itself.
4. **A spawn failure leaves an errored worker reservation record behind.** That is existing
   `fail_worker_reservation` behaviour, so a goal whose harness cannot spawn accumulates one
   errored record per attempt until the no-progress guard stops it (asserted at its current
   behaviour in `goal_loop_test.rb`).

## Known tradeoff recorded here on purpose

- The metric probe runs on the reconcile thread. A pass spends at most
  `Engine::GOAL_ADVANCE_BUDGET_SECONDS` (30s, injectable) on goals, so many goals cannot starve
  session polling, but one slow metric command still delays that pass up to its own
  `metric.timeout_seconds`. Session state is only *delayed*, never lost: the next pass observes
  it. Moving measurement onto its own thread with an exactly-once handoff is the follow-up.

## Deliberately not covered by automated tests

- A goal running against a real metric command in a real repository (a real coverage or lint
  run) with real harness sessions. `metric_probe_test.rb` covers the probe mechanics with shell
  builtins; the end-to-end "real metric, real agent" path stays a manual check.
- Wall-clock behaviour is asserted by ageing `started_at` in state rather than sleeping.
