# frozen_string_literal: true

require "fileutils"
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
      INTERACTIVE_RPC_SHUTDOWN_TIMEOUT = 0.1
      PROMPT_DELIVERY_MARKER_PREFIX = "<!-- meringue-prompt-delivery:".freeze

      MODE_ALIASES = {
        "normal" => "normal",
        "steer" => "steer",
        "follow_up" => "follow_up",
        "followUp" => "follow_up"
      }.freeze

      class Error < StandardError; end
      class ProcessNotFoundError < Error; end
      # A Pi RPC session is one long-lived process, so its exit is terminal for that session's
      # transport: no later RPC can be answered, and re-prompting it only times out. The marker
      # tells the kernel to settle the worker with the real cause instead of retrying it as if the
      # session were momentarily busy.
      class ProcessExitedError < Error
        include Harness::SessionProcessGoneError
      end
      class SessionTransportUnavailableError < Error; end
      # Another live Meringue instance owns the session and is still mid-turn. Prompting succeeds
      # once that turn settles, so the kernel queues and retries instead of failing the command.
      class SessionBusyError < SessionTransportUnavailableError
        include Harness::TransientSessionError
      end
      class UnmanagedProcessError < Error; end
      class RpcError < Error; end
      class RpcTimeoutError < Error
        attr_reader :command_type

        def initialize(message = nil, command_type: nil)
          @command_type = command_type&.to_s
          super(message)
        end
      end
      class InvalidModeError < Error; end
      class InvalidModelReferenceError < Error; end
      class InvalidThinkingLevelError < Error; end
      class SessionSettingsBusyError < Error; end

      THINKING_LEVELS = ModelCatalog::THINKING_LEVELS
      # Pi only offers these two levels when a model explicitly maps them.
      EXPLICIT_THINKING_LEVELS = %w[xhigh max].freeze
      MODEL_CATALOG_SOURCE = "pi_rpc_get_available_models"
      # A catalog probe is a throwaway ephemeral Pi process, so it should not
      # inherit the long event timeout used for real agent turns.
      DEFAULT_MODEL_CATALOG_TIMEOUT = 30

      # Pi records why a turn stopped on its final assistant message. "error" is a
      # provider/transport failure (dropped connection, DNS/TLS failure, 5xx,
      # exhausted auto-retries): the turn ended without finishing its work.
      TURN_FAILURE_STOP_REASONS = %w[error].freeze
      # A settled session whose last assistant message is still waiting on a tool
      # call—or was intentionally aborted for an ownership handoff—never reached a
      # final answer. These are recoverable interruptions rather than completions.
      TURN_INCOMPLETE_STOP_REASONS = %w[toolUse abort aborted].freeze
      # Reading the tail is enough to find the final assistant message, and keeps
      # the 2s reconciliation loop from re-parsing multi-megabyte session files.
      TURN_OUTCOME_TAIL_BYTES = 64 * 1024
      NETWORK_ERROR_PATTERN = /
        connection|network|socket|dns|offline|unreachable|refused|reset
        |econn|etimedout|enotfound|epipe|timeout|timed\s?out
        |tls|ssl|certificate|handshake|proxy|gateway|fetch\sfailed
        |overloaded|502|503|504
      /ix.freeze
      # A provider rejection of the *transcript itself* rather than of one unlucky request.
      # Anthropic-style routes refuse a replayed assistant turn whose `thinking`/
      # `redacted_thinking` blocks are not byte-identical to what they originally returned, and
      # nothing about resuming changes that: the same saved turn is replayed, so the same request
      # is refused again. Retrying such a session is guaranteed to fail, which is why it is
      # classified apart from a transport blip.
      UNREPLAYABLE_SESSION_PATTERN = /
        (?:thinking|redacted_thinking)[^\n]{0,200}?cannot\s+be\s+modified
        |blocks\s+must\s+remain\s+as\s+they\s+were\s+in\s+the\s+original\s+response
        |expected\s+`?thinking`?\s+or\s+`?redacted_thinking`?
      /ix.freeze

      # Mirrors Pi's own `clampThinkingLevel`: a level a model does not advertise
      # resolves to the nearest level it does, searching up the ladder first and
      # then down. Pi clamps instead of failing, so Meringue uses this to say what
      # a future session will actually run rather than to hide a level a user is
      # allowed to set. A model's advertised list can under-report what the model
      # really supports (a proxy provider that omits `max` from its
      # `thinkingLevelMap`), which is exactly why it must not be treated as
      # permission to choose.
      def self.clamp_thinking_level(level, available_levels)
        available = Array(available_levels).map { |value| value.to_s.strip.downcase }.reject(&:empty?)
        requested = level.to_s.strip.downcase
        return requested if available.include?(requested)
        return available.first || "off" unless THINKING_LEVELS.include?(requested)
        return "off" if available.empty?

        index = THINKING_LEVELS.index(requested)
        THINKING_LEVELS[index..].find { |candidate| available.include?(candidate) } ||
          THINKING_LEVELS[0...index].reverse_each.find { |candidate| available.include?(candidate) } ||
          available.first
      end

      attr_reader :command, :env, :session_dir, :command_timeout,
                  :event_timeout, :shutdown_timeout

      def prompt_modes
        %w[normal steer follow_up]
      end

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
        @processes_by_transport_key = {}
        @processes_mutex = Mutex.new
        @prompt_receipt_cache = {}
        @prompt_receipt_mutex = Mutex.new
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

      def read_only_workspace_supported?
        true
      end

      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, session_settings: {}, workspace_mode: "isolated")
        expanded_cwd = validate_cwd!(cwd)
        argv = build_argv(
          session_name: session_name,
          system_prompt: system_prompt,
          session_settings: session_settings,
          workspace_mode: workspace_mode
        )
        process = start_rpc_process(argv: argv, cwd: expanded_cwd)
        register_process(process)

        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        set_session_name(process, session_name) if present?(session_name)
        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        session_ref = build_session_ref(
          process,
          state,
          kind: kind,
          cwd: expanded_cwd,
          session_name: session_name,
          workspace_mode: workspace_mode
        )
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

      def prompt_session(session_ref, prompt, mode: "normal", delivery_id: nil)
        normalized_mode = normalize_mode!(mode)
        message = prompt_with_delivery_marker(prompt.to_s, delivery_id)
        current_ref = session_ref
        recovery_metadata = {}
        process = process_for_session(current_ref, required: false)
        unless process
          # Another Meringue instance (or a previous run of this one) may hold
          # the pipes. Take the transport over instead of failing forever, then
          # continue on the resumed session.
          takeover = take_over_transport(current_ref)
          # A follow-up is still a valid continuation when the saved turn did not finish: after
          # reconciliation has discovered a dead Pi process, the only meaningful delivery is a
          # normal prompt into the resumed transcript. Steer is different because it promises to
          # interrupt a live turn, so keep rejecting it when there is no active transport.
          if normalized_mode == "steer" && !takeover.fetch("resumable", false)
            raise InvalidModeError,
                  "Pi session is not active; resume it with mode: \"normal\" before using #{normalized_mode.inspect}"
          end

          # A resumed session starts settled, so an urgent steer/follow-up has
          # nothing to interrupt and is delivered as a normal continuation.
          requested_mode = normalized_mode
          normalized_mode = "normal"
          current_ref = attach_session(current_ref)
          process = process_for_session(current_ref)
          recovery_metadata = takeover_metadata(takeover)
          if requested_mode != normalized_mode
            recovery_metadata["prompt_mode_downgraded_from"] = requested_mode
            recovery_metadata.merge!(
              delivered_mode_metadata(
                requested_mode: requested_mode,
                delivered_mode: normalized_mode,
                note: "The session was not live, so it was resumed and this #{prompt_mode_noun(requested_mode)} " \
                      "was delivered as a normal continuation."
              )
            )
          end
        end
        current_ref = get_state(current_ref)

        delivered_mode = normalized_mode
        # A prompt routed to a session that happens to be mid-turn is a timing condition, not a bad
        # request. Pi's follow_up queues the message behind the active turn, so it is delivered in
        # order instead of being dropped on the floor. Only "normal" is coerced: steer and follow_up
        # already say what they want to do to an active turn.
        if normalized_mode == "normal" && current_ref.fetch("is_streaming", false)
          delivered_mode = "follow_up"
          recovery_metadata.merge!(
            delivered_mode_metadata(
              requested_mode: normalized_mode,
              delivered_mode: delivered_mode,
              note: "The session was mid-turn, so this prompt was queued as a follow-up instead of " \
                    "interrupting the active turn."
            )
          )
        end

        command = case delivered_mode
                  when "normal"
                    { "type" => "prompt", "message" => message }
                  when "steer"
                    { "type" => "steer", "message" => message }
                  when "follow_up"
                    { "type" => "follow_up", "message" => message }
                  end

        rpc_data(process.request(command, timeout: command_timeout), allow_nil_data: true)
        prompted_ref = begin
          get_state(current_ref)
        rescue RpcTimeoutError => e
          # The prompt RPC itself was acknowledged. A follow-up state refresh cannot turn that
          # known delivery back into a failed PromptAgent command; reconciliation will refresh (or
          # settle) the session later without replaying the accepted prompt.
          current_ref.merge(
            "pid" => process.pid,
            "is_streaming" => true,
            "metadata" => metadata_with(
              current_ref,
              "prompt_delivery_acknowledged" => true,
              "prompt_state_refresh_error_class" => e.class.name,
              "prompt_state_refresh_error" => e.message
            )
          )
        end
        # get_state rebuilds metadata from the live process, so recovery details
        # are re-applied here to stay visible in state and logs.
        return prompted_ref if recovery_metadata.empty?

        prompted_ref.merge("metadata" => metadata_with(prompted_ref, recovery_metadata))
      end

      def prompt_delivery_receipts_supported?
        true
      end

      # A prompt RPC timeout does not cancel Pi's request. Pi may still be compacting a restored
      # transcript and can persist the user message well after Meringue's response deadline. Only
      # prompt-like RPCs therefore have an ambiguous delivery outcome; a get_state timeout happened
      # before prompt_session wrote anything and remains an ordinary command failure.
      def ambiguous_prompt_delivery_error?(error)
        error.is_a?(RpcTimeoutError) && %w[prompt steer follow_up].include?(error.command_type)
      end

      def prompt_delivery_status(session_ref, delivery_id:, prompt:, started_at: nil)
        marker = prompt_delivery_marker(delivery_id)
        path = session_file_path(session_ref)
        delivered, delivered_at = path && marker ? scan_prompt_delivery_receipt(path, marker) : [false, nil]

        process_error = nil
        live_pid = begin
          process = process_for_session(session_ref, required: false)
          process&.pid || unmanaged_process_pid(session_ref)
        rescue StandardError => e
          process_error = e
          nil
        end
        return {
          "status" => "delivered",
          "delivered_at" => delivered_at,
          "process_alive" => !live_pid.nil?,
          "pid" => live_pid,
          "session_file" => path
        }.compact if delivered

        # The session file is the durable delivery ledger. Once the process that owned the request
        # is gone, absence from that file proves that this delivery id can no longer appear.
        status = if process_error
                   "unknown"
                 elsif live_pid
                   "pending"
                 elsif path || present?(session_ref["session_file"] || session_ref[:session_file]) ||
                       present?(session_ref["session_id"] || session_ref[:session_id])
                   "not_delivered"
                 else
                   "unknown"
                 end
        {
          "status" => status,
          "process_alive" => !live_pid.nil?,
          "pid" => live_pid,
          "session_file" => path,
          "checked_at" => Time.now.utc.iso8601,
          "started_at" => started_at,
          "prompt_bytes" => prompt.to_s.bytesize,
          "error" => process_error && "#{process_error.class}: #{process_error.message}"
        }.compact
      rescue StandardError => e
        { "status" => "unknown", "error" => "#{e.class}: #{e.message}" }
      end

      def abort_session(session_ref)
        process = process_for_session(session_ref, required: false)
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
        process = process_for_session(session_ref, required: false)
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
        process = process_for_session(session_ref)
        if process
          begin
            state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
            return build_session_ref(
              process,
              state,
              kind: metadata_value(session_ref, "kind"),
              cwd: session_ref.fetch("cwd", process.cwd),
              session_name: metadata_value(session_ref, "session_name") || state["sessionName"],
              workspace_mode: metadata_value(session_ref, "workspace_mode") || "isolated"
            )
          rescue ProcessExitedError
            # The wait thread and an RPC-state read can cross by a few instructions. Once request
            # proves the child is gone, continue through durable session-file classification rather
            # than exposing a lower-level "RPC process is not running" race to reconciliation.
          end
        end

        if (unmanaged_pid = unmanaged_process_pid(session_ref))
          # RPC state belongs to the process that owns its pipes. The transport lease is newer than
          # the pid in state, so consult it too: a recovery process may have started after the last
          # state write. Treating that live replacement as dead could launch a second writer and
          # duplicate its continuation prompt.
          current_ref = session_ref.merge("pid" => unmanaged_pid)
          persisted_ref = build_session_ref_from_file(current_ref)
          return persisted_ref.merge(
            "harness" => "pi",
            "pid" => unmanaged_pid,
            "is_streaming" => true,
            "metadata" => metadata_with(
              persisted_ref,
              "transport_available" => false,
              "transport_owner_pid" => transport_owner_pid(current_ref),
              "transport_note" => unowned_transport_note(current_ref)
            )
          )
        end

        build_session_ref_from_file(session_ref)
      end

      # Pi's session statistics include current context usage and message counts.
      # Failures are intentionally represented as unavailable telemetry rather than
      # allowing a stats probe to make an otherwise healthy session look errored.
      def get_session_stats(session_ref)
        process = process_for_session(session_ref, required: false)
        return session_ref.fetch("session_stats", nil) unless process

        normalize_session_stats(rpc_data(process.request({ "type" => "get_session_stats" }, timeout: command_timeout)))
      rescue StandardError
        nil
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

        available_levels = rpc_data(
          process.request({ "type" => "get_available_thinking_levels" }, timeout: command_timeout)
        ).fetch("levels", []).filter_map do |available_level|
          level = available_level.to_s.strip.downcase
          level if THINKING_LEVELS.include?(level)
        end
        effective_level = updated_ref.dig("session_settings", "thinking_level").to_s.strip.downcase
        if !effective_level.empty? && !available_levels.include?(effective_level)
          fallback_level = compatible_thinking_level(effective_level, available_levels)
          unless fallback_level
            raise InvalidThinkingLevelError,
                  "Pi model #{requested_reference} does not support thinking level #{effective_level.inspect}, " \
                  "and reported no compatible fallback."
          end

          rpc_data(
            process.request({ "type" => "set_thinking_level", "level" => fallback_level }, timeout: command_timeout),
            allow_nil_data: true
          )
          updated_ref = get_state(state_ref)
          effective_level = updated_ref.dig("session_settings", "thinking_level")
          unless effective_level == fallback_level
            raise InvalidThinkingLevelError,
                  "Pi did not apply compatible thinking level #{fallback_level.inspect}; effective level is #{effective_level || "unknown"}."
          end
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

      # An exited process still holds the journal that recorded *why* it exited, including its own
      # `process_exit` event, its exit status, and its stderr. Requiring a live process here is what
      # threw that evidence away: `get_state` raises first for a dead session, so the exit event was
      # never drained and nothing in Meringue ever said the process had gone.
      def read_events(session_ref)
        process = process_for_session(session_ref, required: false) || exited_process_for(session_ref)
        return [] unless process

        process.drain_events(consumer: "kernel")
      end

      # Harness-neutral evidence about a session whose process is no longer running. Returns nil
      # when this client never owned the process (a different Meringue instance, or a restart).
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

      # A Pi RPC process is a child whose anonymous pipes are owned by one Meringue process. The
      # durable transport lease lets reconciliation distinguish an isolated Pi crash (owner still
      # alive) from the dashboard/supervisor disappearing (both owner and child gone). Only the
      # second condition is safe to resume automatically across all affected workers.
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

      # Pi event names stop at this boundary, exactly like `read_events` and the session view.
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
        argv = build_argv(session_name: session_name, system_prompt: nil, session: session, workspace_mode: workspace_mode)
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

      # Quiesce the dashboard-owned RPC process before a native Pi interactive process is started.
      # Pi cannot transfer a live provider request between frontends, so an active turn is first
      # stopped through Pi's supported abort RPC and observed settled. Only then is the managed
      # writer terminated. The handoff keeps a checkpoint and continuation obligation so leaving
      # focus before a newer final answer can automatically resume the work on the dashboard.
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

      def wait_for_settled(session_ref, timeout: event_timeout)
        wait_for_event(session_ref, type: "agent_settled", timeout: timeout)
      end

      def last_assistant_text(session_ref)
        process = process_for_session(session_ref, required: false)
        if process
          # Pi's RPC can still expose the previous turn's answer after a new prompt has been
          # accepted. Never let that stale answer settle the current turn as completed.
          return nil if current_turn_pending?(session_ref)

          data = rpc_data(process.request({ "type" => "get_last_assistant_text" }, timeout: command_timeout))
          return data["text"]
        end

        session_file_summary(session_ref).fetch("last_assistant_text", nil)
      end

      # Harness-neutral outcome of the session's most recent turn.
      #
      # Pi persists the turn's final assistant message - including a failed one -
      # to the session file, so a wifi drop that killed the turn stays visible even
      # though the live RPC state only says the session is no longer streaming.
      def turn_outcome(session_ref)
        record = last_assistant_record(session_ref)
        return nil unless record

        stop_reason = assistant_stop_reason(record)
        text = assistant_text_from_message(record)
        ended_at = assistant_turn_ended_at(record)
        return incomplete_turn_outcome(stop_reason, ended_at) if TURN_INCOMPLETE_STOP_REASONS.include?(stop_reason.to_s)
        return completed_turn_outcome(stop_reason, text, ended_at) unless TURN_FAILURE_STOP_REASONS.include?(stop_reason.to_s)

        failed_turn_outcome(stop_reason, assistant_error_message(record), text, ended_at)
      rescue StandardError
        nil
      end

      private

      attr_reader :transport_ownership, :takeover_settle_timeout

      def settle_interactive_rpc_turn(session_ref)
        settled_ref = abort_session(session_ref)
        return settled_ref unless settled_ref.fetch("is_streaming", false)

        wait_for_settled(settled_ref)
        refreshed = get_state(settled_ref)
        return refreshed unless refreshed.fetch("is_streaming", false)

        raise SessionBusyError,
              "Pi acknowledged the focus handoff abort but the managed turn is still active; the RPC writer was left untouched."
      end

      def quiesce_interactive_rpc(session_ref)
        process = process_for_session(session_ref, required: false)
        unless process
          if unmanaged_process_alive?(session_ref)
            raise SessionTransportUnavailableError,
                  "Refusing the Agent session while another live Pi process still owns this session"
          end

          release_transport(session_ref, pid: session_ref.fetch("pid", nil))
          return session_ref.merge(
            "pid" => nil,
            "is_streaming" => false,
            "metadata" => metadata_with(
              session_ref,
              "interactive_rpc_quiesced" => true,
              "interactive_rpc_already_stopped" => true
            )
          )
        end

        process.terminate(timeout: INTERACTIVE_RPC_SHUTDOWN_TIMEOUT)
        unregister_process(process)
        release_transport(session_ref, pid: process.pid)
        session_ref.merge(
          "pid" => nil,
          "is_streaming" => false,
          "last_event_at" => process.last_event_at,
          "metadata" => metadata_with(session_ref, "interactive_rpc_quiesced" => true)
        )
      end

      def prompt_delivery_marker(delivery_id)
        value = delivery_id.to_s.strip
        return nil if value.empty?

        safe_id = value.gsub(/[^A-Za-z0-9_.:@\/-]/, "_")
        "#{PROMPT_DELIVERY_MARKER_PREFIX}#{safe_id} -->"
      end

      def prompt_with_delivery_marker(prompt, delivery_id)
        marker = prompt_delivery_marker(delivery_id)
        return prompt unless marker
        return prompt if prompt.include?(marker)

        "#{prompt}\n\n#{marker}"
      end

      # Receipt checks run every reconciliation tick while Pi may be compacting a large transcript.
      # Scan only bytes appended since the prior check (plus enough overlap for a split marker)
      # instead of repeatedly parsing the entire multi-megabyte JSONL history.
      def scan_prompt_delivery_receipt(path, marker)
        @prompt_receipt_mutex.synchronize do
          stat = File.stat(path)
          key = [File.expand_path(path), marker]
          cached = @prompt_receipt_cache[key]
          return [true, cached["delivered_at"]] if cached&.fetch("delivered", false)

          offset = if cached && cached.fetch("inode", nil) == stat.ino && cached.fetch("size", 0).to_i <= stat.size
                     [cached.fetch("size", 0).to_i - marker.bytesize, 0].max
                   else
                     0
                   end
          bytes = File.open(path, "rb") do |file|
            file.seek(offset)
            file.read.to_s
          end
          marker_offset = bytes.index(marker)
          delivered = !marker_offset.nil?
          delivered_at = if delivered
                           line_start = bytes.rindex("\n", marker_offset) || -1
                           line_end = bytes.index("\n", marker_offset) || bytes.bytesize
                           line = bytes.byteslice(line_start + 1, line_end - line_start - 1)
                           begin
                             entry = JSON.parse(line)
                             message = entry.is_a?(Hash) ? entry["message"] : nil
                             entry.fetch("timestamp", nil) || (message.is_a?(Hash) && message.fetch("timestamp", nil)) || stat.mtime.utc.iso8601
                           rescue JSON::ParserError
                             stat.mtime.utc.iso8601
                           end
                         end
          @prompt_receipt_cache[key] = {
            "inode" => stat.ino,
            "size" => stat.size,
            "delivered" => delivered,
            "delivered_at" => delivered_at
          }
          [delivered, delivered_at]
        end
      end

      def compatible_thinking_level(current_level, available_levels)
        current_index = THINKING_LEVELS.index(current_level)
        return nil unless current_index

        THINKING_LEVELS.first(current_index + 1).reverse_each.find do |level|
          available_levels.include?(level)
        end || available_levels.first
      end

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

      # Pi splits a reference on the *first* slash (`resolveModel`), and real Pi
      # model ids contain slashes and colons of their own
      # (`fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`). Splitting
      # into three and refusing the remainder made those models unusable here.
      def parse_model_reference!(model_reference)
        parsed = ModelReference.parse(model_reference)
        unless parsed
          raise InvalidModelReferenceError,
                "Pi models must use a provider/model id: " \
                "#{ModelReference.rejection_reason(model_reference)}. #{ModelReference::FORMAT_HINT}"
        end

        [parsed.fetch("provider"), parsed.fetch("id")]
      end

      def writable_session_state(session_ref)
        if unmanaged_process_alive?(session_ref) && !process_for_session(session_ref, required: false)
          owner_pid = transport_owner_pid(session_ref)
          owner = owner_pid ? "Meringue instance #{owner_pid}" : "another Meringue instance"
          raise SessionTransportUnavailableError,
                "This Pi session is owned by #{owner}; update it from that window or wait until it is resumable."
        end

        existing_process = process_for_session(session_ref, required: false)
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

        # Bind the in-memory pipes to the durable session key before exposing the ref. Looking up
        # transports by pid alone is unsafe during mass recovery because the OS may reuse one dead
        # worker's pid for a different worker's replacement process.
        associate_process_with_transport(session_ref)
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

      def preserve_session_identity(current_ref, previous_ref)
        current_ref.merge(
          "session_file" => current_ref.fetch("session_file", nil) || previous_ref.fetch("session_file", nil),
          "session_id" => current_ref.fetch("session_id", nil) || previous_ref.fetch("session_id", nil),
          "cwd" => current_ref.fetch("cwd", nil) || previous_ref.fetch("cwd", nil)
        ).compact
      end

      def create_replacement_session_from_rpc(session_ref)
        process = process_for_session(session_ref)
        data = rpc_data(process.request({ "type" => "get_entries" }, timeout: command_timeout))
        entries = Array(data.fetch("entries", []))
        replacement_id = SecureRandom.uuid
        cwd = session_ref.fetch("cwd", nil) || Dir.pwd
        directory = File.expand_path(session_dir || File.join(cwd, ".meringue", "pi-sessions"))
        FileUtils.mkdir_p(directory)
        path = File.join(directory, "#{Time.now.utc.strftime("%Y%m%d_%H%M%S")}_#{replacement_id}.jsonl")
        temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
        header = {
          "type" => "session",
          "version" => 3,
          "id" => replacement_id,
          "timestamp" => Time.now.utc.iso8601,
          "cwd" => cwd,
          "parentSession" => session_ref.fetch("session_file", nil)
        }.compact
        File.open(temporary, "w", 0o600) do |file|
          file.puts(JSON.generate(header))
          entries.each { |entry| file.puts(JSON.generate(entry)) }
        end
        File.rename(temporary, path)
        {
          "session_id" => replacement_id,
          "session_file" => path,
          "entry_count" => entries.length,
          "source_session_id" => session_ref.fetch("session_id", nil),
          "latest_user_intent" => entries.reverse_each.filter_map do |entry|
            message = entry.is_a?(Hash) ? entry["message"] : nil
            next unless message.is_a?(Hash) && message.fetch("role", nil).to_s == "user"

            message_text_from_message(message)
          end.first,
          "reason" => "rpc_session_file_unavailable"
        }.compact
      rescue StandardError
        File.delete(temporary) if defined?(temporary) && temporary && File.file?(temporary)
        raise
      end

      def safe_session_file_summary(session_ref)
        session_file_summary(session_ref)
      rescue StandardError
        {}
      end

      def bounded_handoff_summary(summary)
        return {} unless summary.is_a?(Hash)

        summary.slice(
          "session_file", "session_id", "turn_pending", "last_stop_reason", "last_event_at", "session_name",
          "last_user_text", "last_assistant_text"
        ).each_with_object({}) do |(key, value), bounded|
          bounded[key] = value.is_a?(String) ? value.byteslice(0, 4000).to_s.scrub : value
        end.compact
      end

      def latest_user_intent(events)
        Array(events).reverse_each do |entry|
          event = entry.is_a?(Hash) ? (entry["event"] || entry) : {}
          message = event["message"] || event
          next unless message.is_a?(Hash) && message.fetch("role", nil).to_s == "user"

          text = message_text_from_message(message)
          return text if present?(text)
        end
        nil
      end

      def message_text_from_message(message)
        content = message.fetch("content", nil)
        return content.to_s.strip if content.is_a?(String)

        Array(content).filter_map do |part|
          part["text"] if part.is_a?(Hash) && part["type"].to_s == "text"
        end.join("\n").strip
      end

      def interactive_continuation_prompt(session_ref, events:, latest_user_intent:, session_summary:)
        context = session_ref.dig("metadata", "interactive_handoff", "context")
        context = {} unless context.is_a?(Hash)
        progress = PiSessionView.progress_items(events).last(10).filter_map do |item|
          text = item.is_a?(Hash) ? item["text"] : nil
          bounded_handoff_text(text, 2_000) if present?(text)
        end

        sections = [
          "Meringue interrupted the dashboard-managed turn because the user requested an Agent session. " \
          "Continue the same task in this existing workspace and session. Inspect the transcript and current files " \
          "before repeating tool calls; work completed before the interruption may already be present."
        ]
        issue_line = [context["issue_id"], context["issue_title"]].compact.map(&:to_s).reject(&:empty?).join(" — ")
        sections << "Current issue: #{bounded_handoff_text(issue_line, 1_000)}" unless issue_line.empty?
        sections << "Issue description:\n#{bounded_handoff_text(context["issue_description"], 4_000)}" if present?(context["issue_description"])
        sections << "Original worker assignment:\n#{bounded_handoff_text(context["assignment"], 6_000)}" if present?(context["assignment"])
        sections << "Latest user intent in the saved transcript:\n#{bounded_handoff_text(latest_user_intent, 3_000)}" if present?(latest_user_intent)
        sections << "Last durable assistant text before interruption:\n#{bounded_handoff_text(session_summary["last_assistant_text"], 3_000)}" if present?(session_summary["last_assistant_text"])
        sections << "Recent in-memory assistant progress before interruption:\n#{progress.join("\n")}" unless progress.empty?
        workspace = [context["workspace_path"], context["workspace_branch"]].compact.map(&:to_s).reject(&:empty?).join(" on branch ")
        sections << "Workspace continuity: #{bounded_handoff_text(workspace, 2_000)}" unless workspace.empty?
        sections.join("\n\n")
      end

      def bounded_handoff_text(value, bytes)
        value.to_s.byteslice(0, bytes).to_s.scrub.strip
      end

      def interactive_session_argv(session_ref, handoff_prompt: nil)
        session = resume_session_argument(session_ref)
        argv = Array(command).map(&:to_s)
        argv += ["--session-dir", File.expand_path(session_dir)] if present?(session_dir)
        argv += ["--session", session]
        session_name = metadata_value(session_ref, "session_name")
        argv += ["--name", session_name.to_s] if present?(session_name)
        session_arguments = without_options(extra_args, "--model", "--thinking")
        session_arguments = enforce_read_only_tools(session_arguments) if metadata_value(session_ref, "workspace_mode") == "shared_read_only"
        argv += session_arguments
        argv << handoff_prompt.to_s if present?(handoff_prompt)
        argv
      end

      def resolve_interactive_executable(argv, cwd:, environment:)
        name = Array(argv).first.to_s
        path = environment.fetch("PATH", ENV.fetch("PATH", "")).to_s
        resolved = if name.include?(File::SEPARATOR)
                     candidate = File.expand_path(name, cwd.to_s)
                     candidate if File.file?(candidate) && File.executable?(candidate)
                   else
                     path.split(File::PATH_SEPARATOR).each_with_object(nil) do |directory, _unused|
                       directory = "." if directory.empty?
                       candidate = File.expand_path(File.join(directory, name), cwd.to_s)
                       break candidate if File.file?(candidate) && File.executable?(candidate)
                     end
                   end
        return resolved if resolved

        raise Error,
              "The configured Pi command #{name.inspect} could not be resolved for the Agent session " \
              "with PATH=#{path.inspect}. Configure [harness.pi] command with an executable path or make it " \
              "available in [harness.pi.env] PATH, then restart Meringue."
      end

      def interactive_handoff_metadata(was_streaming:, events:, prompt:, latest_user_intent:, session_summary:, interrupted_turn_outcome:, turn_checkpoint:, replacement:)
        progress = PiSessionView.progress_items(events)
        {
          "mode" => "native_interactive",
          "transfer" => was_streaming ? "coordinated_turn_abort" : "settled_session",
          "exact_stream_transfer" => !was_streaming,
          "was_streaming" => !!was_streaming,
          "continuation_required" => !!was_streaming,
          "interruption_method" => was_streaming ? "rpc_abort" : nil,
          "prompt" => prompt,
          "latest_user_intent" => latest_user_intent,
          "session_file_summary" => session_summary,
          "interrupted_turn_outcome" => interrupted_turn_outcome,
          "turn_checkpoint" => turn_checkpoint,
          "replacement" => replacement,
          "captured_event_count" => events.length,
          "last_progress" => progress.last(20),
          "tool_call_ids" => events.filter_map do |event|
            next unless event.is_a?(Hash)

            event["toolCallId"] || event.dig("message", "content")&.filter_map do |part|
              part["id"] if part.is_a?(Hash) && part["type"] == "toolCall"
            end
          end.flatten.uniq.last(50)
        }.compact
      end

      def bounded_turn_outcome(outcome)
        return nil unless outcome.is_a?(Hash)

        outcome.slice("state", "kind", "stop_reason", "turn_ended_at", "last_assistant_text").transform_values do |value|
          value.is_a?(String) ? value.byteslice(0, 4_000).to_s.scrub : value
        end.compact
      end

      def dashboard_continuation_required?(session_ref, handoff)
        details = handoff.is_a?(Hash) ? (handoff["handoff"] || handoff[:handoff] || handoff) : {}
        return false unless details.is_a?(Hash) && details.fetch("continuation_required", false)

        current = bounded_turn_outcome(turn_outcome(session_ref))
        checkpoint = details.fetch("turn_checkpoint", nil)
        return true unless current.is_a?(Hash)
        return true unless current.fetch("state", nil) == "completed"
        return true unless present?(current.fetch("last_assistant_text", nil))

        turn_outcome_signature(current) == turn_outcome_signature(checkpoint)
      end

      def turn_outcome_signature(outcome)
        return nil unless outcome.is_a?(Hash)

        %w[state kind stop_reason turn_ended_at last_assistant_text].map { |key| outcome.fetch(key, nil).to_s }.join("|")
      end

      def dashboard_continuation_prompt(handoff)
        details = handoff.is_a?(Hash) ? (handoff["handoff"] || handoff[:handoff] || handoff) : {}
        original = details.is_a?(Hash) ? details.fetch("prompt", nil) : nil
        return original if present?(original)

        "Continue the focused task from the existing transcript and workspace. Inspect current files and any pending tool work before repeating actions, then finish with a final result."
      end

      def build_argv(session_name:, system_prompt:, session: nil, session_settings: {}, workspace_mode: "isolated")
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
        unless present?(session) || session_settings.empty?
          model = session_settings["model"] || session_settings[:model]
          thinking = session_settings["thinking_level"] || session_settings[:thinking_level]
          if present?(model)
            session_arguments = without_options(session_arguments, "--model")
            session_arguments += ["--model", model.to_s]
          end
          if present?(thinking)
            session_arguments = without_options(session_arguments, "--thinking")
            session_arguments += ["--thinking", thinking.to_s]
          end
        end
        session_arguments = enforce_read_only_tools(session_arguments) if workspace_mode.to_s == "shared_read_only"
        argv + session_arguments
      end

      def enforce_read_only_tools(arguments)
        # Tool allowlisting blocks write/edit/bash, while disabling extensions closes the startup
        # side door: Pi extensions execute with full user permissions before a tool call and can
        # replace a built-in tool by name. Explicit -e/--extension arguments are removed too,
        # because Pi intentionally lets explicit extensions override --no-extensions.
        safe = without_options(arguments, "--tools", "-t", "--extension", "-e")
        safe << "--no-extensions" unless safe.include?("--no-extensions")
        safe + ["--tools", "read,grep,find,ls"]
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
        stdin, stdout, stderr, wait_thread = Open3.popen3(process_environment(cwd), *argv, chdir: cwd)
        RpcProcess.new(stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread,
                       argv: argv, cwd: cwd)
      rescue Errno::ENOENT => e
        raise Error, "Unable to start Pi RPC process with #{argv.first.inspect}: #{e.message}"
      end

      def process_environment(cwd)
        configured = ENV.to_h.merge(env)
        environment = env.merge(Git::CommitIdentity.environment(cwd: cwd, base_environment: configured))
        # Open3 inherits unspecified variables, but the native PTY performs its
        # own executable discovery before spawning. Preserve the effective PATH
        # explicitly so that a provider installed outside a restricted launcher
        # environment is still resolved by the handoff.
        environment["PATH"] ||= configured.fetch("PATH", "")
        environment
      end

      def set_session_name(process, session_name)
        rpc_data(
          process.request({ "type" => "set_session_name", "name" => session_name.to_s },
                          timeout: command_timeout),
          allow_nil_data: true
        )
      end

      def build_session_ref(process, pi_state, kind:, cwd:, session_name:, workspace_mode: "isolated", session_stats: nil)
        {
          "harness" => "pi",
          "pid" => process.pid,
          "cwd" => cwd,
          "session_id" => pi_state["sessionId"],
          "session_file" => pi_state["sessionFile"],
          "is_streaming" => !!pi_state["isStreaming"],
          "last_event_at" => process.last_event_at,
          "session_settings" => session_settings_from_pi_state(pi_state),
          "session_stats" => session_stats,
          "metadata" => {
            "kind" => kind.to_s,
            "session_name" => session_name,
            "workspace_mode" => workspace_mode.to_s,
            "started_at" => process.started_at,
            "command" => process.argv,
            "prompt_modes" => prompt_modes,
            "completed" => !!pi_state["completed"],
            "pi_state" => pi_state,
            "stderr_tail" => process.stderr_tail,
            "supervision" => {
              "owner_pid" => Process.pid,
              "owner_started_at" => transport_ownership.owner_started_at,
              "harness_pid" => process.pid,
              "harness_started_at" => process.started_at,
              "recorded_at" => Time.now.utc.iso8601(6)
            }.compact
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
          "session_stats" => summary.fetch("session_stats", nil),
          "metadata" => metadata_with(
            session_ref,
            "session_name" => summary.fetch("session_name", nil) || metadata_value(session_ref, "session_name"),
            "completed" => summary.fetch("completed", false),
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
        last_assistant_index = nil
        last_user_index = nil
        records = []

        File.foreach(path) do |line|
          record = JSON.parse(line)
          record_index = records.length
          records << record
          summary["last_event_at"] = record["timestamp"] if record["timestamp"]
          if record["type"] == "session"
            summary["session_id"] ||= record["id"]
            summary["cwd"] ||= record["cwd"]
          elsif record["type"] == "session_info"
            summary["session_name"] = record["name"] if record["name"]
          elsif record["type"] == "message"
            case record.dig("message", "role")
            when "user"
              last_user_index = record_index
              user_text = message_text_from_message(record.fetch("message", {}))
              summary["last_user_text"] = user_text.byteslice(0, 4000).to_s.scrub if present?(user_text)
            when "assistant"
              last_assistant = record
              last_assistant_index = record_index
              text = assistant_text_from_message(record)
              summary["last_assistant_text"] = text if present?(text)
              stop_reason = record["stopReason"] || record.dig("message", "stopReason")
              summary["last_stop_reason"] = stop_reason if present?(stop_reason)
            end
          end
        rescue JSON::ParserError
          next
        end

        turn_pending = last_user_index && (!last_assistant_index || last_user_index > last_assistant_index)
        summary["turn_pending"] = !!turn_pending
        summary["last_assistant_text"] = nil if turn_pending
        summary["last_stop_reason"] = nil if turn_pending
        summary["completed"] = !turn_pending && assistant_message_completed?(last_assistant)
        summary["session_settings"] = session_settings_from_session_records(records)
        summary
      end

      def normalize_session_stats(stats)
        return nil unless stats.is_a?(Hash)

        context = stats["contextUsage"] || stats["context_usage"]
        context = normalize_context_usage(context)
        {
          "user_messages" => stats["userMessages"] || stats["user_messages"],
          "assistant_messages" => stats["assistantMessages"] || stats["assistant_messages"],
          "tool_calls" => stats["toolCalls"] || stats["tool_calls"],
          "tool_results" => stats["toolResults"] || stats["tool_results"],
          "total_messages" => stats["totalMessages"] || stats["total_messages"],
          "context_usage" => context
        }.compact
      end

      def normalize_context_usage(context)
        return nil unless context.is_a?(Hash)

        {
          "tokens" => context.key?("tokens") ? context["tokens"] : context["used"],
          "capacity" => context["contextWindow"] || context["context_window"] || context["capacity"],
          "percent" => context["percent"],
          # Pi documents this value as an estimate: it combines provider usage
          # with estimated tokens for messages after the latest response.
          "approximate" => true,
          "source" => "pi_session_stats"
        }
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

      def assistant_stop_reason(record)
        record["stopReason"] || record.dig("message", "stopReason")
      end

      def assistant_error_message(record)
        record["errorMessage"] || record.dig("message", "errorMessage") ||
          record["error"] || record.dig("message", "error")
      end

      def assistant_turn_ended_at(record)
        timestamp = record["timestamp"]
        return timestamp.to_s if present?(timestamp) && timestamp.is_a?(String)

        epoch_ms = record.dig("message", "timestamp")
        return nil unless epoch_ms.is_a?(Numeric)

        Time.at(epoch_ms / 1000.0).utc.iso8601
      end

      def completed_turn_outcome(stop_reason, text, ended_at)
        {
          "state" => "completed",
          "stop_reason" => present?(stop_reason) ? stop_reason.to_s : nil,
          "turn_ended_at" => ended_at,
          "last_assistant_text" => present?(text) ? text : nil
        }.compact
      end

      def incomplete_turn_outcome(stop_reason, ended_at)
        interrupted = %w[abort aborted].include?(stop_reason.to_s)
        {
          "state" => "incomplete",
          "kind" => interrupted ? "interrupted_turn" : "pending_tool_call",
          "reason" => interrupted ? "its last turn was interrupted before a final assistant result" :
                                    "its last turn stopped while a tool call was still pending",
          "stop_reason" => stop_reason.to_s,
          "turn_ended_at" => ended_at
        }.compact
      end

      def failed_turn_outcome(stop_reason, error_message, text, ended_at)
        unreplayable = UNREPLAYABLE_SESSION_PATTERN.match?(error_message.to_s)
        network = !unreplayable && NETWORK_ERROR_PATTERN.match?(error_message.to_s)
        {
          "state" => "failed",
          "kind" => turn_failure_kind(unreplayable, network),
          "reason" => turn_failure_reason(network, error_message, unreplayable: unreplayable),
          # Harness-neutral hint for the kernel: this session can never be resumed, but the work
          # can continue in a fresh session on the same workspace.
          "recovery" => unreplayable ? "fresh_session" : nil,
          "stop_reason" => stop_reason.to_s,
          "error_message" => present?(error_message) ? error_message.to_s : nil,
          # When the turn ended, so a later prompt can be told apart from stale evidence.
          "turn_ended_at" => ended_at,
          "last_assistant_text" => present?(text) ? text : nil
        }.compact
      end

      def turn_failure_kind(unreplayable, network)
        return "unreplayable_session" if unreplayable

        network ? "network_failure" : "provider_error"
      end

      def turn_failure_reason(network, error_message, unreplayable: false)
        detail = error_message.to_s.strip
        if unreplayable
          return "its saved session can no longer be replayed to the model, so resuming it fails the same way every time" if detail.empty?

          return "its saved session can no longer be replayed to the model, so resuming it fails " \
                 "the same way every time (#{detail})"
        end

        if network
          return "its model request failed mid-turn because the network connection dropped" if detail.empty?

          "its model request failed mid-turn (network error: #{detail})"
        else
          return "its model request failed mid-turn" if detail.empty?

          "its model request failed mid-turn (#{detail})"
        end
      end

      # Newest-first scan of the session file tail for the last assistant message.
      def last_assistant_record(session_ref)
        path = session_file_path(session_ref)
        return nil unless present?(path) && File.file?(path)

        records = session_file_tail_lines(path).filter_map do |line|
          record = parse_session_line(line)
          record if record.is_a?(Hash)
        end
        assistant_index = nil
        user_index = nil
        records.each_with_index do |record, index|
          next unless record["type"].nil? || record["type"] == "message"

          case record.dig("message", "role")
          when "assistant"
            assistant_index = index
          when "user"
            user_index = index
          end
        end
        # A session can retain a perfectly good answer from the previous turn after the next user
        # prompt has been written. It is not evidence for the current turn.
        return nil if user_index && (!assistant_index || user_index > assistant_index)

        assistant_index && records.fetch(assistant_index)
      end

      def session_file_tail_lines(path)
        size = File.size(path)
        offset = [size - TURN_OUTCOME_TAIL_BYTES, 0].max
        chunk = File.open(path, "rb") do |file|
          file.seek(offset)
          file.read
        end
        lines = chunk.to_s.split("\n")
        # The first line of a mid-file read is almost always truncated.
        lines.shift if offset.positive?
        lines.reject { |line| line.strip.empty? }
      end

      def parse_session_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def current_turn_pending?(session_ref)
        path = session_file_path(session_ref)
        return false unless present?(path) && File.file?(path)

        session_file_summary(session_ref).fetch("turn_pending", false)
      rescue ProcessNotFoundError
        false
      end

      def assistant_message_completed?(record)
        return false unless record

        stop_reason = record["stopReason"] || record.dig("message", "stopReason")
        return false if TURN_INCOMPLETE_STOP_REASONS.include?(stop_reason.to_s)
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

      # The registered process for this session that has already exited. `process_for` deliberately
      # hides it (callers must not send RPC to a dead process); this is for reading what it left
      # behind.
      def exited_process_for(session_ref)
        process = managed_process_for_transport(session_ref)
        process && !process.alive? ? process : nil
      end

      def unmanaged_process_alive?(session_ref)
        !unmanaged_process_pid(session_ref).nil?
      end

      # The transport lease may be one state write ahead of the agent record during recovery. Its
      # pid is therefore considered after the persisted pid, but only when it still identifies a Pi
      # process for this durable session and is not already managed by this client.
      def unmanaged_process_pid(session_ref)
        supervision = transport_record(session_ref)
        candidates = [
          [session_ref["pid"] || session_ref[:pid], metadata_value(session_ref, "started_at")],
          [supervision["pid"], supervision["harness_started_at"]]
        ].uniq
        candidates.find do |pid, started_at|
          next false unless pid
          next false if process_for({ "pid" => integer_or_nil(pid) }, required: false)

          live_harness_process_at?(pid, started_at: started_at)
        end&.first&.to_i
      end

      def process_for_session(session_ref, required: false)
        process = managed_process_for_transport(session_ref)
        return process if process&.alive?

        # Session-bearing refs must never fall back to a pid-only lookup: during recovery that pid
        # can already belong to another session's newly attached process. Refs without a stable key
        # are only used during initial process setup and retain the legacy lookup.
        process = process_for(session_ref, required: false) unless stable_transport_key?(session_ref)
        return process if process
        return nil unless required

        raise ProcessNotFoundError,
              "No live Pi RPC process for session #{session_ref["session_id"] || session_ref[:session_id] || "unknown"}"
      end

      def stable_transport_key?(session_ref)
        present?(session_ref["session_id"] || session_ref[:session_id]) ||
          present?(session_ref["session_file"] || session_ref[:session_file])
      end

      def managed_process_for_transport(session_ref)
        key = transport_key(session_ref)
        return nil unless key

        @processes_mutex.synchronize { @processes_by_transport_key[key] }
      end

      def associate_process_with_transport(session_ref)
        key = transport_key(session_ref)
        pid = integer_or_nil(session_ref["pid"] || session_ref[:pid])
        return false unless key && pid

        @processes_mutex.synchronize do
          process = @processes_by_pid[pid]
          return false unless process

          @processes_by_transport_key[key] = process
          true
        end
      end

      def transport_record(session_ref)
        key = transport_key(session_ref)
        key ? transport_ownership.record_for(key) : {}
      rescue StandardError
        {}
      end

      # A transport claim normally happens just after a session ref is built, making its lease the
      # newest source. If that claim could not be written, however, an older lease must not hide the
      # newer supervision identity saved in state. Timestamp selection preserves both the
      # attach-before-state-write crash window and the lock-write-failure fallback.
      def newest_supervision_source(lease, persisted)
        lease_available = lease.is_a?(Hash) && lease["owner_pid"]
        persisted_available = persisted.is_a?(Hash) && persisted["owner_pid"]
        return [lease, "transport_ownership"] if lease_available && !persisted_available
        return [persisted, "session_metadata"] if persisted_available && !lease_available
        return [{}, nil] unless lease_available && persisted_available

        lease_time = parse_supervision_time(lease["updated_at"])
        persisted_time = parse_supervision_time(persisted["recorded_at"])
        if persisted_time && (!lease_time || persisted_time > lease_time)
          [persisted, "session_metadata"]
        else
          [lease, "transport_ownership"]
        end
      end

      def parse_supervision_time(value)
        return nil unless present?(value)

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def live_harness_process_at?(pid, started_at: nil)
        return false unless process_alive?(pid)

        ProcessIdentity.matches?(pid, command: Array(command).first, started_at: started_at)
      end

      def process_identity_alive?(pid, started_at: nil)
        return false unless pid
        return ProcessIdentity.alive?(pid) unless present?(started_at)

        ProcessIdentity.matches?(pid, started_at: started_at)
      end

      def integer_or_nil(value)
        numeric = Integer(value)
        numeric.positive? ? numeric : nil
      rescue ArgumentError, TypeError
        nil
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

      # Harness-neutral report of what the harness actually did with a prompt whose requested mode
      # could not be used as-is. The kernel logs and records the delivered mode from these keys, so
      # a coerced delivery is visible instead of silently relabelled.
      def delivered_mode_metadata(requested_mode:, delivered_mode:, note:)
        {
          "requested_prompt_mode" => requested_mode,
          "delivered_prompt_mode" => delivered_mode,
          "prompt_mode_note" => note
        }
      end

      def prompt_mode_noun(mode)
        case mode.to_s
        when "steer" then "correction"
        when "follow_up" then "follow-up"
        else "prompt"
        end
      end

      def register_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid[process.pid] = process
        end
      end

      def unregister_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid.delete(process.pid)
          @processes_by_transport_key.delete_if { |_key, registered| registered.equal?(process) }
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
          raise RpcTimeoutError.new(
            "Timed out waiting for Pi RPC response to #{command["type"].inspect}",
            command_type: command["type"]
          )
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
