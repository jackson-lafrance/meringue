# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Turning kernel log entries into chat messages exactly once.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def sync_state_logs!(_state)
        # Durable kernel logs are the visible event stream. Conversation messages
        # are kept only for transient in-flight status and legacy persisted rows,
        # so do not synthesize second copies of completed head/worker events here.
      end

      def sync_polled_head_updates!(state)
        Array(state.fetch("agents", [])).each do |agent|
          next unless agent.fetch("type", nil) == "head"

          metadata = agent.fetch("harness_metadata", {}) || {}
          head_result = metadata["head_result"]
          next unless metadata["head_result_applied_at"] && head_result.is_a?(Hash)

          append_message_once(
            head_completed_key(agent.fetch("id", nil)),
            "meringue",
            head_result_user_lines(head_result).join("\n")
          )
        end
      end

      def sync_worker_completion_updates!(state)
        Array(state.fetch("agents", [])).each do |agent|
          issue = Array(state.fetch("issues", [])).find { |candidate| candidate.fetch("id", nil) == agent.fetch("issue_id", nil) }
          next unless existing_worker_completion_event?(agent, issue)

          metadata = agent.fetch("harness_metadata", {}) || {}
          next unless log_sync_after_start?(metadata["completed_at"])

          append_message_once(
            worker_completed_key(agent.fetch("id", nil)),
            "agent",
            worker_completed_text_from_agent(agent, issue),
            source_id: agent.fetch("id", nil)
          )
        end
      end

      def existing_head_completion_event?(agent)
        return false unless agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata["head_result_applied_at"] && metadata["head_result"].is_a?(Hash)
      end

      def existing_worker_completion_event?(agent, issue = nil)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "completed"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata["completed_at"] || Array(metadata["reported_pr_urls"]).any? || AgentTreeNavigation.agent_pr_url(issue || {})
      end

      def log_sync_after_start?(timestamp)
        return false if timestamp.to_s.empty?

        parsed = Timestamps.parse(timestamp)
        return false unless parsed

        parsed >= @started_at
      end

      def worker_completed_text_from_agent(agent, issue = nil)
        metadata = agent.fetch("harness_metadata", {}) || {}
        user_facing_worker_lines(
          agent_id: agent.fetch("id", "worker"),
          pr_urls: verified_agent_pr_urls(metadata, issue),
          last_assistant_text: metadata["last_assistant_text"]
        ).join("\n")
      end

      def verified_agent_pr_urls(metadata, issue = nil)
        delivery_pull_requests = [
          issue&.fetch("delivery_pull_request", nil),
          *Array(issue&.fetch("delivery_pull_requests", nil)),
          metadata["delivery_pull_request"],
          *Array(metadata["delivery_pull_requests"])
        ].compact
        delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }.uniq
      end

      def head_completed_key(head_id)
        "head_completed:#{head_id}"
      end

      def worker_completed_key(agent_id)
        "worker_completed:#{agent_id}"
      end

      def remember_log_event(key)
        return if key.to_s.empty?

        @chat_mutex.synchronize { @log_event_keys[key] = true }
      end

      def forget_log_event(key)
        return if key.to_s.empty?

        @chat_mutex.synchronize { @log_event_keys.delete(key) }
      end
    end
  end
end
