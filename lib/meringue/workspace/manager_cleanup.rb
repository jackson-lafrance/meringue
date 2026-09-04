# frozen_string_literal: true

module Meringue
  module Workspace
    # Release and cleanup of worker worktrees: giving a failed or finished
    # worker's checkout back, inspecting a settled predecessor's worktree before
    # a continuation inherits it, and the stricter non-forced removal used when
    # a record is pruned. Planning, allocation, and validation stay in
    # `manager.rb`.
    class Manager
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

        worktree_missing = !Dir.exist?(worktree_root)
        if !worktree_missing
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
        details = worktree_missing ? { worktree_missing: true } : {}
        cleanup_outcome("removed", "worktree_removed", success: true, attempted: true, **details, **base)
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
    end
  end
end
