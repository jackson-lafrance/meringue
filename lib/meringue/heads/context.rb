# frozen_string_literal: true

module Meringue
  module Heads
    class Context
      DEFAULT_KERNEL_COMMANDS_PATH = Meringue.root_path("docs", "head_agent_kernel_commands.md")
      ACTIVE_STATUSES = %w[queued working idle].freeze
      DISCOVERY_ALLOWED_COMMANDS = [
        "pwd",
        "ls",
        "find nearby project directories and .git folders",
        "rg project names, manifests, READMEs, and domain terms",
        "git rev-parse --show-toplevel",
        "git remote -v",
        "git status --short --branch",
        "read lightweight project files such as README.md, AGENTS.md, package.json, Gemfile, or pyproject.toml"
      ].freeze
      DISCOVERY_FORBIDDEN_COMMANDS = [
        "file edits or writes",
        "git checkout/switch/worktree/branch/pull/fetch/merge/rebase",
        "package installs or dependency upgrades",
        "generators, migrations, or formatters that write files",
        "production/staging, credential, database, or destructive commands"
      ].freeze

      ROUTING_ACTIVITY_LIMIT = 16
      ROUTING_CANDIDATE_LIMIT = 40
      ROUTING_TEXT_LIMIT = 2_000

      attr_reader :head_id, :user_message, :snapshot, :question_id, :selected_target,
                  :kernel_commands_path, :cwd, :state_path

      def initialize(head_id:, user_message:, snapshot:, question_id: nil, selected_target: nil,
                     kernel_commands_path: DEFAULT_KERNEL_COMMANDS_PATH, cwd: Dir.pwd,
                     state_path: State::Store.default_path)
        @head_id = head_id
        @user_message = user_message
        @snapshot = snapshot
        @question_id = question_id
        @selected_target = selected_target
        @kernel_commands_path = kernel_commands_path
        @cwd = File.expand_path(cwd)
        @state_path = File.expand_path(state_path)
      end

      def to_h
        to_prompt_h.merge("kernel_command_reference" => kernel_command_reference)
      end

      def to_prompt_h
        {
          "head_id" => head_id,
          "user_message" => user_message,
          "question_id" => question_id,
          "cwd" => cwd,
          "state_access" => state_access,
          "project_discovery" => project_discovery,
          "current_state_summary" => current_state_summary,
          "routing_context" => routing_context,
          "kernel_command_reference" => reference_metadata.merge(
            "appended_to_system_prompt" => true
          )
        }
      end

      def system_prompt
        <<~PROMPT
          You are a stateless Meringue head agent.
          Read the user message and return a HeadResult JSON object only.
          The prompt includes the Meringue state file path and read-only commands you may run when state details are necessary.
          Do not assume all state is embedded in the prompt; inspect only the parts of state you need.
          You may use tools to inspect local projects and git repositories before deciding, but discovery must be read-only and limited to routing/orchestration context.
          Do not investigate or answer the user's substantive task directly; create or reuse issues and spawn or prompt workers for investigation, implementation, and informational work.
          Meringue housekeeping is different: when the user asks for maintenance the kernel already owns (prune, recount, kill, clear, info, tree/state listings, theme, harness, or Pi session/default model and thinking settings), propose that user command yourself instead of creating an issue or spawning a worker. Follow the destructive-command confirmation rules in the reference below.
          Treat the supplied routing context as candidate evidence, not a conversation database. Classify whether this message starts a new goal, follows an existing issue, or answers an open question, then deliberately choose whether to prompt, follow up, or replace an existing worker.
          When routing_context.selected_target is present, it is explicit UI routing context: keep this message on its resolved issue. An agent selection resolves to that agent's owning issue; use the selected agent as a session-context hint, but still choose the appropriate healthy worker and PromptAgent mode through kernel commands. Never bypass head routing or prompt an agent from another issue.
          When questions are open, check routing_context.open_questions and routing_context.answer_inference first. If this message clearly answers exactly one open question, propose AnswerQuestion for that question id and route the work it unblocks in the same result. If several open questions are plausible, or the message is plainly a new goal, leave every question open and route normally or ask one clarifying question.
          When proposing AddProject, use the concise suggested product name from project_discovery when available. Preserve intentional capitalization exactly, and do not use a worktree suffix, repository path slug, or verbose product description as the name.
          Prefer a healthy existing worker session when its Pi or other harness history contains the context needed for the follow-up. Do not duplicate that harness history in Meringue state.
          An issue is the durable goal and a worker is one session step, so one goal that needs research and then implementation is one issue with two workers on it (issue_from_command on both, plus after_from_command and follow_up_of_command on the implementer), not two issues. Create a second issue only for a genuinely independent goal. Never write a worker prompt that polls Meringue state or sleeps waiting for another worker: the kernel owns that wait.
          When the user wants an outcome driven to completion rather than attempted once ("keep going until", "don't stop until", "this is critical, it has to actually land") and there is a finish line the kernel can measure by running a command, that is a goal loop: propose CreateGoal instead of a single one-shot worker. CreateGoal mints its own issue from a prompt (send prompt plus project_id, or project_from_command for a project this batch registers), so you never have to create an issue first, and the kernel spawns and judges the attempt workers itself. Urgency alone is not a goal loop: if nothing measurable defines done, route the work normally or ask one question about what done is measured by, rather than using a goal to buy ordinary work extra iterations.
          Do not mutate files, git state, dependencies, databases, remote services, or Meringue state directly.
          Propose kernel commands using the reference below.

          #{kernel_command_reference}
        PROMPT
      end

      def reference_metadata
        {
          "path" => kernel_commands_path,
          "bytes" => kernel_command_reference.bytesize,
          "lines" => kernel_command_reference.lines.count
        }
      end

      private

      def kernel_command_reference
        @kernel_command_reference ||= File.read(kernel_commands_path)
      rescue Errno::ENOENT
        raise ArgumentError, "Head kernel command reference not found: #{kernel_commands_path}"
      end

      def state_access
        {
          "state_path" => state_path,
          "read_only" => true,
          "guidance" => "The full Meringue state is intentionally not embedded. Read this file only when the user request requires current projects, issues, agents, questions, logs, counters, prior PR URLs, or a follow-up/refinement may depend on a head that was still routing when you spawned. Use only ids that actually appear in state; never invent future issue ids.",
          "suggested_commands" => [
            {
              "purpose" => "Read full JSON state when necessary.",
              "tool" => "read",
              "path" => state_path
            },
            {
              "purpose" => "Summarize projects, issues, agents, and open questions without printing full logs or harness metadata.",
              "tool" => "bash",
              "command" => state_summary_command
            }
          ]
        }
      end

      def current_state_summary
        {
          "project_count" => snapshot.fetch("projects", []).length,
          "issue_count" => snapshot.fetch("issues", []).length,
          "agent_count" => snapshot.fetch("agents", []).length,
          "open_question_count" => unresolved_questions.length,
          "open_question_ids" => unresolved_questions.map { |question| question.fetch("id", nil) }.compact,
          "active_head_count" => active_heads.length,
          "active_worker_count" => active_workers.length,
          "status_counts" => status_counts,
          "registered_projects" => registered_projects
        }
      end

      def routing_context
        context = {
          "purpose" => "Stateless routing hints assembled from existing issues, logs, and inspectable harness session metadata. These are not a separate conversation history.",
          "explicit_references" => explicit_references,
          "question_being_answered" => question_being_answered,
          "open_questions" => open_question_records,
          "answer_inference" => answer_inference,
          "issue_candidates" => routing_issue_candidates,
          "worker_candidates" => routing_worker_candidates,
          "recent_activity" => recent_routing_activity,
          "decision_rules" => [
            "When selected_target is present, route within its resolved issue. An agent selection identifies its owning issue and is a preferred session-context hint, not permission to bypass the head or force an unhealthy agent.",
            "Do not create or prompt work on another issue while selected_target is active. If the message explicitly conflicts with the selected issue, ask the user to clear/change the selection rather than silently ignoring it.",
            "Explicit project, issue, worker, or question ids in the user message take precedence when they are compatible with selected_target; otherwise surface the conflict instead of guessing.",
            "A refinement, correction, question about findings, or next step for an existing durable goal should reuse that issue.",
            "If a refinement arrives while another head is still routing the original goal, read current state before returning. When that already-visible head has since created the issue for this goal, reuse the real issue_id from state; do not predict a future issue id, and use issue_from_command only for issues your own HeadResult creates.",
            "Prefer PromptAgent when a healthy worker on that issue has useful persisted harness context; do not spawn a new worker merely because this is a new user message.",
            "Use steer for an urgent correction to active work, follow_up for related work that should run after the active turn, and normal for a settled resumable session. Read the target's is_streaming/recommended_prompt_mode instead of defaulting to normal; a normal prompt to a mid-turn session is still accepted, but the kernel delivers it as a follow-up.",
            "Spawn a follow-up worker on the same issue only when no suitable session is resumable, work should be independent or parallel, context is known to be over 50%, or a delivered workspace should remain immutable.",
            "One goal that needs several steps is one issue with several workers. A research step and the implementation step that consumes its findings belong on the same issue: one CreateIssue, then one SpawnWorker per step bound with issue_from_command, with after_from_command for the ordering and follow_up_of_command (or follow_up_of_agent_id: \"@<command_id>\") for the visible lineage on the later step. Separate PRs or a findings-only step never justify a second issue.",
            "Never write a worker prompt that waits on another worker by polling Meringue state, sleeping between checks, or budgeting hours for a predecessor to settle. The kernel owns that wait through after_agent_id/after_from_command and hands over the predecessor's final report itself.",
            "Use replace_agent_id only when the old worker is stale, unhealthy, pursuing the wrong approach, or must stop before a successor continues. Replacement starts the successor before killing the old session.",
            "replace_agent_id (and replace_agent_from_command) cannot be combined with follow_up_of_agent_id or after_agent_id on one SpawnWorker. The kernel rejects that payload and spawns nothing, so pick exactly one: replace to take over from a live session, or follow_up/after to continue behind it. follow_up_of_agent_id together with after_agent_id is still allowed.",
            "To retry a worker that errored, spawn one new worker on the same issue with follow_up_of_agent_id naming the errored worker and no replace_agent_id. A worker whose harness_session_id is null never started a session, so there is no session to replace, and PromptAgent has nothing to prompt.",
            "PromptAgent targets a worker. Retrying a head is a user action the kernel performs itself, so never propose PromptAgent on a head id; that command is rejected whatever status the head is in, including a head left blocked with part of its request unrouted.",
            "When your own user message says it is a retry of an earlier head, it lists that head's already-applied commands and the ones that never landed. Reuse the records it names instead of creating them again, route only the part of the request that is still unrouted, and fix what the kernel objected to rather than re-proposing the same command.",
            "Use after_agent_id (or after_from_command for a worker this batch spawns) when the next step must not start until another worker settles, such as research then implementation. The kernel queues that worker, starts it when its predecessor completes, and hands over the predecessor's final report. It cancels it with a warning when the predecessor errors, unless if_predecessor_fails is \"run\". Queueing a step this way does not make it a separate goal: keep it on the same issue.",
            "Create a new issue only for a genuinely distinct durable goal that would still stand on its own if the first goal were dropped, such as a missing capability the request revealed. Ask a clarifying question instead of guessing between plausible issues or workers.",
            "A request to drive an outcome to completion (keep going until X, don't stop until Y, this is critical and must actually land) plus a finish line the kernel can measure by running a command is a goal loop, not a one-shot worker: propose CreateGoal. Use its prompt form (prompt plus project_id, or project_from_command) when no issue represents the outcome yet, so no CreateIssue is needed, and do not add a SpawnWorker for the same issue: the kernel spawns and judges every attempt itself. Attach the goal to an existing issue with issue_id when one already represents that outcome.",
            "Insistence without a measurable finish line is still ordinary work. Route it to a worker (or ask one question about what done is measured by) instead of opening a goal loop; goal budgets are clamped, so a goal is not a way to give an ordinary task extra iterations.",
            "When this message answers an open question, pair AnswerQuestion with the routing command that acts on the answer in the same HeadResult. Closing a question without routing the unblocked work drops the user's request."
          ]
        }
        target = selected_target_context
        context["selected_target"] = target if target
        context
      end

      def selected_target_context
        return @selected_target_context if defined?(@selected_target_context)

        raw = selected_target_hash
        selected_id = (raw["selected_id"] || raw[:selected_id] || raw["id"] || raw[:id]).to_s.strip
        selected_record = unless selected_id.empty?
                            snapshot_records("agents").find { |agent| agent.fetch("id", nil).to_s == selected_id } ||
                              snapshot_records("issues").find { |issue| issue.fetch("id", nil).to_s == selected_id }
                          end
        issue_id = if selected_record && issue_record?(selected_record)
                     selected_record.fetch("id", nil)
                   elsif selected_record
                     selected_record.fetch("issue_id", nil)
                   else
                     raw["issue_id"] || raw[:issue_id]
                   end
        issue = snapshot_records("issues").find { |candidate| candidate.fetch("id", nil).to_s == issue_id.to_s }
        return @selected_target_context = nil unless issue

        agent = selected_record if selected_record && selected_record.fetch("type", nil).to_s != ""
        selected_agent_id = agent&.fetch("id", nil) || raw["selected_agent_id"] || raw[:selected_agent_id]
        selected_agent_id = nil unless present_value?(selected_agent_id)
        selected_agent_type = agent&.fetch("type", nil) || raw["selected_agent_type"] || raw[:selected_agent_type]
        @selected_target_context = {
          "selected_id" => selected_id.empty? ? issue.fetch("id") : selected_id,
          "selected_type" => selected_agent_id ? "agent" : "issue",
          "issue_id" => issue.fetch("id"),
          "project_id" => issue.fetch("project_id", nil),
          "issue_title" => issue.fetch("title", nil),
          "selected_agent_id" => selected_agent_id,
          "selected_agent_type" => selected_agent_type,
          "selected_agent_title" => selected_agent_title(agent),
          "instruction" => "Route this message within #{issue.fetch("id")}. A selected agent resolves to this owning issue; keep head-agent routing and choose the appropriate worker/session action on the issue."
        }.compact
      end

      # Recovered heads read their selection back out of persisted state, so the
      # value can be the canonical Hash, a bare id String, or missing entirely.
      # Normalize instead of assuming one shape.
      def selected_target_hash
        case selected_target
        when Hash then selected_target
        when String, Symbol then { "selected_id" => selected_target.to_s }
        else {}
        end
      end

      def selected_agent_title(agent)
        metadata = agent.is_a?(Hash) ? agent.fetch("harness_metadata", nil) : nil
        metadata.is_a?(Hash) ? metadata.fetch("title", nil) : nil
      end

      def snapshot_records(key)
        Array(snapshot.is_a?(Hash) ? snapshot.fetch(key, []) : []).select { |record| record.is_a?(Hash) }
      end

      # Local shape check avoids a dependency from the head layer back into the
      # TUI's AgentTree helpers.
      def issue_record?(record)
        record.is_a?(Hash) && record.key?("project_id") && record.key?("agent_ids")
      end

      def explicit_references
        mentioned_ids = user_message.to_s.scan(Meringue::Ids::RECORD_ID_SCAN_PATTERN).map(&:upcase).uniq
        resolved_ids = mentioned_ids.flat_map { |id| [id, *parent_ids_for(id)] }.uniq
        known_state_ids = (
          snapshot.fetch("projects", []).map { |record| record["id"] } +
          snapshot.fetch("issues", []).map { |record| record["id"] } +
          snapshot.fetch("agents", []).map { |record| record["id"] } +
          snapshot.fetch("questions", []).map { |record| record["id"] }
        ).compact
        {
          "mentioned_ids" => mentioned_ids,
          "known_ids" => resolved_ids.select { |id| known_state_ids.include?(id) },
          "unknown_ids" => mentioned_ids.reject { |id| known_state_ids.include?(id) }
        }
      end

      def parent_ids_for(id)
        worker_match = id.match(/\A(P\d+)-(I\d+)-W\d+\z/)
        return [worker_match[1], "#{worker_match[1]}-#{worker_match[2]}"] if worker_match

        issue_match = id.match(/\A(P\d+)-I\d+\z/)
        issue_match ? [issue_match[1]] : []
      end

      # Populated on two paths: the kernel answered a question and spawned this head for it
      # (question_id is set), or the user message itself names exactly one open question, which is
      # the "ANSWERING Q4 ..." case that used to leave this field null.
      def question_being_answered
        record = question_id ? snapshot_question(question_id) : nil
        inference_source = record ? "answer_command" : nil

        unless record
          referenced = referenced_open_question_ids
          if referenced.length == 1
            record = snapshot_question(referenced.first)
            inference_source = "user_message_reference"
          end
        end
        return nil unless record

        record
          .slice("id", "head_id", "project_id", "issue_id", "question", "context", "status", "answer", "created_at", "updated_at")
          .merge(
            "inference_source" => inference_source,
            "original_user_message" => original_user_message_for(record),
            "instruction" => question_answer_instruction(record)
          ).compact
      end

      def question_answer_instruction(record)
        if record.fetch("status", nil) == "answered"
          "The kernel already recorded this answer and closed the question. Do not ask it again and do not propose AnswerQuestion for it; route the work the answer unblocks."
        else
          "This message appears to answer this open question. Propose AnswerQuestion for it with the user's answer, then route the work it unblocks in the same HeadResult."
        end
      end

      def snapshot_question(id)
        Meringue::Ids.find_record(snapshot.fetch("questions", []), id)
      end

      # Full open-question records, not just a count, so a head can recognize a free-form reply as
      # an answer without the user running /answer.
      def open_question_records
        referenced = referenced_open_question_ids
        unresolved_questions.map do |question|
          {
            "id" => question.fetch("id", nil),
            "head_id" => question.fetch("head_id", nil),
            "project_id" => question.fetch("project_id", nil),
            "issue_id" => question.fetch("issue_id", nil),
            "question" => bounded_text(question.fetch("question", nil)),
            "context" => bounded_text(question.fetch("context", nil)),
            "status" => question.fetch("status", nil),
            "original_user_message" => original_user_message_for(question),
            "explicitly_referenced_in_user_message" => referenced.include?(question.fetch("id", nil)),
            "created_at" => question.fetch("created_at", nil),
            "updated_at" => question.fetch("updated_at", nil)
          }.compact
        end
      end

      def answer_inference
        candidates = open_question_records
        referenced = referenced_open_question_ids
        {
          "purpose" => "Decide whether this user message answers an open question even though it did not use the /answer command.",
          "open_question_ids" => candidates.map { |question| question.fetch("id", nil) }.compact,
          "explicitly_referenced_question_ids" => referenced,
          "single_referenced_question_id" => referenced.length == 1 ? referenced.first : nil,
          "only_open_question_id" => candidates.length == 1 ? candidates.first.fetch("id", nil) : nil,
          "ambiguous" => candidates.length > 1 && referenced.length != 1,
          "rules" => [
            "If the message clearly responds to exactly one open question, treat it exactly as if the user had run /answer: propose AnswerQuestion with that question id and the user's message as the answer.",
            "An explicit mention such as \"answering Q4\", \"re: Q4\", \"for the question above\", or a direct restatement of that question's subject is a strong signal.",
            "Always pair AnswerQuestion with the command that acts on the answer in the same HeadResult: reuse the question's issue_id/project_id when it still represents the goal, prompt the healthiest existing worker on that issue, and create or spawn only when nothing suitable exists.",
            "Never propose AnswerQuestion alone. A closed question with no routing or ModifyIssue command silently drops the user's request.",
            "If several open questions are plausible, do not guess. Leave them open and either route the message as its own request or ask one clarifying question that names the candidate question ids.",
            "If the message is plainly a new goal, an unrelated request, or a question about status, leave every open question open and route normally.",
            "Do not re-ask a question that this message answers, and do not answer a question the user only mentioned in passing."
          ]
        }
      end

      def referenced_open_question_ids
        open_ids = unresolved_questions.map { |question| question.fetch("id", nil) }.compact
        explicit_references.fetch("mentioned_ids").select { |id| open_ids.include?(id) }
      end

      def original_user_message_for(question)
        stored = bounded_text(question.fetch("original_user_message", nil))
        return stored if stored

        head = snapshot.fetch("agents", []).find do |agent|
          agent.fetch("type", nil) == "head" && agent.fetch("id", nil) == question.fetch("head_id", nil)
        end
        bounded_text((head&.fetch("harness_metadata", nil) || {}).dig("head_request", "user_message"))
      end

      def routing_issue_candidates
        routing_candidates(snapshot.fetch("issues", [])).map do |issue|
          workers = workers_for_issue(issue.fetch("id", nil))
          {
            "id" => issue.fetch("id", nil),
            "project_id" => issue.fetch("project_id", nil),
            "parent_issue_id" => issue.fetch("parent_issue_id", nil),
            "title" => issue.fetch("title", nil),
            "description" => bounded_text(issue.fetch("description", nil)),
            "status" => issue.fetch("status", nil),
            "agent_ids" => workers.map { |worker| worker.fetch("id", nil) },
            "latest_agent_id" => workers.max_by { |worker| routing_sort_key(worker) }&.fetch("id", nil),
            "has_delivery_pull_request" => issue_delivery?(issue),
            "updated_at" => issue.fetch("updated_at", nil)
          }.compact
        end
      end

      def routing_worker_candidates
        workers = snapshot.fetch("agents", []).select { |agent| agent.fetch("type", nil) == "worker" }
        routing_candidates(workers).map do |agent|
          metadata = agent.fetch("harness_metadata", {}) || {}
          streaming = !!metadata.fetch("is_streaming", false)
          session_available = present_value?(agent.fetch("harness_session_id", nil)) ||
            present_value?(agent.fetch("harness_session_file", nil)) || present_value?(agent.fetch("pid", nil))
          {
            "id" => agent.fetch("id", nil),
            "project_id" => agent.fetch("project_id", nil),
            "issue_id" => agent.fetch("issue_id", nil),
            "title" => metadata.fetch("title", nil),
            "status" => agent.fetch("status", nil),
            "harness" => agent.fetch("harness", nil),
            "harness_session_id" => agent.fetch("harness_session_id", nil),
            "harness_session_file" => agent.fetch("harness_session_file", nil),
            "is_streaming" => streaming,
            "session_available" => session_available,
            "resumable" => session_available && !terminal_for_prompting?(agent),
            "stopped_without_finishing" => stopped_without_finishing?(agent) || nil,
            # Prompting this worker cannot replay its session; the kernel answers such a prompt by
            # continuing the work in a fresh session on the same worktree, which is a new worker id.
            "session_unreplayable" => session_unreplayable?(agent) || nil,
            "status_reason" => metadata.fetch("status_reason", nil),
            "supported_prompt_modes_now" => supported_prompt_modes(agent, streaming: streaming, session_available: session_available),
            "recommended_prompt_mode" => recommended_prompt_mode(agent, streaming: streaming, session_available: session_available),
            "prompt_mode_note" => prompt_mode_note(agent, streaming: streaming, session_available: session_available),
            "prompt_count" => metadata.fetch("prompt_count", 0).to_i,
            "last_prompt_mode" => metadata.fetch("last_prompt_mode", nil),
            "context_utilization" => context_utilization(metadata),
            "last_result" => bounded_text(metadata.fetch("last_assistant_text", nil)),
            "workspace_branch" => agent.fetch("workspace_branch", nil),
            "has_delivery_pull_request" => issue_delivery?(issue_for_agent(agent)),
            "follow_up_of_agent_id" => agent.fetch("follow_up_of_agent_id", nil),
            "replaces_agent_id" => agent.fetch("replaces_agent_id", nil),
            "replaced_by_agent_id" => agent.fetch("replaced_by_agent_id", nil),
            "after_agent_id" => agent.fetch("after_agent_id", nil),
            "deferred_spawn" => deferred_spawn_summary(metadata),
            "created_at" => agent.fetch("created_at", nil),
            "updated_at" => agent.fetch("updated_at", nil)
          }.compact
        end
      end

      # Compact view of a queued-after dependency so a head can see that a worker exists but has not
      # started, and who it is waiting for, without reading the whole harness metadata blob.
      def deferred_spawn_summary(metadata)
        deferred = metadata.is_a?(Hash) ? metadata.fetch("deferred_spawn", nil) : nil
        return nil unless deferred.is_a?(Hash)

        deferred.slice(
          "state", "after_agent_id", "after_agent_issue_id", "if_predecessor_fails",
          "include_predecessor_result", "chain_depth", "queued_at"
        ).compact
      end

      def routing_candidates(records)
        sorted = records.sort_by { |record| routing_sort_key(record) }.reverse
        target = selected_target_context || {}
        referenced = explicit_references.fetch("known_ids") + [
          target["selected_id"], target["issue_id"], target["project_id"], target["selected_agent_id"]
        ].compact
        explicit_records = sorted.select { |record| referenced.include?(record.fetch("id", nil)) }
        (explicit_records + sorted.first(ROUTING_CANDIDATE_LIMIT)).uniq { |record| record.fetch("id", nil) }
      end

      def recent_routing_activity
        snapshot.fetch("logs", []).last(ROUTING_ACTIVITY_LIMIT).map do |log|
          {
            "id" => log.fetch("id", nil),
            "timestamp" => log.fetch("timestamp", nil),
            "source_type" => log.fetch("source_type", nil),
            "source_id" => log.fetch("source_id", nil),
            "level" => log.fetch("level", nil),
            "message" => bounded_text(log.fetch("message", nil)),
            "routing" => routing_log_details(log.fetch("details", nil))
          }.compact
        end
      end

      def routing_log_details(details)
        return nil unless details.is_a?(Hash)

        details.slice(
          "head_id", "question_id", "project_id", "issue_id", "agent_id", "target_id",
          "selected_target_id", "selected_target_type", "mode", "routing_action",
          "follow_up_of_agent_id", "replaces_agent_id", "replaced_by_agent_id", "after_agent_id"
        ).compact
      end

      def workers_for_issue(issue_id)
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "worker" && agent.fetch("issue_id", nil) == issue_id
        end
      end

      def issue_for_agent(agent)
        snapshot.fetch("issues", []).find { |issue| issue.fetch("id", nil) == agent.fetch("issue_id", nil) }
      end

      def issue_delivery?(issue)
        return false unless issue.is_a?(Hash)

        present_value?(issue.fetch("delivery_pull_request", nil)) || Array(issue.fetch("delivery_pull_requests", [])).any?
      end

      # A worker that errored because its turn was cut short by a transport failure (a dropped
      # wifi connection is the common case) still owns a resumable session, so prompting it to
      # continue is the right routing choice. Every other errored or killed worker is terminal.
      def stopped_without_finishing?(agent)
        return false unless agent.fetch("status", nil) == "errored"

        metadata = agent.fetch("harness_metadata", {}) || {}
        metadata.fetch("settle_failure", nil).is_a?(Hash)
      end

      def terminal_for_prompting?(agent)
        return false unless %w[killed errored].include?(agent.fetch("status", nil))

        !stopped_without_finishing?(agent)
      end

      # The model provider refused to replay this worker's saved transcript, so no resume can
      # recover it. The work itself is not lost: its worktree and branch are intact.
      def session_unreplayable?(agent)
        metadata = agent.fetch("harness_metadata", {}) || {}
        failure = metadata.fetch("settle_failure", nil)
        return false unless failure.is_a?(Hash)

        failure.fetch("kind", nil).to_s == "unreplayable_session"
      end

      def supported_prompt_modes(agent, streaming:, session_available:)
        return [] unless session_available
        return [] if terminal_for_prompting?(agent)

        if streaming
          agent.fetch("harness", nil) == "pi" ? %w[steer follow_up] : []
        else
          ["normal"]
        end
      end

      def recommended_prompt_mode(agent, streaming:, session_available:)
        modes = supported_prompt_modes(agent, streaming: streaming, session_available: session_available)
        return nil if modes.empty?

        streaming ? "follow_up" : "normal"
      end

      # Says out loud what happens to the mode a head is most likely to pick by default, so a
      # mid-turn session reads as "choose deliberately" instead of "do not prompt".
      def prompt_mode_note(agent, streaming:, session_available:)
        return nil unless streaming
        return nil if supported_prompt_modes(agent, streaming: streaming, session_available: session_available).empty?

        "This session is mid-turn. Use steer to interrupt it or follow_up to run after it; " \
          "a normal prompt is accepted but the kernel delivers it as a follow-up."
      end

      def context_utilization(metadata)
        value = metadata.fetch("context_utilization", nil) || metadata.dig("pi_state", "contextUtilization")
        value&.to_f
      end

      def routing_sort_key(record)
        [record.fetch("updated_at", "").to_s, record.fetch("created_at", "").to_s, record.fetch("id", "").to_s]
      end

      def bounded_text(value)
        text = value.to_s.strip
        return nil if text.empty?
        return text if text.length <= ROUTING_TEXT_LIMIT

        "#{text[0, ROUTING_TEXT_LIMIT]}…"
      end

      def present_value?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def state_summary_command
        <<~COMMAND.strip
          ruby -rjson -e 's=JSON.parse(File.read(ARGV.fetch(0))); puts JSON.pretty_generate({projects:s.fetch("projects",[]).map{|p|p.slice("id","name","root_path","status")}, issues:s.fetch("issues",[]).map{|i|i.slice("id","project_id","title","status","agent_ids")}, agents:s.fetch("agents",[]).map{|a|a.slice("id","type","status","project_id","issue_id","workspace_path","workspace_branch","harness")}, open_questions:s.fetch("questions",[]).select{|q|q["status"]=="open"}.map{|q|q.slice("id","head_id","project_id","issue_id","question","status")}, counters:s.fetch("counters",{})})' #{state_path.inspect}
        COMMAND
      end

      def active_heads
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "head" && ACTIVE_STATUSES.include?(agent.fetch("status", nil))
        end
      end

      def active_workers
        snapshot.fetch("agents", []).select do |agent|
          agent.fetch("type", nil) == "worker" && ACTIVE_STATUSES.include?(agent.fetch("status", nil))
        end
      end

      def unresolved_questions
        snapshot.fetch("questions", []).select do |question|
          question.fetch("status", nil) == "open"
        end
      end

      def project_discovery
        {
          "responsibility" => "The head discovers local projects and proposes AddProject when needed; the kernel only validates and mutates state.",
          "starting_points" => discovery_starting_points,
          "registered_projects" => registered_projects,
          "allowed_read_only_discovery" => DISCOVERY_ALLOWED_COMMANDS,
          "forbidden_discovery" => DISCOVERY_FORBIDDEN_COMMANDS,
          "current_directory" => current_directory_metadata,
          "candidate_search_roots" => candidate_search_roots,
          "decision_rules" => [
            "Prefer a registered project when the id, name, root_path, git root, or remote clearly matches the request.",
            "For phrases like this project, current project, here, or this repo, prefer the current_directory.git_root when present; otherwise use cwd.",
            "If the preferred local repository is not registered, propose AddProject with its absolute root before CreateIssue or SpawnWorker.",
            "When proposing AddProject, use current_directory.suggested_project_name when available. Prefer the concise product name from the repository's README heading, preserve its intentional capitalization exactly, and never use a worktree suffix, path slug, or verbose description as the project name. Omit name only when no reliable product name is available.",
            "A project name never contains a lifecycle status. projects[].status is rendered separately, so propose \"Meringue\", never \"Meringue working\"; the same applies to ModifyProject, which is the only command that renames a project. The kernel strips a trailing status word anyway.",
            "Before proposing CreateIssue, inspect existing issues in the chosen project. If the prompt is a follow-up, refinement, or next step for an existing issue, reuse that issue and propose SpawnWorker only.",
            "Do not investigate or answer substantive task content yourself. Route implementation, investigation, and informational work through CreateIssue/SpawnWorker or PromptAgent as appropriate.",
            "Use the HeadResult summary to describe routing decisions, not to deliver the worker's substantive answer.",
            "Do not create nested/subissues for ordinary follow-up prompts; keep parent_issue_id null unless the user explicitly asks for a child issue hierarchy.",
            "Always include a short action-oriented title in SpawnWorker payloads so workers render clearly under their issue in the AgentTree.",
            "When chaining AddProject with CreateIssue and SpawnWorker in one HeadResult, read state counters when necessary and compute the future project id from counters.projects or the max existing P<number>.",
            "Never predict the id of an issue your own HeadResult creates. Give the CreateIssue command a command_id and set SpawnWorker.issue_from_command to that command_id (or its 0-based index), or set issue_id to \"@<command_id>\"; the kernel resolves it to the issue it actually created. Use a real issue_id only for an issue that already exists in supplied or freshly read current state, and use project_from_command the same way for a project this batch registers.",
            "One batch may mix targets: workers bound with issue_from_command to issues this batch creates plus workers with a real issue_id for issues that already exist. Every issue this batch creates must get at least one worker of its own in the same batch; otherwise the kernel treats a worker aimed at another issue as a mis-target and reroutes or rejects it. At least one is a floor, not a cap: two workers on one created issue (researcher, then implementer queued with after_from_command and linked with follow_up_of_command) is a supported shape. To create an issue for later while working only on an existing issue, mark that worker with a real existing follow_up_of_agent_id, replace_agent_id, or existing_issue: true.",
            "If the app was launched outside the target project, use registered projects and candidate_search_roots to inspect likely local repositories by name/path before choosing.",
            "Ask a clarifying question when multiple repositories are plausible."
          ]
        }
      end

      def registered_projects
        snapshot.fetch("projects", []).map do |project|
          {
            "id" => project.fetch("id", nil),
            "name" => project.fetch("name", nil),
            "root_path" => project.fetch("root_path", nil),
            "status" => project.fetch("status", nil)
          }
        end
      end

      def current_directory_metadata
        git_root = nearest_git_root(cwd)
        default_root = git_root || cwd
        suggested_project_name = ProjectNaming.name_for(default_root)
        {
          "cwd" => cwd,
          "git_root" => git_root,
          "default_project_root" => default_root,
          "default_project_name" => suggested_project_name,
          "suggested_project_name" => suggested_project_name,
          "registered_project_id" => registered_project_id_for(default_root),
          "should_propose_add_project_for_current_directory" => registered_project_id_for(default_root).nil?
        }
      end

      def candidate_search_roots
        env_roots = ENV.fetch("MERINGUE_PROJECT_ROOTS", "").split(File::PATH_SEPARATOR)
        common_roots = [
          "~/slaade/Projects",
          "~/Projects",
          "~/Developer",
          "~/code",
          "~/src"
        ]

        (discovery_starting_points + env_roots + common_roots)
          .compact
          .map(&:to_s)
          .reject(&:empty?)
          .map { |path| File.expand_path(path) }
          .select { |path| Dir.exist?(path) }
          .uniq
      end

      def registered_project_id_for(path)
        expanded_path = File.expand_path(path.to_s)
        snapshot.fetch("projects", []).find do |project|
          root_path = project.fetch("root_path", nil).to_s
          next false if root_path.empty?

          File.expand_path(root_path) == expanded_path
        end&.fetch("id", nil)
      end

      def nearest_git_root(path)
        current = File.expand_path(path.to_s)

        loop do
          return current if File.exist?(File.join(current, ".git"))

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def discovery_starting_points
        ([cwd, nearest_git_root(cwd)] + snapshot.fetch("projects", []).map { |project| project.fetch("root_path", nil) })
          .compact
          .map(&:to_s)
          .reject(&:empty?)
          .uniq
      end

      def status_counts
        snapshot.fetch("agents", []).each_with_object(Hash.new(0)) do |agent, counts|
          counts[agent.fetch("status", "unknown")] += 1
        end
      end
    end
  end
end
