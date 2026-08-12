# Scalability benchmark

`benchmark/scalability.rb` is the process-level, token-free responsiveness harness for Meringue. It is deliberately separate from microbenchmarks: one result combines state size, issues/tasks, retained logs, agents, active fake sessions, concurrent reconciliation writes, AgentTree rendering, log rendering, typing, and scrolling.

## Isolation and measurement

For every workload the parent process:

1. creates a fresh `Dir.mktmpdir` and generates its only `state.json` there;
2. starts a separate Ruby/Meringue child process (never the user's running Meringue);
3. gives every generated worker a `fake` harness and `mock-session-*` reference;
4. runs the real `Meringue::App` and `Meringue::TUI::App` event/render loop behind a JSON protocol terminal;
5. runs synthetic reconciliation concurrently at the requested cadence. It calls `Harness::FakeClient#get_state`, advances every active session revision, appends uniquely identified lifecycle activity, and atomically saves state. It never starts Pi, another harness CLI, a network request, or a model turn;
6. writes one input and waits for the child to acknowledge the frame rendered from that input. Elapsed time therefore includes input transport, state refresh/composition, layout, Canvas rendering, and frame output—not just a key handler;
7. records median, p95, p99, and maximum independently for typing and mouse-wheel scrolling, samples child RSS, and verifies that typed text rendered, all active revisions reached the final update, and synthetic event IDs remained exactly once.

The default budget is p95 below 50 ms for both interaction types and no measured sample above 100 ms. A workload is `fast` only if all three checks pass. Logs use the real 500-entry retention boundary. Generated descriptions add state payload rather than relying on a developer's history.

The benchmark's `ps` RSS sample and timings are development-machine diagnostics, not CI assertions. CI runs a small structural process-level workload in `test/integration/tui/scalability_benchmark_test.rb`; it verifies hermetic child execution, rendering distributions, concurrent updates, state visibility, and exactly-once events without imposing machine-sensitive thresholds.

## Reproduction

From the repository root:

```bash
# Default progressive sweep; stops at the first workload over budget
ruby benchmark/scalability.rb

# The full sweep used below
ruby benchmark/scalability.rb \
  --loads 25,100,250,500,750,1000,1250,1500,2000,2500,3000,4000 \
  --samples 60 --interval 0.1 --no-stop-at-limit > scalability.json

# Larger state payloads or a custom sweep
ruby benchmark/scalability.rb --loads 100,500,1000 --payload-bytes 2048 --samples 100

# Durable structural regression
ruby -Ilib -Itest test/integration/tui/scalability_benchmark_test.rb
```

The progress table goes to stderr and the complete machine-readable report goes to stdout. `--json` emits compact JSON. Keep the machine otherwise available, use the same Ruby and terminal dimensions (the protocol fixes the viewport at 140×45), and compare runs with the same sample count and reconciliation cadence.

To benchmark an older revision with this harness, export that revision to a temporary directory, copy `benchmark/scalability.rb` into it, and run it there. The script detects revisions predating injectable reconciliation cadence and safely changes the constant inside the isolated child only.

## Profile and improvements

The baseline profile found three costs that multiplied one another:

- presentation refreshed by parsing a complete unchanged JSON snapshot;
- AgentTree found workers by scanning every agent once for every issue (`O(issues × agents)`) and laid out identical rows for every keystroke;
- appending one log invalidated the complete wrapped-log cache, re-normalizing and re-wrapping the other 499 immutable retained entries.

The implementation now:

- gives presentation a deeply frozen, identity-cached `Store#load_readonly` snapshot while preserving independent mutable `Store#load` copies for the kernel;
- indexes workers by issue in one pass and caches AgentTree rows using only presentation-relevant fields, so heartbeat-only updates do not invalidate layout;
- caches formatted log rows per immutable log ID, width, selection, and colorscheme, so one append formats one entry rather than the entire retained window;
- makes the reconciliation interval injectable for deterministic process stress without changing the production two-second default.

Atomic state publication, cross-process fingerprint invalidation, mutable kernel snapshots, complete state visibility, and unique event application remain checked by Store concurrency/cache tests, existing kernel exactly-once/reconciliation tests, and the process harness.

## Results

Measured on the development machine with Ruby 3.4, 140×45 frames, 60 typing plus 60 scrolling samples per workload, a 100 ms synthetic reconcile interval, 256-byte issue payloads, and an otherwise available machine. Values are milliseconds.

A same-harness baseline from `origin/main` established a largest fast workload of **100 issues/tasks and agents (60 active)**. At 250 it exceeded the p95 budget; at 500 it became visibly non-interactive:

| Workload (agents / active) | State | Before typing median / p95 / p99 / max | Before scroll median / p95 / p99 / max | Peak RSS |
|---:|---:|---:|---:|---:|
| 100 / 60 | 0.16 MB | 11.87 / 18.35 / 25.99 / 25.99 | 16.82 / 24.19 / 27.16 / 27.16 | 49.0 MB |
| 250 / 150 | 0.39 MB | 38.58 / 67.05 / 71.57 / 71.57 | 54.16 / 76.89 / 79.78 / 79.78 | 59.1 MB |
| 500 / 300 | 0.65 MB | 106.01 / 571.71 / 955.50 / 955.50 | 159.16 / 191.18 / 1954.80 / 1954.80 | 73.6 MB |

After the changes, the largest tested workload satisfying both p95 < 50 ms and max < 100 ms was **1,250 issues/tasks, 1,250 mocked agents, 750 concurrently active agents, 500 retained logs, and a 1.42 MB state file**:

| Workload (agents / active) | State | After typing median / p95 / p99 / max | After scroll median / p95 / p99 / max | Peak RSS |
|---:|---:|---:|---:|---:|
| 250 / 150 | 0.39 MB | 3.87 / 9.31 / 13.71 / 13.71 | 4.64 / 14.72 / 16.63 / 16.63 | 53.8 MB |
| 500 / 300 | 0.65 MB | 5.56 / 22.10 / 37.57 / 37.57 | 7.23 / 21.86 / 36.03 / 36.03 | 59.7 MB |
| 1,000 / 600 | 1.16 MB | 8.86 / 24.71 / 27.50 / 27.50 | 11.63 / 33.37 / 51.43 / 51.43 | 77.2 MB |
| **1,250 / 750** | **1.42 MB** | **10.46 / 30.46 / 39.17 / 39.17** | **14.15 / 33.36 / 48.09 / 48.09** | **83.1 MB** |

Every row reported state visibility and exactly-once synthetic events as true. At the fast limit, 10 reconciliation writes completed during the 120 measured interactions.

### Beyond the limit

At 1,500 agents, a steady-state scrolling/GC spike produced 233.95 ms p95 and 328.94 ms max. At 2,000, both p95 values crossed 50 ms (typing 52.98 ms, scrolling 53.63 ms), though max remained below 100 ms in that run. At 3,000 (3.24 MB state, 1,800 active), typing p95/max reached 657.54/725.79 ms and scrolling p95/max reached 117.21/187.64 ms, with 144.0 MB peak RSS. The process remained correct and completed cleanly; degradation is latency and allocation/GC pressure, not missing state, duplicated activity, corruption, or a crash.

The boundary is workload- and machine-sensitive, so **1,250 is a measured fast operating point, not a hard product cap**. Run the sweep on the target machine when planning materially larger deployments.
