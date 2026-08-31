# frozen_string_literal: true

require "json"
require "open3"

module Meringue
  # The code-hosting frontend: the thing Meringue asks about pull requests,
  # their branches, and their state. The built-in implementation is the GitHub
  # frontend (`Forge::GitHubClient`, backed by the `gh` CLI); it is the default
  # and GitHub support is default behavior.
  #
  # Pull requests are tracked as links, not as GitHub URLs specifically: any
  # forge link a frontend can answer for — GitHub, Graphite, Meteorite, or a
  # private adapter — can be registered, discovered in worker output, and
  # refreshed. `PULL_REQUEST_URL_PATTERN` is therefore host-generic.
  module Forge
    DEFAULT_FRONTEND = "github"
    FRONTENDS = %w[github command].freeze
    DEFAULT_COMMAND_TIMEOUT_SECONDS = 5.0
    TERMINATION_GRACE_SECONDS = 0.1

    # A pull-request link on any forge host: `/pull/N` or `/pr/N` after the
    # host and any owner/repository path segments. GitHub
    # (`github.com/owner/repo/pull/1`), Graphite (`app.graphite.dev/pr/1`),
    # and Meteorite-style hosts all match; so does any private forge that
    # follows the same shape.
    PULL_REQUEST_URL_PATTERN = %r!https?://[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*?/(?:pull|pr)/\d+(?:[/?#][^\s<>"'\])}]+)?!.freeze

    module_function

    # The configured frontend id. `command` is the extension point for an
    # alternate frontend (for example a private adapter executable around a
    # forge such as meteorite); anything unconfigured or unrecognized reads as
    # the default GitHub frontend, the same way an unknown version-control
    # backend id falls back to the built-in one.
    def frontend(config)
      configured = begin
        config&.setting("forge.frontend").to_s
      rescue StandardError
        ""
      end
      FRONTENDS.include?(configured) ? configured : DEFAULT_FRONTEND
    end

    # True when the built-in GitHub frontend is the active one, which is the
    # default. GitHub-specific guidance and access checks key off this; pull
    # request tracking itself is frontend-agnostic and always available.
    def github_frontend?(config)
      frontend(config) != "command"
    end

    # The forge client a kernel should use. An explicitly injected client
    # always wins (embedding applications supply their own frontend object);
    # otherwise the config selection decides. `command` with a configured argv
    # builds a CommandFrontend; `command` without one fails closed.
    def client_for(config, client: nil)
      return client if client

      return GitHubClient.new if github_frontend?(config)

      argv = begin
        Array(config&.setting("forge.command"))
      rescue StandardError
        []
      end
      argv.empty? ? AlternateFrontend.new : CommandFrontend.new(argv)
    end

    # True when the string contains at least one forge pull-request link.
    def contains_pull_request_url?(text)
      !text.to_s[PULL_REQUEST_URL_PATTERN].nil?
    end

    # Whether one URL is a pull-request link (full match, no trailing prose).
    def pull_request_url?(url)
      Regexp.new("\\A#{PULL_REQUEST_URL_PATTERN.source}\\z").match?(url.to_s)
    end

    # The stable form of a pull-request link: everything up to and including
    # the number, so tracking/projection keys never carry query strings or
    # trailing punctuation a worker happened to paste.
    def canonical_pull_request_url(url)
      cleaned = url.to_s.sub(/[.,;:]+\z/, "")
      match = cleaned.match(%r{\A(https?://[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*?/(?:pull|pr)/\d+)})
      match ? match[1] : cleaned
    end

    # Fails closed: a `command` frontend selection without a usable adapter.
    # Every lookup reports unavailable rather than guessing or silently using
    # GitHub.
    class AlternateFrontend
      def id
        "command"
      end

      def repository_from_remote(remote)
        remote.to_s
      end

      def test_access(repository:, timeout: nil)
        _ = timeout
        {
          "outcome" => "unavailable",
          "status" => "unavailable",
          "message" => "An alternate frontend is configured but no adapter command is set; forge access was not checked.",
          "repository" => repository.to_s
        }
      end

      def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
        _ = [repository, branch, timeout]
        []
      end

      def pull_request_status(url, timeout: nil)
        _ = timeout
        {
          "provider" => "command",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => "alternate frontend has no adapter command configured"
        }
      end
    end

    # A frontend backed by a private adapter executable (for example around
    # meteorite). The configured argv prefix receives one of three actions and
    # writes exactly one JSON object to stdout; progress and human diagnostics
    # belong on stderr. The argv is spawned directly, never through a shell.
    #
    #   <command...> access --repository <remote-or-slug>
    #     -> {"outcome":"success|unavailable|missing_tooling|unauthenticated|permission_denied|repository_read_failure|timeout|malformed_remote","message":"..."}
    #
    #   <command...> pull-requests --repository <remote-or-slug> --branch <branch>
    #     -> {"urls":["https://..."]}
    #
    #   <command...> status --url <url>
    #     -> {"state":"open|merged|closed|unknown","merged_at":null,"head_branch":"...","base_repository":"...","is_cross_repository":false}
    #
    # The adapter resolves the repository argument itself: Meringue passes the
    # project's `origin` remote URL verbatim, so an adapter maps it to whatever
    # slug its forge uses. `status` fields other than `state` and `url` are
    # optional; an unanswered question is `unknown`, never a guess. Every
    # action must be bounded and read-only with respect to the forge.
    class CommandFrontend
      class CommandTimeout < StandardError; end

      def initialize(argv, command_timeout: DEFAULT_COMMAND_TIMEOUT_SECONDS)
        @argv = Array(argv).map(&:to_s)
        raise ArgumentError, "alternate frontend command must contain an executable" if @argv.empty?

        @command_timeout = Float(command_timeout)
      end

      def id
        "command"
      end

      # The adapter owns remote-to-slug resolution, so the raw remote URL is
      # the repository handle for a command frontend.
      def repository_from_remote(remote)
        remote.to_s
      end

      def test_access(repository:, timeout: nil)
        run_json("access", "--repository", repository.to_s, timeout: timeout) do |data|
          {
            "outcome" => data["outcome"].to_s.then { |outcome| outcome.empty? ? "unavailable" : outcome },
            "status" => data["outcome"].to_s,
            "message" => data["message"].to_s,
            "repository" => repository.to_s
          }
        end
      rescue CommandTimeout => e
        {
          "outcome" => "timeout",
          "status" => "timeout",
          "message" => "Frontend access test timed out. Try again; no forge resource was changed.",
          "repository" => repository.to_s,
          "error" => e.message
        }.compact
      rescue Errno::ENOENT => e
        {
          "outcome" => "missing_tooling",
          "status" => "missing_tooling",
          "message" => "Frontend adapter is missing: #{e.message}",
          "repository" => repository.to_s,
          "error" => e.message.to_s[/\A[^,]+/].to_s
        }.compact
      end

      def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
        data = run_json("pull-requests", "--repository", repository.to_s, "--branch", branch.to_s, timeout: timeout)
        Array(data["urls"]).map(&:to_s).uniq
      rescue CommandTimeout, Errno::ENOENT
        raise if timeout

        []
      rescue JsonError
        []
      end

      def pull_request_status(url, timeout: nil)
        run_json("status", "--url", url.to_s, timeout: timeout) do |data|
          {
            "provider" => "command",
            "url" => data["url"] || url.to_s,
            "state" => normalized_state(data["state"]),
            "merged_at" => data["merged_at"],
            "raw_state" => data["state"],
            "is_draft" => data["is_draft"],
            "head_branch" => data["head_branch"],
            "head_repository" => data["head_repository"],
            "base_repository" => data["base_repository"],
            "is_cross_repository" => data["is_cross_repository"],
            "title" => data["title"]
          }.compact
        end
      rescue CommandTimeout => e
        unknown_status(url, e.message).merge("timed_out" => true)
      rescue Errno::ENOENT => e
        unknown_status(url, e.message)
      rescue JsonError => e
        unknown_status(url, e.message)
      end

      private

      class JsonError < StandardError; end

      def run_json(*arguments, timeout: nil)
        stdout, _stderr = run_adapter(*arguments, timeout: timeout)
        data = begin
          JSON.parse(stdout)
        rescue JSON::ParserError => e
          raise JsonError, e.message
        end
        raise JsonError, "adapter response is not a JSON object" unless data.is_a?(Hash)

        block_given? ? yield(data) : data
      end

      # Bounded, direct-argv execution in its own process group: an adapter
      # that hangs on credentials or the network can never freeze Meringue.
      def run_adapter(*arguments, timeout: nil)
        limit = Float(timeout || @command_timeout)
        raise CommandTimeout, timeout_message(limit) unless limit.positive?

        stdin = stdout = stderr = wait_thread = nil
        reader = nil
        environment = SubprocessEnvironment.clean.merge("NO_COLOR" => "1")
        stdin, stdout, stderr, wait_thread = Open3.popen3(environment, *@argv, *arguments, pgroup: true)
        stdin.close
        reader = Thread.new { stdout.read }
        unless wait_thread.join(limit)
          terminate_process_group(wait_thread)
          raise CommandTimeout, timeout_message(limit)
        end
        [reader.value, stderr.read]
      ensure
        if reader
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
        "frontend adapter timed out after #{format("%.2f", limit)} seconds"
      end

      def normalized_state(state)
        case state.to_s.downcase
        when "merged" then "merged"
        when "closed" then "closed"
        when "open" then "open"
        else "unknown"
        end
      end

      def unknown_status(url, error_message)
        {
          "provider" => "command",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => error_message.to_s.strip
        }.compact
      end
    end
  end
end
