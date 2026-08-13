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
7. records median, p95, p99, and maximum independently for typing and mouse-wheel scrolling and samples child RSS. Frame acknowledgements include revision and viewport digests extracted from the bytes the child rendered: every wheel sample must change the visible logs viewport. After measured samples, an unmeasured barrier pauses reconciliation and requires the final committed revision onscreen; every active agent must converge to that revision, and retained event IDs must equal the complete ordered suffix of committed revisions (not merely be unique).

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
- the existing immutable-log fragment cache kept log formatting bounded, but whole-state parsing and AgentTree work still dominated as issue/agent counts grew.

The implementation now:

- gives presentation a deeply frozen, identity-cached `Store#load_readonly` snapshot while preserving independent mutable `Store#load` copies for the kernel;
- indexes workers by issue in one pass and caches AgentTree rows. Its key includes every rendered record field and all non-heartbeat harness metadata, so reconciliation-visible provisioning, settlement, continuation, PR, and lineage changes invalidate immediately while volatile heartbeat-only updates reuse layout;
- retains the merge base's existing formatted-log fragment cache unchanged;
- makes the reconciliation interval injectable for deterministic process stress without changing the production two-second default.

Atomic state publication, cross-process fingerprint invalidation, mutable kernel snapshots, complete state visibility, and unique event application remain checked by Store concurrency/cache tests, existing kernel exactly-once/reconciliation tests, and the process harness.

## Results

Measured on the development machine with Ruby 4.0.6, 140×45 frames, 60 typing plus 60 scrolling samples per workload, a 100 ms synthetic reconcile interval, 256-byte issue payloads, and an otherwise available machine. Values are milliseconds. The exact baseline is merge base `3e14d9f5f415a3c2aadba3cc0a4a8b14ab2556f1`; the optimized measurements were taken from the identical candidate tree implemented at `4986e6949723b79221ad27d63ca0ebaf062113fe` (the later `31e9b0dce60cb6119ab04cd895da247f3df972dc` adds only the unmeasured final visibility barrier). Raw outputs are `/tmp/baseline-scale.json`, `/tmp/optimized-scale.json`, and `/tmp/optimized-scale-large.json` when reproduced with the commands above.

The corrected same-harness baseline established a largest fast workload of **100 issues/tasks and agents (60 active)**. At 250 it exceeded the p95 budget; at 500 both p95 and maximum were non-interactive:

| Workload (agents / active) | State | Before typing median / p95 / p99 / max | Before scroll median / p95 / p99 / max | Peak RSS |
|---:|---:|---:|---:|---:|
| 100 / 60 | 0.16 MB | 11.92 / 20.28 / 29.36 / 29.36 | 16.80 / 23.11 / 25.59 / 25.59 | 50.5 MB |
| 250 / 150 | 0.39 MB | 36.50 / 51.86 / 81.30 / 81.30 | 52.78 / 67.32 / 72.00 / 72.00 | 62.8 MB |
| 500 / 300 | 0.65 MB | 104.31 / 125.38 / 227.63 / 227.63 | 155.39 / 171.72 / 179.60 / 179.60 | 74.2 MB |
| 1,000 / 600 | 1.17 MB | 329.42 / 353.48 / 674.47 / 674.47 | 486.47 / 507.92 / 514.69 / 514.69 | 106.4 MB |

After the changes, the largest tested workload satisfying both p95 < 50 ms and max < 100 ms was **1,500 issues/tasks, 1,500 mocked agents, 900 concurrently active agents, 500 retained logs, and a 1.68 MB state file**:

| Workload (agents / active) | State | After typing median / p95 / p99 / max | After scroll median / p95 / p99 / max | Peak RSS |
|---:|---:|---:|---:|---:|
| 250 / 150 | 0.39 MB | 3.99 / 13.51 / 19.21 / 19.21 | 5.04 / 14.85 / 15.93 / 15.93 | 56.4 MB |
| 500 / 300 | 0.65 MB | 6.04 / 23.52 / 28.46 / 28.46 | 7.67 / 21.59 / 22.17 / 22.17 | 64.9 MB |
| 1,000 / 600 | 1.16 MB | 10.26 / 28.90 / 38.72 / 38.72 | 14.09 / 34.93 / 35.54 / 35.54 | 86.2 MB |
| 1,250 / 750 | 1.42 MB | 12.74 / 38.84 / 44.98 / 44.98 | 17.24 / 38.68 / 41.66 / 41.66 | 93.9 MB |
| **1,500 / 900** | **1.68 MB** | **14.74 / 40.49 / 43.48 / 43.48** | **19.53 / 49.66 / 61.70 / 61.70** | **102.6 MB** |

Every row reported rendered state visibility, complete ordered exactly-once retained events, and clean exit as true. At the fast limit, 12 reconciliation writes completed during the measured run.

### Beyond the limit

At 2,000 agents, typing/scrolling p95 reached 54.78/54.52 ms (72.18 ms maximum), crossing the interactive p95 budget. At 2,500, scrolling max reached 128.48 ms. At 4,000 (4.27 MB state, 2,400 active), typing p95/max reached 107.69/156.59 ms and scrolling p95/max reached 110.84/127.33 ms with 188.0 MB peak RSS. Every run still rendered committed activity, retained the exact event sequence, converged all active revisions, and exited cleanly: failure beyond the limit is steadily rising layout/allocation latency, not hidden state, duplication, corruption, or a crash.

The boundary is workload- and machine-sensitive, so **1,500 is a measured fast operating point, not a hard product cap**. After the nested cache-key snapshot correctness fix, a 100-sample confirmation at 1,500 reported typing median/p95/p99/max **14.62/35.79/45.35/45.35 ms** and scrolling **19.45/43.56/83.83/83.83 ms**; the fast point therefore still holds with the final cache semantics. Run the sweep on the target machine when planning materially larger deployments.
