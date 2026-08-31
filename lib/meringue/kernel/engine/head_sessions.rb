# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # A head's own session: claiming its result exactly once, handing it over to a successor, and
      # releasing or erroring it.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # Returns false when the head or its journal entry is gone, so the caller can
      # stop the batch instead of raising out of the whole apply/reconcile pass.
      def mark_head_command_started!(head_id, index)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          next false unless head

          metadata = head.fetch("harness_metadata", {}) || {}
          journal = Array(metadata.fetch("head_result_command_journal", []))
          entry = journal[index]
          next false unless entry

          now = timestamp
          entry["status"] = "running"
          entry["started_at"] = now
          # The claim identifies this instance so another live instance re-entering the same
          # batch skips a command that is already running here instead of applying it twice.
          entry.merge!(instance_ownership_metadata)
          metadata["head_result_command_journal"] = journal
          head["harness_metadata"] = metadata.merge(head_result_apply_lease(now))
          head["updated_at"] = now
          touch_state!(state)
          store.save(state)
          true
        end
      end

      def checkpoint_head_command_result!(head_id, index, result)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          next false unless head

          metadata = head.fetch("harness_metadata", {}) || {}
          journal = Array(metadata.fetch("head_result_command_journal", []))
          entry = journal[index]
          next false unless entry

          entry.merge!(
            "status" => result.fetch("status", "failed"),
            "target_id" => result.fetch("target_id", nil),
            "message" => result.fetch("message", nil),
            "result" => result.fetch("result", nil),
            "errors" => result.fetch("errors", []),
            "log_entry_ids" => result.fetch("log_entry_ids", []),
            "completed_at" => timestamp
          )
          metadata["head_result_command_journal"] = journal
          head["harness_metadata"] = metadata.merge(head_result_apply_lease(timestamp))
          head["updated_at"] = timestamp
          touch_state!(state)
          store.save(state)
          true
        end
      end

      # Identifies this kernel instance so a head command batch is applied exactly once even when
      # more than one Meringue process shares the same state file.
      def kernel_instance_id
        @kernel_instance_id ||= "#{kernel_host_name}:#{Process.pid}:#{object_id}"
      end

      def kernel_host_name
        @kernel_host_name ||= begin
          Socket.gethostname
        rescue StandardError
          "localhost"
        end
      end

      def head_result_apply_lease(now = timestamp)
        {
          "head_result_apply_owner" => kernel_instance_id,
          "head_result_apply_owner_host" => kernel_host_name,
          "head_result_apply_owner_pid" => Process.pid,
          "head_result_apply_heartbeat" => now
        }
      end

      def head_result_apply_lease_held_elsewhere?(head)
        metadata = head.is_a?(Hash) ? (head.fetch("harness_metadata", {}) || {}) : {}
        return false unless metadata.is_a?(Hash)

        owner = present_string(metadata.fetch("head_result_apply_owner", nil))
        return false unless owner
        return false if owner == kernel_instance_id
        return false if present_string(metadata.fetch("head_result_applied_at", nil))

        heartbeat = parse_time_or_nil(metadata.fetch("head_result_apply_heartbeat", nil))
        return false unless heartbeat
        return false if Time.now - heartbeat > HEAD_RESULT_APPLY_LEASE_SECONDS

        owner_host = present_string(metadata.fetch("head_result_apply_owner_host", nil))
        owner_pid = metadata.fetch("head_result_apply_owner_pid", nil).to_i
        return true unless owner_host == kernel_host_name && owner_pid.positive?

        owner_process_alive?(owner_pid)
      end

      def owner_process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue StandardError
        true
      end

      def command_result_from_journal(entry)
        {
          "command_id" => entry.fetch("command_id", nil),
          "command_type" => entry.fetch("command_type", nil),
          "status" => entry.fetch("status", nil),
          "target_id" => entry.fetch("target_id", nil),
          "message" => entry.fetch("message", nil),
          "result" => entry.fetch("result", nil),
          "errors" => entry.fetch("errors", []),
          "log_entry_ids" => entry.fetch("log_entry_ids", [])
        }
      end

      def terminal_command_status?(status)
        %w[accepted rejected failed].include?(status.to_s)
      end

      # Returns the pid of another live Meringue instance that is running this
      # command right now, or nil when the command is free to run here.
      def head_command_claim_owner(entry)
        return nil unless entry.is_a?(Hash)
        return nil unless entry.fetch("status", nil).to_s == "running"

        other_live_instance_pid(
          entry.fetch("owner_instance_id", nil),
          entry.fetch("owner_instance_pid", nil),
          entry.fetch("owner_instance_started_at", nil)
        )
      end

      def kernel_command_result?(value)
        value.is_a?(Hash) && value.key?("status") && value.key?("command_type")
      end

      # Terminal reconcile details for a polled head whose result the kernel rejected or failed.
      # Shaped like the other terminal models so the log-once/no-churn guards apply unchanged.
      def unapplied_head_result_reconcile_model(apply_result, now)
        {
          "state" => RECONCILE_STATE_TERMINAL_ERROR,
          "agent_type" => "head",
          "reason" => "head_result_not_applied",
          "last_error_at" => now,
          "error_message" => present_string(apply_result.fetch("message", nil)) || "Head result was not applied.",
          "apply_status" => apply_result.fetch("status", nil),
          "apply_errors" => Array(apply_result.fetch("errors", []))
        }.compact
      end

      def head_result_fully_applied?(apply_result)
        return false if head_result_apply_skipped?(apply_result)

        command_results = apply_result.dig("result", "command_results")
        Array(command_results).all? { |result| result.fetch("status", nil) == "accepted" }
      end

      # True when this instance deliberately did nothing because another kernel instance holds the
      # apply lease for the batch. The owner finishes the batch and owns the head bookkeeping.
      def head_result_apply_skipped?(apply_result)
        return false unless apply_result.is_a?(Hash)

        apply_result.dig("result", "skipped").to_s == "head_result_apply_in_progress"
      end

      # Head-proposed commands carry the proposing head id so the kernel can attribute the work
      # (`CreateIssue.originating_head_id`) and so commands like `Recount` can tell their own
      # proposer apart from an unrelated in-flight head.
      def command_with_default_id(command, head_id:, index:)
        return command unless command.is_a?(Hash)

        payload = value_at(command, "payload") || {}
        # `_head_id` marks every head-proposed command. CreateIssue uses it for attribution,
        # AnswerQuestion avoids spawning a redundant routing head, and commands such as Recount
        # and SetHarness use it to avoid treating the proposer as its own active-head blocker.
        enriched_command = if payload.is_a?(Hash)
                             command.merge("payload" => payload.merge("_head_id" => head_id.to_s))
                           else
                             command
                           end
        return enriched_command unless blank?(value_at(enriched_command, "command_id", "id"))

        enriched_command.merge("command_id" => "#{head_id}-C#{index + 1}")
      end

      def build_question(state:, head_id:, question_text:, context:, project_id:, issue_id:)
        now = timestamp
        question_id = next_question_id!(state)
        {
          "id" => question_id,
          "head_id" => head_id,
          "project_id" => project_id,
          "issue_id" => issue_id,
          "question" => question_text,
          "context" => context,
          # Head records are removed once their result is applied, so the message that triggered
          # the question is captured here while it is still recoverable. A later answer needs it
          # to route the blocked work.
          "original_user_message" => head_request_user_message(state, head_id),
          "status" => "open",
          "answer" => nil,
          "created_at" => now,
          "updated_at" => now
        }
      end

      def head_request_user_message(state, head_id)
        head = find_agent(state, head_id.to_s)
        return nil unless head && head.fetch("type", nil) == "head"

        metadata = head.fetch("harness_metadata", {}) || {}
        request = metadata.fetch("head_request", {}) || {}
        present_string(request.fetch("user_message", nil))
      end

      def update_issue_status_from_workers!(state, issue, now)
        # An issue that owns a live goal loop is not finished just because the workers it has
        # spawned so far are: the goal decides completion, and a `completed` issue between
        # iterations would also make the issue prunable mid-goal.
        active_goal = issue_has_active_goal?(state, issue.fetch("id", nil))
        workers = state.fetch("agents").select do |candidate|
          candidate.fetch("type", nil) == "worker" && candidate.fetch("issue_id", nil) == issue.fetch("id") &&
            candidate.fetch("status", nil) != "killed"
        end
        return if workers.empty?

        pending_continuation = workers.any? { |worker| pending_completion_continuation?(worker) }
        issue["status"] = if workers.all? { |worker| worker.fetch("status", nil) == "completed" }
                            active_goal || pending_continuation ? "working" : "completed"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "working" }
                            "working"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "errored" }
                            "errored"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "blocked" }
                            "blocked"
                          elsif workers.any? { |worker| worker.fetch("status", nil) == "paused" }
                            "idle"
                          else
                            issue.fetch("status", "idle")
                          end
        issue["updated_at"] = now
      end

      def update_project_status_from_issues!(state, project, now)
        issues = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == project.fetch("id") }
        return if issues.empty?

        project["status"] = if issues.all? { |issue| issue.fetch("status", nil) == "completed" }
                              "completed"
                            elsif issues.any? { |issue| issue.fetch("status", nil) == "working" }
                              "working"
                            elsif issues.any? { |issue| issue.fetch("status", nil) == "errored" }
                              "errored"
                            elsif issues.any? { |issue| issue.fetch("status", nil) == "blocked" }
                              "blocked"
                            elsif issues.all? { |issue| %w[idle paused].include?(issue.fetch("status", nil).to_s) }
                              "idle"
                            else
                              project.fetch("status", "idle")
                            end
        project["updated_at"] = now
      end

      # Records the harness session the head owns for its lifetime. Called for both the
      # polled/async head path and the synchronous head path so head session metadata is
      # inspectable and reconcilable the same way worker session metadata is.
      def record_head_session!(head_id, session_ref)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          raise "Head #{head_id} disappeared before its session could be recorded." unless head

          now = timestamp
          merge_session_ref_into_agent!(head, session_ref)
          head["status"] = "working"
          head["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "harness",
            source_id: head_id.to_s,
            level: "info",
            message: "Started agent session for head #{head_id}.",
            details: {
              "head_id" => head_id.to_s,
              "harness" => head.fetch("harness", nil),
              "pid" => head.fetch("pid", nil),
              "session_id" => head.fetch("harness_session_id", nil),
              "session_file" => head.fetch("harness_session_file", nil),
              "head_session_state" => (head.fetch("harness_metadata", {}) || {}).fetch("head_session_state", nil)
            }.compact
          )
          log_ids.concat(append_session_model_substitution_log(state, head))
          touch_state!(state, now)
          store.save(state)

          { "agent" => deep_copy(head), "log_entry_ids" => log_ids }
        end
      end

      def head_takeover_claimed_by?(agent, successor_id: nil)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        return false unless metadata.is_a?(Hash)
        return false unless metadata.fetch("head_takeover_state", nil).to_s == "claimed"

        successor_id.nil? || metadata.fetch("head_takeover_by_head_id", nil).to_s == successor_id.to_s
      end

      def complete_head_takeover!(previous_head_id, successor_head_id)
        synchronized_state do
          state = normalized_state
          previous = find_agent(state, previous_head_id)
          successor = find_agent(state, successor_head_id)
          unless previous && successor && head_takeover_claimed_by?(previous, successor_id: successor_head_id)
            return { "changed" => false, "reason" => "takeover_target_missing", "log_entry_ids" => [] }
          end

          now = timestamp
          session_release = release_head_session!(previous, reason: "head_taken_over", now: now)
          remove_agent_from_active_state!(state, previous_head_id)
          successor_metadata = successor.fetch("harness_metadata", {}) || {}
          successor["harness_metadata"] = successor_metadata.merge(
            "takeover_state" => "completed",
            "takeover_completed_at" => now,
            "takeover_previous_head_id" => previous_head_id
          )
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: successor_head_id,
            level: "info",
            message: "Head #{successor_head_id} took over the still-routing request from head #{previous_head_id}.",
            details: {
              "head_id" => successor_head_id,
              "takeover_of_head_id" => previous_head_id,
              "routing_action" => "head_takeover",
              "previous_head_removed_from_active_tree" => true,
              "previous_head_session_released" => session_release.fetch("changed", false),
              "previous_head_session_release_reason" => session_release.fetch("reason", nil)
            }.compact
          )
          touch_state!(state, now)
          store.save(state)
          {
            "changed" => true,
            "previous_head_id" => previous_head_id,
            "successor_head_id" => successor_head_id,
            "session_release" => session_release,
            "log_entry_ids" => log_ids
          }
        end
      end

      def rollback_head_takeover!(previous_head_id, successor_head_id, reason:)
        synchronized_state do
          state = normalized_state
          previous = find_agent(state, previous_head_id)
          next unless previous && head_takeover_claimed_by?(previous, successor_id: successor_head_id)

          now = timestamp
          metadata = previous.fetch("harness_metadata", {}) || {}
          metadata = metadata.dup
          metadata.delete("head_takeover_state")
          metadata.delete("head_takeover_by_head_id")
          metadata.delete("head_takeover_claimed_at")
          metadata["head_takeover_rollback_at"] = now
          metadata["head_takeover_rollback_reason"] = reason.to_s
          previous["harness_metadata"] = metadata
          previous["status"] = "completed" if metadata.fetch("head_result", nil).is_a?(Hash)
          previous["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: successor_head_id,
            level: "warning",
            message: "Head takeover by #{successor_head_id} did not start; head #{previous_head_id} remains available.",
            details: {
              "head_id" => successor_head_id,
              "takeover_of_head_id" => previous_head_id,
              "routing_action" => "head_takeover_rollback",
              "reason" => reason.to_s
            }
          )
          touch_state!(state, now)
          store.save(state)
          log_ids
        end
      rescue StandardError
        nil
      end

      def defer_head_result_for_takeover(command_id, command_type, state, head, head_result)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = metadata.dup
        if metadata.fetch("head_result_apply_state", nil).to_s == "takeover_pending" &&
           metadata.fetch("head_result", nil).is_a?(Hash)
          return accepted_result(
            command_id,
            command_type,
            head.fetch("id"),
            "Head #{head.fetch("id")} was taken over; its result will not be routed separately.",
            {
              "head_id" => head.fetch("id"),
              "skipped" => "head_taken_over",
              "takeover_head_id" => metadata.fetch("head_takeover_by_head_id")
            },
            []
          )
        end
        metadata["title"] = head_result.fetch("title")
        metadata["summary"] = head_result.fetch("summary")
        metadata["response"] = present_string(head_result.fetch("response", nil))
        metadata["head_result"] = deep_copy(head_result)
        metadata["head_result_fingerprint"] = head_result_fingerprint(head_result)
        metadata["head_result_apply_state"] = "takeover_pending"
        metadata["head_result_takeover_deferred_at"] ||= timestamp
        head["harness_metadata"] = metadata.compact
        head["status"] = "completed"
        head["updated_at"] = timestamp
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: head.fetch("id"),
          level: "info",
          message: "Deferred the result from head #{head.fetch("id")} because head #{metadata.fetch("head_takeover_by_head_id")} took over its request.",
          details: {
            "head_id" => head.fetch("id"),
            "takeover_head_id" => metadata.fetch("head_takeover_by_head_id"),
            "routing_action" => "head_takeover_defer_result"
          }
        )
        touch_state!(state)
        store.save(state)
        accepted_result(
          command_id,
          command_type,
          head.fetch("id"),
          "Head #{head.fetch("id")} was taken over; its result will not be routed separately.",
          {
            "head_id" => head.fetch("id"),
            "skipped" => "head_taken_over",
            "takeover_head_id" => metadata.fetch("head_takeover_by_head_id")
          },
          log_ids
        )
      end

      def mark_head_session_unavailable!(head_id, reason:)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return { "agent" => nil, "log_entry_ids" => [] } unless head

          now = timestamp
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "head_session_state" => HEAD_SESSION_STATE_UNAVAILABLE,
            "head_session_note" => reason
          )
          head["updated_at"] = now
          touch_state!(state, now)
          store.save(state)

          { "agent" => deep_copy(head), "log_entry_ids" => [] }
        end
      end

      def mark_head_session_active!(agent, now: timestamp)
        return unless agent.fetch("type", nil) == "head"
        return unless agent_has_session_reference?(agent)

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        reactivated = metadata.fetch("head_session_state", nil) == HEAD_SESSION_STATE_RELEASED
        updated = metadata.merge(
          "head_session_state" => HEAD_SESSION_STATE_ACTIVE,
          "head_session_started_at" => present_string(metadata.fetch("head_session_started_at", nil)) || now
        )
        if reactivated
          updated["head_session_restarted_at"] = now
          updated.delete("head_session_released_at")
          updated.delete("head_session_release_reason")
        end
        agent["harness_metadata"] = updated.compact
      end

      # Terminal teardown for a head session. Stops the harness session the head owned and
      # records why it ended so reconciliation never treats a dead head as resumable.
      def release_head_session!(agent, reason:, now: timestamp)
        return { "changed" => false, "reason" => "agent_is_not_head" } unless agent.fetch("type", nil) == "head"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        already_released = metadata.fetch("head_session_state", nil) == HEAD_SESSION_STATE_RELEASED
        killed_session = false
        if !already_released && present_string(agent.fetch("harness", nil))
          killed_session = close_head_session_safely(agent)
        end
        agent["harness_metadata"] = metadata.merge(
          "head_session_state" => HEAD_SESSION_STATE_RELEASED,
          "head_session_released_at" => present_string(metadata.fetch("head_session_released_at", nil)) || now,
          "head_session_release_reason" => present_string(metadata.fetch("head_session_release_reason", nil)) || reason,
          "is_streaming" => false
        ).compact

        {
          "changed" => !already_released,
          "killed_session" => killed_session,
          "reason" => reason
        }
      end

      def close_head_session_safely(agent)
        session_ref = session_ref_from_agent(agent)
        runner = active_head_runner(provider: agent.fetch("harness", nil))
        if runner.respond_to?(:close_head_session)
          return !!runner.close_head_session(session_ref)
        end

        kill_session_safely(session_ref, agent: agent)
        !!agent_has_session_reference?(agent)
      rescue StandardError
        false
      end

      def mark_head_errored(head_id, error, release_session: false)
        synchronized_state do
          state = normalized_state
          head = find_agent(state, head_id)
          return unless head

          now = timestamp
          error_info = error_payload(error)
          head["status"] = "errored"
          head["updated_at"] = now
          head["harness_metadata"] = (head.fetch("harness_metadata", {}) || {}).merge(
            "error_class" => error_info.fetch("class"),
            "error_message" => error_info.fetch("message")
          )
          released = release_session ? release_head_session!(head, reason: "head_errored", now: now) : nil
          append_log(
            state,
            source_type: "head",
            source_id: head_id,
            level: "error",
            message: "Head #{head_id} failed: #{error_info.fetch("message")}",
            details: { "class" => error_info.fetch("class") }.merge(released ? { "head_session_released" => true } : {})
          )
          touch_state!(state, now)
          store.save(state)
          release_session
        end
      rescue StandardError
        nil
      end

      def async_heads?
        @async_heads
      end

      def import_project!(state, bundle, project_path, payload, capability: {})
        expanded = File.expand_path(project_path.to_s)
        existing = state.fetch("projects").find do |project|
          project.is_a?(Hash) && project["root_path"] && File.expand_path(project["root_path"].to_s) == expanded
        end
        return existing if existing

        first_project = bundle.fetch("workers").first.fetch("project", {})
        now = timestamp
        project = {
          "id" => next_project_id!(state),
          "name" => project_display_name(value_at(payload, "project_name", "projectName")) ||
                    project_display_name(first_project["name"]) || default_project_name(expanded),
          "root_path" => expanded,
          # The same isolation evidence registration records, so an imported worker can be
          # given a workspace.
          "version_control_backend" => capability.fetch("backend", @version_control_backend.id),
          "version_control_repository_identity" => capability["repository_identity"],
          "version_control_capabilities" => capability.fetch("capabilities", {}),
          "version_control_diagnostics" => Array(capability["diagnostics"]),
          "version_control_diagnostic_at" => capability["diagnostic_at"],
          "status" => "working",
          "portable_import" => {
            "bundle_id" => bundle.fetch("bundle_id", nil),
            "source_project_id" => first_project["source_id"]
          }.compact,
          "created_at" => now,
          "updated_at" => now
        }
        state.fetch("projects") << project
        append_log(
          state,
          source_type: "kernel",
          source_id: project.fetch("id"),
          level: "info",
          message: "Created destination project #{project.fetch("id")} for imported workers: #{project.fetch("name")}",
          details: { "portable_bundle_id" => bundle.fetch("bundle_id", nil) }.compact
        )
        project
      end

      def import_issue!(state, project, bundle, entry)
        source_issue = entry.fetch("issue")
        source_issue_id = source_issue.fetch("source_id", "")
        existing = find_import_issue(state, project.fetch("id"), bundle, source_issue_id)
        return existing if existing

        now = timestamp
        issue = {
          "id" => next_issue_id!(state, project.fetch("id")),
          "project_id" => project.fetch("id"),
          "title" => source_issue.fetch("title", "Imported worker task").to_s.strip,
          "description" => source_issue.fetch("description", "").to_s,
          "status" => "queued",
          "agent_ids" => [],
          "portable_import" => {
            "bundle_id" => bundle.fetch("bundle_id", nil),
            "source_issue_id" => source_issue_id
          }.compact,
          "created_at" => now,
          "updated_at" => now
        }
        delivery = entry.fetch("delivery", {}) || {}
        State::Models.attach_pull_requests_to_issue!(
          issue,
          delivery_pull_requests: Array(delivery["pull_requests"]),
          candidate_urls: Array(delivery["candidate_urls"]),
          reported_urls: Array(delivery["reported_urls"])
        )
        state.fetch("issues") << issue
        project["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: issue.fetch("id"),
          level: "info",
          message: "Created destination issue #{issue.fetch("id")} from imported worker context: #{issue.fetch("title")}",
          details: {
            "project_id" => project.fetch("id"),
            "source_issue_id" => source_issue_id,
            "portable_bundle_id" => bundle.fetch("bundle_id", nil)
          }.compact
        )
        issue["_import_log_ids"] = log_ids
        issue
      end

      def find_import_issue(state, project_id, bundle, source_issue_id)
        state.fetch("issues").find do |issue|
          marker = issue.is_a?(Hash) ? issue["portable_import"] : nil
          marker.is_a?(Hash) && marker["bundle_id"].to_s == bundle.fetch("bundle_id", "").to_s &&
            marker["source_issue_id"].to_s == source_issue_id.to_s && issue["project_id"].to_s == project_id.to_s
        end
      end

      def imported_worker_for_bundle(bundle, source_worker_id)
        synchronized_state do
          state = normalized_state
          state.fetch("agents").find do |agent|
            next false unless agent.is_a?(Hash) && agent["type"].to_s == "worker"

            marker = (agent["harness_metadata"].is_a?(Hash) && agent["harness_metadata"]["portable_import"])
            marker.is_a?(Hash) && marker["bundle_id"].to_s == bundle.fetch("bundle_id", "").to_s &&
              marker["source_worker_id"].to_s == source_worker_id.to_s
          end
        end
      end

      def mark_imported_worker!(worker_id, marker, log_ids)
        synchronized_state do
          state = normalized_state
          worker = find_agent(state, worker_id)
          return unless worker

          now = timestamp
          metadata = worker.fetch("harness_metadata", {}) || {}
          worker["harness_metadata"] = metadata.merge("portable_import" => marker).compact
          worker["updated_at"] = now
          log_ids.concat(append_log(
            state,
            source_type: "worker",
            source_id: worker.fetch("id"),
            level: "warning",
            message: "Worker #{worker.fetch("id")} imported as a fresh session; the source harness session cannot be resumed directly.",
            details: {
              "portable_bundle_id" => marker.fetch("bundle_id", nil),
              "source_worker_id" => marker.fetch("source_worker_id", nil),
              "session_resume_available" => false,
              "session_resume_reason" => marker.fetch("session_resume_reason", Workers::Bundle::PORTABLE_SESSION_REASON)
            }.compact
          ))
          touch_state!(state, now)
          store.save(state)
        end
      end
    end
  end
end
