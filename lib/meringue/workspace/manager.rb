# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"
require "timeout"

module Meringue
  module Workspace
    class Manager
      DEFAULT_ROOT = File.expand_path("~/.meringue/workspaces")
      DEFAULT_COMMAND_TIMEOUT = 60
      TERMINATION_GRACE_SECONDS = 1
      # A worker branch/worktree can already exist when a previous attempt was interrupted or when
      # another actor provisioned the same worker concurrently. Reuse it when it is usable, and
      # otherwise fall back to a uniquified branch/path instead of failing the spawn.
      ALLOCATION_ATTEMPT_LIMIT = 3
      COLLISION_ERROR_PATTERN = /already exists|already used by worktree|is already checked out/i

      class CommandTimeout < StandardError
        attr_reader :argv, :timeout, :stdout, :stderr

        def initialize(argv:, timeout:, stdout:, stderr:)
          @argv = argv
          @timeout = timeout
          @stdout = stdout
          @stderr = stderr
          super("command timed out after #{timeout} seconds: #{argv.join(" ")}")
        end
      end

      attr_reader :root_path, :command_timeout

      def initialize(root_path: DEFAULT_ROOT, command_timeout: DEFAULT_COMMAND_TIMEOUT)
        @root_path = File.expand_path(root_path)
        @command_timeout = Float(command_timeout)
      end

      def plan_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil)
        safe_project_name = human_slug(File.basename(File.expand_path(project_root))) || "project"
        safe_task_name = human_slug(task_title) || "task"
        unique_suffix = Digest::SHA256.hexdigest(
          [File.expand_path(project_root), project_id, issue_id, agent_id, safe_task_name].join("\0")
        )[0, 8]
        workspace_name = [safe_task_name, unique_suffix].join("-")
        branch = "meringue/#{workspace_name}"
        workspace_path = File.join(root_path, safe_project_name, workspace_name)

        {
          "strategy" => "git_worktree",
          "project_root" => File.expand_path(project_root),
          "workspace_path" => workspace_path,
          "workspace_branch" => branch,
          "created" => false
        }
      end

      def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil)
        plan = nil
        plan = plan_worker_workspace(
          project_root: project_root,
          project_id: project_id,
          issue_id: issue_id,
          agent_id: agent_id,
          task_title: task_title
        )
        project_path = canonical_path(project_root)
        plan["project_root"] = project_path
        git_root = git_root_for(project_path)
        return project_root_workspace(project_path, plan, "project root is not inside a git repository") unless git_root

        worktree_root = File.expand_path(plan.fetch("workspace_path"))
        relative_project_path = relative_path(project_path, git_root)
        base_ref = preferred_base_ref(git_root)
        return failed_workspace(plan, ["could not find a git base ref for worker workspace"], git_root: git_root, worktree_root: worktree_root) unless base_ref

        errors = []
        last_failure = nil
        ALLOCATION_ATTEMPT_LIMIT.times do |attempt|
          candidate = candidate_allocation(plan, attempt)
          worktree_root = candidate.fetch("worktree_root")
          outcome = allocate_candidate_worktree(
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: candidate.fetch("branch"),
            worktree_root: worktree_root
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
          exit_status: last_failure && last_failure["exit_status"]
        )
      rescue CommandTimeout => e
        cleanup = cleanup_incomplete_allocation(
          git_root: defined?(git_root) && git_root,
          worktree_root: defined?(worktree_root) && worktree_root,
          branch: plan && plan["workspace_branch"]
        )
        failed_workspace(
          plan,
          ["git worktree add timed out after #{e.timeout} seconds"],
          git_root: defined?(git_root) && git_root,
          worktree_root: defined?(worktree_root) && worktree_root,
          base_ref: defined?(base_ref) && base_ref,
          stdout: e.stdout,
          stderr: e.stderr,
          timed_out: true,
          timeout_seconds: e.timeout,
          cleanup: cleanup
        )
      rescue StandardError => e
        failed_workspace(plan, ["worker workspace allocation failed: #{e.message}"])
      end

      def release_worker_workspace(workspace, delete_branch: false)
        return false unless workspace.is_a?(Hash)
        return false unless workspace.fetch("created", false)
        return false unless workspace.fetch("strategy", workspace.fetch("workspace_strategy", nil)) == "git_worktree"

        git_root = workspace["git_root"] || workspace.dig("plan", "git_root") || workspace["project_root"]
        worktree_root = workspace["worktree_root_path"] || workspace["workspace_root_path"] || workspace.dig("plan", "worktree_root_path") || workspace["workspace_path"]
        return false unless git_root && worktree_root && Dir.exist?(worktree_root.to_s)

        result = run_command("git", "-C", git_root.to_s, "worktree", "remove", "--force", worktree_root.to_s)
        return false unless result.fetch("status").success?

        branch = workspace["workspace_branch"] || workspace.dig("plan", "workspace_branch")
        run_command("git", "-C", git_root.to_s, "branch", "-D", branch.to_s) if delete_branch && branch
        true
      rescue StandardError
        false
      end

      # Pruning uses a deliberately stricter cleanup path than failed provisioning. It removes
      # only a registered, clean, unlocked Meringue worktree whose path and branch still match the
      # persisted ownership record. Branches are retained so delivered commits remain reachable.
      # A structured result lets the kernel retain the record and explain anything unsafe to
      # remove instead of forcing or guessing.
      def cleanup_pruned_worker_workspace(workspace, protected_paths: [])
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
        unless branch.to_s.start_with?("meringue/")
          return cleanup_outcome("failed", "branch_not_meringue_managed", success: false, **base)
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

        listed = run_command("git", "-C", git_root, "worktree", "list", "--porcelain")
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

          return cleanup_outcome("already_removed", "worktree_already_removed", success: true, **base)
        end
        unless record.fetch("branch", nil) == "refs/heads/#{branch}"
          return cleanup_outcome("failed", "worktree_branch_mismatch", success: false, **base)
        end
        if record.key?("locked")
          return cleanup_outcome("failed", "worktree_locked", success: false, **base)
        end

        if Dir.exist?(worktree_root)
          dirty = run_command("git", "-C", worktree_root, "status", "--porcelain", "--untracked-files=all")
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

        removed = run_command("git", "-C", git_root, "worktree", "remove", worktree_root)
        unless removed.fetch("status").success?
          output = present_output(removed.fetch("stderr")) || present_output(removed.fetch("stdout"))
          reason = output.to_s.match?(/locked/i) ? "worktree_locked" : "worktree_remove_failed"
          return cleanup_outcome("failed", reason, success: false, attempted: true, error: output, **base)
        end

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

      def git_root_for(project_path)
        return nil unless Dir.exist?(project_path)

        result = run_command("git", "-C", project_path, "rev-parse", "--show-toplevel")
        return nil unless result.fetch("status").success?

        canonical_path(result.fetch("stdout").strip)
      rescue CommandTimeout
        raise
      rescue StandardError
        nil
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

      def failed_workspace(plan, errors, git_root: nil, worktree_root: nil, base_ref: nil, stdout: nil, stderr: nil, exit_status: nil,
                           timed_out: false, timeout_seconds: nil, cleanup: nil)
        (plan || {}).merge(
          "git_root" => git_root,
          "workspace_root_path" => worktree_root,
          "worktree_root_path" => worktree_root,
          "base_ref" => base_ref,
          "created" => false,
          "errors" => Array(errors).compact,
          "stdout" => present_output(stdout),
          "stderr" => present_output(stderr),
          "exit_status" => exit_status,
          "timed_out" => timed_out,
          "timeout_seconds" => timeout_seconds,
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

      def allocate_candidate_worktree(plan:, git_root:, base_ref:, relative_project_path:, branch:, worktree_root:)
        candidate_plan = plan.merge("workspace_branch" => branch, "workspace_path" => worktree_root)
        workspace_path = relative_project_path == "." ? worktree_root : File.join(worktree_root, relative_project_path)

        if Dir.exist?(worktree_root)
          adopted = adopt_existing_worktree(candidate_plan, git_root: git_root, worktree_root: worktree_root, workspace_path: workspace_path,
                                            relative_project_path: relative_project_path, base_ref: base_ref)
          return { "workspace" => adopted } if adopted

          discarded = discard_empty_owned_directory(worktree_root)
          return { "retry" => true, "errors" => ["worker worktree path already exists: #{worktree_root}"] } unless discarded
        end

        remove_orphaned_owned_branch(git_root, branch)
        FileUtils.mkdir_p(File.dirname(worktree_root))
        created_branch = !branch_exists?(git_root, branch)
        argv = if branch_exists?(git_root, branch)
                 return { "retry" => true, "errors" => ["worker branch #{branch} is checked out in another worktree"] } if branch_checked_out?(git_root, branch)

                 # The branch survived a previous attempt for this worker; check it out instead of
                 # failing on "a branch named ... already exists".
                 ["git", "-C", git_root, "worktree", "add", worktree_root, branch]
               else
                 ["git", "-C", git_root, "worktree", "add", "-b", branch, worktree_root, base_ref]
               end
        result = run_command(*argv)
        stdout = result.fetch("stdout")
        stderr = result.fetch("stderr")
        status = result.fetch("status")

        unless status.success?
          output = present_output(stderr) || present_output(stdout)
          # A failed attempt must not leave a half-provisioned directory or an unused branch behind,
          # otherwise the next attempt collides with this instance's own leftovers.
          cleanup_failed_attempt(git_root: git_root, worktree_root: worktree_root, branch: branch,
                                 created_branch: created_branch, collision: collision_output?(output))
          return {
            "retry" => collision_output?(output),
            "errors" => ["git worktree add failed: #{output || "exit #{status.exitstatus}"}"],
            "stdout" => stdout,
            "stderr" => stderr,
            "exit_status" => status.exitstatus
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

      def collision_output?(output)
        output.to_s.match?(COLLISION_ERROR_PATTERN)
      end

      def cleanup_failed_attempt(git_root:, worktree_root:, branch:, created_branch:, collision:)
        discard_empty_owned_directory(worktree_root)
        # Only remove a branch this attempt intended to create; a collision means the branch belongs
        # to an existing worktree or another actor.
        remove_orphaned_owned_branch(git_root, branch) if created_branch && !collision
      rescue StandardError
        nil
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

      def remove_orphaned_owned_branch(git_root, branch)
        return unless branch.to_s.start_with?("meringue/")
        return if worktree_records(git_root).any? { |record| record["branch"] == "refs/heads/#{branch}" }

        result = run_command("git", "-C", git_root, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
        run_command("git", "-C", git_root, "branch", "-D", branch) if result.fetch("status").success?
      end

      def cleanup_incomplete_allocation(git_root:, worktree_root:, branch:)
        return { "attempted" => false } unless git_root && worktree_root && branch.to_s.start_with?("meringue/")

        remove = run_command("git", "-C", git_root, "worktree", "remove", "--force", worktree_root, timeout: TERMINATION_GRACE_SECONDS * 5)
        FileUtils.rm_rf(worktree_root) if owned_workspace_path?(worktree_root)
        run_command("git", "-C", git_root, "worktree", "prune", timeout: TERMINATION_GRACE_SECONDS * 5)
        remove_orphaned_owned_branch(git_root, branch)
        { "attempted" => true, "worktree_remove_status" => remove.fetch("status").exitstatus }
      rescue StandardError => e
        { "attempted" => true, "error" => e.message }
      end

      def owned_workspace_path?(path)
        expanded = canonical_path(path)
        managed_root = canonical_path(root_path)
        expanded.start_with?("#{managed_root}#{File::SEPARATOR}")
      end

      def run_command(*argv, timeout: command_timeout)
        stdout = +""
        stderr = +""
        status = nil
        stdin = out = err = wait_thread = nil
        readers = []

        Open3.popen3(*argv, pgroup: true) do |child_stdin, child_out, child_err, child_wait|
          stdin = child_stdin
          out = child_out
          err = child_err
          wait_thread = child_wait
          stdin.close
          readers << Thread.new { stdout << out.read.to_s }
          readers << Thread.new { stderr << err.read.to_s }
          begin
            Timeout.timeout(timeout) { status = wait_thread.value }
          rescue Timeout::Error
            terminate_process_group(wait_thread.pid)
            readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
            raise CommandTimeout.new(argv: argv, timeout: timeout, stdout: stdout, stderr: stderr)
          ensure
            terminate_process_group(wait_thread.pid) if status.nil? && wait_thread&.alive?
            readers.each(&:join)
            out.close unless out.closed?
            err.close unless err.closed?
          end
        end
        { "stdout" => stdout, "stderr" => stderr, "status" => status }
      ensure
        stdin.close if stdin && !stdin.closed?
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
        sleep(TERMINATION_GRACE_SECONDS)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def present_output(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def human_slug(value)
        text = value.to_s.gsub(/\bP\d+(?:-I\d+)?(?:-W\d+)?\b/i, " ")
        text = text.gsub(/\b[HQ]\d+\b/i, " ")
        slug = text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        slug = slug[0, 48].gsub(/-+\z/, "")
        slug.empty? ? nil : slug
      end
    end
  end
end
