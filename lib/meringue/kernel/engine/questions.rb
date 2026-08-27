# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # GetInfo, and the question lifecycle: asking, answering, dismissing, and clearing state.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def get_info(command_id, command_type, payload)
        target_id = present_string(value_at(payload, "target_id", "TargetID", "targetId", "id"))
        return rejected_result(command_id, command_type, "Info was not loaded.", ["target_id is required"]) unless target_id

        state = normalized_state
        kind, record = %w[agent issue project question goal].filter_map do |candidate_kind|
          found = case candidate_kind
                  when "agent" then find_agent(state, target_id)
                  when "issue" then find_issue(state, target_id)
                  when "project" then find_project(state, target_id)
                  when "goal" then find_goal(state, target_id)
                  else find_question(state, target_id)
                  end
          [candidate_kind, found] if found
        end.first
        unless record
          return rejected_result(command_id, command_type, "#{target_id} does not exist.", ["target_not_found"])
        end

        info = {
          "kind" => kind,
          "id" => record.fetch("id", target_id),
          "record" => deep_copy(record),
          "recent_logs" => state.fetch("logs").select { |log| log.fetch("source_id", nil) == target_id }
                                .last(5).map { |log| log.slice("id", "timestamp", "level", "message") }
        }
        info["issues"] = state.fetch("issues").select { |issue| issue.fetch("project_id", nil) == target_id }
                              .map { |issue| issue.slice("id", "title", "status") } if kind == "project"
        info["agents"] = state.fetch("agents").select { |agent| agent.fetch("issue_id", nil) == target_id }
                              .map { |agent| agent.slice("id", "type", "status") } if kind == "issue"
        if kind == "agent" && record.fetch("type", nil) == "worker"
          deferred = deferred_spawn_metadata(record)
          unless deferred.empty?
            predecessor = find_agent(state, deferred_worker_after_agent_id(record))
            info["deferred_spawn"] = deep_copy(deferred).merge(
              "after_agent_status" => predecessor ? predecessor.fetch("status", nil) : "missing"
            ).compact
          end
          dependents = waiting_deferred_dependents(state, [record.fetch("id")])
          info["waiting_dependent_agent_ids"] = dependents.map { |dependent| dependent.fetch("id") } if dependents.any?
          provisioning = worker_provisioning_info(record)
          info["provisioning"] = provisioning if provisioning
        end
        if kind == "issue"
          info["goals"] = goals_for_issue_ids(state, [record.fetch("id", target_id)]).map { |goal| goal_status_summary(goal) }
        end
        info["goal_summary"] = goal_status_summary(record) if kind == "goal"

        accepted_result(command_id, command_type, record.fetch("id", target_id), "Loaded #{kind} #{target_id}.", info, [])
      end

      def answer_question(command_id, command_type, payload)
        record_question_answer(command_id, command_type, payload).fetch("result")
      end

      def record_question_answer(command_id, command_type, payload)
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        answer = value_at(payload, "answer", "Answer")
        errors = []

        errors << "question_id is required" if blank?(question_id)
        errors << "answer is required" if blank?(answer)
        unless errors.empty?
          return { "result" => rejected_result(command_id, command_type, "Question was not answered.", errors), "recorded" => false }
        end

        state = normalized_state
        question = find_question(state, question_id)
        unless question
          return {
            "result" => rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"]),
            "recorded" => false
          }
        end

        if question.fetch("status", nil) == "answered" && question.fetch("answer", nil).to_s == answer.to_s
          return {
            "result" => accepted_result(
              command_id,
              command_type,
              question.fetch("id"),
              "Question #{question.fetch("id")} already records this answer.",
              deep_copy(question),
              []
            ),
            "question" => deep_copy(question),
            "recorded" => false
          }
        end

        # Dismissing is a decision not to answer. Accepting an answer afterwards silently
        # flipped the record back to `answered` and re-opened routing for work the user had
        # already waved off, so it is rejected the way `DismissQuestion` rejects a closed
        # question. Re-answering an *answered* question stays allowed: that is a correction.
        if question.fetch("status", nil) == "dismissed"
          return {
            "result" => rejected_result(
              command_id,
              command_type,
              "Question #{question.fetch("id")} was dismissed, so it cannot be answered. " \
                "Send the instruction as a normal message instead.",
              ["question_not_open"]
            ),
            "question" => deep_copy(question),
            "recorded" => false
          }
        end

        now = timestamp
        question["status"] = "answered"
        question["answer"] = answer.to_s
        question["answered_at"] = now
        question["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: question.fetch("id"),
          level: "info",
          message: "Answered question #{question.fetch("id")}.",
          details: {
            "head_id" => question.fetch("head_id", nil),
            "project_id" => question.fetch("project_id", nil),
            "issue_id" => question.fetch("issue_id", nil),
            "question_id" => question.fetch("id"),
            "answer" => answer.to_s,
            "routing_action" => "answer_question"
          }.compact
        )
        touch_state!(state, now)
        store.save(state)

        {
          "result" => accepted_result(
            command_id,
            command_type,
            question.fetch("id"),
            "Answered question #{question.fetch("id")}.",
            deep_copy(question),
            log_ids
          ),
          "question" => deep_copy(question),
          "recorded" => true
        }
      end

      def dismiss_question(command_id, command_type, payload)
        question_id = value_at(payload, "question_id", "QuestionID", "questionId")
        errors = []

        errors << "question_id is required" if blank?(question_id)
        return rejected_result(command_id, command_type, "Question was not dismissed.", errors) unless errors.empty?

        state = normalized_state
        question = find_question(state, question_id)
        return rejected_result(command_id, command_type, "Question #{question_id} does not exist.", ["question_not_found"]) unless question

        current_status = question.fetch("status", nil)
        return accepted_result(command_id, command_type, question.fetch("id"), "Question #{question.fetch("id")} is already dismissed.", question, []) if current_status == "dismissed"
        unless current_status == "open"
          return rejected_result(command_id, command_type, "Question #{question.fetch("id")} is #{current_status}, not open.", ["question_not_open"])
        end

        now = timestamp
        question["status"] = "dismissed"
        question["updated_at"] = now
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: question.fetch("id"),
          level: "info",
          message: "Dismissed question #{question.fetch("id")}.",
          details: {
            "head_id" => question.fetch("head_id", nil),
            "project_id" => question.fetch("project_id", nil),
            "issue_id" => question.fetch("issue_id", nil)
          }
        )
        touch_state!(state, now)
        store.save(state)

        accepted_result(command_id, command_type, question.fetch("id"), "Dismissed question #{question.fetch("id")}.", question, log_ids)
      end

      def clear_state(command_id, command_type)
        now = timestamp
        state = State::Models.empty_state(now: now)
        store.save(state, preserve_log_buffer: false)

        accepted_result(command_id, command_type, nil, "Cleared Meringue state.", state, [])
      end

      def ask_question(command_id, command_type, payload)
        head_id = value_at(payload, "head_id", "HeadID", "headId", "_head_id")
        question_text = value_at(payload, "question", "Question")
        context = value_at(payload, "context", "Context")
        project_id = value_at(payload, "project_id", "ProjectID", "projectId")
        issue_id = value_at(payload, "issue_id", "IssueID", "issueId")
        errors = []

        errors << "head_id is required" if blank?(head_id)
        errors << "question is required" if blank?(question_text)
        return rejected_result(command_id, command_type, "Question was not stored.", errors) unless errors.empty?

        state = normalized_state
        return rejected_result(command_id, command_type, "Head #{head_id} does not exist.", ["head_not_found"]) unless find_agent(state, head_id)
        return rejected_result(command_id, command_type, "Project #{project_id} does not exist.", ["project_not_found"]) if present_string(project_id) && !find_project(state, project_id)
        return rejected_result(command_id, command_type, "Issue #{issue_id} does not exist.", ["issue_not_found"]) if present_string(issue_id) && !find_issue(state, issue_id)

        # One clarification must produce one question record and one log line, even when a head
        # expresses it both in its HeadResult `questions` array and as an `AskQuestion` command.
        existing_question = find_duplicate_head_question(state, head_id.to_s, question_text)
        if existing_question
          return accepted_result(
            command_id,
            command_type,
            existing_question.fetch("id"),
            "Question #{existing_question.fetch("id")} already records this clarification for head #{head_id}.",
            existing_question,
            []
          )
        end

        log_ids = []
        question = build_question(
          state: state,
          head_id: head_id.to_s,
          question_text: question_text.to_s,
          context: context.to_s,
          project_id: present_string(project_id),
          issue_id: present_string(issue_id)
        )
        state.fetch("questions") << question
        log_ids.concat(append_log(
          state,
          source_type: "kernel",
          source_id: question.fetch("id"),
          level: "info",
          message: "Question #{question.fetch("id")}: #{question.fetch("question")}",
          details: { "head_id" => head_id.to_s }
        ))
        touch_state!(state)
        store.save(state)

        accepted_result(command_id, command_type, question.fetch("id"), "Stored question #{question.fetch("id")}.", question, log_ids)
      end
    end
  end
end
