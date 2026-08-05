# Goal loops

A **goal** is the durable controller for "keep producing work until this criterion is met". It is attached to exactly one issue, owns success criteria, a judge, budgets, and iteration history, and is advanced by the kernel's existing reconcile tick.

A goal is not an agent, not a new AgentTree node kind, and not a long-lived LLM session. That is the central design decision: the loop's memory lives in `state["goals"]`, so it survives restarts, costs nothing while idle, keeps heads stateless, and keeps the kernel the only layer that mutates orchestration state.

```txt
reconcile tick (2s)
  -> advance_goal_loops
     -> Goals::Loop.next_action(goal, agents, now)      pure decision
        -> measure baseline | start attempt | measure | review | judge | stop | wait
     -> kernel performs exactly one of those, writes the result to state, logs it
```

## Two judges

`judge.mode` picks what "met" means. Everything else — single flight, budgets, guardrails, directives, exactly-once, interruption, prune — is identical for both.

| | `metric_only` (default) | `reviewer` |
| --- | --- | --- |
| Success condition | a kernel-run command prints a number that satisfies the comparator | a reviewer session approves the attempt against the success criteria |
| Needs | `metric.command` + `metric.target` | nothing but `success_criteria` |
| Use it for | coverage, failures, p95, file counts, byte size | "the onboarding reads cleanly", UX polish, prose, design |
| Progress signal | metric delta ≥ `min_metric_delta` | the reviewer's critique changed |
| Cost per iteration | 1 attempt session | 1 attempt session + 1 short reviewer session |

Use `metric_only` whenever the success condition can honestly be counted: a number is cheaper, deterministic, and cannot be talked into approving. `reviewer` exists for the goals where no such number exists, which previously could not be expressed as a goal at all.

A reviewer-judged goal **rejects** a metric command rather than ignoring it: an unmeasured `metric.command` sitting on the record is a lie about what the loop is doing. Attach that command as a `--guardrail` instead, which is honoured on both judges.

## Shape of the loop

One **iteration** is one attempt plus one judgement, serialized:

1. **attempting** — a worker is producing work. The kernel re-prompts the previous worker (`accumulate`, the default) or spawns a new one (`fresh_attempt`).

`accumulate` is the default because each iteration should build on the last: the same worker, worktree, and branch carry forward, so a metric that moves 60 → 68 → 76 keeps its gains and the session budget is not consumed. `fresh_attempt` allocates a new worktree per iteration branched from the project's base ref, so iterations are *independent* attempts rather than cumulative ones; use it when an attempt should start from a clean tree, and expect the metric to restart from the baseline each time.
2. **measuring** — the attempt has settled, so the kernel runs the metric command and the guardrails against the attempt's own workspace/branch. A reviewer-judged goal has no metric command, so this phase only runs the guardrails and fingerprints the workspace.
3. **reviewing** — *reviewer-judged goals only.* The kernel spawns one short-lived reviewer session and, on a later tick, reads its verdict.
4. **judging** — the judge scores the measurement, or the reviewer's verdict, against the guardrails and writes the directive the next attempt receives.
5. **settled** — the iteration is history. The loop either stops or starts the next iteration.

At most one attempt worker exists per goal at any moment. That single-flight invariant is what makes unbounded spawning impossible, and it is enforced in the pure decision function, not by prompt guidance. A reviewer session only ever runs after its attempt has settled, so "one goal, one live session" holds for reviewer-judged goals too.

## Who measures, who judges

The **metric is measured by the kernel**, never self-reported by the attempt agent. A number an agent reports about its own work is not a measurement, and the failure mode is well documented: assertion-free tests that raise coverage, lowered thresholds, deleted or skipped tests, edited exclude lists. So:

- the metric command lives on the goal record and is run by `Goals::MetricProbe` with a hard timeout, its own process group, and capped output;
- it runs in the attempt's workspace, so it measures the branch the attempt actually produced;
- **guardrails** (for example `rake test`) must keep passing. Reaching the target while a guardrail is red is *not* success: it is recorded as `not_met` with `gaming_suspected`, and it does not count as progress.

The **judge** (`Goals::Evaluator`) is deterministic today. It turns one measurement into a verdict (`met`, `partially_met`, `not_met`, `inconclusive`), a score, a delta, evidence lines, and `next_directive`. Both gates must agree for a goal to complete: the comparator/target *and* the guardrails *and* the verdict.

The reflection is deliberately kept **outside** the agent session. Iteration N+1 gets a compact "you already tried this, the metric moved 61 → 64, here is the directive" instead of a growing transcript, because self-critique with no external signal restates the same plan in new words.

## The reviewer

A reviewer-judged goal replaces the number with a second opinion. The reviewer is **an ordinary short-lived worker session spawned by the kernel through the normal `SpawnWorker` path**, with one difference: it is handed the attempt's own workspace path instead of being allocated a worktree, so it reads the exact branch the attempt produced and never gets a branch of its own.

That choice is what keeps the feature small. The reviewer inherits the AgentTree node, the exactly-once spawn dedupe, session settings, the kill cascade, and the settle classification that every worker already has. The kernel spawns it and then does nothing: the next reconcile tick sees a terminal session and collects the verdict. Nothing polls, nothing sleeps, and no code waits on another agent.

The reviewer prompt (`Goals::ReviewPrompt`) gives it the success criteria, the branch, the guardrail results the kernel already ran, and the previous rounds' critiques, and tells it the turn is read-only.

### The verdict contract

A reviewer ends its turn with one JSON object:

```json
{
  "approved": false,
  "rationale": "one or two sentences on why",
  "critique": ["specific actionable change", "another specific actionable change"]
}
```

`Goals::ReviewVerdict` is deliberately **tolerant about where the JSON is and strict about what it says**. It accepts a fenced block, a trailing object, or a bare object, takes the last verdict-shaped object in the turn (so quoting the contract before answering is harmless), accepts common spellings (`"yes"`, `"verdict": "approved"`, `"changes_requested"`), and normalizes bullet strings and `{item: ...}` objects into a critique list. It then caps the rationale and the critique so one verbose reviewer cannot bloat state.

Anything the kernel cannot act on is **unusable**, not "not approved":

- no JSON object in the turn;
- JSON with no true/false `approved`;
- a rejection with neither a rationale nor any critique — there would be nothing to tell the next attempt.

An unusable verdict is handled as a **broken probe**, exactly like an unreadable metric command:

1. the reviewer is asked **once** more for the same iteration, with the parse failure quoted back at it. The retry gets its own command id (`G1-IT3-REVIEW-RETRY2`) so it is not swallowed by the spawn dedupe;
2. a second unusable answer settles the iteration `inconclusive` and increments `consecutive_probe_failures`;
3. two consecutive unusable iterations stop the goal with `errored` / `probe_unavailable`.

A reviewer session that cannot be spawned at all, or that ends with no final message, is treated the same way. The loop is never blocked by a reviewer that will not answer, and it never invents critique on a reviewer's behalf.

### Guardrails still win

Guardrails are the reason a reviewer-judged goal is not just "an LLM said yes". They run on the attempt's branch before the reviewer is even asked, the reviewer is shown the results, and an approval with a red guardrail is recorded as `not_met` with `gaming_suspected` — the same rule as a metric goal that hits its target with a broken test suite. `--guardrail "rake test"` is strongly recommended on any reviewer-judged goal that touches code.

### Progress without a number

`min_metric_delta` means nothing here, so progress is defined as **the reviewer's critique changed**. `ReviewVerdict.critique_fingerprint` hashes the critique items after downcasing, stripping punctuation and whitespace, and sorting, so reordering or re-punctuating the same asks is still the same critique. An identical critique two iterations running feeds the existing `max_consecutive_no_progress` guard, which stops the loop rather than paying for the same exchange forever. The workspace-fingerprint oscillation guard is unchanged and still applies.

## Termination

A goal stops for exactly one reason, and the reason is durable on the record.

| Rule | Default | Result |
| --- | --- | --- |
| Success | comparator satisfied (or reviewer approved) **and** guardrails green **and** verdict `met` | `completed`, `goal_met` |
| Iteration budget | 5 iterations (hard ceiling 20) | `blocked`, `max_iterations` |
| No progress | 2 consecutive iterations without a delta ≥ `min_metric_delta`, or with an unchanged reviewer critique | `blocked`, `no_progress` |
| Oscillation | an iteration reproduces a workspace fingerprint the goal already produced | `blocked`, `oscillation` |
| Wall clock | 4 h (hard ceiling 24 h) | `blocked`, `budget_exhausted` |
| Session budget | `2 × max_iterations + 2` spawned sessions (attempts **and** reviewers) | `blocked`, `budget_exhausted` |
| Broken probe | metric command unreadable, or reviewer verdict unusable, twice in a row | `errored`, `probe_unavailable` |
| User stop | `/goal stop`, `Kill`, or a paused goal | `killed` / no action |

For a reviewer-judged goal, `max_iterations` is the *expected* end, not a failure: "run a few times and see if a reviewer is happy" ends either approved or out of budget. Both are ordinary reported outcomes. `blocked` / `max_iterations` keeps the branch, every attempt, and every critique on the record, and the question it raises names the reviewer's last outstanding point so the user can accept the work, raise the budget, or stop.

Budgets are clamped on write, so a user or head asking for 10,000 iterations gets the ceiling instead. Every stop except a user stop also raises a **question**, so a stalled goal shows up in `/questions` instead of going quiet; answering it routes through the normal answer → head path.

Iteration cadence is rate-limited by `min_seconds_between_iterations` (15s default) so a fast-failing attempt cannot burn the whole budget in seconds.

## How a goal reads in the AgentTree

A goal is still rendered on its issue, because the AgentTree stays projects -> issues -> workers. What it adds to that row is a goal-colored chip: the iteration it is on, and how much of the goal is actually done. There is deliberately no badge glyph beside the issue id — the numbers are the signal, and a goal row keeps the exact leader, and the exact column alignment, of every other row.

```txt
  └─ ● I7  Raise kernel coverage  3/5 46% ↗
                                  │   │   │
                                  │   │   └─ the issue's delivery PR, still its own marker
                                  │   └─── percent complete: how far the metric travelled
                                  │        from its baseline toward its target
                                  └─── iteration 3 of a 5 iteration budget
```

The two numbers deliberately answer different questions. `3/5` is budget *spent*; the percentage is progress *made*, computed by `Goals::Record.progress_score` from `baseline_metric → target`, so a `lte` goal that drives a number down reads exactly like one that pushes a number up, and only a satisfied comparator reads `100%`.

The reading degrades instead of lying:

| Record state | Row shows |
| --- | --- |
| baseline and a measurement | `46%` |
| baselined, not attempted yet | `0%` (or `100%` if the baseline already satisfies the target) |
| a measurement but no baseline | `64.8→80`, the raw reading, because there is no span to measure travel across |
| nothing numeric measured yet | `?%` |
| no numeric target at all (a reviewer-judged loop) | the iteration alone |

`paused`, `goal met`, `stopped by you`, and `stopped: <reason>` are appended to the chip, so a settled goal says why it settled. The goal chip stands in for the usual completed/total worker ratio on that row: a goal's workers are its attempts, and a second fraction beside the iteration count reads as a conflicting one. When the pane is narrow the title is ellipsized to keep the chip and the PR marker on the row, because both are row status rather than decoration.

## Interrupting a goal

| You want | Use | Effect |
| --- | --- | --- |
| Stop starting new attempts, keep the loop | `/goal pause G1` | The tick skips the goal. The in-flight attempt is untouched and is not judged until you resume. |
| Resume | `/goal resume G1` | The loop continues from its recorded phase. |
| End the loop, keep the work | `/goal stop G1` | Goal `killed` / `user_stopped`. The current attempt session and its branch are left alone. |
| End the loop and the attempt | `/kill G1` | Goal `killed`, and its in-flight attempt session is killed and removed, like any other kill cascade. |
| Change the target or budget | `/goal status`, then a head or `ModifyGoal` | Raising `max_iterations` and setting `status: working` restarts a guard-stopped goal. |

Killing the goal's issue or project settles the goal too; a goal is never left ticking against a record that no longer exists.

## Creating a goal

A goal needs an issue, but you do not need to have one already. `/goal create` (and the `CreateGoal` kernel command behind it) takes either shape:

```bash
# 1. Attach a loop to an issue that already exists.
/goal create P1-I7 "line coverage of lib/meringue/kernel is at least 80%" \
  --metric "bundle exec rake coverage" --target 80 --guardrail "rake test" --max-iterations 4

# 2. Describe the outcome and let Meringue create the issue for it.
/goal create "get line coverage of lib/meringue/kernel to 80% without weakening the suite" \
  --metric "bundle exec rake coverage" --target 80 --guardrail "rake test" --project P1

# 3. Either form, judged by a reviewer instead of a metric.
/goal create "make the first-run onboarding clean, concise, and explicit about the three core commands" \
  --reviewer --guardrail "rake test" --max-iterations 4 --project P1
```

The two forms are told apart by the **first positional token, before anything else is read**:

- A token shaped like a Meringue record id (`P1-I7`, `P1`, `G3`, `P1-I7-W2`) is always an id, never prose. An issue-shaped id attaches the loop to that issue; any other id shape, or an id with no criteria after it, is a usage error naming the right spelling. A mistyped id can therefore never become the title of a brand-new issue.
- Anything else is the prompt, and it must be a single quoted argument. An unquoted sentence is rejected with "quote the whole prompt" rather than silently keeping its first two words.

When the kernel mints the issue:

- **Project**: `--project <project_id>` (a project name or root path also resolves) wins; otherwise the registered project containing Meringue's working directory, otherwise the only registered project, otherwise the command is rejected with `project_ambiguous` and the list of candidates. Meringue never guesses between several projects. `--project` alongside an `<issue_id>` is rejected when the two disagree.
- **Title**: the first sentence of the prompt, trimmed to 72 characters. Heads may send `issue_title` for a better one.
- **Description**: the prompt verbatim, plus the goal id, the success criteria, the metric command with its comparator and target (or the reviewer judge, for a reviewer-judged goal), and the guardrails.
- **Criteria**: the goal's `success_criteria` defaults to the whole prompt.
- The issue is an ordinary issue: same `P<n>-I<n>` counter, prunable, recountable, killable.

Creation is all-or-nothing, so a rejected goal **never leaves an orphan issue behind**: every validation (criteria, metric, comparator, continuity, judge mode, project) runs before anything is minted, and the issue and the goal are written in the same single save. A goal that fails validation leaves the state file exactly as it was, including the id counters.

## Commands

`CreateGoal`, `ModifyGoal`, `StopGoal`, and `ListGoals` are ordinary kernel commands: validated, logged, journaled, and head-proposable. See `docs/head_agent_kernel_commands.md` for the head-facing contract, including how a head decides that "this is critical, don't stop until it's done" is a goal loop rather than an ordinary worker.

```bash
/goal status            # every loop, its iteration accounting, and stop reasons
/goal status G1         # one loop plus its recent iterations, verdicts and directives
/goal pause G1 | /goal resume G1 | /goal stop G1
```

`--reviewer` is the friendly spelling of `--judge reviewer`. It works with either creation form and is mutually exclusive with `--metric`/`--target`; nothing else changes, so budgets, guardrails, continuity, `--project`, pause/resume/stop and `--title` all behave the same.

Useful flags: `--comparator gte|lte|gt|lt|eq`, `--parse last_number|first_number|regex|json_path|exit_status`, `--pattern "<regex>"`, `--json-path totals.line`, `--metric-cwd workspace|project_root`, `--project`, `--reviewer`, `--min-delta`, `--no-progress`, `--max-workers`, `--max-seconds`, `--cooldown`, `--fresh-attempt`, `--accumulate`, `--paused`, `--title`.

## Record shape

`state["goals"]` holds one record per goal; `counters["goals"]` mints `G<n>` ids, and `/recount` renumbers them with everything else.

```txt
Goal
  id, project_id, issue_id, title, success_criteria, kind
  status: queued|working|blocked|completed|errored|killed      (no new statuses)
  stop_reason, paused, question_id
  metric  { command, cwd, comparator, target, timeout_seconds, parse{...}, guardrails[] }
          (a reviewer-judged goal has guardrails only: no command, no target)
  judge   { mode: "metric_only" | "reviewer" }
  budget  { max_iterations, max_wall_clock_seconds, max_workers,
            max_consecutive_no_progress, min_metric_delta, min_seconds_between_iterations }
  continuity: accumulate|fresh_attempt
  baseline_metric / last_metric / best_metric
  current_iteration, workers_spawned, consecutive_no_progress, consecutive_probe_failures
  active_worker_id, last_worker_id, next_tick_at
  owner_instance_id / owner_instance_pid / owner_instance_started_at
  iterations[]  (last 20 verbatim)

Iteration
  number, phase: attempting|measuring|reviewing|judging|settled, mode
  attempt_command_id ("G1-IT3-ATTEMPT"), attempt_worker_id, attempt_worker_status,
  attempt_branch, attempt_workspace_path
  metric{value, exit_status, timed_out, stdout_tail, parse_error}, metric_delta, guardrails[]
  review_command_id ("G1-IT3-REVIEW"), review_worker_id, review_worker_status, review_attempts
  review{usable, approved, rationale, critique[], error, review_worker_id, reviewed_at}
  workspace_fingerprint
  verdict, score, evidence[], gaming_suspected, next_directive, judged_by
  started_at, settled_at, duration_seconds
```

The reviewer fields are the only additions, and they are absent on metric goals.

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

## Watching a reviewer-judged goal

The reviewer's state is visible everywhere the metric would be, so nobody has to read `state.json`:

- **AgentTree** — the goal line shows `◎2/4 changes requested` instead of `◎2/4 61/80`, and the reviewer session appears as an ordinary worker under the issue while it runs.
- **`/goal status`** — the summary line carries `reviewer: approved | changes requested | unreadable verdict | not reviewed yet`, plus `judge_mode`, the last critique, and one line per settled iteration (`it2: not_met changes requested: name the three commands`).
- **`GetInfo` on the issue or goal** — reports `judge_mode` and omits the metric/comparator/target fields instead of showing empty ones.
- **Logs** — one line per phase: review started on `P1-I7-W4`, then the verdict and its first critique item.

## Deliberately not built yet

- **A combined judge.** `worker_when_metric_met` and `worker_every_iteration` ("the metric says met, is it actually met?") are still rejected with a clear message rather than silently downgraded. They need a second-gate ordering that neither `metric_only` nor `reviewer` needs on its own; both single-judge halves now exist to build it from.
- **A human-in-the-loop reviewer.** The question mechanism could ask *the user* to approve an iteration instead of a reviewer session. It is a strictly larger change (the loop would need a durable "waiting on a human" state that no budget can time out sensibly), and the machine-readable reviewer is what makes the loop run unattended, which is the point.
- **Parallel best-of-N attempts.** N worktrees × N sessions per iteration is the most expensive shape available, and the selection verifier would be the gate that already exists. Serial N=1 first.
- **Research-kind goals** (`kind: "research"`, novelty-bounded crawling). Without a trustworthy metric there is no stopping rule.
- **Token/cost budgets.** Nothing in the harness layer reports usage yet, so budgets are honest about what they can count: iterations, sessions, and wall clock.

## Testing

`test/integration/kernel_goals/` covers the pure decisions (`goal_decision_test.rb`), the tick-driven loop (`goal_loop_test.rb`), every termination guard (`goal_termination_test.rb`), maintenance interaction (`goal_maintenance_test.rb`), the reviewer-judged loop end to end (`goal_reviewer_test.rb`), the verdict parser (`review_verdict_test.rb`), and the probe against real shell commands in a temp directory (`metric_probe_test.rb`). The loop is driven by scripted measurements and scripted reviewer replies, so a whole multi-iteration goal runs in milliseconds without a harness, a real metric command, or a real reviewer.
