# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"

require_relative "../delivery_artifact_policy"

module Meringue
  module Workspace
    class Manager
      DEFAULT_ROOT = File.expand_path("~/.meringue/workspaces")
      # Budget for the short git plumbing commands allocation runs: rev-parse, show-ref,
      # worktree list. None of them touch a working tree, so 60s is already generous and a
      # command that spends longer than that reading refs really is stuck.
      DEFAULT_COMMAND_TIMEOUT = 60
      # `git worktree add` is not plumbing: it checks the whole tree out. shop/world is ~478k
      # files, which is minutes of honest work on a warm disk and longer on a cold one, so one
      # flat 60s budget for both `git rev-parse` and a half-million-file checkout is what turned a
      # slow provisioning into a dead worker. The checkout is therefore bounded by two independent
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
      ALLOCATION_ATTEMPT_LIMIT = 3
      OWNERSHIP_SCHEMA_VERSION = 1
      OWNERSHIP_DIRECTORY = ".ownership"
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
      # Some global git configs (Shopify's `dev` config among them) enable core.fsmonitor. Git then
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
          checkout_timeout: section.fetch("worktree_checkout_timeout", DEFAULT_CHECKOUT_TIMEOUT)
        )
      end

      attr_reader :root_path, :command_timeout, :checkout_stall_timeout, :checkout_timeout, :cleanup_timeout,
                  :progress_interval

      def initialize(root_path: DEFAULT_ROOT, command_timeout: DEFAULT_COMMAND_TIMEOUT,
                     checkout_stall_timeout: DEFAULT_CHECKOUT_STALL_TIMEOUT,
                     checkout_timeout: DEFAULT_CHECKOUT_TIMEOUT,
                     cleanup_timeout: DEFAULT_CLEANUP_TIMEOUT,
                     progress_interval: PROGRESS_REPORT_INTERVAL)
        @root_path = File.expand_path(root_path)
        @command_timeout = positive_float(command_timeout, DEFAULT_COMMAND_TIMEOUT)
        @checkout_stall_timeout = positive_float(checkout_stall_timeout, DEFAULT_CHECKOUT_STALL_TIMEOUT)
        @checkout_timeout = positive_float(checkout_timeout, DEFAULT_CHECKOUT_TIMEOUT)
        # A stall bound above the absolute bound could never fire, which would silently remove the
        # only limit that catches a genuinely stuck command.
        @checkout_stall_timeout = @checkout_timeout if @checkout_stall_timeout > @checkout_timeout
        @cleanup_timeout = positive_float(cleanup_timeout, DEFAULT_CLEANUP_TIMEOUT)
        @progress_interval = positive_float(progress_interval, PROGRESS_REPORT_INTERVAL)
      end

      # Hard ceiling on one allocate_worker_workspace call, including every retried candidate and
      # every plumbing command. Provisioning can be slow; it can never be unbounded.
      def allocation_budget
        checkout_timeout
      end

      def plan_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil)
        safe_project_name = project_slug(File.basename(File.expand_path(project_root))) || "project"
        safe_task_name = DeliveryArtifactPolicy.slug(task_title)
        unique_suffix = Digest::SHA256.hexdigest(
          [File.expand_path(project_root), project_id, issue_id, agent_id, safe_task_name].join("\0")
        )[0, 8]
        workspace_name = [safe_task_name, unique_suffix].join("-")
        branch = workspace_name
        workspace_path = File.join(root_path, safe_project_name, workspace_name)

        {
          "strategy" => "git_worktree",
          "project_root" => File.expand_path(project_root),
          "workspace_path" => workspace_path,
          "workspace_branch" => branch,
          "workspace_owner_id" => agent_id.to_s,
          "created" => false
        }
      end

      # Resolve an already-existing main/master checkout that investigation-only workers may
      # share. This method is intentionally discovery-only: it never creates a branch, directory,
      # or worktree. A registered bare repository (World's common shape) is a valid source for
      # isolated allocation, but only one of its existing non-bare linked worktrees can satisfy
      # this contract.
      def shared_read_only_checkout(project_root:)
        project_path = canonical_path(project_root)
        repository = repository_context(project_path)
        return reuse_outcome(false, "project_is_not_a_git_repository") unless repository

        git_root = repository.fetch("git_root")
        relative_project_path = repository.fetch("bare") ? "." : relative_path(project_path, git_root)
        listed = run_command("git", "-C", git_root, "worktree", "list", "--porcelain")
        unless listed.fetch("status").success?
          return reuse_outcome(
            false,
            "worktree_list_failed",
            error: present_output(listed.fetch("stderr")) || present_output(listed.fetch("stdout"))
          )
        end

        candidates = parse_worktree_records(listed.fetch("stdout")).filter_map do |record|
          next if record.key?("bare") || record.key?("locked") || record.key?("prunable")

          branch = record.fetch("branch", nil)
          next unless %w[refs/heads/main refs/heads/master].include?(branch)

          checkout_root = present_output(record.fetch("worktree", nil))
          next unless checkout_root

          checkout_root = canonical_path(checkout_root)
          workspace_path = relative_project_path == "." ? checkout_root : File.join(checkout_root, relative_project_path)
          next unless Dir.exist?(workspace_path) && File.readable?(workspace_path)
          next if bare_repository?(checkout_root)

          {
            "strategy" => "shared_checkout",
            "workspace_strategy" => "shared_checkout",
            "project_root" => project_path,
            "workspace_path" => canonical_path(workspace_path),
            "workspace_root_path" => checkout_root,
            "worktree_root_path" => checkout_root,
            "workspace_branch" => branch.sub(%r{\Arefs/heads/}, ""),
            "git_root" => git_root,
            "project_relative_path" => relative_project_path,
            "created" => false,
            "read_only" => true,
            "errors" => []
          }
        end
        preferred = candidates.find { |candidate| same_path?(candidate.fetch("workspace_root_path"), git_root) } || candidates.first
        return preferred if preferred

        reason = repository.fetch("bare") ? "bare_repository_has_no_shared_main_checkout" : "no_readable_main_checkout"
        reuse_outcome(false, reason, git_root: git_root)
      rescue CommandTimeout => e
        reuse_outcome(false, "shared_checkout_discovery_timed_out", error: e.message)
      rescue StandardError => e
        reuse_outcome(false, "shared_checkout_discovery_error", error: e.message)
      end

      # `progress` is an optional callable invoked (at most every PROGRESS_REPORT_INTERVAL
      # seconds) while a long command is still running, so a caller can tell the user that a
      # checkout is working rather than hung.
      def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil, progress: nil,
                                    unavailable_paths: [])
        plan = nil
        set_allocation_deadline!(self.class.monotonic_now + allocation_budget)
        plan = plan_worker_workspace(
          project_root: project_root,
          project_id: project_id,
          issue_id: issue_id,
          agent_id: agent_id,
          task_title: task_title
        )
        project_path = canonical_path(project_root)
        plan["project_root"] = project_path
        repository = repository_context(project_path)
        return project_root_workspace(project_path, plan, "project root is not inside a git repository") unless repository

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
        return reuse_outcome(true, "workspace_ready", workspace_path: canonical_path(path)) unless strategy == "git_worktree"

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
        return false unless workspace_owned_by?(worktree_root, agent_id: owner_id, git_root: git_root,
                                                branch: workspace["workspace_branch"] || workspace.dig("plan", "workspace_branch"))

        result = run_command("git", "-C", git_root.to_s, "worktree", "remove", "--force", worktree_root.to_s,
                             timeout: cleanup_timeout, deadline: false)
        return false unless result.fetch("status").success?

        branch = workspace["workspace_branch"] || workspace.dig("plan", "workspace_branch")
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
        return reuse_outcome(false, "outside_managed_workspace_root") unless owned_workspace_path?(worktree_root)
        return reuse_outcome(false, "branch_not_delivery_managed") unless DeliveryArtifactPolicy.managed_branch?(branch)
        return reuse_outcome(false, "git_root_missing") if git_root.to_s.strip.empty? || !Dir.exist?(git_root.to_s)

        listed = run_command("git", "-C", canonical_path(git_root), "worktree", "list", "--porcelain")
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
          "workspace_branch" => workspace["workspace_branch"] || plan["workspace_branch"]
        }.compact
        unless owned_workspace_path?(worktree_root)
          return cleanup_outcome("skipped", "outside_managed_workspace_root", success: true, **base)
        end
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

      private

      # A registered project may be either a normal checkout or a bare common repository. World
      # uses the latter: `--show-toplevel` correctly fails there, but the bare repository is still
      # exactly the Git directory from which isolated editable worktrees must be created.
      def repository_context(project_path)
        return nil unless Dir.exist?(project_path)

        bare = run_command("git", "-C", project_path, "rev-parse", "--is-bare-repository")
        return nil unless bare.fetch("status").success?
        if bare.fetch("stdout").to_s.strip == "true"
          git_dir = run_command("git", "-C", project_path, "rev-parse", "--absolute-git-dir")
          return nil unless git_dir.fetch("status").success?

          return { "git_root" => canonical_path(git_dir.fetch("stdout").strip), "bare" => true }
        end

        top = run_command("git", "-C", project_path, "rev-parse", "--show-toplevel")
        return nil unless top.fetch("status").success?

        { "git_root" => canonical_path(top.fetch("stdout").strip), "bare" => false }
      rescue CommandTimeout
        raise
      rescue StandardError
        nil
      end

      def bare_repository?(path)
        result = run_command("git", "-C", path, "rev-parse", "--is-bare-repository")
        result.fetch("status").success? && result.fetch("stdout").to_s.strip == "true"
      rescue CommandTimeout
        raise
      rescue StandardError
        false
      end

      def preferred_base_ref(git_root)
        %w[origin/main origin/master main master HEAD].find do |ref|
          run_command("git", "-C", git_root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}").fetch("status").success?
        end
      end

      def relative_path(project_path, git_root)
        Pathname.new(canonical_path(project_path)).relative_path_from(Pathname.new(canonical_path(git_root))).to_s
      rescue ArgumentError
        "."
      end

      # Resolve symlinks even when the final worktree path is already gone. This keeps stale
      # registrations comparable on systems such as macOS where /var and /private/var alias.
      def canonical_path(path)
        expanded = File.expand_path(path.to_s)
        return File.realpath(expanded) if File.exist?(expanded)

        missing_parts = []
        existing = expanded
        until File.exist?(existing) || File.dirname(existing) == existing
          missing_parts.unshift(File.basename(existing))
          existing = File.dirname(existing)
        end
        File.join(File.realpath(existing), *missing_parts)
      rescue StandardError
        expanded
      end

      def same_path?(left, right)
        canonical_path(left) == canonical_path(right)
      end

      def paths_overlap?(left, right)
        left_path = canonical_path(left)
        right_path = canonical_path(right)
        left_path == right_path ||
          left_path.start_with?("#{right_path}#{File::SEPARATOR}") ||
          right_path.start_with?("#{left_path}#{File::SEPARATOR}")
      end

      def reuse_outcome(usable, reason, **details)
        {
          "usable" => usable,
          "reason" => reason
        }.merge(details.transform_keys(&:to_s)).compact
      end

      def cleanup_outcome(status, reason, success:, attempted: false, **details)
        {
          "status" => status,
          "reason" => reason,
          "success" => success,
          "attempted" => attempted
        }.merge(details.transform_keys(&:to_s)).compact
      end

      def project_root_workspace(project_path, plan, reason)
        {
          "strategy" => "project_root",
          "project_root" => project_path,
          "workspace_path" => project_path,
          "workspace_branch" => nil,
          "created" => false,
          "fallback_reason" => reason,
          "plan" => plan,
          "errors" => []
        }
      end

      def failed_workspace(plan, errors, git_root: nil, worktree_root: nil, base_ref: nil, stdout: nil, stderr: nil,
                           stdout_bytes: nil, stderr_bytes: nil, diagnostics_truncated: nil, exit_status: nil,
                           timed_out: false, timeout_seconds: nil, cleanup: nil, failure_kind: nil, recovery: RECOVERY_NONE)
        (plan || {}).merge(
          "git_root" => git_root,
          "workspace_root_path" => worktree_root,
          "worktree_root_path" => worktree_root,
          "base_ref" => base_ref,
          "created" => false,
          "errors" => Array(errors).compact,
          "stdout" => present_output(stdout),
          "stderr" => present_output(stderr),
          "stdout_bytes" => stdout_bytes,
          "stderr_bytes" => stderr_bytes,
          "diagnostics_truncated" => diagnostics_truncated,
          "exit_status" => exit_status,
          "timed_out" => timed_out,
          "timeout_seconds" => timeout_seconds,
          "failure_kind" => failure_kind,
          "recovery" => recovery,
          "cleanup" => cleanup
        ).compact
      end

      # Attempt numbers above zero uniquify the branch and worktree path so a worker can still be
      # provisioned when the preferred names are taken by another worktree or an unrelated branch.
      def candidate_allocation(plan, attempt)
        branch = plan.fetch("workspace_branch")
        worktree_root = File.expand_path(plan.fetch("workspace_path"))
        return { "branch" => branch, "worktree_root" => worktree_root } if attempt.zero?

        suffix = "-#{attempt + 1}"
        { "branch" => "#{branch}#{suffix}", "worktree_root" => "#{worktree_root}#{suffix}" }
      end

      # Candidate ownership is reserved before any path/ref mutation and held under a per-candidate
      # advisory lock until checkout finishes. Distinct workers still provision in parallel because
      # their locks differ; contenders for one path can only observe or reallocate, never both
      # decide that an existing worktree is theirs.
      def allocate_candidate_worktree(plan:, git_root:, base_ref:, relative_project_path:, branch:, worktree_root:,
                                      owner:, progress: nil, attempt_started: nil)
        reservation = reserve_workspace_candidate(owner)
        return reservation.fetch("outcome") unless reservation.fetch("acquired", false)

        allocate_reserved_candidate_worktree(
          plan: plan,
          git_root: git_root,
          base_ref: base_ref,
          relative_project_path: relative_project_path,
          branch: branch,
          worktree_root: worktree_root,
          progress: progress,
          attempt_started: attempt_started
        )
      ensure
        release_candidate_lock(reservation && reservation["lock"])
      end

      def allocate_reserved_candidate_worktree(plan:, git_root:, base_ref:, relative_project_path:, branch:, worktree_root:,
                                               progress: nil, attempt_started: nil)
        candidate_plan = plan.merge("workspace_branch" => branch, "workspace_path" => worktree_root)
        workspace_path = relative_project_path == "." ? worktree_root : File.join(worktree_root, relative_project_path)

        if Dir.exist?(worktree_root)
          adopted = adopt_existing_worktree(candidate_plan, git_root: git_root, worktree_root: worktree_root, workspace_path: workspace_path,
                                            relative_project_path: relative_project_path, base_ref: base_ref)
          return { "workspace" => adopted } if adopted

          discarded = discard_empty_owned_directory(worktree_root)
          unless discarded
            return {
              "retry" => true,
              "errors" => ["worker worktree path already exists: #{worktree_root}"],
              "failure_kind" => "path_collision",
              "recovery" => RECOVERY_NONE
            }
          end
        end

        # Remember whether the candidate branch existed before this attempt. The normal stale-empty
        # branch cleanup may recreate it, but an ENOSPC failure must still preserve that name for a
        # later retry rather than treating it as disposable debris created for this attempt.
        branch_preexisting = branch_exists?(git_root, branch)
        remove_orphaned_owned_branch(git_root, branch)
        FileUtils.mkdir_p(File.dirname(worktree_root))
        created_branch = !branch_exists?(git_root, branch)
        argv = if created_branch
                 # `origin/main` normally makes Git auto-write branch tracking config. Two otherwise
                 # independent concurrent adds then race on `.git/config.lock`. Workers push their
                 # explicit task branch and do not need an implicit upstream at checkout time, so
                 # suppress that shared config mutation and keep distinct candidate checkouts truly
                 # parallel.
                 ["git", "-C", git_root, "worktree", "add", "--no-track", "-b", branch, worktree_root, base_ref]
               else
                 if branch_checked_out?(git_root, branch)
                   return {
                     "retry" => true,
                     "errors" => ["worker branch #{branch} is checked out in another worktree"],
                     "failure_kind" => "branch_collision",
                     "recovery" => RECOVERY_NONE
                   }
                 end

                 # The branch survived a previous attempt for this worker and carries commits, so
                 # it is checked out instead of being recreated: the previous attempt's work stays
                 # reachable and "a branch named ... already exists" never fails the spawn.
                 ["git", "-C", git_root, "worktree", "add", worktree_root, branch]
               end
        # From this point onward the path is either absent/empty and Meringue-owned, and the branch
        # ownership decision is known. Outer exception/timeout handling may therefore clean this
        # exact attempt without inferring ownership from a similar path or branch name.
        attempt_started&.call("created_branch" => created_branch)
        result = run_command(
          *argv,
          timeout: checkout_timeout,
          stall_timeout: checkout_stall_timeout,
          output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES,
          progress: progress
        )
        stdout = result.fetch("stdout")
        stderr = result.fetch("stderr")
        status = result.fetch("status")

        unless status.success?
          output = present_output(stderr) || present_output(stdout)
          collision = collision_output?(output)
          disk_exhausted = result.dig("diagnostics", "disk_exhausted") ||
                           disk_exhaustion_output?(stderr) || disk_exhaustion_output?(stdout)
          # A failed attempt must not leave a half-provisioned directory or an unused branch behind,
          # otherwise the next attempt collides with this instance's own leftovers.
          cleanup = cleanup_failed_attempt(
            git_root: git_root,
            worktree_root: worktree_root,
            branch: branch,
            created_branch: created_branch,
            collision: collision,
            preserve_branch: disk_exhausted && branch_preexisting
          )
          failure_kind = if disk_exhausted
                           "disk_exhausted"
                         elsif collision
                           "worktree_collision"
                         else
                           "git_error"
                         end
          recovery = if disk_exhausted
                       # The checkout is safely cleaned, but an immediate retry would consume the
                       # same full filesystem again. Preserve the worker for an explicit retry once
                       # the operator has made headroom.
                       RECOVERY_RESUME
                     elsif transient_output?(output)
                       RECOVERY_RETRY
                     else
                       RECOVERY_NONE
                     end
          error = if disk_exhausted
                    "git worktree add failed: disk is full (no space left on device); " \
                      "free disk space, then prompt this worker to retry provisioning"
                  elsif collision
                    "git worktree add failed: #{output || "exit #{status.exitstatus}"}"
                  else
                    "git worktree add failed: #{failure_summary(output) || "exit #{status.exitstatus}"}"
                  end
          return {
            "retry" => collision,
            "errors" => [error],
            "stdout" => stdout,
            "stderr" => stderr,
            "stdout_bytes" => result.dig("diagnostics", "stdout_bytes"),
            "stderr_bytes" => result.dig("diagnostics", "stderr_bytes"),
            "diagnostics_truncated" => result.dig("diagnostics", "truncated"),
            "exit_status" => status.exitstatus,
            "failure_kind" => failure_kind,
            "recovery" => recovery,
            "cleanup" => cleanup
          }
        end

        {
          "workspace" => candidate_plan.merge(
            "workspace_path" => workspace_path,
            "workspace_root_path" => worktree_root,
            "worktree_root_path" => worktree_root,
            "git_root" => git_root,
            "base_ref" => base_ref,
            "project_relative_path" => relative_project_path,
            "created" => true,
            "errors" => [],
            "stdout" => present_output(stdout),
            "stderr" => present_output(stderr)
          ).compact
        }
      end

      def workspace_owner(plan, git_root:, branch:, worktree_root:)
        {
          "schema_version" => OWNERSHIP_SCHEMA_VERSION,
          "agent_id" => plan.fetch("workspace_owner_id").to_s,
          "project_root" => canonical_path(plan.fetch("project_root")),
          "git_root" => canonical_path(git_root),
          "branch" => branch.to_s,
          "worktree_root" => canonical_path(worktree_root)
        }
      end

      def reserve_workspace_candidate(owner)
        FileUtils.mkdir_p(ownership_directory)
        lock = File.open(workspace_owner_lock_path(owner.fetch("worktree_root")), File::RDWR | File::CREAT, 0o600)
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          current = read_workspace_owner(owner.fetch("worktree_root"))
          same_owner = current && ownership_matches?(current, owner)
          lock.close
          return {
            "acquired" => false,
            "outcome" => {
              # A different owner gets a fresh candidate immediately. A duplicate attempt for the
              # same worker waits for kernel reconciliation instead of provisioning a second tree.
              "retry" => !same_owner,
              "errors" => ["worker workspace reservation is already in progress: #{owner.fetch("worktree_root")}"],
              "failure_kind" => same_owner ? "allocation_in_progress" : "ownership_collision",
              "recovery" => same_owner ? RECOVERY_RETRY : RECOVERY_NONE
            }
          }
        end

        current = read_workspace_owner(owner.fetch("worktree_root"))
        if current && !ownership_matches?(current, owner)
          return {
            "acquired" => false,
            "outcome" => ownership_collision_outcome(owner, current),
            "lock" => lock
          }
        end

        unless current
          foreign_path = Dir.exist?(owner.fetch("worktree_root")) &&
                         (Dir.children(owner.fetch("worktree_root")) - [".DS_Store"]).any?
          foreign_registration = worktree_registered?(owner.fetch("git_root"), owner.fetch("worktree_root"))
          foreign_branch = branch_exists?(owner.fetch("git_root"), owner.fetch("branch"))
          if foreign_path || foreign_registration || foreign_branch
            return {
              "acquired" => false,
              "outcome" => ownership_collision_outcome(owner, nil),
              "lock" => lock
            }
          end
          write_workspace_owner(owner)
        end

        { "acquired" => true, "lock" => lock }
      rescue StandardError => e
        release_candidate_lock(lock)
        {
          "acquired" => false,
          "outcome" => {
            "retry" => false,
            "errors" => ["worker workspace reservation failed: #{e.message}"],
            "failure_kind" => "ownership_reservation_error",
            "recovery" => RECOVERY_RETRY
          }
        }
      end

      def ownership_collision_outcome(owner, current)
        owner_id = current && current["agent_id"]
        suffix = owner_id ? " (owned by #{owner_id})" : " (ownership could not be verified)"
        {
          "retry" => true,
          "errors" => ["worker workspace is already reserved: #{owner.fetch("worktree_root")}#{suffix}"],
          "failure_kind" => "ownership_collision",
          "recovery" => RECOVERY_NONE
        }
      end

      def ownership_directory
        File.join(root_path, OWNERSHIP_DIRECTORY)
      end

      def workspace_owner_key(worktree_root)
        Digest::SHA256.hexdigest(canonical_path(worktree_root))[0, 32]
      end

      def workspace_owner_path(worktree_root)
        File.join(ownership_directory, "#{workspace_owner_key(worktree_root)}.json")
      end

      def workspace_owner_lock_path(worktree_root)
        File.join(ownership_directory, "#{workspace_owner_key(worktree_root)}.lock")
      end

      def read_workspace_owner(worktree_root)
        path = workspace_owner_path(worktree_root)
        return nil unless File.file?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def write_workspace_owner(owner)
        path = workspace_owner_path(owner.fetch("worktree_root"))
        temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(owner))
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary
      end

      def workspace_owned_by?(worktree_root, agent_id:, git_root:, branch:)
        return false if [agent_id, git_root, branch].any? { |value| value.to_s.strip.empty? }

        owner = read_workspace_owner(worktree_root)
        owner && ownership_matches?(
          owner,
          "agent_id" => agent_id.to_s,
          "git_root" => canonical_path(git_root),
          "branch" => branch.to_s,
          "worktree_root" => canonical_path(worktree_root)
        )
      end

      def ownership_matches?(left, right)
        left.fetch("agent_id", nil) == right.fetch("agent_id", nil) &&
          left.fetch("branch", nil) == right.fetch("branch", nil) &&
          same_path?(left.fetch("git_root", ""), right.fetch("git_root", "")) &&
          same_path?(left.fetch("worktree_root", ""), right.fetch("worktree_root", ""))
      end

      def release_workspace_owner(worktree_root, agent_id:, git_root:, branch:)
        return false unless workspace_owned_by?(worktree_root, agent_id: agent_id, git_root: git_root, branch: branch)

        FileUtils.rm_f(workspace_owner_path(worktree_root))
        true
      rescue StandardError
        false
      end

      def release_candidate_lock(lock)
        return unless lock

        lock.flock(File::LOCK_UN)
        lock.close
      rescue IOError, SystemCallError
        nil
      end

      def collision_output?(output)
        output.to_s.match?(COLLISION_ERROR_PATTERN)
      end

      def transient_output?(output)
        return false if collision_output?(output)

        output.to_s.match?(TRANSIENT_ERROR_PATTERN)
      end

      def disk_exhaustion_output?(output)
        output.to_s.match?(DISK_EXHAUSTION_PATTERN)
      end

      def cleanup_failed_attempt(git_root:, worktree_root:, branch:, created_branch:, collision:, preserve_branch: false)
        # A collision means the path or branch belongs to an existing worktree or another actor, so
        # nothing here may be removed. Anything else is this attempt's own debris.
        return { "attempted" => false, "reason" => "collision" } if collision

        cleanup_incomplete_allocation(
          git_root: git_root,
          worktree_root: worktree_root,
          branch: branch,
          created_branch: created_branch,
          preserve_branch: preserve_branch
        )
      rescue StandardError => e
        { "attempted" => true, "error" => e.message }
      end

      def branch_exists?(git_root, branch)
        run_command("git", "-C", git_root, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}").fetch("status").success?
      end

      def branch_checked_out?(git_root, branch)
        worktree_records(git_root).any? { |record| record["branch"] == "refs/heads/#{branch}" }
      end

      def discard_empty_owned_directory(path)
        return false unless owned_workspace_path?(path)
        return false unless (Dir.children(path) - [".DS_Store"]).empty?

        FileUtils.rm_rf(path)
        !Dir.exist?(path)
      rescue StandardError
        false
      end

      def adopt_existing_worktree(plan, git_root:, worktree_root:, workspace_path:, relative_project_path:, base_ref:)
        records = worktree_records(git_root)
        record = records.find { |candidate| canonical_path(candidate.fetch("worktree", "")) == canonical_path(worktree_root) }
        return nil unless record
        return nil unless record.fetch("branch", nil) == "refs/heads/#{plan.fetch("workspace_branch")}"
        return nil if record.key?("locked")
        return nil unless Dir.exist?(workspace_path)

        plan.merge(
          "workspace_path" => workspace_path,
          "workspace_root_path" => worktree_root,
          "worktree_root_path" => worktree_root,
          "git_root" => git_root,
          "base_ref" => base_ref,
          "project_relative_path" => relative_project_path,
          "created" => true,
          "adopted" => true,
          "errors" => []
        )
      end

      def worktree_records(git_root)
        result = run_command("git", "-C", git_root, "worktree", "list", "--porcelain")
        return [] unless result.fetch("status").success?

        parse_worktree_records(result.fetch("stdout"))
      rescue StandardError
        []
      end

      def parse_worktree_records(output)
        output.to_s.split(/\n\n+/).filter_map do |block|
          fields = block.lines.each_with_object({}) do |line, record|
            key, value = line.strip.split(" ", 2)
            record[key] = value if key
          end
          fields unless fields.empty?
        end
      end

      # Deletes an allocator-owned branch only when losing it cannot lose work: it must match the
      # managed delivery convention, not be checked out anywhere, and carry no commit unreachable from
      # every other ref. A branch with commits is always kept, even though that leaves a name
      # Meringue has to work around, because the alternative is destroying a worker's delivery.
      def remove_orphaned_owned_branch(git_root, branch, warnings: nil)
        release_owned_branch(git_root, branch, warnings: warnings || [])
      end

      def release_owned_branch(git_root, branch, warnings: [])
        return "not_owned" unless DeliveryArtifactPolicy.managed_branch?(branch)
        return "absent" unless branch_exists?(git_root, branch)

        if branch_checked_out?(git_root, branch)
          warnings << "left branch #{branch} in place: it is still registered to a worktree"
          return "kept_checked_out"
        end

        commits = unique_commit_count(git_root, branch)
        if commits.nil?
          # Could not prove the branch is empty, so only git's own safe delete may run: it refuses
          # a branch that is not fully merged.
          return "deleted" if delete_branch(git_root, branch, force: false)

          warnings << "left branch #{branch} in place: git refused a safe delete and Meringue " \
                      "could not prove the branch carries no commits"
          return "kept_unverified"
        end
        if commits.positive?
          warnings << "left branch #{branch} in place: it carries #{commits} commit#{"s" unless commits == 1} " \
                      "that exist nowhere else"
          return "kept_has_commits"
        end

        # Verified empty: `-d` first, and `-D` only as the fallback for a branch that is empty but
        # not an ancestor of HEAD (a fresh worker branch off origin/main while HEAD is elsewhere).
        return "deleted" if delete_branch(git_root, branch, force: false)
        return "deleted" if delete_branch(git_root, branch, force: true)

        warnings << "could not delete branch #{branch}"
        "delete_failed"
      end

      def delete_branch(git_root, branch, force:)
        run_command("git", "-C", git_root, "branch", force ? "-D" : "-d", branch).fetch("status").success?
      rescue CommandTimeout
        false
      end

      # Commits reachable from this branch and from no other ref. Zero means deleting the branch
      # cannot orphan anything. nil means the question could not be answered, which callers treat
      # as "assume it has work".
      def unique_commit_count(git_root, branch)
        ref = "refs/heads/#{branch}"
        result = run_command("git", "-C", git_root, "rev-list", "--count", ref, "--not", "--exclude=#{ref}", "--all")
        return nil unless result.fetch("status").success?

        Integer(result.fetch("stdout").to_s.strip)
      rescue ArgumentError, TypeError, CommandTimeout
        nil
      end

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
      def cleanup_incomplete_allocation(git_root:, worktree_root:, branch:, created_branch: true, preserve_branch: false)
        return { "attempted" => false } unless git_root && worktree_root

        warnings = []
        outcome = remove_incomplete_worktree(git_root: git_root, worktree_root: worktree_root, warnings: warnings)
        branch_result = if outcome["worktree_removed"] == false
                          warnings << "left branch #{branch} in place because the partial worktree could not be fully removed"
                          "kept_worktree_remaining"
                        elsif preserve_branch
                          "kept_for_retry"
                        elsif created_branch
                          release_owned_branch(git_root, branch, warnings: warnings)
                        else
                          "kept_pre_existing"
                        end
        outcome.merge(
          "attempted" => true,
          "branch" => branch,
          "branch_result" => branch_result,
          "branch_removed" => branch_result == "deleted",
          "warnings" => warnings
        ).compact
      rescue StandardError => e
        { "attempted" => true, "error" => e.message, "warnings" => ["workspace cleanup failed: #{e.message}"] }
      end

      def remove_incomplete_worktree(git_root:, worktree_root:, warnings:)
        unless owned_workspace_path?(worktree_root)
          warnings << "left #{worktree_root} in place: it is outside the Meringue workspace root"
          return { "worktree_removed" => false, "worktree_remove_status" => nil }
        end

        remove = cleanup_command(git_root, "worktree", "remove", "--force", worktree_root, warnings: warnings)
        status = exit_status_of(remove)
        unless command_succeeded?(remove)
          cleanup_command(git_root, "worktree", "unlock", worktree_root, warnings: nil)
          remove = cleanup_command(git_root, "worktree", "remove", "--force", "--force", worktree_root, warnings: warnings)
          status = exit_status_of(remove)
        end

        if Dir.exist?(worktree_root)
          FileUtils.rm_rf(worktree_root)
          warnings << "could not delete #{worktree_root}" if Dir.exist?(worktree_root)
        end
        # An unlock before pruning is what makes the prune effective: prune skips locked worktrees
        # even when their directory is already gone.
        cleanup_command(git_root, "worktree", "unlock", worktree_root, warnings: nil)
        cleanup_command(git_root, "worktree", "prune", warnings: warnings)

        still_registered = worktree_registered?(git_root, worktree_root)
        if still_registered
          warnings << "worktree #{worktree_root} is still registered in #{git_root}; " \
                      "run `git -C #{git_root} worktree prune` to clear it"
        end
        { "worktree_removed" => !still_registered && !Dir.exist?(worktree_root), "worktree_remove_status" => status }
      end

      def worktree_registered?(git_root, worktree_root)
        worktree_records(git_root).any? { |record| same_path?(record.fetch("worktree", ""), worktree_root) }
      end

      # Cleanup runs after the allocation budget is already spent, so it uses its own budget and
      # never raises: a cleanup command that fails is reported, not propagated over the original
      # provisioning failure.
      def cleanup_command(git_root, *argv, warnings:)
        run_command("git", "-C", git_root, *argv, timeout: cleanup_timeout, deadline: false)
      rescue CommandTimeout => e
        warnings << "#{command_label(e.argv)} timed out after #{e.timeout} seconds during cleanup" if warnings
        nil
      rescue StandardError => e
        warnings << "#{command_label(["git", *argv])} failed during cleanup: #{e.message}" if warnings
        nil
      end

      def command_succeeded?(result)
        result.is_a?(Hash) && result.fetch("status", nil)&.success?
      end

      def exit_status_of(result)
        result.is_a?(Hash) ? result.fetch("status", nil)&.exitstatus : nil
      end

      def owned_workspace_path?(path)
        expanded = canonical_path(path)
        managed_root = canonical_path(root_path)
        expanded.start_with?("#{managed_root}#{File::SEPARATOR}")
      end

      # Names the command a CommandTimeout came from, such as "git worktree add" or "git rev-parse".
      def command_label(argv)
        tokens = Array(argv).map(&:to_s)
        return "git command" if tokens.empty?

        words = [File.basename(tokens.first)]
        index = 1
        while index < tokens.length && words.length < 2
          token = tokens[index]
          if GIT_VALUE_FLAGS.include?(token)
            index += 2
          elsif token.start_with?("-")
            index += 1
          else
            words << token
            index += 1
          end
        end
        next_token = tokens[index]
        if words.length == 2 && GIT_SUBCOMMAND_GROUPS.include?(words.last) && next_token && !next_token.start_with?("-")
          words << next_token
        end
        words.join(" ")
      end

      def isolated_git_argv(argv)
        return argv unless File.basename(argv.first.to_s) == "git"

        [argv.first, *GIT_ISOLATION_ARGS, *argv[1..]]
      end

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
      def run_command(*argv, timeout: command_timeout, stall_timeout: nil, deadline: nil, output_limit: nil, progress: nil)
        requested_argv = argv.map(&:to_s)
        # Every git command Meringue runs is spawned with the isolation flags, so no call site can
        # forget them. Timeouts still report the caller's argv, which reads better in logs.
        effective_argv = isolated_git_argv(requested_argv)
        ceiling = effective_ceiling(timeout, deadline)
        monitor = OutputMonitor.new
        stdout_buffer = DiagnosticBuffer.new(limit: output_limit, on_match: ->(chunk) { monitor.record(chunk) })
        stderr_buffer = DiagnosticBuffer.new(limit: output_limit, on_match: ->(chunk) { monitor.record(chunk) })
        status = nil
        stdin = out = err = wait_thread = nil
        readers = []
        expiry = nil

        # Provider, Git, and diagnostic commands are independent executables. Do not leak
        # `bundle exec`'s RUBYOPT/BUNDLE_GEMFILE into them: in particular, invoking a system
        # Ruby would otherwise try to load this process's Bundler and exit before producing
        # the output the watchdog is responsible for capturing.
        Open3.popen3(SubprocessEnvironment.clean, *effective_argv, pgroup: true) do |child_stdin, child_out, child_err, child_wait|
          stdin = child_stdin
          out = child_out
          err = child_err
          wait_thread = child_wait
          stdin.close
          readers << stream_reader(out, stdout_buffer)
          readers << stream_reader(err, stderr_buffer)
          begin
            expiry = watch_command(
              wait_thread,
              monitor,
              ceiling: ceiling,
              stall_timeout: stall_timeout,
              progress: progress,
              label: command_label(requested_argv)
            )
            status = wait_thread.value unless expiry
          ensure
            terminate_process_group(wait_thread.pid) if status.nil? && wait_thread&.alive?
            readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
            # Closing the pipes unblocks a reader still parked in readpartial, so a child that
            # left a grandchild holding the write end can never wedge this thread.
            out.close unless out.closed?
            err.close unless err.closed?
            readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
            readers.each(&:kill)
          end
        end
        stdout = stdout_buffer.to_s
        stderr = stderr_buffer.to_s
        diagnostics = {
          "stdout_bytes" => stdout_buffer.bytes_seen,
          "stderr_bytes" => stderr_buffer.bytes_seen,
          "truncated" => stdout_buffer.truncated? || stderr_buffer.truncated?,
          "disk_exhausted" => monitor.disk_exhausted?
        }
        if expiry
          raise CommandTimeout.new(
            argv: requested_argv,
            timeout: expiry.fetch("limit"),
            reason: expiry.fetch("reason"),
            elapsed: expiry.fetch("elapsed"),
            stdout: stdout,
            stderr: stderr,
            diagnostics: diagnostics
          )
        end

        {
          "stdout" => stdout,
          "stderr" => stderr,
          "status" => status,
          "argv" => effective_argv,
          "diagnostics" => diagnostics
        }
      ensure
        stdin.close if stdin && !stdin.closed?
      end

      # Returns nil when the command finished on its own, or a description of the bound that
      # fired. Never returns while the command is still allowed to run.
      def watch_command(wait_thread, monitor, ceiling:, stall_timeout:, progress: nil, label: nil)
        started = self.class.monotonic_now
        reported_at = started
        loop do
          # Never sleep past a bound: the poll interval is the ceiling on how long the watchdog
          # can be late, not a fixed granularity.
          now = self.class.monotonic_now
          nap = [
            COMMAND_POLL_INTERVAL,
            ceiling && (started + ceiling - now),
            stall_timeout && (monitor.last_at + stall_timeout - now)
          ].compact.min
          return nil if wait_thread.join([nap, 0.01].max)

          now = self.class.monotonic_now
          elapsed = now - started
          silence = now - monitor.last_at
          if ceiling && elapsed >= ceiling
            return { "reason" => CommandTimeout::BUDGET, "limit" => round_seconds(ceiling), "elapsed" => round_seconds(elapsed) }
          end
          if stall_timeout && silence >= stall_timeout
            return { "reason" => CommandTimeout::STALLED, "limit" => round_seconds(stall_timeout), "elapsed" => round_seconds(elapsed) }
          end
          next unless progress && now - reported_at >= progress_interval

          reported_at = now
          report_progress(progress, label: label, elapsed: elapsed, silence: silence, monitor: monitor)
        end
      end

      def report_progress(progress, label:, elapsed:, silence:, monitor:)
        progress.call(
          "command" => label,
          "elapsed" => round_seconds(elapsed),
          "quiet_for" => round_seconds(silence),
          "detail" => bounded_tail(monitor.last_line, PROGRESS_DETAIL_LIMIT_BYTES)
        )
      rescue StandardError
        nil
      end

      def stream_reader(io, buffer)
        Thread.new do
          loop do
            buffer << io.readpartial(READ_CHUNK_BYTES)
          end
        rescue EOFError, IOError, Errno::EIO
          nil
        end
      end

      def effective_ceiling(timeout, deadline)
        limit = timeout.nil? ? nil : Float(timeout)
        ambient = deadline == false ? nil : (deadline || allocation_deadline)
        return limit unless ambient

        remaining = [ambient - self.class.monotonic_now, 0.0].max
        limit.nil? ? remaining : [limit, remaining].min
      end

      def round_seconds(value)
        (value.to_f * 1000).round / 1000.0
      end

      def set_allocation_deadline!(at)
        Thread.current[:meringue_workspace_allocation_deadline] = at
      end

      def clear_allocation_deadline!
        Thread.current[:meringue_workspace_allocation_deadline] = nil
      end

      def allocation_deadline
        Thread.current[:meringue_workspace_allocation_deadline]
      end

      def positive_float(value, fallback)
        number = Float(value)
        number.positive? ? number : Float(fallback)
      rescue ArgumentError, TypeError
        Float(fallback)
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
        sleep(TERMINATION_GRACE_SECONDS)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def failure_summary(value)
        text = present_output(value)
        return nil unless text

        bounded_tail(text, FAILURE_SUMMARY_LIMIT_BYTES)
      end

      def bounded_tail(value, limit)
        text = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
        return text if text.bytesize <= limit

        tail = text.byteslice(text.bytesize - limit, limit).to_s.force_encoding(Encoding::UTF_8).scrub
        "… [#{text.bytesize - tail.bytesize} earlier bytes omitted] …\n#{tail}"
      end

      def present_output(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def project_slug(value)
        slug = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        slug = slug[0, DeliveryArtifactPolicy::MAX_SLUG_LENGTH].to_s.gsub(/-+\z/, "")
        slug.empty? ? nil : slug
      end
    end
  end
end
