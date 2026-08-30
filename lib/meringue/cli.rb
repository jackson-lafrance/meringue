# frozen_string_literal: true

require "optparse"

module Meringue
  class CLI
    def initialize(argv, input: $stdin, out: $stdout, err: $stderr)
      @original_argv = argv.dup
      @argv = argv.dup
      @input = input
      @out = out
      @err = err
    end

    def run
      command = argv.shift

      case command
      when nil, "tui"
        # The env-aware reader, not the bare constant: every other subcommand
        # resolves the state path through it, and the dashboard reading a
        # different file than `meringue workers` or `meringue doctor` is how
        # MERINGUE_STATE_PATH silently did nothing here.
        run_tui(default_state_path: State::Store.default_path)
      when "-v", "--version", "version"
        out.puts VERSION
        0
      when "-h", "--help", "help"
        print_help
        0
      when "doctor"
        run_doctor
      when "reset-state"
        reset_state
      when "workers", "worker"
        run_workers
      when "head-loop"
        run_head_loop
      else
        err.puts "Unknown command: #{command}"
        print_help
        1
      end
    end

    private

    attr_reader :argv, :input, :out, :err

    # Everything the quick start used to ask the reader to verify by hand, with
    # the fix printed next to each failure instead of in a troubleshooting
    # section they have to go and find.
    def run_doctor
      options = parse_runtime_options(default_state_path: State::Store.default_path)
      return 1 unless options

      config = runtime_config(options)
      return 1 unless config

      doctor = Doctor.new(
        config: config,
        config_path: options.fetch(:config_path),
        state_path: options.fetch(:state_path),
        registry: Harness::Registry.new(config: config)
      )
      checks = doctor.checks
      out.puts "Meringue #{VERSION}"
      out.puts
      checks.each { |check| print_check(check) }
      out.puts
      problems = checks.count(&:problem?)
      if problems.zero?
        out.puts "Everything Meringue needs is in place."
        0
      else
        out.puts "#{problems} problem#{problems == 1 ? "" : "s"} to fix before Meringue can run properly."
        1
      end
    end

    DOCTOR_MARKERS = { Doctor::OK => "ok", Doctor::PROBLEM => "FAIL", Doctor::NOTE => "note" }.freeze

    def print_check(check)
      out.puts "  [#{DOCTOR_MARKERS.fetch(check.status, "?").rjust(4)}] #{check.title}"
      out.puts "         #{check.detail}" if check.detail.to_s != ""
      out.puts "         → #{check.fix}" if check.fix.to_s != ""
    end

    def run_workers
      action = argv.shift.to_s.downcase
      case action
      when "export"
        run_worker_export
      when "import"
        run_worker_import
      else
        err.puts "Usage: meringue workers export <bundle_path> [worker_id...]"
        err.puts "       meringue workers import <bundle_path> --project <path> [--state PATH] [--config PATH]"
        1
      end
    rescue ArgumentError => e
      err.puts e.message
      1
    end

    def run_worker_export
      options = { state_path: State::Store.default_path }
      parser = OptionParser.new do |option_parser|
        option_parser.on("--state PATH", "Read Meringue state from PATH.") { |path| options[:state_path] = path }
      end
      parser.parse!(argv)
      bundle_path = argv.shift
      raise ArgumentError, "Usage: meringue workers export <bundle_path> [worker_id...]" if bundle_path.to_s.strip.empty?

      bundle = Workers::Bundle.export(state_store(path: options.fetch(:state_path)).load, worker_ids: argv)
      destination = Workers::Bundle.write(bundle_path, bundle)
      out.puts "Exported #{bundle.fetch("workers").length} worker(s) to #{destination}."
      out.puts "Harness sessions were not included; import starts fresh sessions on the destination computer."
      0
    rescue OptionParser::ParseError => e
      err.puts e.message
      1
    end

    def run_worker_import
      options = {
        state_path: State::Store.default_path,
        config_path: Config::DEFAULT_PATH,
        harness: nil,
        project_path: nil
      }
      parser = OptionParser.new do |option_parser|
        option_parser.on("--state PATH", "Read Meringue state from PATH.") { |path| options[:state_path] = path }
        option_parser.on("--config PATH", "Read Meringue harness config TOML from PATH.") { |path| options[:config_path] = path }
        option_parser.on("--harness NAME", "Use this worker harness provider.") { |name| options[:harness] = name }
        option_parser.on("--project PATH", "Destination project directory (required).") { |path| options[:project_path] = path }
      end
      parser.parse!(argv)
      bundle_path = argv.shift
      raise ArgumentError, "Usage: meringue workers import <bundle_path> --project <path>" if bundle_path.to_s.strip.empty? || argv.any?
      raise ArgumentError, "--project PATH is required when importing workers." if options[:project_path].to_s.strip.empty?

      runtime_options = {
        state_path: options.fetch(:state_path),
        config_path: options.fetch(:config_path),
        harness: options[:harness],
        head_harness: nil,
        worker_harness: options[:harness]
      }
      config = runtime_config(runtime_options)
      return 1 unless config

      registry = Harness::Registry.new(config: config)
      store = state_store(path: options.fetch(:state_path))
      engine = tui_engine(store, registry, config: config, config_path: options.fetch(:config_path))
      bundle = Workers::Bundle.read(bundle_path)
      result = engine.apply(
        "type" => "ImportWorkers",
        "payload" => {
          "bundle" => bundle,
          "project_path" => options.fetch(:project_path)
        }
      )
      engine.wait_for_worker_provisioning if result.fetch("status", nil) == "accepted"
      out.puts result.fetch("message", "Worker import finished.")
      result.fetch("status", nil) == "accepted" ? 0 : 1
    rescue OptionParser::ParseError => e
      err.puts e.message
      1
    end

    def run_tui(default_state_path:)
      options = parse_runtime_options(default_state_path: default_state_path)
      return 1 unless options

      config = runtime_config(options)
      return 1 unless config

      configure_tui_style(config)
      keybindings = configured_keybindings(config)

      registry = Harness::Registry.new(config: config)
      lifecycle = Lifecycle::Manager.new(arguments: @original_argv)
      store = state_store(path: options.fetch(:state_path))
      engine = tui_engine(store, registry, config: config, config_path: options.fetch(:config_path))
      agent_session_service = engine ? Sessions::WorkerSessionService.new(engine: engine) : nil
      workspace_controller = Workspace::Controller.from_config(
        config,
        focus_session_service: agent_session_service,
        session_environment_patterns: Harness::Registry.managed_session_environment_patterns
      )
      prompt_loop = Heads::PromptLoop.new(engine: engine, wait_for_workers: false)
      result = App.new(
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
          lifecycle: lifecycle,
          # First-run setup saves its Settings draft through the kernel, so it is
          onboarding_enabled: true,
          # A registry-backed check lets the TUI force setup open and gate chat
          # when no role harness is configured yet, instead of exiting at startup.
          harness_configured_check: -> { registry.provider_configured?("worker") || registry.provider_configured?("head") },
          # Setup asks the machine which backends it can actually run. Locating is
          # cheap enough for a render path; probing starts the harness and is only
          # reached from the check the user activates.
          harness_availability_provider: -> { registry.provider_availability },
          harness_probe: ->(provider) { registry.probe_provider(provider) }
        ),
        prompt_handler: prompt_loop,
        reconciler: -> { engine.reconcile_sessions }
      ).run
      return 0 unless result == :reload

      reload_result = lifecycle.reload
      return 0 unless reload_result.is_a?(Hash) && reload_result.fetch("status", nil) == "failed"

      err.puts reload_result.fetch("message", "Meringue could not reload.")
      1
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
        option_parser.on("--harness NAME", "Use one harness provider for heads and workers: pi, claude/claude_code, or codex.") do |name|
          options[:harness] = name
        end
        option_parser.on("--head-harness NAME", "Use a specific head harness provider: pi, claude/claude_code, or codex.") do |name|
          options[:head_harness] = name
        end
        option_parser.on("--worker-harness NAME", "Use a specific worker harness provider: pi, claude/claude_code, or codex.") do |name|
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

    # `--state PATH` used to be dropped here, so `meringue reset-state --state ./scratch.json`
    # silently wiped the *default* state file instead of the one that was named.
    def reset_state
      options = parse_runtime_options(default_state_path: State::Store.default_path)
      return 1 unless options

      store = state_store(path: options.fetch(:state_path))
      store.save(State::Models.empty_state, preserve_log_buffer: false)
      out.puts "Reset Meringue state at #{store.path}"
      0
    end

    def state_store(path: State::Store.default_path)
      @state_stores ||= {}
      @state_stores[File.expand_path(path)] ||= State::Store.new(path: path)
    end

    def tui_engine(store, registry, config: nil, config_path: Config::DEFAULT_PATH)
      # The engine may be built before any harness is chosen. Pass nil clients
      # and defaults then; the provider lambdas resolve a real backend lazily
      # once setup persists a harness and reconciliation reads it from state.
      worker_configured = registry.provider_configured?("worker")
      head_configured = registry.provider_configured?("head")
      Kernel::Engine.new(
        store: store,
        harness_client: worker_configured ? registry.worker_client : nil,
        head_runner: head_configured ? registry.head_runner(cwd: Dir.pwd) : nil,
        harness_client_resolver: ->(agent) { registry.client_for_agent(agent) },
        harness_client_provider: ->(provider) { registry.worker_client_for(provider: provider) },
        head_runner_provider: ->(provider) { registry.head_runner_for(provider: provider, cwd: Dir.pwd) },
        default_harness_provider: worker_configured ? registry.worker_provider : nil,
        default_head_harness_provider: head_configured ? registry.head_provider : nil,
        default_worker_harness_provider: worker_configured ? registry.worker_provider : nil,
        session_defaults_provider: ->(provider) { registry.session_defaults(provider: provider) },
        session_defaults_updater: lambda do |provider, model: nil, model_role: nil, thinking_level: nil, thinking_role: nil|
          registry.update_session_defaults!(
            provider: provider,
            model: model,
            model_role: model_role,
            thinking_level: thinking_level,
            thinking_role: thinking_role
          )
        end,
        model_catalog_provider: ->(provider) { registry.model_catalog(provider: provider, cwd: Dir.pwd) },
        runtime_config_updater: ->(updated_config, changed_ids: []) { registry.reload_config!(updated_config, changed_ids: changed_ids) },
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
      Config.migrate_settings!(
        path: options.fetch(:config_path),
        state_path: options.fetch(:state_path)
      ).with_overrides(config_overrides(options), source: "cli")
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

    # Rendered from the parser's own command table rather than a second hand-written list. The
    # CLI help used to name 17 of the 47 slash commands, so `/answer`, `/goal`, `/prune`,
    # `/retry`, and the rest were discoverable only from inside a running dashboard - and a
    # command added to the parser never reached this text at all.
    SLASH_COMMAND_HELP_COLUMN = 46

    def slash_command_help
      Kernel::Engine.grouped_help_commands(Input::SlashCommandParser::COMMAND_SPECS).flat_map do |group, entries|
        ["", "  #{group}"] + entries.map do |usage, description|
          "    #{usage.ljust(SLASH_COMMAND_HELP_COLUMN)} # #{first_sentence(description)}"
        end
      end.drop(1).join("\n")
    end

    # One line per command: the help is an inventory, and `/help` inside the dashboard carries
    # the full description for any command the reader wants to know more about.
    def first_sentence(description)
      text = description.to_s.strip
      sentence = text[/\A.*?[.!?](?:\s|\z)/m] || text
      sentence.strip.delete_suffix(".")
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
          meringue tui --harness codex           # use Codex CLI for both heads and workers
          meringue tui --head-harness claude --worker-harness codex
          meringue doctor                        # check Ruby, git, the configured harness, config, and state
          meringue reset-state                   # reset ~/.meringue/state.json to an empty Meringue state
          meringue workers export <PATH> [IDS]   # export current workers without machine-specific sessions or paths
          meringue workers import <PATH> --project <PATH> # import workers as fresh destination sessions
          meringue head-loop [--harness NAME]    # run the manual configured head -> kernel -> worker loop
          meringue --version                     # print the app version
          meringue --help                        # print this help

        Config:
          Default path: #{Config::DEFAULT_PATH}
          Supported harness providers: pi, claude (aliases: claude_code, claude-code, cc), codex (alias: codex-cli)
          Supported TUI colorschemes: #{TUI::Style.colorschemes.join(", ")}
          TUI keybindings can be customized under [tui.keybindings]; omitted actions keep defaults.
          CLI flags override config.toml, and MERINGUE_HARNESS / MERINGUE_HEAD_HARNESS / MERINGUE_WORKER_HARNESS override both.

        Slash commands (run these in the dashboard; /help repeats them there):
        #{slash_command_help}

        TUI controls:
          Enter                     # send chat; when agent tree/logs is focused, enter jump mode
          /                         # show slash command suggestions in an otherwise empty prompt
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
