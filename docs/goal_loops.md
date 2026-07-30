# Goal loops

A **goal** is the durable controller for "keep producing work until this measurable criterion is met". It is attached to exactly one issue, owns success criteria, a deterministic metric, budgets, and iteration history, and is advanced by the kernel's existing reconcile tick.

A goal is not an agent, not a new AgentTree node kind, and not a long-lived LLM session. That is the central design decision: the loop's memory lives in `state["goals"]`, so it survives restarts, costs nothing while idle, keeps heads stateless, and keeps the kernel the only layer that mutates orchestration state.

```txt
reconcile tick (2s)
  -> advance_goal_loops
     -> Goals::Loop.next_action(goal, agents, now)      pure decision
        -> measure baseline | start attempt | measure | judge | stop | wait
     -> kernel performs exactly one of those, writes the result to state, logs it
```

## Shape of the loop

One **iteration** is one attempt plus one judgement, serialized:

1. **attempting** — a worker is producing work. The kernel re-prompts the previous worker (`accumulate`, the default) or spawns a new one (`fresh_attempt`).

`accumulate` is the default because each iteration should build on the last: the same worker, worktree, and branch carry forward, so a metric that moves 60 → 68 → 76 keeps its gains and the session budget is not consumed. `fresh_attempt` allocates a new worktree per iteration branched from the project's base ref, so iterations are *independent* attempts rather than cumulative ones; use it when an attempt should start from a clean tree, and expect the metric to restart from the baseline each time.
2. **measuring** — the attempt has settled, so the kernel runs the metric command and the guardrails against the attempt's own workspace/branch.
3. **judging** — the judge scores the measurement against the metric and guardrails and writes the directive the next attempt receives.
4. **settled** — the iteration is history. The loop either stops or starts the next iteration.

At most one attempt worker exists per goal at any moment. That single-flight invariant is what makes unbounded spawning impossible, and it is enforced in the pure decision function, not by prompt guidance.

## Who measures, who judges

The **metric is measured by the kernel**, never self-reported by the attempt agent. A number an agent reports about its own work is not a measurement, and the failure mode is well documented: assertion-free tests that raise coverage, lowered thresholds, deleted or skipped tests, edited exclude lists. So:

- the metric command lives on the goal record and is run by `Goals::MetricProbe` with a hard timeout, its own process group, and capped output;
- it runs in the attempt's workspace, so it measures the branch the attempt actually produced;
- **guardrails** (for example `rake test`) must keep passing. Reaching the target while a guardrail is red is *not* success: it is recorded as `not_met` with `gaming_suspected`, and it does not count as progress.

The **judge** (`Goals::Evaluator`) is deterministic today. It turns one measurement into a verdict (`met`, `partially_met`, `not_met`, `inconclusive`), a score, a delta, evidence lines, and `next_directive`. Both gates must agree for a goal to complete: the comparator/target *and* the guardrails *and* the verdict.

The reflection is deliberately kept **outside** the agent session. Iteration N+1 gets a compact "you already tried this, the metric moved 61 → 64, here is the directive" instead of a growing transcript, because self-critique with no external signal restates the same plan in new words.

## Termination

A goal stops for exactly one reason, and the reason is durable on the record.

| Rule | Default | Result |
| --- | --- | --- |
| Success | comparator satisfied **and** guardrails green **and** verdict `met` | `completed`, `goal_met` |
| Iteration budget | 5 iterations (hard ceiling 20) | `blocked`, `max_iterations` |
| No progress | 2 consecutive iterations without a delta ≥ `min_metric_delta` | `blocked`, `no_progress` |
| Oscillation | an iteration reproduces a workspace fingerprint the goal already produced | `blocked`, `oscillation` |
| Wall clock | 4 h (hard ceiling 24 h) | `blocked`, `budget_exhausted` |
| Session budget | `2 × max_iterations + 2` spawned attempts | `blocked`, `budget_exhausted` |
| Broken metric | metric command unreadable twice in a row | `errored`, `probe_unavailable` |
| User stop | `/goal stop`, `Kill`, or a paused goal | `killed` / no action |

Budgets are clamped on write, so a user or head asking for 10,000 iterations gets the ceiling instead. Every stop except a user stop also raises a **question**, so a stalled goal shows up in `/questions` instead of going quiet; answering it routes through the normal answer → head path.

Iteration cadence is rate-limited by `min_seconds_between_iterations` (15s default) so a fast-failing attempt cannot burn the whole budget in seconds.

## Interrupting a goal

| You want | Use | Effect |
| --- | --- | --- |
| Stop starting new attempts, keep the loop | `/goal pause G1` | The tick skips the goal. The in-flight attempt is untouched and is not judged until you resume. |
| Resume | `/goal resume G1` | The loop continues from its recorded phase. |
| End the loop, keep the work | `/goal stop G1` | Goal `killed` / `user_stopped`. The current attempt session and its branch are left alone. |
| End the loop and the attempt | `/kill G1` | Goal `killed`, and its in-flight attempt session is killed and removed, like any other kill cascade. |
| Change the target or budget | `/goal status`, then a head or `ModifyGoal` | Raising `max_iterations` and setting `status: working` restarts a guard-stopped goal. |

Killing the goal's issue or project settles the goal too; a goal is never left ticking against a record that no longer exists.

## Commands

`CreateGoal`, `ModifyGoal`, `StopGoal`, and `ListGoals` are ordinary kernel commands: validated, logged, journaled, and head-proposable. See `docs/head_agent_kernel_commands.md` for the head-facing contract.

```bash
/goal create P1-I7 "line coverage of lib/meringue/kernel is at least 80%" \
  --metric "bundle exec rake coverage" --target 80 --guardrail "rake test" --max-iterations 4
/goal status            # every loop, its iteration accounting, and stop reasons
/goal status G1         # one loop plus its recent iterations and directives
/goal pause G1 | /goal resume G1 | /goal stop G1
```

Useful flags: `--comparator gte|lte|gt|lt|eq`, `--parse last_number|first_number|regex|json_path|exit_status`, `--pattern "<regex>"`, `--json-path totals.line`, `--metric-cwd workspace|project_root`, `--min-delta`, `--no-progress`, `--max-workers`, `--max-seconds`, `--cooldown`, `--fresh-attempt`, `--accumulate`, `--paused`, `--title`.

## Record shape

`state["goals"]` holds one record per goal; `counters["goals"]` mints `G<n>` ids, and `/recount` renumbers them with everything else.

```txt
Goal
  id, project_id, issue_id, title, success_criteria, kind
  status: queued|working|blocked|completed|errored|killed      (no new statuses)
  stop_reason, paused, question_id
  metric  { command, cwd, comparator, target, timeout_seconds, parse{...}, guardrails[] }
  judge   { mode: "metric_only" }
  budget  { max_iterations, max_wall_clock_seconds, max_workers,
            max_consecutive_no_progress, min_metric_delta, min_seconds_between_iterations }
  continuity: accumulate|fresh_attempt
  baseline_metric / last_metric / best_metric
  current_iteration, workers_spawned, consecutive_no_progress, consecutive_probe_failures
  active_worker_id, last_worker_id, next_tick_at
  owner_instance_id / owner_instance_pid / owner_instance_started_at
  iterations[]  (last 20 verbatim)

Iteration
  number, phase: attempting|measuring|judging|settled, mode
  attempt_command_id ("G1-IT3-ATTEMPT"), attempt_worker_id, attempt_worker_status,
  attempt_branch, attempt_workspace_path
  metric{value, exit_status, timed_out, stdout_tail, parse_error}, metric_delta, guardrails[]
  workspace_fingerprint
  verdict, score, evidence[], gaming_suspected, next_directive, judged_by
  started_at, settled_at, duration_seconds
```

Iteration history is the source of truth for progress. Logs explain what happened but are evicted at 500 entries, so they are never read back as state.

## Exactly-once and multi-instance behaviour

- Each iteration has a deterministic command id (`G1-IT3-ATTEMPT`), so a repeated `SpawnWorker` reuses the kernel's existing exactly-once spawn dedupe instead of creating a second worker.
- The phase is checkpointed to state *before* the side effect, so a crash between checkpoint and spawn resumes the same iteration.
- A goal records its driving instance. Another live Meringue instance sharing the state file will not advance a goal that is already owned, matching `docs/kernel-command-application.md`.
- The tick advances a goal by at most 4 phases per pass, and after starting an attempt the only legal next decision is "wait".
- Metric commands are external I/O on the reconcile thread, so one pass spends at most `GOAL_ADVANCE_BUDGET_SECONDS` (30s, injectable) advancing goals; goals that do not fit wait for the next tick instead of delaying session reconciliation for everything else. A single metric command can still exceed that on its own, bounded by the goal's `metric.timeout_seconds` (default 600s). Moving measurement off the tick thread is a follow-up; keep long-running metrics in mind when choosing a metric command.

## Deferred (dependent) workers

Goal attempts and deferred workers ("start B after A settles") are independent features that share
the tick. A goal never queues its own attempts behind another agent: their order comes from the
loop's single-flight rule, so an attempt starts immediately and carries no deferred metadata.

Where they meet:

- **Tick order.** A dependent is activated by the worker-completion hook while polls are applied,
  and the reconcile-level `resolve_deferred_workers` step is its recovery path. Both run before
  `advance_goal_loops` in the same pass, so a goal never observes a dependent that is still waiting.
- **Kill.** `Kill G1` ends the loop and kills its attempt, and the kill cascade then cancels any
  worker queued behind that attempt, so nothing is left waiting on a removed record.
- **Prune.** `active_goals` and `pending_deferred_dependents` are independent blockers, and an issue
  can report both.
- **Budgets.** A goal counts only the sessions it started itself; a dependent someone else queued on
  the goal's issue does not consume the goal's session budget.

## Prune and issue status

- An issue that owns a live goal is never marked `completed` by the worker rollup, because a `completed` issue between iterations would also make it prunable mid-goal.
- `active_goals` is a prune blocker; a goal is removed only when its issue bundle is removed, and then it never dangles.

## Deliberately not built yet

- **A worker-backed judge.** `judge.mode` exists and is validated, but only `metric_only` is implemented; `worker_when_metric_met` is rejected with a clear message rather than silently downgraded. The verdict/evidence/directive contract above is what that follow-up fills.
- **Parallel best-of-N attempts.** N worktrees × N sessions per iteration is the most expensive shape available, and the selection verifier would be the gate that already exists. Serial N=1 first.
- **Research-kind goals** (`kind: "research"`, novelty-bounded crawling). Without a trustworthy metric there is no stopping rule.
- **Token/cost budgets.** Nothing in the harness layer reports usage yet, so budgets are honest about what they can count: iterations, sessions, and wall clock.

## Testing

`test/integration/kernel_goals/` covers the pure decisions (`goal_decision_test.rb`), the tick-driven loop (`goal_loop_test.rb`), every termination guard (`goal_termination_test.rb`), maintenance interaction (`goal_maintenance_test.rb`), and the probe against real shell commands in a temp directory (`metric_probe_test.rb`). The loop is driven by scripted measurements, so a whole multi-iteration goal runs in milliseconds without a harness or a real metric command.
