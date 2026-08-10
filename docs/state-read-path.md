# The state read path

`State::Store#load` is the hottest call in Meringue. `App#run` hands the TUI
`-> { state_store.load }` as its state provider, so it runs for every rendered frame and every
keystroke, and the kernel calls it again for every command it applies. Anything `load` does is
therefore multiplied by the user's typing speed and by the 2-second reconcile tick.

This document records why the read path is cached and why the spawn argv is compacted. It is a
companion to [`docs/log-retention.md`](log-retention.md), which bounds how much log history the
same file carries.

## What `load` used to cost

Measured against a real 1,026,019-byte `~/.meringue/state.json` (2 projects, 15 issues, 21 agents,
266 logs), warm, Ruby 3.4:

| Step | Cost |
| --- | ---: |
| `File.read` | 0.24 ms |
| `JSON.parse` | 1.24 ms |
| `Models.ensure_state_shape!` | ~0.5 ms |
| `Compactor.compact!` | 2.41 ms |
| **`Store#load` total** | **4.51 ms** |

Every frame paid all of it. The two normalization steps were the majority of the cost and were
pure waste on a read: `save_unlocked` already normalizes and compacts whatever it writes, so
re-walking every string in the object graph could only ever confirm that nothing needed trimming.
Worse, the cost is `O(state size)`, so the dashboard got slower the more work the user did.

## The snapshot cache

`Store` keeps the normalized snapshot as a JSON string, keyed on a file fingerprint of
`[dev, ino, size, mtime.to_i, mtime.nsec]`. A `load` that finds a matching fingerprint parses the
cached string and skips the file read and both normalization passes.

Three properties make the cache safe:

- **Every `load` still returns an independent, mutable copy.** The kernel loads state, mutates it,
  and saves it; handing out a shared object would let one caller corrupt another's snapshot. The
  cache stores a string precisely so the only way to get a state out of it is to parse a new one.
- **Any write is observed.** Saves publish through an atomic rename of a fresh temp file, so a new
  snapshot always has a new inode. Size and nanosecond mtime cover a writer that rewrites the path
  in place instead. `save_unlocked` also seeds the cache with the snapshot it just published, so
  this process never re-normalizes its own write.
- **A torn read is never cached.** `read_state_unlocked` samples the fingerprint *before* reading
  the file and re-samples it after. A write that lands in between produces a mismatch, so the
  parsed state is returned to the caller but not remembered.

Result on the same 1 MB state: **4.51 ms → 1.03 ms** per load, with 1 normalization across 120
loads instead of 120.

## Why the spawn argv is compacted

`harness_metadata.command` is the argv Meringue used to spawn a harness process, kept for
diagnostics. For a head, one of its elements is the entire `--append-system-prompt` payload, which
is the whole kernel snapshot the head was given. On the measured state file two head records held
100 KB and 126 KB of argv each, and argv totalled **258,116 bytes: 28.9% of the whole file**.

Nothing reads it back. It was re-read, re-parsed, re-compacted, and re-serialized on every frame
and every save, and it never shrank.

`Compactor::COMMAND_ARGUMENT_MAX_BYTES` identifies an oversized argv element and replaces that
*entire diagnostic argument* with an omission record carrying its original byte count. The program
and normal flags stay readable while the duplicated prompt body is discarded as one bounded field;
Meringue never keeps a prefix that could be mistaken for a complete message. Compacting the real
state file with this limit shrank it by **21.8%**.

The rule is deliberately scoped to strings inside the diagnostic argv array. `goal.metric.command`
and `goal.guardrails[].command` are scalar strings under the same key name, and they are commands
Meringue still has to run, so they remain verbatim. All other scalar state strings remain verbatim
too: user prompts, worker final reports, conversation messages, and retained log messages are never
partially truncated. Durable logs reclaim space by evicting whole oldest records at the retention
boundary, while head routing uses count-bounded candidate/activity windows of complete messages.

## Verifying

```bash
ruby -Ilib -Itest test/integration/state/store_snapshot_cache_test.rb
ruby -Ilib -Itest test/integration/state/compactor_test.rb
ruby -Ilib -Itest test/integration/tui/state_reload_cost_test.rb
```

`store_snapshot_cache_test.rb` pins the cache and the three safety properties above.
`compactor_test.rb` pins the argv limit and the scalar-command exemption.
`state_reload_cost_test.rb` is the durable guard against the whole class of problem: it renders 30
frames over a large state file through the real store and asserts the store normalized state
**once**, not once per frame. That assertion is structural rather than a stopwatch, so it fails
loudly if per-frame `O(state size)` work is reintroduced, on any machine.
