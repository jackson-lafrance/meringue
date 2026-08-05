# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# Helpers shared by the input slice tests (test/integration/input/**).
#
# Everything here is hermetic: state, config, and project directories live in a
# Dir.mktmpdir sandbox, head agents are stubbed plain Ruby objects, and the
# harness is Meringue's in-repo fake client. No Pi/Claude/Antigravity process is
# ever started, no network call is made, and the real ~/.meringue directory is
# never read or written.
module InputSupport
  # Stands in for a head agent. Returns pre-canned HeadResult hashes and records
  # every call so tests can assert what the kernel handed to the head, including
  # the question_id and the assembled head context.
  class StubHeadRunner
    DEFAULT_RESULT = {
      "title" => "Stub head",
      "summary" => "Stub head proposed no commands.",
      "commands" => [],
      "questions" => []
    }.freeze

    attr_reader :calls

    def initialize(results = [])
      @results = Array(results).dup
      @calls = []
    end

    def enqueue(result)
      @results << result
      self
    end

    # Queue a transport-style failure so a test can produce a head that stopped without routing,
    # which is the state a retry recovers from.
    def enqueue_failure(message)
      @results << RuntimeError.new(message)
      self
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      @calls << {
        "user_message" => user_message,
        "question_id" => question_id,
        "context" => context,
        "context_prompt" => context.respond_to?(:to_prompt_h) ? context.to_prompt_h : nil,
        "snapshot" => snapshot
      }
      queued = @results.shift
      raise queued if queued.is_a?(Exception)

      queued || deep_dup(DEFAULT_RESULT)
    end

    private

    def deep_dup(value)
      JSON.parse(JSON.generate(value))
    end
  end

  # One tmp Meringue installation: state file, config file, project directory,
  # kernel engine, and the input router/prompt loop wired together.
  class Sandbox
    attr_reader :dir, :project_path, :state_path, :config_path, :store, :engine,
                :prompt_loop, :head_runner, :router

    def initialize(dir)
      @dir = dir
      @project_path = File.join(dir, "proj")
      FileUtils.mkdir_p(@project_path)
      @state_path = File.join(dir, "state.json")
      @config_path = File.join(dir, "config.toml")
      @store = Meringue::State::Store.new(path: @state_path)
      @head_runner = StubHeadRunner.new
      @router = Meringue::Input::Router.new
      @engine = Meringue::Kernel::Engine.new(
        store: @store,
        harness_client: Meringue::Harness::FakeClient.new,
        head_runner: @head_runner,
        workspace_manager: Meringue::Workspace::Manager.new,
        cwd: @project_path,
        async_heads: false,
        config_path: @config_path
      )
      @prompt_loop = Meringue::Heads::PromptLoop.new(engine: @engine, wait_for_workers: false)
    end

    # Sends one line of user input through the real input router + kernel path.
    def submit(text)
      prompt_loop.call(text)
    end

    def apply(type, payload = {})
      engine.apply("type" => type, "payload" => payload)
    end

    def state
      store.load
    end

    def questions
      state.fetch("questions")
    end

    def question(id)
      questions.find { |question| question.fetch("id") == id }
    end

    def open_questions
      questions.select { |question| question.fetch("status") == "open" }
    end

    def agents
      state.fetch("agents")
    end

    def head_result(title: "Stub head", summary: "Stub head result.", commands: [], questions: [])
      {
        "title" => title,
        "summary" => summary,
        "commands" => commands,
        "questions" => questions
      }
    end

    def command_results(payload)
      Array(payload["command_results"]) +
        Array(payload.dig("apply_head_result", "result", "command_results"))
    end

    def command_result_pairs(payload)
      command_results(payload).map { |result| [result.fetch("command_type"), result.fetch("status")] }
    end
  end

  # Yields a fresh Sandbox rooted in a tmpdir and removes it afterwards.
  def input_sandbox
    Dir.mktmpdir("meringue-input-test") do |dir|
      yield Sandbox.new(dir)
    end
  end

  # The TUI colorscheme is process-global. Any test that touches /theme or the
  # CLI theme configuration restores the previous scheme so sibling tests in the
  # same `rake test` process are unaffected.
  def with_preserved_tui_style
    previous = Meringue::TUI::Style.current_colorscheme
    yield
  ensure
    Meringue::TUI::Style.configure!(previous)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Runs the CLI with captured IO and no terminal attached.
  def run_cli(argv, stdin: StringIO.new(""))
    out = StringIO.new
    err = StringIO.new
    status = Meringue::CLI.new(argv, input: stdin, out: out, err: err).run
    { "status" => status, "out" => out.string, "err" => err.string }
  end

  def parse_cli_runtime_options(argv, default_state_path: "/default/state.json")
    cli = Meringue::CLI.new(argv, out: StringIO.new, err: StringIO.new)
    options = cli.send(:parse_runtime_options, default_state_path: default_state_path)
    { "options" => options, "overrides" => options && cli.send(:config_overrides, options) }
  end

  def write_config(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def slash_parser
    Meringue::Input::SlashCommandParser.new
  end

  def parse_slash(input)
    slash_parser.parse(input).to_h
  end

  # Models a harness would report, in the shape the kernel persists after asking
  # it for its catalog. Deliberately unsorted so ordering assertions are real.
  SAMPLE_CATALOG_MODELS = [
    { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol",
      "thinking_levels" => %w[off low medium high xhigh max], "reasoning" => true, "context_window" => 400_000 },
    { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5",
      "thinking_levels" => %w[off minimal low medium high xhigh max], "reasoning" => true, "context_window" => 1_000_000 },
    { "provider" => "anthropic-flex", "id" => "claude-opus-5", "name" => "Claude Opus 5",
      "thinking_levels" => %w[xhigh max], "reasoning" => true, "context_window" => 1_000_000 },
    { "provider" => "google", "id" => "gemini-3-flash", "name" => "Gemini 3 Flash",
      "thinking_levels" => ["off"], "reasoning" => false, "context_window" => 1_048_576 }
  ].freeze

  def model_catalog_snapshot(harness: "pi", models: nil, source: "test_catalog")
    Meringue::Harness::ModelCatalog.available(
      harness: harness,
      models: models || SAMPLE_CATALOG_MODELS,
      source: source
    ).to_h
  end

  # sample_state plus the metadata the kernel maintains for session settings:
  # the active harness, saved future-session defaults, and per-harness catalogs.
  def sample_state_with_model_catalog(harness: "pi", catalogs: nil, current_model: "anthropic/claude-opus-5",
                                      default_model: "anthropic-flex/claude-opus-5")
    state = sample_state
    state.fetch("agents").first.merge!(
      "harness" => harness,
      "harness_session_id" => "session-1",
      "session_settings" => {
        "model" => { "provider" => current_model.split("/").first, "id" => current_model.split("/").last, "reference" => current_model },
        "thinking_level" => "max",
        "availability" => "available"
      }
    )
    state["metadata"] = {
      "active_harness" => harness,
      "pi_session_defaults" => { "model" => default_model, "thinking_level" => "xhigh" },
      "harness_model_catalogs" => catalogs || { harness => model_catalog_snapshot(harness: harness) }
    }
    state
  end

  def sample_state
    {
      "projects" => [{ "id" => "P1", "name" => "proj", "status" => "working" }],
      "issues" => [{ "id" => "P1-I1", "title" => "Fix login", "status" => "queued" }],
      "agents" => [
        { "id" => "P1-I1-W1", "type" => "worker", "status" => "working", "issue_id" => "P1-I1" },
        { "id" => "H1", "type" => "head", "status" => "completed" }
      ],
      "questions" => [
        { "id" => "Q1", "status" => "open", "question" => "Which environment should I target?" },
        { "id" => "Q2", "status" => "answered", "question" => "Already answered question" }
      ]
    }
  end
end
