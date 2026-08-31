# frozen_string_literal: true

require "open3"

# Shared scaffolding for the end-to-end suite.
#
# Everything here is hermetic: no real harness processes, no network, no GitHub, no TTY.
# Each test gets its own tmpdir containing a throwaway git repository (the "managed project"),
# a Meringue state file, and a workspace root for git worktrees. ~/.meringue and this
# repository's own git state are never touched.
module E2eSupport
  # Raised by the fake harness client when a session reference no longer maps to a live
  # session, which is what the kernel sees after a restart or a crashed harness process.
  class SessionGoneError < StandardError; end

  # A scripted head runner. Each queued script receives the real head invocation
  # (user message, state snapshot, and Heads::Context) and returns a HeadResult.
  class ScriptedHeadRunner < Meringue::Heads::Runner
    attr_reader :calls

    def initialize
      @scripts = []
      @calls = []
    end

    def script(&block)
      @scripts << block
      self
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      call = {
        "user_message" => user_message,
        "snapshot" => snapshot,
        "context" => context,
        "question_id" => question_id
      }
      @calls << call
      raise "ScriptedHeadRunner has no scripted HeadResult for #{user_message.inspect}" if @scripts.empty?

      E2eSupport.head_result(@scripts.shift.call(call))
    end

  end

  # An in-memory harness client. It behaves like a real client from the kernel's point of
  # view (spawn/prompt/poll/attach/kill session refs) without starting any process.
  class FakeHarnessClient < Meringue::Harness::Client
    HARNESS_NAME = "e2e"

    def initialize
      @mutex = Mutex.new
      @sessions = {}
      @counter = 0
    end

    def harness_name
      HARNESS_NAME
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, workspace_mode: "isolated")
      @mutex.synchronize do
        @counter += 1
        session_id = "e2e-#{kind}-#{@counter}"
        @sessions[session_id] = {
          "id" => session_id,
          "kind" => kind.to_s,
          "cwd" => cwd,
          "spawn_prompt" => prompt.to_s,
          "system_prompt" => system_prompt.to_s,
          "session_name" => session_name.to_s,
          "live" => true,
          "attachable" => true,
          "streaming" => true,
          "killed" => false,
          "assistant_text" => nil,
          "events" => [],
          "prompts" => []
        }
        session_ref(session_id)
      end
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      session_id = session_id_from(session_ref)
      @mutex.synchronize do
        session = @sessions[session_id]
        raise SessionGoneError, "no e2e session #{session_id}" unless session

        session.fetch("prompts") << { "prompt" => prompt.to_s, "mode" => mode.to_s }
        session["live"] = true
        session["streaming"] = true
        session_ref(session_id)
      end
    end

    def abort_session(session_ref)
      session_id = session_id_from(session_ref)
      @mutex.synchronize do
        session = @sessions[session_id]
        raise SessionGoneError, "no e2e session #{session_id}" unless session

        session["streaming"] = false
        session_ref(session_id)
      end
    end

    def kill_session(session_ref)
      session_id = session_id_from(session_ref)
      @mutex.synchronize do
        session = @sessions[session_id]
        return session_ref.merge("killed" => true, "is_streaming" => false) unless session

        session["killed"] = true
        session["live"] = false
        session["attachable"] = false
        session["streaming"] = false
        session_ref(session_id).merge("killed" => true)
      end
    end

    def get_state(session_ref)
      session_id = session_id_from(session_ref)
      @mutex.synchronize do
        session = @sessions[session_id]
        raise SessionGoneError, "no live e2e session for #{session_id}" unless session && session.fetch("live", false)

        session_ref(session_id)
      end
    end

    def attach_session(session_ref)
      session_id = session_id_from(session_ref)
      @mutex.synchronize do
        session = @sessions[session_id]
        raise SessionGoneError, "e2e session #{session_id} cannot be attached" unless session && session.fetch("attachable", false)

        session["live"] = true
        session_ref(session_id)
      end
    end

    def read_events(session_ref)
      session_id = session_id_from(session_ref)
      @mutex.synchronize { Array(@sessions.dig(session_id, "events")).map(&:dup) }
    end

    def last_assistant_text(session_ref)
      session_id = session_id_from(session_ref)
      @mutex.synchronize { @sessions.dig(session_id, "assistant_text") }
    end

    # Test controls.

    # Settles a session the way a harness does when its turn finishes.
    def finish!(session_id, assistant_text: nil)
      @mutex.synchronize do
        session = @sessions.fetch(session_id)
        session["streaming"] = false
        session["assistant_text"] = assistant_text || "Finished #{session.fetch("session_name")}."
      end
      self
    end

    # Registers a session that survived a restart: polling it fails until the kernel
    # re-attaches, which is how a resumable harness session looks to a fresh kernel.
    def register_resumable_session(session_id, kind: "worker")
      @mutex.synchronize do
        @sessions[session_id] = {
          "id" => session_id,
          "kind" => kind.to_s,
          "cwd" => nil,
          "spawn_prompt" => nil,
          "system_prompt" => nil,
          "session_name" => session_id,
          "live" => false,
          "attachable" => true,
          "streaming" => false,
          "killed" => false,
          "assistant_text" => nil,
          "events" => [],
          "prompts" => []
        }
      end
      self
    end

    def session(session_id)
      @mutex.synchronize { deep_copy(@sessions[session_id]) }
    end

    def sessions
      @mutex.synchronize { deep_copy(@sessions) }
    end

    def session_ids
      @mutex.synchronize { @sessions.keys.dup }
    end

    def prompts_for(session_id)
      Array(session(session_id)&.fetch("prompts", []))
    end

    def worker_session_cwds
      sessions.values.select { |session| session.fetch("kind") == "worker" }.map { |session| session.fetch("cwd") }
    end

    private

    def session_ref(session_id)
      session = @sessions.fetch(session_id)
      {
        "harness" => HARNESS_NAME,
        "pid" => nil,
        "cwd" => session.fetch("cwd"),
        "session_id" => session_id,
        "session_file" => nil,
        "is_streaming" => session.fetch("streaming"),
        "last_event_at" => nil,
        "metadata" => {
          "session_name" => session.fetch("session_name"),
          "session_kind" => session.fetch("kind")
        }
      }
    end

    def session_id_from(session_ref)
      return session_ref.to_s unless session_ref.is_a?(Hash)

      (session_ref["session_id"] || session_ref[:session_id]).to_s
    end

    def deep_copy(value)
      value.nil? ? nil : JSON.parse(JSON.generate(value))
    end
  end

  # A forge client that never touches the network. Nothing in the e2e suite publishes
  # pull requests, so every lookup is empty/unknown.
  class StubForgeClient
    def pull_request_urls_for_branch(repository:, branch:)
      []
    end

    def pull_request_status(url)
      { "provider" => "github", "url" => url.to_s, "state" => "unknown" }
    end
  end

  def self.head_result(raw)
    result = raw || {}
    {
      "title" => result.fetch("title", "Scripted head decision"),
      "summary" => result.fetch("summary", "Scripted head routing decision."),
      "commands" => Array(result["commands"]),
      "questions" => Array(result["questions"])
    }
  end

  def self.add_project_command(path, name)
    { "type" => "AddProject", "payload" => { "path" => path.to_s, "name" => name.to_s } }
  end

  def self.create_issue_command(project_id:, title:, description: "")
    {
      "type" => "CreateIssue",
      "payload" => { "project_id" => project_id, "title" => title, "description" => description }
    }
  end

  def self.spawn_worker_command(issue_id:, title:, prompt:)
    {
      "type" => "SpawnWorker",
      "payload" => { "issue_id" => issue_id, "title" => title, "prompt" => prompt }
    }
  end

  def self.prompt_agent_command(agent_id:, prompt:, mode: "normal")
    {
      "type" => "PromptAgent",
      "payload" => { "agent_id" => agent_id, "prompt" => prompt, "mode" => mode }
    }
  end

  def self.answer_question_command(question_id:, answer:)
    { "type" => "AnswerQuestion", "payload" => { "question_id" => question_id, "answer" => answer } }
  end

  # Instance helpers mixed into the e2e test cases.

  def setup_e2e
    @e2e_root = Dir.mktmpdir("meringue-e2e")
    @project_root = File.join(@e2e_root, "demo-project")
    @state_path = File.join(@e2e_root, "state", "state.json")
    @workspaces_root = File.join(@e2e_root, "workspaces")
    @config_path = File.join(@e2e_root, "config.toml")
    init_project_repo(@project_root)
    @head_runner = ScriptedHeadRunner.new
    @harness_client = FakeHarnessClient.new
  end

  def teardown_e2e
    FileUtils.remove_entry(@e2e_root) if @e2e_root && Dir.exist?(@e2e_root)
  end

  attr_reader :project_root, :state_path, :workspaces_root

  def head_runner
    @head_runner
  end

  def harness_client
    @harness_client
  end

  def new_store
    Meringue::State::Store.new(path: state_path)
  end

  def build_engine(store: new_store, head_runner: self.head_runner, harness_client: self.harness_client)
    Meringue::Kernel::Engine.new(
      store: store,
      harness_client: harness_client,
      head_runner: head_runner,
      harness_client_resolver: ->(_agent) { harness_client },
      default_harness_provider: "fake",
      workspace_manager: Meringue::Workspace::Manager.new(root_path: workspaces_root, command_timeout: 30),
      cwd: project_root,
      async_heads: false,
      forge_client: StubForgeClient.new,
      config_path: @config_path
    )
  end

  def build_prompt_loop(engine, wait_for_workers: false)
    Meringue::Heads::PromptLoop.new(engine: engine, wait_for_workers: wait_for_workers, worker_wait_timeout: 5)
  end

  # State read back from disk with a brand new store, i.e. what a fresh Meringue process sees.
  def reloaded_state
    new_store.load
  end

  def raw_persisted_state
    JSON.parse(File.read(state_path))
  end

  def agent_tree_text(state = reloaded_state)
    Meringue::TUI::Panes::AgentTreePane.new.render(state, width: 100)
  end

  def log_messages(state = reloaded_state)
    state.fetch("logs").map { |log| log.fetch("message") }
  end

  def assert_logged(pattern, state = reloaded_state)
    messages = log_messages(state)
    assert(messages.any? { |message| message.match?(pattern) },
           "expected a log entry matching #{pattern.inspect}, got:\n#{messages.join("\n")}")
  end

  def refute_logged(pattern, state = reloaded_state)
    messages = log_messages(state)
    refute(messages.any? { |message| message.match?(pattern) },
           "expected no log entry matching #{pattern.inspect}, got:\n#{messages.join("\n")}")
  end

  def agent(state, agent_id)
    state.fetch("agents").find { |candidate| candidate.fetch("id") == agent_id }
  end

  def issue(state, issue_id)
    state.fetch("issues").find { |candidate| candidate.fetch("id") == issue_id }
  end

  def workers(state)
    state.fetch("agents").select { |candidate| candidate.fetch("type") == "worker" }
  end

  def question(state, question_id)
    state.fetch("questions").find { |candidate| candidate.fetch("id") == question_id }
  end

  def current_branch(path)
    git("rev-parse", "--abbrev-ref", "HEAD", dir: path).strip
  end

  def git(*argv, dir:)
    stdout, stderr, status = Open3.capture3("git", "-C", dir.to_s, *argv)
    raise "git #{argv.join(" ")} failed in #{dir}: #{stderr}" unless status.success?

    stdout
  end

  def init_project_repo(path)
    FileUtils.mkdir_p(path)
    run_git!(path, "init", "--quiet", "--initial-branch=main")
    run_git!(path, "config", "user.email", "e2e@example.com")
    run_git!(path, "config", "user.name", "Meringue E2E")
    run_git!(path, "config", "commit.gpgsign", "false")
    File.write(File.join(path, "README.md"), "# demo project\n")
    run_git!(path, "add", ".")
    run_git!(path, "commit", "--quiet", "--no-verify", "-m", "initial commit")
    # Registration requires isolation evidence, and the built-in backend reads it from a
    # GitHub origin. The URL is never contacted.
    run_git!(path, "remote", "add", "origin", "git@github.com:example/demo-project.git")
    path
  end

  def run_git!(dir, *argv)
    _stdout, stderr, status = Open3.capture3("git", "-C", dir.to_s, *argv)
    raise "git #{argv.join(" ")} failed in #{dir}: #{stderr}" unless status.success?

    true
  end
end
