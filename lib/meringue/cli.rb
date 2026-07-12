# frozen_string_literal: true

require "fileutils"

module Meringue
  class CLI
    PI_SESSION_DIR = File.expand_path(ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
    # Heads need local read-only discovery so they can identify nearby git repositories
    # before proposing AddProject/CreateIssue commands. Keep write/edit tools disabled;
    # bash is included only for read-only commands such as git rev-parse and git remote -v.
    PI_HEAD_EXTRA_ARGS = [
      "--thinking", "minimal",
      "--tools", "read,bash,grep,find,ls",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-context-files",
      "--no-approve"
    ].freeze
    # Workers are the only agents that should edit project files. Keep Pi-specific
    # tool configuration here so the kernel and TUI stay harness-agnostic.
    PI_WORKER_EXTRA_ARGS = [
      "--thinking", "minimal",
      "--tools", "read,bash,grep,find,ls,edit,write",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-context-files",
      "--no-approve"
    ].freeze

    def initialize(argv, input: $stdin, out: $stdout, err: $stderr)
      @argv = argv.dup
      @input = input
      @out = out
      @err = err
    end

    def run
      case argv.first
      when nil, "tui", "demo"
        App.new(input: input, out: out, err: err).run
      when "-v", "--version", "version"
        out.puts VERSION
        0
      when "-h", "--help", "help"
        print_help
        0
      when "demo-state"
        out.puts File.read(Meringue.root_path("fixtures", "demo_state.json"))
        0
      when "reset-state"
        reset_state
      when "head-loop"
        run_pi_head_loop
      when "fake-head-loop"
        run_fake_head_loop
      else
        err.puts "Unknown command: #{argv.first}"
        print_help
        1
      end
    end

    private

    attr_reader :argv, :input, :out, :err

    def run_pi_head_loop
      head_client = pi_harness_client(extra_args: PI_HEAD_EXTRA_ARGS)
      worker_client = pi_harness_client(extra_args: PI_WORKER_EXTRA_ARGS)
      Heads::SimpleLoop.new(
        initial_state: State::Models.empty_state,
        store: state_store,
        out: out,
        err: err,
        runner: Heads::PiRunner.new(harness_client: head_client, cwd: Dir.pwd),
        runner_name: "pi",
        harness_client: worker_client,
        wait_for_workers: true
      ).run
    end

    def run_fake_head_loop
      Heads::SimpleLoop.new(
        initial_state: demo_state,
        out: out,
        err: err,
        runner: Heads::FakeRunner.new,
        runner_name: "fake",
        harness_client: Harness::FakeClient.new
      ).run
    end

    def pi_harness_client(extra_args:)
      FileUtils.mkdir_p(PI_SESSION_DIR)
      Harness::PiClient.new(
        session_dir: PI_SESSION_DIR,
        extra_args: extra_args
      )
    end

    def reset_state
      state_store.save(State::Models.empty_state)
      out.puts "Reset Meringue state at #{state_store.path}"
      0
    end

    def state_store
      @state_store ||= State::Store.new
    end

    def demo_state
      State::Store.new(path: Meringue.root_path("fixtures", "demo_state.json")).load
    end

    def print_help
      out.puts <<~HELP
        Meringue #{VERSION}

        Usage:
          meringue                  # run the fake-state TUI demo
          meringue tui              # run the fake-state TUI demo
          meringue demo             # run the fake-state TUI demo
          meringue demo-state       # print the fake demo state fixture
          meringue reset-state      # reset ~/.meringue/state.json to an empty Meringue state
          meringue head-loop        # run the manual real Pi head -> kernel -> worker loop
          meringue fake-head-loop   # run the manual fake head -> kernel -> worker loop
          meringue --version        # print the app version
          meringue --help           # print this help

        TUI controls:
          q, Esc, or Ctrl-C         # quit the rendering demo
      HELP
    end
  end
end
