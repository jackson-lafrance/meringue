# frozen_string_literal: true

require "rbconfig"
require "shellwords"

module Meringue
  module TUI
    class PullRequestOpener
      DEFAULT_COMMANDS = {
        "darwin" => "open",
        "linux" => "xdg-open"
      }.freeze

      def initialize(command: ENV["MERINGUE_PR_OPEN_COMMAND"])
        @command = command
      end

      def open(url)
        return rejected("Agent has no pull request URL to open.") unless present?(url)
        return rejected("Pull request URL is not a supported GitHub PR URL: #{url}") unless pull_request_url?(url)

        argv = opener_argv
        return failed("Could not open pull request because no URL opener is configured. Set MERINGUE_PR_OPEN_COMMAND, or install xdg-open/open.") if argv.empty?

        pid = Process.spawn(*(argv + [url]), in: File::NULL, out: File::NULL, err: File::NULL)
        Process.detach(pid)
        opened("Opened pull request: #{url}")
      rescue Errno::ENOENT
        failed("Could not open pull request because #{opener_name.inspect} was not found.")
      rescue SystemCallError => e
        failed("Could not open pull request: #{e.message}")
      end

      private

      def opener_argv
        configured = configured_argv
        return configured if configured.any?

        command = DEFAULT_COMMANDS.fetch(RbConfig::CONFIG.fetch("host_os", ""), nil)
        command ||= "open" if RbConfig::CONFIG.fetch("host_os", "").include?("darwin")
        command ||= "xdg-open" if RbConfig::CONFIG.fetch("host_os", "").include?("linux")
        return [] unless present?(command)
        return [command] if executable?(command)

        []
      end

      def configured_argv
        return [] unless present?(@command)

        Shellwords.split(@command.to_s)
      rescue ArgumentError
        [@command.to_s]
      end

      def opener_name
        opener_argv.first || @command
      end

      def executable?(name)
        return File.file?(name) && File.executable?(name) if name.include?(File::SEPARATOR)

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, name)
          File.file?(path) && File.executable?(path)
        end
      end

      def pull_request_url?(url)
        url.to_s.match?(%r{\Ahttps?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+(?:[/?#].*)?\z})
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      def opened(message)
        { "status" => "opened", "message" => message }
      end

      def rejected(message)
        { "status" => "rejected", "message" => message }
      end

      def failed(message)
        { "status" => "failed", "message" => message }
      end
    end
  end
end
