# kernel_core slice findings

Scope: `Meringue::Kernel::Engine` project/issue/state commands (`AddProject`, `CreateIssue`,
`ModifyIssue`, `GetInfo`, `ListAll`) plus the cross-cutting `KernelCommandResult` and log
contract, exercised through the public `Engine#apply` / `#apply_all` / `#list_all` API against a
tmp-dir `State::Store`.

Tests:

- `test/integration/kernel_core/add_project_test.rb`
- `test/integration/kernel_core/create_issue_test.rb`
- `test/integration/kernel_core/modify_issue_test.rb`
- `test/integration/kernel_core/get_info_test.rb`
- `test/integration/kernel_core/list_all_test.rb`
- `test/integration/kernel_core/command_contract_test.rb`
- `test/support/kernel_core_support.rb`

All tests assert **current actual behaviour**. No production code was changed. The notes below
record the gaps and surprises found while writing them.

## 1. `GetInfo` is specified but not implemented (real gap)

`AGENTS.md` ("`GetInfo(TargetID) -> Project | Issue | Agent | Question`") and
`docs/head_agent_kernel_commands.md` ("### GetInfo") both document the command, and the docs even
show the payload/example. `Engine#dispatch_command` has no `GetInfo` branch and `COMMAND_ALIASES`
has no `get_info` entry, so every `GetInfo` command is rejected:

```
status: "rejected", message: "Unknown kernel command: GetInfo", errors: ["unknown_command"]
```

Consequences:

- A head that follows the documented command reference gets a rejection plus a warning log line.
- The rejection is identical for a valid target id (`P1`, `P1-I1`, `H1`, `Q1`) and for an unknown
  one (`P99`), so there is no way to distinguish "unimplemented" from "not found".
- Detail lookups today only work by pulling the whole snapshot (`GetState` / `ListAll`) or
  `ListQuestions` and filtering client-side.

`get_info_test.rb` pins the rejection and also proves the snapshot fallback path returns the
project/issue/agent/question detail that `GetInfo` was supposed to return.

## 2. "Rejected commands do not mutate state" is true for domain records only

`rejected_result` / `failed_result` call `record_result_log`, which appends a log entry, bumps
`counters.logs`, updates `metadata.updated_at`, and saves. So a rejected command *does* write to
the persisted state file. What it never touches is the domain data: `projects`, `issues`,
`agents`, `questions`, and the id counters (`projects`, `heads`, `questions`,
`issues_by_project`, `workers_by_issue`).

`KernelCoreSupport#domain_snapshot` / `#domain_counters` encode that boundary, and
`command_contract_test.rb` walks 17 different rejected commands asserting the domain snapshot and
id counters are byte-identical afterwards (reloaded from the persisted JSON) while exactly one
`warning` log entry is appended.

## 3. `ListAll` returns the raw state snapshot, not an aggregated AgentTree

`AGENTS.md` says `ListAll() -> AgentTree` "should include all projects, issues, workers, active
heads, pending questions, and status counts". The implementation returns `store.load`, i.e. the
persisted state hash (`projects`, `issues`, `agents`, `questions`, `logs`, `conversation`, `ui`,
`counters`, `metadata`, `schema_version`).

- Nesting is implicit: consumers must join on `issue.project_id`, `issue.parent_issue_id`,
  `agent.issue_id` / `agent.project_id`, and `issue.agent_ids`.
- There are no aggregate status-count fields. `counters` holds id high-water marks, not counts of
  `working` / `queued` / `completed` records; callers must tally statuses themselves.
- Head agents carry `project_id`/`issue_id` = `nil`, so heads only nest under the tree root.

`list_all_test.rb` asserts the shape that exists today, including the derived-status tally done
in the test rather than by the kernel.

## 4. Project status is never "queued"/"idle" and only worsens on child updates

`AddProject` hardcodes `status: "working"` for a brand-new project that has no issues at all.
`update_project_status_from_issues!` (invoked by `ModifyIssue`) only recomputes to `completed`,
`errored`, `blocked`, or `working`; when every child issue is merely `queued` or `idle` it keeps
the previous project status. So a project registered and left alone reads as `working`, and a
project whose only queued issue never runs stays `working` too.

Captured in `list_all_test.rb#test_list_all_reports_derived_status_counts` (`P2` has one `queued`
issue and reports `working`) and `modify_issue_test.rb#test_modify_issue_project_status_reflects_the_worst_child_status`.

## 5. Mixed timestamp representations inside one state file

`Engine#timestamp` is `Time.now.getlocal.iso8601` (local offset, e.g.
`2026-07-29T11:58:28-04:00`), while `State::Models.ensure_state_shape!` defaults `now:` to
`Time.now.utc.iso8601` (`2026-07-29T15:58:28Z`). A single persisted file therefore mixes both:
`metadata.created_at` is UTC while `projects[].created_at` / `issues[].updated_at` carry a local
offset. Everything still parses with `Time.iso8601`, so the tests assert "parses as ISO8601"
rather than a `Z` suffix, but string comparison of timestamps across records is unsafe and
`iso8601` output is machine-local.

Related: the timestamp resolution is one second, so `created_at == updated_at` for records
created and modified within the same second. `modify_issue_test.rb` proves the `updated_at` bump
by rewriting the persisted timestamp to `2000-01-01T00:00:00Z` first instead of sleeping.

## 6. Ids are monotonic and never reclaimed by `Kill`

`Kill` removes project/issue records outright (`remove_issue_bundles_and_agents!`) but leaves
`counters.projects` / `counters.issues_by_project` untouched, so the next `AddProject` after
killing `P1` returns `P2`, and the next `CreateIssue` after killing `P1-I1` returns `P1-I3`.
Compaction of ids is an explicit, separate `Recount` operation. Asserted in
`add_project_test.rb` and `create_issue_test.rb`.

## 7. `ModifyIssue` field semantics are key-presence based, except for status

- `title` / `description` / `parent_issue_id` are applied whenever the key is present, so
  `"description" => ""` counts as a change and `"parent_issue_id" => ""` clears the parent.
- `status` is applied only when non-blank; `"status" => "   "` is silently ignored and is not
  listed in `changed_fields`.
- A payload with only `issue_id` is accepted, logs `Modified issue P1-I1: no fields changed`, and
  still bumps `issue.updated_at`, `project.updated_at`, and `metadata.updated_at`.

## 8. `AddProject` duplicate detection is expanded-path equality only

Duplicates are detected by comparing `File.expand_path` of the stored `root_path`, so
`/tmp/app` and `/tmp/app/.` collide (asserted) while symlinked or case-variant paths pointing at
the same directory would not. A duplicate registration is rejected with `project_already_exists`
and, notably, an alternative `name` in the duplicate payload is discarded rather than treated as
a rename.

## Hermeticity notes

- Every engine is constructed with a `State::Store` inside `Dir.mktmpdir`, a tmp `config_path`,
  and a tmp `Workspace::Manager` root. `~/.meringue` is never read or written (verified by
  checking `~/.meringue/config.toml` is unchanged across a full run).
- `SpawnWorker` coverage passes an explicit `workspace_path`, which takes the
  `requested_workspace_path` branch of `resolve_worker_workspace` and avoids `git` subprocesses
  entirely; the harness is `Harness::FakeClient`.
- Head coverage uses a local `RecordingHeadRunner` stub, so no Pi/Claude process is ever started.
  `mark_worker_completed` is deliberately not exercised here because its delivery-PR verification
  path can shell out to `git`/`gh`.
