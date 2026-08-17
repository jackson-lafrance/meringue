# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# Shared helpers for the workspace/worktree integration tests.
#
# Everything here is hermetic:
#
#   * git repositories are created inside Dir.mktmpdir with a local bare
#     "origin" remote, so no test ever runs git against the real checkout;
#   * git commands run with an isolated HOME and config so the developer's
#     global gitconfig cannot change results;
#   * shells, editors, and PTYs are never really launched. Test doubles record
#     the argv/env/options that production code built so assertions can be made
#     on the exact command instead of on a spawned process.
module WorkspaceSupport
  # ---------------------------------------------------------------- temp dirs

  def with_workspace_tmpdir(&block)
    Dir.mktmpdir("meringue-workspace-test", &block)
  end

  # Dir.mktmpdir hands back /var/... on macOS while git reports the resolved
  # /private/var/... path. Manager canonicalizes git/project roots, so tests
  # compare against this helper rather than the raw temp path.
  def real_path(path)
    File.realpath(File.expand_path(path.to_s))
  end

  # -------------------------------------------------------------------- git

  def isolated_git_env(home)
    {
      "HOME" => home,
      "XDG_CONFIG_HOME" => File.join(home, "xdg"),
      "GIT_CONFIG_GLOBAL" => File.join(home, "gitconfig"),
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_AUTHOR_NAME" => "Meringue Test",
      "GIT_AUTHOR_EMAIL" => "test@example.invalid",
      "GIT_COMMITTER_NAME" => "Meringue Test",
      "GIT_COMMITTER_EMAIL" => "test@example.invalid"
    }
  end

  def run_git!(dir, *argv, env:)
    stdout, stderr, status = Open3.capture3(env, "git", *argv, chdir: dir)
    raise "git #{argv.join(" ")} failed in #{dir}: #{stderr}#{stdout}" unless status.success?

    stdout
  end

  # Throwaway repository with a local bare origin, one commit on main, and a
  # nested "app" subdirectory used for project-root-inside-git-root cases.
  def create_git_project(tmp, name: "project")
    home = File.join(tmp, "git-home")
    origin_path = File.join(tmp, "#{name}-origin.git")
    project_root = File.join(tmp, name)
    FileUtils.mkdir_p([home, project_root, File.join(project_root, "app")])
    env = isolated_git_env(home)

    run_git!(tmp, "init", "--bare", "--initial-branch=main", origin_path, env: env)
    run_git!(project_root, "init", "--initial-branch=main", env: env)
    File.write(File.join(project_root, "README.md"), "seed\n")
    File.write(File.join(project_root, "app", "main.rb"), "puts :seed\n")
    run_git!(project_root, "add", ".", env: env)
    run_git!(project_root, "commit", "-m", "seed commit", env: env)
    run_git!(project_root, "remote", "add", "origin", origin_path, env: env)
    run_git!(project_root, "push", "origin", "main", env: env)

    {
      "project_root" => project_root,
      "origin_path" => origin_path,
      "git_env" => env,
      "origin_sha" => run_git!(project_root, "rev-parse", "origin/main", env: env).strip
    }
  end

  # Commit on local main only, so tests can prove worktrees are based on
  # origin/main rather than the checked-out branch tip.
  def advance_local_main(project)
    root = project.fetch("project_root")
    env = project.fetch("git_env")
    File.write(File.join(root, "local-only.txt"), "local\n")
    run_git!(root, "add", ".", env: env)
    run_git!(root, "commit", "-m", "local only commit", env: env)
    run_git!(root, "rev-parse", "HEAD", env: env).strip
  end

  def git_output(project, dir, *argv)
    run_git!(dir, *argv, env: project.fetch("git_env"))
  end

  def branch_exists?(project, branch)
    _out, _err, status = Open3.capture3(
      project.fetch("git_env"), "git", "show-ref", "--verify", "--quiet", "refs/heads/#{branch}",
      chdir: project.fetch("project_root")
    )
    status.success?
  end

  # ---------------------------------------------------------------- manager

  def workspace_manager(tmp, **options)
    Meringue::Workspace::Manager.new(root_path: File.join(tmp, "workspaces"), **options)
  end

  def allocate_workspace(manager, project, task_title:, issue_id: "P1-I1", agent_id: "P1-I1-W1", project_root: nil, profile: nil)
    manager.allocate_worker_workspace(
      project_root: project_root || project.fetch("project_root"),
      project_id: "P1",
      issue_id: issue_id,
      agent_id: agent_id,
      task_title: task_title,
      profile: profile
    )
  end

  # Write a project-declared workspace profile file at the project root.
  def write_workspace_profile(project, body)
    dir = File.join(project.fetch("project_root"), ".meringue")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "workspace-profile.toml"), body)
  end

  # Project with several top-level directories so a sparse profile can exclude
  # some and include others while staying hermetic.
  def create_git_project_with_dirs(tmp, name: "project", dirs: %w[src docs tests config build])
    project = create_git_project(tmp, name: name)
    env = project.fetch("git_env")
    root = project.fetch("project_root")
    dirs.each do |dir|
      FileUtils.mkdir_p(File.join(root, dir))
      File.write(File.join(root, dir, "file.txt"), "#{dir} content\n")
    end
    run_git!(root, "add", ".", env: env)
    run_git!(root, "commit", "-m", "add top-level directories", env: env)
    run_git!(root, "push", "origin", "main", env: env)
    project["origin_sha"] = run_git!(root, "rev-parse", "origin/main", env: env).strip
    project
  end

  # Manager whose `git worktree add` always times out, used to exercise the
  # timeout/cleanup branch without ever hanging the suite. The timeout is
  # injected, so no test ever waits for a real bound to expire.
  class TimingOutManager < Meringue::Workspace::Manager
    def initialize(reason: Meringue::Workspace::Manager::CommandTimeout::BUDGET, run_add_first: false,
                   commit_before_timeout: false, **options)
      super(**options)
      @reason = reason
      @run_add_first = run_add_first
      @commit_before_timeout = commit_before_timeout
    end

    private

    def run_command(*argv, **options)
      return super unless worktree_add?(argv)

      # `run_add_first` reproduces the production shape: git really did create the
      # branch and register the worktree before Meringue killed it, so cleanup has
      # a genuine half-provisioned worktree to deal with.
      result = @run_add_first ? super : nil
      simulate_interrupted_checkout(argv) if @run_add_first
      raise Meringue::Workspace::Manager::CommandTimeout.new(
        argv: argv,
        timeout: 0.25,
        reason: @reason,
        elapsed: 0.3,
        stdout: result ? result.fetch("stdout") : "",
        stderr: result ? result.fetch("stderr") : "simulated hang"
      )
    end

    def worktree_add?(argv)
      tokens = argv.map(&:to_s)
      tokens.include?("worktree") && tokens.include?("add")
    end

    # git writes `.git/worktrees/<name>/locked` for the duration of the checkout and
    # unlinks it on success, so a worktree add that was killed leaves a *locked*
    # registration behind. That is what makes `git worktree remove --force` exit 128.
    def simulate_interrupted_checkout(argv)
      git_root = argv[argv.index("-C") + 1].to_s
      worktree_root = argv.last(2).first.to_s
      worktree_root = argv.last.to_s unless Dir.exist?(worktree_root)
      commit_in(worktree_root) if @commit_before_timeout
      admin_dir = File.join(git_root, ".git", "worktrees", File.basename(worktree_root))
      File.write(File.join(admin_dir, "locked"), "initializing\n") if Dir.exist?(admin_dir)
    end

    # Only used to prove cleanup refuses to delete a branch that carries commits.
    def commit_in(worktree_root)
      File.write(File.join(worktree_root, "worker-delivery.txt"), "delivered\n")
      env = {
        "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
        "GIT_AUTHOR_NAME" => "Meringue Test", "GIT_AUTHOR_EMAIL" => "test@example.invalid",
        "GIT_COMMITTER_NAME" => "Meringue Test", "GIT_COMMITTER_EMAIL" => "test@example.invalid"
      }
      Open3.capture3(env, "git", "-C", worktree_root, "add", ".")
      Open3.capture3(env, "git", "-C", worktree_root, "commit", "-m", "worker delivery")
    end
  end

  # Manager that reproduces Git's ENOSPC failure after it has registered and populated a
  # worktree. The emitted stderr is deliberately much larger than production's diagnostic cap,
  # but no filesystem is actually filled: the failure is injected after a normal small checkout.
  class DiskExhaustedManager < Meringue::Workspace::Manager
    attr_reader :injected_stderr_bytes

    def initialize(repeated_errors: 2_000, fail_once: false, **options)
      super(**options)
      @repeated_errors = repeated_errors
      @remaining_failures = fail_once ? 1 : Float::INFINITY
      @injected_stderr_bytes = 0
    end

    private

    def run_command(*argv, **options)
      return super unless worktree_add?(argv)
      return super unless @remaining_failures.positive?

      @remaining_failures -= 1 unless @remaining_failures.infinite?
      result = super
      stderr = "Preparing worktree\n" + Array.new(
        @repeated_errors,
        "error: failed to open file 'large/path.rb': No space left on device\n"
      ).join + "fatal: Could not reset index file to revision 'HEAD'.\n"
      @injected_stderr_bytes = stderr.bytesize
      buffer = Meringue::Workspace::Manager::DiagnosticBuffer.new(
        limit: Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES
      )
      buffer << stderr
      result.merge(
        "stderr" => buffer.to_s,
        "status" => FailureStatus.new(128),
        "diagnostics" => {
          "stdout_bytes" => result.fetch("stdout").bytesize,
          "stderr_bytes" => buffer.bytes_seen,
          "truncated" => buffer.truncated?
        }
      )
    end

    FailureStatus = Struct.new(:exitstatus) do
      def success? = false
    end

    def worktree_add?(argv)
      tokens = argv.map(&:to_s)
      tokens.include?("worktree") && tokens.include?("add")
    end
  end

  class PreflightDiskExhaustedManager < Meringue::Workspace::Manager
    private

    def preferred_base_ref(*)
      raise Errno::ENOSPC, "simulated preflight read"
    end
  end

  class IncompleteCleanupManager < Meringue::Workspace::Manager
    attr_reader :branch_release_attempted

    private

    def remove_incomplete_worktree(**)
      { "worktree_removed" => false, "worktree_remove_status" => 128 }
    end

    def release_owned_branch(*)
      @branch_release_attempted = true
      "deleted"
    end
  end

  class RaisingDiskExhaustedManager < Meringue::Workspace::Manager
    private

    def run_command(*argv, **options)
      tokens = argv.map(&:to_s)
      raise Errno::ENOSPC, "simulated allocation write" if tokens.include?("worktree") && tokens.include?("add")

      super
    end
  end

  # ----------------------------------------------------------------- agents

  def worker_agent(id: "P1-I1-W1", workspace_path: nil, cwd: nil, plan: {}, **extra)
    {
      "id" => id,
      "type" => "worker",
      "workspace_path" => workspace_path,
      "harness_metadata" => { "cwd" => cwd, "workspace_plan" => plan }.compact
    }.compact.merge(extra)
  end

  # Executable that exists on disk so LaunchCommand#executable_path resolves it.
  # Tests never run it; they assert on the argv that was built.
  def stub_executable(path, body: "#!/bin/sh\nexit 0\n")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end

  # ------------------------------------------------------------------ fakes

  # Config double with the shape `*.from_config` expects.
  class StubConfig
    def initialize(sections = {})
      @sections = sections
    end

    def section(*keys)
      value = @sections.fetch(keys.map(&:to_s).join("."), nil)
      value.is_a?(Hash) ? value : {}
    end
  end

  # Stands in for Workspace::TerminalSession: records everything the manager and
  # controller ask for, and never touches a PTY or a process.
  class FakeTerminalSession
    attr_reader :starts, :writes, :resizes, :closes

    def initialize(alive: true, output: "", start_status: nil)
      @alive = alive
      @output = output.dup.b
      @start_status = start_status
      @starts = []
      @writes = []
      @resizes = []
      @closes = 0
      @workspace_path = nil
    end

    def start(workspace_path:, rows: 24, columns: 80, on_started: nil)
      @starts << { "workspace_path" => workspace_path, "rows" => rows, "columns" => columns }
      @workspace_path = workspace_path
      on_started&.call(4242)
      @start_status || {
        "status" => "active",
        "message" => "Started terminal in #{workspace_path}.",
        "pid" => 4242,
        "workspace_path" => workspace_path,
        "started" => true
      }
    end

    def alive? = @alive

    def exit!(exitstatus: 2)
      @alive = false
      @exitstatus = exitstatus
      self
    end

    def status
      {
        "state" => @alive ? "running" : "exited",
        "pid" => 4242,
        "workspace_path" => @workspace_path,
        "alive" => @alive,
        "exit_status" => @alive ? nil : { "success" => false, "exitstatus" => @exitstatus }
      }.compact
    end

    def write(data)
      bytes = data.to_s.b
      @writes << bytes
      { "status" => "written", "bytes" => bytes.bytesize }
    end

    def feed_output(bytes)
      @output << bytes.to_s.b
      self
    end

    def drain_output(timeout: 0)
      drained = @output.dup
      @output.clear
      drained
    end

    def resize(rows:, columns:)
      @resizes << [rows, columns]
      { "status" => "resized", "rows" => rows, "columns" => columns }
    end

    def close
      @closes += 1
      { "status" => "closed", "message" => "Workspace terminal stopped." }
    end
  end

  # PTY double: records the spawn arguments TerminalSession built and then fails
  # deterministically, so no shell is ever started.
  class RecordingPty
    attr_reader :calls

    def initialize(error: Errno::ENOTTY)
      @calls = []
      @error = error
    end

    def spawn(env, *argv, **options)
      @calls << { "env" => env, "argv" => argv, "options" => options }
      raise @error
    end

    def last_call = @calls.last
  end

  # Editor launcher whose immediate-exit probe is stubbed, so tests can assert
  # both the spawned argv and the success/failure messaging without a process.
  class RecordingEditorLauncher < Meringue::Workspace::EditorLauncher
    ImmediateStatus = Struct.new(:success, :signaled, :termsig, :exitstatus) do
      def success? = success
      def signaled? = signaled
    end

    attr_reader :spawn_calls

    def self.succeeding(**options)
      new(immediate_status: ImmediateStatus.new(true, false, nil, 0), **options)
    end

    def self.exiting(exitstatus: 3, **options)
      new(immediate_status: ImmediateStatus.new(false, false, nil, exitstatus), **options)
    end

    def initialize(immediate_status: nil, **options)
      @immediate_status = immediate_status
      @spawn_calls = []
      recorder = lambda do |env, *argv|
        @spawn_calls << { "env" => env, "argv" => argv[0..-2], "options" => argv.last }
        4242
      end
      super(spawn: recorder, **options)
    end

    def last_spawn = @spawn_calls.last

    private

    def wait_for_immediate_exit(_pid)
      @immediate_status
    end
  end

  # Editor launcher double for controller tests.
  class FakeEditorLauncher
    attr_reader :opened

    def initialize(result: nil)
      @opened = []
      @result = result
    end

    def open(agent)
      @opened << agent
      @result || { "status" => "opened", "message" => "Opened #{agent.is_a?(Hash) ? agent["id"] : agent} in the editor." }
    end
  end
end
