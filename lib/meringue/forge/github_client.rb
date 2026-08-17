# frozen_string_literal: true

require "json"
require "open3"

module Meringue
  module Forge
    class GitHubClient
      DEFAULT_COMMAND_TIMEOUT_SECONDS = 5.0
      TERMINATION_GRACE_SECONDS = 0.1

      class CommandTimeout < StandardError; end

      attr_reader :command_timeout

      def initialize(command_timeout: DEFAULT_COMMAND_TIMEOUT_SECONDS)
        @command_timeout = Float(command_timeout)
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

      # `gh` can wait on DNS, authentication helpers, or the network indefinitely. Run it in its
      # own process group, drain both pipes concurrently, and terminate the whole group when the
      # bounded budget expires so a maintenance command can conservatively retain the PR-backed
      # record instead of freezing Meringue.
      def run_gh(*arguments, timeout: nil)
        limit = Float(timeout || command_timeout)
        raise CommandTimeout, timeout_message(limit) unless limit.positive?

        stdin = stdout = stderr = wait_thread = nil
        stdout_reader = stderr_reader = nil
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          SubprocessEnvironment.clean, "gh", *arguments, pgroup: true
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
