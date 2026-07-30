# frozen_string_literal: true

module Meringue
  module Harness
    class FakeClient < Client
      def harness_name
        "fake"
      end

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

      # Deterministic stand-in catalog so tests and the demo state can exercise
      # catalog-driven UI without spawning a harness process.
      FAKE_MODELS = [
        { "provider" => "fake", "id" => "fake-large", "name" => "Fake Large",
          "thinking_levels" => %w[off low medium high], "reasoning" => true, "context_window" => 200_000 },
        { "provider" => "fake", "id" => "fake-small", "name" => "Fake Small",
          "thinking_levels" => ["off"], "reasoning" => false, "context_window" => 32_000 }
      ].freeze

      def model_catalog_supported?
        true
      end

      def available_models(cwd: nil) # rubocop:disable Lint/UnusedMethodArgument
        ModelCatalog.available(harness: harness_name, models: FAKE_MODELS, source: "fake_client")
      end

      def attach_session(session_ref)
        session_ref
      end
    end
  end
end
