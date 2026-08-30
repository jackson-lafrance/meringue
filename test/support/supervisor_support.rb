# frozen_string_literal: true

require "json"
require "time"

require_relative "../../lib/meringue/supervisor/transport_adapter"
require_relative "../../lib/meringue/supervisor/errors"

module Meringue
  module Supervisor
    # Hermetic, in-process transport adapter for the supervisor test suite.
    #
    # It implements the full `TransportAdapter` contract without ever spawning a
    # real harness process: ownership is an in-memory Hash, evidence is scripted
    # per session, and attach/prompt/abort/kill record their calls so tests can
    # assert exactly-once delivery and no-duplicate-prompt recovery. This is the
    # supervisor analogue of `Meringue::Harness::FakeClient`.
    class FakeTransportAdapter
      include TransportAdapter

      attr_reader :harness_name_value, :claims, :releases, :attaches, :prompts,
                  :aborts, :kills, :states, :wait_calls
      attr_accessor :now

      def initialize(harness_name: "pi", now: Time.now.utc)
        @harness_name_value = harness_name
        @now = now
        @records = {}            # transport_key -> ownership record
        @evidence = {}           # transport_key -> evidence Hash (or nil)
        @streaming = {}          # transport_key -> bool
        @session_refs = {}       # transport_key -> latest ref
        @claims = []
        @releases = []
        @attaches = []
        @prompts = []
        @aborts = []
        @kills = []
        @states = []
        @wait_calls = []
        @attach_result = nil
        @attach_error = nil
      end

      def harness_name
        @harness_name_value
      end

      def capabilities
        { "session_start" => true, "session_lookup" => true, "health_status" => true,
          "attachment" => "fake", "recovery" => "fake", "stop" => true,
          "concurrent_sessions" => true }
      end

      def transport_key(session_ref)
        session_id = session_ref.fetch("session_id", nil) || session_ref.fetch(:session_id, nil)
        "#{harness_name_value}-#{session_id}"
      end

      def seed_session(session_ref, streaming: false, evidence: nil)
        key = transport_key(session_ref)
        @session_refs[key] = session_ref.dup
        @streaming[key] = streaming
        @evidence[key] = evidence
        @records[key] = {
          "session_id" => session_ref.fetch("session_id"),
          "pid" => session_ref.fetch("pid"),
          "owner_pid" => nil,
          "updated_at" => iso8601(now)
        }
        self
      end

      def set_streaming(session_ref, value)
        @streaming[transport_key(session_ref)] = !!value
        self
      end

      def set_evidence(session_ref, evidence)
        @evidence[transport_key(session_ref)] = evidence
        self
      end

      def claim(session_ref, harness_pid:, note: nil)
        key = transport_key(session_ref)
        @claims << { "key" => key, "harness_pid" => harness_pid, "note" => note }
        @records[key] = {
          "session_id" => session_ref.fetch("session_id"),
          "pid" => harness_pid,
          "owner_pid" => owner_pid_from_note(note),
          "updated_at" => iso8601(now)
        }
        @session_refs[key] = session_ref.dup
        record_for(session_ref)
      end

      def release(session_ref, harness_pid: nil)
        key = transport_key(session_ref)
        @releases << { "key" => key, "harness_pid" => harness_pid }
        return false if harness_pid && @records[key] && @records[key].fetch("pid") != harness_pid

        @records[key] = { "session_id" => session_ref.fetch("session_id"), "released" => true, "updated_at" => iso8601(now) }
        true
      end

      def record_for(session_ref)
        @records[transport_key(session_ref)] || {}
      end

      def evidence(session_ref)
        @evidence[transport_key(session_ref)]
      end

      def attach(session_ref)
        key = transport_key(session_ref)
        @attaches << key
        raise @attach_error if @attach_error

        base = @session_refs[key] || session_ref
        ref = base.merge("pid" => base.fetch("pid", nil) || 20_000 + @attaches.length,
                         "is_streaming" => @streaming.fetch(key, false))
        @session_refs[key] = ref
        ref
      end

      def prompt(session_ref, prompt, mode: "normal")
        key = transport_key(session_ref)
        @prompts << { "key" => key, "prompt" => prompt, "mode" => mode }
        ref = (@session_refs[key] || session_ref).merge("is_streaming" => true)
        @session_refs[key] = ref
        @streaming[key] = true
        ref
      end

      def abort(session_ref)
        key = transport_key(session_ref)
        @aborts << key
        @streaming[key] = false
        ref = (@session_refs[key] || session_ref).merge("is_streaming" => false)
        @session_refs[key] = ref
        ref
      end

      def kill(session_ref)
        key = transport_key(session_ref)
        @kills << key
        @streaming[key] = false
        ref = (@session_refs[key] || session_ref).merge("is_streaming" => false, "killed" => true)
        @session_refs[key] = ref
        ref
      end

      def get_state(session_ref)
        key = transport_key(session_ref)
        @states << key
        ref = (@session_refs[key] || session_ref).merge("is_streaming" => @streaming.fetch(key, false))
        @session_refs[key] = ref
        ref
      end

      def streaming?(session_ref)
        @streaming.fetch(transport_key(session_ref), false)
      end

      def wait_for_settled(session_ref, timeout:)
        key = transport_key(session_ref)
        @wait_calls << { "key" => key, "timeout" => timeout }
        @streaming[key] = false
        [get_state(session_ref)]
      end

      def stub_attach_error(error)
        @attach_error = error
        self
      end

      private

      def owner_pid_from_note(note)
        # Tests do not need a real owner pid in the fake record; the supervisor
        # service records its own owner identity in the durable state store.
        nil
      end

      def iso8601(time)
        time.respond_to?(:iso8601) ? time.iso8601(6) : Time.parse(time.to_s).iso8601(6)
      end
    end
  end
end
