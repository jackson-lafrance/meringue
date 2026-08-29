# frozen_string_literal: true

module Meringue
  module TUI
    class App
      # Submitting a prompt or slash command, and turning the handler's result into chat lines.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def submit_prompt(input_buffer, on_submit, state, remember_input: false)
        # Collapsed pastes are re-expanded here and nowhere else: the composer,
        # the wrapper, and the slash completer only ever saw the markers, while
        # the kernel receives the message the user actually pasted.
        text = @chat_pastes.expand(input_buffer).strip
        @chat_pastes.clear!
        return if text.empty?

        remember_chat_input(text) if remember_input
        slash_command = text.start_with?("/")
        # Without a harness the kernel cannot spawn a head, so a plain prompt
        # would fail mid-routing. Slash commands (notably /setup and /config)
        # still work so the user can pick a backend and continue.
        unless slash_command
          unless harness_configured?
            append_jump_response("No agent harness is configured. Run /setup to choose one before sending prompts.")
            return
          end
        end
        # Slash commands are explicit clutch-path instructions and never carry
        # dashboard routing context. LogScope.chat_target already normalizes an
        # absent, cleared, or unbound selection to nil, so both branches produce
        # the same "Hash or nil" shape the handler call expects.
        selected_target = slash_command ? nil : LogScope.chat_target(state)
        assistant_message_id = nil
        unless slash_command
          # This placeholder is presentation-only. Persisting it here can wait behind a kernel
          # state write and block the input thread before the background head even starts.
          assistant_message_id = append_message(
            "meringue",
            "",
            status: "queued",
            visible: false,
            persist: false
          )
        end
        submission = if on_submit&.respond_to?(:enqueue_submission)
                       on_submit.enqueue_submission(text, selected_target: selected_target)
                     end
        increment_pending_count

        Thread.new do
          begin
            update_message(
              assistant_message_id,
              text: "",
              status: "head working",
              visible: false,
              persist: false
            ) if assistant_message_id
            result = if submission && on_submit.respond_to?(:deliver_submission)
                       on_submit.deliver_submission(submission) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     elsif on_submit
                       submit_to_prompt_handler(on_submit, text, selected_target) do |event|
                         update_message_from_event(assistant_message_id, event)
                       end
                     else
                       unavailable_prompt_handler_result
                     end
            if slash_command
              command_results = result.fetch("command_results", []) || []
              apply_slash_command_results(command_results) if result.fetch("event", nil) == "slash_command_applied"
              resolve_theme_picker_submission(command_results)
            else
              final_text = result_logged_to_kernel?(result) ? "" : log_text_for(result)
              visible = !final_text.to_s.strip.empty?
              update_message(assistant_message_id, text: final_text, status: nil, visible: visible, persist: visible)
            end
          rescue StandardError => e
            restore_pending_theme_picker if slash_command && text.start_with?("/theme ")
            if slash_command && text.start_with?("/config save ") && @status_bar_composer_active && @status_bar_composer_draft
              @status_bar_composer_saving = false
              @status_bar_composer_draft.apply_save_failure("Configuration save failed: #{e.class}: #{e.message}")
            elsif slash_command && text.start_with?("/config save ") && @settings_active && @settings_draft
              @settings_saving = false
              @settings_draft.apply_save_failure("Configuration save failed: #{e.class}: #{e.message}")
            elsif assistant_message_id
              update_message(assistant_message_id, text: "Head loop failed: #{e.class}: #{e.message}", status: "errored", visible: true)
            else
              # A slash command has no queued assistant message to fail, so without this the
              # composer cleared, the command never ran, and nothing at all was rendered.
              append_message("meringue", "#{command_word(text)} failed: #{e.class}: #{e.message}", status: "errored")
            end
          ensure
            decrement_pending_count
          end
        end
      end

      # Selected dashboard chat still goes through the normal head callback. The
      # target is a keyword so it cannot be confused with user text or turn into
      # a direct PromptAgent shortcut.
      def submit_to_prompt_handler(on_submit, text, selected_target, &on_event)
        return on_submit.call(text, &on_event) if blank_selected_target?(selected_target)
        return on_submit.call(text, &on_event) unless handler_accepts_selected_target?(on_submit)

        on_submit.call(text, selected_target: selected_target, &on_event)
      end

      # nil, "", and {} all mean "nothing is selected". Normalizing here keeps a
      # stale or partially cleared value from turning a normal prompt into a
      # keyword call carrying no routing information.
      def blank_selected_target?(selected_target)
        return true if selected_target.nil?
        return selected_target.empty? if selected_target.respond_to?(:empty?)

        false
      end

      # Older embedders pass a one-argument prompt handler. Routing context is
      # additive, so degrade to an unscoped prompt instead of failing the whole
      # message with an ArgumentError only when a target happens to be selected.
      def handler_accepts_selected_target?(on_submit)
        parameters = handler_parameters(on_submit)
        return true unless parameters

        parameters.any? do |kind, name|
          kind == :keyrest || (%i[key keyreq].include?(kind) && name == :selected_target)
        end
      end

      def handler_parameters(on_submit)
        return on_submit.parameters if on_submit.respond_to?(:parameters)
        return on_submit.method(:call).parameters if on_submit.respond_to?(:call)

        nil
      rescue StandardError
        nil
      end

      # The leading `/word` of a submitted slash command, for naming it in a failure line.
      def command_word(text)
        text.to_s.strip.split(/\s+/).first.to_s[0, 40]
      end

      def unavailable_prompt_handler_result
        {
          "summary" => "Prompt handling is not enabled for this TUI session.",
          "spawn_head_result" => { "status" => "rejected", "message" => "No prompt handler configured." }
        }
      end

      def update_message_from_event(message_id, event)
        case event.fetch("event", nil)
        when "head_completed"
          remember_log_event(head_completed_key(event.fetch("head_id", nil)))
          update_message_status(message_id, "applying commands", persist: false)
        when "head_result_applied"
          # A head may propose user commands such as /clear or /theme. Their local side effects
          # must match the typed slash path.
          apply_slash_command_results(event.fetch("command_results", []) || [])
          update_message_status(message_id, worker_wait_status(event), persist: false)
        when "slash_command_applied"
          apply_slash_command_results(event.fetch("command_results", []) || [])
        when "worker_wait_started"
          update_message_status(message_id, "workers running", persist: false)
        when "worker_completed"
          update_message_status(message_id, nil, persist: false)
        when "worker_wait_failed"
          append_user_facing_line(message_id, worker_wait_failed_line(event), status: "worker wait failed")
        end
      end

      def result_logged_to_kernel?(result)
        kernel_results = [
          result.fetch("spawn_head_result", nil),
          result.fetch("apply_head_result", nil),
          *Array(result.fetch("worker_wait_results", [])).map { |worker| worker.fetch("completion_result", nil) }
        ].compact
        kernel_results.any? { |kernel_result| Array(kernel_result.fetch("log_entry_ids", [])).any? }
      end

      def log_text_for(result)
        if result.fetch("event", nil) == "slash_command_applied"
          apply_theme_command_results(result.fetch("command_results", []) || [])
          return ""
        end

        spawn_result = result.fetch("spawn_head_result", {}) || {}
        apply_result = result.fetch("apply_head_result", {}) || {}
        head = spawn_result.fetch("result", {}) || {}
        metadata = head.fetch("harness_metadata", {}) || {}
        head_result = metadata.fetch("head_result", {}) || {}

        lines = []
        if head_result.any?
          lines.concat(head_result_user_lines(head_result, question_ids: question_ids_from_apply_result(apply_result)))
        else
          lines.concat(failure_result_lines(spawn_result, apply_result, fallback: result.fetch("summary", nil)))
        end

        lines.concat(worker_summary_lines(result.fetch("worker_wait_results", []) || []))
        lines.concat(failure_result_lines(spawn_result, apply_result)) if lines.empty?
        lines.reject { |line| line.to_s.empty? }.join("\n")
      end

      def apply_slash_command_results(command_results)
        clear_logs! if clear_state_accepted?(command_results)
        reload_recounted_presentation_state! if recount_accepted?(command_results)
        apply_theme_command_results(command_results)
        apply_github_access_test_results(command_results)
        apply_configuration_command_results(command_results)
      end

      def apply_github_access_test_results(command_results)
        result = Array(command_results).reverse.find { |candidate| candidate.fetch("command_type", nil) == "TestGitHubAccess" }
        return unless result

        payload = result.fetch("result", {}) || {}
        @github_access_test_result = payload.merge(
          "outcome" => payload.fetch("outcome", payload.fetch("status", result.fetch("status", "unavailable"))),
          "message" => payload.fetch("message", result.fetch("message", "GitHub access test was unavailable."))
        )
      rescue StandardError => e
        @github_access_test_result = {
          "outcome" => "unavailable",
          "message" => "GitHub access result could not be shown: #{e.message}"
        }
      end

      # Setup's project adoption rides on the save it was chosen in: the command
      # is only sent once the configuration transaction has actually been
      # accepted, using the submit context captured when Complete was pressed.
      def submit_pending_project_adoption
        candidate = @pending_project_adoption
        context = @setup_submit_context
        @pending_project_adoption = nil
        @setup_submit_context = nil
        return unless candidate && context

        on_submit, state = context
        name = candidate.fetch("name", "").to_s
        command = "/project add #{candidate.fetch("path")}"
        command = "#{command} \"#{name.gsub("\"", "")}\"" unless name.empty?
        submit_prompt(command, on_submit, state)
      rescue StandardError => e
        append_jump_response("The project could not be registered automatically: #{e.message} — run /project add <path> when you are ready.")
      end

      def apply_configuration_command_results(command_results)
        result = Array(command_results).reverse.find { |candidate| candidate.fetch("command_type", nil) == "SaveConfiguration" }
        return unless result

        if result.fetch("status", nil) == "accepted"
          outcome = result.dig("result", "onboarding_outcome") || @settings_setup_outcome
          setup_was_active = @settings_active && setup_mode?
          composer_was_active = @status_bar_composer_active
          @config = config.reload_file
          workspace_controller.reload_editor_config(@config) if workspace_controller&.respond_to?(:reload_editor_config)
          @keybindings = Keybindings.from_config(@config.section("tui", "keybindings"))
          close_settings(discard: outcome == "skipped") if @settings_active
          close_status_bar_composer if composer_was_active
          if setup_was_active && outcome
            append_jump_response(outcome == "skipped" ? Onboarding.skip_card : Onboarding.completion_card(@config))
            submit_pending_project_adoption
          end
        elsif @status_bar_composer_active && @status_bar_composer_draft
          @status_bar_composer_saving = false
          details = result.fetch("result", {}) || {}
          @status_bar_composer_draft.apply_save_failure(
            result.fetch("message", "Configuration was not saved."),
            details.fetch("field_errors", {})
          )
        elsif @settings_active && @settings_draft
          @settings_saving = false
          details = result.fetch("result", {}) || {}
          @settings_draft.apply_save_failure(
            result.fetch("message", "Configuration was not saved."),
            details.fetch("field_errors", {})
          )
        end
      rescue StandardError => e
        if @status_bar_composer_active && @status_bar_composer_draft
          @status_bar_composer_saving = false
          @status_bar_composer_draft.apply_save_failure("Configuration result could not be applied: #{e.message}")
        elsif @settings_active && @settings_draft
          @settings_saving = false
          @settings_draft.apply_save_failure("Configuration result could not be applied: #{e.message}")
        end
      end

      def clear_state_accepted?(command_results)
        Array(command_results).any? do |result|
          result.fetch("command_type", nil) == "ClearState" && result.fetch("status", nil) == "accepted"
        end
      end

      def recount_accepted?(command_results)
        Array(command_results).any? do |result|
          result.fetch("command_type", nil) == "Recount" && result.fetch("status", nil) == "accepted"
        end
      end

      # A recount renames records, and the kernel rewrote the ids embedded in persisted chat
      # history and in the focused-workspace selection to match. This in-memory state is written
      # back on the next append, so it has to be re-read: otherwise the stale buffer would
      # reintroduce pre-recount ids that now name different records.
      def reload_recounted_presentation_state!
        return unless log_store&.respond_to?(:load)

        state = log_store.load
        restore_logs!(state)
        restore_agent_workspace!(state)
      rescue StandardError
        nil
      end

      def clear_logs!
        snapshot = @chat_mutex.synchronize do
          @messages = []
          @next_message_id = 0
          @log_event_keys = {}
          log_buffer_snapshot_unlocked
        end
        persist_log_snapshot(snapshot)
      end

      def apply_theme_command_results(command_results)
        theme_result = Array(command_results).reverse.find do |result|
          result.fetch("command_type", nil) == "SetTheme"
        end
        return unless theme_result

        if theme_result.fetch("status", nil) == "accepted"
          theme = (theme_result.fetch("result", {}) || {})["theme"]
          Style.configure!(theme) if theme
          @theme_picker_pending_original = nil
        else
          restore_pending_theme_picker
        end
      rescue StandardError
        restore_pending_theme_picker
      end

      # A slash submission can finish without a SetTheme result (for example an
      # unavailable callback). Do not leave the process-local preview active.
      def resolve_theme_picker_submission(command_results)
        return if @theme_picker_pending_original.nil?
        return if Array(command_results).any? { |result| result.fetch("command_type", nil) == "SetTheme" }

        restore_pending_theme_picker
      end

      def append_head_result_applied_summary(message_id, event)
        lines = head_result_user_lines(
          event.fetch("head_result", {}) || {},
          question_ids: question_ids_from_apply_result(event.fetch("apply_result", {}) || {})
        )
        status = worker_wait_status(event)
        if lines.empty?
          update_message_status(message_id, status)
        else
          append_user_facing_line(message_id, lines.join("\n"), status: status)
        end
      end

      def head_result_user_lines(head_result, question_ids: [])
        response = head_result.fetch("response", "").to_s.strip
        questions = Array(head_result.fetch("questions", []))
        question_lines = question_user_lines(questions, question_ids: question_ids)

        [response.empty? ? nil : response, *question_lines].compact
      end

      def question_user_lines(questions, question_ids: [])
        questions.each_with_index.filter_map do |question, index|
          question_text = question.fetch("question", "").to_s.strip
          next if question_text.empty?

          question_id = question_ids[index].to_s
          label = question_id.empty? ? "Question" : "Question #{question_id}"
          context = question.fetch("context", "").to_s.strip
          [
            "#{label}: #{question_text}",
            context.empty? ? nil : "Context: #{context}",
            question_answer_hint(question_id)
          ].compact.join("\n")
        end
      end

      # Answering is a real routing action: the kernel records the answer and spawns a head that
      # continues the work. Tell the user both ways to answer so the question is not a dead end.
      def question_answer_hint(question_id)
        return "Reply here to answer, or run /answer <question_id> \"<answer>\"." if question_id.to_s.empty?

        "Reply here to answer, or run /answer #{question_id} \"<answer>\"."
      end

      def worker_summary_lines(worker_wait_results)
        worker_wait_results.filter_map do |worker|
          next unless worker.fetch("status", nil) == "settled"

          worker_completed_line(worker)
        end
      end

      def worker_completed_line(event)
        user_facing_worker_lines(
          agent_id: event.fetch("agent_id", "worker"),
          pr_urls: Array(event.fetch("pr_urls", [])).compact,
          last_assistant_text: event.fetch("last_assistant_text", nil)
        ).join("\n")
      end

      def worker_wait_failed_line(event)
        agent_id = event.fetch("agent_id", "worker")
        error = event.fetch("error", {}) || {}
        message = error.fetch("message", "worker result could not be read").to_s.strip
        "Could not read #{agent_id}'s result#{message.empty? ? "." : ": #{message}"}"
      end

      def user_facing_worker_lines(agent_id:, pr_urls:, last_assistant_text:)
        lines = Array(pr_urls).compact.map { |url| "PR  #{url}" }
        output = AgentOutput.normalize(last_assistant_text, source_id: agent_id, pr_urls: pr_urls)
        lines << output unless output.empty?
        lines
      end

      def append_user_facing_line(message_id, line, status: nil)
        return if line.to_s.strip.empty?

        append_to_message(message_id, line, status: status, visible: true)
      end

      def question_ids_from_apply_result(apply_result)
        result = apply_result.fetch("result", {}) || {}
        Array(result.fetch("question_ids", []))
      end

      def failure_result_lines(spawn_result, apply_result, fallback: nil)
        failed_result = [apply_result, spawn_result].compact.find do |result|
          status = result.fetch("status", nil)
          !status.to_s.empty? && status != "accepted"
        end
        message = failed_result&.fetch("message", nil).to_s.strip
        errors = Array(failed_result&.fetch("errors", [])).map(&:to_s).reject(&:empty?)
        lines = []
        lines << message unless message.empty?
        lines.concat(errors.map { |error| "- #{error}" })
        lines << fallback.to_s.strip if lines.empty? && !fallback.to_s.strip.empty?
        lines
      end

      def worker_wait_status(event)
        command_results = (event.fetch("apply_result", {}).fetch("result", {}) || {}).fetch("command_results", [])
        has_workers = command_results.any? do |command_result|
          command_result.fetch("command_type", nil) == "SpawnWorker" && command_result.fetch("status", nil) == "accepted"
        end

        has_workers ? "workers running" : nil
      end
    end
  end
end
