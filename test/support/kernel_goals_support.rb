# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Shared hermetic harness for the goal-loop slice.
#
# Everything lives inside a per-test Dir.mktmpdir: state file, workspace root, config path,
# and a throwaway git repository used as the project root. No harness process is started and
# no metric command is ever executed: the probe is a scripted seam, so a goal loop can be
# driven deterministically without shelling out.
module KernelGoalsSupport
  # Harness client seam. `streaming` decides whether a polled session looks like it is still
  # working (loop must wait) or has settled (loop may measure).
  class GoalHarnessClient < Meringue::Harness::FakeClient
    REVIEW_MARKER = Meringue::Goals::ReviewPrompt::VERDICT_MARKER

    attr_reader :spawns, :prompts, :kills
    attr_accessor :streaming, :spawn_error, :prompt_error

    def initialize(streaming: true, provider: "pi")
      @spawns = []
      @prompts = []
      @kills = []
      @streaming = streaming
      @provider = provider.to_s
      @counter = 0
      @review_sessions = {}
      @review_replies = []
      @last_review_reply = nil
    end

    # What a reviewer session says at the end of its turn. A Hash is rendered as the fenced
    # JSON object the contract asks for; a String is returned verbatim, which is how a
    # malformed or refusing reviewer is modelled. The last queued reply repeats.
    def queue_review(*replies)
      @review_replies.concat(replies.flatten)
      self
    end

    def harness_name
      @provider
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, workspace_mode: "isolated")
      @counter += 1
      session_id = "goal-session-#{@counter}"
      @spawns << { "kind" => kind, "cwd" => cwd, "prompt" => prompt, "session_name" => session_name, "session_id" => session_id }
      @review_sessions[session_id] = true if prompt.to_s.include?(REVIEW_MARKER)
      raise @spawn_error if @spawn_error

      {
        "harness" => @provider,
        "pid" => 50_000 + @counter,
        "cwd" => cwd,
        "session_id" => session_id,
        "session_file" => File.join(cwd.to_s, ".goal-session-#{@counter}.json"),
        "is_streaming" => streaming,
        "last_event_at" => nil,
        "metadata" => { "session_name" => session_name }
      }
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      @prompts << { "session_id" => session_ref.fetch("session_id", nil), "prompt" => prompt, "mode" => mode }
      raise @prompt_error if @prompt_error

      session_ref.merge("is_streaming" => streaming)
    end

    def get_state(session_ref)
      session_ref.merge("is_streaming" => streaming)
    end

    def kill_session(session_ref)
      @kills << session_ref.fetch("session_id", nil)
      session_ref.merge("killed" => true, "is_streaming" => false)
    end

    def abort_session(session_ref)
      session_ref.merge("is_streaming" => false)
    end

    def read_events(_session_ref)
      []
    end

    def last_assistant_text(session_ref = nil)
      session_id = session_ref.is_a?(Hash) ? session_ref["session_id"] : nil
      return "Attempt finished." unless session_id && @review_sessions[session_id]

      reply = @review_replies.shift
      @last_review_reply = reply unless reply.nil?
      render_review_reply(@last_review_reply)
    end

    def review_session_ids
      @review_sessions.keys
    end

    def review_prompts
      all_prompts.select { |prompt| prompt.include?(REVIEW_MARKER) }
    end

    def attempt_prompts
      all_prompts.reject { |prompt| prompt.include?(REVIEW_MARKER) }
    end

    private

    def all_prompts
      @spawns.map { |spawn| spawn.fetch("prompt") } + @prompts.map { |prompt| prompt.fetch("prompt") }
    end

    def render_review_reply(reply)
      case reply
      when nil then "The review session ended without a verdict."
      when Hash then "Here is my review.\n\n```json\n#{JSON.pretty_generate(reply)}\n```"
      else reply.to_s
      end
    end
  end

  # Scripted stand-in for Goals::MetricProbe. Measurements are queued, so a test states the
  # metric trajectory it wants ("61, then 72, then 80") instead of running real commands.
  class ScriptedMetricProbe
    attr_reader :calls, :guardrail_calls
    attr_accessor :guardrail_passes, :fingerprints

    def initialize(values: [], guardrail_passes: true, fingerprints: nil)
      @values = Array(values)
      @calls = []
      @guardrail_calls = []
      @guardrail_passes = guardrail_passes
      @fingerprints = fingerprints
      @fingerprint_index = 0
    end

    # Each entry may be a number, or a hash to model a broken probe
    # ({ "exit_status" => 1 }, { "timed_out" => true }, { "parse_error" => "..." }).
    def queue(*values)
      @values.concat(values.flatten)
      self
    end

    def measure(command:, cwd:, parse: {}, timeout: nil)
      @calls << { "command" => command, "cwd" => cwd, "parse" => parse, "timeout" => timeout }
      entry = @values.shift
      entry = @values.last if entry.nil? && !@values.empty?
      base = { "exit_status" => 0, "timed_out" => false, "stdout_tail" => "measured", "stderr_tail" => "" }
      case entry
      when nil then base.merge("value" => nil, "parse_error" => "no measurement queued")
      when Numeric then base.merge("value" => entry.to_f)
      when Hash then base.merge(entry)
      else base.merge("value" => nil, "parse_error" => "unusable measurement")
      end
    end

    def check_guardrail(command:, cwd:, timeout: nil)
      @guardrail_calls << { "command" => command, "cwd" => cwd }
      passed = @guardrail_passes.is_a?(Array) ? @guardrail_passes.shift : @guardrail_passes
      passed = true if passed.nil?
      { "command" => command, "expect" => "exit_zero", "passed" => passed, "exit_status" => passed ? 0 : 1 }
    end

    # Unique per call by default: a real fingerprint changes whenever the attempt commits
    # something. Tests that want the oscillation guard supply an explicit repeated sequence.
    def workspace_fingerprint(cwd:)
      @fingerprint_index += 1
      return "fingerprint-#{cwd}-#{@fingerprint_index}" if @fingerprints.nil?

      @fingerprints[@fingerprint_index - 1] || @fingerprints.last
    end

    def measured_values
      @calls.length
    end
  end

  def goals_setup
    @goals_tmpdir = Dir.mktmpdir("meringue-kernel-goals")
    @harness_client = GoalHarnessClient.new
    @probe = ScriptedMetricProbe.new
  end

  def goals_teardown
    FileUtils.remove_entry(@goals_tmpdir) if @goals_tmpdir && Dir.exist?(@goals_tmpdir)
  end

  attr_reader :harness_client, :probe

  def tmpdir
    @goals_tmpdir
  end

  def tmp_path(*parts)
    File.join(tmpdir, *parts)
  end

  def store
    @store ||= Meringue::State::Store.new(path: tmp_path("state.json"))
  end

  def workspace_manager
    @workspace_manager ||= Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"), command_timeout: 30)
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

  def build_engine(harness_client: self.harness_client, metric_probe: probe, cwd: tmpdir, **overrides)
    Meringue::Kernel::Engine.new(
      store: store,
      harness_client: harness_client,
      harness_client_resolver: ->(_agent) { harness_client },
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: workspace_manager,
      cwd: cwd,
      forge_client: OfflineForgeClient.new,
      metric_probe: metric_probe,
      config_path: tmp_path("config.toml"),
      **overrides
    )
  end

  def engine
    @engine ||= build_engine
  end

  # A throwaway git repository; never the Meringue checkout under test.
  def create_git_repo(name = "goal-project")
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

  def apply_raw(type, payload = {}, command_id: nil)
    engine.apply("command_id" => command_id, "type" => type, "payload" => payload)
  end

  def apply!(type, payload = {}, command_id: nil)
    result = apply_raw(type, payload, command_id: command_id)
    assert_equal "accepted", result.fetch("status"), "#{type} was not accepted: #{result.fetch("message")} #{result.fetch("errors")}"
    result
  end

  # Registers a project without an issue, for the `/goal create "<prompt>"` form where the
  # kernel mints the issue itself.
  def registered_project(name = "goal-project", project_name: "Goal demo")
    root = create_git_repo(name)
    project_id = apply!("AddProject", { "path" => root, "name" => project_name }).fetch("target_id")
    { "root" => root, "project_id" => project_id }
  end

  def project_with_issue(title: "Raise kernel coverage")
    root = create_git_repo
    project_id = apply!("AddProject", { "path" => root, "name" => "Goal demo" }).fetch("target_id")
    issue_id = apply!("CreateIssue", { "project_id" => project_id, "title" => title, "description" => "Fixture issue" }).fetch("target_id")
    { "root" => root, "project_id" => project_id, "issue_id" => issue_id }
  end

  def create_goal!(issue_id, **overrides)
    payload = {
      "issue_id" => issue_id,
      "success_criteria" => "line coverage of lib/meringue/kernel is at least 80%",
      "metric_command" => "rake coverage",
      "target" => 80,
      "max_iterations" => 3,
      "min_seconds_between_iterations" => 0
    }.merge(overrides.transform_keys(&:to_s))
    apply!("CreateGoal", payload)
  end

  # A reviewer-judged goal: no metric command, no target, judged by a reviewer session.
  def create_reviewer_goal!(issue_id, **overrides)
    payload = {
      "issue_id" => issue_id,
      "success_criteria" => "the first-run onboarding reads cleanly and explains the three core commands",
      "judge_mode" => "reviewer",
      "max_iterations" => 3,
      "min_seconds_between_iterations" => 0
    }.merge(overrides.transform_keys(&:to_s))
    apply!("CreateGoal", payload)
  end

  def state
    store.load
  end

  def goal(goal_id = "G1")
    state.fetch("goals").find { |record| record.fetch("id") == goal_id }
  end

  def issue_record(issue_id)
    state.fetch("issues").find { |record| record.fetch("id") == issue_id }
  end

  def workers
    state.fetch("agents").select { |agent| agent.fetch("type") == "worker" }
  end

  def review_workers(goal_id = "G1")
    review_ids = iterations(goal_id).filter_map { |iteration| iteration["review_worker_id"] }
    workers.select { |worker| review_ids.include?(worker.fetch("id")) }
  end

  def attempt_workers(goal_id = "G1")
    review_ids = iterations(goal_id).filter_map { |iteration| iteration["review_worker_id"] }
    workers.reject { |worker| review_ids.include?(worker.fetch("id")) }
  end

  def iterations(goal_id = "G1")
    Array(goal(goal_id).fetch("iterations"))
  end

  def settled_iterations(goal_id = "G1")
    iterations(goal_id).select { |iteration| iteration.fetch("phase") == "settled" }
  end

  def log_messages
    state.fetch("logs").map { |entry| entry.fetch("message") }
  end

  def logs_matching(pattern)
    log_messages.select { |message| message.match?(pattern) }
  end

  # One reconcile pass: exactly what App's 2-second tick calls.
  def tick!
    engine.reconcile_sessions
  end

  # Runs ticks until the goal settles, with a hard cap so a broken loop fails the test
  # instead of hanging it.
  def tick_until_settled!(goal_id = "G1", max_ticks: 30)
    max_ticks.times do
      break unless Meringue::Goals::Record::ACTIVE_STATUSES.include?(goal(goal_id).fetch("status"))

      tick!
      finish_attempt_session!
    end
    goal(goal_id)
  end

  # Models the attempt agent finishing its turn: the harness stops streaming, so the next
  # poll settles the worker and the loop may measure its branch.
  def finish_attempt_session!
    harness_client.streaming = false
    tick!
    harness_client.streaming = true
  end

  # Same thing, named for the reviewer-judged loop where the session that settles may be an
  # attempt or a reviewer.
  alias settle_sessions! finish_attempt_session!
end
