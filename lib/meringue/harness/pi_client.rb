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
        session_ref = record_requested_session_model(session_ref, option_value(argv, "--model"))
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
            current_ref = build_session_ref(
              process,
              state,
              kind: metadata_value(session_ref, "kind"),
              cwd: session_ref.fetch("cwd", process.cwd),
              session_name: metadata_value(session_ref, "session_name") || state["sessionName"],
              workspace_mode: metadata_value(session_ref, "workspace_mode") || "isolated"
            )
            return record_requested_session_model(
              current_ref,
              metadata_value(session_ref, "requested_session_model")
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
        requested_reference = ModelReference.format(provider: provider, id: model_id)
        updated_ref = record_requested_session_model(get_state(state_ref), requested_reference)
        effective_reference = updated_ref.dig("session_settings", "model", "reference")
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

      # A Pi RPC process is a child whose anonymous pipes are owned by one Meringue process. The
      # durable transport lease lets reconciliation distinguish an isolated Pi crash (owner still
      # alive) from the dashboard/supervisor disappearing (both owner and child gone). Only the
      # second condition is safe to resume automatically across all affected workers.

      # Pi event names stop at this boundary, exactly like `read_events` and the session view.




      # Quiesce the dashboard-owned RPC process before a native Pi interactive process is started.
      # Pi cannot transfer a live provider request between frontends, so an active turn is first
      # stopped through Pi's supported abort RPC and observed settled. Only then is the managed
      # writer terminated. The handoff keeps a checkpoint and continuation obligation so leaving
      # focus before a newer final answer can automatically resume the work on the dashboard.






      # Harness-neutral outcome of the session's most recent turn.
      #
      # Pi persists the turn's final assistant message - including a failed one -
      # to the session file, so a wifi drop that killed the turn stays visible even
      # though the live RPC state only says the session is no longer streaming.

      private

      attr_reader :transport_ownership, :takeover_settle_timeout





      # Receipt checks run every reconciliation tick while Pi may be compacting a large transcript.
      # Scan only bytes appended since the prior check (plus enough overlap for a split marker)
      # instead of repeatedly parsing the entire multi-megabyte JSONL history.



      # The probe keeps the configured resource flags (extensions, tools) so the
      # listed models match what a future head/worker could really select, but
      # drops `--model`/`--thinking` because an unavailable saved default would
      # otherwise make Pi exit before it can answer. `--no-session` keeps the
      # probe from writing a session file.



      # Mirrors Pi's own rule (pi-ai `getSupportedThinkingLevels`) so the levels
      # Meringue offers for a model are the levels `set_thinking_level` accepts.

      # Pi splits a reference on the *first* slash (`resolveModel`), and real Pi
      # model ids contain slashes and colons of their own
      # (`fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`). Splitting
      # into three and refusing the remainder made those models unusable here.








      # Key that identifies one durable harness session across Meringue
      # instances. The session id is stable across resumes of the same session.



      # Coordinated single-writer takeover.
      #
      # Returns a description of what happened so the caller can record it. It
      # only raises when another *live* Meringue instance is still mid-turn on
      # the session, and that message tells the user what to do.

      # Recovery details recorded on the worker so a takeover is auditable in
      # state and in the focused workspace.

      # The lock record is more current than a persisted session ref, so it wins
      # when it names a live harness process for this session.


      # A pid alone can belong to an unrelated process after reuse. Only a live
      # process that still looks like our configured Pi command is treated as a
      # harness transport, and only such a process is ever signaled.

      # Waits briefly for another instance's in-flight turn to finish. Pi appends
      # completed assistant messages to the session file, so settling is visible
      # without owning the transport.




      # Returns true when the process is still alive after the timeout.











































      # Newest-first scan of the session file tail for the last assistant message.






      # The registered process for this session that has already exited. `process_for` deliberately
      # hides it (callers must not send RPC to a dead process); this is for reading what it left
      # behind.


      # The transport lease may be one state write ahead of the agent record during recovery. Its
      # pid is therefore considered after the persisted pid, but only when it still identifies a Pi
      # process for this durable session and is not already managed by this client.






      # A transport claim normally happens just after a session ref is built, making its lease the
      # newest source. If that claim could not be written, however, an older lease must not hide the
      # newer supervision identity saved in state. Timestamp selection preserves both the
      # attach-before-state-write crash window and the lock-write-failure fallback.









      # Harness-neutral report of what the harness actually did with a prompt whose requested mode
      # could not be used as-is. The kernel logs and records the delivered mode from these keys, so
      # a coerced delivery is visible instead of silently relabelled.








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
