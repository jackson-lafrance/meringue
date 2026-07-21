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
        workspace_path = relative_project_path == "." ? worktree_root : File.join(worktree_root, relative_project_path)
        base_ref = preferred_base_ref(git_root)
        return failed_workspace(plan, ["could not find a git base ref for worker workspace"], git_root: git_root, worktree_root: worktree_root) unless base_ref

        if Dir.exist?(worktree_root)
          adopted = adopt_existing_worktree(plan, git_root: git_root, worktree_root: worktree_root, workspace_path: workspace_path,
                                            relative_project_path: relative_project_path, base_ref: base_ref)
          return adopted if adopted

          return failed_workspace(plan, ["worker worktree path already exists: #{worktree_root}"], git_root: git_root, worktree_root: worktree_root, base_ref: base_ref)
        end

        remove_orphaned_owned_branch(git_root, plan.fetch("workspace_branch"))
        FileUtils.mkdir_p(File.dirname(worktree_root))
        result = run_command(
          "git",
          "-C",
          git_root,
          "worktree",
          "add",
          "-b",
          plan.fetch("workspace_branch"),
          worktree_root,
          base_ref
        )
        stdout = result.fetch("stdout")
        stderr = result.fetch("stderr")
        status = result.fetch("status")

        unless status.success?
          return failed_workspace(
            plan,
            ["git worktree add failed: #{present_output(stderr) || present_output(stdout) || "exit #{status.exitstatus}"}"],
            git_root: git_root,
            worktree_root: worktree_root,
            base_ref: base_ref,
            stdout: stdout,
            stderr: stderr,
            exit_status: status.exitstatus
          )
        end

        plan.merge(
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

      def canonical_path(path)
        expanded = File.expand_path(path.to_s)
        File.exist?(expanded) ? File.realpath(expanded) : expanded
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

        result.fetch("stdout").split(/\n\n+/).filter_map do |block|
          fields = block.lines.each_with_object({}) do |line, record|
            key, value = line.strip.split(" ", 2)
            record[key] = value if key
          end
          fields unless fields.empty?
        end
      rescue StandardError
        []
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
        expanded = File.expand_path(path.to_s)
        expanded.start_with?("#{root_path}#{File::SEPARATOR}")
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
