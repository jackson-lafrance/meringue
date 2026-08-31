# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # How long each working agent has gone without producing anything.
      #
      # Meringue's whole reason to exist is watching several agents at once, and the question it
      # could not answer was the first one a user asks: has this one stopped, or is it still
      # thinking? Session state said `working` for a worker two seconds into its turn and for one
      # that had been silent for forty minutes, identically.
      #
      # `last_activity_at` is the answer, and the rule that makes it trustworthy is that only
      # *observed activity* advances it - harness events drained this pass, session progress, a
      # prompt the user delivered, or a harness heartbeat that moved forward. Meringue's own
      # bookkeeping writes never do, which is why the clock does not reset itself the moment the
      # quiet warning is recorded.
      #
      # Quiet is reported as quiet, never as stuck. A long tool call and a long think are both
      # quiet, and Meringue cannot tell them apart from outside the harness; what it can honestly
      # say is how long it has been since anything came out.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Advance a worker's activity clock. Monotonic: an out-of-order or unparseable timestamp is
      # ignored rather than moving the clock backwards, so a harness that reports a stale
      # heartbeat cannot make a quiet worker look busy. Returns whether the record changed.
      def record_worker_activity!(agent, observed_at)
        return false unless agent.is_a?(Hash)

        incoming = parse_time_or_nil(observed_at)
        return false unless incoming

        metadata = agent.fetch("harness_metadata", nil)
        metadata = agent["harness_metadata"] = {} unless metadata.is_a?(Hash)
        previous = parse_time_or_nil(metadata[WORKER_LAST_ACTIVITY_KEY])
        return false if previous && incoming <= previous

        metadata[WORKER_LAST_ACTIVITY_KEY] = incoming.utc.iso8601
        # The stretch of quiet this warning described is over.
        metadata.delete(WORKER_QUIET_WARNING_MARKER_KEY)
        true
      end

      # Start the clock for a worker that has none: one written before this existed, or one
      # adopted from a state file after a restart.
      #
      # It starts *now*, not at the record's own `updated_at`. Meringue can honestly say "I have
      # been watching this and heard nothing for twenty minutes"; it cannot say that about the
      # three days it was not running. Seeding from the stale record instead would report every
      # `working` row in a reloaded state file as quiet at once, which is noise rather than a
      # signal, and would be a claim Meringue is not in a position to make.
      def seed_worker_activity!(agent, now)
        return false unless agent.is_a?(Hash)

        metadata = agent.fetch("harness_metadata", nil)
        metadata = agent["harness_metadata"] = {} unless metadata.is_a?(Hash)
        return false if present_string(metadata[WORKER_LAST_ACTIVITY_KEY])

        metadata[WORKER_LAST_ACTIVITY_KEY] = now
        true
      end

      # What one poll observed. Every drained event is activity, including reasoning deltas and
      # tool lifecycle events that intentionally do not become worker log lines. Anything Meringue
      # did log is also activity; otherwise the harness's last-event timestamp is the evidence.
      def observed_worker_activity_at(session_ref, events, log_entry_ids, now)
        return now if Array(events).any? || Array(log_entry_ids).any?
        return nil unless session_ref.is_a?(Hash)

        session_ref.fetch("last_event_at", nil)
      end

      # Seconds a worker may produce nothing before it is called quiet. 0 disables the signal.
      # A configuration Meringue cannot read must not silence the dashboard, so the default
      # stands rather than the signal turning itself off.
      def quiet_worker_warning_seconds
        seconds = Integer(config.setting("agent.quiet_worker_warning"), exception: false)
        return WORKER_QUIET_WARNING_SECONDS if seconds.nil?

        seconds.negative? ? 0 : seconds
      rescue StandardError
        WORKER_QUIET_WARNING_SECONDS
      end

      # The instant a worker's quiet stretch is measured from. A worker with no clock has not
      # been watched yet, so there is no honest answer and it is not reported as quiet.
      def worker_activity_reference(agent)
        metadata = agent.fetch("harness_metadata", nil)
        metadata = {} unless metadata.is_a?(Hash)
        parse_time_or_nil(metadata[WORKER_LAST_ACTIVITY_KEY])
      end

      def worker_quiet_seconds(agent, now)
        reference = worker_activity_reference(agent)
        return nil unless reference

        current = parse_time_or_nil(now)
        return nil unless current

        elapsed = (current - reference).to_i
        elapsed.negative? ? 0 : elapsed
      end

      # Only a worker that is supposed to be producing something can be quiet. A queued, paused,
      # blocked, or settled worker is silent on purpose and saying so would be noise.
      def quiet_warning_candidate?(agent)
        return false unless agent.is_a?(Hash)
        return false unless agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "working"
        return false if worker_provisioning_in_progress?(agent)

        true
      end

      # One `warning` per quiet stretch, per worker. The marker that makes it once-only lives
      # beside the activity clock and is cleared by `record_worker_activity!`, so a worker that
      # goes quiet, speaks, and goes quiet again is reported both times.
      def warn_quiet_workers
        threshold = quiet_worker_warning_seconds
        return [] unless threshold.positive?

        synchronized_state do
          state = normalized_state
          now = timestamp
          results = state.fetch("agents").filter_map do |agent|
            next unless quiet_warning_candidate?(agent)

            metadata = agent.fetch("harness_metadata", {}) || {}
            # The marker is a durable fact, not a value to display. Treat any persisted marker
            # as present so older snapshots (or a concurrent refresh that serialized it as false)
            # cannot reopen the same quiet stretch and append another warning.
            next if metadata.is_a?(Hash) && metadata.key?(WORKER_QUIET_WARNING_MARKER_KEY)

            quiet_seconds = worker_quiet_seconds(agent, now)
            next unless quiet_seconds && quiet_seconds >= threshold

            record_quiet_worker_warning!(state, agent, quiet_seconds, now)
          end
          next results if results.empty?

          touch_state!(state, now)
          store.save(state)
          results
        end
      end

      def record_quiet_worker_warning!(state, agent, quiet_seconds, now)
        metadata = agent.fetch("harness_metadata", nil)
        metadata = agent["harness_metadata"] = {} unless metadata.is_a?(Hash)
        metadata[WORKER_QUIET_WARNING_MARKER_KEY] = now
        log_ids = append_log(
          state,
          source_type: "worker",
          source_id: agent.fetch("id", nil),
          level: "warning",
          message: quiet_worker_warning_message(agent, quiet_seconds),
          details: {
            "kind" => "worker_quiet",
            "quiet_seconds" => quiet_seconds,
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "last_activity_at" => worker_activity_reference(agent)&.utc&.iso8601
          }.compact
        )
        {
          "status" => "accepted",
          "agent_id" => agent.fetch("id", nil),
          "quiet_seconds" => quiet_seconds,
          "log_entry_ids" => log_ids
        }
      end

      # Says what is true (no output for this long) and what to do about it, without claiming to
      # know whether the agent is stuck. Both remedies are one keystroke from the row itself.
      def quiet_worker_warning_message(agent, quiet_seconds)
        "Worker #{agent.fetch("id", "?")} has produced no output for #{quiet_duration_phrase(quiet_seconds)}. " \
          "It may still be working; open its focused workspace to watch it, or prompt it to check in."
      end

      # Prose, for a log line a person reads once. The AgentTree chip has its own compact form.
      def quiet_duration_phrase(seconds)
        total = seconds.to_i
        return count_phrase(total, "second") if total < 60

        minutes = total / 60
        return count_phrase(minutes, "minute") if minutes < 60

        hours = minutes / 60
        remainder = minutes % 60
        return count_phrase(hours, "hour") if remainder.zero?

        "#{count_phrase(hours, "hour")} #{count_phrase(remainder, "minute")}"
      end
    end
  end
end
