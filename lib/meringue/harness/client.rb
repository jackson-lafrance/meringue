# frozen_string_literal: true

module Meringue
  module Harness
    class Client
      class UnsupportedSessionSettingsError < StandardError; end

      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
        raise NotImplementedError, "harness clients must implement #spawn_session"
      end

      def prompt_session(session_ref, prompt, mode: "normal")
        raise NotImplementedError, "harness clients must implement #prompt_session"
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

      def attach_session(session_ref)
        raise NotImplementedError, "harness clients must implement #attach_session"
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
