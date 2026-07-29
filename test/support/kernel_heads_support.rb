# frozen_string_literal: true

require "test_helper"

# Shared seams and helpers for the kernel head/question integration tests.
#
# Everything here is hermetic: no real Pi/harness processes, no network, no git
# subprocesses, and every byte of state lives under a per-test Dir.mktmpdir.
module KernelHeadsSupport
  # Returns a caller-supplied HeadResult instead of routing heuristics, and records
  # what the kernel handed to the head. Has no #spawn_head_session, so the kernel
  # treats the head session as unavailable and runs the head synchronously.
  class StubHeadRunner < Meringue::Heads::Runner
    attr_reader :calls
    attr_accessor :head_result

    def initialize(head_result: nil)
      @head_result = head_result || KernelHeadsSupport.empty_head_result
      @calls = []
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      @calls << {
        "user_message" => user_message,
        "snapshot" => snapshot,
        "context" => context,
        "question_id" => question_id
      }
      @head_result.is_a?(Proc) ? @head_result.call(user_message, snapshot) : @head_result
    end
  end

  # Head runner that owns a fake head session for the head's lifetime, exercising the
  # spawn_head_session/await_head_result/close_head_session seam without a real harness.
  class SessionHeadRunner < StubHeadRunner
    attr_reader :spawned_sessions, :closed_sessions

    def initialize(head_result: nil)
      super(head_result: head_result)
      @spawned_sessions = []
      @closed_sessions = []
    end

    def spawn_head_session(user_message:, snapshot:, question_id: nil, context: nil)
      session_ref = {
        "harness" => "fake",
        "pid" => nil,
        "cwd" => context&.cwd,
        "session_id" => "fake-head-session-#{@spawned_sessions.length + 1}",
        "session_file" => nil,
        "is_streaming" => false,
        "metadata" => { "user_message" => user_message, "question_id" => question_id }
      }
      @spawned_sessions << session_ref
      session_ref
    end

    def await_head_result(session_ref)
      @calls << { "await" => session_ref.fetch("session_id") }
      @head_result
    end

    def close_head_session(session_ref)
      @closed_sessions << session_ref
      true
    end
  end

  # Blocks the first worker spawn so a second kernel instance can try to apply the
  # same head batch while the first one still holds the apply lease.
  class GatedHarnessClient < Meringue::Harness::FakeClient
    def initialize(entered:, release:)
      @entered = entered
      @release = release
      @gated = true
      super()
    end

    def spawn_session(**kwargs)
      if @gated
        @gated = false
        @entered << true
        @release.pop
      end
      super(**kwargs)
    end
  end

  # Removes the head record mid-batch, the way another kernel instance does when it
  # finishes and cleans up the same head while this instance is still applying commands.
  class HeadKillingHarnessClient < Meringue::Harness::FakeClient
    attr_accessor :engine, :head_id

    def spawn_session(**kwargs)
      if head_id && engine
        engine.apply("type" => "Kill", "payload" => { "target_id" => head_id })
        self.head_id = nil
      end
      super(**kwargs)
    end
  end

  # Makes worker provisioning fail the way an unavailable harness backend does.
  class FailingSpawnHarnessClient < Meringue::Harness::FakeClient
    def spawn_session(**_kwargs)
      raise "fake harness refused to spawn a session"
    end
  end

  # Never touches git; every worker gets the project root as its workspace.
  class StubWorkspaceManager
    attr_reader :released

    def initialize
      @released = []
    end

    def plan_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil)
      {
        "strategy" => "project_root",
        "project_root" => File.expand_path(project_root),
        "workspace_path" => File.expand_path(project_root),
        "workspace_branch" => nil,
        "created" => false,
        "fallback_reason" => "test stub workspace manager"
      }
    end

    def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil)
      plan_worker_workspace(
        project_root: project_root,
        project_id: project_id,
        issue_id: issue_id,
        agent_id: agent_id,
        task_title: task_title
      ).merge("errors" => [])
    end

    def release_worker_workspace(workspace, delete_branch: false)
      @released << { "workspace" => workspace, "delete_branch" => delete_branch }
      false
    end
  end

  # Guarantees the kernel never shells out to `gh` during tests.
  class StubForgeClient
    def pull_request_urls_for_branch(repository:, branch:)
      []
    end

    def pull_request_status(url)
      { "provider" => "github", "url" => url.to_s, "state" => "unknown" }
    end
  end

  module_function

  def empty_head_result(title: "Stub head", summary: "Stub head made no proposals.")
    {
      "title" => title,
      "summary" => summary,
      "commands" => [],
      "questions" => []
    }
  end
end

# Base class for the kernel head/question integration tests. Each test gets a fresh
# temp root, state file, config file, and engine.
class KernelHeadsTestCase < Minitest::Test
  include KernelHeadsSupport

  attr_reader :temp_root, :state_path, :config_path, :project_path, :engine, :head_runner, :harness_client

  def setup
    @temp_root = Dir.mktmpdir("meringue-kernel-heads-")
    @state_path = File.join(@temp_root, "state.json")
    @config_path = File.join(@temp_root, "config.toml")
    @project_path = File.join(@temp_root, "demo-project")
    FileUtils.mkdir_p(@project_path)
    File.write(File.join(@project_path, "README.md"), "# kernel heads integration tests\n")
    @head_runner = KernelHeadsSupport::StubHeadRunner.new
    @harness_client = Meringue::Harness::FakeClient.new
    @engine = build_engine(head_runner: @head_runner, harness_client: @harness_client)
  end

  def teardown
    FileUtils.remove_entry(@temp_root) if @temp_root && Dir.exist?(@temp_root)
  end

  def build_engine(head_runner: nil, harness_client: nil, state_path: nil, cwd: nil, async_heads: false)
    Meringue::Kernel::Engine.new(
      store: Meringue::State::Store.new(path: state_path || @state_path),
      harness_client: harness_client || Meringue::Harness::FakeClient.new,
      head_runner: head_runner || KernelHeadsSupport::StubHeadRunner.new,
      workspace_manager: KernelHeadsSupport::StubWorkspaceManager.new,
      cwd: cwd || @project_path,
      async_heads: async_heads,
      forge_client: KernelHeadsSupport::StubForgeClient.new,
      config_path: @config_path
    )
  end

  # --- command helpers ---------------------------------------------------------

  def apply_command(type, payload = {}, target_engine: nil)
    (target_engine || engine).apply("type" => type, "payload" => payload)
  end

  def add_project!(path: nil, name: "demo-project", target_engine: nil)
    result = apply_command("AddProject", { "path" => path || project_path, "name" => name }, target_engine: target_engine)
    raise "AddProject was not accepted: #{result.inspect}" unless result.fetch("status") == "accepted"

    result.fetch("target_id")
  end

  def spawn_head!(message, question_id: nil, target_engine: nil)
    payload = { "user_message" => message }
    payload["question_id"] = question_id if question_id
    result = apply_command("SpawnHead", payload, target_engine: target_engine)
    raise "SpawnHead was not accepted: #{result.inspect}" unless result.fetch("status") == "accepted"

    result.fetch("target_id")
  end

  def apply_head_result(head_id, head_result, cleanup_head: true, target_engine: nil)
    apply_command(
      "ApplyHeadResult",
      {
        "head_id" => head_id,
        "head_result" => head_result,
        "_cleanup_head" => cleanup_head
      },
      target_engine: target_engine
    )
  end

  def head_result(commands: [], questions: [], title: "Route the request", summary: "Routing summary.")
    {
      "title" => title,
      "summary" => summary,
      "commands" => commands,
      "questions" => questions
    }
  end

  def create_issue_command(project_id:, title:, description: nil, command_id: nil)
    command = {
      "type" => "CreateIssue",
      "payload" => {
        "project_id" => project_id,
        "title" => title,
        "description" => description || "#{title} description",
        "parent_issue_id" => nil
      }
    }
    command_id ? command.merge("command_id" => command_id) : command
  end

  def spawn_worker_command(issue_id:, title: "Worker task", prompt: "Investigate and report.", command_id: nil, extra: {})
    command = {
      "type" => "SpawnWorker",
      "payload" => { "issue_id" => issue_id, "title" => title, "prompt" => prompt }.merge(extra)
    }
    command_id ? command.merge("command_id" => command_id) : command
  end

  def ask_question_command(head_id:, question:, context: "", project_id: nil, issue_id: nil)
    {
      "type" => "AskQuestion",
      "payload" => {
        "head_id" => head_id,
        "question" => question,
        "context" => context,
        "project_id" => project_id,
        "issue_id" => issue_id
      }.compact
    }
  end

  # --- state helpers -----------------------------------------------------------

  def state
    engine.list_all
  end

  def agents(type: nil, current_state: nil)
    (current_state || state).fetch("agents").select { |agent| type.nil? || agent.fetch("type", nil) == type }
  end

  def find_agent_record(agent_id, current_state: nil)
    (current_state || state).fetch("agents").find { |agent| agent.fetch("id", nil) == agent_id }
  end

  def issues(current_state: nil)
    (current_state || state).fetch("issues")
  end

  def questions(current_state: nil)
    (current_state || state).fetch("questions")
  end

  def questions_for_head(head_id, current_state: nil)
    questions(current_state: current_state).select { |question| question.fetch("head_id", nil) == head_id }
  end

  def logs(current_state: nil)
    (current_state || state).fetch("logs")
  end

  def logs_matching(current_state: nil, &block)
    logs(current_state: current_state).select(&block)
  end

  def log_messages(current_state: nil)
    logs(current_state: current_state).map { |entry| entry.fetch("message", "") }
  end

  def command_results(apply_result)
    Array(apply_result.dig("result", "command_results"))
  end

  def command_statuses(apply_result)
    command_results(apply_result).map { |result| [result.fetch("command_type", nil), result.fetch("status", nil)] }
  end

  # Rewrites the persisted state file directly. Used to simulate crashes and other
  # kernel instances, which is the only way to reach the recovery/lease branches
  # without spawning real processes.
  def rewrite_state!
    raw = JSON.parse(File.read(state_path))
    yield raw
    File.write(state_path, JSON.pretty_generate(raw) + "\n")
    raw
  end

  def utc_now_iso8601
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
