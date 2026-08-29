# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    # Read-only delivery-PR presentation for the agent workspace. Candidate URLs reported in
    # worker prose are intentionally excluded: only kernel-verified delivery PRs are actionable.
    module DeliveryPullRequest
      STALE_AFTER_SECONDS = 5 * 60
      GITHUB_PULL_REQUEST_URL = %r{\Ahttps?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/(\d+)(?:[/?#].*)?\z}
      # A PR nobody can act on anymore. Everything else (open, or not yet
      # verified) is still live work.
      SETTLED_STATES = %w[merged closed].freeze

      module_function

      def for_id(state, id, now: Time.now.utc)
        record = tracked_record_for_id(state, id)
        return missing(id) unless record

        url = pull_request_url(record)
        return invalid(id, record, url) unless valid_url?(url)

        state_name = record_state(record)
        refresh_unavailable = record["availability"].to_s == "unavailable"
        stale = refresh_unavailable || stale_record?(record, now: now)
        {
          "agent_id" => id.to_s,
          "record" => record,
          "url" => url,
          "number" => url[GITHUB_PULL_REQUEST_URL, 1],
          "state" => state_name,
          "available" => true,
          "metadata_available" => !refresh_unavailable,
          "stale" => stale,
          "message" => presentation_message(state_name, refresh_unavailable: refresh_unavailable, stale: stale)
        }
      end

      # Which of an issue's delivery PRs belongs to this id.
      #
      # PRs are stored on the owning issue oldest-first (`delivery_pull_request`
      # is just `delivery_pull_requests.first`), so picking the first valid record
      # meant the oldest PR ever attached won forever: a second worker on the same
      # issue kept showing its predecessor's number. Prefer the PR whose head
      # branch is this worker's own delivery branch, then the newest PR that is
      # still live.
      def tracked_record_for_id(state, id)
        worker = worker_record(state, id)
        issue = issue_record(state, id, worker)
        records = pull_request_records(issue)
        actionable = records.select { |record| valid_url?(pull_request_url(record)) }
        return records.first if actionable.empty?

        branch_record(actionable, worker) || newest_live_record(actionable)
      end

      # Which node the dashboard is currently "looking at" for delivery purposes:
      # the jump-mode cursor while it is active, otherwise the sticky AgentTree
      # selection when it resolves to a worker or an issue. "" means unscoped.
      #
      # A previously focused workspace agent is deliberately *not* a scope: it
      # outlives the workspace view, which is why unscoped chat used to pin one
      # arbitrary worker's PR under the chat bar.
      def scoped_id(state)
        return AgentTreeNavigation.selected_agent_id(state).to_s if AgentTreeNavigation.active?(state)

        target = LogScope.selected_target(state)
        (target.fetch("selected_agent_id", nil) || target.fetch("issue_id", nil)).to_s
      end

      def worker_record(state, id)
        Array(state.fetch("agents", [])).find do |candidate|
          candidate.is_a?(Hash) && candidate["type"].to_s == "worker" && candidate["id"].to_s == id.to_s
        end
      end

      def issue_record(state, id, worker = nil)
        issues = Array(state.fetch("issues", []))
        wanted = worker ? worker.fetch("issue_id", nil).to_s : id.to_s
        issues.find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == wanted }
      end

      # The strongest worker-to-PR link already in state: the kernel verifies a
      # delivery PR against the worker's branch and records `matched_branch` /
      # `head_branch` on it.
      def branch_record(records, worker)
        branch = delivery_branch(worker)
        return nil if branch.empty?

        records.find do |record|
          [record["matched_branch"], record["head_branch"]].any? { |candidate| normalized_branch(candidate) == branch }
        end
      end

      def delivery_branch(worker)
        return "" unless worker.is_a?(Hash)

        metadata = worker["harness_metadata"].is_a?(Hash) ? worker["harness_metadata"] : {}
        normalized_branch(metadata["delivery_branch"] || worker["workspace_branch"])
      end

      def normalized_branch(branch)
        branch.to_s.strip.sub(%r{\Arefs/heads/}, "").sub(%r{\Aorigin/}, "")
      end

      # Records are appended oldest-first, so the last unsettled record is the
      # newest PR still worth looking at. Merged/closed records only win when
      # nothing is live, so a settled issue still shows what it delivered.
      def newest_live_record(records)
        live = records.reject { |record| SETTLED_STATES.include?(record_state(record)) }
        (live.empty? ? records : live).last
      end

      def record_state(record)
        raw = record.is_a?(Hash) ? (record["state"] || record["status"] || record["raw_state"]).to_s.downcase : ""
        %w[open merged closed].include?(raw) ? raw : "unknown"
      end

      def pull_request_records(record)
        return [] unless record.is_a?(Hash)

        Array(record["delivery_pull_requests"]).filter_map do |entry|
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
        # `stale` is freshness of the last forge check, not a PR lifecycle
        # state. Name that dimension so `merged` can never read as contradictory.
        presentation["stale"] ? "#{label} · check stale" : label
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

      def presentation_message(state_name, refresh_unavailable:, stale: false)
        return "Pull request status is temporarily unavailable; the last verified link is still openable." if refresh_unavailable
        return "Pull request status has not been verified recently; the tracked link is still openable." if state_name == "unknown"
        return "Tracked delivery pull request is #{state_name}; its forge status check is stale." if stale

        "Tracked delivery pull request is #{state_name}."
      end
    end
  end
end
