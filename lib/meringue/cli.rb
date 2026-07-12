# frozen_string_literal: true

require "fileutils"
require "optparse"

module Meringue
  class CLI
    PI_SESSION_DIR = File.expand_path(ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
    # Heads need local read-only discovery so they can identify nearby git repositories
    # before proposing AddProject/CreateIssue commands. Keep write/edit tools disabled;
    # bash is included only for read-only commands such as git rev-parse and git remote -v.
    PI_HEAD_EXTRA_ARGS = [
      "--thinking", "high",
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
      "--thinking", "high",
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
      command = argv.shift

      case command
      when nil, "tui"
        run_tui(default_state_path: State::Store::DEFAULT_PATH, enable_agents: true)
      when "demo"
        run_tui(default_state_path: App::DEMO_STATE_PATH, enable_agents: false)
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
        err.puts "Unknown command: #{command}"
        print_help
        1
      end
    end

    private

    attr_reader :argv, :input, :out, :err

    def run_tui(default_state_path:, enable_agents:)
      options = parse_tui_options(default_state_path: default_state_path)
      return 1 unless options

      store = state_store(path: options.fetch(:state_path))
      App.new(
        input: input,
        out: out,
        err: err,
        state_path: options.fetch(:state_path),
        state_store: store,
        prompt_handler: enable_agents ? tui_prompt_handler(store) : nil
      ).run
    end

    def parse_tui_options(default_state_path:)
      options = { state_path: default_state_path }
      parser = OptionParser.new do |option_parser|
        option_parser.on("--state PATH", "Read Meringue state from PATH.") do |path|
          options[:state_path] = path
        end
      end

      parser.parse!(argv)
      if argv.any?
        err.puts "Unexpected argument(s): #{argv.join(" ")}"
        return nil
      end

      options
    rescue OptionParser::ParseError => e
      err.puts e.message
      nil
    end

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

    def state_store(path: State::Store.default_path)
      @state_stores ||= {}
      @state_stores[File.expand_path(path)] ||= State::Store.new(path: path)
    end

    def tui_prompt_handler(store)
      head_client = pi_harness_client(extra_args: PI_HEAD_EXTRA_ARGS)
      worker_client = pi_harness_client(extra_args: PI_WORKER_EXTRA_ARGS)
      engine = Kernel::Engine.new(
        store: store,
        harness_client: worker_client,
        head_runner: Heads::PiRunner.new(harness_client: head_client, cwd: Dir.pwd),
        workspace_manager: Workspace::Manager.new,
        cwd: Dir.pwd
      )
      Heads::PromptLoop.new(engine: engine, wait_for_workers: true)
    end

    def demo_state
      State::Store.new(path: Meringue.root_path("fixtures", "demo_state.json")).load
    end

    def print_help
      out.puts <<~HELP
        Meringue #{VERSION}

        Usage:
          meringue                  # open the TUI and route chat prompts through real Pi head agents
          meringue tui              # open the TUI and route chat prompts through real Pi head agents
          meringue tui --state PATH # open the TUI against a specific Meringue state JSON file
          meringue demo             # display the fake demo state fixture without agent prompting
          meringue demo-state       # print the fake demo state fixture
          meringue reset-state      # reset ~/.meringue/state.json to an empty Meringue state
          meringue head-loop        # run the manual real Pi head -> kernel -> worker loop
          meringue fake-head-loop   # run the manual fake head -> kernel -> worker loop
          meringue --version        # print the app version
          meringue --help           # print this help

        TUI controls:
          Enter                     # send the chat prompt to a head agent
          /clear                    # reset the persisted Meringue state
          Esc on an empty prompt or Ctrl-C # quit the TUI
      HELP
    end
  end
end
