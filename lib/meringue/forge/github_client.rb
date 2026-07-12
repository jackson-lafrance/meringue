# frozen_string_literal: true

require "json"
require "open3"

module Meringue
  module Forge
    class GitHubClient
      def pull_request_status(url)
        stdout, stderr, status = Open3.capture3("gh", "pr", "view", url.to_s, "--json", "state,mergedAt,url")
        return unknown_status(url, stderr, status.exitstatus) unless status.success?

        data = JSON.parse(stdout)
        normalized_state = normalize_state(data["state"])
        {
          "provider" => "github",
          "url" => data["url"] || url.to_s,
          "state" => normalized_state,
          "merged_at" => data["mergedAt"],
          "raw_state" => data["state"]
        }.compact
      rescue Errno::ENOENT => e
        unknown_status(url, e.message, nil)
      rescue JSON::ParserError => e
        unknown_status(url, e.message, nil)
      end

      private

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
