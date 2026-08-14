# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Shared hermetic harness for the kernel worker-lifecycle integration slice.
#
# Everything here stays inside a per-test Dir.mktmpdir sandbox: state file,
# workspace root, config path, and any git repository used as a project root.
# No real harness process is ever started; the kernel talks to
# RecordingHarnessClient, which records the calls the kernel makes.
module KernelWorkersSupport
  # Harness client seam used in place of Pi/Claude/Antigravity.
  #
  # It records every kernel -> harness call so tests can assert on the cwd the
  # kernel handed to the harness, the session name it chose, and the prompt mode
  # it selected, and it can be told to fail a spawn or a prompt.
  class RecordingHarnessClient < Meringue::Harness::FakeClient
    attr_reader :spawns, :prompts, :kills, :aborts, :calls, :provider
    attr_accessor :spawn_error, :prompt_error, :streaming, :session_state, :events
    attr_writer :last_assistant_text

    # provider: the harness name the kernel records on the agent. "fake" agents are
    # intentionally skipped by kernel reconciliation, so reconcile-driven tests use
    # a selectable provider name while still talking to this in-process client.
    def initialize(streaming: false, provider: "fake")
      @spawns = []
      @prompts = []
      @kills = []
      @aborts = []
      @calls = []
      @spawn_error = nil
      @prompt_error = nil
      @streaming = streaming
      @provider = provider.to_s
      @session_counter = 0
      @last_assistant_text = nil
      @session_state = "idle"
      @events = []
    end

    def read_events(_session_ref)
      Array(@events)
    end

    # Mirrors a harness that can derive mid-work progress from its own event stream. Events are
    # supplied to this client in raw Pi RPC shape, so kernel tests drive the real extractor
    # instead of a hand-written progress list.
    def session_progress(events)
      Meringue::Harness::PiSessionView.progress_items(events)
    end

    # Read-only transcript view used by the worker session UI boundary. The
    # reported session_state is what drives automatic prompt-mode selection.
    def open_session_view(session_ref)
      reported_state = session_state
      reported_harness = provider
      Meringue::Harness::SessionView::Handle.new(
        snapshot_loader: lambda {
          {
            "availability" => "live",
            "session_state" => reported_state,
            "harness" => reported_harness,
            "items" => [],
            "capabilities" => {
              "live_events" => true,
              "prompt" => true,
              "steer" => true,
              "follow_up" => true,
              "abort" => true
            },
            "warning" => "",
            "session_id" => session_ref.fetch("session_id", nil)
          }
        }
      )
    end

    def harness_name
      provider
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, session_settings: {}, workspace_mode: "isolated")
      call = {
        "kind" => kind,
        "cwd" => cwd,
        "prompt" => prompt,
        "system_prompt" => system_prompt,
        "session_name" => session_name,
        "session_settings" => session_settings,
        "workspace_mode" => workspace_mode
      }
      @spawns << call
      @calls << { "call" => "spawn_session", "session_name" => session_name, "cwd" => cwd }
      raise @spawn_error if @spawn_error

      @session_counter += 1
      {
        "harness" => provider,
        "pid" => 40_000 + @session_counter,
        "cwd" => cwd,
        "session_id" => "fake-#{kind}-session-#{@session_counter}",
        "session_file" => File.join(cwd.to_s, ".fake-session-#{@session_counter}.json"),
        "is_streaming" => streaming,
        "last_event_at" => nil,
        "session_settings" => session_settings.empty? ? nil : {
          "model" => session_settings["model"] && Meringue::Harness::ModelReference.parse(session_settings["model"]),
          "thinking_level" => session_settings["thinking_level"]
        }.compact,
        "metadata" => {
          "prompt" => prompt,
          "system_prompt" => system_prompt,
          "session_name" => session_name,
          "workspace_mode" => workspace_mode
        }
      }
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      # Mirrors the harness contract: a normal prompt into a mid-turn session is queued behind the
      # active turn as a follow-up and the substitution is reported back on the session ref.
      delivered_mode = mode.to_s == "normal" && streaming ? "follow_up" : mode.to_s
      @prompts << {
        "session_id" => session_ref.fetch("session_id", nil),
        "cwd" => session_ref.fetch("cwd", nil),
        "prompt" => prompt,
        "mode" => delivered_mode,
        "requested_mode" => mode.to_s
      }
      @calls << { "call" => "prompt_session", "session_id" => session_ref.fetch("session_id", nil), "mode" => delivered_mode }
      raise @prompt_error if @prompt_error

      coercion = if delivered_mode == mode.to_s
                   {}
                 else
                   {
                     "requested_prompt_mode" => mode.to_s,
                     "delivered_prompt_mode" => delivered_mode,
                     "prompt_mode_note" => "The session was mid-turn, so this prompt was queued as a follow-up " \
                                           "instead of interrupting the active turn."
                   }
                 end
      session_ref.merge(
        "is_streaming" => streaming,
        "metadata" => (session_ref.fetch("metadata", {}) || {}).merge(
          "last_prompt" => prompt,
          "last_prompt_mode" => delivered_mode,
          "queued_prompts" => queued_prompts_for(session_ref, prompt, delivered_mode)
        ).merge(coercion)
      )
    end

    def kill_session(session_ref)
      @kills << { "session_id" => session_ref.fetch("session_id", nil) }
      @calls << { "call" => "kill_session", "session_id" => session_ref.fetch("session_id", nil) }
      session_ref.merge("killed" => true, "is_streaming" => false)
    end

    def abort_session(session_ref)
      @aborts << { "session_id" => session_ref.fetch("session_id", nil) }
      session_ref.merge("is_streaming" => false)
    end

    def get_state(session_ref)
      session_ref.merge("is_streaming" => streaming)
    end

    def killed_session_ids
      @kills.map { |call| call.fetch("session_id", nil) }
    end

    def prompt_modes
      @prompts.map { |call| call.fetch("mode", nil) }
    end

    def call_names
      @calls.map { |call| call.fetch("call") }
    end

    def call_index(name, index: 0)
      matching = @calls.each_index.select { |position| @calls[position].fetch("call") == name }
      matching[index]
    end

    # Matches the harness-client seam the kernel uses to capture a worker's final
    # assistant message when a session settles.
    def last_assistant_text(_session_ref = nil)
      @last_assistant_text
    end

    private

    # Mirrors a harness that queues follow-up prompts instead of interrupting an
    # in-flight turn, so the kernel's mode selection is observable in metadata.
    def queued_prompts_for(session_ref, prompt, mode)
      queued = Array((session_ref.fetch("metadata", {}) || {}).fetch("queued_prompts", []))
      return queued unless mode.to_s == "follow_up"

      queued + [prompt]
    end
  end

  # Raised where a harness client cannot reach a session that is momentarily owned
  # elsewhere; the kernel is expected to queue the prompt instead of failing it.
  class BusySessionError < StandardError
    include Meringue::Harness::TransientSessionError
  end

  # A client whose session reads and reattaches always fail, used to drive the
  # kernel's worker reconciliation blocked/errored transitions.
  class BrokenSessionClient < RecordingHarnessClient
    def get_state(_session_ref)
      raise IOError, "session transport is gone"
    end

    def attach_session(_session_ref)
      raise IOError, "session cannot be reattached"
    end
  end

  # Never shells out to `gh`; delivery pull-request lookups stay offline.
  class OfflineForgeClient
    def pull_request_urls_for_branch(repository:, branch:)
      []
    end

    def pull_request_status(url)
      { "provider" => "github", "url" => url.to_s, "state" => "unknown" }
    end
  end

  # Workspace manager that reports a provisioning failure for every allocation,
  # standing in for a branch/worktree collision the manager could not resolve.
  class FailingWorkspaceManager < Meringue::Workspace::Manager
    attr_reader :released

    def initialize(errors:, **options)
      super(**options)
      @errors = Array(errors)
      @released = []
    end

    def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil)
      plan = plan_worker_workspace(
        project_root: project_root,
        project_id: project_id,
        issue_id: issue_id,
        agent_id: agent_id,
        task_title: task_title
      )
      plan.merge("created" => false, "errors" => @errors)
    end

    def release_worker_workspace(workspace, delete_branch: false)
      @released << workspace
      false
    end
  end

  def setup
    super
    @kernel_workers_tmpdir = Dir.mktmpdir("meringue-kernel-workers")
    @harness_client = RecordingHarnessClient.new
  end

  def teardown
    FileUtils.remove_entry(@kernel_workers_tmpdir) if @kernel_workers_tmpdir && Dir.exist?(@kernel_workers_tmpdir)
    super
  end

  def tmpdir
    @kernel_workers_tmpdir
  end

  def tmp_path(*parts)
    File.join(tmpdir, *parts)
  end

  def state_path
    tmp_path("state.json")
  end

  def workspace_root
    tmp_path("workspaces")
  end

  def store
    @store ||= Meringue::State::Store.new(path: state_path)
  end

  def workspace_manager
    @workspace_manager ||= Meringue::Workspace::Manager.new(root_path: workspace_root, command_timeout: 30)
  end

  def build_engine(harness_client: @harness_client, head_runner: Meringue::Heads::FakeRunner.new,
                   workspace_manager: self.workspace_manager, cwd: tmpdir,
                   forge_client: OfflineForgeClient.new)
    Meringue::Kernel::Engine.new(
      store: store,
      harness_client: harness_client,
      head_runner: head_runner,
      workspace_manager: workspace_manager,
      cwd: cwd,
      forge_client: forge_client,
      config_path: tmp_path("config.toml")
    )
  end

  # A throwaway git repository; never the Meringue checkout under test.
  def create_git_repo(name = "demo-project")
    root = tmp_path(name)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "README.md"), "# #{name}\n")
    run_git(root, "init", "--initial-branch=main")
    run_git(root, "config", "user.email", "meringue-tests@example.com")
    run_git(root, "config", "user.name", "Meringue Tests")
    run_git(root, "add", ".")
    run_git(root, "commit", "-m", "initial commit")
    root
  end

  def create_plain_directory(name = "plain-project")
    root = tmp_path(name)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "notes.txt"), "no git here\n")
    root
  end

  def run_git(root, *args)
    env = {
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_AUTHOR_NAME" => "Meringue Tests",
      "GIT_AUTHOR_EMAIL" => "meringue-tests@example.com",
      "GIT_COMMITTER_NAME" => "Meringue Tests",
      "GIT_COMMITTER_EMAIL" => "meringue-tests@example.com"
    }
    stdout, stderr, status = Open3.capture3(env, "git", "-C", root.to_s, *args.map(&:to_s))
    raise "git #{args.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

    stdout
  end

  def apply_raw(engine, type, payload = {}, command_id: nil)
    engine.apply("command_id" => command_id, "type" => type, "payload" => payload)
  end

  def apply!(engine, type, payload = {}, command_id: nil)
    result = apply_raw(engine, type, payload, command_id: command_id)
    assert_equal "accepted", result.fetch("status"), "#{type} was not accepted: #{result.fetch("message")}"
    result
  end

  # Direct state edits are only used to seed records the kernel cannot create with a
  # fake harness (for example a session-less worker), never to assert behavior.
  def patch_state!
    state = store.load
    yield state
    store.save(state)
    state
  end

  def patch_agent!(agent_id)
    patch_state! do |state|
      record = state.fetch("agents").find { |candidate| candidate.fetch("id") == agent_id }
      raise "agent #{agent_id} is not in state" unless record

      yield record
    end
  end

  def add_project(engine, root, name: "Demo")
    apply!(engine, "AddProject", { "path" => root, "name" => name }).fetch("target_id")
  end

  def create_issue(engine, project_id, title: "Fix the login bug", description: "Details here.")
    apply!(
      engine,
      "CreateIssue",
      { "project_id" => project_id, "title" => title, "description" => description }
    ).fetch("target_id")
  end

  def spawn_worker(engine, issue_id, prompt: "Do the work.", **payload)
    apply!(engine, "SpawnWorker", { "issue_id" => issue_id, "prompt" => prompt }.merge(stringify(payload)))
  end

  def state(engine = nil)
    engine ? engine.list_all : store.load
  end

  def agent(engine, agent_id)
    state(engine).fetch("agents").find { |record| record.fetch("id") == agent_id }
  end

  def issue(engine, issue_id)
    state(engine).fetch("issues").find { |record| record.fetch("id") == issue_id }
  end

  def project(engine, project_id)
    state(engine).fetch("projects").find { |record| record.fetch("id") == project_id }
  end

  def log_messages(engine)
    state(engine).fetch("logs").map { |entry| entry.fetch("message") }
  end

  def logs_matching(engine, pattern)
    log_messages(engine).select { |message| message.match?(pattern) }
  end

  # Every visible log entry attributed to one agent, in order. Used to assert how many
  # lines a single lifecycle event is allowed to write.
  def worker_scoped_logs(engine, agent_id)
    state(engine).fetch("logs").select { |entry| entry.fetch("source_id", nil) == agent_id }
  end

  def stringify(payload)
    payload.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
  end

  # Convenience: registered project + issue on a throwaway git repo.
  def project_with_issue(engine, repo_name: "demo-project", title: "Fix the login bug")
    root = create_git_repo(repo_name)
    project_id = add_project(engine, root)
    issue_id = create_issue(engine, project_id, title: title)
    { "root" => root, "project_id" => project_id, "issue_id" => issue_id }
  end
end
