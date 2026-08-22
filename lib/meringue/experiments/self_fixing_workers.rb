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

      module_function

      def eligible?(worker)
        return false unless worker.is_a?(Hash)
        return false unless worker.fetch("type", nil) == "worker"
        return false unless ELIGIBLE_STATUSES.include?(worker.fetch("status", nil).to_s)

        metadata = worker.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        !metadata.key?(RECOVERY_CHILD_METADATA_KEY) && recovery_record(worker).fetch("source_worker_id", nil).to_s.empty?
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

      def prompt(worker)
        issue_id = worker.fetch("issue_id", "the affected issue")
        source_id = worker.fetch("id", "the failed worker")
        <<~PROMPT.strip
          Diagnose and recover the failed or blocked worker #{source_id} on #{issue_id}.
          Inspect the existing work and the worker's failure context, then make the smallest safe correction needed to complete the original task. Do not wait, poll, or spawn another recovery worker. If the task cannot be safely completed, explain the blocker in your final report.
        PROMPT
      end

      def title(worker)
        "Self-fix #{worker.fetch("id", "worker")}"
      end
    end
  end
end
