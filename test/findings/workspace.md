# Workspace / worktree slice findings

Scope: `lib/meringue/workspace/*.rb` (manager, path_resolver, controller,
launch_command, editor_launcher, terminal_manager, terminal_session,
terminal_screen), `lib/meringue/tui/workspace_health.rb`, and the workspace
strategy selection in `Kernel::Engine#resolve_worker_workspace`.

No production code was changed. Where current behavior looked wrong or
surprising, the tests assert what the code does today and the behavior is
recorded here.

## Real bugs / rough edges found (tests pin current behavior)

1. ~~**A released worker branch is deleted and recreated on re-allocation, so
   commits that only lived on it stop being reachable.**~~ **Fixed.**
   `remove_orphaned_owned_branch` no longer force-deletes: it deletes a
   `meringue/` branch only when the branch is not registered to a worktree *and*
   `git rev-list --count <branch> --not --exclude=<branch> --all` proves it
   carries no commit that exists nowhere else, and it prefers `git branch -d`
   (which refuses an unmerged branch) before the verified `-D`. A branch with
   commits is kept and checked back out by the next allocation, so an
   interrupted worker's commits stay reachable *and* stay in its worktree.
   `release_worker_workspace(delete_branch: true)` follows the same rule.
   Tests: `WorkspaceManagerCollisionTest#test_reallocating_after_release_keeps_the_branch_and_its_commits`,
   `#test_reallocating_after_release_recreates_an_empty_branch_from_origin_main`,
   `#test_release_with_delete_branch_keeps_a_branch_that_carries_commits`, and
   `WorkspaceManagerFailedAllocationCleanupTest#test_cleanup_keeps_a_branch_that_carries_commits_and_says_why`.

2. **`Workspace::PathResolver` raises `ArgumentError` on a path containing a
   null byte instead of returning a rejected result.** `absolute_path` rescues
   `ArgumentError` and retries `File.expand_path`, which raises again, so the
   exception escapes into the render/input loop that every other unusable path
   is reported through. Test:
   `WorkspacePathResolverTest#test_null_byte_paths_raise_argument_error_today`.
   Suggested fix: treat a value containing `"\0"` as unusable and return the
   normal `unavailable` result.

3. **`TUI::WorkspaceHealth` has no dirty/clean worktree awareness.** It reports a
   *missing* worktree, a missing harness process, and a missing session file, but
   a worktree full of uncommitted work is indistinguishable from a clean one, so
   nothing warns a user before they act on a worker with unsaved changes. Tests:
   `WorkspaceHealthTest#test_dirty_worktree_is_still_considered_healthy` and
   `#test_missing_worktree_is_reported_without_losing_delivery_metadata`.
   The docs section "dirty/clean/missing worktree detection" is therefore only
   satisfied for *missing*; dirty/clean is asserted as "both report no notice".

4. **`TerminalSession.new` with a non-positive `terminal_buffer_bytes` does not
   raise; it silently degrades.** `normalize_buffer_size` raises `ArgumentError`,
   but the constructor's `rescue ArgumentError` converts it into
   `configuration_error` and leaves `@max_buffer_bytes` as `nil`, so the object
   is only usable for producing a `rejected` start result. Test:
   `WorkspaceTerminalSessionTest#test_non_positive_buffer_size_degrades_to_a_configuration_error`.
   This is a reasonable "never crash the TUI" choice, but the `nil` buffer size
   would raise inside `trim_buffer!` if output ever reached it.

5. **`Manager#release_worker_workspace` force-removes the worktree directory.**
   `git worktree remove --force` discards *uncommitted* changes in the worktree.
   Committed work survives on the branch (see finding 1 for the follow-on
   problem). Refused releases (not a Hash, `created == false`, non-`git_worktree`
   strategy, `project_root` strategy) delete nothing, which is what protects a
   user's project checkout. Tests in `WorkspaceManagerCollisionTest`:
   `#test_release_removes_the_worktree_but_keeps_the_branch_and_its_commits`,
   `#test_release_refuses_records_it_does_not_own`,
   `#test_release_is_idempotent_after_the_worktree_is_gone`.

## Confirmed intended behavior (now covered)

- **Human-facing branch names.** `plan_worker_workspace` slugifies the task
  title, strips `P<n>`/`P<n>-I<n>`/`P<n>-I<n>-W<n>` and `H<n>`/`Q<n>` tokens,
  truncates to 48 characters, and appends a deterministic 8-hex-character digest
  of (project root, project id, issue id, agent id, slug). The branch is
  `meringue/<slug>-<suffix>`; no Meringue/Pi id text appears in it. Same worker →
  same name; different worker → different suffix. Titles with no usable words
  fall back to `task`.
- **Worktrees are based on `origin/main`.** `preferred_base_ref` tries
  `origin/main`, `origin/master`, `main`, `master`, `HEAD`. A throwaway repo with
  an advanced local `main` proves the worktree HEAD equals the `origin/main` sha.
- **Project root inside the git root.** `workspace_path` becomes
  `<worktree_root>/<relative path>` and `project_relative_path` records the
  relative segment; `workspace_root_path` / `worktree_root_path` stay at the
  worktree root.
- **Collision handling.** An existing worktree for the same branch is *adopted*
  (`"adopted" => true`) and its uncommitted files are untouched. A non-empty
  foreign directory at the planned path is left alone and allocation moves to
  `<branch>-2` / `<path>-2`. An empty owned directory is reclaimed for the
  preferred name. A branch checked out in another worktree also forces `-2` and
  never disturbs the other worktree.
- **Fallback strategies.** Outside a git repository (or with a missing project
  root) the manager returns `strategy: "project_root"` with
  `fallback_reason: "project root is not inside a git repository"` and creates
  nothing (not even the workspaces root). `Kernel::Engine#resolve_worker_workspace`
  classifies an explicitly requested directory as `dedicated_directory`, or
  `project_root` when it equals the project root, records
  `"workspace_path must be an existing directory"` when it is missing, and falls
  back to the project root cwd when the manager could not create a worktree
  (including the timeout case, where the allocation errors are surfaced).
- **Timeout handling.** `git worktree add` runs under two independent bounds: a
  stall bound (no output at all for `worktree_stall_timeout` seconds) and an
  absolute ceiling (`worktree_checkout_timeout`), which also bounds one whole
  `allocate_worker_workspace` call including its plumbing commands and retried
  candidates. Short plumbing keeps the 60s `git_command_timeout`. A killed
  command produces `timed_out: true`, `timeout_seconds`, the captured output, a
  `failure_kind` (`command_stalled` / `command_timed_out`), a `recovery`
  classification (`retry` for a stall, `resume` for a blown ceiling), a
  `cleanup` record, and no leftover worktree or branch. Tests:
  `WorkspaceManagerCheckoutTimeoutTest`.
- **Cleanup after a killed `git worktree add`.** git holds
  `.git/worktrees/<name>/locked` for the whole checkout, so an interrupted add
  leaves a *locked* registration that `git worktree remove --force` refuses with
  exit 128 and `git worktree prune` skips. Cleanup unlocks, force-removes twice,
  deletes the owned directory, prunes, verifies the registration is gone, and
  reports anything it could not do safely in `cleanup["warnings"]` (which the
  kernel logs as a warning). Tests:
  `WorkspaceManagerFailedAllocationCleanupTest`.
- **Path resolution.** Candidate order is `workspace_path`, harness `cwd`, plan
  `workspace_path`, `workspace_root_path`, `worktree_root_path`; the first
  existing directory wins; a fallback sets `recovered: true` plus a "Using X
  because the recorded workspace Y is missing." message. Relative candidates
  resolve against the recorded project/git root and *never* against the process
  cwd (this is what used to produce nested `.meringue/workspaces/...` paths).
  `~` expands via `HOME`. Missing, blank, and non-directory values are refused
  with actionable messages, and refusals omit the `"path"` key entirely (callers
  must use `path_for` or `resolution["path"]`, not `fetch("path")`).
- **Command construction is never shelled out.** `LaunchCommand` splits strings
  with shell-style quoting only; `>`/`;`/`|` become ordinary arguments. Empty
  commands, non-string members, empty arguments, and null bytes are rejected with
  labeled messages. `display` shell-escapes, so paths with spaces round-trip as
  `/tmp/work\ space/project`.
- **Editor/terminal launches assert on the built command.** The editor spawn is
  `[resolved_executable, *command_args, *editor_args]` with
  `chdir: <workspace>, in/out/err: /dev/null, pgroup: true`; the terminal PTY
  spawn is `[resolved_shell, *shell_args]` with `chdir: <workspace>` and an
  environment where every `PI_*` variable is scrubbed to `nil` and
  `TERM`/`COLORTERM`/`MERINGUE_WORKSPACE` are set. Missing executables, invalid
  configuration, and missing workspaces are reported without spawning anything.
- **Screen model.** Incomplete UTF-8 sequences are held across chunk boundaries
  (byte-at-a-time feeding of `λ→🎉 ok` renders intact), split escape sequences
  survive chunking, wrapping scrolls the oldest row off the top, `ESC ( B` +
  `ESC [ m` no longer leaks a literal `B`, OSC payloads are not content, SGR
  styles are preserved per segment, `styled_lines` can be rendered repeatedly
  (and mutated by a caller) without corrupting the screen, and resize clamps the
  cursor while bumping `revision` only when something actually changed.
- **Scrollback lives on the session, not the screen.** `TerminalScreen` discards
  scrolled-off rows; the retained scrollback is `TerminalSession#transcript`,
  bounded by `terminal_buffer_bytes` (oldest bytes trimmed first).
  `drain_output` hands out pending bytes exactly once and leaves the transcript
  intact for redraws.

## Benchmark script replacement

`scripts/benchmark_workspace_scroll.rb` was deleted. It printed cold/warm frame
times for TUI-level wheel scrolling and asserted nothing, and reproducing it
required driving `TUI::App`'s private compose/handle_key/render path with a
stubbed session service.

It is replaced by `test/integration/workspace/terminal_scroll_performance_test.rb`,
which keeps the properties that made scrolling smooth, at the layer this slice
owns:

- feeding 3,000 colorized lines in 50-line chunks into a 45x140 screen, then
  running 200 `lines` + `styled_lines` render frames, each within a 10 s bound
  (measured ≈90 ms and ≈75 ms locally, so the bound is ~100x headroom);
- 60 resize+render steps over a 1,000-line stream within the same bound;
- proof that rendering an unchanged screen does **not** change `revision`, which
  is the cache key renderers use to avoid re-laying out a frame while scrolling.

TUI-level scroll-frame timing (pane row composition, wheel/PageUp handling) is
left to the TUI slice, which owns `TUI::Panes::AgentWorkspacePane`.

Both doc follow-ups are done: `docs/agent_workspace_integration.md` step 11 now
points at `test/integration/workspace/terminal_scroll_performance_test.rb`, and the
"Manual integration verification" preamble now starts with `rake test` instead of
claiming that repository policy forbids automated test files.

## Test hermeticity notes

- Every git test builds a throwaway repo inside `Dir.mktmpdir` with a local bare
  `origin`, an isolated `HOME`/`GIT_CONFIG_GLOBAL`, and fixed author/committer
  identity. No git command runs against the real meringue checkout.
- The manager is always constructed with `root_path: <tmpdir>/workspaces`, so
  `owned_workspace_path?` logic and all cleanup stay inside the temp directory
  and `~/.meringue` is never touched.
- Shells, editors, and PTYs are never really launched: `WorkspaceSupport`
  provides a recording `spawn` lambda, a recording PTY double that raises after
  capturing the arguments, and a `TerminalSession` double. `Kernel::Engine` is
  built with a temp state path and temp config path and is only asked to resolve
  a workspace (no state is loaded or saved).
