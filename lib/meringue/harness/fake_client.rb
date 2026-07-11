# frozen_string_literal: true

module Meringue
  module Harness
    class FakeClient < Client
      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
        {
          "harness" => "fake",
          "pid" => nil,
          "cwd" => cwd,
          "session_id" => "fake-#{kind}-session",
          "session_file" => nil,
          "is_streaming" => false,
          "last_event_at" => nil,
          "metadata" => {
            "prompt" => prompt,
            "system_prompt" => system_prompt,
            "session_name" => session_name
          }
        }
      end

      def prompt_session(session_ref, prompt, mode: "normal")
        session_ref.merge(
          "last_prompt" => prompt,
          "last_prompt_mode" => mode,
          "is_streaming" => false
        )
      end

      def abort_session(session_ref)
        session_ref.merge("is_streaming" => false)
      end

      def kill_session(session_ref)
        session_ref.merge("killed" => true, "is_streaming" => false)
      end

      def get_state(session_ref)
        session_ref
      end

      def read_events(_session_ref)
        []
      end

      def attach_session(session_ref)
        session_ref
      end
    end
  end
end
