# frozen_string_literal: true

module Meringue
  module Harness
    class Client
      class UnsupportedSessionSettingsError < StandardError; end

      # session_settings contains optional per-session spawn overrides (currently
      # model and thinking_level). An empty hash means the client must retain its
      # configured future-session defaults. workspace_mode is harness-neutral: an
      # implementation advertising read-only support must enforce shared_read_only
      # sessions rather than relying only on prompt wording.
      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, session_settings: {}, workspace_mode: "isolated")
        raise NotImplementedError, "harness clients must implement #spawn_session"
      end

      def read_only_workspace_supported?
        false
      end

      # Modes are harness neutral: "normal" continues a settled session, "steer" interrupts active
      # work, and "follow_up" queues behind active work.
      #
      # A client that cannot deliver the requested mode right now should still deliver the prompt in
      # the closest safe mode rather than dropping it, and report the substitution on the returned
      # session ref's metadata so the kernel can log it:
      #   metadata["requested_prompt_mode"], metadata["delivered_prompt_mode"], metadata["prompt_mode_note"].
      # Errors that will succeed once a turn settles should include Harness::TransientSessionError so
      # the kernel queues and redelivers instead of failing the command.
      def prompt_session(session_ref, prompt, mode: "normal", delivery_id: nil)
        raise NotImplementedError, "harness clients must implement #prompt_session"
      end

      # Some RPC transports can accept a prompt before their acknowledgement reaches Meringue (for
      # example Pi compacts a large saved session before persisting the user message). A timeout in
      # that window is an ambiguous outcome, not proof of failure. Receipt-capable clients receive a
      # stable delivery id, persist it with the harness prompt, and can later report:
      #
      #   { "status" => "delivered" | "pending" | "not_delivered" | "unknown",
      #     "process_alive" => true | false, "delivered_at" => "...", "pid" => 123 }
      #
      # The kernel never retries `pending`/`unknown`; `not_delivered` is safe to retry only because
      # the original process is gone and the durable transcript lacks the delivery id.
      def prompt_delivery_receipts_supported?
        false
      end

      def ambiguous_prompt_delivery_error?(_error)
        false
      end

      def prompt_delivery_status(_session_ref, delivery_id:, prompt:, started_at: nil)
        { "status" => "unknown" }
      end

      def abort_session(session_ref)
        raise NotImplementedError, "harness clients must implement #abort_session"
      end

      def kill_session(session_ref)
        raise NotImplementedError, "harness clients must implement #kill_session"
      end

      def get_state(session_ref)
        raise NotImplementedError, "harness clients must implement #get_state"
      end

      # Optional session telemetry. A client that cannot report it returns nil;
      # callers must never substitute cumulative token totals for current context usage.
      def get_session_stats(_session_ref)
        nil
      end

      # Session settings are intentionally harness-neutral. Providers opt in as
      # they gain authoritative read/update APIs; unsupported providers fail
      # explicitly instead of echoing Meringue spawn defaults.
      def session_settings_supported?
        false
      end

      def get_session_settings(_session_ref)
        raise UnsupportedSessionSettingsError,
              "#{session_settings_harness_name} does not expose managed session model or thinking settings"
      end

      def set_session_model(_session_ref, _model_reference)
        raise UnsupportedSessionSettingsError,
              "#{session_settings_harness_name} does not support changing a managed session model"
      end

      def set_session_thinking_level(_session_ref, _level)
        raise UnsupportedSessionSettingsError,
              "#{session_settings_harness_name} does not support changing a managed session thinking level"
      end

      # Model catalogs are asked of the harness, never hand-maintained here.
      # Providers that cannot answer yet return an explicit unsupported catalog
      # so callers can say why the list is missing instead of guessing.
      def model_catalog_supported?
        false
      end

      def available_models(cwd: nil) # rubocop:disable Lint/UnusedMethodArgument
        ModelCatalog.unsupported(
          harness: session_settings_harness_name,
          note: "#{session_settings_harness_name} does not expose a model catalog yet, so Meringue cannot list its models."
        )
      end

      def read_events(session_ref)
        raise NotImplementedError, "harness clients must implement #read_events"
      end

      # Mid-work progress derived from events the caller already drained.
      #
      # This is deliberately a *pure* transform of an event array rather than another read: some
      # transports (see `ProcessClient::ManagedProcess`) keep a single shared drain cursor, so a
      # second `read_events` call for progress would steal events from reconciliation and break
      # settle classification. The kernel therefore drains once and hands the same array here.
      #
      # Returns `Harness::SessionProgress` items. The default is `[]`: a harness that cannot
      # supply session events simply has no derived progress, and every other behaviour (settle
      # classification, logging, the workspace pane) is unaffected.
      def session_progress(_events)
        []
      end

      # Harness-neutral outcome of the session's most recent turn.
      #
      # A session that is no longer streaming has not necessarily finished its
      # work: the turn can also end because the transport died, the provider
      # request failed (a dropped wifi connection, DNS/TLS failure, 5xx), or the
      # process disappeared mid-tool-call. Clients that can tell those apart
      # return:
      #
      #   { "state" => "completed" | "failed" | "incomplete",
      #     "kind" => "network_failure" | "provider_error" | ...,
      #     "reason" => human-readable sentence fragment,
      #     "stop_reason" => harness stop reason,
      #     "error_message" => harness error text }
      #
      # Returning nil means "no evidence available"; the kernel then falls back to
      # the session events it already has. An explicit "failed" or "incomplete" state
      # makes the kernel settle an agent as `errored` instead of `completed`.
      def turn_outcome(_session_ref)
        nil
      end

      # Harness-neutral evidence about a session whose process is gone.
      #
      # A client that raises an error carrying `Harness::SessionProcessGoneError` should also be
      # able to say what it saw when the process left:
      #
      #   { "pid" => 27282,
      #     "exit_status" => { "exit_code" => 1, "termsig" => nil, "success" => false },
      #     "stderr_tail" => "...",
      #     "last_event_at" => "2026-08-06T18:22:51Z" }
      #
      # Returning nil means "no evidence available" (for example a session this process never
      # owned). The kernel then reports the exit without the exit status rather than guessing.
      def session_exit_evidence(_session_ref)
        nil
      end

      # Harness-neutral evidence about the process supervising a session transport.
      #
      # Long-lived RPC harnesses may be children of the Meringue dashboard process. When that
      # shared supervisor exits, every child loses its pipe owner together even though each durable
      # session and workspace remains valid. Clients that persist transport ownership can report:
      #
      #   { "supervisor_exited" => true,
      #     "owner_pid" => 123,
      #     "owner_started_at" => "...",
      #     "harness_pid" => 456,
      #     "harness_started_at" => "...",
      #     "source" => "transport_ownership" }
      #
      # The kernel only auto-recovers a process-gone worker when this evidence proves its shared
      # supervisor also left. Returning nil preserves the ordinary isolated-process-exit behavior.
      def session_supervision_evidence(_session_ref)
        nil
      end

      def attach_session(session_ref)
        raise NotImplementedError, "harness clients must implement #attach_session"
      end

      # A backend that already runs its session in an interactive process Meringue owns can hand
      # out a live view of it instead of being handed off to a separate one.
      #
      # This is the difference between focusing a worker and interrupting it. `live_terminal`
      # returns a handle onto the session that is *already* running, so opening the focused viewer
      # aborts no turn, replaces no process, and leaves nothing to roll back if the user switches
      # away again. Clients that cannot do this fall back to `prepare_interactive_session` below,
      # which necessarily stops the managed turn first.
      #
      # The handle carries input and screen only: `write`, `snapshot(rows:, columns:)`, `resize`,
      # and `alive?`. Session ownership stays with the kernel, so a UI holding one can type and
      # watch but cannot detach, signal, or kill the session.
      def live_terminal_supported?
        false
      end

      def live_terminal(_session_ref)
        raise NotImplementedError, "harness clients must implement #live_terminal"
      end

      # Native interactive mode is an optional harness capability. A capable client must settle an
      # active managed turn through its supported cancellation boundary, preserve a continuation
      # obligation when that turn has no final result, quiesce its managed transport, and only then
      # return argv for the persisted session. It must never leave two session writers alive. The
      # preparation result may also include `interactive_executable`, an absolute path resolved
      # with provider-specific installation knowledge. This is important for app/GUI launches whose
      # PATH cannot see a package-manager bin directory even though the harness can supply it.
      def interactive_session_supported?
        false
      end

      def prepare_interactive_session(_session_ref)
        raise NotImplementedError, "harness clients must implement #prepare_interactive_session"
      end

      # Reclaims a native interactive process left behind by a crashed Meringue instance. Providers
      # must verify the recorded pid still belongs to their own interactive command before signaling.
      def reclaim_interactive_session(_session_ref, pid:)
        raise NotImplementedError, "harness clients must implement #reclaim_interactive_session"
      end

      def resume_dashboard_session(session_ref, handoff: nil)
        _ = handoff
        attach_session(session_ref)
      end

      # Returns a read-only, harness-neutral view. Managed prompting and
      # cancellation intentionally remain outside this handle so callers cannot
      # gain process attach/detach/kill controls through the UI integration.
      def open_session_view(session_ref)
        harness = if respond_to?(:harness_name)
                    harness_name
                  else
                    session_ref["harness"] || session_ref[:harness] || "unknown"
                  end
        SessionView::Handle.new(
          snapshot_loader: lambda {
            SessionView.unavailable_snapshot(
              harness: harness,
              message: "This agent session does not provide a native managed session view."
            )
          }
        )
      end

      private

      def session_settings_harness_name
        respond_to?(:harness_name) ? harness_name.to_s : self.class.name
      end
    end
  end
end
