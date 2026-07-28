# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    # Read-only delivery-PR presentation for the agent workspace. Candidate URLs reported in
    # worker prose are intentionally excluded: only kernel-verified delivery PRs are actionable.
    module DeliveryPullRequest
      STALE_AFTER_SECONDS = 5 * 60
      GITHUB_PULL_REQUEST_URL = %r{\Ahttps?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/(\d+)(?:[/?#].*)?\z}

      module_function

      def for_id(state, id, now: Time.now.utc)
        record = tracked_record_for_id(state, id)
        return missing(id) unless record

        url = pull_request_url(record)
        return invalid(id, record, url) unless valid_url?(url)

        raw_state = (record["state"] || record["status"] || record["raw_state"]).to_s.downcase
        state_name = %w[open merged closed].include?(raw_state) ? raw_state : "unknown"
        refresh_unavailable = record["availability"].to_s == "unavailable"
        {
          "agent_id" => id.to_s,
          "record" => record,
          "url" => url,
          "number" => url[GITHUB_PULL_REQUEST_URL, 1],
          "state" => state_name,
          "available" => true,
          "metadata_available" => !refresh_unavailable,
          "stale" => refresh_unavailable || stale_record?(record, now: now),
          "message" => presentation_message(state_name, refresh_unavailable: refresh_unavailable)
        }
      end

      def tracked_record_for_id(state, id)
        issues = Array(state.fetch("issues", []))
        issue = issues.find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == id.to_s }
        unless issue
          worker = Array(state.fetch("agents", [])).find do |candidate|
            candidate.is_a?(Hash) && candidate["type"].to_s == "worker" && candidate["id"].to_s == id.to_s
          end
          issue = issues.find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == worker&.fetch("issue_id", nil).to_s }
        end
        pull_request_records(issue).find { |candidate| valid_url?(pull_request_url(candidate)) } || pull_request_records(issue).first
      end

      def pull_request_records(record)
        return [] unless record.is_a?(Hash)

        [record["delivery_pull_request"], *Array(record["delivery_pull_requests"])].compact.filter_map do |entry|
          case entry
          when Hash then entry.transform_keys(&:to_s)
          when String then { "url" => entry }
          end
        end
      end

      def pull_request_url(record)
        record.is_a?(Hash) ? record["url"].to_s.strip : ""
      end

      def valid_url?(url)
        url.to_s.match?(GITHUB_PULL_REQUEST_URL)
      end

      def openable?(presentation)
        presentation.is_a?(Hash) && presentation["available"] && valid_url?(presentation["url"])
      end

      def status_label(presentation)
        return "not tracked" unless presentation.is_a?(Hash)
        return "unavailable" unless presentation["available"]
        return "status unavailable" unless presentation.fetch("metadata_available", true)

        label = presentation.fetch("state", "unknown").to_s
        presentation["stale"] ? "#{label} · stale" : label
      end

      def stale_record?(record, now: Time.now.utc)
        checked_at = record["last_checked_at"] || record["verified_at"]
        return true if checked_at.to_s.empty?

        now - Time.iso8601(checked_at.to_s) > STALE_AFTER_SECONDS
      rescue ArgumentError, TypeError
        true
      end

      def missing(id)
        {
          "agent_id" => id.to_s,
          "state" => "missing",
          "available" => false,
          "metadata_available" => false,
          "stale" => false,
          "message" => "No verified delivery pull request is tracked yet."
        }
      end

      def invalid(id, record, url)
        {
          "agent_id" => id.to_s,
          "record" => record,
          "url" => url,
          "state" => "invalid",
          "available" => false,
          "metadata_available" => false,
          "stale" => false,
          "message" => "Tracked delivery pull request metadata does not contain a supported GitHub PR URL."
        }
      end

      def presentation_message(state_name, refresh_unavailable:)
        return "Pull request status is temporarily unavailable; the last verified link is still openable." if refresh_unavailable
        return "Pull request status has not been verified recently; the tracked link is still openable." if state_name == "unknown"

        "Tracked delivery pull request is #{state_name}."
      end
    end
  end
end
