# frozen_string_literal: true

require "optparse"

module Meringue
  class CLI
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

      config = runtime_config(options)
      return 1 unless config

      configure_tui_style(config)
      keybindings = configured_keybindings(config)

      registry = Harness::Registry.new(config: config)
      store = state_store(path: options.fetch(:state_path))
      engine = enable_agents ? tui_engine(store, registry, config: config, config_path: options.fetch(:config_path)) : nil
      agent_session_service = engine ? Sessions::WorkerSessionService.new(engine: engine) : nil
      workspace_controller = Workspace::Controller.from_config(config, focus_session_service: agent_session_service)
      prompt_loop = engine ? Heads::PromptLoop.new(engine: engine, wait_for_workers: false) : nil
      App.new(
        input: input,
        out: out,
        err: err,
        state_path: options.fetch(:state_path),
        state_store: store,
        tui_app: TUI::App.new(
          input: input,
          out: out,
          session_opener: registry.terminal_session_opener,
          workspace_controller: workspace_controller,
          agent_session_service: agent_session_service,
          log_store: store,
          keybindings: keybindings,
          config: config,
          # First-run setup applies every choice through a kernel command, so it
          # is only offered when there is a kernel behind the UI. `meringue demo`
          # has none and must never open it.
          onboarding_enabled: enable_agents
        ),
        prompt_handler: prompt_loop,
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
        worker_harness: nil
      }
      parser = OptionParser.new do |option_parser|
        option_parser.on("--state PATH", "Read Meringue state from PATH.") do |path|
          options[:state_path] = path
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
      state_store.save(State::Models.empty_state, preserve_log_buffer: false)
      out.puts "Reset Meringue state at #{state_store.path}"
      0
    end

    def state_store(path: State::Store.default_path)
      @state_stores ||= {}
      @state_stores[File.expand_path(path)] ||= State::Store.new(path: path)
    end

    def tui_engine(store, registry, config: nil, config_path: Config::DEFAULT_PATH)
      Kernel::Engine.new(
        store: store,
        harness_client: registry.worker_client,
        head_runner: registry.head_runner(cwd: Dir.pwd),
        harness_client_resolver: ->(agent) { registry.client_for_agent(agent) },
        harness_client_provider: ->(provider) { registry.worker_client_for(provider: provider) },
        head_runner_provider: ->(provider) { registry.head_runner_for(provider: provider, cwd: Dir.pwd) },
        default_harness_provider: registry.worker_provider,
        session_defaults_provider: ->(provider) { registry.session_defaults(provider: provider) },
        session_defaults_updater: lambda do |provider, model: nil, thinking_level: nil|
          registry.update_session_defaults!(provider: provider, model: model, thinking_level: thinking_level)
        end,
        model_catalog_provider: ->(provider) { registry.model_catalog(provider: provider, cwd: Dir.pwd) },
        # Timeouts for worker provisioning are configurable under `[workspace]`, because how long
        # a `git worktree add` may take is a property of the repository and the disk.
        workspace_manager: config ? Workspace::Manager.from_config(config) : Workspace::Manager.new,
        cwd: Dir.pwd,
        async_heads: true,
        async_worker_provisioning: true,
        config_path: config_path,
        config: config
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

    def configured_keybindings(config)
      TUI::Keybindings.from_config(config.section("tui", "keybindings"))
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
          meringue tui --config PATH             # open the TUI with a specific harness/config TOML file
          meringue tui --harness claude          # use Claude Code for both heads and workers
          meringue tui --head-harness antigravity --worker-harness claude
          meringue demo                          # display the fake demo state fixture without agent prompting
          meringue demo-state                    # print the fake demo state fixture
          meringue reset-state                   # reset ~/.meringue/state.json to an empty Meringue state
          meringue head-loop [--harness NAME]    # run the manual configured head -> kernel -> worker loop
          meringue fake-head-loop                # run the manual fake head -> kernel -> worker loop
          meringue --version                     # print the app version
          meringue --help                        # print this help

        Config:
          Default path: #{Config::DEFAULT_PATH}
          Supported harness providers: pi, claude (aliases: claude_code, claude-code, cc), antigravity
          Supported TUI colorschemes: #{TUI::Style.colorschemes.join(", ")}
          TUI keybindings can be customized under [tui.keybindings]; omitted actions keep defaults.
          CLI flags override config.toml, and MERINGUE_HARNESS / MERINGUE_HEAD_HARNESS / MERINGUE_WORKER_HARNESS override both.

        TUI controls:
          Enter                     # send chat; when agent tree/logs is focused, enter jump mode
          /                         # show slash command suggestions in an otherwise empty prompt
          /help                     # list command syntax
          /quit                     # quit the TUI
          /theme <name>             # set and persist the TUI theme
          /harness <pi|claude|antigravity> # select the harness backend for future agents
          /models [harness]         # open the searchable model picker; Enter sets the default model, Ctrl-R refreshes
          /keybind                  # show all TUI keybindings
          /config                   # show active config, supported defaults, conflict policy, and keybindings
          /jump [agent_id]          # open a focused workspace; omit id to navigate the AgentTree
          /recount                  # compact AgentTree numbering after records are removed
          Ctrl-B                    # open the selected issue's verified delivery PR; with nothing selected, pick from the open PRs
          Enter in jump mode        # open selected issue/agent PR when one is available
          a in jump mode            # open the selected agent's focused workspace
          AgentTree single-click    # focus logs; issue/worker selections also target chat through a fresh head
          click the selected row    # clear the log/chat target (empty AgentTree space also clears it)
          issue/worker double-click # open that worker's optional focused workspace; unavailable rows stay quiet
          Ctrl-Space, then T / F    # switch terminal/agent view / cycle transcript filter
          Ctrl-Space, then A        # open the worker's underlying agent session externally
          Ctrl-Space, then B / P    # open the workspace editor / verified delivery PR
          Ctrl-Space, then Q        # only focused-workspace quit; keep worker and terminal alive
          / in a focused workspace  # workspace commands: /help /terminal /filter /session /editor /pr /cwd /cancel /quit
          logs double-click         # select the word under the pointer and copy it; drag from it to extend by word
          Alt-V with logs focused   # toggle keyboard logs selection; Shift+arrows also start it
          Ctrl-C with a selection   # copy the selection to the system clipboard
          Ctrl-C on an empty prompt # quit the TUI; Esc clears a selection, then the AgentTree log filter and jump mode
      HELP
    end
  end
end
