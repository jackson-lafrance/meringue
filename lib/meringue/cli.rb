# frozen_string_literal: true

require "json"
require "optparse"

module Meringue
  class CLI
    FULL_DEMO_STATE_PATH = File.expand_path(ENV.fetch("MERINGUE_DEMO_STATE_PATH", "~/.meringue/devpost-demo-state.json"))
    FULL_DEMO_STATE_FIXTURE_PATH = Meringue.root_path("fixtures", "devpost_demo_state.json")
    DEMO_PROJECT_ROOT_PLACEHOLDER = "__MERINGUE_DEMO_PROJECT_ROOT__"

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
      when "devpost-demo-state"
        out.puts JSON.pretty_generate(devpost_demo_state)
        0
      when "reset-state"
        reset_state
      when "reset-demo-state"
        reset_demo_state
      when "head-loop"
        run_head_loop
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
      options = parse_runtime_options(default_state_path: default_state_path)
      return 1 unless options

      prepare_demo_state!(options) if options.fetch(:demo_state, false)

      config = runtime_config(options)
      return 1 unless config

      configure_tui_style(config)

      registry = Harness::Registry.new(config: config)
      store = state_store(path: options.fetch(:state_path))
      engine = enable_agents ? tui_engine(store, registry, config_path: options.fetch(:config_path)) : nil
      App.new(
        input: input,
        out: out,
        err: err,
        state_path: options.fetch(:state_path),
        state_store: store,
        tui_app: TUI::App.new(input: input, out: out, session_opener: registry.terminal_session_opener),
        prompt_handler: engine ? Heads::PromptLoop.new(engine: engine, wait_for_workers: false) : nil,
        reconciler: engine ? -> { engine.reconcile_sessions } : nil
      ).run
    rescue ArgumentError => e
      err.puts e.message
      1
    end

    def parse_runtime_options(default_state_path:)
      options = {
        state_path: default_state_path,
        config_path: Config::DEFAULT_PATH,
        harness: nil,
        head_harness: nil,
        worker_harness: nil,
        demo_state: false,
        reset_demo_state: false,
        state_path_overridden: false
      }
      parser = OptionParser.new do |option_parser|
        option_parser.on("--state PATH", "Read Meringue state from PATH.") do |path|
          options[:state_path] = path
          options[:state_path_overridden] = true
        end
        option_parser.on("--config PATH", "Read Meringue harness config TOML from PATH. Defaults to #{Config::DEFAULT_PATH}.") do |path|
          options[:config_path] = path
        end
        option_parser.on("--harness NAME", "Use one harness provider for heads and workers: pi, claude/claude_code, or antigravity.") do |name|
          options[:harness] = name
        end
        option_parser.on("--head-harness NAME", "Use a specific head harness provider: pi, claude/claude_code, or antigravity.") do |name|
          options[:head_harness] = name
        end
        option_parser.on("--worker-harness NAME", "Use a specific worker harness provider: pi, claude/claude_code, or antigravity.") do |name|
          options[:worker_harness] = name
        end
        option_parser.on("--demo-state", "Run the full TUI against the resettable Devpost demo state at #{FULL_DEMO_STATE_PATH}.") do
          options[:demo_state] = true
        end
        option_parser.on("--reset-demo-state", "Reset the Devpost demo state from its fixture before opening the full TUI. Implies --demo-state.") do
          options[:demo_state] = true
          options[:reset_demo_state] = true
        end
      end

      parser.parse!(argv)
      options[:state_path] = FULL_DEMO_STATE_PATH if options[:demo_state] && !options[:state_path_overridden]
      if argv.any?
        err.puts "Unexpected argument(s): #{argv.join(" ")}"
        return nil
      end

      options
    rescue OptionParser::ParseError => e
      err.puts e.message
      nil
    end

    def run_head_loop
      options = parse_runtime_options(default_state_path: State::Store.default_path)
      return 1 unless options

      config = runtime_config(options)
      return 1 unless config

      registry = Harness::Registry.new(config: config)
      Heads::SimpleLoop.new(
        initial_state: State::Models.empty_state,
        store: state_store(path: options.fetch(:state_path)),
        out: out,
        err: err,
        runner: registry.head_runner(cwd: Dir.pwd),
        runner_name: registry.head_provider,
        harness_client: registry.worker_client,
        wait_for_workers: true
      ).run
    rescue ArgumentError => e
      err.puts e.message
      1
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

    def reset_state
      state_store.save(State::Models.empty_state, preserve_conversation: false)
      out.puts "Reset Meringue state at #{state_store.path}"
      0
    end

    def reset_demo_state
      reset_demo_state_file!(path: FULL_DEMO_STATE_PATH)
      out.puts "Reset Meringue Devpost demo state at #{FULL_DEMO_STATE_PATH}"
      0
    end

    def prepare_demo_state!(options)
      path = File.expand_path(options.fetch(:state_path))
      return if File.exist?(path) && !options.fetch(:reset_demo_state, false)

      reset_demo_state_file!(path: path)
    end

    def reset_demo_state_file!(path:)
      State::Store.new(path: path).save(devpost_demo_state, preserve_conversation: false)
    end

    def devpost_demo_state
      replace_demo_state_placeholders(
        JSON.parse(File.read(FULL_DEMO_STATE_FIXTURE_PATH)),
        demo_project_root
      )
    end

    def replace_demo_state_placeholders(value, project_root)
      case value
      when Hash
        value.transform_values { |child| replace_demo_state_placeholders(child, project_root) }
      when Array
        value.map { |child| replace_demo_state_placeholders(child, project_root) }
      when String
        value.gsub(DEMO_PROJECT_ROOT_PLACEHOLDER, project_root)
      else
        value
      end
    end

    def demo_project_root
      nearest_git_root(Dir.pwd) || File.expand_path(Dir.pwd)
    end

    def nearest_git_root(path)
      current = File.expand_path(path.to_s)

      loop do
        return current if File.exist?(File.join(current, ".git"))

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    def state_store(path: State::Store.default_path)
      @state_stores ||= {}
      @state_stores[File.expand_path(path)] ||= State::Store.new(path: path)
    end

    def tui_engine(store, registry, config_path: Config::DEFAULT_PATH)
      Kernel::Engine.new(
        store: store,
        harness_client: registry.worker_client,
        head_runner: registry.head_runner(cwd: Dir.pwd),
        harness_client_resolver: ->(agent) { registry.client_for_agent(agent) },
        harness_client_provider: ->(provider) { registry.worker_client_for(provider: provider) },
        head_runner_provider: ->(provider) { registry.head_runner_for(provider: provider, cwd: Dir.pwd) },
        default_harness_provider: registry.worker_provider,
        workspace_manager: Workspace::Manager.new,
        cwd: Dir.pwd,
        async_heads: true,
        config_path: config_path
      )
    end

    def runtime_config(options)
      Config.load(path: options.fetch(:config_path)).with_overrides(config_overrides(options))
    rescue Config::ParseError => e
      err.puts e.message
      nil
    end

    def config_overrides(options)
      harness = {}
      harness["provider"] = options[:harness] if options[:harness]
      harness["head_provider"] = options[:head_harness] if options[:head_harness]
      harness["worker_provider"] = options[:worker_harness] if options[:worker_harness]
      harness.empty? ? {} : { "harness" => harness }
    end

    def configure_tui_style(config)
      TUI::Style.configure!(configured_colorscheme(config))
    end

    def configured_colorscheme(config)
      config.value("tui", "colorscheme") ||
        config.value("tui", "color_scheme") ||
        TUI::Style::DEFAULT_COLORSCHEME
    end

    def demo_state
      State::Store.new(path: Meringue.root_path("fixtures", "demo_state.json")).load
    end

    def print_help
      out.puts <<~HELP
        Meringue #{VERSION}

        Usage:
          meringue                               # open the TUI and route chat prompts through configured head agents
          meringue tui                           # open the TUI and route chat prompts through configured head agents
          meringue tui --state PATH              # open the TUI against a specific Meringue state JSON file
          meringue tui --demo-state              # open the full agent-enabled TUI against the resettable Devpost demo state
          meringue tui --reset-demo-state        # reset the Devpost demo state, then open the full agent-enabled TUI
          meringue tui --config PATH             # open the TUI with a specific harness/config TOML file
          meringue tui --harness claude          # use Claude Code for both heads and workers
          meringue tui --head-harness antigravity --worker-harness claude
          meringue demo                          # display the fake demo state fixture without agent prompting
          meringue demo-state                    # print the fake demo state fixture
          meringue devpost-demo-state            # print the full agent-enabled Devpost demo state after path templating
          meringue reset-state                   # reset ~/.meringue/state.json to an empty Meringue state
          meringue reset-demo-state              # reset ~/.meringue/devpost-demo-state.json without opening the TUI
          meringue head-loop [--harness NAME]    # run the manual configured head -> kernel -> worker loop
          meringue fake-head-loop                # run the manual fake head -> kernel -> worker loop
          meringue --version                     # print the app version
          meringue --help                        # print this help

        Config:
          Default path: #{Config::DEFAULT_PATH}
          Supported harness providers: pi, claude (aliases: claude_code, claude-code, cc), antigravity
          Supported TUI colorschemes: #{TUI::Style.colorschemes.join(", ")}
          CLI flags override config.toml, and MERINGUE_HARNESS / MERINGUE_HEAD_HARNESS / MERINGUE_WORKER_HARNESS override both.
          Full demo state path: #{FULL_DEMO_STATE_PATH} (override with MERINGUE_DEMO_STATE_PATH or --state PATH with --demo-state).

        TUI controls:
          Enter                     # send chat; when agent tree is focused, enter jump mode
          /                         # show slash command suggestions in an otherwise empty prompt
          /help                     # list command syntax
          /quit                     # quit the TUI
          /theme <name>             # set and persist the TUI theme
          /harness <pi|claude|antigravity> # select the harness backend for future agents
          /keybind                  # show all TUI keybindings
          /jump [agent_id]          # open an agent session in Alacritty; omit id to navigate the AgentTree
          /jumpr [agent_id]         # open an agent PR; omit id to navigate only agents with open PRs
          p in jump mode            # open selected agent PR when one is available; otherwise do nothing
          Ctrl-C on an empty prompt # quit the TUI; Esc cancels jump/PR navigation only
      HELP
    end
  end
end
