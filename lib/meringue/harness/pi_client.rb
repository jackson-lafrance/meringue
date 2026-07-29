# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "thread"
require "time"
require "timeout"

module Meringue
  module Harness
    class PiClient < Client
      DEFAULT_COMMAND = "pi"
      DEFAULT_COMMAND_TIMEOUT = 30
      DEFAULT_EVENT_TIMEOUT = 120
      DEFAULT_SHUTDOWN_TIMEOUT = 2
      MAX_STDERR_CHARS = 20_000
      # How long a takeover waits for another instance's in-flight turn to
      # settle before reporting an actionable conflict.
      DEFAULT_TAKEOVER_SETTLE_TIMEOUT = 5.0
      TAKEOVER_POLL_INTERVAL = 0.25
      TAKEOVER_EXIT_TIMEOUT = 5.0

      MODE_ALIASES = {
        "normal" => "normal",
        "steer" => "steer",
        "follow_up" => "follow_up",
        "followUp" => "follow_up"
      }.freeze

      class Error < StandardError; end
      class ProcessNotFoundError < Error; end
      class ProcessExitedError < Error; end
      class SessionTransportUnavailableError < Error; end
      # Another live Meringue instance owns the session and is still mid-turn. Prompting succeeds
      # once that turn settles, so the kernel queues and retries instead of failing the command.
      class SessionBusyError < SessionTransportUnavailableError
        include Harness::TransientSessionError
      end
      class UnmanagedProcessError < Error; end
      class RpcError < Error; end
      class RpcTimeoutError < Error; end
      class InvalidModeError < Error; end
      class InvalidModelReferenceError < Error; end
      class InvalidThinkingLevelError < Error; end
      class SessionSettingsBusyError < Error; end

      THINKING_LEVELS = %w[off minimal low medium high xhigh max].freeze
      # Pi only offers these two levels when a model explicitly maps them.
      EXPLICIT_THINKING_LEVELS = %w[xhigh max].freeze
      MODEL_CATALOG_SOURCE = "pi_rpc_get_available_models"
      # A catalog probe is a throwaway ephemeral Pi process, so it should not
      # inherit the long event timeout used for real agent turns.
      DEFAULT_MODEL_CATALOG_TIMEOUT = 30

      attr_reader :command, :env, :session_dir, :command_timeout,
                  :event_timeout, :shutdown_timeout

      def harness_name
        "pi"
      end

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], session_dir: nil,
                     command_timeout: DEFAULT_COMMAND_TIMEOUT,
                     event_timeout: DEFAULT_EVENT_TIMEOUT,
                     shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT,
                     transport_ownership: nil,
                     takeover_settle_timeout: DEFAULT_TAKEOVER_SETTLE_TIMEOUT)
        @transport_ownership = transport_ownership || TransportOwnership.new
        @takeover_settle_timeout = Float(takeover_settle_timeout)
        @command = command
        @env = env.transform_keys(&:to_s).transform_values(&:to_s)
        @extra_args = extra_args.map(&:to_s)
        @spawn_arguments_mutex = Mutex.new
        @session_dir = session_dir
        @command_timeout = command_timeout
        @event_timeout = event_timeout
        @shutdown_timeout = shutdown_timeout
        @processes_by_pid = {}
        @processes_mutex = Mutex.new
      end

      def extra_args
        @spawn_arguments_mutex.synchronize { @extra_args.dup }
      end

      # Registry updates this client in place so its already-running RPC
      # transports remain owned while future sessions use new app defaults.
      def configure_spawn_arguments(arguments)
        @spawn_arguments_mutex.synchronize { @extra_args = Array(arguments).map(&:to_s) }
        extra_args
      end

      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
        expanded_cwd = validate_cwd!(cwd)
        argv = build_argv(session_name: session_name, system_prompt: system_prompt)
        process = start_rpc_process(argv: argv, cwd: expanded_cwd)
        register_process(process)

        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        set_session_name(process, session_name) if present?(session_name)
        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        session_ref = build_session_ref(process, state, kind: kind, cwd: expanded_cwd,
                                                        session_name: session_name)
        claim_transport(session_ref, note: "spawned")

        return session_ref unless present?(prompt)

        prompt_session(session_ref, prompt, mode: "normal")
      rescue StandardError
        if process
          unregister_process(process)
          process.terminate(timeout: shutdown_timeout)
        end
        raise
      end

      def prompt_session(session_ref, prompt, mode: "normal")
        normalized_mode = normalize_mode!(mode)
        message = prompt.to_s
        current_ref = session_ref
        recovery_metadata = {}
        process = process_for(current_ref, required: false)
        unless process
          # Another Meringue instance (or a previous run of this one) may hold
          # the pipes. Take the transport over instead of failing forever, then
          # continue on the resumed session.
          takeover = take_over_transport(current_ref)
          if normalized_mode != "normal" && !takeover.fetch("resumable", false)
            raise InvalidModeError,
                  "Pi session is not active; resume it with mode: \"normal\" before using #{normalized_mode.inspect}"
          end

          # A resumed session starts settled, so an urgent steer/follow-up has
          # nothing to interrupt and is delivered as a normal continuation.
          requested_mode = normalized_mode
          normalized_mode = "normal"
          current_ref = attach_session(current_ref)
          process = process_for(current_ref)
          recovery_metadata = takeover_metadata(takeover)
          recovery_metadata["prompt_mode_downgraded_from"] = requested_mode if requested_mode != normalized_mode
        end
        current_ref = get_state(current_ref)

        command = case normalized_mode
                  when "normal"
                    if current_ref.fetch("is_streaming", false)
                      raise InvalidModeError,
                            "Pi session is streaming; use mode: \"steer\" or \"follow_up\""
                    end

                    { "type" => "prompt", "message" => message }
                  when "steer"
                    { "type" => "steer", "message" => message }
                  when "follow_up"
                    { "type" => "follow_up", "message" => message }
                  end

        rpc_data(process.request(command, timeout: command_timeout), allow_nil_data: true)
        prompted_ref = get_state(current_ref)
        # get_state rebuilds metadata from the live process, so recovery details
        # are re-applied here to stay visible in state and logs.
        return prompted_ref if recovery_metadata.empty?

        prompted_ref.merge("metadata" => metadata_with(prompted_ref, recovery_metadata))
      end

      def abort_session(session_ref)
        process = process_for(session_ref, required: false)
        unless process
          if unmanaged_process_alive?(session_ref)
            owner_pid = transport_owner_pid(session_ref)
            owner = owner_pid ? "Meringue instance #{owner_pid}" : "another Meringue instance"
            raise SessionTransportUnavailableError,
                  "This Pi session's turn is owned by #{owner}, so it cannot be cancelled from here. " \
                  "Cancel it in that window, or prompt this worker to take the session over once its turn settles."
          end

          raise ProcessNotFoundError,
                "No live Pi RPC process for pid #{(session_ref["pid"] || session_ref[:pid]).inspect}"
        end

        rpc_data(process.request({ "type" => "abort" }, timeout: command_timeout), allow_nil_data: true)
        get_state(session_ref)
      end

      def kill_session(session_ref)
        process = process_for(session_ref, required: false)
        unless process
          return session_ref.merge(
            "is_streaming" => false,
            "metadata" => metadata_with(session_ref, "killed" => true, "kill_note" => "no live Pi process found")
          )
        end

        process.terminate(timeout: shutdown_timeout)
        unregister_process(process)
        release_transport(session_ref, pid: process.pid)

        session_ref.merge(
          "pid" => process.pid,
          "is_streaming" => false,
          "last_event_at" => process.last_event_at,
          "metadata" => metadata_with(
            session_ref,
            "killed" => true,
            "exit_status" => process.exit_status,
            "stderr_tail" => process.stderr_tail
          )
        )
      end

      def get_state(session_ref)
        process = process_for(session_ref, required: false)
        if process
          state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
          return build_session_ref(
            process,
            state,
            kind: metadata_value(session_ref, "kind"),
            cwd: session_ref.fetch("cwd", process.cwd),
            session_name: metadata_value(session_ref, "session_name") || state["sessionName"]
          )
        end

        if unmanaged_process_alive?(session_ref)
          # RPC state belongs to the process that owns its pipes. Pi persists
          # model/thinking changes as session entries, so refresh those values
          # from the durable session instead of returning old spawn metadata.
          persisted_ref = build_session_ref_from_file(session_ref)
          return persisted_ref.merge(
            "harness" => "pi",
            "is_streaming" => true,
            "metadata" => metadata_with(
              persisted_ref,
              "transport_available" => false,
              "transport_owner_pid" => transport_owner_pid(session_ref),
              "transport_note" => unowned_transport_note(session_ref)
            )
          )
        end

        build_session_ref_from_file(session_ref)
      end

      def session_settings_supported?
        true
      end

      def model_catalog_supported?
        true
      end

      # Authoritative model list straight from Pi. Pi answers
      # `get_available_models` per process rather than per session, so this uses
      # a short-lived ephemeral RPC probe instead of borrowing a worker's
      # transport, which stays owned by whatever is prompting it.
      def available_models(cwd: nil)
        probe_cwd = catalog_probe_cwd(cwd)
        process = start_rpc_process(argv: build_model_catalog_argv, cwd: probe_cwd)
        begin
          data = rpc_data(
            process.request({ "type" => "get_available_models" }, timeout: model_catalog_timeout)
          )
          ModelCatalog.available(
            harness: harness_name,
            models: Array(data["models"]).filter_map { |model| model_catalog_entry(model) },
            source: MODEL_CATALOG_SOURCE
          )
        ensure
          process.terminate(timeout: shutdown_timeout)
        end
      rescue StandardError => e
        ModelCatalog.unavailable(
          harness: harness_name,
          note: "Could not read Pi's model catalog: #{e.message}",
          source: MODEL_CATALOG_SOURCE,
          reason: "fetch_failed",
          error: e.class.name
        )
      end

      def get_session_settings(session_ref)
        state_ref = get_state(session_ref)
        {
          "session_ref" => state_ref,
          "settings" => state_ref.fetch("session_settings", unknown_session_settings("Pi did not report session settings."))
        }
      end

      def set_session_model(session_ref, model_reference)
        provider, model_id = parse_model_reference!(model_reference)
        state_ref, process, attached = writable_session_state(session_ref)
        rpc_data(
          process.request(
            { "type" => "set_model", "provider" => provider, "modelId" => model_id },
            timeout: command_timeout
          )
        )
        updated_ref = get_state(state_ref)
        effective_reference = updated_ref.dig("session_settings", "model", "reference")
        requested_reference = "#{provider}/#{model_id}"
        unless effective_reference == requested_reference
          raise InvalidModelReferenceError,
                "Pi did not apply model #{requested_reference.inspect}; effective model is #{effective_reference || "unknown"}."
        end

        { "session_ref" => updated_ref, "settings" => updated_ref.fetch("session_settings") }
      rescue StandardError
        release_settings_attachment(process, state_ref) if attached
        raise
      end

      def set_session_thinking_level(session_ref, level)
        requested_level = level.to_s.strip.downcase
        unless THINKING_LEVELS.include?(requested_level)
          raise InvalidThinkingLevelError,
                "Invalid Pi thinking level #{level.inspect}. Valid levels: #{THINKING_LEVELS.join(", ")}"
        end

        state_ref, process, attached = writable_session_state(session_ref)
        available = rpc_data(
          process.request({ "type" => "get_available_thinking_levels" }, timeout: command_timeout)
        ).fetch("levels", []).map(&:to_s)
        unless available.include?(requested_level)
          model = state_ref.dig("session_settings", "model", "reference") || "the current model"
          raise InvalidThinkingLevelError,
                "Pi model #{model} does not support thinking level #{requested_level.inspect}. " \
                "Available levels: #{available.join(", ")}"
        end

        rpc_data(
          process.request({ "type" => "set_thinking_level", "level" => requested_level }, timeout: command_timeout),
          allow_nil_data: true
        )
        updated_ref = get_state(state_ref)
        effective_level = updated_ref.dig("session_settings", "thinking_level")
        unless effective_level == requested_level
          raise InvalidThinkingLevelError,
                "Pi did not apply thinking level #{requested_level.inspect}; effective level is #{effective_level || "unknown"}."
        end

        { "session_ref" => updated_ref, "settings" => updated_ref.fetch("session_settings") }
      rescue StandardError
        release_settings_attachment(process, state_ref) if attached
        raise
      end

      def read_events(session_ref)
        process = process_for(session_ref, required: false)
        return [] unless process

        process.drain_events(consumer: "kernel")
      end

      def open_session_view(session_ref)
        process = process_for(session_ref, required: false)
        return history_session_view(session_ref) unless process

        initial_cursor = process.event_cursor
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
        process = process_for(session_ref, required: false)
        return get_state(session_ref) if process
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
        argv = build_argv(session_name: session_name, system_prompt: nil, session: session)
        process = start_rpc_process(argv: argv, cwd: expanded_cwd)
        register_process(process)

        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        set_session_name(process, session_name) if present?(session_name)
        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        resumed_ref = build_session_ref(process, state, kind: metadata_value(session_ref, "kind"), cwd: expanded_cwd,
                                                        session_name: session_name)
        attached_ref = resumed_ref.merge(
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

      def wait_for_event(session_ref, type:, timeout: event_timeout)
        process = process_for(session_ref)
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

      def wait_for_settled(session_ref, timeout: event_timeout)
        wait_for_event(session_ref, type: "agent_settled", timeout: timeout)
      end

      def last_assistant_text(session_ref)
        process = process_for(session_ref, required: false)
        if process
          data = rpc_data(process.request({ "type" => "get_last_assistant_text" }, timeout: command_timeout))
          return data["text"]
        end

        session_file_summary(session_ref).fetch("last_assistant_text", nil)
      end

      private

      attr_reader :transport_ownership, :takeover_settle_timeout

      def model_catalog_timeout
        [command_timeout.to_i, DEFAULT_MODEL_CATALOG_TIMEOUT].max
      end

      # The probe keeps the configured resource flags (extensions, tools) so the
      # listed models match what a future head/worker could really select, but
      # drops `--model`/`--thinking` because an unavailable saved default would
      # otherwise make Pi exit before it can answer. `--no-session` keeps the
      # probe from writing a session file.
      def build_model_catalog_argv
        Array(command).map(&:to_s) + ["--mode", "rpc", "--no-session"] +
          without_options(extra_args, "--model", "--thinking")
      end

      def catalog_probe_cwd(cwd)
        [cwd, Dir.pwd, Dir.tmpdir].compact.each do |candidate|
          expanded = File.expand_path(candidate.to_s)
          return expanded if Dir.exist?(expanded)
        end
        raise Error, "No usable working directory for a Pi model catalog probe"
      end

      def model_catalog_entry(model)
        return nil unless model.is_a?(Hash)

        provider = model["provider"].to_s
        model_id = (model["id"] || model["modelId"]).to_s
        return nil if provider.empty? || model_id.empty?

        ModelCatalog.entry(
          provider: provider,
          id: model_id,
          name: model["name"],
          thinking_levels: supported_thinking_levels(model),
          reasoning: !!model["reasoning"],
          context_window: model["contextWindow"],
          max_tokens: model["maxTokens"]
        )
      end

      # Mirrors Pi's own rule (pi-ai `getSupportedThinkingLevels`) so the levels
      # Meringue offers for a model are the levels `set_thinking_level` accepts.
      def supported_thinking_levels(model)
        return ["off"] unless model["reasoning"]

        map = model["thinkingLevelMap"]
        map = nil unless map.is_a?(Hash)
        THINKING_LEVELS.select do |level|
          mapped_present = map&.key?(level)
          next false if mapped_present && map[level].nil?
          next !!mapped_present if EXPLICIT_THINKING_LEVELS.include?(level)

          true
        end
      end

      def parse_model_reference!(model_reference)
        reference = model_reference.to_s.strip
        provider, model_id, extra = reference.split("/", 3)
        if !present?(provider) || !present?(model_id) || present?(extra)
          raise InvalidModelReferenceError,
                "Pi models must use an exact provider/model id, for example openai/gpt-5.6-sol."
        end

        [provider, model_id]
      end

      def writable_session_state(session_ref)
        if unmanaged_process_alive?(session_ref) && !process_for(session_ref, required: false)
          owner_pid = transport_owner_pid(session_ref)
          owner = owner_pid ? "Meringue instance #{owner_pid}" : "another Meringue instance"
          raise SessionTransportUnavailableError,
                "This Pi session is owned by #{owner}; update it from that window or wait until it is resumable."
        end

        existing_process = process_for(session_ref, required: false)
        state_ref = if existing_process
                      get_state(session_ref)
                    else
                      attach_session(session_ref)
                    end
        if state_ref.fetch("is_streaming", false)
          raise SessionSettingsBusyError,
                "Pi session is currently running; wait for it to settle before changing its model or thinking level."
        end

        [state_ref, process_for(state_ref), existing_process.nil?]
      end

      def release_settings_attachment(process, session_ref)
        return unless process

        process.terminate(timeout: shutdown_timeout)
        unregister_process(process)
        release_transport(session_ref || {}, pid: process.pid)
      rescue StandardError
        nil
      end

      def session_settings_from_pi_state(pi_state)
        model = pi_state["model"]
        normalized_model = normalize_pi_model(model)
        thinking_level = present?(pi_state["thinkingLevel"]) ? pi_state["thinkingLevel"].to_s : nil
        session_settings(
          model: normalized_model,
          thinking_level: thinking_level,
          source: "live_session_state",
          note: normalized_model || thinking_level ? nil : "Pi get_state did not report a model or thinking level."
        )
      end

      def session_settings_from_session_records(records)
        entries = Array(records).select { |record| record.is_a?(Hash) && present?(record["id"]) }
        by_id = entries.to_h { |record| [record["id"].to_s, record] }
        branch = []
        cursor = entries.last
        seen = {}
        while cursor && !seen[cursor["id"].to_s]
          branch << cursor
          seen[cursor["id"].to_s] = true
          parent_id = cursor["parentId"]
          cursor = present?(parent_id) ? by_id[parent_id.to_s] : nil
        end
        branch.reverse!

        model_change = branch.reverse.find { |record| record["type"] == "model_change" }
        assistant = branch.reverse.find do |record|
          record["type"] == "message" && record.dig("message", "role") == "assistant"
        end
        provider = model_change&.fetch("provider", nil) || assistant&.dig("message", "provider")
        model_id = model_change&.fetch("modelId", nil) || assistant&.dig("message", "model")
        normalized_model = if present?(provider) && present?(model_id)
                             normalize_pi_model("provider" => provider, "id" => model_id)
                           end
        thinking_change = branch.reverse.find { |record| record["type"] == "thinking_level_change" }
        thinking_level = thinking_change&.fetch("thinkingLevel", nil)&.to_s

        session_settings(
          model: normalized_model,
          thinking_level: thinking_level,
          source: "persisted_session",
          note: normalized_model || thinking_level ? nil : "Pi session metadata does not contain model or thinking settings."
        )
      end

      def normalize_pi_model(model)
        return nil unless model.is_a?(Hash)

        provider = model["provider"].to_s
        model_id = (model["id"] || model["modelId"]).to_s
        return nil if provider.empty? || model_id.empty?

        {
          "provider" => provider,
          "id" => model_id,
          "reference" => "#{provider}/#{model_id}",
          "name" => present?(model["name"]) ? model["name"].to_s : nil
        }.compact
      end

      def session_settings(model:, thinking_level:, source:, note: nil)
        availability = if model && thinking_level
                         "available"
                       elsif model || thinking_level
                         "partial"
                       else
                         "unknown"
                       end
        {
          "model" => model,
          "thinking_level" => thinking_level,
          "availability" => availability,
          "source" => source,
          "note" => note
        }.compact
      end

      def unknown_session_settings(note)
        {
          "model" => nil,
          "thinking_level" => nil,
          "availability" => "unknown",
          "source" => "pi",
          "note" => note.to_s
        }
      end

      # Key that identifies one durable harness session across Meringue
      # instances. The session id is stable across resumes of the same session.
      def transport_key(session_ref)
        session_id = session_ref["session_id"] || session_ref[:session_id]
        return "pi-#{session_id}" if present?(session_id)

        session_file = session_ref["session_file"] || session_ref[:session_file]
        return "pi-#{File.basename(session_file.to_s, ".jsonl")}" if present?(session_file)

        pid = session_ref["pid"] || session_ref[:pid]
        present?(pid) ? "pi-pid-#{pid}" : nil
      end

      def claim_transport(session_ref, note: nil)
        key = transport_key(session_ref)
        return false unless key

        transport_ownership.claim(
          key,
          pid: session_ref["pid"] || session_ref[:pid],
          session_id: session_ref["session_id"] || session_ref[:session_id],
          note: note
        )
      rescue StandardError
        false
      end

      def release_transport(session_ref, pid: nil)
        key = transport_key(session_ref)
        return false unless key

        transport_ownership.release(key, pid: pid)
      rescue StandardError
        false
      end

      # Coordinated single-writer takeover.
      #
      # Returns a description of what happened so the caller can record it. It
      # only raises when another *live* Meringue instance is still mid-turn on
      # the session, and that message tells the user what to do.
      def take_over_transport(session_ref)
        key = transport_key(session_ref)
        return { "action" => "none", "resumable" => resumable_session?(session_ref) } unless key

        transport_ownership.with_lease(key) do |lease|
          pid = live_unowned_pid(session_ref, lease)
          unless pid
            lease.release!(pid: lease.harness_pid) if lease.harness_pid && !process_alive?(lease.harness_pid)
            next { "action" => "none", "resumable" => resumable_session?(session_ref) }
          end

          owner_pid = owner_pid_for(pid, lease)
          owner_alive = owner_pid && owner_pid != Process.pid && ProcessIdentity.alive?(owner_pid)
          raise SessionBusyError, busy_owner_message(owner_pid, pid) if owner_alive && !settled_for_takeover?(session_ref)

          terminate_unowned_process(pid)
          lease.release!(pid: pid)
          {
            "action" => "reclaimed",
            "reclaimed_pid" => pid,
            "previous_owner_pid" => owner_pid,
            "previous_owner_alive" => !!owner_alive,
            "resumable" => true
          }
        end
      rescue TransportOwnership::LockTimeout => e
        raise SessionTransportUnavailableError,
              "#{e.message}. Another Meringue instance is taking this session over right now; retry in a moment."
      end

      # Recovery details recorded on the worker so a takeover is auditable in
      # state and in the focused workspace.
      def takeover_metadata(takeover)
        return {} unless takeover.is_a?(Hash) && takeover.fetch("action", nil) == "reclaimed"

        {
          "transport_available" => true,
          "transport_reclaimed_at" => Time.now.utc.iso8601,
          "transport_reclaimed_pid" => takeover["reclaimed_pid"],
          "transport_previous_owner_pid" => takeover["previous_owner_pid"],
          "transport_note" => "Meringue instance #{Process.pid} took this Pi session over from " \
                              "#{takeover["previous_owner_pid"] || "a previous owner"} and resumed it from its session file."
        }.compact
      end

      # The lock record is more current than a persisted session ref, so it wins
      # when it names a live harness process for this session.
      def live_unowned_pid(session_ref, lease)
        candidates = [lease.harness_pid, session_ref["pid"] || session_ref[:pid]].compact.uniq
        candidates.find do |candidate|
          next false if process_for({ "pid" => candidate }, required: false)

          live_harness_process?(candidate, session_ref)
        end
      end

      def owner_pid_for(pid, lease)
        recorded = lease.recorded_owner_pid if lease.harness_pid == pid
        return recorded if recorded

        description = ProcessIdentity.describe(pid)
        parent = description && description.fetch("ppid", nil)
        parent && parent > 1 ? parent : nil
      end

      # A pid alone can belong to an unrelated process after reuse. Only a live
      # process that still looks like our configured Pi command is treated as a
      # harness transport, and only such a process is ever signaled.
      def live_harness_process?(pid, session_ref)
        return false unless process_alive?(pid)

        ProcessIdentity.matches?(
          pid,
          command: Array(command).first,
          started_at: metadata_value(session_ref, "started_at")
        )
      end

      # Waits briefly for another instance's in-flight turn to finish. Pi appends
      # completed assistant messages to the session file, so settling is visible
      # without owning the transport.
      def settled_for_takeover?(session_ref)
        deadline = monotonic_time + takeover_settle_timeout
        loop do
          return true if resumable_session?(session_ref)
          return false if monotonic_time >= deadline

          sleep TAKEOVER_POLL_INTERVAL
        end
      end

      def resumable_session?(session_ref)
        session_file_summary(session_ref).fetch("completed", false)
      rescue StandardError
        false
      end

      def terminate_unowned_process(pid)
        signal_unowned_process("TERM", pid)
        return true unless wait_for_process_exit(pid, TAKEOVER_EXIT_TIMEOUT)

        signal_unowned_process("KILL", pid)
        wait_for_process_exit(pid, TAKEOVER_EXIT_TIMEOUT)
        !process_alive?(pid)
      end

      def signal_unowned_process(signal, pid)
        Process.kill(signal, Integer(pid))
        true
      rescue Errno::ESRCH, ArgumentError, TypeError
        false
      rescue Errno::EPERM
        raise SessionTransportUnavailableError,
              "Pi process #{pid} belongs to another user, so this Meringue instance cannot take its session over. " \
              "Stop that process, or continue this issue with a new worker."
      end

      # Returns true when the process is still alive after the timeout.
      def wait_for_process_exit(pid, timeout)
        deadline = monotonic_time + timeout
        while process_alive?(pid)
          return true if monotonic_time >= deadline

          sleep TAKEOVER_POLL_INTERVAL
        end
        false
      end

      def busy_owner_message(owner_pid, pid)
        "Meringue instance #{owner_pid} owns this Pi session (process #{pid}) and is still mid-turn. " \
          "Prompting will take it over automatically once that turn settles: retry in a moment, " \
          "or quit instance #{owner_pid} to hand the session over now."
      end

      def transport_owner_pid(session_ref)
        key = transport_key(session_ref)
        return nil unless key

        record = transport_ownership.record_for(key)
        owner = record["owner_pid"]
        owner && Integer(owner) != Process.pid ? Integer(owner) : nil
      rescue StandardError
        nil
      end

      def unowned_transport_note(session_ref)
        owner_pid = transport_owner_pid(session_ref)
        if owner_pid && ProcessIdentity.alive?(owner_pid)
          "The saved Pi process is alive and Meringue instance #{owner_pid} owns its RPC pipes. " \
            "Showing persisted history; prompting takes the session over once its current turn settles."
        else
          "The saved Pi process is alive but no Meringue instance owns its RPC pipes. " \
            "Showing persisted history; prompting reclaims the session automatically."
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def build_argv(session_name:, system_prompt:, session: nil)
        argv = Array(command).map(&:to_s) + ["--mode", "rpc"]
        argv += ["--session-dir", File.expand_path(session_dir)] if present?(session_dir)
        argv += ["--session", session.to_s] if present?(session)
        argv += ["--name", session_name.to_s] if present?(session_name)
        argv += ["--append-system-prompt", system_prompt.to_s] if present?(system_prompt)
        session_arguments = extra_args
        # Model/thinking defaults are spawn-only. Passing newly configured
        # defaults while resuming an existing session would silently mutate the
        # very session that global commands promise to leave unchanged.
        session_arguments = without_options(session_arguments, "--model", "--thinking") if present?(session)
        argv + session_arguments
      end

      def without_options(arguments, *options)
        result = []
        skip_next = false
        Array(arguments).each do |argument|
          if skip_next
            skip_next = false
            next
          end

          text = argument.to_s
          if options.include?(text)
            skip_next = true
          elsif options.any? { |option| text.start_with?("#{option}=") }
            next
          else
            result << text
          end
        end
        result
      end

      def start_rpc_process(argv:, cwd:)
        stdin, stdout, stderr, wait_thread = Open3.popen3(env, *argv, chdir: cwd)
        RpcProcess.new(stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread,
                       argv: argv, cwd: cwd)
      rescue Errno::ENOENT => e
        raise Error, "Unable to start Pi RPC process with #{argv.first.inspect}: #{e.message}"
      end

      def set_session_name(process, session_name)
        rpc_data(
          process.request({ "type" => "set_session_name", "name" => session_name.to_s },
                          timeout: command_timeout),
          allow_nil_data: true
        )
      end

      def build_session_ref(process, pi_state, kind:, cwd:, session_name:)
        {
          "harness" => "pi",
          "pid" => process.pid,
          "cwd" => cwd,
          "session_id" => pi_state["sessionId"],
          "session_file" => pi_state["sessionFile"],
          "is_streaming" => !!pi_state["isStreaming"],
          "last_event_at" => process.last_event_at,
          "session_settings" => session_settings_from_pi_state(pi_state),
          "metadata" => {
            "kind" => kind.to_s,
            "session_name" => session_name,
            "started_at" => process.started_at,
            "command" => process.argv,
            "pi_state" => pi_state,
            "stderr_tail" => process.stderr_tail
          }
        }
      end

      def build_session_ref_from_file(session_ref)
        summary = session_file_summary(session_ref)
        kind = metadata_value(session_ref, "kind").to_s
        unless summary.fetch("completed", false) || (summary.fetch("process_alive", false) && kind != "head")
          session = summary.fetch("session_file", nil) || summary.fetch("session_id", nil)
          if summary.fetch("process_alive", false)
            raise UnmanagedProcessError,
                  "Pi head session #{session} is still running outside this client and has no completed assistant response"
          end

          raise ProcessExitedError,
                "Pi session #{session} has no live process and no completed assistant response"
        end

        pi_state = {
          "sessionId" => summary.fetch("session_id", nil),
          "sessionFile" => summary.fetch("session_file", nil),
          "sessionName" => summary.fetch("session_name", nil),
          "isStreaming" => !summary.fetch("completed", false),
          "cwd" => summary.fetch("cwd", nil),
          "fromSessionFile" => true,
          "processAlive" => summary.fetch("process_alive", false),
          "completed" => summary.fetch("completed", false),
          "lastStopReason" => summary.fetch("last_stop_reason", nil)
        }

        session_ref.merge(
          "harness" => "pi",
          "pid" => session_ref["pid"] || session_ref[:pid],
          "cwd" => summary.fetch("cwd", nil) || session_ref["cwd"] || session_ref[:cwd],
          "session_id" => summary.fetch("session_id", nil) || session_ref["session_id"] || session_ref[:session_id],
          "session_file" => summary.fetch("session_file", nil),
          "is_streaming" => !summary.fetch("completed", false),
          "last_event_at" => summary.fetch("last_event_at", nil),
          "session_settings" => summary.fetch("session_settings"),
          "metadata" => metadata_with(
            session_ref,
            "session_name" => summary.fetch("session_name", nil) || metadata_value(session_ref, "session_name"),
            "pi_state" => pi_state,
            "session_file_summary" => summary,
            "reconnected_from_session_file" => true
          )
        )
      end

      def session_file_summary(session_ref)
        path = session_file_path(session_ref)
        raise ProcessNotFoundError, "Pi session file is missing for #{session_ref_summary(session_ref)}" unless path && File.file?(path)

        summary = {
          "session_file" => path,
          "session_id" => session_ref["session_id"] || session_ref[:session_id],
          "process_alive" => process_alive?(session_ref["pid"] || session_ref[:pid]),
          "completed" => false,
          "last_assistant_text" => nil,
          "last_stop_reason" => nil,
          "last_event_at" => nil,
          "cwd" => session_ref["cwd"] || session_ref[:cwd],
          "session_name" => metadata_value(session_ref, "session_name")
        }
        last_assistant = nil
        records = []

        File.foreach(path) do |line|
          record = JSON.parse(line)
          records << record
          summary["last_event_at"] = record["timestamp"] if record["timestamp"]
          if record["type"] == "session"
            summary["session_id"] ||= record["id"]
            summary["cwd"] ||= record["cwd"]
          elsif record["type"] == "session_info"
            summary["session_name"] = record["name"] if record["name"]
          elsif record["type"] == "message" && record.dig("message", "role") == "assistant"
            last_assistant = record
            text = assistant_text_from_message(record)
            summary["last_assistant_text"] = text if present?(text)
            stop_reason = record["stopReason"] || record.dig("message", "stopReason")
            summary["last_stop_reason"] = stop_reason if present?(stop_reason)
          end
        rescue JSON::ParserError
          next
        end

        summary["completed"] = assistant_message_completed?(last_assistant)
        summary["session_settings"] = session_settings_from_session_records(records)
        summary
      end

      def session_file_path(session_ref)
        path = session_ref["session_file"] || session_ref[:session_file]
        expanded_path = File.expand_path(path) if present?(path)
        return expanded_path if expanded_path && File.file?(expanded_path)

        session_id = session_ref["session_id"] || session_ref[:session_id]
        discovered_path = if present?(session_id) && session_dir
                            Dir[File.join(File.expand_path(session_dir), "*#{session_id}*.jsonl")].max_by { |candidate| File.mtime(candidate) }
                          end

        discovered_path || expanded_path
      end

      def resume_session_argument(session_ref)
        path = session_file_path(session_ref)
        return path if present?(path) && File.file?(path)

        session_id = session_ref["session_id"] || session_ref[:session_id]
        return session_id if present?(session_id)

        raise ProcessNotFoundError, "Pi session cannot be resumed without a session file or session id: #{session_ref_summary(session_ref)}"
      end

      def session_ref_summary(session_ref)
        metadata = session_ref["metadata"] || session_ref[:metadata] || {}
        {
          "pid" => session_ref["pid"] || session_ref[:pid],
          "session_id" => session_ref["session_id"] || session_ref[:session_id],
          "session_file" => session_ref["session_file"] || session_ref[:session_file],
          "cwd" => session_ref["cwd"] || session_ref[:cwd],
          "kind" => metadata["kind"] || metadata[:kind],
          "session_name" => metadata["session_name"] || metadata[:session_name]
        }.compact
      end

      def assistant_text_from_message(record)
        Array(record.dig("message", "content")).filter_map do |part|
          part["text"] if part.is_a?(Hash) && part["type"] == "text"
        end.join("\n").strip
      end

      def assistant_message_completed?(record)
        return false unless record

        stop_reason = record["stopReason"] || record.dig("message", "stopReason")
        return false if stop_reason.to_s == "toolUse"
        return true if present?(stop_reason)

        Array(record.dig("message", "content")).any? do |part|
          part.is_a?(Hash) && part["type"] == "text" && present?(part["text"])
        end
      end

      def history_session_view(session_ref)
        cache_mutex = Mutex.new
        cached_signature = nil
        cached_snapshot = nil
        SessionView::Handle.new(
          snapshot_loader: lambda {
            path = session_ref["session_file"] || session_ref[:session_file]
            signature = begin
              stat = path && File.stat(File.expand_path(path.to_s))
              [stat.size, stat.mtime.to_f]
            rescue SystemCallError
              [:missing]
            end
            process_alive = unmanaged_process_alive?(session_ref)
            signature << process_alive
            cache_mutex.synchronize do
              if cached_snapshot && cached_signature == signature
                next cached_snapshot
              end

              cached_signature = signature
              cached_snapshot = PiSessionView.history_snapshot(session_ref: session_ref, process_alive: process_alive)
            end
          }
        )
      end

      def unmanaged_process_alive?(session_ref)
        pid = session_ref["pid"] || session_ref[:pid]
        process_alive?(pid) && process_for(session_ref, required: false).nil?
      end

      def process_alive?(pid)
        return false unless present?(pid)

        Process.kill(0, pid.to_i)
        true
      rescue Errno::ESRCH, TypeError, ArgumentError
        false
      rescue Errno::EPERM
        true
      end

      def rpc_data(response, allow_nil_data: false)
        unless response.is_a?(Hash) && response["type"] == "response"
          raise RpcError, "Expected Pi RPC response, got: #{response.inspect}"
        end

        unless response["success"]
          raise RpcError, response["error"].to_s.empty? ? "Pi RPC command failed" : response["error"].to_s
        end

        data = response["data"]
        return data if data || allow_nil_data

        raise RpcError, "Pi RPC response for #{response["command"].inspect} did not include data"
      end

      def validate_cwd!(cwd)
        expanded = File.expand_path(cwd.to_s)
        raise ArgumentError, "cwd must be an existing directory: #{cwd.inspect}" unless Dir.exist?(expanded)

        expanded
      end

      def normalize_mode!(mode)
        normalized = MODE_ALIASES[mode.to_s]
        return normalized if normalized

        raise InvalidModeError, "Unknown Pi prompt mode: #{mode.inspect}"
      end

      def register_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid[process.pid] = process
        end
      end

      def unregister_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid.delete(process.pid)
        end
      end

      def process_for(session_ref, required: true)
        pid = session_ref["pid"] || session_ref[:pid]
        process = @processes_mutex.synchronize { @processes_by_pid[pid] }

        return process if process && process.alive?
        return nil unless required

        raise ProcessNotFoundError, "No live Pi RPC process for pid #{pid.inspect}"
      end

      def metadata_value(session_ref, key)
        metadata = session_ref["metadata"] || session_ref[:metadata] || {}
        metadata[key] || metadata[key.to_sym]
      end

      def metadata_with(session_ref, values)
        metadata = (session_ref["metadata"] || session_ref[:metadata] || {}).dup
        metadata.merge(values)
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      class RpcProcess
        attr_reader :stdin, :stdout, :stderr, :wait_thread, :argv, :cwd, :pid, :started_at,
                    :last_event_at, :exit_status

        def initialize(stdin:, stdout:, stderr:, wait_thread:, argv:, cwd:)
          @stdin = stdin
          @stdout = stdout
          @stderr = stderr
          @wait_thread = wait_thread
          @argv = argv
          @cwd = cwd
          @pid = wait_thread.pid
          @started_at = Time.now.utc.iso8601
          @last_event_at = nil
          @exit_status = nil
          @pending = {}
          @pending_mutex = Mutex.new
          @write_mutex = Mutex.new
          @event_journal = EventJournal.new
          @consumer_cursors = {}
          @consumer_mutex = Mutex.new
          @stderr_buffer = +""
          @stderr_mutex = Mutex.new

          @stdin.sync = true
          start_stdout_reader
          start_stderr_reader
          start_exit_watcher
        end

        def request(command, timeout:)
          ensure_alive!

          id = command.fetch("id") { "req_#{SecureRandom.hex(8)}" }
          queue = Queue.new
          payload = command.merge("id" => id)

          @pending_mutex.synchronize { @pending[id] = queue }
          write_json(payload)

          result = Timeout.timeout(timeout) { queue.pop }
          raise result if result.is_a?(Exception)

          result
        rescue Timeout::Error
          @pending_mutex.synchronize { @pending.delete(id) } if id
          raise RpcTimeoutError, "Timed out waiting for Pi RPC response to #{command["type"].inspect}"
        rescue IOError, Errno::EPIPE => e
          @pending_mutex.synchronize { @pending.delete(id) } if id
          raise ProcessExitedError, "Pi RPC stdin is closed: #{e.message}"
        end

        def drain_events(consumer: "default")
          result = read_for_consumer(consumer)
          result.fetch("entries").map { |entry| entry.fetch("event") }
        end

        def event_cursor
          @event_journal.cursor
        end

        def events_after(cursor, limit: nil)
          @event_journal.read(after: cursor, limit: limit)
        end

        def next_event(timeout:, consumer: "waiter")
          cursor = consumer_cursor(consumer)
          result = @event_journal.wait(after: cursor, timeout: timeout, limit: 1)
          entry = result.fetch("entries").first
          raise RpcTimeoutError, "Timed out waiting for next Pi RPC event" unless entry

          update_consumer_cursor(consumer, result.fetch("cursor"))
          entry.fetch("event")
        end

        def stderr_tail
          @stderr_mutex.synchronize { @stderr_buffer.dup }
        end

        def alive?
          wait_thread.alive?
        end

        def terminate(timeout:)
          close_stdin
          send_signal("TERM") if alive?
          wait_for_exit(timeout)
          send_signal("KILL") if alive?
          wait_for_exit(0.5)
        end

        private

        def ensure_alive!
          return if alive?

          raise ProcessExitedError, "Pi RPC process #{pid} is not running. Stderr: #{stderr_tail}"
        end

        def write_json(payload)
          @write_mutex.synchronize do
            stdin.write(JSON.generate(payload))
            stdin.write("\n")
            stdin.flush
          end
        end

        def start_stdout_reader
          @stdout_thread = Thread.new do
            Thread.current.abort_on_exception = false
            buffer = +""

            begin
              loop do
                buffer << stdout.readpartial(4096)
                buffer = emit_complete_lines(buffer)
              end
            rescue EOFError
              emit_line(buffer) unless buffer.empty?
            rescue IOError
              # Process shutdown closes the pipe.
            end
          end
        end

        def emit_complete_lines(buffer)
          while (newline_index = buffer.index("\n"))
            line = buffer.slice!(0..newline_index)
            line = line[0...-1]
            emit_line(line)
          end

          buffer
        end

        def emit_line(line)
          line = line[0...-1] if line.end_with?("\r")
          return if line.empty?

          record = JSON.parse(line)
          if record["type"] == "response" && record["id"]
            pending_queue = @pending_mutex.synchronize { @pending.delete(record["id"]) }
            if pending_queue
              pending_queue << record
            else
              enqueue_event(record)
            end
          else
            enqueue_event(record)
          end
        rescue JSON::ParserError => e
          enqueue_event(
            "type" => "rpc_parse_error",
            "error" => e.message,
            "line" => line
          )
        end

        def start_stderr_reader
          @stderr_thread = Thread.new do
            Thread.current.abort_on_exception = false
            begin
              loop do
                append_stderr(stderr.readpartial(4096))
              end
            rescue EOFError, IOError
              # Process shutdown closes the pipe.
            end
          end
        end

        def append_stderr(chunk)
          @stderr_mutex.synchronize do
            @stderr_buffer << chunk.to_s
            @stderr_buffer = @stderr_buffer[-MAX_STDERR_CHARS, MAX_STDERR_CHARS] || @stderr_buffer if @stderr_buffer.length > MAX_STDERR_CHARS
          end
        end

        def start_exit_watcher
          @exit_thread = Thread.new do
            Thread.current.abort_on_exception = false
            status = wait_thread.value
            @exit_status = {
              "exit_code" => status.exitstatus,
              "termsig" => status.termsig,
              "success" => status.success?
            }
            enqueue_event("type" => "process_exit", "pid" => pid, "status" => @exit_status)
            fail_pending(ProcessExitedError.new("Pi RPC process #{pid} exited with #{@exit_status.inspect}"))
          end
        end

        def enqueue_event(event)
          @last_event_at = Time.now.utc.iso8601
          @event_journal.publish(event)
        end

        def read_for_consumer(consumer)
          cursor = consumer_cursor(consumer)
          result = @event_journal.read(after: cursor)
          update_consumer_cursor(consumer, result.fetch("cursor"))
          result
        end

        def consumer_cursor(consumer)
          @consumer_mutex.synchronize { @consumer_cursors.fetch(consumer.to_s, 0) }
        end

        def update_consumer_cursor(consumer, cursor)
          @consumer_mutex.synchronize { @consumer_cursors[consumer.to_s] = cursor.to_i }
        end

        def fail_pending(error)
          queues = @pending_mutex.synchronize do
            pending = @pending.values
            @pending.clear
            pending
          end
          queues.each { |queue| queue << error }
        end

        def close_stdin
          stdin.close unless stdin.closed?
        rescue IOError
          nil
        end

        def send_signal(signal)
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end

        def wait_for_exit(timeout)
          deadline = Time.now + timeout
          sleep 0.05 while alive? && Time.now < deadline
        end
      end
    end
  end
end
