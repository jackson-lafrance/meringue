# frozen_string_literal: true

require "fileutils"

module Meringue
  class CLI
    PI_HEAD_SESSION_DIR = File.expand_path("~/.meringue/pi-head-sessions")
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
      Heads::SimpleLoop.new(
        initial_state: demo_state,
        out: out,
        err: err,
        runner: pi_head_runner,
        runner_name: "pi"
      ).run
    end

    def run_fake_head_loop
      Heads::SimpleLoop.new(
        initial_state: demo_state,
        out: out,
        err: err,
        runner: Heads::FakeRunner.new,
        runner_name: "fake"
      ).run
    end

    def pi_head_runner
      FileUtils.mkdir_p(PI_HEAD_SESSION_DIR)
      Heads::PiRunner.new(
        harness_client: Harness::PiClient.new(
          session_dir: PI_HEAD_SESSION_DIR,
          extra_args: PI_HEAD_EXTRA_ARGS
        ),
        cwd: Dir.pwd
      )
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
          meringue head-loop        # run the manual real Pi head-agent loop
          meringue fake-head-loop   # run the manual fake head-agent loop
          meringue --version        # print the app version
          meringue --help           # print this help

        TUI controls:
          q, Esc, or Ctrl-C         # quit the rendering demo
      HELP
    end
  end
end
