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
    end
  end
end
