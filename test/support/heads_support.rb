# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"

# Shared fixtures and doubles for the head-agent slice of the suite.
#
# Everything here is hermetic: temporary directories only, no network, no real
# harness processes, and no reads or writes under ~/.meringue.
module HeadsSupport
  # A head runner double. It records every call and returns scripted HeadResults,
  # raises a scripted error, or defers to a block so a test can observe kernel
  # state at the exact moment a head is "thinking".
  class ScriptedHeadRunner < Meringue::Heads::Runner
    attr_reader :calls

    def initialize(results: [], error: nil, &block)
      @results = Array(results)
      @error = error
      @block = block
      @calls = []
      @mutex = Mutex.new
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      call = {
        "user_message" => user_message,
        "snapshot" => snapshot,
        "context" => context,
        "question_id" => question_id
      }
      @mutex.synchronize { @calls << call }
      raise @error if @error
      return @block.call(call) if @block

      @mutex.synchronize { @results.length > 1 ? @results.shift : @results.first }
    end
  end

  # A head runner that owns a harness "session" the way HarnessRunner does, so the
  # kernel's session-tracking path is exercised without a real harness.
  class ScriptedSessionHeadRunner < ScriptedHeadRunner
    attr_reader :spawned_sessions, :closed_sessions

    def initialize(results: [], error: nil, await_error: nil, &block)
      super(results: results, error: error, &block)
      @await_error = await_error
      @spawned_sessions = []
      @closed_sessions = []
    end

    def spawn_head_session(user_message:, snapshot:, context: nil, question_id: nil)
      session_ref = {
        "harness" => "fake",
        "pid" => nil,
        "cwd" => context&.cwd,
        "session_id" => "fake-head-session-#{@spawned_sessions.length + 1}",
        "session_file" => nil,
        "is_streaming" => false,
        "metadata" => { "question_id" => question_id, "user_message" => user_message }
      }
      @spawned_sessions << session_ref
      session_ref
    end

    def await_head_result(session_ref)
      raise @await_error if @await_error

      run(
        user_message: session_ref.dig("metadata", "user_message"),
        snapshot: {},
        context: nil,
        question_id: session_ref.dig("metadata", "question_id")
      )
    end

    def close_head_session(session_ref)
      @closed_sessions << session_ref
      true
    end
  end

  # FakeClient plus the optional settle/transcript methods the loops probe for.
  class SettlingHarnessClient < Meringue::Harness::FakeClient
    attr_reader :waits, :assistant_text

    def initialize(assistant_text: "worker finished", events: [{ "type" => "assistant" }])
      @assistant_text = assistant_text
      @events = events
      @waits = []
    end

    def wait_for_settled(session_ref, timeout: nil)
      @waits << { "session_ref" => session_ref, "timeout" => timeout }
      @events
    end

    def last_assistant_text(_session_ref)
      @assistant_text
    end
  end

  # A harness client whose transcript is a HeadResult JSON document, used to drive
  # HarnessRunner end to end without a real harness process.
  class HeadResultHarnessClient < Meringue::Harness::FakeClient
    attr_reader :spawned, :killed, :waits

    def initialize(raw_output:)
      @raw_output = raw_output
      @spawned = []
      @killed = []
      @waits = []
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
      session_ref = super
      @spawned << {
        "kind" => kind,
        "cwd" => cwd,
        "prompt" => prompt,
        "system_prompt" => system_prompt,
        "session_name" => session_name
      }
      session_ref
    end

    def wait_for_settled(session_ref, timeout: nil)
      @waits << { "session_ref" => session_ref, "timeout" => timeout }
      []
    end

    def last_assistant_text(_session_ref)
      @raw_output
    end

    def kill_session(session_ref)
      @killed << session_ref
      super
    end
  end

  # Bundle of temp paths plus a wired kernel engine for one test.
  Environment = Struct.new(
    :root,
    :project_path,
    :state_path,
    :workspace_root,
    :store,
    :engine,
    :runner,
    :harness_client,
    :workspace_manager,
    keyword_init: true
  ) do
    def state
      store.load
    end

    def agents(type: nil)
      state.fetch("agents", []).select { |agent| type.nil? || agent.fetch("type", nil) == type }
    end

    def project_entries
      Dir.children(project_path).sort
    end
  end

  def wait_until(timeout: 10, description: "condition")
    deadline = Time.now + timeout
    loop do
      return true if yield
      flunk "timed out after #{timeout}s waiting for #{description}" if Time.now > deadline

      sleep 0.01
    end
  end

  def head_temp_root(name = "meringue-heads-test-")
    @head_temp_roots ||= []
    root = Dir.mktmpdir(name)
    @head_temp_roots << root
    root
  end

  def teardown
    Array(@head_temp_roots).each do |root|
      FileUtils.remove_entry(root) if Dir.exist?(root)
    end
    @head_temp_roots = []
    super
  end

  # Builds a hermetic project directory, state store, and kernel engine.
  def build_head_environment(runner: Meringue::Heads::FakeRunner.new,
                             harness_client: Meringue::Harness::FakeClient.new,
                             initial_state: nil,
                             git_project: true,
                             async_heads: false)
    root = head_temp_root
    project_path = File.join(root, "demo-project")
    workspace_root = File.join(root, "workspaces")
    FileUtils.mkdir_p(project_path)
    FileUtils.mkdir_p(workspace_root)
    File.write(File.join(project_path, "README.md"), "# demo project\n")
    # A bare .git marker keeps project discovery deterministic without running git.
    FileUtils.mkdir_p(File.join(project_path, ".git")) if git_project

    state_path = File.join(root, "state.json")
    store = Meringue::State::Store.new(path: state_path)
    store.save(normalized_seed_state(initial_state)) if initial_state
    workspace_manager = Meringue::Workspace::FakeManager.new(root_path: workspace_root)

    engine = Meringue::Kernel::Engine.new(
      store: store,
      harness_client: harness_client,
      head_runner: runner,
      workspace_manager: workspace_manager,
      # Fixture projects are directories, not repositories: the capability probe is
      # answered by the fake backend so these tests stay about head behaviour.
      version_control_backend: Meringue::VersionControl::FakeBackend.new(manager: workspace_manager),
      cwd: project_path,
      async_heads: async_heads,
      default_harness_provider: "fake",
      config_path: File.join(root, "config.toml")
    )

    Environment.new(
      root: root,
      project_path: project_path,
      state_path: state_path,
      workspace_root: workspace_root,
      store: store,
      engine: engine,
      runner: runner,
      harness_client: harness_client,
      workspace_manager: workspace_manager
    )
  end

  def normalized_seed_state(state)
    JSON.parse(JSON.generate(state))
  end

  def head_result(title: "Routed the request",
                  summary: "Reused the existing issue and prompted its worker.",
                  response: nil,
                  commands: [],
                  questions: [])
    {
      "title" => title,
      "summary" => summary,
      "commands" => commands,
      "questions" => questions
    }.tap { |result| result["response"] = response unless response.nil? }
  end

  def kernel_command(type, payload = {})
    { "type" => type, "payload" => payload }
  end

  # A realistic-but-small snapshot with a project, issue, worker, head, question,
  # and logs. Worker harness metadata deliberately carries transcript-ish and
  # secret-ish keys so context tests can assert they are not forwarded to heads.
  def head_snapshot(question_status: "open")
    {
      "schema_version" => 1,
      "projects" => [
        {
          "id" => "P1",
          "name" => "meringue",
          "root_path" => "/tmp/meringue-project",
          "status" => "working",
          # Registration records the backend's isolation evidence, and workers are only
          # provisioned for a project that carries it.
          "version_control_backend" => "github_git",
          "version_control_repository_identity" => "git@github.com:example/meringue.git",
          "version_control_capabilities" => { "isolated_workspaces" => true, "mutable_workspace" => true },
          "version_control_diagnostic_at" => "2024-01-01T00:00:00Z",
          "created_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-02T00:00:00Z"
        }
      ],
      "issues" => [
        {
          "id" => "P1-I1",
          "project_id" => "P1",
          "parent_issue_id" => nil,
          "title" => "Add question answering",
          "description" => "Answering an open question should drive a head.",
          "status" => "working",
          "agent_ids" => ["P1-I1-W1"],
          "delivery_pull_requests" => [{ "url" => "https://example.test/pr/1" }],
          "created_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-03T00:00:00Z"
        },
        {
          "id" => "P1-I2",
          "project_id" => "P1",
          "parent_issue_id" => nil,
          "title" => "Unrelated docs cleanup",
          "description" => "Tidy the docs directory.",
          "status" => "queued",
          "agent_ids" => [],
          "created_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-02T00:00:00Z"
        }
      ],
      "agents" => [
        {
          "id" => "P1-I1-W1",
          "type" => "worker",
          "status" => "idle",
          "project_id" => "P1",
          "issue_id" => "P1-I1",
          "harness" => "pi",
          "harness_session_id" => "pi-session-1",
          "harness_session_file" => "/tmp/pi-session-1.jsonl",
          "pid" => 4242,
          "workspace_path" => "/tmp/workspaces/w1",
          "workspace_branch" => "meringue/add-question-answering",
          "session_stats" => { "context_usage" => { "tokens" => 50_000, "capacity" => 200_000, "percent" => 0.25 } },
          "harness_metadata" => {
            "title" => "Wire AnswerQuestion into head routing",
            "prompt_count" => 2,
            "last_prompt_mode" => "follow_up",
            "prompt_modes" => %w[normal steer follow_up],
            "is_streaming" => false,
            "last_assistant_text" => "I updated the engine and added logging.",
            # Transcript-ish and secret-ish keys that must not reach the head.
            "harness_events" => [{ "type" => "assistant", "text" => "SECRET_TRANSCRIPT_LINE" }],
            "prompt" => "SECRET_WORKER_PROMPT",
            "system_prompt" => "SECRET_SYSTEM_PROMPT",
            "api_key" => "sk-SECRET-TOKEN-VALUE",
            "pi_state" => { "contextUtilization" => 0.25, "transcript" => "SECRET_PI_TRANSCRIPT" }
          },
          "created_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-03T00:00:00Z"
        },
        {
          "id" => "H7",
          "type" => "head",
          "status" => "working",
          "harness" => "fake",
          "harness_metadata" => { "user_message" => "why did the worker stall?" },
          "created_at" => "2024-01-03T00:00:00Z",
          "updated_at" => "2024-01-03T00:00:00Z"
        }
      ],
      "questions" => [
        {
          "id" => "Q4",
          "head_id" => "H7",
          "project_id" => "P1",
          "issue_id" => "P1-I1",
          "question" => "Should the worker keep the existing branch or start a new one?",
          "context" => "Two branches already exist for this issue.",
          "status" => question_status,
          "answer" => nil,
          "created_at" => "2024-01-03T00:00:00Z",
          "updated_at" => "2024-01-03T00:00:00Z"
        },
        {
          "id" => "Q5",
          "head_id" => "H7",
          "project_id" => "P1",
          "issue_id" => "P1-I2",
          "question" => "Which docs directory should be cleaned first?",
          "context" => "docs/ and website/docs both exist.",
          "status" => question_status,
          "answer" => nil,
          "created_at" => "2024-01-03T00:00:01Z",
          "updated_at" => "2024-01-03T00:00:01Z"
        }
      ],
      "logs" => [
        {
          "id" => "L1",
          "timestamp" => "2024-01-03T00:00:00Z",
          "source_type" => "kernel",
          "source_id" => "P1-I1",
          "level" => "info",
          "message" => "Created issue P1-I1: Add question answering",
          "details" => { "project_id" => "P1", "issue_id" => "P1-I1", "secret" => "SECRET_LOG_DETAIL" }
        },
        {
          "id" => "L2",
          "timestamp" => "2024-01-03T00:00:01Z",
          "source_type" => "kernel",
          "source_id" => "Q4",
          "level" => "info",
          "message" => "Question Q4: Should the worker keep the existing branch or start a new one?",
          "details" => { "head_id" => "H7", "question_id" => "Q4" }
        }
      ],
      "counters" => {
        "projects" => 1,
        "heads" => 7,
        "questions" => 5,
        "logs" => 2,
        "issues_by_project" => { "P1" => 2 },
        "workers_by_issue" => { "P1-I1" => 1 }
      },
      "metadata" => {
        "created_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-03T00:00:01Z",
        "active_harness" => "fake"
      }
    }
  end

  def build_head_context(user_message: "keep the existing branch please",
                         snapshot: nil,
                         question_id: nil,
                         cwd: nil,
                         state_path: nil)
    root = cwd || head_temp_root
    Meringue::Heads::Context.new(
      head_id: "H8",
      user_message: user_message,
      snapshot: snapshot || head_snapshot,
      question_id: question_id,
      cwd: root,
      state_path: state_path || File.join(root, "state.json")
    )
  end
end
