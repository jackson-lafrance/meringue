# State-layer test findings (store, models, logs, compactor)

Tests in `test/integration/state/` assert **current actual behavior**. Where that behavior
looks like a bug or a sharp edge, it is recorded here instead of being "fixed" in a test.

Files:

- `test/integration/state/store_persistence_test.rb`
- `test/integration/state/store_concurrency_test.rb`
- `test/integration/state/models_test.rb`
- `test/integration/state/log_retention_test.rb`
- `test/integration/state/compactor_test.rb`
- `test/support/state_support.rb` (shared, hermetic helpers)

## Confirmed working as documented

- `Store#load` on a missing file returns a fully shaped empty state and does **not** create
  the file; `Store#save` creates missing directories and writes pretty JSON with a trailing
  newline via a temp file plus `File.rename`, leaving no temporary files behind.
- Full round trip of projects, issues, agents, questions, logs, counters, conversation
  buffer and agent-workspace UI state is byte-stable: `save` → file → `load` are equal.
- ISO8601 timestamps are preserved verbatim (`2026-07-11T00:08:00Z` style) and generated
  timestamps parse with `Time.iso8601`.
- `fixtures/demo_state.json` loads tolerantly: the omitted `conversation`/`ui`/`metadata`
  sections are materialized with defaults, counters are derived from the records, and the
  fixture file itself is not rewritten by a load.
- Unknown top-level sections and unknown record fields survive normalization and a round
  trip, so a newer state file is not silently pruned.
- Log retention behaves exactly as `docs/log-retention.md` describes: 500 newest entries,
  oldest-first eviction, chronological retained window, `counters.logs` computed before
  eviction so identifiers stay monotonic, and kernel appends after a pruned legacy load
  continue from the high-water mark (`L801` after a 800-log legacy file).
- Retention is independent of record pruning: `Prune` removing an issue/worker/project
  leaves existing log entries in place, including logs that reference records which no
  longer exist.
- Streamed harness output is not persisted: `token`, `text_delta`, `content_delta`,
  `message_delta`, `thinking_delta`, `stream_chunk`, `response`, `heartbeat` and
  turn/tool lifecycle events produce no log entries; only matching failure/exit events
  (`process_exit`, `rpc_parse_error`) become `harness`-sourced logs.
- `Store#compact!` persists the retention bound immediately, returns `false` for a state
  that is already bounded, and is a no-op when the file does not exist.

## Sharp edges and probable bugs (asserted as-is, not fixed)

1. **Temporary file name is only process-scoped.** `Store#save_unlocked` uses
   `"#{path}.tmp.#{$$}"`. Two `Store` instances saving whole snapshots concurrently inside
   one process therefore share one temporary path: one writer's `ensure File.delete` can
   remove the other writer's in-flight temp file, and the loser raises
   `Errno::ENOENT ... rb_file_s_rename`. Reproduced reliably with two instances × 60
   save iterations in threads. The suite now asserts the deterministic consequence
   (`test_temp_file_name_is_shared_per_process_so_a_save_clobbers_another_writers_temp_file`)
   and exercises concurrency only in configurations that are safe today (single writer +
   readers, or many threads through one `Store` instance, whose `Mutex` serializes saves).
   A per-instance/per-thread suffix (or `Tempfile` in the same directory) would fix it.
2. **No cross-instance or cross-process advisory lock.** There is `flock` usage in
   `lib/meringue/harness/transport_ownership.rb`, but none in `State::Store`. Whole-snapshot
   `Store#save` is last-writer-wins: a stale snapshot from instance B overwrites orchestration
   records saved by instance A (`test_whole_snapshot_saves_are_last_writer_wins_for_orchestration_records`).
   Only the read-modify-write entry points re-read the newest snapshot first
   (`save_log_buffer`, `save_agent_workspace`) and `save(preserve_log_buffer: true)` merges the
   persisted conversation buffer by message id, so those paths do not lose other writers' data.
3. **`save_log_buffer` replaces the whole buffer.** Callers must pass the complete message
   list. Racing read-modify-write callers can therefore drop each other's newest messages
   even through one `Store` instance. Invariants that do hold: no duplicate ids, already
   persisted messages are not lost, orchestration sections are untouched.
4. **Corrupt state files raise instead of degrading.** `Store#load` propagates
   `JSON::ParserError` for truncated/garbage files (an empty file included), and a valid
   but non-object document (e.g. `[]`) raises `TypeError: no implicit conversion of String
   into Integer` from normalization. There is no quarantine/backup-and-reset path. Note that
   `Store#save` *does* tolerate a corrupt file on disk: `merge_persisted_log_buffer!`
   rescues `JSON::ParserError`, so a save repairs the file.
5. **`Compactor.compact!` is convergent but not idempotent in one pass.** The
   `"… [truncated N bytes …]"` marker counts toward the byte limit, so a value that was
   just compacted is still over its limit and is re-trimmed on the next pass (`5000 →
   4056 → 4054 → 4054`, `changed` reports `true, true, true, false, ...`). The marker never
   accumulates and the value stabilizes after three passes, but `compact!` reporting
   `changed == true` for an already compacted state causes extra `Store#compact!` writes.
6. **Array elements are compacted using the array's key, not a per-element key.** A long
   string inside `"line" => [...]` is trimmed at 4KB because the key `line` has a limit,
   while an unknown array key keeps the 100KB default. This is consistent but easy to
   misread as per-string limits.
7. **Normalization does not validate vocabularies.** `LIFECYCLE_STATUSES`,
   `QUESTION_STATUSES`, `LOG_LEVELS` and `LOG_SOURCE_TYPES` exist, but
   `Models.ensure_state_shape!` accepts and preserves out-of-vocabulary values such as an
   agent status of `sleeping` or a log level of `trace`. Validation only happens on the write
   path in `Kernel::Engine#append_log` (which raises `ArgumentError` for an unknown level or
   source type). Loading a hand-edited state cannot surface such a value as an error.
8. **An unknown future `schema_version` is loaded as-is.** `ensure_state_shape!` only fills
   in a missing version, so a `schema_version: 99` file is read with version 1 semantics
   rather than being rejected or migrated.
9. **Rejected kernel commands still append durable logs.** A rejected `AddProject`
   ("Project is already registered.") consumes a log id and occupies a slot in the retained
   window. Noticed while porting the benchmark's append assertions.

## Doc follow-up (outside this slice's writable paths)

`docs/log-retention.md` ends with "Reproducing the measurement" and tells the reader to run
`ruby scripts/benchmark_log_retention.rb`. That script was deleted in this slice and its
correctness assertions now live in `test/integration/state/log_retention_test.rb`
(boundary, legacy load, bounded save/reload, monotonic ids, plus a bounded size/timing
check). This slice may not modify `docs/`, so that section still points at a removed file
and should be updated to reference `rake test` /
`ruby -Ilib -Itest test/integration/state/log_retention_test.rb`.
