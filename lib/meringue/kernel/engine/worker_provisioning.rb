# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Asynchronous worker provisioning: the executor threads, the reserved-worker slots they fill,
      # and the recovery of reservations and head results a previous process left behind.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Adds a durable reservation to this process's bounded executor. The in-memory set is only a
      # duplicate-work guard; state remains authoritative, so a process crash loses no work and a
      # later reconciliation pass can enqueue the same reservation under a new live owner.
      def schedule_worker_provisioning(agent_id)
        return false unless @async_worker_provisioning

        submitted = @worker_provisioning_jobs_mutex.synchronize do
          next false if @worker_provisioning_jobs.key?(agent_id.to_s)

          @worker_provisioning_jobs[agent_id.to_s] = true
          start_worker_provisioning_threads_locked
          @worker_provisioning_queue << agent_id.to_s
          true
        end
        submitted
      end

      def start_worker_provisioning_threads_locked
        while @worker_provisioning_threads.length < worker_provisioning_concurrency
          index = @worker_provisioning_threads.length + 1
          @worker_provisioning_threads << Thread.new do
            Thread.current.name = "meringue-worker-provisioner-#{index}" if Thread.current.respond_to?(:name=)
            loop do
              agent_id = @worker_provisioning_queue.pop
              begin
                provision_reserved_worker(agent_id)
              rescue StandardError => e
                record_worker_provisioning_executor_error(agent_id, e)
              ensure
                @worker_provisioning_jobs_mutex.synchronize do
                  @worker_provisioning_jobs.delete(agent_id)
                  @worker_provisioning_jobs_condition.broadcast
                end
              end
            end
          end
        end
      end

      def provision_reserved_worker(agent_id)
        command = synchronized_state do
          state = normalized_state
          agent = find_agent(state, agent_id)
          next nil unless agent && agent.fetch("type", nil) == "worker"
          next nil unless agent.fetch("status", nil) == "queued"
          next nil if agent_has_session_reference?(agent) || waiting_deferred_worker?(agent)
          next nil if owned_by_other_live_instance?(agent)

          metadata = agent.fetch("harness_metadata", {}) || {}
          next nil unless present_string(metadata.fetch("spawn_prompt", nil))
          # The configured limit is host-wide, not merely per Engine object. The state lock makes
          # this check-and-claim atomic across dashboards sharing the state file. A dead owner's
          # stale marker consumes no slot and will itself be recovered by reconciliation.
          active_provisioners = state.fetch("agents").count do |other|
            next false if Ids.same?(other.fetch("id", nil), agent_id)
            next false unless worker_provisioning_slot_occupied?(other)

            ownership = other.fetch("harness_metadata", {}) || {}
            ownership.fetch("owner_instance_id", nil).to_s == instance_id ||
              !other_live_instance_pid(
                ownership.fetch("owner_instance_id", nil),
                ownership.fetch("owner_instance_pid", nil),
                ownership.fetch("owner_instance_started_at", nil)
              ).nil?
          end
          next nil if active_provisioners >= worker_provisioning_concurrency

          now = timestamp
          agent["updated_at"] = now
          agent["harness_metadata"] = metadata.merge(
            "provisioning_state" => "allocating_workspace",
            "provisioning_attempt_started_at" => now,
            "provisioning_next_step" => nil,
            **instance_ownership_metadata
          ).compact
          touch_state!(state, now)
          store.save(state)
          worker_reservation_command(agent, provision_reserved: true)
        end
        return unless command

        # Do not call apply: its worker-spawn mutex intentionally serializes public reservation
        # commands. Provisioners operate on distinct, durably claimed records and may run together.
        spawn_worker(command.fetch("command_id", nil), "SpawnWorker", command.fetch("payload"))
      end

      def worker_provisioning_slot_occupied?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false if agent_has_session_reference?(agent)

        %w[allocating_workspace starting_harness].include?(
          (agent.fetch("harness_metadata", {}) || {}).fetch("provisioning_state", nil).to_s
        )
      end

      def worker_reservation_command(agent, provision_reserved: false)
        metadata = agent.fetch("harness_metadata", {}) || {}
        {
          "command_id" => present_string(metadata.fetch("spawn_command_id", nil)),
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => agent.fetch("issue_id"),
            # The record itself, so recovery resumes this reservation instead of depending on a
            # spawn command id the original request may never have had.
            "_reservation_agent_id" => agent.fetch("id"),
            "_provision_reserved" => provision_reserved,
            "title" => metadata.fetch("title", nil),
            "prompt" => metadata.fetch("spawn_prompt", nil),
            "workspace_path" => metadata.fetch("requested_workspace_path", nil),
            "follow_up_of_agent_id" => metadata.fetch("follow_up_of_agent_id", nil),
            "replace_agent_id" => metadata.fetch("replace_agent_id", nil),
            "_self_fixing_recovery" => metadata.fetch("self_fixing_recovery", nil),
            "model" => metadata.dig("spawn_session_settings", "model"),
            "thinking_level" => metadata.dig("spawn_session_settings", "thinking_level"),
            "workspace_mode" => agent.fetch("workspace_mode", metadata.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED)),
            # An activation interrupted between its durable state flip and launch must not be
            # evaluated as a fresh deferral request.
            "after_agent_id" => present_string(agent.fetch("after_agent_id", nil)),
            "_activate_deferred" => deferred_spawn_metadata(agent).fetch("state", nil) == DEFERRED_STATE_ACTIVATING
          }.compact
        }
      end

      def record_worker_provisioning_executor_error(agent_id, error)
        reservation = synchronized_state do
          agent = find_agent(normalized_state, agent_id)
          next nil unless agent && !agent_has_session_reference?(agent)

          { "agent_id" => agent_id, "workspace" => workspace_from_reserved_agent(agent) }
        end
        return unless reservation

        fail_worker_reservation(
          reservation,
          command_id: nil,
          command_type: "SpawnWorker",
          message: "Worker #{agent_id} failed during background provisioning: #{error.message}",
          errors: [error.class.name, error.message],
          workspace: reservation.fetch("workspace")
        )
      end

      def recover_worker_reservations
        reservations = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "worker" && agent.fetch("status", nil) == "queued"
            next if agent_has_session_reference?(agent)
            next if owned_by_other_live_instance?(agent)
            # A worker queued behind another agent is not an interrupted provisioning attempt. It is
            # waiting on purpose, and only resolve_deferred_workers may start it.
            next if waiting_deferred_worker?(agent)
            next unless present_string((agent.fetch("harness_metadata", {}) || {}).fetch("spawn_prompt", nil))

            deep_copy(agent)
          end
        end
        if @async_worker_provisioning
          reservations.filter_map do |agent|
            next unless schedule_worker_provisioning(agent.fetch("id"))

            accepted_result(
              nil,
              "RecoverWorkerReservation",
              agent.fetch("id"),
              "Queued worker #{agent.fetch("id")} for background provisioning.",
              agent,
              []
            )
          end
        else
          reservations.map { |agent| apply(worker_reservation_command(agent)) }
        end
      end

      def recover_unapplied_head_results
        candidates = synchronized_state do
          normalized_state.fetch("agents").filter_map do |agent|
            next unless agent.fetch("type", nil) == "head"

            metadata = agent.fetch("harness_metadata", {}) || {}
            head_result = metadata.fetch("head_result", nil)
            next unless head_result.is_a?(Hash)
            next if present_string(metadata.fetch("head_result_applied_at", nil))
            next if owned_by_other_live_instance?(agent)
            next if head_takeover_claimed_by?(agent)
            next unless metadata.fetch("head_result_apply_state", nil) == "applying" ||
                        (agent.fetch("status", nil) == "completed" && agent_has_session_reference?(agent))
            # Another kernel instance is applying this batch right now; recovering it here would
            # apply every command a second time.
            next if head_result_apply_lease_held_elsewhere?(agent)

            { "head_id" => agent.fetch("id"), "head_result" => deep_copy(head_result) }
          end
        end

        candidates.map do |candidate|
          begin
            @head_result_mutex.synchronize do
              apply_head_result(
                nil,
                "ApplyHeadResult",
                "head_id" => candidate.fetch("head_id"),
                "head_result" => candidate.fetch("head_result"),
                "_recover" => true
              )
            end
          rescue StandardError => e
            synchronized_state do
              rejected_result(
                nil,
                "ApplyHeadResult",
                "Head result recovery for #{candidate.fetch("head_id")} was skipped: #{sanitized_error_message(e)}",
                [e.class.name, sanitized_error_message(e)]
              )
            end
          end
        end
      end
    end
  end
end
