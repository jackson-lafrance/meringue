# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"

require_relative "../delivery_artifact_policy"
require_relative "profile"
require_relative "worktree_provider"

module Meringue
  module Workspace
    class Manager
      DEFAULT_ROOT = File.expand_path("~/.meringue/workspaces")
      # Budget for the short git plumbing commands allocation runs: rev-parse, show-ref,
      # worktree list. None of them touch a working tree, so 60s is already generous and a
      # command that spends longer than that reading refs really is stuck.
      DEFAULT_COMMAND_TIMEOUT = 60
      # `git worktree add` is not plumbing: it checks the whole tree out. A large monorepo is
      # hundreds of thousands of files, which is minutes of honest work on a warm disk and longer
      # on a cold one, so one flat 60s budget for both `git rev-parse` and a half-million-file
      # checkout is what turned a slow provisioning into a dead worker. The checkout is therefore
      # bounded by two independent
      # limits instead of one:
      #
      #   * DEFAULT_CHECKOUT_STALL_TIMEOUT - the real bound. Git reports checkout progress on
      #     stderr at least once a second (progress.c drives the display from a 1s SIGALRM) and
      #     keeps doing so when stderr is a pipe, so "no output at all for two minutes" means the
      #     command is stuck (an fsmonitor daemon that never answers, a credential prompt, a lock
      #     it will never get), not that it is slow. That case is still killed quickly.
      #   * DEFAULT_CHECKOUT_TIMEOUT - the backstop. A command that keeps printing progress
      #     forever is still killed, so the stall detector can never degrade into a hang.
      DEFAULT_CHECKOUT_STALL_TIMEOUT = 120
      DEFAULT_CHECKOUT_TIMEOUT = 1800
      # Cleanup after a failed attempt still has to delete a partially written tree, which is
      # slow on a monorepo but never interactive.
      DEFAULT_CLEANUP_TIMEOUT = 300
      # How often the watchdog wakes up to compare the clocks. Small enough that a killed command
      # dies promptly, large enough that the poll costs nothing.
      COMMAND_POLL_INTERVAL = 0.1
      # How often a long-running command reports progress to its caller.
      PROGRESS_REPORT_INTERVAL = 15
      READ_CHUNK_BYTES = 64 * 1024
      # Git can emit one checkout-progress record per file and repeat the same failure thousands of
      # times. Keep enough head/tail context to diagnose a failure without retaining an unbounded
      # in-memory transcript or copying hundreds of kilobytes into state and logs.
      DIAGNOSTIC_OUTPUT_LIMIT_BYTES = 16 * 1024
      FAILURE_SUMMARY_LIMIT_BYTES = 2 * 1024
      PROGRESS_DETAIL_LIMIT_BYTES = 1 * 1024
      TERMINATION_GRACE_SECONDS = 1
      # A worker branch/worktree can already exist when a previous attempt was interrupted or when
      # another actor provisioned the same worker concurrently. Reuse it when it is usable, and
      # otherwise fall back to a uniquified branch/path instead of failing the spawn.
      #
      # Candidate names are the task slug plus a deterministic numeric suffix (`-2`, `-3`, ...),
      # so every worker on one task contends for the same sequence. The limit therefore has to
      # cover the number of workers an issue can run at once, not just retries of one worker;
      # `allocation_budget` still bounds how long the search may take.
      ALLOCATION_ATTEMPT_LIMIT = 10
      OWNERSHIP_SCHEMA_VERSION = 1
      OWNERSHIP_DIRECTORY = ".ownership"
      SHARED_READ_ONLY_DIRECTORY = ".shared-read-only"
      SHARED_READ_ONLY_OWNER_KIND = "managed_shared_read_only_checkout"
      COLLISION_ERROR_PATTERN = /already exists|already used by worktree|is already checked out/i
      # How a failed allocation can be recovered. The manager knows git, so it classifies; the
      # kernel owns what to do with a worker in each case.
      #   retry  - transient. Worth another automatic attempt.
      #   resume - real, but not worth burning another long attempt without a human. The worker
      #            stays resumable instead of being errored into a dead end.
      #   none   - deterministic (no git repo, every candidate path occupied). Another identical
      #            attempt would fail identically.
      RECOVERY_RETRY = "retry"
      RECOVERY_RESUME = "resume"
      RECOVERY_NONE = "none"
      # When a project declares no sparse profile, a large bare source still materializes the full
      # tree per isolated worker. To avoid multi-minute provisioning on such sources, Meringue
      # synthesizes a generic root-files-only sparse profile (no project-specific paths) once the
      # packed object count crosses this threshold. The count is read from pack `.idx` footers in
      # O(number-of-packs), so the gate itself never scans every object. Operators can opt out via
      # `[workspace] default_bare_checkout_mode = "full"` or raise/lower the threshold.
      DEFAULT_BARE_SPARSE_OBJECT_THRESHOLD = 1_000_000
      DEFAULT_BARE_CHECKOUT_MODE = "sparse"
      BARE_FULL_CHECKOUT_MODE = "full"
      BARE_DEFAULT_PROFILE_NAME = "bare-default-root"
      # `/*` matches every entry directly under the root; `!/*/` negates all root
      # directories. In non-cone mode the result is root-level files only (README,
      # manifests, etc.) with every subdirectory skipped until the worker expands
      # its working set. The pair is fully generic: it carries no project-specific
      # path and makes zero layout assumptions.
      BARE_DEFAULT_SPARSE_PATTERNS = ["/*", "!/*/"].freeze
      # Some global git configs (a shared developer config among them) enable core.fsmonitor. Git then
      # starts a `git fsmonitor--daemon` for every new worktree and blocks on that daemon's answer
      # before it can read the new index. `git worktree add` runs `git reset --hard` internally, so
      # a daemon that never answers hangs provisioning until the command timeout kills it and the
      # worker spawn fails. Meringue's own plumbing never needs a file-system monitor, so every git
      # command it runs disables one. Git forwards `-c` to child git processes through
      # GIT_CONFIG_PARAMETERS, so the internal `git branch`/`git reset` inherit the setting too.
      GIT_ISOLATION_ARGS = ["-c", "core.fsmonitor=false"].freeze
      # Global git flags that consume the next argv entry, so command_label can skip both.
      GIT_VALUE_FLAGS = %w[-C -c --git-dir --work-tree --namespace --exec-path].freeze
      # Git commands whose meaning needs the word after the subcommand (`worktree add`).
      GIT_SUBCOMMAND_GROUPS = %w[worktree remote submodule stash notes reflog].freeze
      # Git failures that another attempt can plausibly get past: someone else held a lock, or an
      # index/ref lock file survived a crash. Distinct from a collision, which is deterministic.
      TRANSIENT_ERROR_PATTERN = /index\.lock|cannot lock ref|unable to create.*\.lock|another git process|resource temporarily unavailable|file exists/i
      # Git normally reports filesystem exhaustion in stderr and exits 128 rather than surfacing a
      # Ruby exception. Cover the portable errno spelling, the macOS/Linux message, quota failures,
      # and the common Windows wording. This must be checked before generic git-error handling: an
      # immediate retry cannot create space and can make the outage worse.
      DISK_EXHAUSTION_PATTERN = /\bENOSPC\b|no space left on device|disk quota exceeded|not enough space (?:on (?:the )?disk|is available)|disk (?:is )?full/i

      # A command Meringue killed. `reason` separates the two bounds so the caller can say which
      # one fired, and so "stuck" can be retried while "legitimately enormous" is not retried
      # automatically.
      class CommandTimeout < StandardError
        STALLED = "stalled"
        BUDGET = "budget"

        attr_reader :argv, :timeout, :stdout, :stderr, :reason, :elapsed, :diagnostics

        def initialize(argv:, timeout:, stdout:, stderr:, reason: BUDGET, elapsed: nil, diagnostics: nil)
          @argv = argv
          @timeout = timeout
          @stdout = stdout
          @stderr = stderr
          @reason = reason.to_s
          @elapsed = elapsed
          @diagnostics = diagnostics
          super(
            if stalled?
              "command produced no output for #{timeout} seconds: #{argv.join(" ")}"
            else
              "command timed out after #{timeout} seconds: #{argv.join(" ")}"
            end
          )
        end

        def stalled?
          reason == STALLED
        end

        # Human-readable failure for a named command, used in workspace `errors`.
        def describe(label)
          return "#{label} timed out after #{timeout} seconds" unless stalled?

          killed_after = elapsed ? " (killed after #{format("%.1f", elapsed)} seconds)" : ""
          "#{label} stalled: no output for #{timeout} seconds#{killed_after}"
        end
      end

      # Retains a bounded head and tail while counting every byte the child produced. The head says
      # what Git was doing, the tail carries the terminal errno, and the omission marker makes it
      # impossible to mistake the diagnostic for a complete transcript. Output is normalized to
      # UTF-8 at the process boundary so an odd filename cannot make state serialization fail.
      class DiagnosticBuffer
        attr_reader :bytes_seen

        def initialize(limit: nil, on_match: nil)
          @limit = limit && Integer(limit)
          @head_limit = @limit && @limit / 4
          @tail_limit = @limit && @limit - @head_limit
          @on_match = on_match
          @head = +""
          @tail = +""
          @bytes_seen = 0
          @truncated = false
        end

        def <<(chunk)
          raw = chunk.to_s
          @on_match&.call(raw)
          @bytes_seen += raw.bytesize
          text = raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
          if @limit.nil? || (!@truncated && @head.bytesize + text.bytesize <= @limit)
            @head << text
            return self
          end

          unless @truncated
            combined = @head + text
            @head = byteslice(combined, 0, @head_limit)
            @tail = byteslice(combined, [combined.bytesize - @tail_limit, 0].max, @tail_limit)
            @truncated = true
            return self
          end

          @tail << text
          @tail = byteslice(@tail, @tail.bytesize - @tail_limit, @tail_limit) if @tail.bytesize > @tail_limit
          self
        end

        def truncated?
          @truncated
        end

        def to_s
          return @head.dup unless truncated?

          retained = @head.bytesize + @tail.bytesize
          omitted = [bytes_seen - retained, 1].max
          marker = "\n… [#{omitted} output bytes omitted] …\n"
          tail_budget = [@limit - @head.bytesize - marker.bytesize, 0].max
          @head + marker + byteslice(@tail, [@tail.bytesize - tail_budget, 0].max, tail_budget)
        end

        private

        def byteslice(value, start, length)
          value.to_s.byteslice(start, length).to_s.force_encoding(Encoding::UTF_8).scrub
        end
      end

      # Records when a running command last wrote anything, so the watchdog can tell "slow but
      # progressing" from "stuck" without parsing git's output format.
      class OutputMonitor
        def initialize(now: Manager.monotonic_now)
          @mutex = Mutex.new
          @last_at = now
          @last_line = nil
        end

        def record(chunk)
          text = chunk.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
          line = text.split(/[\r\n]+/).reject { |part| part.strip.empty? }.last
          @mutex.synchronize do
            @last_at = Manager.monotonic_now
            @last_line = line if line
            scan = @scan_tail.to_s + text
            @disk_exhausted ||= scan.match?(Manager::DISK_EXHAUSTION_PATTERN)
            @scan_tail = scan.byteslice([scan.bytesize - 256, 0].max, 256).to_s.force_encoding(Encoding::UTF_8).scrub
          end
        end

        def last_at
          @mutex.synchronize { @last_at }
        end

        def last_line
          @mutex.synchronize { @last_line }
        end

        def disk_exhausted?
          @mutex.synchronize { !!@disk_exhausted }
        end
      end

      def self.monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # `[workspace]` in ~/.meringue/config.toml can widen or tighten every bound per machine,
      # because "how long may a checkout take" is a property of the repository and the disk, not
      # of Meringue.
      def self.from_config(config, root_path: DEFAULT_ROOT)
        section = config.respond_to?(:section) ? config.section("workspace") : {}
        section = {} unless section.is_a?(Hash)
        new(
          root_path: section.fetch("root_path", root_path),
          command_timeout: section.fetch("git_command_timeout", DEFAULT_COMMAND_TIMEOUT),
          checkout_stall_timeout: section.fetch("worktree_stall_timeout", DEFAULT_CHECKOUT_STALL_TIMEOUT),
          checkout_timeout: section.fetch("worktree_checkout_timeout", DEFAULT_CHECKOUT_TIMEOUT),
          bare_sparse_object_threshold: section.fetch("bare_sparse_object_threshold", DEFAULT_BARE_SPARSE_OBJECT_THRESHOLD),
          default_bare_checkout_mode: section.fetch("default_bare_checkout_mode", DEFAULT_BARE_CHECKOUT_MODE),
          worktree_provider: section.fetch("worktree_provider", WorktreeProvider::DEFAULT_KIND),
          worktree_provider_fallback: section.fetch("worktree_provider_fallback", WorktreeProvider::DEFAULT_FALLBACK),
          worktree_provider_command: section.fetch("worktree_provider_command", nil)
        )
      end

      attr_reader :root_path, :command_timeout, :checkout_stall_timeout, :checkout_timeout, :cleanup_timeout,
                  :progress_interval, :bare_sparse_object_threshold, :default_bare_checkout_mode,
                  :worktree_provider, :worktree_provider_fallback

      def initialize(root_path: DEFAULT_ROOT, command_timeout: DEFAULT_COMMAND_TIMEOUT,
                     checkout_stall_timeout: DEFAULT_CHECKOUT_STALL_TIMEOUT,
                     checkout_timeout: DEFAULT_CHECKOUT_TIMEOUT,
                     cleanup_timeout: DEFAULT_CLEANUP_TIMEOUT,
                     progress_interval: PROGRESS_REPORT_INTERVAL,
                     bare_sparse_object_threshold: DEFAULT_BARE_SPARSE_OBJECT_THRESHOLD,
                     default_bare_checkout_mode: DEFAULT_BARE_CHECKOUT_MODE,
                     worktree_provider: WorktreeProvider::DEFAULT_KIND,
                     worktree_provider_fallback: WorktreeProvider::DEFAULT_FALLBACK,
                     worktree_provider_command: nil)
        @root_path = File.expand_path(root_path)
        @command_timeout = positive_float(command_timeout, DEFAULT_COMMAND_TIMEOUT)
        @checkout_stall_timeout = positive_float(checkout_stall_timeout, DEFAULT_CHECKOUT_STALL_TIMEOUT)
        @checkout_timeout = positive_float(checkout_timeout, DEFAULT_CHECKOUT_TIMEOUT)
        # A stall bound above the absolute bound could never fire, which would silently remove the
        # only limit that catches a genuinely stuck command.
        @checkout_stall_timeout = @checkout_timeout if @checkout_stall_timeout > @checkout_timeout
        @cleanup_timeout = positive_float(cleanup_timeout, DEFAULT_CLEANUP_TIMEOUT)
        @progress_interval = positive_float(progress_interval, PROGRESS_REPORT_INTERVAL)
        @bare_sparse_object_threshold = positive_integer(bare_sparse_object_threshold, DEFAULT_BARE_SPARSE_OBJECT_THRESHOLD)
        @default_bare_checkout_mode = normalize_bare_checkout_mode(default_bare_checkout_mode)
        @worktree_provider = WorktreeProvider.build(kind: worktree_provider, command: worktree_provider_command)
        @worktree_provider_fallback = WorktreeProvider.normalize_fallback(worktree_provider_fallback)
        @worktree_provider_command = WorktreeProvider.command_argv(worktree_provider_command)
        # The large-bare determination reads pack idx footers once per bare source and is reused
        # across plan/allocate calls, so a busy provisioning loop never re-runs count-objects.
        @large_bare_source_cache = {}
      end

      # Hard ceiling on one allocate_worker_workspace call, including every retried candidate and
      # every plumbing command. Provisioning can be slow; it can never be unbounded.
      def allocation_budget
        checkout_timeout
      end

      def plan_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil, profile: nil,
                                 repository: nil)
        profile = resolve_provisioning_profile(project_root, profile, repository: repository)
        safe_project_name = project_slug(File.basename(File.expand_path(project_root))) || "project"
        safe_task_name = DeliveryArtifactPolicy.slug(task_title)
        workspace_name = safe_task_name
        branch = workspace_name
        workspace_path = default_workspace_path(root_path, safe_project_name, workspace_name)
        if profile&.custom_path_template?
          expanded = profile.expand_path(root: root_path, project_slug: safe_project_name,
                                         task_slug: safe_task_name)
          workspace_path = expanded || workspace_path
        end

        plan = {
          "strategy" => "git_worktree",
          "project_root" => File.expand_path(project_root),
          "workspace_path" => workspace_path,
          "workspace_branch" => branch,
          "workspace_owner_id" => agent_id.to_s,
          "requested_worktree_provider" => worktree_provider.kind,
          "worktree_provider" => worktree_provider.kind,
          "created" => false
        }
        attach_profile_metadata(plan, profile)
      end

      # Resolve a clean main/master checkout that investigation-only workers may share. A normal
      # registered checkout is discovery-only. A bare registered repository has no executable
      # working tree of its own, so when no suitable linked checkout exists Meringue creates one
      # deterministic, manager-owned cache under +root_path+. The cache is protected by a
      # cross-process lock while it is created or recovered and is retained across worker pruning
      # so later concurrent readers pay the checkout cost only once.
      def shared_read_only_checkout(project_root:)
        project_path = canonical_path(project_root)
        repository = repository_context(project_path)
        return reuse_outcome(false, "project_is_not_a_git_repository") unless repository

        existing = discover_shared_read_only_checkout(project_path, repository)
        return existing if existing.fetch("strategy", nil) == "shared_checkout"
        return existing unless repository.fetch("bare")

        provision_managed_shared_read_only_checkout(project_path, repository)
      rescue CommandTimeout => e
        reuse_outcome(false, "shared_checkout_discovery_timed_out", error: e.message)
      rescue StandardError => e
        reuse_outcome(false, "shared_checkout_discovery_error", error: e.message)
      end

      # `progress` is an optional callable invoked (at most every PROGRESS_REPORT_INTERVAL
      # seconds) while a long command is still running, so a caller can tell the user that a
      # checkout is working rather than hung.
      def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil, progress: nil,
                                    unavailable_paths: [], profile: nil)
        plan = nil
        set_allocation_deadline!(self.class.monotonic_now + allocation_budget)
        project_path = canonical_path(project_root)
        # Resolve the repository once and reuse it for both profile resolution and
        # the rest of provisioning, so the allocation budget is not spent on a
        # second `git rev-parse` pass before `git worktree add` runs.
        repository = repository_context(project_path)
        profile = resolve_provisioning_profile(project_root, profile, repository: repository)
        plan = plan_worker_workspace(
          project_root: project_root,
          project_id: project_id,
          issue_id: issue_id,
          agent_id: agent_id,
          task_title: task_title,
          profile: profile,
          repository: repository
        )
        plan["project_root"] = project_path
        return failed_workspace(plan, ["isolated workspace unavailable: project root is not inside a git repository"], failure_kind: "version_control_backend_unavailable", recovery: RECOVERY_RESUME) unless repository

        git_root = repository.fetch("git_root")
        worktree_root = File.expand_path(plan.fetch("workspace_path"))
        relative_project_path = repository.fetch("bare") ? "." : relative_path(project_path, git_root)
        base_ref = preferred_base_ref(git_root)
        return failed_workspace(plan, ["could not find a git base ref for worker workspace"], git_root: git_root, worktree_root: worktree_root) unless base_ref

        errors = []
        last_failure = nil
        candidate_branch = plan.fetch("workspace_branch")
        candidate_created_branch = false
        candidate_owned_attempt = false
        ALLOCATION_ATTEMPT_LIMIT.times do |attempt|
          candidate = candidate_allocation(plan, attempt)
          worktree_root = candidate.fetch("worktree_root")
          candidate_branch = candidate.fetch("branch")
          if Array(unavailable_paths).any? { |path| paths_overlap?(worktree_root, path) }
            errors << "worker worktree candidate is unavailable: #{worktree_root}"
            last_failure = {
              "failure_kind" => "workspace_collision",
              "recovery" => RECOVERY_RETRY,
              "retry" => true
            }
            next
          end
          candidate_created_branch = false
          candidate_owned_attempt = false
          attempt_started = lambda do |details|
            candidate_created_branch = details.fetch("created_branch", false)
            candidate_owned_attempt = true
          end
          outcome = allocate_candidate_worktree(
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: candidate_branch,
            worktree_root: worktree_root,
            owner: workspace_owner(plan, git_root: git_root, branch: candidate_branch, worktree_root: worktree_root),
            progress: progress,
            profile: profile,
            attempt_started: attempt_started
          )
          workspace = outcome.fetch("workspace", nil)
          return workspace if workspace

          errors.concat(Array(outcome.fetch("errors", [])))
          last_failure = outcome
          break unless outcome.fetch("retry", false)
        end

        failed_workspace(
          plan,
          errors,
          git_root: git_root,
          worktree_root: worktree_root,
          base_ref: base_ref,
          stdout: last_failure && last_failure["stdout"],
          stderr: last_failure && last_failure["stderr"],
          stdout_bytes: last_failure && last_failure["stdout_bytes"],
          stderr_bytes: last_failure && last_failure["stderr_bytes"],
          diagnostics_truncated: last_failure && last_failure["diagnostics_truncated"],
          exit_status: last_failure && last_failure["exit_status"],
          timed_out: last_failure && last_failure["timed_out"],
          timeout_seconds: last_failure && last_failure["timeout_seconds"],
          failure_kind: (last_failure && last_failure["failure_kind"]) || "worktree_unavailable",
          recovery: (last_failure && last_failure["recovery"]) || RECOVERY_NONE,
          cleanup: last_failure && last_failure["cleanup"]
        )
      rescue CommandTimeout => e
        # Cleanup must not inherit the exhausted allocation budget, or it would be killed on its
        # first command and leave exactly the mess it exists to remove.
        clear_allocation_deadline!
        timeout_disk_exhausted = disk_exhaustion_output?(e.stderr) || disk_exhaustion_output?(e.stdout) ||
                                 (e.diagnostics && e.diagnostics["disk_exhausted"])
        cleanup = if defined?(candidate_owned_attempt) && candidate_owned_attempt
                    cleanup_incomplete_allocation(
                      git_root: defined?(git_root) && git_root,
                      worktree_root: defined?(worktree_root) && worktree_root,
                      branch: (defined?(candidate_branch) && candidate_branch) || (plan && plan["workspace_branch"]),
                      created_branch: defined?(candidate_created_branch) && candidate_created_branch
                    )
                  else
                    { "attempted" => false, "reason" => "allocation_not_started" }
                  end
        timeout_errors = if timeout_disk_exhausted
                           [
                             "git worktree add failed: disk is full (no space left on device); " \
                               "free disk space, then prompt this worker to retry provisioning"
                           ]
                         else
                           # Allocation runs several git commands, so name the one that actually
                           # hung instead of always blaming `git worktree add`.
                           [e.describe(command_label(e.argv))]
                         end
        failed_workspace(
          plan,
          timeout_errors,
          git_root: defined?(git_root) && git_root,
          worktree_root: defined?(worktree_root) && worktree_root,
          base_ref: defined?(base_ref) && base_ref,
          stdout: e.stdout,
          stderr: e.stderr,
          stdout_bytes: e.diagnostics && e.diagnostics["stdout_bytes"],
          stderr_bytes: e.diagnostics && e.diagnostics["stderr_bytes"],
          diagnostics_truncated: e.diagnostics && e.diagnostics["truncated"],
          timed_out: true,
          timeout_seconds: e.timeout,
          # A stuck command is worth one more attempt: the usual causes (a file-system monitor
          # that never answered, a lock another process held) do not survive a fresh spawn. A
          # command that blew the absolute ceiling while still making progress is not retried
          # automatically, because the retry would cost the same half hour; the worker is left
          # resumable so a human decides.
          failure_kind: timeout_disk_exhausted ? "disk_exhausted" : (e.stalled? ? "command_stalled" : "command_timed_out"),
          recovery: timeout_disk_exhausted ? RECOVERY_RESUME : (e.stalled? ? RECOVERY_RETRY : RECOVERY_RESUME),
          cleanup: cleanup
        )
      rescue StandardError => e
        clear_allocation_deadline!
        disk_exhausted = e.is_a?(Errno::ENOSPC) || e.is_a?(Errno::EDQUOT) || disk_exhaustion_output?(e.message)
        if disk_exhausted
          cleanup = if defined?(candidate_owned_attempt) && candidate_owned_attempt
                      cleanup_incomplete_allocation(
                        git_root: defined?(git_root) && git_root,
                        worktree_root: defined?(worktree_root) && worktree_root,
                        branch: (defined?(candidate_branch) && candidate_branch) || (plan && plan["workspace_branch"]),
                        created_branch: defined?(candidate_created_branch) && candidate_created_branch
                      )
                    else
                      { "attempted" => false, "reason" => "allocation_not_started" }
                    end
          failed_workspace(
            plan,
            [
              "worker workspace allocation failed: disk is full (no space left on device); " \
                "free disk space, then prompt this worker to retry provisioning"
            ],
            git_root: defined?(git_root) && git_root,
            worktree_root: defined?(worktree_root) && worktree_root,
            base_ref: defined?(base_ref) && base_ref,
            failure_kind: "disk_exhausted",
            recovery: RECOVERY_RESUME,
            cleanup: cleanup
          )
        else
          failed_workspace(plan, ["worker workspace allocation failed: #{e.message}"], failure_kind: "allocation_error")
        end
      ensure
        clear_allocation_deadline!
      end

      # Final launch gate. Allocation and harness startup are separated by state checkpointing, so
      # validate the checkout again immediately before the kernel gives it to a worker. Managed
      # worktrees must still be registered, editable, on the reserved branch, and owned by this
      # worker. A bare repository is a valid *source* for `git worktree add`, never a valid cwd.
      def validate_worker_workspace(workspace, agent_id: nil)
        return reuse_outcome(false, "invalid_workspace_record") unless workspace.is_a?(Hash)

        path = present_output(workspace["workspace_path"])
        return reuse_outcome(false, "workspace_missing") unless path && Dir.exist?(path)

        strategy = workspace["workspace_strategy"] || workspace["strategy"] || workspace.dig("plan", "strategy")
        if strategy == "shared_checkout"
          return reuse_outcome(false, "workspace_not_readable") unless File.readable?(path)
          return reuse_outcome(false, "workspace_is_bare_repository") if bare_repository?(path)

          expected_root = workspace["workspace_root_path"] || workspace["worktree_root_path"] || path
          expected_branch = workspace["workspace_branch"]
          git_root = workspace["git_root"] || workspace["project_root"]
          return reuse_outcome(false, "shared_checkout_metadata_missing") unless expected_branch && git_root

          listed = run_command("git", "-C", canonical_path(git_root), "worktree", "list", "--porcelain")
          return reuse_outcome(false, "worktree_list_failed") unless listed.fetch("status").success?

          record = parse_worktree_records(listed.fetch("stdout")).find do |candidate|
            same_path?(candidate.fetch("worktree", ""), expected_root)
          end
          return reuse_outcome(false, "worktree_not_registered") unless record
          return reuse_outcome(false, "workspace_is_bare_repository") if record.key?("bare")
          return reuse_outcome(false, "worktree_locked") if record.key?("locked")
          return reuse_outcome(false, "worktree_prunable") if record.key?("prunable")
          unless record.fetch("branch", nil) == "refs/heads/#{expected_branch}" && %w[main master].include?(expected_branch)
            return reuse_outcome(false, "shared_checkout_not_on_main_branch")
          end
          clean = shared_checkout_clean?(expected_root)
          return clean unless clean.fetch("usable", false)
          if workspace.fetch("managed_shared_checkout", false)
            owner = read_workspace_owner(expected_root)
            unless managed_shared_checkout_owner_matches?(
              owner,
              project_root: workspace.fetch("project_root", git_root),
              git_root: git_root,
              branch: expected_branch,
              worktree_root: expected_root
            )
              return reuse_outcome(false, "managed_shared_checkout_owner_mismatch")
            end
          end

          return reuse_outcome(
            true,
            "shared_checkout_ready",
            workspace_path: canonical_path(path),
            worktree_root_path: canonical_path(expected_root),
            workspace_branch: expected_branch
          )
        end

        return reuse_outcome(false, "workspace_not_editable") unless File.writable?(path)
        return reuse_outcome(false, "workspace_is_bare_repository") if bare_repository?(path)
        return reuse_outcome(false, "isolated_workspace_proof_missing") unless strategy == "git_worktree"

        plan = workspace["plan"].is_a?(Hash) ? workspace.fetch("plan") : workspace
        root = workspace["worktree_root_path"] || workspace["workspace_root_path"] ||
               plan["worktree_root_path"] || plan["workspace_root_path"] || path
        branch = workspace["workspace_branch"] || plan["workspace_branch"]
        git_root = workspace["git_root"] || plan["git_root"] || workspace["project_root"] || plan["project_root"]
        inspection = inspect_shared_worktree(worktree_root: root, branch: branch, git_root: git_root)
        return inspection unless inspection.fetch("usable", false)

        expected_owner = present_output(agent_id) || present_output(workspace["workspace_owner_id"]) ||
                         present_output(plan["workspace_owner_id"])
        return reuse_outcome(false, "workspace_owner_unknown") unless expected_owner

        owner = read_workspace_owner(root)
        return reuse_outcome(false, "workspace_owner_missing") unless owner
        unless owner.fetch("agent_id", nil) == expected_owner &&
               same_path?(owner.fetch("worktree_root", ""), root) &&
               owner.fetch("branch", nil) == branch &&
               same_path?(owner.fetch("git_root", ""), git_root)
          return reuse_outcome(
            false,
            "workspace_owner_mismatch",
            expected_owner_agent_id: expected_owner,
            owner_agent_id: owner.fetch("agent_id", nil)
          )
        end

        reuse_outcome(
          true,
          "workspace_ready",
          workspace_path: canonical_path(path),
          worktree_root_path: canonical_path(root),
          workspace_branch: branch,
          owner_agent_id: expected_owner
        )
      rescue CommandTimeout => e
        reuse_outcome(false, "workspace_validation_timed_out", error: e.message)
      rescue StandardError => e
        reuse_outcome(false, "workspace_validation_error", error: e.message)
      end

      def release_worker_workspace(workspace, delete_branch: false)
        return false unless workspace.is_a?(Hash)
        return false unless workspace.fetch("created", false)
        return false unless workspace.fetch("strategy", workspace.fetch("workspace_strategy", nil)) == "git_worktree"

        git_root = workspace["git_root"] || workspace.dig("plan", "git_root") || workspace["project_root"]
        worktree_root = workspace["worktree_root_path"] || workspace["workspace_root_path"] || workspace.dig("plan", "worktree_root_path") || workspace["workspace_path"]
        return false unless git_root && worktree_root && Dir.exist?(worktree_root.to_s)
        owner_id = workspace["workspace_owner_id"] || workspace.dig("plan", "workspace_owner_id")
        branch = workspace["workspace_branch"] || workspace.dig("plan", "workspace_branch")
        return false unless workspace_owned_by?(worktree_root, agent_id: owner_id, git_root: git_root, branch: branch)

        provider = provider_for_workspace(workspace)
        if provider.external?
          released = release_external_workspace(workspace, provider: provider, preserve_branch: !delete_branch)
          return released.fetch("success", false)
        end

        result = run_command("git", "-C", git_root.to_s, "worktree", "remove", "--force", worktree_root.to_s,
                             timeout: cleanup_timeout, deadline: false)
        return false unless result.fetch("status").success?

        # Even an explicit delete keeps a branch that carries commits: releasing a workspace must
        # never be the reason a delivered commit stops being reachable. Keep its ownership record
        # with it; a later retry by the same worker may safely check that branch back out, while a
        # different worker must allocate elsewhere.
        branch_result = release_owned_branch(canonical_path(git_root.to_s), branch.to_s) if delete_branch && branch
        if branch_result == "deleted" || !branch_exists?(canonical_path(git_root.to_s), branch.to_s)
          release_workspace_owner(worktree_root, agent_id: owner_id, git_root: git_root, branch: branch)
        end
        true
      rescue StandardError
        false
      end

      # Whether an existing Meringue worktree is safe for another worker to continue working in.
      #
      # The kernel decides *who* may share a workspace (relationship, liveness, delivery state);
      # this answers the git-only half of that question for a worktree the kernel already believes
      # belongs to the predecessor. It deliberately does not run `git status`: a dirty tree is the
      # whole point of continuing someone else's work, and `--untracked-files=all` is the slowest
      # command in the provisioning path on a large repository.
      #
      # Reasons a shared worktree is refused:
      #   worktree_missing            the directory is gone
      #   outside_managed_workspace_root  not a Meringue-owned path, so Meringue makes no claims
      #   branch_not_delivery_managed the recorded branch does not match the managed delivery convention
      #   git_root_missing            the repository the worktree belongs to is gone
      #   worktree_list_failed        git could not be asked
      #   worktree_not_registered     the directory exists but git no longer knows it
      #   worktree_branch_moved       another branch (or a detached HEAD) is checked out there now
      #   worktree_locked             git holds a lock on it, including a half-finished checkout
      def inspect_shared_worktree(worktree_root:, branch:, git_root:)
        return reuse_outcome(false, "worktree_missing") if worktree_root.to_s.strip.empty?

        worktree_root = canonical_path(worktree_root)
        return reuse_outcome(false, "worktree_missing") unless Dir.exist?(worktree_root)
        return reuse_outcome(false, "branch_not_delivery_managed") unless DeliveryArtifactPolicy.managed_branch?(branch)
        return reuse_outcome(false, "git_root_missing") if git_root.to_s.strip.empty? || !Dir.exist?(git_root.to_s)
        git_root = canonical_path(git_root)
        unless managed_owned_workspace_path?(worktree_root, git_root: git_root, branch: branch)
          return reuse_outcome(false, "outside_managed_workspace_root")
        end

        listed = run_command("git", "-C", git_root, "worktree", "list", "--porcelain")
        unless listed.fetch("status").success?
          return reuse_outcome(
            false,
            "worktree_list_failed",
            error: present_output(listed.fetch("stderr")) || present_output(listed.fetch("stdout"))
          )
        end

        record = parse_worktree_records(listed.fetch("stdout")).find do |candidate|
          same_path?(candidate.fetch("worktree", ""), worktree_root)
        end
        return reuse_outcome(false, "worktree_not_registered") unless record

        checked_out = record.fetch("branch", nil)
        unless checked_out == "refs/heads/#{branch}"
          return reuse_outcome(
            false,
            "worktree_branch_moved",
            checked_out_branch: checked_out ? checked_out.sub(%r{\Arefs/heads/}, "") : nil,
            detached: record.key?("detached")
          )
        end
        return reuse_outcome(false, "worktree_locked") if record.key?("locked")

        reuse_outcome(true, "worktree_reusable", worktree_root_path: worktree_root, workspace_branch: branch)
      rescue CommandTimeout => e
        reuse_outcome(false, "worktree_inspection_timed_out", error: e.message)
      rescue StandardError => e
        reuse_outcome(false, "worktree_inspection_error", error: e.message)
      end

      # `git worktree prune` removes administrative files for worktrees whose directories are
      # already gone. It never touches a live worktree directory, so it is safe to run after a
      # prune pass to clear any dangling registrations the per-worktree cleanup could not
      # deregister (for example a worktree directory that was removed out of band while its
      # registration lingered). This is a courtesy, not a force-removal: dirty, locked, or
      # actively-referenced worktrees are untouched.
      def prune_dangling_worktrees(git_root)
        return { "success" => false, "reason" => "git_root_missing" } if git_root.to_s.strip.empty? || !Dir.exist?(git_root.to_s)
        result = run_command("git", "-C", git_root.to_s, "worktree", "prune")
        {
          "success" => result.fetch("status").success?,
          "stdout" => present_output(result.fetch("stdout")),
          "stderr" => present_output(result.fetch("stderr"))
        }.compact
      rescue CommandTimeout => e
        { "success" => false, "reason" => "prune_timed_out", "error" => e.message }
      rescue StandardError => e
        { "success" => false, "reason" => "prune_error", "error" => e.message }
      end

      # Pruning uses a deliberately stricter cleanup path than failed provisioning. It removes
      # only a registered, clean, unlocked Meringue worktree whose path and branch still match the
      # persisted ownership record. Branches are retained so delivered commits remain reachable.
      # A structured result lets the kernel explain anything unsafe to remove instead of forcing
      # or guessing; the kernel decides separately whether the associated terminal record remains.
      def cleanup_pruned_worker_workspace(workspace, protected_paths: [], deadline: nil)
        return cleanup_outcome("skipped", "invalid_workspace_record", success: true) unless workspace.is_a?(Hash)

        plan = workspace["plan"].is_a?(Hash) ? workspace.fetch("plan") : {}
        strategy = workspace["strategy"] || workspace["workspace_strategy"] || plan["strategy"]
        return cleanup_outcome("skipped", "not_a_managed_worktree", success: true) unless strategy == "git_worktree"

        worktree_root = workspace["worktree_root_path"] || workspace["workspace_root_path"] ||
                        plan["worktree_root_path"] || plan["workspace_root_path"] ||
                        workspace["workspace_path"] || plan["workspace_path"]
        return cleanup_outcome("skipped", "no_worktree_recorded", success: true) if worktree_root.to_s.strip.empty?

        worktree_root = canonical_path(worktree_root)
        base = {
          "worktree_root_path" => worktree_root,
          "workspace_branch" => workspace["workspace_branch"] || plan["workspace_branch"],
          "workspace_owner_id" => workspace["workspace_owner_id"] || plan["workspace_owner_id"],
          "requested_worktree_provider" => workspace["requested_worktree_provider"] || plan["requested_worktree_provider"],
          "worktree_provider" => workspace["worktree_provider"] || plan["worktree_provider"],
          "worktree_provider_identifier" => workspace["worktree_provider_identifier"] || plan["worktree_provider_identifier"],
          "worktree_provider_cwd" => workspace["worktree_provider_cwd"] || plan["worktree_provider_cwd"],
          "project_root" => workspace["project_root"] || plan["project_root"]
        }.compact
        if Array(protected_paths).compact.any? { |path| paths_overlap?(worktree_root, canonical_path(path)) }
          return cleanup_outcome("failed", "workspace_owned_by_another_worker", success: false, **base)
        end

        branch = base["workspace_branch"]
        unless DeliveryArtifactPolicy.managed_branch?(branch)
          return cleanup_outcome("failed", "branch_not_delivery_managed", success: false, **base)
        end

        git_root = workspace["git_root"] || plan["git_root"] || workspace["project_root"] || plan["project_root"]
        if git_root.to_s.strip.empty? || !Dir.exist?(git_root.to_s)
          return cleanup_outcome("failed", "git_root_missing", success: false, **base)
        end

        git_root = canonical_path(git_root)
        base["git_root"] = git_root
        owner_id = workspace["workspace_owner_id"] || plan["workspace_owner_id"]
        unless managed_owned_workspace_path?(worktree_root, git_root: git_root, branch: branch, agent_id: owner_id)
          provider = provider_for_workspace(workspace)
          provider_identifier = workspace["worktree_provider_identifier"] || plan["worktree_provider_identifier"]
          released_record = if provider.external? && provider_identifier
                              worktree_records(git_root).find do |candidate|
                                same_path?(candidate.fetch("worktree", ""), worktree_root)
                              end
                            end
          if released_record && released_record.fetch("branch", nil) != "refs/heads/#{branch}"
            return cleanup_outcome(
              "already_removed",
              "provider_workspace_already_released",
              success: true,
              "worktree_provider" => provider.kind,
              **base
            )
          end
          return cleanup_outcome("skipped", "outside_managed_workspace_root", success: true, **base)
        end
        if paths_overlap?(worktree_root, git_root)
          return cleanup_outcome("failed", "main_checkout_protected", success: false, **base)
        end

        listed = run_command("git", "-C", git_root, "worktree", "list", "--porcelain", deadline: deadline)
        unless listed.fetch("status").success?
          return cleanup_outcome(
            "failed",
            "worktree_list_failed",
            success: false,
            error: present_output(listed.fetch("stderr")) || present_output(listed.fetch("stdout")),
            **base
          )
        end

        record = parse_worktree_records(listed.fetch("stdout")).find do |candidate|
          same_path?(candidate.fetch("worktree", ""), worktree_root)
        end
        unless record
          if Dir.exist?(worktree_root)
            return cleanup_outcome("failed", "worktree_not_registered", success: false, **base)
          end

          owner_id = workspace["workspace_owner_id"] || plan["workspace_owner_id"]
          release_workspace_owner(worktree_root, agent_id: owner_id, git_root: git_root, branch: branch) if owner_id
          return cleanup_outcome("already_removed", "worktree_already_removed", success: true, **base)
        end
        unless record.fetch("branch", nil) == "refs/heads/#{branch}"
          provider = provider_for_workspace(workspace)
          if provider.external?
            owner_id = workspace["workspace_owner_id"] || plan["workspace_owner_id"]
            release_workspace_owner(worktree_root, agent_id: owner_id, git_root: git_root, branch: branch) if owner_id
            return cleanup_outcome(
              "already_removed",
              "provider_workspace_already_released",
              success: true,
              "worktree_provider" => provider.kind,
              **base
            )
          end
          return cleanup_outcome("failed", "worktree_branch_mismatch", success: false, **base)
        end
        if record.key?("locked")
          return cleanup_outcome("failed", "worktree_locked", success: false, **base)
        end

        if Dir.exist?(worktree_root)
          dirty = run_command("git", "-C", worktree_root, "status", "--porcelain", "--untracked-files=all", deadline: deadline)
          unless dirty.fetch("status").success?
            return cleanup_outcome(
              "failed",
              "worktree_status_failed",
              success: false,
              error: present_output(dirty.fetch("stderr")) || present_output(dirty.fetch("stdout")),
              **base
            )
          end
          unless dirty.fetch("stdout").to_s.empty?
            return cleanup_outcome("failed", "worktree_dirty", success: false, **base)
          end
        end

        provider = provider_for_workspace(workspace)
        if provider.external?
          released = release_external_workspace(workspace, provider: provider, preserve_branch: true, deadline: deadline)
          if released.fetch("success", false)
            return cleanup_outcome(
              "removed",
              released.fetch("reason", "provider_workspace_released"),
              success: true,
              attempted: true,
              "worktree_provider" => provider.kind,
              "worktree_retained" => released.fetch("worktree_retained", false),
              "branch_restored" => released.fetch("branch_restored", false),
              **base
            )
          end
          return cleanup_outcome(
            "failed",
            released.fetch("reason", "external_provider_release_failed"),
            success: false,
            attempted: released.fetch("attempted", false),
            error: released.fetch("error", nil),
            "worktree_provider" => provider.kind,
            **base
          )
        end

        removed = run_command("git", "-C", git_root, "worktree", "remove", worktree_root, timeout: cleanup_timeout, deadline: deadline)
        unless removed.fetch("status").success?
          output = present_output(removed.fetch("stderr")) || present_output(removed.fetch("stdout"))
          reason = output.to_s.match?(/locked/i) ? "worktree_locked" : "worktree_remove_failed"
          return cleanup_outcome("failed", reason, success: false, attempted: true, error: output, **base)
        end

        owner_id = workspace["workspace_owner_id"] || plan["workspace_owner_id"]
        release_workspace_owner(worktree_root, agent_id: owner_id, git_root: git_root, branch: branch) if owner_id
        cleanup_outcome("removed", "worktree_removed", success: true, attempted: true, **base)
      rescue CommandTimeout => e
        cleanup_outcome(
          "failed",
          "worktree_cleanup_timed_out",
          success: false,
          attempted: true,
          error: e.message,
          worktree_root_path: defined?(worktree_root) && worktree_root,
          workspace_branch: defined?(branch) && branch,
          git_root: defined?(git_root) && git_root
        )
      rescue StandardError => e
        cleanup_outcome(
          "failed",
          "worktree_cleanup_error",
          success: false,
          error: e.message,
          worktree_root_path: defined?(worktree_root) && worktree_root,
          workspace_branch: defined?(branch) && branch,
          git_root: defined?(git_root) && git_root
        )
      end

      # Read-only capability probe used at project registration and by Doctor.
      # A directory is not a workspace capability: only a Git repository with a
      # usable base and a GitHub origin is accepted by the built-in backend.
      def inspect_project(root_path)
        project_path = canonical_path(root_path)
        repository = repository_context(project_path)
        return { "available" => false, "capabilities" => { "isolated_workspaces" => false }, "diagnostics" => ["not_a_git_repository"] } unless repository

        git_root = repository.fetch("git_root")
        base = preferred_base_ref(git_root)
        remote = run_command("git", "-C", git_root, "remote", "get-url", "origin")
        remote_url = remote.fetch("stdout").to_s.strip
        github = remote.fetch("status").success? && remote_url.match?(%r{(?:github\.com[:/])}i)
        diagnostics = []
        diagnostics << "github_origin_missing" unless github
        diagnostics << "base_ref_missing" unless base
        ready = github && !base.nil?
        {
          "available" => !!ready, "backend" => "github_git",
          "repository_identity" => (github ? remote_url : git_root),
          "capabilities" => { "isolated_workspaces" => !!ready, "mutable_workspace" => !!ready,
                               "shared_read_only_workspace" => true, "delivery" => github },
          "diagnostics" => diagnostics, "diagnostic_at" => Time.now.utc.iso8601
        }
      rescue StandardError => e
        { "available" => false, "capabilities" => { "isolated_workspaces" => false },
          "diagnostics" => ["backend_probe_failed: #{e.message}"] }
      end

      private










      # A registered project may be either a normal checkout or a bare common repository. World
      # uses the latter: `--show-toplevel` correctly fails there, but the bare repository is still
      # exactly the Git directory from which isolated editable worktrees must be created.




      # Resolve symlinks even when the final worktree path is already gone. This keeps stale
      # registrations comparable on systems such as macOS where /var and /private/var alias.








      # Attempt numbers above zero uniquify the branch and worktree path so a worker can still be
      # provisioned when the preferred names are taken by another worktree or an unrelated branch.

      # Candidate ownership is reserved before any path/ref mutation and held under a per-candidate
      # advisory lock until checkout finishes. Distinct workers still provision in parallel because
      # their locks differ; contenders for one path can only observe or reallocate, never both
      # decide that an existing worktree is theirs.


      # Command providers select their own destination. Meringue reserves the
      # deterministic branch/name first, asks the provider to provision it,
      # then discovers the resulting path from Git's registry and transfers the
      # durable ownership record to that exact path. Git remains authoritative
      # for every launch and cleanup safety check.

      FailureStatus = Struct.new(:exitstatus) do
        def success? = false
      end






































      # Deletes an allocator-owned branch only when losing it cannot lose work: it must match the
      # managed delivery convention, not be checked out anywhere, and carry no commit unreachable from
      # every other ref. A branch with commits is always kept, even though that leaves a name
      # Meringue has to work around, because the alternative is destroying a worker's delivery.



      # Commits reachable from this branch and from no other ref. Zero means deleting the branch
      # cannot orphan anything. nil means the question could not be answered, which callers treat
      # as "assume it has work".

      # Removes the debris a killed or failed `git worktree add` leaves behind.
      #
      # `git worktree add` writes `.git/worktrees/<name>/locked` ("initializing") for the whole
      # checkout and only unlinks it on success. A worktree that was killed mid-checkout is
      # therefore *locked*: `git worktree remove --force` refuses it with exit 128 and
      # `git worktree prune` silently skips it. That is exactly the leak this issue reported -
      # `worktree_remove_status: 128` plus an abandoned `meringue/*` branch after every failure,
      # which then pushed the next attempt onto a `-2` name. Cleanup therefore unlocks, uses
      # git's documented double `--force` override, deletes the directory it owns, prunes the
      # registration, verifies the result, and only then releases the branch.



      # Whether the worktree at the planned path is this worker's own resumable checkout of
      # its exact planned branch, and therefore safe to reclaim when no ownership record says
      # otherwise. The branch name is the worker's deterministic delivery branch, the worktree
      # must live inside the Meringue-managed root, be registered, on that one branch, unlocked,
      # and not bare or prunable. Anything else (a foreign squatter directory, a worktree that
      # moved to another branch, a half-finished locked checkout, a bare repository) stays a
      # collision so the allocator falls back to a uniquified candidate as before.


      # Cleanup runs after the allocation budget is already spent, so it uses its own budget and
      # never raises: a cleanup command that fails is reported, not propagated over the original
      # provisioning failure.




      # A command provider owns its destination layout, which may live outside
      # +root_path+. Such a path is managed only when the allocator's durable
      # ownership record matches that exact Git root, branch, and path.

      # Names the command a CommandTimeout came from, such as "git worktree add" or "git rev-parse".


      # Runs one command under two independent bounds.
      #
      #   timeout       absolute ceiling for this command, always finite.
      #   stall_timeout optional: kill the command after this many seconds with no output at all.
      #                 Only meaningful for a command that reports progress (`git worktree add`).
      #   deadline      optional monotonic instant that caps `timeout`. Defaults to the ambient
      #                 allocation deadline so one provisioning attempt is bounded as a whole;
      #                 pass `false` to opt out (cleanup, which runs after the budget is spent).
      #
      # The command is polled rather than wrapped in Timeout.timeout, so the watchdog can look at
      # output activity, report progress, and kill the process group promptly.

      # Returns nil when the command finished on its own, or a description of the bound that
      # fired. Never returns while the command is still allowed to run.














      # ---- project-native sparse provisioning profiles ----------------------

      # Profiles are project-declared and loaded from the project root. An
      # explicit profile (or a cached one) wins; otherwise the project's
      # `.meringue/workspace-profile.toml` is read. A missing or malformed file
      # returns nil so the default full-checkout behavior is preserved exactly.

      # Resolve the profile that should drive provisioning for a worker. A
      # project-declared profile (or an explicit one) always wins. When no
      # profile is declared and the source is a large bare repository, a generic
      # root-only cone sparse profile is synthesized so an isolated writable
      # worker does not materialize the whole tree. The synthesis carries no
      # project-specific paths: the non-cone patterns `/*` plus `!/*/`
      # materialize root-level files only and skip every subdirectory.
      # Operators opt out with `[workspace] default_bare_checkout_mode = "full"`
      # to keep the legacy full checkout, and a project that declares any
      # profile (sparse or full-checkout) always overrides the synthetic default.

      # The generic synthetic profile used when a large bare source declares no
      # profile. Root-files-only (non-cone) keeps it project-agnostic: it
      # materializes the root-level files (README, manifests) and skips every
      # subdirectory until the worker expands its working set with
      # `git sparse-checkout add <path>` or `git checkout HEAD -- <path>`.


      # Whether a bare source is large enough that a full per-worker checkout is
      # worth avoiding. The packed object count is read from `git
      # count-objects -v`, whose `in-pack:` line is derived from pack `.idx`
      # footers in O(number-of-packs), never O(objects). The result is memoized
      # per git_root so repeated plan/allocate calls never re-run the command.





      # Stamps the selected profile onto a plan/workspace record so it is
      # persisted on the agent's workspace_plan and reused on retry.

      # Applies per-worktree sparse-checkout configuration after a
      # `git worktree add --no-checkout`. Sparse settings are written to the
      # worktree's own git dir so no shared repository config is mutated; this
      # keeps bare-repository and shared-checkout protections intact. Only the
      # declared pattern set is materialized via `read-tree -mu HEAD`.



      # A bounded count of materialized files, used to record how much the
      # sparse profile reduced the working set. It is capped so counting a
      # sparse checkout never costs the minutes the full checkout would have.



      # Runs the project-declared post-provision validation command inside the
      # checkout so a project can confirm the sparse set is recognized by its
      # own tooling. A non-zero exit fails provisioning so the worker never
      # launches in a checkout its project tooling rejects.

    end
  end
end
