# Persisted log retention

Meringue retains the **500 newest durable log entries** in `state.json`. Retention is based only on append order: the oldest entries fall out when the window exceeds the limit, while the retained array stays chronological for existing routing and TUI code.

This is a storage boundary, not issue or project pruning. `/prune`, `/clear`, record status, source, and severity do not change which logs age out. Projects, issues, agents, questions, counters, and harness session files keep their existing lifecycles.

## Why 500 entries

The cap was selected from the state that exposed typing latency, not chosen as a round number in isolation. On July 27, 2026, the active state had:

- 232 logs spanning 149 hours (about 37 logs/day);
- a 360,093-byte state file;
- 227,137 bytes of minified log JSON, or 63.1% of the complete file;
- 978 bytes per log on average (428-byte median, 3,227-byte p95, 21,162-byte maximum);
- 4 logs per referenced issue at the median and 27 at p95.

At that observed rate, 500 entries retain about 13 days of activity. The window holds roughly 18 p95-sized issue lifecycles and is more than twice the history that reproduced the TUI latency. This is enough recent diagnostic context for routing and lifecycle investigation while detailed agent conversations remain available in harness session files.

A replay of the measured log mix through the pre-retention store showed approximately linear persistence cost:

| Logs | State size | Load average | Save average |
| ---: | ---: | ---: | ---: |
| 232 | 360,093 bytes | 1.97 ms | 2.04 ms |
| 500 | 672,794 bytes | 3.55 ms | 4.05 ms |
| 1,000 | 1,254,565 bytes | 6.61 ms | 8.07 ms |
| 5,000 | 5,891,535 bytes | 33.48 ms | 33.65 ms |

A 250-entry limit would preserve only the already-observed six-day window. A 1,000-entry limit would roughly double bounded storage and recurring persistence work for older events whose detailed diagnostic source is normally the harness session. The 500-entry limit leaves headroom over the observed workload while preventing multi-megabyte, tens-of-milliseconds steady-state persistence.

The limit is count-based so entries remain whole and TUI history has a predictable row-level bound. Existing per-field state compaction still limits large messages and captured assistant output. The tradeoff is that an unusually verbose retained window can be larger than the measured average, and old warnings or errors eventually age out rather than receiving status-based special treatment.

## Compatibility and identifiers

No schema field or schema version changed. Older unbounded state files still load. State normalization computes the highest persisted log identifier before removing old entries, and the independent `counters.logs` high-water mark is never reduced. The next kernel event therefore receives a new monotonic ID even when every nearby older entry was discarded.

A legacy oversized file is bounded in memory on its first load and written at the smaller size on the next save. `State::Store#compact!` can also persist the bound immediately. All normal saves enforce the same window. Newest retention does not require referenced projects or issues to exist, so it remains independent from record pruning and recounting.

## Reproducing the measurement

The retention rules and the bounded persistence behavior are covered by the automated suite:

```bash
ruby -Ilib -Itest test/integration/state/log_retention_test.rb
```

It writes an oversized legacy snapshot in a temporary directory, verifies the 500-entry boundary, checks that the bound is applied on load and persisted on the next save, confirms `State::Store#compact!`, and appends through the kernel to confirm that the next ID stays monotonic. It also keeps a generous upper bound on load/save cost so an accidental O(n^2) regression fails the suite.
