# frozen_string_literal: true

module Meringue
  module Harness
    class Client
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
    end
  end
end
