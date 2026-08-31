# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Workers queued behind a predecessor or a command gate: their metadata, their queueing, and
      # the shape of the gate they wait on.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      # --- Deferred (queued-after) workers ------------------------------------------------------
      #
      # Dependency model: a dependent is an ordinary queued worker agent record with a top-level
      # `after_agent_id` plus a `harness_metadata.deferred_spawn` block. The record *is* the whole
      # dependency, so nothing sleeps or polls for it, the AgentTree/GetInfo/Kill/Prune/Recount
      # paths already understand it, and any kernel instance can resolve it after a restart.
      #
      # Settle policy. Every outcome is logged; a dependent is never silently dropped.
      #   completed -> activate, handing the predecessor's final report to the dependent
      #   errored   -> cancel by default, or start anyway with `if_predecessor_fails: "run"`
      #   killed    -> cancel, unless the kill was a replacement, in which case the dependent is
      #                re-pointed at the successor that took the predecessor's place
      #   removed   -> cancel (prune retains a predecessor while a dependent still waits, so this
      #                only happens after an out-of-band removal)
      #   queued/working/idle/blocked -> keep waiting
      def deferred_spawn_metadata(agent)
        metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
        deferred = metadata.fetch("deferred_spawn", nil)
        deferred.is_a?(Hash) ? deferred : {}
      end

      # A worker that is deliberately not started yet. Deliberately narrow: it must still be queued
      # with no session, so a half-provisioned worker is never mistaken for a queued dependent.
      def waiting_deferred_worker?(agent)
        return false unless agent.is_a?(Hash) && agent.fetch("type", nil) == "worker"
        return false unless agent.fetch("status", nil) == "queued"
        return false if agent_has_session_reference?(agent)

        deferred_spawn_metadata(agent).fetch("state", nil) == DEFERRED_STATE_WAITING
      end

      def pending_deferred_worker?(agent)
        DEFERRED_PENDING_STATES.include?(deferred_spawn_metadata(agent).fetch("state", nil))
      end

      def deferred_worker_after_agent_id(agent)
        present_string(agent.fetch("after_agent_id", nil)) ||
          present_string(deferred_spawn_metadata(agent).fetch("after_agent_id", nil))
      end

      # Workers that are still running and whose lineage or shared checkout names one of these
      # predecessors. A queued dependent is covered by `waiting_deferred_dependents`; this is the
      # same protection once that successor is actually working.
      def live_worker_successors(state, predecessor_ids)
        wanted = Array(predecessor_ids).compact.map(&:to_s).reject(&:empty?)
        return [] if wanted.empty?

        state.fetch("agents").select do |agent|
          next false unless agent.fetch("type", nil) == "worker"
          next false unless PRUNE_BLOCKING_WORKER_STATUSES.include?(agent.fetch("status", nil).to_s)

          references = [
            agent.fetch("after_agent_id", nil),
            agent.fetch("follow_up_of_agent_id", nil),
            agent.fetch("replaces_agent_id", nil),
            agent.dig("harness_metadata", "workspace_reuse", "of_agent_id")
          ].compact
          next false if references.empty?

          references.any? { |reference| wanted.any? { |candidate| Ids.same?(candidate, reference) } }
        end
      end

      def waiting_deferred_dependents(state, predecessor_ids)
        wanted = Array(predecessor_ids).compact.map(&:to_s).reject(&:empty?)
        return [] if wanted.empty?

        state.fetch("agents").select do |agent|
          next false unless waiting_deferred_worker?(agent)

          after_agent_id = deferred_worker_after_agent_id(agent)
          wanted.any? { |candidate| Ids.same?(candidate, after_agent_id) }
        end
      end

      def deferred_worker_default_failure_policy
        @deferred_worker_default_failure_policy || DEFERRED_WORKER_DEFAULT_FAILURE_POLICY
      end

      def normalized_deferred_failure_policy(payload)
        raw = present_string(value_at(payload, *DEFERRED_WORKER_FAILURE_POLICY_KEYS))
        return deferred_worker_default_failure_policy unless raw

        normalized = raw.downcase.tr("-", "_")
        normalized = "run" if %w[run run_anyway continue proceed start].include?(normalized)
        normalized = "cancel" if %w[cancel skip drop abort].include?(normalized)
        DEFERRED_WORKER_FAILURE_POLICIES.include?(normalized) ? normalized : nil
      end

      def deferred_handover_requested?(payload)
        raw = value_at(payload, *DEFERRED_WORKER_HANDOVER_KEYS)
        return true if raw.nil?

        !%w[false 0 no off].include?(raw.to_s.strip.downcase)
      end

      # --- Command-gated ("wait for this script") queued workers ---------------------------------
      #
      # `after_command` is the second predicate a queued worker can carry. It is deliberately the
      # *same* queued-worker concept as `after_agent_id`, not a second scheduler: the condition
      # lives on the worker record, the reconcile pass evaluates it, and activation runs through
      # the one `resolve_deferred_workers` seam. When both predicates are present they compose as
      # AND, and the command is only armed once the predecessor settles.
      #
      # Everything a gate can do is bounded up front, because it runs a user/head-supplied shell
      # command on a timer: one process group per check, a hard per-check timeout, a minimum poll
      # interval, a total wait budget, and a cap on consecutive unusable checks.
      def deferred_gate_plan(payload)
        command = present_string(value_at(payload, *DEFERRED_WORKER_GATE_COMMAND_KEYS))
        supplementary = DEFERRED_WORKER_GATE_EXPECT_KEYS + DEFERRED_WORKER_GATE_PATTERN_KEYS +
                        DEFERRED_WORKER_GATE_CWD_KEYS + DEFERRED_WORKER_GATE_INTERVAL_KEYS +
                        DEFERRED_WORKER_GATE_TIMEOUT_KEYS + DEFERRED_WORKER_GATE_MAX_WAIT_KEYS +
                        DEFERRED_WORKER_GATE_EXPIRY_POLICY_KEYS + DEFERRED_WORKER_GATE_LABEL_KEYS
        unless command
          # Gate options with no gate command would silently do nothing, which reads as "the wait
          # worked" when the worker starts immediately. Say so instead.
          return { "gate" => nil, "errors" => [] } if supplementary.none? { |key| !value_at(payload, key).nil? }

          return { "gate" => nil, "errors" => ["after_command_required"] }
        end

        errors = []
        errors << "invalid_after_command" if command.length > DEFERRED_WORKER_GATE_COMMAND_MAX_CHARS
        expect = normalized_gate_expectation(payload)
        errors << "invalid_after_command_expect" if expect.nil?
        pattern = present_string(value_at(payload, *DEFERRED_WORKER_GATE_PATTERN_KEYS))
        # A gate that can never pass must be rejected at spawn time rather than polled for hours:
        # `output_matches` with no pattern, or with a pattern that is not a usable regex, is that.
        if expect == "output_matches"
          if pattern.nil?
            errors << "invalid_after_command_pattern"
          else
            begin
              Regexp.new(pattern, Regexp::MULTILINE)
            rescue RegexpError
              errors << "invalid_after_command_pattern"
            end
          end
        end
        cwd_mode = normalized_gate_cwd_mode(payload)
        errors << "invalid_after_command_cwd" if cwd_mode.nil?
        expiry_policy = normalized_gate_expiry_policy(payload)
        errors << "invalid_if_gate_expires" if expiry_policy.nil?

        return { "gate" => nil, "errors" => errors } unless errors.empty?

        {
          "gate" => {
            "command" => command,
            "label" => present_string(value_at(payload, *DEFERRED_WORKER_GATE_LABEL_KEYS)),
            "expect" => expect,
            "pattern" => pattern,
            "cwd" => cwd_mode,
            "interval_seconds" => bounded_gate_seconds(
              value_at(payload, *DEFERRED_WORKER_GATE_INTERVAL_KEYS),
              default: DEFERRED_WORKER_GATE_DEFAULT_INTERVAL_SECONDS,
              min: DEFERRED_WORKER_GATE_MIN_INTERVAL_SECONDS,
              max: DEFERRED_WORKER_GATE_MAX_INTERVAL_SECONDS
            ),
            "timeout_seconds" => bounded_gate_seconds(
              value_at(payload, *DEFERRED_WORKER_GATE_TIMEOUT_KEYS),
              default: DEFERRED_WORKER_GATE_DEFAULT_TIMEOUT_SECONDS,
              min: 1,
              max: DEFERRED_WORKER_GATE_MAX_TIMEOUT_SECONDS
            ),
            "max_wait_seconds" => bounded_gate_seconds(
              value_at(payload, *DEFERRED_WORKER_GATE_MAX_WAIT_KEYS),
              default: DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS,
              min: DEFERRED_WORKER_GATE_MIN_INTERVAL_SECONDS,
              max: DEFERRED_WORKER_GATE_MAX_WAIT_CEILING_SECONDS
            ),
            "if_gate_expires" => expiry_policy
          }.compact,
          "errors" => []
        }
      end

      def normalized_gate_expectation(payload)
        raw = present_string(value_at(payload, *DEFERRED_WORKER_GATE_EXPECT_KEYS))
        return DEFERRED_WORKER_GATE_DEFAULT_EXPECT unless raw

        normalized = raw.downcase.strip.tr("- ", "__")
        normalized = "exit_zero" if %w[exit_zero exit_0 exit_status zero success].include?(normalized)
        normalized = "output_matches" if %w[output_matches matches regex output_regex output_match].include?(normalized)
        DEFERRED_WORKER_GATE_EXPECTATIONS.include?(normalized) ? normalized : nil
      end

      def normalized_gate_cwd_mode(payload)
        raw = present_string(value_at(payload, *DEFERRED_WORKER_GATE_CWD_KEYS))
        return DEFERRED_WORKER_GATE_DEFAULT_CWD unless raw

        normalized = raw.downcase.strip.tr("- ", "__")
        normalized = "project_root" if %w[project project_root root repo repository].include?(normalized)
        normalized = "workspace" if %w[workspace worktree worker_workspace].include?(normalized)
        DEFERRED_WORKER_GATE_CWD_MODES.include?(normalized) ? normalized : nil
      end

      # Same vocabulary as `if_predecessor_fails`, for the same reason: when the condition the
      # worker is waiting on never resolves, `cancel` (default) drops it with a warning and `run`
      # starts it anyway and says so in the handover.
      def normalized_gate_expiry_policy(payload)
        raw = present_string(value_at(payload, *DEFERRED_WORKER_GATE_EXPIRY_POLICY_KEYS))
        return deferred_worker_default_failure_policy unless raw

        normalized = raw.downcase.tr("-", "_")
        normalized = "run" if %w[run run_anyway continue proceed start].include?(normalized)
        normalized = "cancel" if %w[cancel skip drop abort].include?(normalized)
        DEFERRED_WORKER_FAILURE_POLICIES.include?(normalized) ? normalized : nil
      end

      def bounded_gate_seconds(value, default:, min:, max:)
        number = Float(value.to_s)
        return default unless number.finite?

        number.clamp(min, max).round
      rescue ArgumentError, TypeError
        default
      end

      def deferred_command_gate(agent_or_deferred)
        deferred = if agent_or_deferred.is_a?(Hash) && agent_or_deferred.key?("command_gate")
                     agent_or_deferred
                   else
                     deferred_spawn_metadata(agent_or_deferred)
                   end
        gate = deferred.fetch("command_gate", nil)
        gate.is_a?(Hash) ? gate : nil
      end

      # Arms a gate: `armed_at` starts the total wait budget and `next_check_at` makes it due.
      # A gate behind a predecessor is stored disarmed and armed later, so its budget measures the
      # time the *condition* took, not the time its predecessor took.
      def armed_deferred_gate(gate, now:)
        base = gate.merge("state" => DEFERRED_GATE_STATE_PENDING, "checks" => gate.fetch("checks", 0).to_i)
        return base unless now

        base.merge(
          "armed_at" => now,
          "next_check_at" => now,
          "expires_at" => gate_deadline(now, base.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS))
        ).compact
      end

      def gate_armed?(gate)
        gate.is_a?(Hash) && present_string(gate.fetch("armed_at", nil)) ? true : false
      end

      def gate_pending?(gate)
        gate.is_a?(Hash) && gate.fetch("state", DEFERRED_GATE_STATE_PENDING).to_s == DEFERRED_GATE_STATE_PENDING
      end

      def gate_deadline(now, max_wait_seconds)
        parsed = parse_time_or_nil(now)
        return nil unless parsed

        (parsed + max_wait_seconds.to_i).iso8601
      end

      # Short, honest label for the AgentTree row and log lines. A head-supplied label wins because
      # "pair review on the delivery PR" reads better in a tree than a truncated `gh` invocation.
      def deferred_gate_label(gate)
        return "a wait condition" unless gate.is_a?(Hash)

        label = present_string(gate.fetch("label", nil)) || present_string(gate.fetch("command", nil))
        return "a wait condition" unless label

        single_line = label.to_s.gsub(/\s+/, " ").strip
        return single_line if single_line.length <= GATE_LABEL_MAX_CHARS

        "#{single_line[0, GATE_LABEL_MAX_CHARS - 1].rstrip}…"
      end

      # Validation for one `after_agent_id` at spawn time. Returns a rejection, a deferral, or
      # "start now" when there is nothing left to wait for.
      def deferred_spawn_decision(state, after_agent_id:, failure_policy:)
        requested = present_string(after_agent_id)
        predecessor = find_agent(state, requested)
        unless predecessor
          return deferred_rejection("SpawnWorker cannot wait for #{requested} because that agent does not exist.", ["after_agent_not_found"])
        end
        unless predecessor.fetch("type", nil) == "worker"
          return deferred_rejection(
            "SpawnWorker can only wait for a worker; #{requested} is a #{predecessor.fetch("type", "record")}.",
            ["after_agent_is_not_worker"]
          )
        end

        chain = deferred_pending_chain(state, predecessor)
        if chain.fetch("cycle")
          return deferred_rejection(
            "SpawnWorker cannot wait for #{requested} because its queue already loops (#{chain.fetch("ids").join(" -> ")}).",
            ["deferred_after_agent_cycle"]
          )
        end
        chain_depth = chain.fetch("depth").to_i + 1
        if chain_depth > DEFERRED_WORKER_MAX_CHAIN_DEPTH
          return deferred_rejection(
            "SpawnWorker cannot wait for #{requested} because that would queue #{chain_depth} workers in a row; the limit is #{DEFERRED_WORKER_MAX_CHAIN_DEPTH}.",
            ["deferred_chain_too_deep"]
          )
        end

        status = predecessor.fetch("status", nil).to_s
        unless TERMINAL_AGENT_STATUSES.include?(status)
          return { "kind" => "defer", "predecessor" => deep_copy(predecessor), "chain_depth" => chain_depth }
        end
        # A worker whose turn was cut short by a transport failure is `errored` but not finished: it
        # can still be continued, so queueing work behind it is legitimate rather than a rejection.
        if status == "errored" && failure_policy != "run" && deferred_predecessor_can_still_finish?(predecessor)
          return { "kind" => "defer", "predecessor" => deep_copy(predecessor), "chain_depth" => chain_depth }
        end
        if status == "completed" || (status == "errored" && failure_policy == "run")
          return { "kind" => "start_now", "predecessor" => deep_copy(predecessor), "chain_depth" => chain_depth }
        end

        deferred_rejection(
          "SpawnWorker cannot wait for #{requested} because it already #{status == "killed" ? "was killed" : "errored"}. " \
            "Spawn the worker without after_agent_id, or set if_predecessor_fails to \"run\" when the follow-up work should happen anyway.",
          ["deferred_predecessor_already_#{status}"]
        )
      end

      # Whether an `errored` predecessor is worth waiting on. "Its turn died but its session is
      # live" is: reconciliation re-attaches and re-prompts that session by itself, so the chain
      # really does continue. "Its harness process is gone" is not: nothing in Meringue revives it
      # without a user prompt, so waiting means waiting on a human for an unbounded time. That is
      # exactly the silent wait a queued dependent must never sit in, so it is resolved by its
      # `if_predecessor_fails` policy instead.
      def deferred_predecessor_can_still_finish?(predecessor)
        worker_resumable_after_settle_failure?(predecessor) && !worker_harness_process_exited?(predecessor)
      end

      def deferred_rejection(message, errors)
        { "kind" => "reject", "message" => message, "errors" => errors }
      end

      # Walks the still-pending part of the chain above `agent`. Only queued/activating links count:
      # an already-activated dependency is history, not scheduled work.
      def deferred_pending_chain(state, agent)
        ids = []
        current = agent
        depth = 0
        while current
          id = current.fetch("id", nil)
          return { "cycle" => true, "depth" => depth, "ids" => ids + [id] } if ids.include?(id)

          ids << id
          break unless pending_deferred_worker?(current)

          next_id = deferred_worker_after_agent_id(current)
          break unless next_id

          depth += 1
          break if depth > DEFERRED_WORKER_MAX_CHAIN_DEPTH + 1

          current = find_agent(state, next_id)
        end
        { "cycle" => false, "depth" => depth, "ids" => ids }
      end

      # Records the dependent without starting anything. Called inside the SpawnWorker state
      # section, so it owns its own log line and save.
      def queue_deferred_worker(state, command_id:, command_type:, issue:, project:, prompt:, title:,
                                requested_workspace_path:, follow_up_of_agent_id:, predecessor:,
                                chain_depth:, failure_policy:, include_predecessor_result:, completion_continuation:,
                                rerouted_from_issue_id:, command_gate: nil, workspace_reuse_request: nil,
                                session_settings_override: {}, model_validation: nil,
                                workspace_mode: WORKSPACE_MODE_ISOLATED,
                                self_fixing_recovery: nil)
        now = timestamp
        agent_id = next_worker_id!(state, issue.fetch("id"))
        workspace = resolve_worker_workspace(
          project: project,
          issue: issue,
          requested_workspace_path: requested_workspace_path,
          preview_agent_id: agent_id,
          task_title: worker_display_title(title, issue),
          create: false,
          workspace_mode: workspace_mode,
          harness_provider: active_harness_provider(state)
        )
        return rejected_result(command_id, command_type, "Worker workspace is invalid.", workspace.fetch("errors")) unless workspace.fetch("errors").empty?

        # A queued worker is provisioned by a later command, so it needs a stable spawn command id
        # even when the caller did not supply one. Without it neither activation nor reservation
        # recovery could recognise this record and both would provision a second worker.
        spawn_command_id = present_string(command_id) || "deferred-#{agent_id}-#{SecureRandom.hex(4)}"
        agent = build_worker_reservation(
          agent_id: agent_id,
          issue: issue,
          project: project,
          workspace: workspace,
          provider: active_harness_provider(state),
          command_id: spawn_command_id,
          prompt: prompt,
          title: title,
          requested_workspace_path: requested_workspace_path,
          follow_up_of_agent_id: follow_up_of_agent_id,
          replace_agent_id: nil,
          after_agent_id: predecessor && predecessor.fetch("id"),
          completion_continuation: completion_continuation,
          session_settings_override: session_settings_override,
          model_validation: model_validation,
          workspace_reuse_request: workspace_reuse_request,
          workspace_mode: workspace_mode,
          self_fixing_recovery: self_fixing_recovery,
          now: now,
          harness_generation: state.fetch("metadata").fetch("harness_generation", 0).to_i
        )
        # A gate with no predecessor is live from the moment the worker is queued; a gate behind a
        # predecessor is only armed once that predecessor settles, so `gh pr view` is never polled
        # before the worker that opens the PR has finished.
        gate_record = command_gate && armed_deferred_gate(command_gate, now: predecessor ? nil : now)
        agent["harness_metadata"] = agent.fetch("harness_metadata").merge(
          "provisioning_state" => "deferred",
          "rerouted_from_issue_id" => rerouted_from_issue_id,
          "queue_command_id" => present_string(command_id),
          "deferred_spawn" => {
            "state" => DEFERRED_STATE_WAITING,
            "after_agent_id" => predecessor && predecessor.fetch("id"),
            "after_agent_issue_id" => predecessor && predecessor.fetch("issue_id", nil),
            "after_agent_title" => predecessor && (predecessor.fetch("harness_metadata", {}) || {}).fetch("title", nil),
            "if_predecessor_fails" => failure_policy,
            "include_predecessor_result" => include_predecessor_result,
            "chain_depth" => chain_depth,
            "queued_at" => now,
            "queued_prompt" => prompt.to_s,
            "command_gate" => gate_record
          }.compact
        ).compact
        state.fetch("agents") << agent
        issue.fetch("agent_ids") << agent_id unless issue.fetch("agent_ids").include?(agent_id)
        # Queued work is still live work. This matters when a completion head reopens an issue that
        # had just rolled up to completed before it placed the follow-up behind an external gate.
        issue["status"] = "working" unless issue.fetch("status", nil) == "killed"
        issue["updated_at"] = now
        project["status"] = "working" unless project.fetch("status", nil) == "killed"
        project["updated_at"] = now
        message = deferred_queue_message(agent)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent_id,
          level: "info",
          message: message,
          details: {
            "issue_id" => issue.fetch("id"),
            "project_id" => project.fetch("id"),
            "agent_id" => agent_id,
            "routing_action" => "queue_deferred_worker",
            "after_agent_id" => predecessor && predecessor.fetch("id"),
            "after_agent_status" => predecessor && predecessor.fetch("status", nil),
            "if_predecessor_fails" => failure_policy,
            "include_predecessor_result" => include_predecessor_result,
            "chain_depth" => chain_depth,
            "after_command" => gate_record && gate_record.fetch("command", nil),
            "after_command_label" => gate_record && gate_record.fetch("label", nil),
            "if_gate_expires" => gate_record && gate_record.fetch("if_gate_expires", nil),
            "title" => agent.fetch("harness_metadata", {}).fetch("title", nil),
            "workspace_mode" => agent.fetch("workspace_mode", WORKSPACE_MODE_ISOLATED),
            "effective_workspace_mode" => agent.fetch("effective_workspace_mode", nil)
          }.compact
        )
        touch_state!(state, now)
        store.save(state)
        accepted_result(command_id, command_type, agent_id, message, deep_copy(agent), log_ids)
      end

      # One-line summary for GetInfo output, so "what is P1-I1-W2" says what it is waiting on.
      def deferred_info_line(deferred)
        after = present_string(deferred.fetch("after_agent_id", nil))
        gate = deferred.fetch("command_gate", nil)
        gate = nil unless gate.is_a?(Hash)
        subject = [
          after ? "#{after} (#{deferred.fetch("after_agent_status", "unknown")})" : nil,
          gate ? "wait condition #{deferred_gate_label(gate)} (#{gate.fetch("state", DEFERRED_GATE_STATE_PENDING)})" : nil
        ].compact
        subject = ["an unknown agent"] if subject.empty?
        case deferred.fetch("state", nil).to_s
        when DEFERRED_STATE_WAITING
          "waiting on: #{subject.join(" and ")}; if it fails: " \
            "#{deferred.fetch("if_predecessor_fails", deferred_worker_default_failure_policy)}"
        when DEFERRED_STATE_ACTIVATING
          "starting now after: #{subject.join(" and ")}"
        when DEFERRED_STATE_CANCELLED
          "cancelled before starting: #{deferred.fetch("cancel_reason", "predecessor could not settle")} (#{subject.join(" and ")})"
        else
          "started after: #{subject.join(" and ")}"
        end
      end

      def deferred_queue_message(agent)
        deferred = deferred_spawn_metadata(agent)
        after_agent_id = present_string(deferred.fetch("after_agent_id", nil))
        gate = deferred.fetch("command_gate", nil)
        gate = nil unless gate.is_a?(Hash)
        conditions = [
          after_agent_id ? "#{after_agent_id} settles" : nil,
          gate ? "#{deferred_gate_label(gate)} passes" : nil
        ].compact
        conditions = ["its predecessor settles"] if conditions.empty?
        "Queued worker #{agent.fetch("id")} on #{agent.fetch("issue_id")} to start after #{conditions.join(" and ")}."
      end

      def activated_deferred_spawn_metadata(reserved_agent, now)
        deferred = deferred_spawn_metadata(reserved_agent)
        return nil if deferred.empty?

        deferred.merge("state" => DEFERRED_STATE_ACTIVATED, "started_at" => now)
      end

      # Handover is automatic prompt augmentation rather than something the head has to template:
      # the dependent's prompt is composed when it actually starts, so it carries the predecessor's
      # real final report. Heads can opt out with `include_predecessor_result: false`.
      def deferred_handover_prompt(prompt, predecessor, include_predecessor_result)
        return prompt.to_s unless include_predecessor_result && predecessor.is_a?(Hash)

        metadata = predecessor.fetch("harness_metadata", {}) || {}
        title = present_string(metadata.fetch("title", nil))
        status = present_string(predecessor.fetch("status", nil)) || "unknown"
        report = present_string(metadata.fetch("last_assistant_text", nil))
        body = [
          "Status when it settled: #{status}",
          present_string(predecessor.fetch("issue_id", nil)) ? "Issue: #{predecessor.fetch("issue_id")}" : nil,
          present_string(predecessor.fetch("workspace_branch", nil)) ? "Branch: #{predecessor.fetch("workspace_branch")}" : nil,
          "",
          report ? "Final report:" : "Final report: none was captured.",
          report,
          "",
          if status == "completed"
            "Use that as input for the work described above. Verify anything you rely on instead of assuming it is still true."
          else
            "That agent did not finish cleanly, so treat its output as partial and re-check its conclusions before relying on them."
          end
        ].compact.join("\n")
        header = "--- Handover from #{predecessor.fetch("id")}#{title ? " (#{title})" : ""} ---"
        [prompt.to_s.rstrip, "#{header}\n#{body}"].join("\n\n")
      end

      # The command gate's own handover. A script-gated worker gets the same treatment as an
      # agent-gated one: the thing it waited for hands over what it saw. `gh pr view ... --json
      # reviewDecision` output is exactly the context the follow-up worker needs, and
      # `include_predecessor_result: false` suppresses this block too.
      def deferred_gate_handover_prompt(prompt, gate, include_predecessor_result)
        return prompt.to_s unless include_predecessor_result && gate.is_a?(Hash)

        last = gate.fetch("last_check", nil)
        last = {} unless last.is_a?(Hash)
        output = present_string([last.fetch("stdout_tail", nil), last.fetch("stderr_tail", nil)].compact.join("\n"))
        state_line = case gate.fetch("state", nil).to_s
                     when DEFERRED_GATE_STATE_EXPIRED
                       "It never passed within its #{gate.fetch("max_wait_seconds", DEFERRED_WORKER_GATE_DEFAULT_MAX_WAIT_SECONDS)}s budget, " \
                         "and this worker was started anyway (if_gate_expires: \"run\"). Verify the condition yourself before relying on it."
                     when DEFERRED_GATE_STATE_UNAVAILABLE
                       "It could not be run (#{gate.fetch("last_problem", "the command could not be evaluated")}), " \
                         "and this worker was started anyway (if_gate_expires: \"run\"). Verify the condition yourself before relying on it."
                     else
                       "It passed, which is why this worker started."
                     end
        body = [
          "Command: #{gate.fetch("command", "(unknown)")}",
          "Checked #{gate.fetch("checks", 0).to_i} time(s); last exit status: #{last.fetch("exit_status", "unknown")}",
          state_line,
          "",
          output ? "Last output:" : "Last output: none was captured.",
          output ? truncate_gate_output(output) : nil
        ].compact.join("\n")
        header = "--- Wait condition: #{deferred_gate_label(gate)} ---"
        [prompt.to_s.rstrip, "#{header}\n#{body}"].join("\n\n")
      end

      def truncate_gate_output(text)
        value = text.to_s.strip
        return value if value.length <= DEFERRED_WORKER_GATE_OUTPUT_MAX_CHARS

        "#{value[0, DEFERRED_WORKER_GATE_OUTPUT_MAX_CHARS].rstrip}\n… [output truncated]"
      end
    end
  end
end
