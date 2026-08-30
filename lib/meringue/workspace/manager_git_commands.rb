# frozen_string_literal: true

module Meringue
  module Workspace
    class Manager
    private
      def discover_shared_read_only_checkout(project_path, repository)
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

        rejected_dirty = false
        candidates = parse_worktree_records(listed.fetch("stdout")).filter_map do |record|
          next if record.key?("bare") || record.key?("locked") || record.key?("prunable")

          branch_ref = record.fetch("branch", nil)
          next unless %w[refs/heads/main refs/heads/master].include?(branch_ref)

          checkout_root = present_output(record.fetch("worktree", nil))
          next unless checkout_root

          checkout_root = canonical_path(checkout_root)
          workspace_path = relative_project_path == "." ? checkout_root : File.join(checkout_root, relative_project_path)
          next unless Dir.exist?(workspace_path) && File.readable?(workspace_path)
          next if bare_repository?(checkout_root)

          clean = shared_checkout_clean?(checkout_root)
          unless clean.fetch("usable", false)
            rejected_dirty ||= clean.fetch("reason", nil) == "shared_checkout_dirty"
            next
          end

          branch = branch_ref.sub(%r{\Arefs/heads/}, "")
          managed = managed_shared_checkout_owner_matches?(
            read_workspace_owner(checkout_root),
            project_root: project_path,
            git_root: git_root,
            branch: branch,
            worktree_root: checkout_root
          )
          shared_checkout_record(
            project_path: project_path,
            git_root: git_root,
            relative_project_path: relative_project_path,
            checkout_root: checkout_root,
            branch: branch,
            managed: managed,
            created: false
          )
        end
        preferred = candidates.find { |candidate| candidate.fetch("managed_shared_checkout", false) } ||
                    candidates.find { |candidate| same_path?(candidate.fetch("workspace_root_path"), git_root) } ||
                    candidates.first
        return preferred if preferred

        reason = if rejected_dirty
                   "shared_checkout_dirty"
                 elsif repository.fetch("bare")
                   "bare_repository_has_no_shared_main_checkout"
                 else
                   "no_readable_main_checkout"
                 end
        reuse_outcome(false, reason, git_root: git_root)
      end

      def provision_managed_shared_read_only_checkout(project_path, repository)
        git_root = repository.fetch("git_root")
        branch = preferred_shared_read_only_branch(git_root)
        return reuse_outcome(false, "shared_checkout_main_branch_missing", git_root: git_root) unless branch

        checkout_root = managed_shared_checkout_path(project_path, git_root)
        owner = managed_shared_checkout_owner(
          project_root: project_path,
          git_root: git_root,
          branch: branch,
          worktree_root: checkout_root
        )
        FileUtils.mkdir_p(ownership_directory)
        lock = File.open(workspace_owner_lock_path(checkout_root), File::RDWR | File::CREAT, 0o600)
        lock.flock(File::LOCK_EX)

        # Another process may have completed provisioning while this caller waited for the lock.
        existing = discover_shared_read_only_checkout(project_path, repository)
        return existing if existing.fetch("strategy", nil) == "shared_checkout"

        current_owner = read_workspace_owner(checkout_root)
        if current_owner && !managed_shared_checkout_owner_matches?(
          current_owner,
          project_root: project_path,
          git_root: git_root,
          branch: branch,
          worktree_root: checkout_root
        )
          return reuse_outcome(false, "managed_shared_checkout_owner_mismatch", worktree_root_path: checkout_root)
        end

        if current_owner
          recovered = recover_incomplete_managed_shared_checkout(
            git_root: git_root,
            worktree_root: checkout_root,
            branch: branch
          )
          return recovered unless recovered.fetch("usable", false)
        elsif Dir.exist?(checkout_root) && (Dir.children(checkout_root) - [".DS_Store"]).any?
          return reuse_outcome(false, "managed_shared_checkout_path_occupied", worktree_root_path: checkout_root)
        end

        FileUtils.rm_rf(checkout_root) if Dir.exist?(checkout_root) && Dir.children(checkout_root).empty?
        FileUtils.mkdir_p(File.dirname(checkout_root))
        write_workspace_owner(owner)
        added = run_command(
          "git", "-C", git_root, "worktree", "add", checkout_root, branch,
          timeout: checkout_timeout,
          stall_timeout: checkout_stall_timeout,
          output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES,
          deadline: false
        )
        unless added.fetch("status").success?
          cleanup_incomplete_allocation(
            git_root: git_root,
            worktree_root: checkout_root,
            branch: branch,
            created_branch: false,
            preserve_branch: true
          )
          FileUtils.rm_f(workspace_owner_path(checkout_root))
          error = present_output(added.fetch("stderr")) || present_output(added.fetch("stdout"))
          return reuse_outcome(false, "managed_shared_checkout_create_failed", error: error, git_root: git_root)
        end

        record = shared_checkout_record(
          project_path: project_path,
          git_root: git_root,
          relative_project_path: ".",
          checkout_root: checkout_root,
          branch: branch,
          managed: true,
          created: true
        )
        validation = validate_worker_workspace(record)
        return record if validation.fetch("usable", false)

        reuse_outcome(false, validation.fetch("reason", "managed_shared_checkout_validation_failed"), git_root: git_root)
      rescue CommandTimeout => e
        cleanup_incomplete_allocation(
          git_root: git_root,
          worktree_root: checkout_root,
          branch: branch,
          created_branch: false,
          preserve_branch: true
        ) if defined?(git_root) && defined?(checkout_root) && defined?(branch)
        FileUtils.rm_f(workspace_owner_path(checkout_root)) if defined?(checkout_root)
        reuse_outcome(false, "managed_shared_checkout_create_timed_out", error: e.message)
      ensure
        release_candidate_lock(lock)
      end

      def recover_incomplete_managed_shared_checkout(git_root:, worktree_root:, branch:)
        listed = run_command("git", "-C", git_root, "worktree", "list", "--porcelain")
        return reuse_outcome(false, "worktree_list_failed") unless listed.fetch("status").success?

        record = parse_worktree_records(listed.fetch("stdout")).find do |candidate|
          same_path?(candidate.fetch("worktree", ""), worktree_root)
        end
        if record && Dir.exist?(worktree_root) && !record.key?("locked") && !record.key?("prunable")
          # A registered completed cache is never cleanup debris. If it became dirty, moved branch,
          # or otherwise failed validation, preserve it for diagnosis rather than deleting files
          # merely because the owner marker says Meringue originally created the checkout.
          return reuse_outcome(false, "managed_shared_checkout_branch_moved") unless record.fetch("branch", nil) == "refs/heads/#{branch}"

          clean = shared_checkout_clean?(worktree_root)
          return reuse_outcome(false, "managed_shared_checkout_already_complete") if clean.fetch("usable", false)

          return reuse_outcome(false, "managed_shared_checkout_dirty") if clean.fetch("reason", nil) == "shared_checkout_dirty"
          return clean
        end
        return reuse_outcome(true, "managed_shared_checkout_recovery_not_needed") unless record || Dir.exist?(worktree_root)

        # Ownership plus an absent, locked, or prunable registration proves this path never reached
        # launch validation. Remove only that interrupted cache; main/master itself is preserved.
        cleanup = cleanup_incomplete_allocation(
          git_root: git_root,
          worktree_root: worktree_root,
          branch: nil,
          created_branch: false,
          preserve_branch: true
        )
        return reuse_outcome(false, "managed_shared_checkout_recovery_failed") unless cleanup.fetch("worktree_removed", false)

        reuse_outcome(true, "managed_shared_checkout_recovered")
      end

      def preferred_shared_read_only_branch(git_root)
        %w[main master].find { |branch| branch_exists?(git_root, branch) }
      end

      def managed_shared_checkout_path(project_path, git_root)
        slug = project_slug(File.basename(project_path)) || "project"
        suffix = Digest::SHA256.hexdigest(canonical_path(git_root))[0, 12]
        File.join(root_path, SHARED_READ_ONLY_DIRECTORY, "#{slug}-#{suffix}")
      end

      def managed_shared_checkout_owner(project_root:, git_root:, branch:, worktree_root:)
        {
          "schema_version" => OWNERSHIP_SCHEMA_VERSION,
          "owner_kind" => SHARED_READ_ONLY_OWNER_KIND,
          "project_root" => canonical_path(project_root),
          "git_root" => canonical_path(git_root),
          "branch" => branch.to_s,
          "worktree_root" => canonical_path(worktree_root)
        }
      end

      def managed_shared_checkout_owner_matches?(owner, project_root:, git_root:, branch:, worktree_root:)
        return false unless owner.is_a?(Hash) && owner.fetch("owner_kind", nil) == SHARED_READ_ONLY_OWNER_KIND

        owner.fetch("schema_version", nil) == OWNERSHIP_SCHEMA_VERSION &&
          same_path?(owner.fetch("project_root", ""), project_root) &&
          same_path?(owner.fetch("git_root", ""), git_root) &&
          owner.fetch("branch", nil) == branch.to_s &&
          same_path?(owner.fetch("worktree_root", ""), worktree_root)
      end

      def shared_checkout_record(project_path:, git_root:, relative_project_path:, checkout_root:, branch:, managed:, created:)
        workspace_path = relative_project_path == "." ? checkout_root : File.join(checkout_root, relative_project_path)
        {
          "strategy" => "shared_checkout",
          "workspace_strategy" => "shared_checkout",
          "project_root" => project_path,
          "workspace_path" => canonical_path(workspace_path),
          "workspace_root_path" => checkout_root,
          "worktree_root_path" => checkout_root,
          "workspace_branch" => branch,
          "git_root" => git_root,
          "project_relative_path" => relative_project_path,
          "created" => created,
          "managed_shared_checkout" => managed,
          "read_only" => true,
          "errors" => []
        }
      end

      def shared_checkout_clean?(checkout_root)
        status = run_command("git", "-C", checkout_root, "status", "--porcelain", "--untracked-files=all")
        unless status.fetch("status").success?
          return reuse_outcome(
            false,
            "shared_checkout_status_failed",
            error: present_output(status.fetch("stderr")) || present_output(status.fetch("stdout"))
          )
        end
        return reuse_outcome(false, "shared_checkout_dirty") unless status.fetch("stdout").to_s.empty?

        reuse_outcome(true, "shared_checkout_clean")
      end

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

      def candidate_allocation(plan, attempt)
        branch = plan.fetch("workspace_branch")
        worktree_root = File.expand_path(plan.fetch("workspace_path"))
        return { "branch" => branch, "worktree_root" => worktree_root } if attempt.zero?

        suffix = "-#{attempt + 1}"
        { "branch" => "#{branch}#{suffix}", "worktree_root" => "#{worktree_root}#{suffix}" }
      end

      def allocate_candidate_worktree(plan:, git_root:, base_ref:, relative_project_path:, branch:, worktree_root:,
                                      owner:, progress: nil, attempt_started: nil, profile: nil)
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
          profile: profile,
          attempt_started: attempt_started
        )
      ensure
        release_candidate_lock(reservation && reservation["lock"])
      end

      def allocate_reserved_candidate_worktree(plan:, git_root:, base_ref:, relative_project_path:, branch:, worktree_root:,
                                               progress: nil, attempt_started: nil, profile: nil)
        selected_provider = worktree_provider
        if selected_provider.external?
          incompatibility = external_provider_profile_incompatibility(profile)
          if incompatibility
            return external_provider_unavailable_outcome(selected_provider, incompatibility) unless native_provider_fallback?

            plan = worktree_provider_fallback_plan(plan, selected_provider, incompatibility)
          else
            external = allocate_external_candidate_worktree(
              provider: selected_provider,
              plan: plan,
              git_root: git_root,
              base_ref: base_ref,
              relative_project_path: relative_project_path,
              branch: branch,
              reservation_root: worktree_root,
              progress: progress,
              attempt_started: attempt_started,
              profile: synthetic_bare_profile?(profile) ? nil : profile
            )
            return external unless external.fetch("fallback_to_native", false)

            reason = external.fetch("fallback_reason", "external_provider_unavailable")
            return external_provider_unavailable_outcome(selected_provider, reason) unless native_provider_fallback?

            plan = worktree_provider_fallback_plan(plan, selected_provider, reason)
          end
        end

        candidate_plan = plan.merge("workspace_branch" => branch, "workspace_path" => worktree_root)
        attach_profile_metadata(candidate_plan, profile)
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
        sparse = profile&.sparse?
        no_checkout = sparse ? ["--no-checkout"] : []
        argv = if created_branch
                 # `origin/main` normally makes Git auto-write branch tracking config. Two otherwise
                 # independent concurrent adds then race on `.git/config.lock`. Workers push their
                 # explicit task branch and do not need an implicit upstream at checkout time, so
                 # suppress that shared config mutation and keep distinct candidate checkouts truly
                 # parallel.
                 ["git", "-C", git_root, "worktree", "add", *no_checkout, "--no-track", "-b", branch, worktree_root, base_ref]
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
                 ["git", "-C", git_root, "worktree", "add", *no_checkout, worktree_root, branch]
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

        sparse_result = if sparse
                          apply_sparse_checkout(
                            git_root: git_root,
                            worktree_root: worktree_root,
                            profile: profile,
                            progress: progress
                          )
                        end
        if sparse_result && !sparse_result.fetch("success", false)
          cleanup = cleanup_failed_attempt(
            git_root: git_root,
            worktree_root: worktree_root,
            branch: branch,
            created_branch: created_branch,
            collision: false,
            preserve_branch: false
          )
          return {
            "retry" => false,
            "errors" => sparse_result.fetch("errors"),
            "stdout" => sparse_result["stdout"],
            "stderr" => sparse_result["stderr"],
            "exit_status" => sparse_result["exit_status"],
            "failure_kind" => sparse_result.fetch("failure_kind", "sparse_checkout_failed"),
            "recovery" => RECOVERY_RESUME,
            "cleanup" => cleanup
          }
        end

        validation_result = nil
        if profile&.validation?
          validation_result = run_profile_validation(
            worktree_root: worktree_root,
            workspace_path: workspace_path,
            profile: profile
          )
          unless validation_result.fetch("success", false)
            cleanup = cleanup_failed_attempt(
              git_root: git_root,
              worktree_root: worktree_root,
              branch: branch,
              created_branch: created_branch,
              collision: false,
              preserve_branch: false
            )
            return {
              "retry" => false,
              "errors" => validation_result.fetch("errors"),
              "stdout" => validation_result["stdout"],
              "stderr" => validation_result["stderr"],
              "exit_status" => validation_result["exit_status"],
              "failure_kind" => "validation_failed",
              "recovery" => RECOVERY_RESUME,
              "cleanup" => cleanup
            }
          end
        end

        record = candidate_plan.merge(
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
        record["sparse_checkout"] = sparse_result.fetch("record", nil) if sparse_result
        record["profile_validation"] = validation_result if validation_result
        { "workspace" => record }
      end

      def allocate_external_candidate_worktree(provider:, plan:, git_root:, base_ref:, relative_project_path:, branch:,
                                                reservation_root:, progress:, attempt_started:, profile:)
        control = external_provider_control_directory(plan.fetch("project_root"))
        unless control.fetch("path", nil)
          return {
            "fallback_to_native" => true,
            "fallback_reason" => control.fetch("reason", "provider_control_directory_unavailable")
          }
        end
        unless provider.configured?
          return {
            "fallback_to_native" => true,
            "fallback_reason" => "workspace.worktree_provider_command is not configured"
          }
        end

        provider_cwd = control.fetch("path")
        provider_name = File.basename(reservation_root)
        existing = worktree_records_for_branch(git_root, branch)
        if existing.one?
          adopted = adopt_external_worktree(
            provider: provider,
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: branch,
            record: existing.first,
            provider_name: provider_name,
            provider_cwd: provider_cwd,
            reservation_root: reservation_root
          )
          return { "workspace" => adopted } if adopted

          return {
            "retry" => true,
            "errors" => ["worker branch #{branch} is checked out in a worktree not owned by this worker"],
            "failure_kind" => "branch_collision",
            "recovery" => RECOVERY_NONE
          }
        elsif existing.length > 1
          return {
            "retry" => false,
            "errors" => ["configured worktree provider cannot provision #{branch}: Git reports it in multiple worktrees"],
            "failure_kind" => "ambiguous_provider_worktree",
            "recovery" => RECOVERY_NONE
          }
        end

        branch_preexisting = branch_exists?(git_root, branch)
        remove_orphaned_owned_branch(git_root, branch) if branch_preexisting
        created_branch = !branch_exists?(git_root, branch)
        if created_branch
          branch_result = run_command("git", "-C", git_root, "branch", branch, base_ref)
          unless branch_result.fetch("status").success?
            output = present_output(branch_result.fetch("stderr")) || present_output(branch_result.fetch("stdout"))
            return {
              "retry" => false,
              "errors" => ["could not prepare branch #{branch} for the configured worktree provider: " \
                           "#{failure_summary(output) || "git exited #{branch_result.fetch("status").exitstatus}"}"],
              "failure_kind" => "provider_branch_setup_failed",
              "recovery" => RECOVERY_NONE
            }
          end
        end

        attempt_started&.call("created_branch" => created_branch)
        argv = provider.provision_argv(
          name: provider_name,
          branch: branch,
          base_ref: base_ref,
          git_root: git_root,
          project_root: plan.fetch("project_root")
        )
        begin
          result = run_command(
            *argv,
            chdir: provider_cwd,
            timeout: checkout_timeout,
            stall_timeout: checkout_stall_timeout,
            output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES,
            progress: progress
          )
        rescue Errno::ENOENT => e
          release_owned_branch(git_root, branch) if created_branch && !native_provider_fallback?
          return {
            "fallback_to_native" => true,
            "fallback_reason" => "configured worktree provider command is unavailable (#{e.message})"
          }
        end
        unless result.fetch("status").success?
          return failed_external_provision(
            provider: provider,
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: branch,
            provider_name: provider_name,
            provider_cwd: provider_cwd,
            reservation_root: reservation_root,
            created_branch: created_branch,
            stdout: result.fetch("stdout"),
            stderr: result.fetch("stderr"),
            status: result.fetch("status"),
            diagnostics: result.fetch("diagnostics", {})
          )
        end

        begin
          provider_response = provider.parse_response(result.fetch("stdout"), action: "provision")
        rescue WorktreeProvider::InvalidResponse => e
          return failed_external_provision(
            provider: provider,
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: branch,
            provider_name: provider_name,
            provider_cwd: provider_cwd,
            reservation_root: reservation_root,
            created_branch: created_branch,
            stdout: result.fetch("stdout"),
            stderr: "provider returned an invalid success response: #{e.message}",
            status: FailureStatus.new(1),
            diagnostics: result.fetch("diagnostics", {})
          )
        end

        records = worktree_records_for_branch(git_root, branch)
        unless records.one?
          return failed_external_provision(
            provider: provider,
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: branch,
            provider_name: provider_name,
            provider_cwd: provider_cwd,
            reservation_root: reservation_root,
            created_branch: created_branch,
            stdout: result.fetch("stdout"),
            stderr: "provider exited successfully, but Git registered #{records.length} worktrees for #{branch}",
            status: FailureStatus.new(1),
            diagnostics: result.fetch("diagnostics", {})
          )
        end

        workspace = external_workspace_record(
          provider: provider,
          provider_response: provider_response,
          plan: plan,
          git_root: git_root,
          base_ref: base_ref,
          relative_project_path: relative_project_path,
          branch: branch,
          record: records.first,
          provider_name: provider_name,
          provider_cwd: provider_cwd,
          stdout: result.fetch("stdout"),
          stderr: result.fetch("stderr")
        )
        unless workspace && transfer_external_workspace_owner(plan, workspace, reservation_root: reservation_root)
          return {
            "retry" => false,
            "errors" => ["configured worktree provider created a worktree, but Meringue could not claim its exact path safely"],
            "failure_kind" => "provider_workspace_ownership_collision",
            "recovery" => RECOVERY_RESUME
          }
        end

        if profile&.validation?
          validation = run_profile_validation(
            worktree_root: workspace.fetch("worktree_root_path"),
            workspace_path: workspace.fetch("workspace_path"),
            profile: profile
          )
          workspace["profile_validation"] = validation
          unless validation.fetch("success", false)
            cleanup = release_external_workspace(workspace, provider: provider, preserve_branch: !created_branch)
            return {
              "retry" => false,
              "errors" => validation.fetch("errors"),
              "stdout" => validation["stdout"],
              "stderr" => validation["stderr"],
              "exit_status" => validation["exit_status"],
              "failure_kind" => "validation_failed",
              "recovery" => RECOVERY_RESUME,
              "cleanup" => cleanup
            }
          end
        end

        { "workspace" => workspace }
      rescue CommandTimeout => e
        failed_external_provision(
          provider: provider,
          plan: plan,
          git_root: git_root,
          base_ref: base_ref,
          relative_project_path: relative_project_path,
          branch: branch,
          provider_name: provider_name,
          provider_cwd: provider_cwd,
          reservation_root: reservation_root,
          created_branch: defined?(created_branch) && created_branch,
          stdout: e.stdout,
          stderr: e.stderr,
          status: FailureStatus.new(124),
          diagnostics: e.diagnostics || {},
          timeout: e
        )
      rescue StandardError => e
        {
          "retry" => false,
          "errors" => ["configured worktree provider failed: #{e.message}"],
          "failure_kind" => "external_provider_error",
          "recovery" => RECOVERY_RESUME
        }
      end

    end
  end
end
