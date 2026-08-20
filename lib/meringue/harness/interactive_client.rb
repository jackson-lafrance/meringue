# frozen_string_literal: true

require "json"
require "securerandom"
require "thread"
require "time"

module Meringue
  module Harness
    # A harness backend driven entirely through the agent CLI's own interactive mode.
    #
    # Meringue starts the agent once, in a PTY it keeps for the life of the session, and from then
    # on does two things with it: it types prompts in, and it reads the agent's durable JSONL
    # transcript back out. There is no second transport and no separate "print" invocation per
    # turn, which is what lets the same live session be both autonomously driven and directly
    # watched. Opening the focused viewer attaches to the PTY that is already running, so focusing
    # a worker never interrupts its turn or replaces its process.
    #
    # Everything Meringue decides about a session is read from the transcript, never scraped from
    # the screen. A subclass supplies the provider's argv, where that provider writes its
    # transcript, and a TranscriptSchema that interprets it.
    class InteractiveClient < Client
      DEFAULT_READY_TIMEOUT = 90
      DEFAULT_SUBMIT_SETTLE_TIMEOUT = 15
      DEFAULT_ABORT_TIMEOUT = 20
      DEFAULT_SHUTDOWN_TIMEOUT = 3
      # Bounds how long a submitted prompt may stay unconfirmed in the transcript before the
      # session is treated as no longer streaming. Without it, an agent CLI that silently dropped
      # the keystrokes would leave a worker "working" forever.
      DEFAULT_DELIVERY_CONFIRM_TIMEOUT = 180
      DELIVERY_MARKER_PREFIX = "<!-- meringue-delivery:"
      # Enough recent conversation records to answer "is this turn still running". Older records
      # cannot change that answer, and keeping them would grow with session age.
      CONVERSATION_WINDOW_RECORDS = 64
      PROMPT_MODES = %w[normal steer follow_up].freeze

      class Error < StandardError; end
      class SessionNotRunningError < Error
        include SessionProcessGoneError
      end
      class StartupError < Error; end
      class PromptDeliveryError < Error; end
      class BusyError < Error
        include TransientSessionError
      end

      attr_reader :harness_name, :command, :env, :extra_args, :ready_timeout, :shutdown_timeout

      def initialize(harness_name:, command:, transcript_schema:, env: {}, extra_args: [],
                     ready_timeout: DEFAULT_READY_TIMEOUT,
                     shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT,
                     delivery_confirm_timeout: DEFAULT_DELIVERY_CONFIRM_TIMEOUT)
        @harness_name = harness_name.to_s
        @command = command.is_a?(Array) ? command.map(&:to_s) : [command.to_s]
        @transcript_schema = transcript_schema
        @env = env.transform_keys(&:to_s)
        @extra_args = Array(extra_args).map(&:to_s)
        @ready_timeout = ready_timeout
        @shutdown_timeout = shutdown_timeout
        @delivery_confirm_timeout = delivery_confirm_timeout
        @sessions = {}
        @mutex = Mutex.new
      end

      # Replacement spawn defaults. Existing PTYs keep the arguments they were started with,
      # exactly as a running process would; only the next spawn picks these up.
      def configure_spawn_arguments(args)
        @extra_args = Array(args).map(&:to_s)
        self
      end

      # ---------------------------------------------------------------- lifecycle

      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, session_settings: {}, workspace_mode: "isolated")
        expanded_cwd = validate_cwd!(cwd)
        if workspace_mode.to_s == "shared_read_only" && !read_only_workspace_supported?
          raise Error, "#{harness_name} does not enforce read-only worker tools"
        end

        session_id = new_session_id
        prepare_workspace!(expanded_cwd)
        argv = spawn_argv(
          kind: kind.to_s,
          cwd: expanded_cwd,
          session_id: session_id,
          system_prompt: system_prompt.to_s,
          session_name: session_name.to_s,
          session_settings: session_settings || {}
        )
        entry = start_session_entry(
          session_id: session_id,
          cwd: expanded_cwd,
          argv: argv,
          kind: kind.to_s,
          session_name: session_name.to_s,
          session_settings: session_settings || {}
        )
        deliver_prompt!(entry, prompt.to_s, mode: "normal", delivery_id: nil) if present?(prompt)
        session_ref_for(entry)
      rescue StandardError
        discard_session(session_id) if defined?(session_id) && session_id
        raise
      end

      def prompt_session(session_ref, prompt, mode: "normal", delivery_id: nil)
        text = prompt.to_s
        raise Error, "prompt cannot be empty" if text.strip.empty?

        requested_mode = PROMPT_MODES.include?(mode.to_s) ? mode.to_s : "normal"
        entry = ensure_running_entry(session_ref)
        delivered_mode = deliver_prompt!(entry, text, mode: requested_mode, delivery_id: delivery_id)
        ref = session_ref_for(entry, previous: session_ref)
        return ref if delivered_mode == requested_mode

        ref.merge(
          "metadata" => metadata_with(
            ref,
            "requested_prompt_mode" => requested_mode,
            "delivered_prompt_mode" => delivered_mode,
            "prompt_mode_note" => prompt_mode_note(requested_mode, delivered_mode)
          )
        )
      end

      # Cancels the agent's current operation through the CLI's own interrupt key. The process is
      # never signalled: interrupting a turn must leave the session alive and promptable, which is
      # the difference between cancelling work and killing a worker.
      def abort_session(session_ref)
        entry = live_entry(session_ref)
        return completed_session_ref(session_ref) unless entry && entry.fetch("process").alive?

        clear_pending_delivery(entry)
        interrupt(entry.fetch("process"))
        wait_until_settled(entry, timeout: DEFAULT_ABORT_TIMEOUT)
        session_ref_for(entry, previous: session_ref).merge("is_streaming" => false)
      end

      def kill_session(session_ref)
        session_id = session_id_for(session_ref)
        entry = @mutex.synchronize { @sessions.delete(session_id) }
        unless entry
          return session_ref.merge(
            "is_streaming" => false,
            "metadata" => metadata_with(session_ref, "killed" => true, "kill_note" => "no live #{harness_name} process found")
          )
        end

        process = entry.fetch("process")
        pid = process.pid
        process.terminate(timeout: shutdown_timeout)
        session_ref.merge(
          "pid" => nil,
          "is_streaming" => false,
          "session_file" => entry.fetch("transcript_path", nil),
          "metadata" => metadata_with(session_ref, "killed" => true, "killed_pid" => pid)
        )
      end

      def get_state(session_ref)
        entry = live_entry(session_ref)
        return completed_session_ref(session_ref) unless entry

        process = entry.fetch("process")
        unless process.alive?
          discard_session(entry.fetch("session_id"))
          return completed_session_ref(session_ref).merge(
            "metadata" => metadata_with(session_ref, "exit_status" => process.exit_status)
          )
        end

        session_ref_for(entry, previous: session_ref)
      end

      # ------------------------------------------------------------------- events

      def read_events(session_ref)
        entry = live_entry(session_ref) || adopted_entry(session_ref)
        return [] unless entry

        records = entry.fetch("tail").poll
        return [] if records.empty?

        observe_delivery(entry, records)
        touch_last_event(entry)
        transcript_schema.events(records)
      end

      def session_progress(events)
        transcript_schema.progress(events)
      end

      def turn_outcome(session_ref)
        records = transcript_records(session_ref)
        return nil if records.empty?

        transcript_schema.turn_outcome(records)
      end

      def last_assistant_text(session_ref)
        records = transcript_records(session_ref)
        return nil if records.empty?
        # A finished previous turn must never answer for a turn that is still running: the kernel
        # would settle the worker on the wrong text.
        return nil if current_turn_pending?(session_ref)

        transcript_schema.last_assistant_text(records)
      end

      def session_exit_evidence(session_ref)
        entry = live_entry(session_ref)
        return nil unless entry

        process = entry.fetch("process")
        {
          "pid" => process.pid,
          "exit_status" => process.exit_status,
          "last_event_at" => entry.fetch("last_event_at", nil),
          "screen_tail" => screen_tail(process)
        }.compact
      end

      # ------------------------------------------------------- prompt delivery receipts

      # Every prompt carries a marker that lands in the transcript with the user message, so a
      # keystroke write that appeared to fail can still be proven delivered afterwards. This is
      # what stops Meringue from sending the same instruction to a worker twice.
      def prompt_delivery_receipts_supported?
        true
      end

      def ambiguous_prompt_delivery_error?(error)
        error.is_a?(BusyError) || error.is_a?(PromptDeliveryError)
      end

      def prompt_delivery_status(session_ref, delivery_id:, prompt:, started_at: nil)
        _ = prompt
        _ = started_at
        marker = delivery_marker(delivery_id)
        return { "status" => "unknown" } unless marker

        entry = live_entry(session_ref)
        alive = entry ? entry.fetch("process").alive? : false
        delivered = transcript_contains_marker?(session_ref, marker)
        return { "status" => "delivered", "process_alive" => alive, "pid" => entry&.fetch("process")&.pid }.compact if delivered
        return { "status" => "pending", "process_alive" => true } if alive

        { "status" => "not_delivered", "process_alive" => false }
      end

      # --------------------------------------------------------------- attach / views

      # Adopts a durable session this process did not start. No PTY is created: the transcript is
      # enough to show history and to answer state questions, and starting a second writer for a
      # session that may still be owned elsewhere is exactly what must not happen.
      def attach_session(session_ref)
        entry = adopted_entry(session_ref)
        return session_ref.merge("is_streaming" => false) unless entry

        session_ref.merge(
          "session_file" => entry.fetch("transcript_path", nil),
          "pid" => nil,
          "is_streaming" => false,
          "metadata" => metadata_with(session_ref, "attach_mode" => "transcript_history")
        )
      end

      def open_session_view(session_ref)
        SessionView::Handle.new(
          snapshot_loader: lambda {
            entry = live_entry(session_ref) || adopted_entry(session_ref)
            unless entry
              next SessionView.unavailable_snapshot(
                harness: harness_name,
                availability: "unavailable",
                message: "This agent session has no readable transcript yet."
              )
            end

            transcript_schema.snapshot(
              records: entry.fetch("tail").all_records,
              session_ref: session_ref,
              harness: harness_name,
              live: !!entry.fetch("process", nil)&.alive?
            )
          },
          event_reader: lambda { |cursor, limit|
            entry = live_entry(session_ref) || adopted_entry(session_ref)
            journal = entry&.fetch("journal", nil)
            next { "entries" => [], "cursor" => cursor, "latest_cursor" => cursor, "gap" => false } unless journal

            # Filled here rather than during reconciliation, so the transcript pane updates at its
            # own refresh rate and on a cursor nothing else consumes.
            publish_journal(entry, entry.fetch("view_tail").poll)
            journal.read(after: cursor, limit: limit)
          },
          event_normalizer: ->(entry) { transcript_schema.normalize_journal_entry(entry) }
        )
      end

      # ------------------------------------------------------------- live terminal

      # The whole point of this transport. The session is already an interactive process with a
      # rendered screen, so focusing it is an attach, not a handoff: nothing is aborted, quiesced,
      # replaced, or killed, and returning to the dashboard costs nothing either.
      def live_terminal_supported?
        true
      end

      def live_terminal(session_ref)
        entry = ensure_running_entry(session_ref)
        LiveTerminal.new(
          harness: harness_name,
          session_id: entry.fetch("session_id"),
          cwd: entry.fetch("cwd"),
          process: entry.fetch("process")
        )
      end

      # A client that keeps its own live PTY has nothing to prepare and nothing to hand over, so
      # the older abort-and-relaunch focus path stays switched off for it.
      def interactive_session_supported?
        false
      end

      def shutdown
        entries = @mutex.synchronize do
          current = @sessions.values
          @sessions.clear
          current
        end
        entries.each do |entry|
          entry.fetch("process").terminate(timeout: shutdown_timeout)
        rescue StandardError
          nil
        end
        true
      end

      # ------------------------------------------------------------ subclass contract

      protected

      attr_reader :transcript_schema, :delivery_confirm_timeout

      # argv for a brand-new session.
      def spawn_argv(kind:, cwd:, session_id:, system_prompt:, session_name:, session_settings:)
        raise NotImplementedError, "#{self.class} must implement #spawn_argv"
      end

      # argv that reopens a durable session after the process that owned it is gone.
      def resume_argv(session_ref)
        raise NotImplementedError, "#{self.class} must implement #resume_argv"
      end

      # Where the provider writes this session's transcript.
      def transcript_path(cwd:, session_id:)
        raise NotImplementedError, "#{self.class} must implement #transcript_path"
      end

      # Provider-specific one-time setup for a workspace, such as recording that a newly created
      # worktree is trusted so the CLI does not stop at a modal before its prompt appears.
      def prepare_workspace!(_cwd); end

      # Blocks until the CLI is ready to accept typed input. Returning false aborts the spawn with
      # a clear error rather than typing a prompt into a program that is not listening.
      def wait_until_ready(process)
        process.wait_for_quiet(quiet_for: 0.75, timeout: ready_timeout)
      end

      # How the provider's prompt box receives a whole prompt. Bracketed paste keeps a multi-line
      # prompt one submission instead of letting each newline submit a fragment.
      def submit_prompt(process, text)
        process.write("\e[200~#{text}\e[201~")
        process.wait_for_quiet(quiet_for: 0.2, timeout: 10)
        process.write("\r")
      end

      # The provider's cancel key.
      def interrupt(process)
        process.write("\e")
      end

      def process_environment(cwd)
        base = SubprocessEnvironment.clean(ENV.to_h)
        base.merge(
          env,
          Git::CommitIdentity.environment(cwd: cwd, base_environment: base),
          "TERM" => env.fetch("TERM", "xterm-256color"),
          "COLORTERM" => env.fetch("COLORTERM", "truecolor")
        )
      end

      def command_argv
        command.dup
      end

      def new_session_id
        SecureRandom.uuid
      end

      # ------------------------------------------------------------------- internals

      private

      def start_session_entry(session_id:, cwd:, argv:, kind:, session_name:, session_settings:)
        process = InteractiveProcess.new(argv: argv, cwd: cwd, env: process_environment(cwd))
        process.start
        path = transcript_path(cwd: cwd, session_id: session_id)
        entry = {
          "session_id" => session_id,
          "cwd" => cwd,
          "kind" => kind,
          "session_name" => session_name,
          "session_settings" => session_settings,
          "process" => process,
          "tail" => TranscriptTail.new(path: path),
          "state_tail" => TranscriptTail.new(path: path),
          "view_tail" => TranscriptTail.new(path: path),
          "conversation" => [],
          "transcript_path" => path,
          "journal" => EventJournal.new,
          "pending_delivery" => nil,
          "last_event_at" => nil,
          "mutex" => Mutex.new
        }
        unless wait_until_ready(process)
          process.terminate(timeout: shutdown_timeout)
          raise StartupError, startup_error_message(process)
        end

        @mutex.synchronize { @sessions[session_id] = entry }
        entry
      end

      def startup_error_message(process)
        tail = screen_tail(process)
        base = "#{harness_name} did not become ready for interactive input within #{ready_timeout}s"
        tail.to_s.empty? ? base : "#{base}. Last screen: #{tail}"
      end

      # A session whose PTY is gone is restarted from its durable transcript rather than treated as
      # dead. This is what makes a worker survive a Meringue restart: the agent's own resume path
      # rebuilds the conversation, and the same session id keeps pointing at the same transcript.
      def ensure_running_entry(session_ref)
        entry = live_entry(session_ref)
        return entry if entry&.fetch("process")&.alive?

        discard_session(entry.fetch("session_id")) if entry
        restart_entry(session_ref)
      end

      def restart_entry(session_ref)
        session_id = session_id_for(session_ref)
        raise SessionNotRunningError, "#{harness_name} session has no session id to resume" unless present?(session_id)

        cwd = validate_cwd!(session_ref["cwd"] || session_ref[:cwd] || Dir.pwd)
        prepare_workspace!(cwd)
        argv = resume_argv(session_ref.merge("cwd" => cwd, "session_id" => session_id))
        entry = start_session_entry(
          session_id: session_id,
          cwd: cwd,
          argv: argv,
          kind: metadata_value(session_ref, "kind").to_s,
          session_name: metadata_value(session_ref, "session_name").to_s,
          session_settings: session_ref.fetch("session_settings", {}) || {}
        )
        # A resumed session's transcript already holds its whole history. Replaying it as new
        # events would re-log the entire conversation as if it had just happened.
        entry.fetch("tail").seek_to_end
        entry.fetch("state_tail").seek_to_end
        entry
      end

      def deliver_prompt!(entry, text, mode:, delivery_id:)
        process = entry.fetch("process")
        raise SessionNotRunningError, "#{harness_name} session process is not running" unless process.alive?

        delivered_mode = mode
        if mode == "steer" && streaming_entry?(entry)
          interrupt(process)
          # Steering must land on a settled prompt box. Typing into a TUI that is still tearing
          # down its turn is how prompts get split or swallowed.
          unless wait_until_settled(entry, timeout: DEFAULT_ABORT_TIMEOUT)
            raise BusyError, "#{harness_name} did not settle its current turn in time to steer it"
          end
        elsif mode == "follow_up" && streaming_entry?(entry)
          # Interactive agent CLIs queue what is typed during a turn, which is exactly follow-up
          # semantics, so the text goes in as-is.
          delivered_mode = "follow_up"
        end

        marker = delivery_marker(delivery_id)
        payload = marker ? "#{text}\n\n#{marker}" : text
        entry.fetch("mutex").synchronize do
          entry["pending_delivery"] = {
            "id" => delivery_id&.to_s,
            "marker" => marker,
            "text" => text,
            "submitted_at" => Time.now.utc,
            "confirmed" => false
          }
        end
        begin
          submit_prompt(process, single_line_payload(payload))
        rescue IOError => e
          raise PromptDeliveryError, "could not send the prompt to #{harness_name}: #{e.message}"
        end
        delivered_mode
      end

      # A prompt box submits on Enter, so any literal newline in the text would send a fragment.
      # Bracketed paste is what keeps a multi-line prompt intact; providers whose prompt box does
      # not support it override #submit_prompt.
      def single_line_payload(text)
        text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      end

      def delivery_marker(delivery_id)
        value = delivery_id.to_s.strip
        return nil if value.empty?

        "#{DELIVERY_MARKER_PREFIX} #{value.gsub(/[^A-Za-z0-9_.:@\/-]/, "_")} -->"
      end

      def observe_delivery(entry, records)
        pending = entry.fetch("mutex").synchronize { entry.fetch("pending_delivery", nil) }
        return unless pending && !pending.fetch("confirmed", false)

        confirmed = transcript_schema.user_prompt_present?(records, marker: pending["marker"], text: pending["text"])
        return unless confirmed

        entry.fetch("mutex").synchronize do
          current = entry.fetch("pending_delivery", nil)
          entry["pending_delivery"] = current.merge("confirmed" => true) if current
        end
      end

      def clear_pending_delivery(entry)
        entry.fetch("mutex").synchronize { entry["pending_delivery"] = nil }
      end

      # A prompt Meringue has typed but has not yet seen in the transcript means the turn it starts
      # has not begun. Reporting "idle" in that window would settle the worker on the previous
      # turn's answer.
      def current_turn_pending?(session_ref)
        entry = live_entry(session_ref)
        return false unless entry

        pending = entry.fetch("mutex").synchronize { entry.fetch("pending_delivery", nil) }
        return false unless pending
        return false if pending.fetch("confirmed", false)

        if Time.now.utc - pending.fetch("submitted_at") > delivery_confirm_timeout
          clear_pending_delivery(entry)
          return false
        end
        # Refreshed here too, so a caller that only ever asks for state still notices delivery.
        refresh_conversation!(entry)
        !entry.fetch("mutex").synchronize { entry.fetch("pending_delivery", {}) || {} }.fetch("confirmed", false)
      end

      def streaming_entry?(entry)
        session_state(entry) == "streaming"
      end

      # State is derived from the conversation records seen so far, refreshed incrementally.
      #
      # Re-reading the whole transcript on every poll would make reconciliation cost grow with
      # session age: an hour-old worker has a multi-megabyte transcript and is polled every couple
      # of seconds. The bounded window kept here is all the schema needs to answer.
      def session_state(entry)
        refresh_conversation!(entry)
        pending = entry.fetch("mutex").synchronize { entry.fetch("pending_delivery", nil) }
        return "streaming" if pending && !pending.fetch("confirmed", false) &&
                              Time.now.utc - pending.fetch("submitted_at") <= delivery_confirm_timeout

        transcript_schema.session_state(entry.fetch("mutex").synchronize { entry.fetch("conversation", []).dup })
      end

      # Consumes only what this cursor has not seen. It is deliberately a different cursor from the
      # one `read_events` drains, so neither can steal the other's records.
      def refresh_conversation!(entry)
        tail = entry.fetch("state_tail", nil)
        return unless tail

        records = tail.poll
        return if records.empty?

        conversation = transcript_schema.conversation_records(records)
        observe_delivery(entry, records)
        return if conversation.empty?

        entry.fetch("mutex").synchronize do
          window = entry.fetch("conversation", [])
          window.concat(conversation)
          window.shift while window.length > CONVERSATION_WINDOW_RECORDS
          entry["conversation"] = window
        end
      end

      def wait_until_settled(entry, timeout:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
        loop do
          return true unless streaming_entry?(entry)
          return false unless entry.fetch("process").alive?
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.2
        end
      end

      def transcript_records(session_ref)
        entry = live_entry(session_ref) || adopted_entry(session_ref)
        return [] unless entry

        entry.fetch("tail").all_records
      end

      def transcript_contains_marker?(session_ref, marker)
        return false unless present?(marker)

        transcript_schema.user_prompt_present?(transcript_records(session_ref), marker: marker, text: nil)
      end

      def live_entry(session_ref)
        @mutex.synchronize { @sessions[session_id_for(session_ref)] }
      end

      # A read-only stand-in for a durable session with no process here: it can answer from the
      # transcript but owns nothing and starts nothing.
      def adopted_entry(session_ref)
        session_id = session_id_for(session_ref)
        return nil unless present?(session_id)

        path = session_ref["session_file"] || session_ref[:session_file] ||
               transcript_path(cwd: session_ref["cwd"] || session_ref[:cwd], session_id: session_id)
        return nil unless present?(path) && File.file?(path.to_s)

        @mutex.synchronize do
          cached = @adopted ||= {}
          entry = cached[session_id]
          if entry.nil? || entry.fetch("transcript_path") != path
            entry = {
              "session_id" => session_id,
              "cwd" => session_ref["cwd"] || session_ref[:cwd],
              "process" => nil,
              "tail" => TranscriptTail.new(path: path),
              "state_tail" => TranscriptTail.new(path: path),
              "view_tail" => TranscriptTail.new(path: path),
              "conversation" => [],
              "transcript_path" => path,
              "journal" => EventJournal.new,
              "pending_delivery" => nil,
              "last_event_at" => nil,
              "mutex" => Mutex.new
            }
            cached[session_id] = entry
          end
          entry
        end
      end

      def publish_journal(entry, records)
        journal = entry.fetch("journal", nil)
        return if journal.nil? || records.empty?

        transcript_schema.events(records).each { |event| journal.publish(event) }
      end

      def discard_session(session_id)
        entry = @mutex.synchronize { @sessions.delete(session_id) }
        return false unless entry

        begin
          entry.fetch("process")&.terminate(timeout: shutdown_timeout)
        rescue StandardError
          nil
        end
        true
      end

      def touch_last_event(entry)
        entry["last_event_at"] = Time.now.utc.iso8601
      end

      def session_ref_for(entry, previous: {})
        process = entry.fetch("process", nil)
        state = session_state(entry)
        {
          "harness" => harness_name,
          "pid" => process&.alive? ? process.pid : nil,
          "cwd" => entry.fetch("cwd"),
          "session_id" => entry.fetch("session_id"),
          "session_file" => entry.fetch("transcript_path", nil),
          "is_streaming" => state == "streaming",
          "last_event_at" => entry.fetch("last_event_at", nil),
          "metadata" => (previous.fetch("metadata", {}) || {}).merge(
            {
              "kind" => entry.fetch("kind", nil),
              "session_name" => entry.fetch("session_name", nil),
              "transport" => "interactive_pty",
              "session_state" => state,
              "started_at" => process&.started_at&.iso8601
            }.compact
          )
        }
      end

      def completed_session_ref(session_ref)
        session_ref.merge(
          "pid" => nil,
          "is_streaming" => false,
          "metadata" => metadata_with(session_ref, "transport" => "interactive_pty")
        )
      end

      def screen_tail(process, limit: 400)
        text = process.plain_screen_text.to_s.split("\n").map(&:rstrip).reject(&:empty?).last(6).join(" | ")
        text.length > limit ? text[-limit, limit] : text
      end

      def prompt_mode_note(requested, delivered)
        "#{harness_name} could not deliver a #{requested} prompt right now; it was delivered as #{delivered} instead."
      end

      def session_id_for(session_ref)
        (session_ref["session_id"] || session_ref[:session_id]).to_s
      end

      def metadata_value(session_ref, key)
        (session_ref.fetch("metadata", {}) || {})[key.to_s]
      end

      def metadata_with(session_ref, *values)
        base = (session_ref.fetch("metadata", {}) || {}).dup
        values.each { |value| base.merge!(value.is_a?(Hash) ? value : {}) }
        base.compact
      end

      def validate_cwd!(cwd)
        path = File.expand_path(cwd.to_s)
        raise Error, "workspace directory does not exist: #{path}" unless Dir.exist?(path)

        path
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      # A handle onto the session's already-running PTY. It carries input and screen only: a UI
      # holding one can type and watch, but cannot detach, signal, or kill the session, which stays
      # the kernel's to own.
      class LiveTerminal
        attr_reader :harness, :session_id, :cwd

        def initialize(harness:, session_id:, cwd:, process:)
          @harness = harness
          @session_id = session_id
          @cwd = cwd
          @process = process
        end

        def write(bytes)
          return { "status" => "ignored" } unless alive?

          @process.write(bytes)
          { "status" => "written", "bytes" => bytes.to_s.bytesize }
        rescue IOError => e
          { "status" => "failed", "message" => e.message }
        end

        def snapshot(rows: nil, columns: nil)
          @process.snapshot(rows: rows, columns: columns).merge(
            "harness" => harness,
            "session_id" => session_id,
            "workspace_path" => cwd
          )
        end

        def resize(rows:, columns:)
          @process.resize(rows: rows, columns: columns)
        end

        def alive?
          @process.alive?
        end

        def pid
          @process.pid
        end
      end
    end
  end
end
