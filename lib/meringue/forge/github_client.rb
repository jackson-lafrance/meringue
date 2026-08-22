# frozen_string_literal: true

require "json"
require "open3"

module Meringue
  module Forge
    class GitHubClient
      DEFAULT_COMMAND_TIMEOUT_SECONDS = 5.0
      TERMINATION_GRACE_SECONDS = 0.1
      ACCESS_RESULT_OUTCOMES = %w[success unavailable unauthenticated permission_denied timeout malformed_remote].freeze
      MAX_ERROR_LENGTH = 300

      class CommandTimeout < StandardError; end

      attr_reader :command_timeout

      def initialize(command_timeout: DEFAULT_COMMAND_TIMEOUT_SECONDS)
        @command_timeout = Float(command_timeout)
      end

      # Return the owner/repository portion of a supported GitHub origin without
      # contacting GitHub. Keeping this parser in the forge client gives the
      # kernel and access checks the same remote conventions.
      def self.repository_from_remote(remote)
        text = remote.to_s.strip.sub(/\.git\z/i, "")
        match = text.match(%r{\A(?:https?://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\z}i)
        match && match[1]
      end

      # Check exactly the read-only GitHub capabilities that delivery workflows
      # need: the CLI can identify the current account and that account can read
      # the repository. Neither command creates or changes a GitHub resource.
      def test_access(repository:, timeout: nil)
        repository = repository.to_s.strip
        unless repository.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
          return access_result("malformed_remote", "The GitHub repository remote is malformed.", repository: repository)
        end

        deadline = monotonic_time + Float(timeout || command_timeout)
        auth_stdout, auth_stderr, auth_status = run_gh(
          "auth",
          "status",
          "--hostname",
          "github.com",
          timeout: remaining_timeout(deadline)
        )
        unless auth_status.success?
          output = join_command_output(auth_stdout, auth_stderr)
          outcome = network_failure?(output) ? "unavailable" : "unauthenticated"
          message = if outcome == "unavailable"
                      "GitHub authentication status is unavailable: #{short_error(output)}"
                    else
                      "GitHub is not authenticated. Run `gh auth login` and try again."
                    end
          return access_result(outcome, message, repository: repository, error: short_error(output), exit_status: auth_status.exitstatus)
        end

        identity = github_account(join_command_output(auth_stdout, auth_stderr))
        repo_stdout, repo_stderr, repo_status = run_gh(
          "repo",
          "view",
          repository,
          "--json",
          "nameWithOwner",
          timeout: remaining_timeout(deadline)
        )
        unless repo_status.success?
          output = join_command_output(repo_stdout, repo_stderr)
          outcome = network_failure?(output) ? "unavailable" : "permission_denied"
          message = if outcome == "unavailable"
                      "GitHub is unavailable while checking #{repository}: #{short_error(output)}"
                    else
                      "GitHub authentication works, but #{repository} is not accessible with this account."
                    end
          return access_result(outcome, message, repository: repository, identity: identity, error: short_error(output), exit_status: repo_status.exitstatus)
        end

        data = JSON.parse(repo_stdout)
        confirmed_repository = data["nameWithOwner"].to_s.strip
        unless confirmed_repository.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
          return access_result("unavailable", "GitHub returned an invalid repository response for #{repository}.", repository: repository, identity: identity)
        end

        account = identity ? " as #{identity}" : ""
        access_result(
          "success",
          "GitHub access is ready#{account}; read access to #{confirmed_repository} is confirmed.",
          repository: confirmed_repository,
          identity: identity
        )
      rescue CommandTimeout => e
        access_result("timeout", "GitHub access test timed out. Try again; no GitHub resource was changed.", repository: repository, error: short_error(e.message))
      rescue Errno::ENOENT => e
        access_result("unavailable", "GitHub CLI is unavailable: #{short_error(e.message)}", repository: repository, error: short_error(e.message))
      rescue JSON::ParserError => e
        access_result("unavailable", "GitHub returned an invalid response while checking #{repository}.", repository: repository, error: short_error(e.message))
      rescue ArgumentError => e
        access_result("timeout", "GitHub access test could not start within its bounded time: #{short_error(e.message)}", repository: repository, error: short_error(e.message))
      end

      def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
        stdout, _stderr, status = run_gh(
          "pr",
          "list",
          "--repo",
          repository.to_s,
          "--head",
          branch.to_s,
          "--state",
          "all",
          "--limit",
          "100",
          "--json",
          "url",
          timeout: timeout
        )
        return [] unless status.success?

        Array(JSON.parse(stdout)).filter_map { |pull_request| pull_request["url"] }.uniq
      rescue CommandTimeout
        # Prune supplies an explicit share of its total deadline and needs to distinguish "no PR"
        # from "could not discover whether a PR exists". Other best-effort callers keep the
        # historical empty-array fallback.
        raise if timeout

        []
      rescue Errno::ENOENT, JSON::ParserError
        []
      end

      def pull_request_status(url, timeout: nil)
        stdout, stderr, status = run_gh(
          "pr",
          "view",
          url.to_s,
          "--json",
          "state,mergedAt,url,isDraft,headRefName,headRepository,headRepositoryOwner,isCrossRepository,title",
          timeout: timeout
        )
        return unknown_status(url, stderr, status.exitstatus) unless status.success?

        data = JSON.parse(stdout)
        normalized_state = normalize_state(data["state"])
        {
          "provider" => "github",
          "url" => data["url"] || url.to_s,
          "state" => normalized_state,
          "merged_at" => data["mergedAt"],
          "raw_state" => data["state"],
          "is_draft" => data["isDraft"],
          "head_branch" => data["headRefName"],
          "head_repository" => data.dig("headRepository", "nameWithOwner"),
          "head_repository_owner" => data.dig("headRepositoryOwner", "login"),
          "is_cross_repository" => data["isCrossRepository"],
          "base_repository" => github_repository_from_url(data["url"] || url.to_s),
          "title" => data["title"]
        }.compact
      rescue Errno::ENOENT => e
        unknown_status(url, e.message, nil)
      rescue JSON::ParserError => e
        unknown_status(url, e.message, nil)
      rescue CommandTimeout => e
        unknown_status(url, e.message, nil).merge("timed_out" => true)
      end

      private

      def access_result(outcome, message, repository:, identity: nil, error: nil, exit_status: nil)
        {
          "outcome" => outcome.to_s,
          "status" => outcome.to_s,
          "message" => message.to_s,
          "repository" => repository.to_s,
          "identity" => identity,
          "error" => error,
          "exit_status" => exit_status
        }.compact
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def remaining_timeout(deadline)
        [deadline - monotonic_time, 0.001].max
      end

      def join_command_output(stdout, stderr)
        [stdout, stderr].map { |value| value.to_s.strip }.reject(&:empty?).join(" ")
      end

      def short_error(error)
        error.to_s.strip.gsub(/\s+/, " ")[0, MAX_ERROR_LENGTH]
      end

      def network_failure?(output)
        output.to_s.match?(/could not resolve host|network|connection|timed out|timeout|tls|dns|proxy|api\.github\.com|http\s+5\d\d|server error|service unavailable|rate limit/i)
      end

      def github_account(output)
        match = output.to_s.match(/\baccount\s+([A-Za-z0-9][A-Za-z0-9-]*)\b/i)
        match && match[1]
      end

      # `gh` can wait on DNS, authentication helpers, or the network indefinitely. Run it in its
      # own process group, drain both pipes concurrently, and terminate the whole group when the
      # bounded budget expires so a maintenance command can conservatively retain the PR-backed
      # record instead of freezing Meringue.
      def run_gh(*arguments, timeout: nil)
        limit = Float(timeout || command_timeout)
        raise CommandTimeout, timeout_message(limit) unless limit.positive?

        stdin = stdout = stderr = wait_thread = nil
        stdout_reader = stderr_reader = nil
        environment = SubprocessEnvironment.clean.merge(
          "GH_PROMPT_DISABLED" => "1",
          "GH_PAGER" => "cat",
          "GIT_TERMINAL_PROMPT" => "0"
        )
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          environment, "gh", *arguments, pgroup: true
        )
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }

        unless wait_thread.join(limit)
          terminate_process_group(wait_thread)
          raise CommandTimeout, timeout_message(limit)
        end

        [stdout_reader.value, stderr_reader.value, wait_thread.value]
      ensure
        # Let readers observe EOF after the child exits before closing their streams. Closing a
        # pipe first can make a still-scheduled reader raise `IOError: stream closed in another
        # thread` under a busy full-suite run.
        [stdout_reader, stderr_reader].compact.each do |reader|
          reader.join(TERMINATION_GRACE_SECONDS)
          if reader.alive?
            reader.kill
            reader.join
          end
        end
        [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
      end

      def terminate_process_group(wait_thread)
        signal_process_group("TERM", wait_thread.pid)
        return if wait_thread.join(TERMINATION_GRACE_SECONDS)

        signal_process_group("KILL", wait_thread.pid)
        wait_thread.join
      end

      def signal_process_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      def timeout_message(limit)
        "gh command timed out after #{format("%.2f", limit)} seconds"
      end

      def github_repository_from_url(url)
        match = url.to_s.match(%r{\Ahttps?://github\.com/([^/]+/[^/]+)/pull/\d+})
        match && match[1]
      end

      def normalize_state(state)
        case state.to_s.downcase
        when "merged"
          "merged"
        when "closed"
          "closed"
        when "open"
          "open"
        else
          "unknown"
        end
      end

      def unknown_status(url, error_message, exit_status)
        {
          "provider" => "github",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => error_message.to_s.strip,
          "exit_status" => exit_status
        }.compact
      end
    end
  end
end
