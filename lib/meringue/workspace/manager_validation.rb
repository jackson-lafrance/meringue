# frozen_string_literal: true

module Meringue
  module Workspace
    class Manager
    private
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

      def unique_commit_count(git_root, branch)
        ref = "refs/heads/#{branch}"
        result = run_command("git", "-C", git_root, "rev-list", "--count", ref, "--not", "--exclude=#{ref}", "--all")
        return nil unless result.fetch("status").success?

        Integer(result.fetch("stdout").to_s.strip)
      rescue ArgumentError, TypeError, CommandTimeout
        nil
      end

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

      def reusable_external_owned_branch?(git_root, branch, agent_id)
        return false unless worktree_provider.external?

        records = worktree_records_for_branch(git_root, branch)
        return false unless records.one?

        root = records.first.fetch("worktree", "")
        workspace_owned_by?(root, agent_id: agent_id, git_root: git_root, branch: branch)
      rescue StandardError
        false
      end

      def reusable_existing_checkout?(git_root, worktree_root, branch)
        return false unless owned_workspace_path?(worktree_root)
        return false unless DeliveryArtifactPolicy.managed_branch?(branch)

        record = worktree_records(git_root).find do |candidate|
          same_path?(candidate.fetch("worktree", ""), worktree_root)
        end
        return false unless record
        return false if record.key?("bare") || record.key?("locked") || record.key?("prunable")
        return false unless record.fetch("branch", nil) == "refs/heads/#{branch}"

        Dir.exist?(worktree_root)
      end

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

      def managed_owned_workspace_path?(path, git_root:, branch:, agent_id: nil)
        return true if owned_workspace_path?(path)
        return false if git_root.to_s.strip.empty? || branch.to_s.strip.empty?

        owner = read_workspace_owner(path)
        return false unless owner
        return false if agent_id && owner.fetch("agent_id", nil) != agent_id.to_s

        owner.fetch("branch", nil) == branch.to_s &&
          same_path?(owner.fetch("git_root", ""), git_root) &&
          same_path?(owner.fetch("worktree_root", ""), path)
      end

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

      def run_command(*argv, timeout: command_timeout, stall_timeout: nil, deadline: nil, output_limit: nil, progress: nil,
                     chdir: nil)
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

        spawn_options = { pgroup: true }
        spawn_options[:chdir] = chdir if chdir

        # Provider, Git, and diagnostic commands are independent executables. Do not leak
        # `bundle exec`'s RUBYOPT/BUNDLE_GEMFILE into them: in particular, invoking a system
        # Ruby would otherwise try to load this process's Bundler and exit before producing
        # the output the watchdog is responsible for capturing.
        Open3.popen3(SubprocessEnvironment.clean, *effective_argv, spawn_options) do |child_stdin, child_out, child_err, child_wait|
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
          return nil if wait_thread.join([nap, 0.0].max)

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

      def resolve_profile(project_root, profile)
        return profile if profile.is_a?(Meringue::Workspace::Profile)

        Meringue::Workspace::Profile.load(project_root)
      end

      def resolve_provisioning_profile(project_root, profile, repository: nil)
        resolved = resolve_profile(project_root, profile)
        return resolved if resolved
        return nil if bare_full_checkout_mode?

        repository ||= repository_context(canonical_path(project_root))
        return nil unless repository && repository.fetch("bare")

        git_root = repository.fetch("git_root")
        return nil unless large_bare_source?(git_root)

        default_bare_profile
      rescue CommandTimeout
        raise
      rescue StandardError
        nil
      end

      def default_bare_profile
        Meringue::Workspace::Profile.new(
          name: BARE_DEFAULT_PROFILE_NAME,
          sparse_cone: false,
          sparse_patterns: BARE_DEFAULT_SPARSE_PATTERNS
        )
      end

      def bare_full_checkout_mode?
        default_bare_checkout_mode.to_s == BARE_FULL_CHECKOUT_MODE
      end

      def large_bare_source?(git_root)
        return false if bare_sparse_object_threshold <= 0

        git_root = canonical_path(git_root)
        return @large_bare_source_cache.fetch(git_root) if @large_bare_source_cache.key?(git_root)

        count = packed_object_count(git_root)
        large = count && count >= bare_sparse_object_threshold
        @large_bare_source_cache[git_root] = large
        large
      end

      def packed_object_count(git_root)
        result = run_command("git", "-C", git_root, "count-objects", "-v", timeout: command_timeout)
        return nil unless result.fetch("status").success?

        loose = 0
        packed = 0
        result.fetch("stdout").to_s.each_line do |line|
          if line =~ /^count:\s*(\d+)/
            loose = Regexp.last_match(1).to_i
          elsif line =~ /^in-pack:\s*(\d+)/
            packed = Regexp.last_match(1).to_i
          end
        end
        loose + packed
      rescue CommandTimeout
        raise
      rescue StandardError
        nil
      end

      def normalize_bare_checkout_mode(value)
        mode = value.to_s.strip.downcase
        mode == BARE_FULL_CHECKOUT_MODE ? BARE_FULL_CHECKOUT_MODE : DEFAULT_BARE_CHECKOUT_MODE
      end

      def positive_integer(value, fallback)
        number = Integer(value)
        number.positive? ? number : Integer(fallback)
      rescue ArgumentError, TypeError
        Integer(fallback)
      end

      def default_workspace_path(root, project_name, workspace_name)
        File.join(root, project_name, workspace_name)
      end

      def attach_profile_metadata(record, profile)
        return record unless profile.is_a?(Meringue::Workspace::Profile)

        record["workspace_profile"] = profile.to_h.merge("summary" => profile.summary)
        record
      end

      def apply_sparse_checkout(git_root:, worktree_root:, profile:, progress:)
        patterns = profile.sparse_patterns
        unless profile.sparse?
          # Defensive: a profile marked sparse with no patterns would otherwise leave a
          # `--no-checkout` worktree empty. Materialize the full tree instead.
          materialize_full_tree(worktree_root, progress: progress)
          return success_sparse_record(profile, patterns, materialized: count_materialized_files(worktree_root))
        end

        # Per-worktree sparse config requires the worktreeConfig extension on the
        # common repository so each worktree reads its own sparse settings. The
        # flag is non-destructive and idempotent; without it, sparse config would
        # leak into the shared repository config and apply to every worktree.
        extension_result = run_command(
          "git", "-C", git_root, "config", "extensions.worktreeConfig", "true",
          timeout: command_timeout
        )
        unless extension_result.fetch("status").success?
          return sparse_failure("could not enable per-worktree config extension", extension_result)
        end

        config_result = run_command(
          "git", "-C", worktree_root, "config", "--worktree", "core.sparseCheckout", "true",
          timeout: command_timeout
        )
        unless config_result.fetch("status").success?
          return sparse_failure("git config core.sparseCheckout failed", config_result)
        end
        # A `--no-checkout` worktree created from a bare common repository inherits
        # `core.bare=true`, so `read-tree -mu` refuses to touch the working tree.
        # Flip it per-worktree (harmless on a non-bare source) before materializing.
        bare_result = run_command(
          "git", "-C", worktree_root, "config", "--worktree", "core.bare", "false",
          timeout: command_timeout
        )
        unless bare_result.fetch("status").success?
          return sparse_failure("git config core.bare failed for bare-sourced worktree", bare_result)
        end
        if profile.cone?
          cone_result = run_command(
            "git", "-C", worktree_root, "config", "--worktree", "core.sparseCheckoutCone", "true",
            timeout: command_timeout
          )
          unless cone_result.fetch("status").success?
            return sparse_failure("git config core.sparseCheckoutCone failed", cone_result)
          end
        end

        git_dir = resolve_worktree_git_dir(worktree_root)
        return sparse_failure("could not resolve worktree git dir", nil) unless git_dir

        info_dir = File.join(git_dir, "info")
        FileUtils.mkdir_p(info_dir)
        sparse_file = File.join(info_dir, "sparse-checkout")
        File.write(sparse_file, patterns.join("\n") + "\n")

        read_result = run_command(
          "git", "-C", worktree_root, "read-tree", "-mu", "HEAD",
          timeout: checkout_timeout,
          stall_timeout: checkout_stall_timeout,
          output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES,
          progress: progress
        )
        unless read_result.fetch("status").success?
          return sparse_failure("git read-tree failed to materialize sparse checkout", read_result)
        end

        materialized = count_materialized_files(worktree_root)
        success_sparse_record(profile, patterns, materialized: materialized)
      rescue Meringue::Workspace::Manager::CommandTimeout => e
        {
          "success" => false,
          "errors" => [e.describe(command_label(e.argv))],
          "stdout" => e.stdout,
          "stderr" => e.stderr,
          "exit_status" => nil,
          "failure_kind" => e.stalled? ? "sparse_checkout_stalled" : "sparse_checkout_timed_out"
        }
      rescue StandardError => e
        {
          "success" => false,
          "errors" => ["sparse checkout configuration failed: #{e.message}"],
          "stdout" => nil,
          "stderr" => nil,
          "exit_status" => nil,
          "failure_kind" => "sparse_checkout_error"
        }
      end

      def resolve_worktree_git_dir(worktree_root)
        result = run_command("git", "-C", worktree_root, "rev-parse", "--absolute-git-dir", timeout: command_timeout)
        return nil unless result.fetch("status").success?

        canonical_path(result.fetch("stdout").to_s.strip)
      rescue StandardError
        nil
      end

      def materialize_full_tree(worktree_root, progress:)
        read_result = run_command(
          "git", "-C", worktree_root, "read-tree", "-mu", "HEAD",
          timeout: checkout_timeout,
          stall_timeout: checkout_stall_timeout,
          output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES,
          progress: progress
        )
        read_result.fetch("status").success?
      rescue StandardError
        false
      end

      def count_materialized_files(worktree_root)
        count = 0
        Dir.glob(File.join(worktree_root, "**", "*"), File::FNM_DOTMATCH).each do |entry|
          next if File.basename(entry) == ".git" || entry.include?("#{File::SEPARATOR}.git#{File::SEPARATOR}")
          count += 1 if File.file?(entry)
        end
        count
      rescue StandardError
        nil
      end

      def success_sparse_record(profile, patterns, materialized:)
        {
          "success" => true,
          "record" => {
            "profile" => profile.name,
            "cone" => profile.cone?,
            "patterns" => patterns,
            "materialized_files" => materialized
          }.compact
        }
      end

      def sparse_failure(message, result)
        {
          "success" => false,
          "errors" => [message],
          "stdout" => result && present_output(result.fetch("stdout")),
          "stderr" => result && present_output(result.fetch("stderr")),
          "exit_status" => result && result.fetch("status")&.exitstatus,
          "failure_kind" => "sparse_checkout_failed"
        }
      end

      def run_profile_validation(worktree_root:, workspace_path:, profile:)
        argv = profile.validation_command
        started = self.class.monotonic_now
        result = run_command(
          *argv,
          timeout: validation_timeout,
          stall_timeout: checkout_stall_timeout,
          output_limit: DIAGNOSTIC_OUTPUT_LIMIT_BYTES,
          chdir: workspace_path
        )
        elapsed = self.class.monotonic_now - started
        status = result.fetch("status")
        success = status&.success?
        {
          "success" => success,
          "command" => argv,
          "exit_status" => status&.exitstatus,
          "duration_seconds" => round_seconds(elapsed),
          "stdout" => present_output(result.fetch("stdout")),
          "stderr" => present_output(result.fetch("stderr")),
          "errors" => success ? [] : ["profile validation command failed with exit #{status&.exitstatus}"]
        }
      rescue Meringue::Workspace::Manager::CommandTimeout => e
        {
          "success" => false,
          "command" => argv,
          "exit_status" => nil,
          "duration_seconds" => nil,
          "stdout" => e.stdout,
          "stderr" => e.stderr,
          "errors" => [e.describe("profile validation command")],
          "failure_kind" => e.stalled? ? "validation_stalled" : "validation_timed_out"
        }
      rescue StandardError => e
        {
          "success" => false,
          "command" => argv,
          "exit_status" => nil,
          "duration_seconds" => nil,
          "stdout" => nil,
          "stderr" => nil,
          "errors" => ["profile validation command could not run: #{e.message}"]
        }
      end

      def validation_timeout
        # Validation is project tooling over a sparse checkout, so it shares the
        # checkout budget as its ceiling rather than the short plumbing budget.
        checkout_timeout
      end

    end
  end
end
