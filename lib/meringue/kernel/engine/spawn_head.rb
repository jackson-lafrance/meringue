# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Spawning a head for a user message, and retrying one whose request never finished routing.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def head_takeover_plan(state, head_id, allow_self_consumption: false, direct_follow_up: false)
        target_id = Ids.canonical(head_id.to_s)
        target = find_agent(state, target_id)
        unless target && target.fetch("type", nil) == "head"
          return { "error" => "Head #{head_id} does not exist.", "code" => "head_not_found" }
        end
        unless head_still_routing?(target)
          return {
            "error" => "Head #{target.fetch("id")} is no longer still routing; use /retry for a stopped head or send a new prompt.",
            "code" => "head_not_still_routing"
          }
        end

        metadata = target.fetch("harness_metadata", {}) || {}
        applying = metadata.fetch("head_result_apply_state", nil).to_s == "applying"
        if (applying && !allow_self_consumption) || head_result_apply_lease_held_elsewhere?(target)
          return {
            "error" => "Head #{target.fetch("id")} is already applying its result, so it cannot be taken over safely.",
            "code" => "head_result_apply_in_progress"
          }
        end

        request = head_request_in_state(state, target) || {}
        unless present_string(request.fetch("user_message", nil))
          return {
            "error" => "Head #{target.fetch("id")} has no recorded request to take over; send the new message as a fresh prompt.",
            "code" => "head_request_unavailable"
          }
        end

        {
          "target" => target,
          "request" => request,
          "context" => head_takeover_context(target, request, direct_follow_up: direct_follow_up)
        }
      end

      def head_takeover_context(head, request, direct_follow_up: false)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        prior_takeover = request.fetch("takeover_context", nil)
        prior_takeover = nil unless prior_takeover.is_a?(Hash)
        previous_result = metadata.fetch("head_result", nil)
        previous_result = previous_result.slice("title", "summary", "response", "commands", "questions") if previous_result.is_a?(Hash)
        previous_journal = Array(metadata.fetch("head_result_command_journal", [])).filter_map do |entry|
          next unless entry.is_a?(Hash)

          entry.slice("command_id", "index", "command_type", "status", "target_id", "message", "errors").compact
        end
        {
          "previous_head_id" => head.fetch("id", nil),
          "relationship" => direct_follow_up ? "direct_follow_up" : "takeover",
          "original_user_message" => prior_takeover&.fetch("original_user_message", nil) || request.fetch("user_message", nil),
          "original_prompt" => request.fetch("user_message", nil),
          "original_request" => request.slice("user_message", "question_id", "selected_target", "input_submission_id").compact,
          "previous_title" => metadata.fetch("title", nil),
          "previous_summary" => metadata.fetch("summary", nil),
          "previous_head_result" => previous_result,
          "previous_command_journal" => previous_journal.empty? ? nil : previous_journal,
          "snapshot" => {
            "issue_ids" => metadata.fetch("snapshot_issue_ids", []),
            "project_ids" => metadata.fetch("snapshot_project_ids", []),
            "unapplied_head_ids" => metadata.fetch("snapshot_unapplied_head_ids", []),
            "counters" => metadata.fetch("snapshot_counters", {})
          },
          "prior_takeover" => prior_takeover,
          "guidance" => "Continue the previous head's request with the new prompt. Treat the previous result and command journal as context. Do not duplicate durable commands that already landed; route only one coherent result for this replacement head."
        }.compact
      end

      def spawn_head(command_id, command_type, payload)
        user_message = value_at(payload, "user_message", "UserMessage", "message")
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        requested_selected_target = value_at(payload, "selected_target", "SelectedTarget", "selectedTarget")
        follow_up_of_head_id = present_string(value_at(payload, "_follow_up_of_head_id", "follow_up_of_head_id", "follow_up_of_head", "follow_up_head_id", "followUpOfHeadID", "followUpOfHeadId", "followUpOfHead"))
        takeover_head_id = present_string(value_at(payload, "_takeover_of_head_id", "takeover_of_head_id", "takeover_head_id", "takeoverHeadId"))
        if takeover_head_id && follow_up_of_head_id && !Ids.same?(takeover_head_id, follow_up_of_head_id)
          return synchronized_state do
            rejected_result(command_id, command_type, "Head was not spawned.", ["takeover_of_head_id and follow_up_of_head_id conflict"])
          end
        end
        takeover_head_id ||= follow_up_of_head_id
        proposing_head_id = present_string(value_at(payload, "_head_id", "head_id", "HeadID", "headId"))
        self_follow_up = follow_up_of_head_id && proposing_head_id && Ids.same?(follow_up_of_head_id, proposing_head_id)
        # Internally routed heads (for example the head spawned for an answered question) carry a
        # long structured prompt. The visible chat log should stay short and human-facing.
        log_message = present_string(value_at(payload, "log_message", "LogMessage"))
        log_source_type = present_string(value_at(payload, "_log_source_type", "log_source_type"))
        log_source_type = "user" unless %w[user kernel system].include?(log_source_type)
        log_source_id = present_string(value_at(payload, "_log_source_id", "log_source_id"))
        retry_of = head_retry_lineage(payload)
        completion_trigger = head_completion_trigger_lineage(payload)
        errors = []

        errors << "user_message is required" if blank?(user_message)
        return synchronized_state { rejected_result(command_id, command_type, "Head was not spawned.", errors) } unless errors.empty?

        head_id = nil
        selected_target = nil
        takeover_context = nil
        takeover_target = nil
        started = synchronized_state do
          state = normalized_state
          submission_id = present_string(value_at(payload, "_input_submission_id", "input_submission_id"))
          if submission_id && (existing = head_for_input_submission(state, submission_id))
            return accepted_result(
              command_id, command_type, existing.fetch("id"),
              "Input submission #{submission_id} was already routed to head #{existing.fetch("id")}.",
              deep_copy(existing), []
            )
          end
          if takeover_head_id
            takeover = head_takeover_plan(
              state,
              takeover_head_id,
              allow_self_consumption: !!self_follow_up,
              direct_follow_up: !!follow_up_of_head_id
            )
            if takeover.fetch("error", nil)
              return rejected_result(command_id, command_type, "Head takeover was not started: #{takeover.fetch("error")}", [takeover.fetch("code")])
            end

            takeover_target = takeover.fetch("target")
            takeover_context = takeover.fetch("context").merge("new_prompt" => user_message.to_s)
            request = takeover.fetch("request")
            question_id = present_string(question_id) || present_string(request.fetch("question_id", nil))
            requested_selected_target ||= request.fetch("selected_target", nil)
          end

          if present_string(question_id) && !find_question(state, question_id)
            return rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"])
          end

          selected_target, selected_target_error = resolve_selected_head_target(state, requested_selected_target)
          if selected_target_error
            return rejected_result(
              command_id,
              command_type,
              "Head was not spawned: #{selected_target_error.fetch("message")}",
              [selected_target_error.fetch("code")]
            )
          end

          active_provider = active_harness_provider(state, role: "head")
          active_runner = active_head_runner(provider: active_provider)
          now = timestamp
          head_id = next_head_id!(state)
          if takeover_target
            target_metadata = takeover_target.fetch("harness_metadata", {}) || {}
            takeover_target["harness_metadata"] = target_metadata.merge(
              "head_takeover_state" => "claimed",
              "head_takeover_by_head_id" => head_id,
              "head_takeover_claimed_at" => now
            )
            takeover_target["updated_at"] = now
          end
          agent = build_head_agent(
            head_id: head_id,
            now: now,
            provider: active_provider,
            runner: active_runner,
            harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i,
            user_message: user_message.to_s,
            question_id: present_string(question_id),
            selected_target: selected_target,
            takeover_of_head_id: takeover_target&.fetch("id", nil),
            follow_up_of_head_id: follow_up_of_head_id,
            takeover_context: takeover_context,
            retry_of: retry_of,
            completion_trigger: completion_trigger,
            input_submission_id: submission_id,
            snapshot_issue_ids: state.fetch("issues").map { |issue| issue.fetch("id", nil) }.compact,
            snapshot_project_ids: state.fetch("projects").map { |project| project.fetch("id", nil) }.compact,
            snapshot_unapplied_head_ids: unapplied_head_ids_for_issue_visibility(state),
            snapshot_counters: deep_copy(state.fetch("counters", {})),
            worker_spawning_guidance: worker_spawning_guidance_enabled?
          )
          state.fetch("agents") << agent

          log_ids = append_log(
            state,
            source_type: log_source_type,
            source_id: log_source_type == "user" ? nil : log_source_id,
            level: "info",
            message: log_message || user_message.to_s.strip,
            details: {
              "head_id" => head_id,
              "question_id" => present_string(question_id),
              "retry_of_head_id" => retry_of && retry_of.fetch("head_id", nil),
              "takeover_of_head_id" => takeover_target&.fetch("id", nil),
              "follow_up_of_head_id" => follow_up_of_head_id,
              "routing_action" => if takeover_target
                                    follow_up_of_head_id ? "head_follow_up" : "head_takeover"
                                  end,
              **selected_target_log_details(selected_target)
            }.compact
          )
          # Lineage is recorded next to the prompt that caused it, so the log reads
          # "<your message>" then "Retrying head H13 as H14 ..." in order.
          log_ids.concat(record_head_retry_respawn!(state, retry_of, head_id)) if retry_of
          touch_state!(state, now)
          store.save(state)

          snapshot = deep_copy(state)
          context = Heads::Context.new(
            head_id: head_id,
            user_message: user_message.to_s,
            snapshot: snapshot,
            question_id: present_string(question_id),
            selected_target: selected_target,
            takeover_context: takeover_context,
            cwd: cwd,
            state_path: store.path,
            github_support: github_frontend?(snapshot),
            worker_spawning_guidance: worker_spawning_guidance_enabled?,
            worker_spawning_guidance_prompt: worker_spawning_guidance_prompt
          )

          {
            "context" => context,
            "log_ids" => log_ids,
            # A guidance-enabled Context owns a privacy-filtered copy. Pass the
            # same copy to every runner seam so a fake/custom runner cannot see
            # defaults that the real harness prompt does not receive.
            "snapshot" => context.snapshot,
            "head_runner" => active_runner,
            "takeover_of_head_id" => takeover_target&.fetch("id", nil),
            "follow_up_of_head_id" => follow_up_of_head_id
          }
        end

        runner = started.fetch("head_runner")
        # A head owns a harness session for its whole lifetime. The kernel spawns that
        # session, records it on the head agent record, and only tears it down when the
        # head reaches a terminal state (result applied, errored, or killed).
        session_ref = nil
        if runner.respond_to?(:spawn_head_session)
          session_ref = runner.spawn_head_session(
            user_message: user_message.to_s,
            snapshot: started.fetch("snapshot"),
            question_id: present_string(question_id),
            context: started.fetch("context")
          )
          session_record = record_head_session!(head_id, session_ref)
          session_log_ids = session_record.fetch("log_entry_ids", [])
          if takeover_target
            takeover_release = complete_head_takeover!(takeover_target.fetch("id"), head_id)
            session_log_ids.concat(takeover_release.fetch("log_entry_ids", []))
          end

          if async_heads?
            return synchronized_state do
              accepted_result(
                command_id,
                command_type,
                head_id,
                "Spawned head #{head_id}; polling will apply its HeadResult when complete.",
                session_record.fetch("agent"),
                (started.fetch("log_ids") + session_log_ids).uniq
              )
            end
          end
        else
          session_log_ids = mark_head_session_unavailable!(head_id, reason: "head_runner_has_no_session").fetch("log_entry_ids", [])
          if takeover_target
            takeover_release = complete_head_takeover!(takeover_target.fetch("id"), head_id)
            session_log_ids.concat(takeover_release.fetch("log_entry_ids", []))
          end
        end

        head_result = if session_ref && runner.respond_to?(:await_head_result)
                        runner.await_head_result(session_ref)
                      else
                        runner.run(
                          user_message: user_message.to_s,
                          snapshot: started.fetch("snapshot"),
                          question_id: present_string(question_id),
                          context: started.fetch("context")
                        )
                      end

        synchronized_state do
          state = normalized_state
          agent = find_agent(state, head_id)
          raise "Head #{head_id} disappeared before completion could be recorded." unless agent

          if head_takeover_claimed_by?(agent)
            return defer_head_result_for_takeover(
              command_id,
              command_type,
              state,
              agent,
              head_result
            )
          end

          agent["status"] = "completed"
          agent["updated_at"] = timestamp
          agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
            "title" => head_result.is_a?(Hash) ? head_result["title"] : nil,
            "summary" => head_result.is_a?(Hash) ? head_result["summary"] : nil,
            "response" => head_result.is_a?(Hash) ? head_result["response"] : nil,
            "head_result" => head_result,
            "is_streaming" => false
          ).compact
          log_ids = (started.fetch("log_ids") + session_log_ids).uniq
          touch_state!(state)
          store.save(state)

          accepted_result(command_id, command_type, head_id, "Spawned and completed head #{head_id}.", agent, log_ids)
        end
      rescue StandardError => e
        released = mark_head_errored(head_id, e, release_session: true) if defined?(head_id) && head_id
        rollback_head_takeover!(takeover_target.fetch("id"), head_id, reason: e.message) if takeover_target && head_id
        # If the head record itself is gone the kernel still owns the session it spawned.
        if !released && defined?(session_ref) && session_ref && runner.respond_to?(:close_head_session)
          runner.close_head_session(session_ref)
        end
        synchronized_state do
          failed_result(
            command_id,
            command_type,
            "Head failed: #{e.message}",
            [e.class.name, e.message]
          )
        end
      end

      # `/retry H13` is the only kernel path that retries a head. It is a deliberate user recovery
      # action: the old head/session is never prompted or resumed, and a fresh head receives the
      # original request, the failed command journal, and instructions to route only the missing
      # work. The head contract is unchanged: the retry still returns HeadResult JSON and is never
      # turned into a worker by this path.
      def retry_head_command(command_id, command_type, payload)
        head_id = value_at(payload, "head_id", "HeadID", "headId", "agent_id", "AgentID", "agentId")
        return synchronized_state { rejected_result(command_id, command_type, "Head was not retried.", ["head_id is required"]) } if blank?(head_id)

        retry_head(command_id, command_type, head_id.to_s, instruction: value_at(payload, "prompt", "message", "instruction"), log_message: value_at(payload, "log_message", "LogMessage"))
      end

      def retry_head(command_id, command_type, head, instruction: nil, log_message: nil)
        head_id = head.is_a?(Hash) ? head.fetch("id", nil).to_s : head.to_s
        plan = synchronized_state { head_retry_plan(normalized_state, head_id, instruction: instruction) }
        unless plan.fetch("eligible")
          return synchronized_state do
            rejected_result(command_id, command_type, plan.fetch("message"), [plan.fetch("code")])
          end
        end

        respawn_head_retry(command_id, command_type, plan, instruction: instruction, log_message: log_message)
      end

      # What a retry of this head would do right now, or why it cannot happen. Pure: it reads the
      # supplied state and never locks, so it can be called from inside a synchronized section.
      def head_retry_plan(state, head_id, instruction: nil)
        head = find_agent(state, head_id.to_s)
        unless head
          return { "eligible" => false, "code" => "agent_not_found", "message" => missing_agent_prompt_message(head_id) }
        end
        unless head.fetch("type", nil) == "head"
          return { "eligible" => false, "code" => "agent_is_not_head", "message" => "Agent #{head.fetch("id")} is not a head." }
        end

        resolved_id = head.fetch("id").to_s
        status = head.fetch("status", nil).to_s
        unless State::Models.head_retry_target?(head)
          return {
            "eligible" => false,
            "code" => head_retry_rejection_code(head),
            "message" => head_retry_rejection_message(resolved_id, status, head)
          }
        end

        request = head_request_in_state(state, head) || {}
        original_message = present_string(request.fetch("user_message", nil))
        if original_message.nil? && blank?(instruction)
          return {
            "eligible" => false,
            "code" => "head_request_unavailable",
            "message" => "Head #{resolved_id} has no recorded request to retry; send your message as a new prompt instead."
          }
        end

        failure = head_retry_failure_case(head)
        {
          "eligible" => true,
          "head_id" => resolved_id,
          "status" => status,
          "case" => failure.fetch("case"),
          "reason" => failure.fetch("reason"),
          "strategy" => "respawn",
          "user_message" => original_message,
          "question_id" => present_string(request.fetch("question_id", nil)),
          # What the failed batch already did, straight from its command journal. The retry head
          # is told both halves so it can route what is missing without re-proposing work that
          # already landed.
          "applied_commands" => head_retry_command_digest(State::Models.head_applied_commands(head)),
          "unrouted_commands" => head_retry_command_digest(State::Models.head_unrouted_commands(head))
        }
      end

      # The distinct ways a head stops without routing. Every retry is a fresh head; even an
      # errored head whose harness session is still present is not resumed, because manual retry
      # must not message an old head or replay the same failed turn.
      def head_retry_failure_case(head)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        detail = head_failure_detail(metadata)
        suffix = detail ? " (#{detail})" : ""

        return applied_batch_retry_failure_case(head) if State::Models.head_result_applied?(head)

        if head.fetch("status", nil) == "killed"
          return { "case" => "killed", "reason" => "you killed it before it routed this request", "resumable" => false }
        end
        unless agent_has_session_reference?(head)
          return { "case" => "never_started", "reason" => "it never started an agent session#{suffix}", "resumable" => false }
        end
        if metadata.fetch("head_session_state", nil) == HEAD_SESSION_STATE_RELEASED
          return { "case" => "session_released", "reason" => "it failed before returning a result#{suffix}", "resumable" => false }
        end

        {
          "case" => "transport_failure",
          "reason" => "its agent turn ended before it returned a result#{suffix}",
          "resumable" => false
        }
      end

      # A head whose result was applied is `blocked` because the kernel rejected or failed part of
      # its batch. That is not a head failure at all: the head routed, the kernel refused, and the
      # user's request is the thing left stranded. The reason says how much of it survived, because
      # that is what the user reads in the retry log line.
      def applied_batch_retry_failure_case(head)
        applied = State::Models.head_applied_commands(head)
        unrouted = State::Models.head_unrouted_commands(head)
        total = applied.length + unrouted.length
        if applied.any?
          return {
            "case" => "partially_routed",
            "reason" => "only #{applied.length} of its #{total} commands landed, so the rest of this request was never routed",
            "resumable" => false
          }
        end

        reason = if total.zero?
                   "its result routed nothing"
                 else
                   "none of its #{total} #{total == 1 ? "command" : "commands"} landed, so this request was never routed"
                 end
        { "case" => "nothing_routed", "reason" => reason, "resumable" => false }
      end

      # Compact per-command history for the retry head's prompt. A journal entry carries the whole
      # command result, so only the parts that explain what happened are carried over.
      def head_retry_command_digest(entries)
        Array(entries).map do |entry|
          {
            "command_type" => entry.fetch("command_type", nil),
            "status" => entry.fetch("status", nil),
            "target_id" => present_string(entry.fetch("target_id", nil)),
            "message" => present_string(entry.fetch("message", nil)) && single_line_excerpt(entry.fetch("message"), limit: 240),
            "errors" => Array(entry.fetch("errors", [])).map { |error| single_line_excerpt(error, limit: 120) }
          }.compact
        end
      end

      def head_retry_command_line(entry)
        line = "#{entry.fetch("command_type", nil) || "command"} #{entry.fetch("status", nil) || "unknown"}"
        target = present_string(entry.fetch("target_id", nil))
        line += " -> #{target}" if target
        detail = present_string(entry.fetch("message", nil)) || present_string(Array(entry.fetch("errors", [])).join("; "))
        line += ": #{detail}" if detail
        line
      end

      def head_failure_detail(metadata)
        reconcile = metadata.fetch("reconcile", {}) || {}
        reconcile = {} unless reconcile.is_a?(Hash)
        detail = present_string(metadata.fetch("error_message", nil)) || present_string(reconcile.fetch("error_message", nil))
        detail && truncate_for_state(detail, 200)
      end

      def head_retry_rejection_code(head)
        case head.fetch("status", nil).to_s
        when "queued", "working", "idle" then "head_still_working"
        else "head_already_routed"
        end
      end

      # A refusal must leave the user with a next action, and reaching one should be rare. Only two
      # refusals survive: a head that has not stopped routing yet, and a head that really did route
      # everything it proposed (so there is nothing left to re-run).
      def head_retry_rejection_message(head_id, status, head)
        if %w[queued working idle].include?(status)
          return "Head #{head_id} is still #{status} on its request, so there is nothing to retry yet. " \
                 "Send your message on its own, or kill #{head_id} first."
        end

        applied = State::Models.head_applied_commands(head)
        if applied.any?
          "Head #{head_id} already routed this request: all #{applied.length} of its commands were applied. Prompt the worker it created, or send your message as a new prompt."
        elsif State::Models.head_result_applied?(head)
          "Head #{head_id} answered this request with a question instead of routing it, so there is nothing to re-run. Answer it with /answer, or send your message as a new prompt."
        else
          "Head #{head_id} is #{status} and cannot be retried. Send your message as a new prompt instead."
        end
      end

      # Respawn path: a fresh head runs the failed head's original request plus the failed command
      # journal. This is the only manual retry strategy.
      def respawn_head_retry(command_id, command_type, plan, instruction: nil, log_message: nil)
        head_id = plan.fetch("head_id")
        result = spawn_head(
          command_id,
          command_type,
          {
            "user_message" => head_retry_user_message(plan, instruction),
            "log_message" => log_message || present_string(instruction) || "Retry head #{head_id}.",
            "question_id" => plan.fetch("question_id", nil),
            "_retry_of_head_id" => head_id,
            "_retry_case" => plan.fetch("case"),
            "_retry_reason" => plan.fetch("reason")
          }.compact
        )
        return result unless result.fetch("status", nil) == "accepted"

        result.merge("message" => "Retried head #{head_id} as head #{result.fetch("target_id", nil)}.")
      end

      # The retry head is a fresh stateless head, so everything it needs has to be in its message:
      # the request that was never routed, what the failed batch already applied (which it must not
      # propose again), what never landed and why, and why it is running again.
      def head_retry_user_message(plan, instruction)
        original = present_string(plan.fetch("user_message", nil))
        extra = present_string(instruction)
        extra = nil if original && extra && extra.strip == original.strip
        return extra.to_s if original.nil?

        applied = Array(plan.fetch("applied_commands", []))
        lines = [
          "Retry of head #{plan.fetch("head_id")}, which stopped before routing this request because #{plan.fetch("reason")}.",
          "",
          "Original user message:",
          original
        ]
        lines.concat(head_retry_landed_command_lines(applied))
        lines.concat(head_retry_unrouted_command_lines(Array(plan.fetch("unrouted_commands", []))))
        lines.concat(["", "New instruction from the user:", extra]) if extra
        lines.concat(["", head_retry_closing_instruction(applied)])
        lines.join("\n")
      end

      # Retrying a partially applied batch must not route the same work twice, and the kernel does
      # not re-run journal entries: a retry re-routes the request. So the records that already exist
      # are named for the retry head, which reuses them the same way it reuses any existing issue or
      # worker it can see in state.
      def head_retry_landed_command_lines(applied)
        return [] if applied.empty?

        [
          "",
          "Its previous attempt already applied these commands, and that work exists in state now. " \
            "Reuse those records and never propose them again:",
          *applied.map { |entry| "- #{head_retry_command_line(entry)}" }
        ]
      end

      def head_retry_unrouted_command_lines(unrouted)
        return [] if unrouted.empty?

        [
          "",
          "These commands never landed, so that part of the request is still unrouted. Read current " \
            "state first, then fix what the kernel objected to instead of resending the same command:",
          *unrouted.map { |entry| "- #{head_retry_command_line(entry)}" }
        ]
      end

      def head_retry_closing_instruction(applied)
        return "Route this request now." if applied.empty?

        "Route only the part of this request that is still unrouted, reusing the records above."
      end

      # Retry lineage handed from `respawn_head_retry` to `spawn_head` through the payload.
      def head_retry_lineage(payload)
        head_id = present_string(value_at(payload, "_retry_of_head_id", "retry_of_head_id"))
        return nil unless head_id

        {
          "head_id" => head_id,
          "case" => present_string(value_at(payload, "_retry_case", "retry_case")),
          "reason" => present_string(value_at(payload, "_retry_reason", "retry_reason"))
        }.compact
      end

      # Completion-triggered heads are spawned internally by the kernel, but the head record should
      # still explain why it exists so reconciliation can recover without spawning a duplicate.
      def head_completion_trigger_lineage(payload)
        trigger = value_at(payload, "_completion_trigger", "completion_trigger")
        return nil unless trigger.is_a?(Hash)

        trigger.each_with_object({}) do |(key, value), result|
          next if value.nil?

          result[key.to_s] = value
        end.compact
      end

      # Links the failed head to its successor and says so once, in the log, at the point the
      # retry happened. The previous head leaves the active AgentTree immediately: its record was
      # only a retry affordance, while the durable lineage lives on the new head and this log entry.
      def record_head_retry_respawn!(state, retry_of, new_head_id)
        previous_id = retry_of.fetch("head_id")
        previous = find_agent(state, previous_id)
        previous_snapshot = previous ? deep_copy(previous) : nil
        now = timestamp

        session_release = release_head_session!(previous, reason: "head_retried", now: now) if previous
        carry_retry_display_title!(state, previous_snapshot, new_head_id)
        state.fetch("agents").delete(previous) if previous

        reason = retry_of.fetch("reason", nil)
        append_log(
          state,
          source_type: "kernel",
          source_id: previous_id,
          level: "info",
          message: "Retrying head #{previous_id} as head #{new_head_id}#{reason ? ": #{reason}" : ""}. Re-running its original request with a fresh head.",
          details: {
            "head_id" => new_head_id,
            "retry_of_head_id" => previous_id,
            "retry_strategy" => "respawn",
            "retry_case" => retry_of.fetch("case", nil),
            "head_record_missing" => previous ? nil : true,
            "previous_head_removed_from_active_tree" => previous ? true : nil,
            "previous_head_session_released" => session_release && session_release.fetch("changed", false) ? true : nil,
            "previous_head" => retry_lineage_snapshot(previous_snapshot),
            "routing_action" => "head_retry"
          }.compact
        )
      end

      def carry_retry_display_title!(state, previous_snapshot, new_head_id)
        return unless previous_snapshot

        title = present_string(previous_snapshot.dig("harness_metadata", "title"))

        new_head = find_agent(state, new_head_id)
        return unless new_head

        metadata = new_head.fetch("harness_metadata", {}) || {}
        lineage = {
          "title" => title,
          "head_retry_count" => head_retry_count(previous_snapshot) + 1,
          "previous_head_status" => previous_snapshot.fetch("status", nil)
        }.compact
        new_head["harness_metadata"] = metadata.merge(lineage)
      end

      def retry_lineage_snapshot(previous_snapshot)
        return nil unless previous_snapshot

        metadata = previous_snapshot.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        {
          "id" => previous_snapshot.fetch("id", nil),
          "status" => previous_snapshot.fetch("status", nil),
          "title" => present_string(metadata.fetch("title", nil)),
          "head_session_state" => present_string(metadata.fetch("head_session_state", nil)),
          "harness" => present_string(previous_snapshot.fetch("harness", nil)),
          "harness_session_id" => present_string(previous_snapshot.fetch("harness_session_id", nil)),
          "harness_session_file" => present_string(previous_snapshot.fetch("harness_session_file", nil))
        }.compact
      end

      def head_retry_count(head)
        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        metadata.fetch("head_retry_count", 0).to_i
      end

      # A resumed head is working again, so the failure that stopped it is history. Clearing the
      # terminal reconcile marker is what lets reconciliation poll the session and apply its result.
      def clear_head_failure_metadata(metadata)
        metadata = {} unless metadata.is_a?(Hash)
        cleared = metadata.dup
        previous = {
          "error_class" => cleared.delete("error_class"),
          "error_message" => cleared.delete("error_message"),
          "errored_at" => cleared.delete("errored_at"),
          "reconcile" => cleared.delete("reconcile")
        }.compact
        cleared.delete("reconcile_state")
        cleared["previous_head_failure"] = previous unless previous.empty?
        cleared
      end
    end
  end
end
