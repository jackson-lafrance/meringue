# frozen_string_literal: true

module Meringue
  module Harness
    class PiClient
      def session_exit_evidence(session_ref)
        process = exited_process_for(session_ref)
        return nil unless process

        {
          "pid" => process.pid,
          "exit_status" => process.exit_status,
          "stderr_tail" => present?(process.stderr_tail) ? process.stderr_tail : nil,
          "last_event_at" => process.last_event_at
        }.compact
      end

      def session_supervision_evidence(session_ref)
        lease = transport_record(session_ref)
        persisted = metadata_value(session_ref, "supervision")
        persisted = {} unless persisted.is_a?(Hash)
        source, source_name = newest_supervision_source(lease, persisted)
        return nil unless source.is_a?(Hash) && source["owner_pid"]

        owner_pid = integer_or_nil(source["owner_pid"])
        harness_pid = integer_or_nil(source["pid"] || source["harness_pid"] || session_ref["pid"] || session_ref[:pid])
        owner_started_at = source["owner_started_at"]
        harness_started_at = source["harness_started_at"]
        owner_alive = process_identity_alive?(owner_pid, started_at: owner_started_at)
        harness_alive = live_harness_process_at?(harness_pid, started_at: harness_started_at)
        {
          "source" => source_name,
          "transport_key" => transport_key(session_ref),
          "owner_pid" => owner_pid,
          "owner_started_at" => owner_started_at,
          "owner_alive" => owner_alive,
          "harness_pid" => harness_pid,
          "harness_started_at" => harness_started_at,
          "harness_alive" => harness_alive,
          "supervisor_exited" => !!owner_pid && !owner_alive && !harness_alive,
          "observed_at" => Time.now.utc.iso8601
        }.compact
      rescue StandardError
        nil
      end

      def session_progress(events)
        PiSessionView.progress_items(events)
      end

      def open_session_view(session_ref)
        process = process_for_session(session_ref, required: false)
        return history_session_view(session_ref) unless process

        # A focused view is disposable UI state, not the owner of the Pi stream. Start at the
        # beginning of the retained journal so a view opened after leaving the dashboard can
        # catch up on transient deltas that have not been written to get_entries yet. The journal
        # reports a gap when its bounded history has already rolled over; the durable snapshot is
        # still the repair path in that case.
        initial_cursor = 0
        transcript_mutex = Mutex.new
        transcript_entries = []
        transcript_leaf_id = nil
        entries_supported = true
        SessionView::Handle.new(
          initial_cursor: initial_cursor,
          snapshot_loader: lambda {
            transcript_mutex.synchronize do
              state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
              if entries_supported
                begin
                  command = { "type" => "get_entries" }
                  command["since"] = transcript_leaf_id if transcript_leaf_id
                  data = rpc_data(process.request(command, timeout: command_timeout))
                  transcript_entries.concat(Array(data.fetch("entries", [])))
                  transcript_leaf_id = data.fetch("leafId", transcript_leaf_id)
                  next PiSessionView.live_snapshot(
                    pi_state: state,
                    entries: transcript_entries,
                    leaf_id: transcript_leaf_id,
                    session_ref: session_ref
                  )
                rescue StandardError
                  # Older Pi versions may not expose get_entries. Fall back to
                  # get_messages without weakening the live event stream.
                  entries_supported = false
                end
              end

              messages = rpc_data(process.request({ "type" => "get_messages" }, timeout: command_timeout)).fetch("messages", [])
              PiSessionView.live_snapshot(pi_state: state, messages: messages, session_ref: session_ref)
            end
          },
          event_reader: ->(cursor, limit) { process.events_after(cursor, limit: limit) },
          event_normalizer: ->(entry) { PiSessionView.normalize_event(entry) }
        )
      end

      def attach_session(session_ref)
        process = process_for_session(session_ref)
        return preserve_session_identity(get_state(session_ref), session_ref) if process
        if unmanaged_process_alive?(session_ref)
          raise SessionTransportUnavailableError,
                "Refusing to start a second Pi process while the saved process is still alive"
        end

        persisted_pid = session_ref["pid"] || session_ref[:pid]
        if live_harness_process?(persisted_pid, session_ref)
          raise UnmanagedProcessError,
                "Refusing to attach Pi session while its previous process #{persisted_pid} is still running"
        end

        expanded_cwd = validate_cwd!(session_ref["cwd"] || session_ref[:cwd])
        session = resume_session_argument(session_ref)
        session_name = metadata_value(session_ref, "session_name")
        workspace_mode = metadata_value(session_ref, "workspace_mode") || "isolated"
        preserved_settings = persisted_session_settings(session_ref)
        argv = build_argv(
          session_name: session_name,
          system_prompt: nil,
          session: session,
          session_settings: preserved_settings,
          workspace_mode: workspace_mode
        )
        requested_model = model_reference_from_settings(preserved_settings)
        process = start_rpc_process(argv: argv, cwd: expanded_cwd)
        register_process(process)

        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        set_session_name(process, session_name) if present?(session_name)
        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        resumed_ref = build_session_ref(
          process,
          state,
          kind: metadata_value(session_ref, "kind"),
          cwd: expanded_cwd,
          session_name: session_name,
          workspace_mode: workspace_mode
        )
        resumed_ref = record_requested_session_model(resumed_ref, requested_model)
        attached_ref = preserve_session_identity(resumed_ref, session_ref).merge(
          "metadata" => metadata_with(
            session_ref,
            resumed_ref.fetch("metadata", {}).merge(
              "attach_supported" => true,
              "resumed_from_session" => true,
              "resume_session" => session
            )
          )
        )
        claim_transport(attached_ref, note: "resumed")
        attached_ref
      rescue StandardError
        if process
          unregister_process(process)
          process.terminate(timeout: shutdown_timeout)
        end
        raise
      end

      def interactive_session_supported?
        true
      end

      def prepare_interactive_session(session_ref)
        current_ref = preserve_session_identity(get_state(session_ref), session_ref)
        current_ref = current_ref.merge(
          "metadata" => metadata_with(session_ref, current_ref.fetch("metadata", {}))
        )
        was_streaming = current_ref.fetch("is_streaming", false)
        events = read_events(current_ref)
        rpc_ref = current_ref

        session_summary = safe_session_file_summary(current_ref)
        handoff_summary = bounded_handoff_summary(session_summary)
        handoff_intent = handoff_summary.fetch("last_user_text", nil) || latest_user_intent(events)
        interrupted_turn_outcome = bounded_turn_outcome(turn_outcome(current_ref))
        turn_checkpoint = interrupted_turn_outcome
        replacement = nil
        begin
          interactive_session_argv(current_ref, handoff_prompt: nil)
        rescue ProcessNotFoundError
          replacement = create_replacement_session_from_rpc(current_ref)
          handoff_intent = replacement.fetch("latest_user_intent", nil) unless present?(handoff_intent)
          current_ref = current_ref.merge(
            "session_id" => replacement.fetch("session_id"),
            "session_file" => replacement.fetch("session_file"),
            "metadata" => metadata_with(current_ref, "interactive_replacement" => replacement)
          )
        end

        handoff_prompt = if was_streaming
                           interactive_continuation_prompt(
                             current_ref,
                             events: events,
                             latest_user_intent: handoff_intent,
                             session_summary: handoff_summary
                           )
                         end
        interactive_argv = interactive_session_argv(current_ref, handoff_prompt: handoff_prompt)
        # Resolve environment/commit-identity policy before changing RPC ownership. If validation
        # fails, the original managed turn remains untouched and available to the rollback path.
        interactive_env = process_environment(current_ref.fetch("cwd", Dir.pwd))
        interactive_executable = resolve_interactive_executable(
          interactive_argv,
          cwd: current_ref.fetch("cwd", Dir.pwd),
          environment: interactive_env
        )
        settled_ref = settle_interactive_rpc_turn(rpc_ref) if was_streaming
        if settled_ref
          rpc_ref = preserve_session_identity(settled_ref, rpc_ref)
          # Pi may persist an explicit aborted assistant record. That post-abort record—not the
          # earlier pending tool call—is the baseline a native final result must supersede.
          turn_checkpoint = bounded_turn_outcome(turn_outcome(rpc_ref)) || turn_checkpoint
        end
        quiesced_ref = quiesce_interactive_rpc(rpc_ref)
        detached_ref = quiesced_ref.merge(
          "session_id" => current_ref.fetch("session_id", nil),
          "session_file" => current_ref.fetch("session_file", nil),
          "pid" => nil,
          "is_streaming" => false,
          "metadata" => metadata_with(
            quiesced_ref,
            (current_ref.fetch("metadata", {}) || {}).merge(
              "interactive_handoff_ready" => true,
              "interactive_handoff_prompt" => handoff_prompt,
              "interactive_handoff_event_count" => events.length,
              "interactive_turn_interrupted" => was_streaming,
              "interactive_interruption_method" => was_streaming ? "rpc_abort" : nil,
              "killed" => nil,
              "kill_note" => nil
            ).compact
          )
        )
        {
          "session_ref" => detached_ref,
          "interactive_argv" => interactive_argv,
          "interactive_executable" => interactive_executable,
          "interactive_env" => interactive_env,
          # Escape is Pi's interrupt key for active turns and autocompaction;
          # Ctrl-C only clears its editor. Keep that rule inside this adapter.
          "interactive_shutdown_input" => "\e",
          "handoff" => interactive_handoff_metadata(
            was_streaming: was_streaming,
            events: events,
            prompt: handoff_prompt,
            latest_user_intent: handoff_intent,
            session_summary: handoff_summary,
            interrupted_turn_outcome: interrupted_turn_outcome,
            turn_checkpoint: turn_checkpoint,
            replacement: replacement
          )
        }
      end

      def reclaim_interactive_session(session_ref, pid:)
        numeric_pid = Integer(pid)
        return true unless process_alive?(numeric_pid)

        marker = (session_ref.dig("metadata", "interactive_handoff") || {})
        started_at = marker["reclaim_interactive_started_at"] || marker["interactive_started_at"]
        unless ProcessIdentity.matches?(numeric_pid, command: Array(command).first, started_at: started_at)
          raise SessionTransportUnavailableError,
                "Refusing to reclaim interactive Pi pid #{numeric_pid}: it no longer matches the configured Pi command"
        end

        terminate_unowned_process(numeric_pid)
        return true unless process_alive?(numeric_pid)

        raise SessionTransportUnavailableError, "Interactive Pi process #{numeric_pid} did not stop during crash recovery"
      rescue ArgumentError, TypeError
        true
      end

      def resume_dashboard_session(session_ref, handoff: nil)
        process = process_for_session(session_ref, required: false)
        resumed_ref = process ? get_state(session_ref) : attach_session(session_ref)
        return resumed_ref unless dashboard_continuation_required?(resumed_ref, handoff)

        prompt = dashboard_continuation_prompt(handoff)
        prompted_ref = prompt_session(resumed_ref, prompt, mode: "normal")
        prompted_ref.merge(
          "metadata" => metadata_with(
            prompted_ref,
            "interactive_dashboard_continuation" => "started",
            "interactive_dashboard_continuation_prompt" => prompt
          )
        )
      end

      def wait_for_event(session_ref, type:, timeout: event_timeout)
        process = process_for_session(session_ref)
        deadline = Time.now + timeout
        events = []

        loop do
          remaining = deadline - Time.now
          raise RpcTimeoutError, "Timed out waiting for Pi event #{type.inspect}" if remaining <= 0

          event = process.next_event(timeout: remaining)
          events << event
          return events if event["type"] == type
        end
      end

    end
  end
end
