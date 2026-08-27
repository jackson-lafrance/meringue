# Quiet workers

## The problem

`status == "working"` said exactly the same thing about a worker two seconds into its turn and
about one that had been silent for forty minutes. For a dashboard whose entire reason to exist is
watching several agents at once, that is the first question a person has and the one it could not
answer: *has this one stopped, or is it still thinking?*

## What Meringue reports

A worker that has produced nothing for longer than the threshold is marked **quiet**:

- the AgentTree row gains a `quiet 40m` chip;
- the bottom status bar's worker count gains `· 2 quiet`;
- the logs pane gets one `warning` naming the worker and how long it has been silent.

Quiet is not the same as stuck, and Meringue does not claim to know the difference. A long tool
call and a long think are both quiet, and from outside the harness there is no way to tell them
apart. What Meringue can say honestly is how long it has been since anything came out, so that is
what it says.

The warning is written once per quiet stretch. Output from the worker ends the stretch; if it goes
quiet again, that is a new stretch and a new line.

## The activity clock

Every worker carries `harness_metadata.last_activity_at`. Only *observed activity* advances it:

| advances the clock | does not |
|---|---|
| harness events drained during a reconciliation pass | writing the quiet warning itself |
| session progress extracted from those events | a `reconcile_state` refresh or session-stats poll |
| a prompt delivered to the worker | any other Meringue bookkeeping write |
| a harness heartbeat (`last_event_at`) newer than the stored one | a heartbeat that is not newer |

That separation is the whole design. `updated_at` looks like a usable stand-in and is not: routine
reconciliation bookkeeping moves it, so a clock based on it would reset itself the moment the
quiet warning was recorded.

The clock is monotonic. A harness that replays a stale timestamp cannot make a quiet worker look
busy.

### Workers Meringue has not been watching

A worker adopted from a state file — written before this existed, or left behind by a previous
run — has its clock started at the first reconciliation pass that observes its session, not at
whatever its record last said.

Meringue can honestly report silence it watched. It cannot report silence from the hours it was
not running, and seeding from the stale record would light up every `working` row of a reloaded
state file at once. A record with no clock is reported as nothing at all, never guessed at.

### Workers that are never quiet

- anything that is not `working`: a queued, paused, blocked, or settled worker is silent on
  purpose, and saying so would be noise;
- a worker still waiting on its worktree, which has not been given a session to be quiet in.

## Configuration

```toml
[agent]
quiet_worker_warning_seconds = 900   # default; 0 turns the signal off entirely
```

Also editable in `/config` under **Agent defaults → Quiet worker warning**.

The default is deliberately generous. The signal answers "should I go look at this one?", so a
false alarm every few minutes would be worse than useless.

The kernel owns the threshold and publishes it into `metadata.quiet_worker_warning_seconds`, so
the panes read one value instead of reaching for the config file on every frame. A dashboard that
has not seen a reconciliation pass yet falls back to the same default the kernel uses.

## Cost

The clock is written only when activity actually happens, which is the same moment the row has to
re-render anyway, so it adds no reconciliation churn. The AgentTree row cache keys on the whole
minute the chip displays: a `quiet 12m` row re-renders when it becomes `quiet 13m` and on no frame
in between.

## Testing

```bash
ruby -Ilib -Itest test/integration/kernel_workers/quiet_worker_test.rb
ruby -Ilib -Itest test/integration/tui/quiet_worker_marker_test.rb
```
