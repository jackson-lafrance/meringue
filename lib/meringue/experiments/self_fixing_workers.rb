# frozen_string_literal: true

module Meringue
  module Experiments
    # Policy and durable-marker helpers for the self-fixing-workers experiment. The
    # kernel owns state mutation and spawning; this module deliberately contains no
    # I/O so the safety policy can be exercised without starting a harness.
    module SelfFixingWorkers
      MAX_RECOVERY_ATTEMPTS = 1
      ELIGIBLE_STATUSES = %w[errored blocked].freeze
      RECOVERY_METADATA_KEY = "self_fixing_recovery"
      RECOVERY_CHILD_METADATA_KEY = "self_fixing_recovery_of"
      FAILURE_CLASSIFICATION_KEY = "failure_classification"
      PLATFORM_DEFECT = "platform_or_configuration"
      TASK_FAILURE = "original_task"

      module_function

      def eligible?(worker)
        return false unless worker.is_a?(Hash)
        return false unless worker.fetch("type", nil) == "worker"
        return false unless ELIGIBLE_STATUSES.include?(worker.fetch("status", nil).to_s)

        metadata = worker.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        return false if focus_preparation_failed_without_settle_failure?(metadata)
        return false if human_input_pending?(metadata)

        !metadata.key?(RECOVERY_CHILD_METADATA_KEY) && recovery_record(worker).fetch("source_worker_id", nil).to_s.empty?
      end

      def focus_preparation_failed_without_settle_failure?(metadata)
        handoff = metadata.fetch("last_interactive_handoff", nil)
        handoff.is_a?(Hash) && handoff.fetch("outcome", nil).to_s == "prepare_failed" &&
          !metadata.fetch("settle_failure", nil).is_a?(Hash)
      end

      def human_input_pending?(metadata)
        Harness::HumanInput.pending_marker?(metadata.fetch("human_input_request", nil))
      end

      def recovery_record(worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        record = metadata.is_a?(Hash) ? metadata.fetch(RECOVERY_METADATA_KEY, nil) : nil
        record.is_a?(Hash) ? record : {}
      end

      def attempts(worker)
        recovery_record(worker).fetch("attempts", 0).to_i
      end

      def claimable?(worker)
        return false unless eligible?(worker)

        record = recovery_record(worker)
        return false if record.fetch("state", nil).to_s == "spawning"
        attempts(worker) < MAX_RECOVERY_ATTEMPTS
      end

      def child?(worker, source_id)
        return false unless worker.is_a?(Hash)

        metadata = worker.fetch("harness_metadata", {}) || {}
        return false unless metadata.is_a?(Hash)

        metadata.fetch(RECOVERY_CHILD_METADATA_KEY, nil).to_s == source_id.to_s ||
          recovery_record(worker).fetch("source_worker_id", nil).to_s == source_id.to_s
      end

      def classification(worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        value = metadata.is_a?(Hash) ? metadata.fetch(FAILURE_CLASSIFICATION_KEY, nil) : nil
        return { "kind" => TASK_FAILURE } unless value.is_a?(Hash)

        kind = value.fetch("kind", value.fetch("class", nil)).to_s
        return { "kind" => PLATFORM_DEFECT, "repair_issue_id" => value.fetch("repair_issue_id", nil), "reason" => value.fetch("reason", nil) }.compact if kind == PLATFORM_DEFECT

        { "kind" => TASK_FAILURE }
      end

      def repair_lane?(worker)
        details = classification(worker)
        details.fetch("kind") == PLATFORM_DEFECT && !details.fetch("repair_issue_id", nil).to_s.empty?
      end

      def continuation_prompt(worker)
        metadata = worker.fetch("harness_metadata", {}) || {}
        assignment = metadata.fetch("spawn_prompt", "")
        result = metadata.fetch("last_assistant_text", nil)
        source_id = worker.fetch("id", "the failed worker")
        sections = [
          "Continue the original assignment after worker #{source_id}'s failed turn.",
          "Use the existing worktree and branch. Start with git status and git log, then preserve completed work.",
          "--- Original assignment ---\n\n#{assignment}"
        ]
        sections << "--- Predecessor result ---\n\n#{result}" unless result.to_s.strip.empty?
        sections << "Complete every original requirement. Do not repair Meringue or local configuration in this lane. Do not spawn another recovery worker. Report tests and delivery state."
        sections.join("\n\n")
      end

      def repair_prompt(worker)
        details = classification(worker)
        source_id = worker.fetch("id", "the failed worker")
        reason = details.fetch("reason", "the recorded platform or configuration failure")
        "Repair only the durable Meringue or configuration defect recorded for worker #{source_id}: #{reason}. Do not implement the original task, use its worktree, or spawn another recovery worker. Make local configuration changes reversible, run focused checks, and report the repair result."
      end

      def prompt(worker)
        continuation_prompt(worker)
      end

      def title(worker)
        source_title = worker.fetch("title", nil).to_s.strip
        source_title = worker.fetch("task_title", nil).to_s.strip if source_title.empty?
        source_title = "worker" if source_title.empty?
        "Self-fix: #{source_title}"
      end
    end
  end
end
