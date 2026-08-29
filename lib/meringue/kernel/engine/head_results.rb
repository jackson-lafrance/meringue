# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Validating a head result's shape, recording the questions it asked, and journalling each of
      # its commands exactly once.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def validate_head_result_shape(head_result)
        errors = []
        unless head_result.is_a?(Hash)
          errors << "head_result must be an object"
          return errors
        end

        errors << "head_result.title must be a string" unless head_result["title"].is_a?(String)
        errors << "head_result.summary must be a string" unless head_result["summary"].is_a?(String)
        if head_result.key?("response") && !head_result["response"].nil? && !head_result["response"].is_a?(String)
          errors << "head_result.response must be a string"
        end
        validate_head_commands(head_result["commands"], errors)
        validate_head_questions(head_result["questions"], errors)
        errors
      end

      def validate_head_commands(commands, errors)
        unless commands.is_a?(Array)
          errors << "head_result.commands must be an array"
          return
        end

        commands.each_with_index do |command, index|
          unless command.is_a?(Hash)
            errors << "head_result.commands[#{index}] must be an object"
            next
          end

          errors << "head_result.commands[#{index}].type must be a string" unless command["type"].is_a?(String)
          errors << "head_result.commands[#{index}].payload must be an object" unless command["payload"].is_a?(Hash)
        end
      end

      def validate_head_questions(questions, errors)
        unless questions.is_a?(Array)
          errors << "head_result.questions must be an array"
          return
        end

        questions.each_with_index do |question, index|
          unless question.is_a?(Hash)
            errors << "head_result.questions[#{index}] must be an object"
            next
          end

          errors << "head_result.questions[#{index}].question must be a string" unless question["question"].is_a?(String)
        end
      end

      def append_head_response_log(state, head_id, head_result)
        response = present_string(head_result.fetch("response", nil))
        return [] unless response

        head = find_agent(state, head_id.to_s)
        request = (head&.fetch("harness_metadata", nil) || {}).fetch("head_request", {}) || {}
        selected_target = request.fetch("selected_target", nil)
        append_log(
          state,
          source_type: "head",
          source_id: head_id.to_s,
          level: "info",
          message: response,
          details: { "kind" => "head_response", **selected_target_log_details(selected_target) }
        )
      end

      # A skipped target is useful warning information, but the accepted/rejected counts are
      # internal command-journal status rather than command output. The individual command
      # results already carry their actual output and actionable errors.
      def head_batch_summary_message(head_id:, accepted_count:, rejected_count:, failed_count:, skipped_count:)
        return "" unless skipped_count.positive?

        pronoun = skipped_count == 1 ? "its target" : "their targets"
        "#{count_phrase(skipped_count, "command")} skipped because #{pronoun} #{skipped_count == 1 ? "was" : "were"} removed before this result was applied."
      end

      def head_batch_summary_level(rejected_count:, failed_count:)
        return "error" if failed_count.positive?
        return "warning" if rejected_count.positive?

        "info"
      end

      # Head batches that accept nothing used to leave only per-command error lines, so a correctly
      # captured user message could disappear from the conversation. This restates the message the
      # kernel stored for that head and says what to do with it, so nothing is silently dropped.
      def append_unrouted_user_message_log(state, head_id, command_results)
        user_message = head_request_user_message(state, head_id)
        results = Array(command_results)
        failures = results.reject { |result| result.fetch("status", nil) == "accepted" }
        skipped = failures.select { |result| head_command_result_skipped?(result) }
        # A batch whose every command targeted a record that was pruned or killed under it routed
        # nothing, but nothing failed either. Say that, rather than reporting an error the user
        # cannot act on.
        skipped_only = failures.any? && skipped.length == failures.length
        quoted = user_message ? ": #{single_line_excerpt(user_message).inspect}" : "."
        reason = if failures.empty?
                   "Head #{head_id} routed nothing for this message, so it still needs handling"
                 elsif skipped_only
                   "Every command from head #{head_id} targeted a record that was removed before its result was applied, so this message was not routed"
                 else
                   "No command from head #{head_id} was applied, so this message still needs handling"
                 end
        message = if skipped_only
                    "#{reason}#{quoted} Meringue will automatically start one fresh replacement head with the original request and command context; if that replacement also cannot route it, retry it with /retry or route it yourself."
                  else
                    "#{reason}#{quoted} Retry it with /retry #{head_id}, resend it, or route it yourself with /prompt or /worker spawn."
                  end
        append_log(
          state,
          source_type: "kernel",
          source_id: head_id,
          level: failures.empty? || skipped_only ? "warning" : "error",
          message: message,
          details: {
            "kind" => "unrouted_user_message",
            "head_id" => head_id,
            "user_message" => user_message,
            "accepted_command_count" => 0,
            "command_count" => Array(command_results).length,
            "command_results" => failures.map do |result|
              {
                "command_type" => result.fetch("command_type", nil),
                "status" => result.fetch("status", nil),
                "message" => result.fetch("message", nil)
              }.compact
            end
          }.compact
        )
      end

      def single_line_excerpt(text, limit: 160)
        collapsed = text.to_s.strip.gsub(/\s+/, " ")
        return collapsed if collapsed.length <= limit

        "#{collapsed[0, limit - 1]}…"
      end

      def create_head_questions!(state, head_id, questions, log_ids)
        questions.map do |question_payload|
          question = build_question(
            state: state,
            head_id: head_id.to_s,
            question_text: question_payload.fetch("question").to_s,
            context: question_payload.fetch("context", "").to_s,
            project_id: present_string(value_at(question_payload, "project_id", "projectId")),
            issue_id: present_string(value_at(question_payload, "issue_id", "issueId"))
          )
          state.fetch("questions") << question
          log_ids.concat(append_log(
            state,
            source_type: "kernel",
            source_id: question.fetch("id"),
            level: "info",
            message: "Question #{question.fetch("id")}: #{question.fetch("question")}",
            details: {
              "head_id" => head_id.to_s,
              "project_id" => question.fetch("project_id"),
              "issue_id" => question.fetch("issue_id")
            }
          ))
          question.fetch("id")
        end
      end

      def initialize_head_command_journal(state:, head_id:, head_result:, existing:, recovering:)
        existing_by_id = Array(existing).select { |entry| entry.is_a?(Hash) }.to_h { |entry| [entry["command_id"].to_s, entry] }
        head_result.fetch("commands").each_with_index.map do |proposed_command, index|
          command = command_with_default_id(proposed_command, head_id: head_id, index: index)
          command_id = value_at(command, "command_id", "id").to_s
          prior = existing_by_id[command_id]
          if prior
            next prior.merge(
              "index" => index,
              "command_author_type" => "head",
              "command_author_id" => head_id.to_s
            )
          end

          inferred = nil
          {
            "command_id" => command_id,
            "index" => index,
            "command_type" => canonical_command_type(value_at(command, "type", "command_type")),
            "command_author_type" => "head",
            "command_author_id" => head_id.to_s,
            "status" => inferred ? inferred.fetch("status") : "pending",
            "target_id" => inferred && inferred.fetch("target_id", nil),
            "message" => inferred && inferred.fetch("message", nil),
            "result" => inferred && inferred.fetch("result", nil),
            "errors" => inferred ? inferred.fetch("errors", []) : [],
            "log_entry_ids" => inferred ? inferred.fetch("log_entry_ids", []) : [],
            "recovered" => !!inferred,
            "completed_at" => inferred ? timestamp : nil
          }.compact
        end
      end

      def ensure_head_questions!(state, head_id, questions, log_ids)
        Array(questions).map do |question_payload|
          existing = find_duplicate_head_question(state, head_id, question_payload.fetch("question"))
          next existing.fetch("id") if existing

          create_head_questions!(state, head_id, [question_payload], log_ids).first
        end.compact.uniq
      end

      def find_head_question_by_text(state, head_id, question_text)
        normalized = normalized_question_text(question_text)
        return nil if normalized.empty?

        state.fetch("questions").find do |question|
          question.fetch("head_id", nil).to_s == head_id.to_s &&
            normalized_question_text(question.fetch("question", nil)) == normalized
        end
      end

      # Heads sometimes restate one clarification twice: once in the HeadResult `questions`
      # array and once as an `AskQuestion` command, often with slightly reworded text. The
      # kernel records a clarification once per head, so a near-identical restatement resolves
      # to the question that is already stored instead of creating a second record and log line.
      def find_duplicate_head_question(state, head_id, question_text)
        normalized = normalized_question_text(question_text)
        return nil if normalized.empty?

        exact = find_head_question_by_text(state, head_id, question_text)
        return exact if exact

        head_questions = state.fetch("questions").select { |question| question.fetch("head_id", nil).to_s == head_id.to_s }
        scored = head_questions.map do |question|
          [question_text_similarity(normalized_question_text(question.fetch("question", nil)), normalized), question]
        end
        score, question = scored.max_by { |similarity, _question| similarity }
        return nil unless question && score.to_f >= DUPLICATE_QUESTION_SIMILARITY_THRESHOLD

        question
      end

      def normalized_question_text(question_text)
        question_text.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      def question_text_similarity(left, right)
        left_words = question_text_words(left)
        right_words = question_text_words(right)
        return 0.0 if left_words.empty? || right_words.empty?

        union = (left_words | right_words).length
        return 0.0 if union.zero?

        (left_words & right_words).length.to_f / union
      end

      def question_text_words(text)
        text.to_s.downcase.scan(/[a-z0-9]+/).uniq
      end

      def current_head_journal_entry(head_id, index)
        synchronized_state do
          head = find_agent(normalized_state, head_id)
          metadata = head && (head.fetch("harness_metadata", {}) || {})
          entry = metadata && Array(metadata.fetch("head_result_command_journal", []))[index]
          entry && deep_copy(entry)
        end
      end

      def current_head_command_journal(head_id)
        synchronized_state do
          head = find_agent(normalized_state, head_id)
          metadata = head && (head.fetch("harness_metadata", {}) || {})
          journal = metadata ? Array(metadata.fetch("head_result_command_journal", [])) : []
          deep_copy(journal)
        end
      end
    end
  end
end
