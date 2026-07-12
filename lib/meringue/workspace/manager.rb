# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"

module Meringue
  module Workspace
    class Manager
      DEFAULT_ROOT = File.expand_path("~/.meringue/workspaces")

      attr_reader :root_path

      def initialize(root_path: DEFAULT_ROOT)
        @root_path = File.expand_path(root_path)
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
          return failed_workspace(plan, ["worker worktree path already exists: #{worktree_root}"], git_root: git_root, worktree_root: worktree_root, base_ref: base_ref)
        end

        FileUtils.mkdir_p(File.dirname(worktree_root))
        stdout, stderr, status = Open3.capture3(
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

        _stdout, _stderr, status = Open3.capture3("git", "-C", git_root.to_s, "worktree", "remove", "--force", worktree_root.to_s)
        return false unless status.success?

        branch = workspace["workspace_branch"] || workspace.dig("plan", "workspace_branch")
        Open3.capture3("git", "-C", git_root.to_s, "branch", "-D", branch.to_s) if delete_branch && branch
        true
      rescue StandardError
        false
      end

      private

      def git_root_for(project_path)
        return nil unless Dir.exist?(project_path)

        stdout, _stderr, status = Open3.capture3("git", "-C", project_path, "rev-parse", "--show-toplevel")
        return nil unless status.success?

        canonical_path(stdout.strip)
      rescue StandardError
        nil
      end

      def preferred_base_ref(git_root)
        %w[origin/main origin/master main master HEAD].find do |ref|
          _stdout, _stderr, status = Open3.capture3("git", "-C", git_root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
          status.success?
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

      def failed_workspace(plan, errors, git_root: nil, worktree_root: nil, base_ref: nil, stdout: nil, stderr: nil, exit_status: nil)
        (plan || {}).merge(
          "git_root" => git_root,
          "workspace_root_path" => worktree_root,
          "worktree_root_path" => worktree_root,
          "base_ref" => base_ref,
          "created" => false,
          "errors" => Array(errors).compact,
          "stdout" => present_output(stdout),
          "stderr" => present_output(stderr),
          "exit_status" => exit_status
        ).compact
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
