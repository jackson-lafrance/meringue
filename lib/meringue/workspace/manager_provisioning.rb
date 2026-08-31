# frozen_string_literal: true

module Meringue
  module Workspace
    class Manager
    private
      def failed_external_provision(provider:, plan:, git_root:, base_ref:, relative_project_path:, branch:, provider_name:,
                                    provider_cwd:, reservation_root:, created_branch:, stdout:, stderr:, status:,
                                    diagnostics:, timeout: nil)
        matching = worktree_records_for_branch(git_root, branch)
        cleanup = nil
        if matching.one?
          workspace = external_workspace_record(
            provider: provider,
            provider_response: {},
            plan: plan,
            git_root: git_root,
            base_ref: base_ref,
            relative_project_path: relative_project_path,
            branch: branch,
            record: matching.first,
            provider_name: provider_name,
            provider_cwd: provider_cwd,
            stdout: stdout,
            stderr: stderr
          )
          if workspace && transfer_external_workspace_owner(plan, workspace, reservation_root: reservation_root)
            cleanup = release_external_workspace(workspace, provider: provider, preserve_branch: !created_branch)
          end
        elsif created_branch
          cleanup = {
            "attempted" => true,
            "branch_result" => release_owned_branch(git_root, branch),
            "worktree_removed" => true
          }
        end

        output = present_output(stderr) || present_output(stdout)
        disk_exhausted = diagnostics.fetch("disk_exhausted", false) || disk_exhaustion_output?(output)
        error = if disk_exhausted
                  "configured worktree provider failed: disk is full (no space left on device); " \
                    "free disk space, then prompt this worker to retry provisioning"
                elsif timeout
                  timeout.describe("configured worktree provider")
                else
                  "configured worktree provider failed: #{failure_summary(output) || "exit #{status.exitstatus}"}"
                end
        {
          "retry" => false,
          "errors" => [error],
          "stdout" => stdout,
          "stderr" => stderr,
          "stdout_bytes" => diagnostics["stdout_bytes"],
          "stderr_bytes" => diagnostics["stderr_bytes"],
          "diagnostics_truncated" => diagnostics["truncated"],
          "exit_status" => status.exitstatus,
          "timed_out" => !timeout.nil?,
          "timeout_seconds" => timeout&.timeout,
          "failure_kind" => disk_exhausted ? "disk_exhausted" : (timeout ? (timeout.stalled? ? "command_stalled" : "command_timed_out") : "external_provider_error"),
          "recovery" => disk_exhausted || timeout ? RECOVERY_RESUME : RECOVERY_NONE,
          "cleanup" => cleanup
        }.compact
      end

      def external_workspace_record(provider:, provider_response:, plan:, git_root:, base_ref:, relative_project_path:,
                                    branch:, record:, provider_name:, provider_cwd:, stdout: nil, stderr: nil,
                                    adopted: false)
        return nil if record.key?("bare") || record.key?("locked") || record.key?("prunable")

        worktree_root = canonical_path(record.fetch("worktree", ""))
        return nil unless Dir.exist?(worktree_root)

        workspace_path = relative_project_path == "." ? worktree_root : File.join(worktree_root, relative_project_path)
        return nil unless Dir.exist?(workspace_path)

        identifier = present_output(provider_response["identifier"]) || provider_name
        candidate = plan.merge(
          "workspace_path" => workspace_path,
          "workspace_root_path" => worktree_root,
          "worktree_root_path" => worktree_root,
          "workspace_branch" => branch,
          "git_root" => git_root,
          "base_ref" => base_ref,
          "project_relative_path" => relative_project_path,
          "requested_worktree_provider" => worktree_provider.kind,
          "worktree_provider" => provider.kind,
          "worktree_provider_identifier" => identifier,
          "worktree_provider_cwd" => provider_cwd,
          "created" => true,
          "adopted" => adopted,
          "errors" => [],
          "stdout" => present_output(stdout),
          "stderr" => present_output(stderr)
        ).compact
        candidate.delete("workspace_profile") if synthetic_profile_record?(candidate["workspace_profile"])
        candidate
      end

      def adopt_external_worktree(provider:, plan:, git_root:, base_ref:, relative_project_path:, branch:, record:,
                                  provider_name:, provider_cwd:, reservation_root:)
        root = canonical_path(record.fetch("worktree", ""))
        expected = workspace_owner(plan, git_root: git_root, branch: branch, worktree_root: root)
        current = read_workspace_owner(root)
        identifier = nil
        if current
          return nil unless ownership_matches?(current, expected)

          identifier = current["provider_identifier"]
        else
          reservation = read_workspace_owner(reservation_root)
          expected_reservation = workspace_owner(
            plan,
            git_root: git_root,
            branch: branch,
            worktree_root: reservation_root
          )
          return nil unless reservation && ownership_matches?(reservation, expected_reservation)
        end

        workspace = external_workspace_record(
          provider: provider,
          provider_response: { "identifier" => identifier },
          plan: plan,
          git_root: git_root,
          base_ref: base_ref,
          relative_project_path: relative_project_path,
          branch: branch,
          record: record,
          provider_name: provider_name,
          provider_cwd: provider_cwd,
          adopted: true
        )
        return workspace if current
        return workspace if workspace && transfer_external_workspace_owner(plan, workspace, reservation_root: reservation_root)

        nil
      end

      def transfer_external_workspace_owner(plan, workspace, reservation_root:)
        actual_root = workspace.fetch("worktree_root_path")
        owner = workspace_owner(
          plan,
          git_root: workspace.fetch("git_root"),
          branch: workspace.fetch("workspace_branch"),
          worktree_root: actual_root
        ).merge(
          "provider" => workspace.fetch("worktree_provider"),
          "provider_identifier" => workspace.fetch("worktree_provider_identifier")
        )
        current = read_workspace_owner(actual_root)
        return false if current && !ownership_matches?(current, owner)

        write_workspace_owner(owner) unless current
        unless same_path?(reservation_root, actual_root)
          release_workspace_owner(
            reservation_root,
            agent_id: plan.fetch("workspace_owner_id"),
            git_root: workspace.fetch("git_root"),
            branch: workspace.fetch("workspace_branch")
          )
        end
        true
      rescue StandardError
        false
      end

      def external_provider_control_directory(project_root)
        project_path = canonical_path(project_root)
        return { "path" => project_path } if Dir.exist?(project_path)

        { "reason" => "configured provider needs an existing project directory" }
      end

      def worktree_records_for_branch(git_root, branch)
        worktree_records(git_root).select { |record| record["branch"] == "refs/heads/#{branch}" }
      end

      def external_provider_profile_incompatibility(profile)
        return nil unless profile.is_a?(Meringue::Workspace::Profile)
        return nil if synthetic_bare_profile?(profile)
        return "custom workspace path templates require native Git provisioning" if profile.custom_path_template?
        return "project-declared sparse patterns require native Git provisioning" if profile.sparse?

        nil
      end

      def synthetic_bare_profile?(profile)
        profile.is_a?(Meringue::Workspace::Profile) && profile.name == BARE_DEFAULT_PROFILE_NAME
      end

      def synthetic_profile_record?(record)
        record.is_a?(Hash) && record["name"] == BARE_DEFAULT_PROFILE_NAME
      end

      def native_provider_fallback?
        worktree_provider_fallback == WorktreeProvider::NATIVE_GIT
      end

      def worktree_provider_fallback_plan(plan, provider, reason)
        plan.merge(
          "requested_worktree_provider" => provider.kind,
          "worktree_provider" => WorktreeProvider::NATIVE_GIT,
          "worktree_provider_fallback_reason" => reason
        )
      end

      def external_provider_unavailable_outcome(provider, reason)
        {
          "retry" => false,
          "errors" => ["#{provider.display_name} is unavailable: #{reason}. " \
                       "Set workspace.worktree_provider_fallback = \"native_git\" to allow a safe native fallback."],
          "failure_kind" => "external_provider_unavailable",
          "recovery" => RECOVERY_NONE
        }
      end

      def provider_for_workspace(workspace)
        plan = workspace.is_a?(Hash) && workspace["plan"].is_a?(Hash) ? workspace.fetch("plan") : workspace
        kind = plan.is_a?(Hash) ? plan.fetch("worktree_provider", WorktreeProvider::NATIVE_GIT) : WorktreeProvider::NATIVE_GIT
        WorktreeProvider.new(kind: kind, command: @worktree_provider_command)
      end

      def release_external_workspace(workspace, provider:, preserve_branch:, deadline: nil)
        plan = workspace["plan"].is_a?(Hash) ? workspace.fetch("plan") : workspace
        git_root = canonical_path(workspace["git_root"] || plan["git_root"] || workspace["project_root"] || plan["project_root"])
        project_root = workspace["project_root"] || plan["project_root"] || git_root
        worktree_root = canonical_path(workspace["worktree_root_path"] || workspace["workspace_root_path"] ||
                                       plan["worktree_root_path"] || plan["workspace_root_path"] || workspace["workspace_path"])
        branch = workspace["workspace_branch"] || plan["workspace_branch"]
        identifier = workspace["worktree_provider_identifier"] || plan["worktree_provider_identifier"] || File.basename(worktree_root)
        provider_cwd = workspace["worktree_provider_cwd"] || plan["worktree_provider_cwd"]
        provider_cwd = project_root unless provider_cwd && Dir.exist?(provider_cwd)
        head = run_command("git", "-C", git_root, "rev-parse", "--verify", "refs/heads/#{branch}", deadline: deadline)
        branch_head = head.fetch("status").success? ? head.fetch("stdout").to_s.strip : nil

        result = run_command(
          *provider.release_argv(
            identifier: identifier,
            worktree_path: worktree_root,
            branch: branch,
            git_root: git_root,
            project_root: project_root
          ),
          chdir: provider_cwd,
          timeout: cleanup_timeout,
          deadline: deadline,
          output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES
        )
        unless result.fetch("status").success?
          output = present_output(result.fetch("stderr")) || present_output(result.fetch("stdout"))
          return {
            "success" => false,
            "attempted" => true,
            "reason" => "external_provider_release_failed",
            "error" => failure_summary(output) || "configured provider exited #{result.fetch("status").exitstatus}"
          }
        end

        begin
          response = provider.parse_response(result.fetch("stdout"), action: "release")
        rescue WorktreeProvider::InvalidResponse => e
          return {
            "success" => false,
            "attempted" => true,
            "reason" => "external_provider_invalid_release_response",
            "error" => e.message
          }
        end

        registration = worktree_records(git_root).find { |record| same_path?(record.fetch("worktree", ""), worktree_root) }
        released = if response.fetch("worktree_retained")
                     registration && registration.fetch("branch", nil) != "refs/heads/#{branch}"
                   else
                     registration.nil?
                   end
        unless released
          return {
            "success" => false,
            "attempted" => true,
            "reason" => "external_provider_did_not_release_worktree",
            "error" => "provider-reported release did not match Git registration"
          }
        end

        branch_restore = nil
        if preserve_branch && branch_head && !branch_exists?(git_root, branch)
          branch_restore = run_command(
            "git", "-C", git_root, "update-ref", "refs/heads/#{branch}", branch_head,
            timeout: command_timeout,
            deadline: deadline
          )
          unless branch_restore.fetch("status").success?
            return {
              "success" => false,
              "attempted" => true,
              "released" => true,
              "reason" => "branch_restore_failed",
              "error" => present_output(branch_restore.fetch("stderr")) || present_output(branch_restore.fetch("stdout"))
            }
          end
        end

        owner_id = workspace["workspace_owner_id"] || plan["workspace_owner_id"]
        release_workspace_owner(worktree_root, agent_id: owner_id, git_root: git_root, branch: branch) if owner_id
        {
          "success" => true,
          "attempted" => true,
          "released" => true,
          "reason" => "provider_workspace_released",
          "worktree_retained" => response.fetch("worktree_retained"),
          "branch_restored" => !!branch_restore
        }
      rescue Errno::ENOENT => e
        {
          "success" => false,
          "attempted" => false,
          "reason" => "external_provider_command_unavailable",
          "error" => "configured worktree provider command is unavailable (#{e.message})"
        }
      rescue CommandTimeout => e
        {
          "success" => false,
          "attempted" => true,
          "reason" => "external_provider_cleanup_timed_out",
          "error" => e.describe("configured worktree provider")
        }
      rescue StandardError => e
        {
          "success" => false,
          "attempted" => false,
          "reason" => "external_provider_cleanup_error",
          "error" => e.message
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
          # A previous attempt for this same worker may have left an intact, registered,
          # unlocked worktree on the exact planned branch at the planned path while its
          # ownership record is gone (a crashed instance, a migrated workspace root, or a
          # checkout created before ownership files existed). That is this worker's own
          # resumable checkout, not a foreign collision: claiming it avoids a redundant
          # multi-minute `git worktree add` for a branch that is already checked out locally.
          # The forced-collision case (a different worker on the same candidate) keeps its
          # ownership record, so it is still refused here; the kernel's launch gate still
          # re-checks for live occupants before any session starts in the adopted tree.
          reusable = reusable_existing_checkout?(
            owner.fetch("git_root"), owner.fetch("worktree_root"), owner.fetch("branch")
          ) || reusable_external_owned_branch?(
            owner.fetch("git_root"), owner.fetch("branch"), owner.fetch("agent_id")
          )
          if (foreign_path || foreign_registration || foreign_branch) && !reusable
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

    end
  end
end
