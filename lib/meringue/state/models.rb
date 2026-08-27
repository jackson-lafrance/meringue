# frozen_string_literal: true

require "time"

require_relative "../goals/record"
require_relative "../project_naming"

module Meringue
  module State
    module Models
      SCHEMA_VERSION = 1

      # `paused` is the explicit user-directed worker state: the current turn was
      # aborted without destroying its durable session, workspace, or queued work.
      # `supervision_lost` is the separate paused-runtime state: the supervisor
      # that owns a session's transport has disappeared (both the recorded owner
      # and the harness child are gone), so the session's runtime is paused even
      # though the durable session, workspace, and queued work remain valid. Both
      # states are recoverable and distinct from `working` (a live turn) and from
      # `errored` (a terminal settle). See `Meringue::Supervisor::Service` and
      # `docs/supervisor-transport-ownership.md`.
      LIFECYCLE_STATUSES = %w[queued working idle blocked paused completed errored killed supervision_lost].freeze
      QUESTION_STATUSES = %w[open answered dismissed].freeze
      LOG_LEVELS = %w[info warning error].freeze
      LOG_SOURCE_TYPES = %w[user kernel head worker harness system].freeze
      # This keeps roughly two weeks of activity at the event rate measured while
      # investigating TUI latency, without allowing lifecycle output to dominate
      # persistence indefinitely. Logs remain chronological within this window.
      LOG_RETENTION_LIMIT = 500
      PULL_REQUEST_STORAGE_KEYS = %w[
        delivery_pull_request delivery_pull_requests reported_pr_urls candidate_pr_urls
      ].freeze
      AGENT_WORKSPACE_VIEWS = %w[agent terminal].freeze
      AGENT_WORKSPACE_FILTERS = %w[all output final reasoning tools].freeze
      WORKER_WORKSPACE_MODES = %w[isolated shared_read_only].freeze
      # A head is stateless per user message, so "retrying" one means re-running the request it
      # never finished routing. Three statuses leave a request unrouted:
      #   errored  its turn or session died before it returned a result
      #   killed   the user stopped it before it routed
      #   blocked  its result was applied but a command was rejected or failed, so part (often
      #            all) of the request never landed anywhere
      # A `queued`/`working`/`idle` head is still routing the message, and a `completed` head
      # applied every command it proposed, so neither is a retry target.
      HEAD_RETRY_STATUSES = %w[errored killed blocked].freeze
      HEAD_COMMAND_LANDED_STATUS = "accepted"

      module_function

      # Shared by the kernel (which performs explicit /retry) and the TUI (which marks the row as
      # recoverable and double-clickable), so every layer agrees on which head rows can be retried.
      def head_retry_target?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil).to_s == "head"
        return false unless HEAD_RETRY_STATUSES.include?(agent.fetch("status", nil).to_s)
        # No batch was applied at all, so the whole request is still unrouted.
        return true unless head_result_applied?(agent)

        # An applied batch is retryable only while part of it never landed. The per-command
        # journal is the durable record of that, so a retry can re-run what is missing while
        # leaving the commands that already routed alone.
        head_unrouted_commands(agent).any? || !head_routed_anything?(agent)
      end

      def head_result_applied?(agent)
        !head_metadata(agent).fetch("head_result_applied_at", nil).to_s.strip.empty?
      end

      def head_command_journal(agent)
        Array(head_metadata(agent).fetch("head_result_command_journal", nil)).select { |entry| entry.is_a?(Hash) }
      end

      # Commands whose work really landed. These must never be proposed again by a retry.
      def head_applied_commands(agent)
        head_command_journal(agent).select { |entry| entry.fetch("status", nil).to_s == HEAD_COMMAND_LANDED_STATUS }
      end

      # Commands that were rejected, failed, or never ran. These are what a retry still owes
      # the user.
      def head_unrouted_commands(agent)
        head_command_journal(agent).reject { |entry| entry.fetch("status", nil).to_s == HEAD_COMMAND_LANDED_STATUS }
      end

      # Did an applied batch handle the request at all? An accepted command routed work, a recorded
      # question handed it back to the user, and a direct response answered it without orchestration.
      # A batch that did none of those dropped the message, which is exactly what retry recovers.
      def head_routed_anything?(agent)
        return true if head_applied_commands(agent).any?
        return true unless head_metadata(agent).fetch("response", nil).to_s.strip.empty?

        Array(head_metadata(agent).fetch("head_result_question_ids", nil)).any? { |id| !id.to_s.strip.empty? }
      end

      def head_metadata(agent)
        metadata = agent.is_a?(Hash) ? agent.fetch("harness_metadata", nil) : nil
        metadata.is_a?(Hash) ? metadata : {}
      end

      def empty_state(now: Time.now.utc.iso8601)
        ensure_state_shape!({}, now: now)
      end

      def ensure_state_shape!(state, now: Time.now.utc.iso8601)
        state["schema_version"] ||= SCHEMA_VERSION
        state["projects"] ||= []
        state["issues"] ||= []
        state["agents"] ||= []
        state["questions"] ||= []
        # Goal loop controllers. A goal is attached to exactly one issue and is durable
        # orchestration state, so it lives beside issues rather than in logs.
        Goals::Record.normalize_goals!(state)
        state["logs"] ||= []
        state["conversation"] ||= {}
        state["conversation"]["messages"] ||= []
        state["conversation"]["next_message_id"] ||= max_log_message_id(state)
        state["ui"] = {} unless state["ui"].is_a?(Hash)
        normalize_worker_workspace_modes!(state)
        normalize_agent_workspace_state!(state)
        state["counters"] ||= {}
        state["counters"]["projects"] ||= max_numeric_suffix(state.fetch("projects"), /^P(\d+)$/)
        state["counters"]["heads"] ||= max_numeric_suffix(state.fetch("agents").select { |agent| agent["type"] == "head" }, /^H(\d+)$/)
        state["counters"]["questions"] ||= max_numeric_suffix(state.fetch("questions"), /^Q(\d+)$/)
        state["counters"]["goals"] ||= max_numeric_suffix(state.fetch("goals"), Goals::Record::ID_PATTERN)
        # Calculate the high-water mark before retention so loading an older,
        # unbounded state without a log counter cannot reuse a discarded ID.
        state["counters"]["logs"] = [
          state["counters"].fetch("logs", 0).to_i,
          max_numeric_suffix(state.fetch("logs"), /^L(\d+)$/)
        ].max
        retain_recent_logs!(state)
        state["counters"]["issues_by_project"] ||= {}
        state["counters"]["workers_by_issue"] ||= {}
        state["metadata"] ||= {}
        migrate_active_harness_defaults!(state)
        migrate_agent_session_defaults!(state)
        state["metadata"]["created_at"] ||= now
        state["metadata"]["updated_at"] ||= state["metadata"].fetch("created_at")
        migrate_pull_requests_to_issues!(state)
        repair_project_names!(state)
        state
      end

      # Older snapshots stored one shared future-agent harness. Materialize it
      # into role-aware keys while retaining the shared compatibility fallback.
      def migrate_active_harness_defaults!(state)
        metadata = state["metadata"]
        return state unless metadata.is_a?(Hash)

        shared = metadata["active_harness"]
        return state if shared.to_s.strip.empty?

        metadata["active_head_harness"] ||= shared
        metadata["active_worker_harness"] ||= shared
        shared_label = metadata["active_harness_label"]
        metadata["active_head_harness_label"] ||= shared_label if shared_label
        metadata["active_worker_harness_label"] ||= shared_label if shared_label
        state
      end

      # State written when Pi was the only harness used a provider-specific key
      # for future agent defaults. Import it once into the generic metadata shape;
      # the neutral key is authoritative when both are present. Older snapshots
      # also stored one shared model alongside role-specific thinking values, so
      # materialize that model into both role records for stable consumers.
      def migrate_agent_session_defaults!(state)
        metadata = state["metadata"]
        return state unless metadata.is_a?(Hash)

        legacy_defaults = metadata["pi_session_defaults"]
        defaults = metadata["agent_session_defaults"]
        defaults = copy_state_value(legacy_defaults) unless defaults.is_a?(Hash)
        return state unless defaults.is_a?(Hash)

        metadata["agent_session_defaults"] = defaults
        shared_model = defaults["model"].to_s.strip
        roles = defaults["roles"]
        roles = {} unless roles.is_a?(Hash)
        defaults["roles"] = %w[head worker].each_with_object(roles) do |role, migrated|
          role_defaults = migrated[role]
          role_defaults = {} unless role_defaults.is_a?(Hash)
          role_model = role_defaults["model"].to_s.strip
          role_defaults["model"] = role_model unless role_model.empty?
          role_defaults["model"] = shared_model if role_defaults["model"].to_s.empty? && !shared_model.empty?
          migrated[role] = role_defaults
        end
        state
      end

      def copy_state_value(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, nested), copy| copy[key] = copy_state_value(nested) }
        when Array
          value.map { |nested| copy_state_value(nested) }
        else
          value
        end
      end

      # Older worker records predate the explicit safety contract. Their historical workspaces
      # were writable/isolated, so migration must never infer read-only sharing from prompts or
      # project-root paths.
      # Runs on every state read, so it writes only where the value actually changes: four
      # unconditional hash stores per worker cost real time once there are hundreds of them,
      # and they dirty pages the caller then has to serialize again.
      def normalize_worker_workspace_modes!(state)
        Array(state["agents"]).each do |agent|
          next unless agent.is_a?(Hash) && agent["type"].to_s == "worker"

          requested = agent["workspace_mode"]
          requested = "isolated" unless WORKER_WORKSPACE_MODES.include?(requested)
          effective = agent["effective_workspace_mode"]
          effective = "isolated" unless WORKER_WORKSPACE_MODES.include?(effective)
          agent["workspace_mode"] = requested unless agent["workspace_mode"] == requested
          agent["effective_workspace_mode"] = effective unless agent["effective_workspace_mode"] == effective
          metadata = agent["harness_metadata"]
          next unless metadata.is_a?(Hash)

          metadata["workspace_mode"] ||= requested
          metadata["effective_workspace_mode"] ||= effective
        end
      end

      # Agent-workspace presentation state is durable but is not orchestration state. It is
      # deliberately small: harness/process truth remains on the worker record and is reconciled
      # by the kernel. Invalid selections are cleared rather than resurrecting pruned workers.
      def normalize_agent_workspace_state!(state, workspace: nil)
        state["ui"] = {} unless state["ui"].is_a?(Hash)
        source = workspace || state["ui"]["agent_workspace"]
        source = {} unless source.is_a?(Hash)

        worker_ids = Array(state["agents"]).filter_map do |agent|
          next unless agent.is_a?(Hash) && agent["type"].to_s == "worker"

          agent["id"].to_s
        end
        selected_agent_id = pull_request_record_url(source["selected_agent_id"])
        selected_agent_id = nil unless worker_ids.include?(selected_agent_id)
        view = source["view"].to_s
        view = "agent" unless AGENT_WORKSPACE_VIEWS.include?(view)
        filter = source["filter"].to_s
        filter = "all" unless AGENT_WORKSPACE_FILTERS.include?(filter)

        normalized = {
          "selected_agent_id" => selected_agent_id,
          "view" => view,
          "filter" => filter,
          "draft" => selected_agent_id ? source.fetch("draft", "").to_s : "",
          "agent_scroll_offset" => nonnegative_integer(source["agent_scroll_offset"]),
          "terminal_scroll_offset" => nonnegative_integer(source["terminal_scroll_offset"]),
          "updated_at" => source["updated_at"]
        }.compact
        state["ui"]["agent_workspace"] = normalized
      end

      def agent_workspace_state(state)
        normalize_agent_workspace_state!(state)
        stringify_keys(state.fetch("ui").fetch("agent_workspace")).transform_values do |value|
          value.is_a?(String) ? value.dup : value
        end
      end

      def nonnegative_integer(value)
        [Integer(value || 0), 0].max
      rescue ArgumentError, TypeError
        0
      end

      def retain_recent_logs!(state, limit: LOG_RETENTION_LIMIT)
        logs = state.fetch("logs")
        overflow = logs.length - limit
        return false unless overflow.positive?

        logs.shift(overflow)
        true
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

      # A project name is the product's name; a lifecycle status is what Meringue is doing
      # to it. State written before the kernel enforced that (or by a head that echoed a
      # rendered "Meringue working" label back into AddProject) is repaired on load instead
      # of staying broken, so the next save persists the concise name.
      def repair_project_names!(state)
        Array(state["projects"]).each do |project|
          next unless project.is_a?(Hash)
          # Only a name that really carries a status is touched, so an untouched name is
          # never rewritten for cosmetic reasons.
          next unless ProjectNaming.status_suffix?(project["name"])

          project["name"] = ProjectNaming.without_status_suffix(project["name"])
        end
        state
      end

      # This runs inside `ensure_state_shape!`, which means it runs on every state read *and*
      # every kernel command, forever - not only on the one load that migrates an old file.
      # Walking and rebuilding every worker and every issue each time made it ~75% of the cost
      # of normalizing a snapshot (4.7ms of 6.3ms at 1,000 workers). Both halves are no-ops
      # unless a record actually carries one of the pull-request keys, so the presence check
      # comes first and the allocation-heavy work only visits the records that need it.
      def migrate_pull_requests_to_issues!(state)
        legacy_workers = Array(state["agents"]).select { |agent| legacy_worker_pull_requests?(agent) }
        issues = Array(state["issues"])
        return state if legacy_workers.empty? && issues.none? { |issue| pull_request_keys?(issue) }

        unless legacy_workers.empty?
          issues_by_id = issues.select { |issue| issue.is_a?(Hash) }.to_h { |issue| [issue["id"].to_s, issue] }
          legacy_workers.each do |agent|
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
        end
        issues.each { |issue| normalize_issue_pull_request_fields!(issue) if pull_request_keys?(issue) }
        state
      end

      # An issue with none of these keys is already in its normalized shape:
      # `normalize_issue_pull_request_fields!` would delete keys that are absent and decline to
      # write empty arrays, observing nothing.
      def pull_request_keys?(record)
        record.is_a?(Hash) && PULL_REQUEST_STORAGE_KEYS.any? { |key| record.key?(key) }
      end

      # Pull requests used to live on the worker. A worker carrying none of those keys, on
      # itself or in its harness metadata, has nothing left to move onto its issue.
      def legacy_worker_pull_requests?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent["type"].to_s == "worker"

        pull_request_keys?(agent) || pull_request_keys?(agent["harness_metadata"])
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
