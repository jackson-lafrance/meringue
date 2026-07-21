# frozen_string_literal: true

require "time"

module Meringue
  module State
    module Models
      SCHEMA_VERSION = 1

      LIFECYCLE_STATUSES = %w[queued working idle blocked completed errored killed].freeze
      QUESTION_STATUSES = %w[open answered dismissed].freeze
      LOG_LEVELS = %w[info warning error].freeze
      LOG_SOURCE_TYPES = %w[user kernel head worker harness system].freeze
      PULL_REQUEST_STORAGE_KEYS = %w[
        delivery_pull_request delivery_pull_requests reported_pr_urls candidate_pr_urls
      ].freeze

      module_function

      def empty_state(now: Time.now.utc.iso8601)
        ensure_state_shape!({}, now: now)
      end

      def ensure_state_shape!(state, now: Time.now.utc.iso8601)
        state["schema_version"] ||= SCHEMA_VERSION
        state["projects"] ||= []
        state["issues"] ||= []
        state["agents"] ||= []
        state["questions"] ||= []
        state["logs"] ||= []
        state["conversation"] ||= {}
        state["conversation"]["messages"] ||= []
        state["conversation"]["next_message_id"] ||= max_log_message_id(state)
        state["counters"] ||= {}
        state["counters"]["projects"] ||= max_numeric_suffix(state.fetch("projects"), /^P(\d+)$/)
        state["counters"]["heads"] ||= max_numeric_suffix(state.fetch("agents").select { |agent| agent["type"] == "head" }, /^H(\d+)$/)
        state["counters"]["questions"] ||= max_numeric_suffix(state.fetch("questions"), /^Q(\d+)$/)
        state["counters"]["logs"] ||= max_numeric_suffix(state.fetch("logs"), /^L(\d+)$/)
        state["counters"]["issues_by_project"] ||= {}
        state["counters"]["workers_by_issue"] ||= {}
        state["metadata"] ||= {}
        state["metadata"]["created_at"] ||= now
        state["metadata"]["updated_at"] ||= state["metadata"].fetch("created_at")
        migrate_pull_requests_to_issues!(state)
        state
      end

      def max_log_message_id(state)
        Array(state.dig("conversation", "messages")).filter_map do |message|
          next unless message.is_a?(Hash)

          id = message["id"] || message[:id]
          id && id.to_i
        end.max || 0
      end

      def max_numeric_suffix(records, pattern)
        Array(records).filter_map do |record|
          next unless record.is_a?(Hash)

          match = record.fetch("id", "").to_s.match(pattern)
          match && match[1].to_i
        end.max || 0
      end

      def migrate_pull_requests_to_issues!(state)
        issues_by_id = Array(state["issues"]).select { |issue| issue.is_a?(Hash) }.to_h { |issue| [issue["id"].to_s, issue] }
        Array(state["agents"]).each do |agent|
          next unless agent.is_a?(Hash)
          next unless agent["type"].to_s == "worker"

          issue = issues_by_id[agent["issue_id"].to_s]
          next unless issue

          metadata = agent["harness_metadata"].is_a?(Hash) ? agent["harness_metadata"] : {}
          delivery_records = pull_request_records_from(agent) + pull_request_records_from(metadata)
          candidate_urls = pull_request_urls_from(agent["candidate_pr_urls"]) + pull_request_urls_from(metadata["candidate_pr_urls"])
          reported_urls = pull_request_urls_from(agent["reported_pr_urls"]) + pull_request_urls_from(metadata["reported_pr_urls"])
          attach_pull_requests_to_issue!(
            issue,
            delivery_pull_requests: delivery_records,
            candidate_urls: candidate_urls,
            reported_urls: reported_urls
          )
          scrub_worker_pull_request_keys!(agent)
          scrub_worker_pull_request_keys!(metadata)
        end
        Array(state["issues"]).each { |issue| normalize_issue_pull_request_fields!(issue) if issue.is_a?(Hash) }
        state
      end

      def attach_pull_requests_to_issue!(issue, delivery_pull_requests: [], candidate_urls: [], reported_urls: [])
        return issue unless issue.is_a?(Hash)

        records = pull_request_records_from(issue) + Array(delivery_pull_requests).compact
        merged_records = merge_pull_request_records(records)
        unless merged_records.empty?
          issue["delivery_pull_requests"] = merged_records
          issue["delivery_pull_request"] = merged_records.first
        end

        record_urls = merged_records.filter_map { |record| pull_request_record_url(record) }
        merge_url_array!(issue, "candidate_pr_urls", pull_request_urls_from(candidate_urls))
        merge_url_array!(issue, "reported_pr_urls", pull_request_urls_from(reported_urls) + record_urls)
        normalize_issue_pull_request_fields!(issue)
      end

      def normalize_issue_pull_request_fields!(issue)
        records = merge_pull_request_records(pull_request_records_from(issue))
        if records.empty?
          issue.delete("delivery_pull_request")
          issue.delete("delivery_pull_requests")
        else
          issue["delivery_pull_requests"] = records
          issue["delivery_pull_request"] = records.first
        end
        merge_url_array!(issue, "candidate_pr_urls", [])
        merge_url_array!(issue, "reported_pr_urls", [])
        issue.delete("candidate_pr_urls") if Array(issue["candidate_pr_urls"]).empty?
        issue.delete("reported_pr_urls") if Array(issue["reported_pr_urls"]).empty?
        issue
      end

      def pull_request_records_from(record)
        return [] unless record.is_a?(Hash)

        [
          record["delivery_pull_request"],
          *Array(record["delivery_pull_requests"])
        ].compact
      end

      def merge_pull_request_records(records)
        by_url = {}
        Array(records).each do |record|
          url = pull_request_record_url(record)
          next if url.to_s.empty?

          normalized = record.is_a?(Hash) ? record : { "url" => url }
          by_url[url] = (by_url[url] || {}).merge(stringify_keys(normalized))
        end
        by_url.values
      end

      def pull_request_record_url(record)
        if record.is_a?(Hash)
          record["url"] || record[:url]
        else
          record
        end.to_s.strip
      end

      def pull_request_urls_from(value)
        Array(value).filter_map do |entry|
          url = pull_request_record_url(entry)
          url.empty? ? nil : url
        end.uniq
      end

      def merge_url_array!(record, key, urls)
        merged = (pull_request_urls_from(record[key]) + pull_request_urls_from(urls)).uniq
        record[key] = merged unless merged.empty?
        merged
      end

      def scrub_worker_pull_request_keys!(record)
        return unless record.is_a?(Hash)

        PULL_REQUEST_STORAGE_KEYS.each { |key| record.delete(key) }
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end
    end
  end
end
