# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "time"

# Shared helpers for the kernel maintenance slice (Prune / Kill+ClearState /
# ReconcileSessions / Recount).
#
# Everything here is hermetic:
# - state lives in a per-test Dir.mktmpdir, never ~/.meringue
# - forge/PR lookups are stubbed, so GitHub is never contacted
# - harness sessions are stubbed in-process, so no real Pi process is spawned
module KernelMaintenanceSupport
  BASE_TIME = "2026-01-01T00:00:00Z"

  # Deterministic stand-in for Meringue::Forge::GitHubClient. Returns only what a
  # test configured, and records every lookup so tests can assert which URLs the
  # kernel actually checked.
  class StubForgeClient
    attr_reader :status_calls, :branch_calls

    def initialize(statuses: {}, branch_urls: {})
      @statuses = statuses
      @branch_urls = branch_urls
      @status_calls = []
      @branch_calls = []
    end

    def pull_request_status(url)
      @status_calls << url.to_s
      @statuses.fetch(url.to_s) do
        {
          "provider" => "github",
          "url" => url.to_s,
          "state" => "unknown",
          "merged_at" => nil,
          "error" => "stub forge client has no status for #{url}"
        }
      end
    end

    def pull_request_urls_for_branch(repository:, branch:)
      @branch_calls << { "repository" => repository.to_s, "branch" => branch.to_s }
      Array(@branch_urls.fetch([repository.to_s, branch.to_s], []))
    end
  end

  # A harness error that proves the session's process is gone, exactly the way
  # Meringue::Harness::PiClient::ProcessExitedError does. The kernel must settle a
  # worker on this evidence instead of re-prompting a process that cannot answer.
  class StubProcessGoneError < StandardError
    include Meringue::Harness::SessionProcessGoneError
  end

  # In-process harness stub. Behaviour is scripted per harness session id so one
  # reconcile pass can mix healthy, dead-pid, missing-session-file, and
  # unresumable sessions.
  class StubHarnessClient
    attr_reader :calls

    DEFAULT_SESSION = {
      "streaming" => false,
      "completed" => false,
      "events" => [],
      "last_assistant_text" => nil
    }.freeze

    def initialize(sessions: {}, harness_name: "stub")
      @sessions = sessions
      @harness_name = harness_name
      @calls = []
    end

    def harness_name
      @harness_name
    end

    def config_for(session_ref)
      key = session_ref.is_a?(Hash) ? (session_ref["session_id"] || session_ref[:session_id]).to_s : ""
      DEFAULT_SESSION.merge(@sessions.fetch(key, @sessions.fetch("default", {})))
    end

    def get_state(session_ref)
      @calls << ["get_state", session_id_of(session_ref)]
      config = config_for(session_ref)
      raise_configured_error(config, "get_state_error")
      raise_process_gone_error(config)
      raise_dead_pid_error(config, session_ref)
      raise_missing_session_file_error(config, session_ref)
      settle(session_ref, config)
    end

    def read_events(session_ref)
      @calls << ["read_events", session_id_of(session_ref)]
      Array(config_for(session_ref).fetch("events", []))
    end

    def last_assistant_text(session_ref)
      @calls << ["last_assistant_text", session_id_of(session_ref)]
      config_for(session_ref).fetch("last_assistant_text", nil)
    end

    def attach_session(session_ref)
      @calls << ["attach_session", session_id_of(session_ref)]
      config = config_for(session_ref)
      raise_configured_error(config, "attach_error")
      # An attached session reports whatever the script says it is doing now; a
      # settled session is the one the kernel is allowed to re-prompt.
      settle(session_ref, config.merge("attached" => true))
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      @calls << ["prompt_session", session_id_of(session_ref), mode]
      config = config_for(session_ref)
      raise_configured_error(config, "prompt_error")
      settle(session_ref, config.merge("streaming" => true)).merge("last_prompt" => prompt, "last_prompt_mode" => mode)
    end

    def abort_session(session_ref)
      @calls << ["abort_session", session_id_of(session_ref)]
      session_ref.merge("is_streaming" => false)
    end

    def kill_session(session_ref)
      @calls << ["kill_session", session_id_of(session_ref)]
      session_ref.merge("killed" => true, "is_streaming" => false)
    end

    # Only answered for a session the script says has exited, mirroring a real
    # client that can only report what it owned.
    def session_exit_evidence(session_ref)
      @calls << ["session_exit_evidence", session_id_of(session_ref)]
      config = config_for(session_ref)
      return nil unless config["process_gone_error"]

      {
        "pid" => session_ref.is_a?(Hash) ? (session_ref["pid"] || session_ref[:pid]) : nil,
        "exit_status" => config["exit_status"],
        "stderr_tail" => config["stderr_tail"],
        "last_event_at" => config["process_exited_at"]
      }.compact
    end

    def session_id_of(session_ref)
      session_ref.is_a?(Hash) ? (session_ref["session_id"] || session_ref[:session_id]).to_s : ""
    end

    private

    def settle(session_ref, config)
      metadata = (session_ref.is_a?(Hash) ? session_ref["metadata"] : nil) || {}
      session_ref.merge(
        "is_streaming" => !!config.fetch("streaming", false),
        "metadata" => metadata.merge("completed" => !!config.fetch("completed", false))
      )
    end

    def raise_configured_error(config, key)
      message = config[key]
      return if message.nil?

      raise RuntimeError, message.to_s
    end

    def raise_process_gone_error(config)
      message = config["process_gone_error"]
      return if message.nil?

      raise StubProcessGoneError, message.to_s
    end

    # Persisted pids can be reused or long dead. A stubbed harness reports that
    # evidence the same way a real client would: it fails to talk to the session.
    def raise_dead_pid_error(config, session_ref)
      return unless config.fetch("require_live_pid", false)

      pid = session_ref.is_a?(Hash) ? (session_ref["pid"] || session_ref[:pid]) : nil
      return if pid && Meringue::Harness::ProcessIdentity.alive?(pid)

      raise RuntimeError, "harness process #{pid.inspect} is not alive"
    end

    def raise_missing_session_file_error(config, session_ref)
      return unless config.fetch("require_session_file", false)

      path = session_ref.is_a?(Hash) ? (session_ref["session_file"] || session_ref[:session_file]) : nil
      return if path && File.exist?(path.to_s)

      raise RuntimeError, "harness session file #{path.inspect} is missing"
    end
  end

  # Same stub without session takeover support, so the kernel cannot resume it.
  class StubHarnessClientWithoutAttach < StubHarnessClient
    undef_method :attach_session
  end

  class CountingStore < Meringue::State::Store
    attr_reader :save_count

    def initialize(...)
      super
      @save_count = 0
    end

    def reset_save_count!
      @save_count = 0
    end

    private

    def save_unlocked(...)
      @save_count += 1
      super
    end
  end

  def kernel_maintenance_setup
    @kernel_maintenance_tmp = Dir.mktmpdir("meringue-kernel-maintenance")
    @kernel_maintenance_state_path = File.join(@kernel_maintenance_tmp, "state.json")
  end

  def kernel_maintenance_teardown
    FileUtils.remove_entry(@kernel_maintenance_tmp) if @kernel_maintenance_tmp && File.exist?(@kernel_maintenance_tmp)
  end

  def tmp_path(*parts)
    File.join(@kernel_maintenance_tmp, *parts)
  end

  def state_path
    @kernel_maintenance_state_path
  end

  def make_dir(*parts)
    path = tmp_path(*parts)
    FileUtils.mkdir_p(path)
    path
  end

  def build_engine(forge_client: StubForgeClient.new, harness_client: Meringue::Harness::FakeClient.new,
                   harness_client_resolver: nil, head_runner: Meringue::Heads::FakeRunner.new,
                   prune_forge_lookup_budget: Meringue::Kernel::Engine::PRUNE_FORGE_LOOKUP_BUDGET_SECONDS,
                   delivery_pull_request_refresh_budget: Meringue::Kernel::Engine::DELIVERY_PULL_REQUEST_REFRESH_BUDGET_SECONDS,
                   store: Meringue::State::Store.new(path: state_path))
    Meringue::Kernel::Engine.new(
      store: store,
      harness_client: harness_client,
      head_runner: head_runner,
      harness_client_resolver: harness_client_resolver,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces")),
      cwd: @kernel_maintenance_tmp,
      forge_client: forge_client,
      prune_forge_lookup_budget: prune_forge_lookup_budget,
      delivery_pull_request_refresh_budget: delivery_pull_request_refresh_budget,
      config_path: tmp_path("config.toml")
    )
  end

  def write_state(state)
    FileUtils.mkdir_p(File.dirname(state_path))
    File.write(state_path, JSON.pretty_generate(state) + "\n")
    state
  end

  def read_state
    JSON.parse(File.read(state_path))
  end

  def state_fixture(projects: [], issues: [], agents: [], questions: [], logs: [], counters: nil,
                    conversation: nil, metadata: nil)
    {
      "schema_version" => Meringue::State::Models::SCHEMA_VERSION,
      "projects" => projects,
      "issues" => issues,
      "agents" => agents,
      "questions" => questions,
      "logs" => logs,
      "conversation" => conversation || { "messages" => [], "next_message_id" => 0 },
      "counters" => counters || default_counters(projects: projects, issues: issues, agents: agents, questions: questions),
      "metadata" => metadata || { "created_at" => BASE_TIME, "updated_at" => BASE_TIME }
    }
  end

  def default_counters(projects:, issues:, agents:, questions:)
    {
      "projects" => numeric_suffix_max(projects, /^P(\d+)$/),
      "heads" => numeric_suffix_max(agents.select { |agent| agent["type"] == "head" }, /^H(\d+)$/),
      "questions" => numeric_suffix_max(questions, /^Q(\d+)$/),
      "logs" => 0,
      "issues_by_project" => projects.to_h do |project|
        [project.fetch("id"), issues.count { |issue| issue["project_id"] == project.fetch("id") }]
      end,
      "workers_by_issue" => issues.to_h do |issue|
        [issue.fetch("id"), agents.count { |agent| agent["type"] == "worker" && agent["issue_id"] == issue.fetch("id") }]
      end
    }
  end

  def numeric_suffix_max(records, pattern)
    Array(records).filter_map { |record| record.fetch("id", "").to_s[pattern, 1]&.to_i }.max || 0
  end

  def project_record(id:, root_path: nil, name: nil, status: "completed", created_at: BASE_TIME)
    {
      "id" => id,
      "name" => name || "Project #{id}",
      "root_path" => root_path || make_dir("projects", id),
      "status" => status,
      "created_at" => created_at,
      "updated_at" => created_at
    }
  end

  def issue_record(id:, project_id:, status: "completed", title: nil, parent_issue_id: nil, agent_ids: [],
                   created_at: BASE_TIME, extra: {})
    {
      "id" => id,
      "project_id" => project_id,
      "parent_issue_id" => parent_issue_id,
      "title" => title || "Issue #{id}",
      "description" => "Fixture issue #{id}.",
      "status" => status,
      "agent_ids" => agent_ids,
      "created_at" => created_at,
      "updated_at" => created_at
    }.merge(extra)
  end

  def worker_record(id:, issue_id:, project_id:, status: "completed", harness: "fake", pid: nil,
                    session_id: nil, session_file: nil, workspace_path: nil, harness_metadata: {},
                    created_at: BASE_TIME, extra: {})
    {
      "id" => id,
      "type" => "worker",
      "status" => status,
      "project_id" => project_id,
      "issue_id" => issue_id,
      "title" => "Worker #{id}",
      "workspace_path" => workspace_path,
      "workspace_strategy" => "git_worktree",
      "workspace_branch" => nil,
      "harness" => harness,
      "pid" => pid,
      "harness_session_id" => session_id,
      "harness_session_file" => session_file,
      "harness_metadata" => harness_metadata,
      "created_at" => created_at,
      "updated_at" => created_at
    }.merge(extra)
  end

  def head_record(id:, status: "working", harness: "fake", pid: nil, session_id: nil, session_file: nil,
                  harness_metadata: {}, created_at: BASE_TIME, extra: {})
    {
      "id" => id,
      "type" => "head",
      "status" => status,
      "project_id" => nil,
      "issue_id" => nil,
      "title" => "Head #{id}",
      "harness" => harness,
      "pid" => pid,
      "harness_session_id" => session_id,
      "harness_session_file" => session_file,
      "harness_metadata" => harness_metadata,
      "created_at" => created_at,
      "updated_at" => created_at
    }.merge(extra)
  end

  def question_record(id:, head_id: "H1", project_id: nil, issue_id: nil, status: "open", created_at: BASE_TIME)
    {
      "id" => id,
      "head_id" => head_id,
      "project_id" => project_id,
      "issue_id" => issue_id,
      "question" => "Fixture question #{id}?",
      "context" => "Fixture context for #{id}.",
      "status" => status,
      "answer" => nil,
      "created_at" => created_at,
      "updated_at" => created_at
    }
  end

  def log_record(id:, source_type: "kernel", source_id: nil, level: "info", message: "fixture log", details: {},
                 timestamp: BASE_TIME)
    {
      "id" => id,
      "timestamp" => timestamp,
      "source_type" => source_type,
      "source_id" => source_id,
      "level" => level,
      "message" => message,
      "details" => details
    }
  end

  def github_pr_status(url:, state:, is_draft: false, head_branch: nil, repository: nil, merged_at: nil)
    repository ||= url.to_s[%r{github\.com/([^/]+/[^/]+)/pull/\d+}, 1]
    {
      "provider" => "github",
      "url" => url,
      "state" => state,
      "merged_at" => merged_at,
      "raw_state" => state.to_s.upcase,
      "is_draft" => is_draft,
      "head_branch" => head_branch,
      "head_repository" => repository,
      "is_cross_repository" => false,
      "base_repository" => repository
    }
  end

  # A delivery pull request Meringue already verified and persisted as merged, exactly as
  # `MarkWorkerCompleted`/the delivery refresh writes it onto the issue.
  def merged_delivery_pull_request_record(url:, branch:, repository: "acme/app", verified_at: BASE_TIME)
    {
      "provider" => "github",
      "url" => url,
      "state" => "merged",
      "raw_state" => "MERGED",
      "merged_at" => "2026-01-02T00:00:00Z",
      "is_draft" => false,
      "head_branch" => branch,
      "head_repository" => repository,
      "is_cross_repository" => false,
      "base_repository" => repository,
      "matched_by" => "workspace_branch",
      "matched_branch" => branch,
      "verified_at" => verified_at,
      "last_checked_at" => verified_at,
      "availability" => "available"
    }
  end

  def unavailable_pr_status(url:)
    {
      "provider" => "github",
      "url" => url,
      "state" => "unknown",
      "merged_at" => nil,
      "error" => "gh: could not resolve pull request"
    }
  end

  def issue_with_pull_request(id:, project_id:, url:, status: "completed", agent_ids: [], parent_issue_id: nil)
    issue_record(
      id: id,
      project_id: project_id,
      status: status,
      agent_ids: agent_ids,
      parent_issue_id: parent_issue_id,
      extra: {
        "delivery_pull_request" => { "url" => url, "state" => "open" },
        "delivery_pull_requests" => [{ "url" => url, "state" => "open" }],
        "reported_pr_urls" => [url]
      }
    )
  end

  def apply_command(engine, type, payload = {})
    engine.apply({ "type" => type, "payload" => payload })
  end

  def agent_by_id(state, id)
    Array(state.fetch("agents")).find { |agent| agent.fetch("id", nil) == id }
  end

  def issue_by_id(state, id)
    Array(state.fetch("issues")).find { |issue| issue.fetch("id", nil) == id }
  end

  def question_by_id(state, id)
    Array(state.fetch("questions")).find { |question| question.fetch("id", nil) == id }
  end

  def ids(records)
    Array(records).map { |record| record.fetch("id") }
  end

  # Every persisted record must keep using the documented vocabularies.
  def assert_documented_status_vocabulary(state)
    Array(state.fetch("agents")).each do |agent|
      assert_includes Meringue::State::Models::LIFECYCLE_STATUSES, agent.fetch("status"),
                      "agent #{agent.fetch("id")} has an undocumented lifecycle status"
    end
    (Array(state.fetch("issues")) + Array(state.fetch("projects"))).each do |record|
      assert_includes Meringue::State::Models::LIFECYCLE_STATUSES, record.fetch("status"),
                      "#{record.fetch("id")} has an undocumented lifecycle status"
    end
    Array(state.fetch("questions")).each do |question|
      assert_includes Meringue::State::Models::QUESTION_STATUSES, question.fetch("status"),
                      "question #{question.fetch("id")} has an undocumented question status"
    end
    Array(state.fetch("logs")).each do |log|
      assert_includes Meringue::State::Models::LOG_LEVELS, log.fetch("level"),
                      "log #{log.fetch("id")} has an undocumented log level"
    end
  end

  # A dead pid we know cannot be confused with a live process: start a trivial
  # local child, reap it, and reuse its pid as persisted evidence.
  def reaped_pid
    pid = if Process.respond_to?(:fork)
            Process.fork { exit!(0) }
          else
            Process.spawn(RbConfig.ruby, "-e", "", out: File::NULL, err: File::NULL)
          end
    Process.wait(pid)
    pid
  end
end
