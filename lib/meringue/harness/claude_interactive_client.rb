# frozen_string_literal: true

require "json"

module Meringue
  module Harness
    # Claude Code as a Meringue backend, driven through its interactive mode.
    #
    # One `claude` process per session lives in a PTY for as long as the session does. Prompts are
    # typed into it and results are read from the session transcript it writes, which means the
    # same running session serves an autonomous head or worker and the focused session viewer
    # without any handoff between them.
    class ClaudeInteractiveClient < InteractiveClient
      DEFAULT_COMMAND = "claude"
      # Where Claude Code writes session transcripts. CLAUDE_CONFIG_DIR moves this whole tree.
      DEFAULT_CLAUDE_HOME = File.expand_path("~/.claude")
      # Claude Code boots an LSP, plugins, and MCP servers before its prompt is usable. A cold
      # start on a large repository is comfortably slower than a shell.
      READY_TIMEOUT = 120
      READY_QUIET_SECONDS = 1.0
      TRUST_PROMPT_PATTERN = /trust this folder|Is this a project you (?:created|trust)/i.freeze
      TRUST_ANSWER_TIMEOUT = 20
      # Claude Code's cancel key. Ctrl-C clears the prompt box instead of stopping a turn, so it
      # would leave the agent working while Meringue believed it had aborted.
      INTERRUPT_KEY = "\e"
      # Inherited markers from a parent Claude Code session make a child disable its own transcript
      # and adopt the parent's identity. Meringue reads that transcript, so it must never inherit.
      INHERITED_SESSION_ENV = %w[
        CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
        CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_EXECPATH
        CLAUDE_PID CLAUDE_EFFORT
      ].freeze

      attr_reader :claude_home

      def model_catalog_supported?
        true
      end

      def available_models(cwd: nil)
        ClaudeModelCatalog.fetch(
          command: command,
          env: env,
          cwd: cwd,
          extra_args: extra_args,
          timeout: ClaudeModelCatalog::DEFAULT_TIMEOUT
        )
      end

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [],
                     claude_home: ENV.fetch("CLAUDE_CONFIG_DIR", DEFAULT_CLAUDE_HOME), **kwargs)
        super(
          harness_name: "claude",
          command: command,
          transcript_schema: ClaudeTranscript,
          env: env,
          extra_args: extra_args,
          ready_timeout: kwargs.fetch(:ready_timeout, READY_TIMEOUT),
          shutdown_timeout: kwargs.fetch(:shutdown_timeout, DEFAULT_SHUTDOWN_TIMEOUT),
          delivery_confirm_timeout: kwargs.fetch(:delivery_confirm_timeout, DEFAULT_DELIVERY_CONFIRM_TIMEOUT)
        )
        @claude_home = File.expand_path(claude_home.to_s)
      end

      # Claude Code's own tool allowlist is what enforces this, and the registry passes it as spawn
      # arguments for a read-only role.
      def read_only_workspace_supported?
        true
      end

      protected

      def spawn_argv(kind:, cwd:, session_id:, system_prompt:, session_name:, session_settings:)
        _ = cwd
        argv = command_argv
        argv += ["--session-id", session_id.to_s]
        argv += ["--name", session_name.to_s] if present?(session_name)
        argv += ["--system-prompt", system_prompt.to_s] if present?(system_prompt)
        argv += session_settings_argv(session_settings)
        argv + extra_args
      end

      # A session whose process is gone is reopened by id, so the same transcript keeps growing and
      # the agent still has the conversation it had before. --session-id would refuse an id that
      # already exists, which is why resuming uses --resume instead.
      def resume_argv(session_ref)
        argv = command_argv
        argv += ["--resume", session_id_value(session_ref)]
        argv += session_settings_argv(session_ref.fetch("session_settings", {}) || {})
        argv + extra_args
      end

      def transcript_path(cwd:, session_id:)
        return nil unless present?(session_id)

        expected = File.join(claude_home, "projects", project_directory_name(cwd), "#{session_id}.jsonl") if present?(cwd)
        return expected if expected && File.file?(expected)

        # A session id is unique across projects, so finding the file by id is exact. This is the
        # fallback for a session recorded under a directory name Meringue did not derive - a
        # workspace that moved, or a future change to how Claude Code names project directories.
        discovered = Dir.glob(File.join(claude_home, "projects", "*", "#{session_id}.jsonl")).find { |path| File.file?(path) }
        discovered || expected
      end

      def prepare_workspace!(cwd)
        ClaudeWorkspaceTrust.trust!(cwd, claude_home: workspace_trust_home)
      end

      # Ready means the prompt box is accepting input. The trust modal is answered here rather than
      # pre-empted only by the config flag, because a concurrent Claude Code write to that shared
      # config can drop the flag between recording it and starting the process.
      def wait_until_ready(process)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ready_timeout
        loop do
          return false unless process.alive?
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          if trust_prompt_visible?(process)
            answer_trust_prompt(process)
            next
          end

          quiet = process.wait_for_quiet(quiet_for: READY_QUIET_SECONDS, timeout: 10)
          next unless quiet
          next if trust_prompt_visible?(process)

          return true if prompt_box_visible?(process)
        end
      end

      def interrupt(process)
        process.write(INTERRUPT_KEY)
      end

      # Claude Code's prompt box supports bracketed paste, so a whole multi-line prompt arrives as
      # one submission. Submitting is a separate keystroke after the paste has been drawn, because
      # sending both together can be read as a newline inside the paste.
      def submit_prompt(process, text)
        process.write("\e[200~#{text}\e[201~")
        process.wait_for_quiet(quiet_for: 0.25, timeout: 15)
        process.write("\r")
      end

      def process_environment(cwd)
        environment = super
        INHERITED_SESSION_ENV.each { |key| environment[key] = nil }
        # Claude Code disables transcript persistence when it believes it is a nested session.
        # Meringue's entire read path is that transcript, so persistence is required, not optional.
        environment["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
        environment["CLAUDE_CONFIG_DIR"] = claude_home unless claude_home == DEFAULT_CLAUDE_HOME
        environment
      end

      private

      def workspace_trust_home
        claude_home == DEFAULT_CLAUDE_HOME ? nil : claude_home
      end

      def session_settings_argv(session_settings)
        settings = session_settings || {}
        model = settings["model"] || settings[:model]
        effort = settings["thinking_level"] || settings[:thinking_level]
        argv = []
        argv += ["--model", ModelReference.bare_id(model)] if present?(model)
        argv += ["--effort", effort.to_s] if present?(effort)
        argv
      end

      def trust_prompt_visible?(process)
        process.plain_screen_text.to_s.match?(TRUST_PROMPT_PATTERN)
      end

      # The modal's first option is "Yes, I trust this folder" and it is preselected, so Enter is
      # the answer. The flag is recorded again afterwards so the next session in this workspace
      # does not have to see the modal at all.
      def answer_trust_prompt(process)
        process.write("\r")
        process.wait_for_screen(timeout: TRUST_ANSWER_TIMEOUT) { |text| !text.match?(TRUST_PROMPT_PATTERN) }
      end

      # The prompt box is the input hint Claude Code draws under its banner. Matching the frame
      # marker rather than any particular wording keeps this from breaking on copy changes.
      def prompt_box_visible?(process)
        text = process.plain_screen_text.to_s
        return false if text.strip.empty?

        text.include?("❯") || text.match?(/bypass permissions|accept edits|plan mode|shift\+tab/i)
      end

      # Claude Code names a project directory by replacing every non-alphanumeric character in the
      # resolved workspace path with a dash. Getting this wrong is silent: the session runs fine and
      # Meringue simply reads an empty transcript, so it must match exactly rather than
      # approximately.
      def project_directory_name(cwd)
        ClaudeWorkspaceTrust.canonical_path(cwd).gsub(/[^a-zA-Z0-9]/, "-")
      end

      def session_id_value(session_ref)
        (session_ref["session_id"] || session_ref[:session_id]).to_s
      end
    end
  end
end
