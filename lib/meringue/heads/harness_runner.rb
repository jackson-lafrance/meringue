# frozen_string_literal: true

require "json"
require "timeout"

module Meringue
  module Heads
    class HarnessRunner < Runner
      DEFAULT_TIMEOUT = 120

      attr_reader :harness_client, :cwd, :session_name_prefix, :timeout

      def initialize(harness_client:, cwd: Dir.pwd, session_name_prefix: "Meringue Head", timeout: DEFAULT_TIMEOUT)
        @harness_client = harness_client
        @cwd = File.expand_path(cwd)
        @session_name_prefix = session_name_prefix
        @timeout = timeout
      end

      def run(user_message:, snapshot:, context: nil, question_id: nil)
        context ||= build_context(user_message: user_message, snapshot: snapshot, question_id: question_id)
        session_ref = spawn_head_session(
          user_message: user_message,
          snapshot: snapshot,
          context: context,
          question_id: question_id
        )

        wait_for_settled(session_ref)
        parse_head_result_text(last_assistant_text(session_ref).to_s)
      ensure
        harness_client.kill_session(session_ref) if session_ref && harness_client.respond_to?(:kill_session)
      end

      def spawn_head_session(user_message:, snapshot:, context: nil, question_id: nil)
        context ||= build_context(user_message: user_message, snapshot: snapshot, question_id: question_id)

        harness_client.spawn_session(
          kind: "head",
          cwd: cwd,
          prompt: head_prompt(context),
          system_prompt: context.system_prompt,
          session_name: session_name(context)
        )
      end

      def parse_head_result_text(raw_output)
        ResultParser.parse(raw_output)
      end

      private

      def build_context(user_message:, snapshot:, question_id: nil)
        Context.new(
          head_id: "H?",
          user_message: user_message,
          snapshot: snapshot,
          question_id: question_id,
          cwd: cwd
        )
      end

      def wait_for_settled(session_ref)
        if harness_client.respond_to?(:wait_for_settled)
          harness_client.wait_for_settled(session_ref, timeout: timeout)
        else
          deadline = Time.now + timeout
          loop do
            state_ref = harness_client.get_state(session_ref)
            return state_ref unless state_ref.fetch("is_streaming", false)

            raise Timeout::Error, "Timed out waiting for head session to settle" if Time.now >= deadline

            sleep 0.1
          end
        end
      end

      def last_assistant_text(session_ref)
        return harness_client.last_assistant_text(session_ref) if harness_client.respond_to?(:last_assistant_text)

        state_ref = harness_client.get_state(session_ref)
        state_ref.dig("metadata", "last_assistant_text")
      end

      def session_name(context)
        title = context.user_message.to_s.strip.gsub(/\s+/, " ")[0, 48]
        title = "untitled request" if title.empty?
        "#{session_name_prefix} #{context.head_id}: #{title}"
      end

      def head_prompt(context)
        <<~PROMPT
          Return only a JSON object matching the Meringue HeadResult contract.

          The kernel command reference has already been appended to your system prompt.
          Use the context JSON below to decide which kernel command to propose.
          When the project is unclear, use your read-only tools to inspect local repositories before returning the final JSON.

          Meringue head context JSON:
          #{JSON.pretty_generate(context.to_prompt_h)}
        PROMPT
      end
    end
  end
end
