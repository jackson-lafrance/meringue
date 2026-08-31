# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # PromptAgent: choosing a delivery mode, taking over a routing head, and the durable receipts
      # that keep an ambiguous or transient delivery from being sent twice.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # `/prompt <id>` continues a worker session. When the id is an active head, it starts a
      # replacement head with the original request and compact routing context in hand. A stopped
      # head remains on the explicit `/retry H<n>` path so retry and takeover cannot be confused.
      def prompt_agent_command(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        agent = present_string(agent_id) ? agent_record_snapshot(agent_id.to_s) : nil
        if agent && agent.fetch("type", nil) == "head"
          prompt = value_at(payload, "prompt", "Prompt", "message", "Message")
          return takeover_head_command(command_id, command_type, agent, prompt) if head_still_routing?(agent)

          return synchronized_state do
            rejected_result(
              command_id,
              command_type,
              "Agent #{agent.fetch("id")} is a head. Use /retry #{agent.fetch("id")} to retry a stopped head; /prompt only takes over a head that is still routing.",
              ["agent_is_not_worker", "use_retry_head"]
            )
          end
        end

        prompt = value_at(payload, "prompt", "Prompt", "message", "Message")
        # Continuing a worker whose session the provider refuses to replay cannot be a prompt: the
        # resume would send the same rejected transcript. It is the same intent though, so it is
        # honoured as a fresh session on the worker's own worktree instead of a dead end.
        if agent && worker_session_unreplayable?(agent) && present_string(prompt)
          return continue_unreplayable_worker_session(command_id, command_type, agent, prompt.to_s)
        end

        synchronized_state { prompt_agent(command_id, command_type, payload) }
      end

      # `/prompt` (or a head's PromptAgent) aimed at a worker whose session cannot be replayed. The
      # instruction is carried into a fresh session on the same worktree and branch. When the
      # restart was already spent, the reply names the successor that holds the work.
      def takeover_head_command(command_id, command_type, head, prompt)
        return synchronized_state do
          rejected_result(command_id, command_type, "Head #{head.fetch("id")} cannot be taken over without a replacement prompt.", ["prompt is required"])
        end if blank?(prompt)

        result = spawn_head(
          command_id,
          command_type,
          "user_message" => prompt.to_s,
          "log_message" => prompt.to_s,
          "_log_source_type" => "user",
          "_takeover_of_head_id" => head.fetch("id")
        )
        return result unless result.fetch("status", nil) == "accepted"

        result.merge(
          "message" => "Took over head #{head.fetch("id")} as head #{result.fetch("target_id")}."
        )
      end

      def continue_unreplayable_worker_session(command_id, command_type, agent, instruction)
        restart = restart_unreplayable_worker_session(agent.fetch("id"), trigger: "prompt", instruction: instruction)
        if restart.fetch("claimed", false) && restart.fetch("restarted", false)
          successor = agent_record_snapshot(restart.fetch("successor_agent_id"))
          return accepted_result(
            command_id,
            command_type,
            restart.fetch("successor_agent_id"),
            restart.fetch("message"),
            successor || restart.fetch("result", nil),
            restart.fetch("log_entry_ids", [])
          )
        end

        synchronized_state do
          rejected_result(command_id, command_type, unreplayable_prompt_rejection_message(agent, restart), ["session_unreplayable"])
        end
      end

      def unreplayable_prompt_rejection_message(agent, restart)
        current = agent_record_snapshot(agent.fetch("id")) || agent
        recovery = worker_session_recovery(current)
        successor_id = present_string(current.fetch("replaced_by_agent_id", nil)) ||
                       present_string(recovery.fetch("restarted_by_agent_id", nil))
        base = "Agent #{agent.fetch("id")} cannot be continued because its agent session can no longer be " \
               "replayed to the model."
        if successor_id
          return "#{base} Worker #{successor_id} already took over its workspace, so prompt #{successor_id} instead."
        end
        if restart.is_a?(Hash) && restart.fetch("claimed", false)
          return "#{base} Restarting it in a fresh session failed: #{result_failure_summary(restart.fetch("result", nil))}. " \
                 "#{unreplayable_session_recovery_advice(current)}"
        end

        "#{base} #{unreplayable_session_recovery_advice(current)} Meringue has already used its automatic " \
          "restart for this worker, so spawn a worker on this issue (or continue in the worktree yourself) " \
          "instead of prompting this record."
      end

      def prompt_agent(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "AgentID", "agentId")
        # `message`/`Message` are accepted because `prompt_agent_command` already routes
        # head takeovers and unreplayable-session continuations off those aliases. Reading a
        # narrower set here rejected the identical payload as "prompt is required" depending
        # only on which branch the target agent happened to take.
        prompt = value_at(payload, "prompt", "Prompt", "message", "Message")
        mode = (value_at(payload, "mode", "Mode") || "normal").to_s
        errors = []

        errors << "agent_id is required" if blank?(agent_id)
        errors << "prompt is required" if blank?(prompt)
        errors << "mode must be one of #{PROMPT_MODES.join(", ")}" unless PROMPT_MODES.include?(mode)
        return rejected_result(command_id, command_type, "Agent was not prompted.", errors) unless errors.empty?

        state = normalized_state
        agent = find_agent(state, agent_id)
        unless agent
          return rejected_result(
            command_id,
            command_type,
            with_dropped_intent(missing_agent_prompt_message(agent_id, state), "type" => "PromptAgent", "payload" => payload),
            ["agent_not_found"]
          )
        end
        # Head takeovers are handled by `prompt_agent_command`, before this worker-only
        # implementation is reached. Keep the defensive rejection for callers that bypass the
        # command router or invoke the private method directly.
        if agent.fetch("type", nil) == "head"
          return rejected_result(
            command_id,
            command_type,
            "Agent #{agent_id} is a head. Use /prompt #{agent.fetch("id")} to take over an active head or /retry it after it stops.",
            ["agent_is_not_worker", "head_takeover_requires_command_router"]
          )
        end
        return rejected_result(command_id, command_type, "Agent #{agent_id} is not a worker.", ["agent_is_not_worker"]) unless agent.fetch("type", nil) == "worker"
        metadata = agent.fetch("harness_metadata", {}) || {}
        resume_prompt = truthy?(value_at(payload, "_resume_worker", "resume_worker"))
        pending_prompt_id = present_string(value_at(payload, "_pending_prompt_id", "pending_prompt_id"))
        if agent.fetch("status", nil) == "killed"
          return rejected_result(command_id, command_type, "Agent #{agent_id} is killed.", ["agent_killed"])
        end
        if worker_prune_cleanup_claimed?(agent)
          return rejected_result(
            command_id,
            command_type,
            "Agent #{agent_id} is being safely pruned; its workspace cannot be resumed during cleanup.",
            ["agent_prune_in_progress"]
          )
        end
        if agent_focus_ownership_active?(agent)
          return rejected_result(command_id, command_type, "Agent #{agent_id} has no agent session.", ["missing_harness_session"]) unless agent_has_session_reference?(agent)

          return queue_transient_prompt(
            command_id: command_id,
            command_type: command_type,
            agent_id: agent.fetch("id"),
            prompt: prompt.to_s,
            mode: mode,
            pending_prompt_id: pending_prompt_id,
            error: StandardError.new("the focused Agent session owns prompt delivery"),
            queue_message: "Queued the #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} until its focused Agent session returns."
          )
        end
        if agent.fetch("status", nil) == "paused" && !resume_prompt
          return rejected_result(command_id, command_type, "Worker #{agent_id} is paused. Resume it before sending another prompt.", ["worker_paused"])
        end
        if metadata.fetch("pause_request", nil).is_a?(Hash) && !resume_prompt
          return rejected_result(command_id, command_type, "Worker #{agent_id} is being paused; wait for the pause to finish before prompting it.", ["worker_pause_in_progress"])
        end
        if metadata.fetch("interactive_handoff", nil).is_a?(Hash)
          metadata = metadata.dup
          metadata.delete("interactive_handoff")
          agent["harness_metadata"] = metadata
          touch_state!(state)
          store.save(state)
        end
        delivered_prompt_ids = Array(metadata.fetch("prompt_command_ids", [])).map(&:to_s)
        if present_string(command_id) && delivered_prompt_ids.include?(command_id.to_s)
          return accepted_result(
            command_id,
            command_type,
            agent.fetch("id"),
            "Prompt for worker #{agent.fetch("id")} was already delivered.",
            deep_copy(agent),
            []
          )
        end
        # A later command in the same head batch can target a worker immediately after SpawnWorker.
        # Its harness does not exist yet now that provisioning is asynchronous, so durably fold the
        # instruction into the first turn instead of rejecting it or racing session startup.
        if worker_provisioning_in_progress?(agent) && !agent_has_session_reference?(agent)
          now = timestamp
          initial_prompt = metadata.fetch("spawn_prompt", "").to_s
          combined_prompt = [initial_prompt, "--- Additional instruction before launch ---", prompt.to_s].reject(&:empty?).join("\n\n")
          agent["updated_at"] = now
          agent["harness_metadata"] = metadata.merge(
            "spawn_prompt" => combined_prompt,
            "prompt_command_ids" => (delivered_prompt_ids + [present_string(command_id)]).compact.last(PROMPT_COMMAND_ID_HISTORY_LIMIT)
          )
          message = "Added the prompt to worker #{agent.fetch("id")}'s pending launch."
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent.fetch("id"),
            level: "info",
            message: message,
            details: { "agent_id" => agent.fetch("id"), "mode" => mode, "delivery" => "initial_turn" }
          )
          touch_state!(state, now)
          store.save(state)
          return accepted_result(command_id, command_type, agent.fetch("id"), message, deep_copy(agent), log_ids)
        end
        # A worker whose workspace provisioning failed has no session to prompt, but it is not
        # dead either: prompting it is how the user retries provisioning with a fresh instruction,
        # instead of losing the reservation and having to recreate the worker by hand.
        if worker_awaiting_provisioning_retry?(agent)
          return requeue_worker_provisioning(state, command_id, command_type, agent, prompt.to_s)
        end
        # An errored worker is normally not resumable, but a worker whose turn was cut short by a
        # transport failure still owns its session, worktree, and branch: prompting it is how the
        # user recovers the work instead of losing it.
        if %w[killed errored].include?(agent.fetch("status", nil)) && !worker_resumable_after_settle_failure?(agent)
          return rejected_result(command_id, command_type, "Agent #{agent_id} cannot be continued because it is #{agent.fetch("status")}.", ["agent_not_resumable"])
        end
        if blank?(agent.fetch("pid", nil)) && blank?(agent.fetch("harness_session_id", nil)) && blank?(agent.fetch("harness_session_file", nil))
          return rejected_result(command_id, command_type, "Agent #{agent_id} has no agent session.", ["missing_harness_session"])
        end

        if pending_prompt_id
          pending_prompts = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
          unless pending_prompts.any? { |entry| entry.fetch("id", nil).to_s == pending_prompt_id }
            return accepted_result(
              command_id,
              command_type,
              agent.fetch("id"),
              "Prompt for worker #{agent.fetch("id")} was already delivered.",
              deep_copy(agent),
              []
            )
          end
        end
        client = harness_client_for_agent(agent)
        retrying_ambiguous_delivery = false
        receipt_entry = ambiguous_prompt_receipt_entry(
          metadata,
          command_id: command_id,
          pending_prompt_id: pending_prompt_id,
          prompt: prompt.to_s,
          mode: mode
        )
        if receipt_entry && client.respond_to?(:prompt_delivery_receipts_supported?) && client.prompt_delivery_receipts_supported?
          receipt = client.prompt_delivery_status(
            agent_session_ref(agent),
            delivery_id: receipt_entry.fetch("delivery_id"),
            prompt: prompt.to_s,
            started_at: receipt_entry.fetch("delivery_started_at", nil)
          )
          case receipt.fetch("status", "unknown")
          when "delivered"
            return confirm_ambiguous_prompt_delivery(
              state: state,
              command_id: command_id,
              command_type: command_type,
              agent: agent,
              mode: mode,
              pending_prompt_id: pending_prompt_id,
              receipt: receipt
            )
          when "pending", "unknown"
            if receipt_entry.fetch("source", nil) == "pending_prompt"
              return ambiguous_prompt_wait_result(
                command_id: command_id,
                command_type: command_type,
                agent: agent,
                mode: mode,
                pending_prompt_id: pending_prompt_id,
                receipt: receipt
              )
            end

            return queue_ambiguous_prompt(
              command_id: command_id,
              command_type: command_type,
              agent_id: agent.fetch("id"),
              prompt: prompt.to_s,
              mode: mode,
              pending_prompt_id: pending_prompt_id,
              delivery_id: receipt_entry.fetch("delivery_id"),
              delivery_started_at: receipt_entry.fetch("delivery_started_at", nil),
              error: StandardError.new(receipt.fetch("error", nil) || "Prompt receipt is not available yet")
            )
          when "not_delivered"
            retrying_ambiguous_delivery = true
          end
        end

        if !retrying_ambiguous_delivery && Array(metadata.fetch("pending_prompts", [])).any? { |entry|
          entry.is_a?(Hash) && entry.fetch("delivery_state", nil) == "awaiting_receipt"
        }
          return queue_transient_prompt(
            command_id: command_id,
            command_type: command_type,
            agent_id: agent.fetch("id"),
            prompt: prompt.to_s,
            mode: mode,
            pending_prompt_id: pending_prompt_id,
            error: StandardError.new("an earlier agent prompt is still awaiting its durable delivery receipt")
          )
        end

        supervisor_recovery = metadata.fetch("supervisor_recovery", nil)
        if supervisor_recovery.is_a?(Hash) && supervisor_recovery.fetch("state", nil) == "claimed"
          return queue_transient_prompt(
            command_id: command_id,
            command_type: command_type,
            agent_id: agent.fetch("id"),
            prompt: prompt.to_s,
            mode: mode,
            pending_prompt_id: pending_prompt_id,
            error: StandardError.new("Meringue is recovering this worker after its session supervisor exited")
          )
        end

        claim = metadata.fetch("prompt_delivery_claim", nil)
        if claim.is_a?(Hash) && other_live_instance_pid(
          claim.fetch("owner_instance_id", nil),
          claim.fetch("owner_instance_pid", nil),
          claim.fetch("owner_instance_started_at", nil)
        )
          return queue_transient_prompt(
            command_id: command_id,
            command_type: command_type,
            agent_id: agent.fetch("id"),
            prompt: prompt.to_s,
            mode: mode,
            pending_prompt_id: pending_prompt_id,
            error: StandardError.new("another Meringue instance is delivering a prompt to this worker")
          )
        end

        claim_token = SecureRandom.hex(8)
        delivery_id = prompt_delivery_id(command_id, claim_token)
        metadata = metadata.merge(
          "prompt_delivery_claim" => {
            "token" => claim_token,
            "command_id" => present_string(command_id),
            "prompt" => prompt.to_s,
            "mode" => mode,
            "delivery_id" => delivery_id,
            "claimed_at" => timestamp,
            **instance_ownership_metadata
          }.compact
        )
        agent["harness_metadata"] = metadata
        touch_state!(state)
        store.save(state)

        session_ref = agent_session_ref(agent)
        begin
          prompt_options = { mode: mode }
          if client.respond_to?(:prompt_delivery_receipts_supported?) && client.prompt_delivery_receipts_supported?
            prompt_options[:delivery_id] = delivery_id
          end
          session_ref = client.prompt_session(session_ref, prompt.to_s, **prompt_options)
        rescue StandardError => e
          # A timeout after a receipt-capable harness accepted a prompt is not proof that delivery
          # failed. Keep the deterministic receipt pending until the harness can classify it or the
          # process exits without it; retrying while the original process lives can duplicate work.
          if client.respond_to?(:ambiguous_prompt_delivery_error?) && client.ambiguous_prompt_delivery_error?(e)
            return queue_ambiguous_prompt(
              command_id: command_id,
              command_type: command_type,
              agent_id: agent.fetch("id"),
              prompt: prompt.to_s,
              mode: mode,
              pending_prompt_id: pending_prompt_id,
              delivery_id: delivery_id,
              delivery_started_at: metadata.dig("prompt_delivery_claim", "claimed_at"),
              error: e
            )
          end

          # A session that is busy elsewhere is a timing condition, not a failure: queue the
          # prompt and let reconciliation deliver it once the current turn settles.
          if Harness.transient_session_error?(e)
            clear_prompt_delivery_claim!(agent, claim_token)
            touch_state!(state)
            store.save(state)
            return queue_transient_prompt(
              command_id: command_id,
              command_type: command_type,
              agent_id: agent.fetch("id"),
              prompt: prompt.to_s,
              mode: mode,
              pending_prompt_id: pending_prompt_id,
              error: e
            )
          end

          clear_prompt_delivery_claim!(agent, claim_token)
          touch_state!(state)
          store.save(state)
          return failed_result(
            command_id,
            command_type,
            "Could not prompt agent #{agent_id}: #{e.message}",
            [e.class.name, e.message]
          )
        end

        now = timestamp
        session_metadata = session_ref.fetch("metadata", {}) || {}
        previous_metadata = agent.fetch("harness_metadata", {}) || {}
        delivered_prompt_ids = Array(previous_metadata.fetch("prompt_command_ids", [])).map(&:to_s)
        if present_string(command_id)
          delivered_prompt_ids = (delivered_prompt_ids + [command_id.to_s]).uniq.last(PROMPT_COMMAND_ID_HISTORY_LIMIT)
        end
        # The harness may have had to deliver the prompt in a different mode than the caller asked
        # for (a normal prompt into a mid-turn session is queued as a follow-up instead of being
        # dropped). Record and log what actually happened, not what was requested.
        delivered_mode = delivered_prompt_mode(session_metadata, mode)
        coerced = delivered_mode != mode
        mode_note = coerced ? present_string(session_metadata.fetch("prompt_mode_note", nil)) : nil
        agent["status"] = "working"
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["session_settings"] = deep_copy(session_ref.fetch("session_settings")) if session_ref.fetch("session_settings", nil).is_a?(Hash)
        agent["session_stats"] = deep_copy(session_ref.fetch("session_stats")) if session_ref.fetch("session_stats", nil).is_a?(Hash)
        agent["harness_metadata"] = previous_metadata.merge(
          session_metadata,
          "prompt_count" => previous_metadata.fetch("prompt_count", 0).to_i + 1,
          "last_prompt_mode" => delivered_mode,
          "requested_prompt_mode" => coerced ? mode : nil,
          "delivered_prompt_mode" => coerced ? delivered_mode : nil,
          "prompt_mode_note" => mode_note,
          "last_prompted_at" => now,
          "is_streaming" => session_ref.fetch("is_streaming", false),
          "last_event_at" => session_ref.fetch("last_event_at", nil),
          "routing_action" => prompt_routing_action(delivered_mode),
          "prompt_command_ids" => present_string(command_id) ? delivered_prompt_ids : nil,
          "prompt_delivery_claim" => nil
        ).compact
        # The prompt landed, so a recorded dead-turn reason is history. Cleared after the merge
        # because the session ref carries the agent's own metadata back in.
        clear_settle_failure!(agent)
        clear_incomplete_turn!(agent)
        # A delivered prompt is activity. Restarting the clock here also clears any standing quiet
        # warning, so a worker the user just poked is not still labelled quiet from before.
        record_worker_activity!(agent, now)
        agent["updated_at"] = now

        issue = find_issue(state, agent.fetch("issue_id", nil))
        project = issue && find_project(state, issue.fetch("project_id", nil))
        if issue
          issue["status"] = "working"
          issue["last_agent_id"] = agent.fetch("id")
          issue["last_routing_action"] = prompt_routing_action(delivered_mode)
          issue["last_routed_at"] = now
          issue["updated_at"] = now
        end
        if project
          project["status"] = "working"
          project["updated_at"] = now
        end

        # The harness accepted the prompt, so the delivery is logged exactly once, here.
        remove_pending_prompts!(agent, pending_prompt_id: pending_prompt_id, command_id: command_id)
        delivery_message = if resume_prompt
                             "Resumed worker #{agent.fetch("id")} using its existing session."
                           else
                             prompt_log_message(agent, delivered_mode, requested_mode: coerced ? mode : nil, note: mode_note)
                           end
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: delivery_message,
          details: {
            "issue_id" => agent.fetch("issue_id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "agent_id" => agent.fetch("id"),
            "mode" => delivered_mode,
            "requested_mode" => mode,
            "prompt_mode_note" => mode_note,
            "routing_action" => resume_prompt ? "resume_session" : prompt_routing_action(delivered_mode),
            "resume" => resume_prompt,
            "is_streaming" => session_ref.fetch("is_streaming", false)
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, agent.fetch("id"), delivery_message, agent, log_ids)
      end

      # A head id that no longer resolves is the common case after a kill or a prune, and the
      # generic "does not exist" line leaves the user guessing why their retry target vanished.
      def missing_agent_prompt_message(agent_id, state = nil)
        id = agent_id.to_s
        if id.match?(/\AH\d+\z/i)
          return "Head #{id.upcase} no longer exists. Heads are removed when they are killed, cleaned up " \
                 "after routing, or pruned, so send your message as a new prompt instead."
        end

        # A worker id that stopped resolving is usually a record a prune or kill removed, and the
        # kernel knows which, so it says so instead of leaving the user to guess.
        removal = state && removed_agent_record(state, id)
        return "Agent #{id} does not exist." unless removal

        "Agent #{id} no longer exists: it was removed #{issue_removal_phrase(removal)}."
      end

      # Harness clients report a mode they had to substitute through generic session metadata; an
      # unknown or absent value means the requested mode was used as-is.
      def delivered_prompt_mode(session_metadata, requested_mode)
        reported = present_string(session_metadata.fetch("delivered_prompt_mode", nil))
        return requested_mode.to_s unless reported && PROMPT_MODES.include?(reported)

        reported
      end

      def prompt_delivery_id(command_id, fallback_token)
        "meringue:#{present_string(command_id) || fallback_token}"
      end

      def ambiguous_prompt_receipt_entry(metadata, command_id:, pending_prompt_id:, prompt:, mode:)
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        entry = pending.find do |candidate|
          next false unless candidate.fetch("delivery_state", nil) == "awaiting_receipt"

          (pending_prompt_id && candidate.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && candidate.fetch("command_id", nil).to_s == command_id.to_s)
        end
        return entry.merge("source" => "pending_prompt") if entry && present_string(entry.fetch("delivery_id", nil))

        claim = metadata.fetch("prompt_delivery_claim", nil)
        return nil unless claim.is_a?(Hash) && present_string(claim.fetch("delivery_id", nil))
        return nil if present_string(command_id) && claim.fetch("command_id", nil).to_s != command_id.to_s
        return nil unless claim.fetch("prompt", nil).to_s == prompt.to_s && claim.fetch("mode", nil).to_s == mode.to_s

        {
          "source" => "delivery_claim",
          "delivery_id" => claim.fetch("delivery_id"),
          "delivery_started_at" => claim.fetch("claimed_at", nil)
        }
      end

      def ambiguous_prompt_wait_result(command_id:, command_type:, agent:, mode:, pending_prompt_id:, receipt:)
        accepted_result(
          command_id,
          command_type,
          agent.fetch("id"),
          "Waiting for the agent harness to confirm the timed-out #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")}; it will not be sent twice.",
          {
            "agent_id" => agent.fetch("id"),
            "queued" => true,
            "awaiting_receipt" => true,
            "pending_prompt_id" => pending_prompt_id,
            "receipt_status" => receipt.fetch("status", "unknown")
          }.compact,
          []
        )
      end

      # Persist an ambiguous transport outcome before releasing the delivery claim. Reconciliation
      # checks the receipt through PromptAgent, but does not poll or resume the worker itself until
      # it settles; doing either could duplicate a continuation in the original request.
      def queue_ambiguous_prompt(command_id:, command_type:, agent_id:, prompt:, mode:, pending_prompt_id:,
                                 delivery_id:, delivery_started_at:, error:)
        state = normalized_state
        agent = find_agent(state, agent_id)
        return failed_result(command_id, command_type, "Agent #{agent_id} disappeared before its prompt receipt could be tracked.", ["agent_not_found"]) unless agent

        now = timestamp
        metadata = agent.fetch("harness_metadata", {}) || {}
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        existing = pending.find do |entry|
          (pending_prompt_id && entry.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && entry.fetch("command_id", nil).to_s == command_id.to_s) ||
            entry.fetch("delivery_id", nil).to_s == delivery_id.to_s
        end
        entry = existing || {
          "id" => next_pending_prompt_id(agent, pending),
          "command_id" => present_string(command_id),
          "prompt" => prompt,
          "mode" => mode.to_s,
          "queued_at" => now
        }.compact
        entry.merge!(
          "delivery_state" => "awaiting_receipt",
          "delivery_id" => delivery_id,
          "delivery_started_at" => delivery_started_at || now,
          "last_attempted_at" => now,
          "last_error" => error.message,
          "last_error_class" => error.class.name
        )
        if error.respond_to?(:command_type) && %w[prompt steer follow_up].include?(error.command_type)
          entry["delivered_mode"] = error.command_type == "prompt" ? "normal" : error.command_type
        end
        pending << entry unless existing
        metadata["pending_prompts"] = pending
        metadata["prompt_delivery_claim"] = nil
        metadata["last_ambiguous_prompt_delivery"] = {
          "delivery_id" => delivery_id,
          "pending_prompt_id" => entry.fetch("id"),
          "timed_out_at" => now,
          "error" => error.message
        }
        agent["harness_metadata"] = metadata
        agent["updated_at"] = now

        log_ids = if existing
                    []
                  else
                    append_log(
                      state,
                      source_type: "kernel",
                      source_id: agent.fetch("id"),
                      level: "warning",
                      message: "The agent harness timed out while delivering the #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")}; waiting for its durable session receipt instead of retrying it.",
                      details: {
                        "agent_id" => agent.fetch("id"),
                        "issue_id" => agent.fetch("issue_id", nil),
                        "mode" => mode.to_s,
                        "pending_prompt_id" => entry.fetch("id"),
                        "delivery_id" => delivery_id,
                        "error_class" => error.class.name,
                        "error" => error.message
                      }.compact
                    )
                  end
        touch_state!(state, now)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          agent.fetch("id"),
          "Tracking the timed-out #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} until the agent harness confirms whether it landed.",
          {
            "agent_id" => agent.fetch("id"),
            "queued" => true,
            "awaiting_receipt" => true,
            "pending_prompt_id" => entry.fetch("id"),
            "delivery_id" => delivery_id
          },
          log_ids
        )
      end

      def confirm_ambiguous_prompt_delivery(state:, command_id:, command_type:, agent:, mode:, pending_prompt_id:, receipt:)
        now = receipt.fetch("delivered_at", nil) || timestamp
        metadata = agent.fetch("harness_metadata", {}) || {}
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        receipt_entry = pending.find do |entry|
          (pending_prompt_id && entry.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && entry.fetch("command_id", nil).to_s == command_id.to_s)
        end
        delivered_mode = receipt_entry&.fetch("delivered_mode", nil) || mode
        delivered_ids = Array(metadata.fetch("prompt_command_ids", [])).map(&:to_s)
        delivered_ids = (delivered_ids + [command_id.to_s]).uniq.last(PROMPT_COMMAND_ID_HISTORY_LIMIT) if present_string(command_id)
        metadata = metadata.merge(
          "prompt_count" => metadata.fetch("prompt_count", 0).to_i + 1,
          "last_prompt_mode" => delivered_mode,
          "requested_prompt_mode" => delivered_mode != mode ? mode : nil,
          "delivered_prompt_mode" => delivered_mode != mode ? delivered_mode : nil,
          "last_prompted_at" => now,
          "routing_action" => prompt_routing_action(delivered_mode),
          "prompt_command_ids" => present_string(command_id) ? delivered_ids : nil,
          "prompt_delivery_claim" => nil,
          "last_prompt_delivery_receipt" => receipt.merge("confirmed_at" => timestamp)
        ).compact
        agent["harness_metadata"] = metadata
        agent["pid"] = receipt.fetch("pid") if receipt.fetch("pid", nil)
        agent["status"] = "working"
        agent["updated_at"] = timestamp
        clear_settle_failure!(agent)
        clear_incomplete_turn!(agent)
        record_worker_activity!(agent, timestamp)
        remove_pending_prompts!(agent, pending_prompt_id: pending_prompt_id, command_id: command_id)

        issue = find_issue(state, agent.fetch("issue_id", nil))
        project = issue && find_project(state, issue.fetch("project_id", nil))
        if issue
          issue["status"] = "working"
          issue["last_agent_id"] = agent.fetch("id")
          issue["last_routing_action"] = prompt_routing_action(delivered_mode)
          issue["last_routed_at"] = timestamp
          issue["updated_at"] = timestamp
        end
        if project
          project["status"] = "working"
          project["updated_at"] = timestamp
        end

        message = prompt_log_message(agent, delivered_mode, requested_mode: delivered_mode != mode ? mode : nil)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: message,
          details: {
            "agent_id" => agent.fetch("id"),
            "issue_id" => agent.fetch("issue_id", nil),
            "mode" => delivered_mode,
            "requested_mode" => mode,
            "delivery_confirmation" => "harness_session_receipt",
            "delivery_id" => receipt_entry&.fetch("delivery_id", nil),
            "delivered_at" => receipt.fetch("delivered_at", nil)
          }.compact
        )
        touch_state!(state)
        store.save(state)
        accepted_result(command_id, command_type, agent.fetch("id"), message, agent, log_ids)
      end

      # A session that is momentarily owned by another instance mid-turn is not a command failure.
      # The prompt is stored on the agent and redelivered by reconciliation until it lands.
      def queue_transient_prompt(command_id:, command_type:, agent_id:, prompt:, mode:, pending_prompt_id:, error:, queue_message: nil)
        state = normalized_state
        agent = find_agent(state, agent_id)
        return failed_result(command_id, command_type, "Agent #{agent_id} disappeared before its prompt could be queued.", ["agent_not_found"]) unless agent

        now = timestamp
        metadata = agent.fetch("harness_metadata", {}) || {}
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        existing = pending.find do |entry|
          (pending_prompt_id && entry.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && entry.fetch("command_id", nil).to_s == command_id.to_s) ||
            (entry.fetch("prompt", nil).to_s == prompt && entry.fetch("mode", nil).to_s == mode.to_s)
        end

        attempts = existing ? existing.fetch("attempts", 0).to_i + 1 : 1
        if attempts > PENDING_PROMPT_MAX_ATTEMPTS
          pending.delete(existing)
          metadata["pending_prompts"] = pending
          agent["harness_metadata"] = metadata
          agent["updated_at"] = now
          log_ids = append_log(
            state,
            source_type: "kernel",
            source_id: agent.fetch("id"),
            level: "warning",
            message: "Gave up the queued #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} after #{PENDING_PROMPT_MAX_ATTEMPTS} attempts: #{error.message}",
            details: { "agent_id" => agent.fetch("id"), "mode" => mode, "attempts" => attempts }
          )
          touch_state!(state, now)
          store.save(state)
          return rejected_result(command_id, command_type, "Worker #{agent.fetch("id")} could not accept the prompt: #{error.message}", ["session_busy"])
        end

        entry = existing || {
          "id" => next_pending_prompt_id(agent, pending),
          "command_id" => present_string(command_id),
          "prompt" => prompt,
          "mode" => mode.to_s,
          "queued_at" => now
        }.compact
        entry["attempts"] = attempts
        entry["last_attempted_at"] = now
        entry["last_error"] = error.message
        pending << entry unless existing
        metadata["pending_prompts"] = pending
        agent["harness_metadata"] = metadata
        agent["updated_at"] = now

        message = queue_message || "Queued the #{prompt_delivery_noun(mode)} for worker #{agent.fetch("id")} until its current turn settles."
        log_ids = if existing
                    []
                  else
                    append_log(
                      state,
                      source_type: "kernel",
                      source_id: agent.fetch("id"),
                      level: "info",
                      message: message,
                      details: {
                        "agent_id" => agent.fetch("id"),
                        "issue_id" => agent.fetch("issue_id", nil),
                        "mode" => mode.to_s,
                        "pending_prompt_id" => entry.fetch("id")
                      }
                    )
                  end
        touch_state!(state, now)
        store.save(state)

        accepted_result(
          command_id,
          command_type,
          agent.fetch("id"),
          message,
          { "agent_id" => agent.fetch("id"), "queued" => true, "pending_prompt_id" => entry.fetch("id"), "attempts" => attempts },
          log_ids
        )
      end

      def remove_pending_prompts!(agent, pending_prompt_id:, command_id:)
        metadata = agent.fetch("harness_metadata", {}) || {}
        pending = Array(metadata.fetch("pending_prompts", [])).select { |entry| entry.is_a?(Hash) }
        return if pending.empty?

        remaining = pending.reject do |entry|
          (pending_prompt_id && entry.fetch("id", nil).to_s == pending_prompt_id) ||
            (present_string(command_id) && entry.fetch("command_id", nil).to_s == command_id.to_s)
        end
        metadata["pending_prompts"] = remaining
        agent["harness_metadata"] = metadata
      end

      def clear_prompt_delivery_claim!(agent, claim_token)
        metadata = agent.fetch("harness_metadata", {}) || {}
        claim = metadata.fetch("prompt_delivery_claim", nil)
        return unless claim.is_a?(Hash)
        return if claim_token && claim.fetch("token", nil).to_s != claim_token.to_s

        metadata.delete("prompt_delivery_claim")
        agent["harness_metadata"] = metadata
      end

      def prompt_delivery_noun(mode)
        case mode.to_s
        when "steer" then "correction"
        when "follow_up" then "follow-up"
        else "prompt"
        end
      end

      def next_pending_prompt_id(agent, pending)
        numbers = Array(pending).filter_map do |entry|
          match = entry.is_a?(Hash) && entry.fetch("id", "").to_s.match(/-PP(\d+)\z/)
          match && match[1].to_i
        end
        "#{agent.fetch("id")}-PP#{(numbers.max || 0) + 1}"
      end

      # Redelivers prompts that were queued while a session was busy mid-turn.
      def deliver_pending_agent_prompts
        pending = synchronized_state do
          normalized_state.fetch("agents").flat_map do |agent|
            next [] unless agent.fetch("type", nil) == "worker"
            # Explicitly paused workers own their queued prompts, but resume owns delivery so a
            # prompt cannot wake a session the user deliberately stopped.
            next [] if agent.fetch("status", nil) == "paused"
            next [] if (agent.fetch("harness_metadata", {}) || {}).fetch("pause_request", nil).is_a?(Hash)
            # Focus owns the prompt box. Keep dashboard prompts durable, but do not write through
            # the managed transport until the focused session releases its ownership marker.
            next [] if agent_focus_ownership_active?(agent)
            # A prompt queued while the worker was mid-turn must not be dropped just because that
            # turn then died from a transport failure; that session is still resumable.
            if TERMINAL_AGENT_STATUSES.include?(agent.fetch("status", nil)) && !worker_resumable_after_settle_failure?(agent)
              next []
            end

            metadata = agent.fetch("harness_metadata", {}) || {}
            entries = Array(metadata.fetch("pending_prompts", [])).select do |entry|
              entry.is_a?(Hash) && present_string(entry.fetch("prompt", nil))
            end
            awaiting_receipt = entries.find { |entry| entry.fetch("delivery_state", nil) == "awaiting_receipt" }
            # While one harness request has an ambiguous outcome, no later queued prompt may pass it.
            # Reconciliation checks only that receipt; after it settles, remaining prompts are
            # delivered in their existing order on the next pass.
            entries = [awaiting_receipt] if awaiting_receipt
            entries.map { |entry| { "agent_id" => agent.fetch("id"), "entry" => deep_copy(entry) } }
          end
        end

        pending.map do |item|
          entry = item.fetch("entry")
          apply(
            "command_id" => entry.fetch("command_id", nil),
            "type" => "PromptAgent",
            "payload" => {
              "agent_id" => item.fetch("agent_id"),
              "prompt" => entry.fetch("prompt"),
              "mode" => entry.fetch("mode", "normal"),
              "_pending_prompt_id" => entry.fetch("id", nil)
            }
          )
        end
      end

      # --- goal loops ------------------------------------------------------------
      #
      # A goal is the durable controller for "keep working until this measurable criterion
      # is met". It is attached to exactly one issue, owns its own budgets, and is advanced
      # by the reconcile tick rather than by a long-lived agent session.
    end
  end
end
