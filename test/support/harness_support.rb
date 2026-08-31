# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Shared helpers for the harness integration suite.
#
# Everything here is hermetic: no real pi/claude/gh binary is ever executed,
# nothing is written outside Dir.mktmpdir, and no network call is made. Process
# backed clients are driven by tiny scripted stubs generated per test that speak
# the JSONL protocol the client expects.
module HarnessSupport
  # Every harness client must return a session ref with these keys so the kernel
  # can stay harness independent.
  REQUIRED_SESSION_REF_KEYS = %w[
    harness
    pid
    cwd
    session_id
    session_file
    is_streaming
    last_event_at
  ].freeze

  HARNESS_CLIENT_METHODS = %i[
    spawn_session
    prompt_session
    abort_session
    kill_session
    get_state
    read_events
    attach_session
  ].freeze

  RUBY_BIN = RbConfig.ruby

  def harness_setup
    @harness_tmpdirs = []
    @harness_pids = []
    @harness_sessions = []
    @harness_env_backup = nil
  end

  def harness_teardown
    Array(@harness_sessions).each do |(client, session_ref)|
      client.kill_session(session_ref)
    rescue StandardError
      nil
    end
    Array(@harness_pids).each { |pid| reap_pid(pid) }
    restore_env
    Array(@harness_tmpdirs).each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # --- temp dirs -------------------------------------------------------------

  def make_tmpdir
    dir = Dir.mktmpdir("meringue-harness")
    (@harness_tmpdirs ||= []) << dir
    dir
  end

  def tmpdir
    @tmpdir ||= make_tmpdir
  end

  # --- env -------------------------------------------------------------------

  def with_env(values)
    @harness_env_backup ||= {}
    values.each do |key, value|
      key = key.to_s
      @harness_env_backup[key] = ENV[key] unless @harness_env_backup.key?(key)
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value.to_s
      end
    end
    return unless block_given?

    begin
      yield
    ensure
      restore_env
    end
  end

  def restore_env
    return unless @harness_env_backup

    @harness_env_backup.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    @harness_env_backup = nil
  end

  # --- processes -------------------------------------------------------------

  def track_pid(pid)
    (@harness_pids ||= []) << pid
    pid
  end

  def track_session(client, session_ref)
    (@harness_sessions ||= []) << [client, session_ref]
    session_ref
  end

  # A long lived process that looks like a harness transport to
  # ProcessIdentity (its executable basename is "ruby") but never answers RPC.
  def spawn_idle_ruby_process(seconds: 30)
    pid = Process.spawn(RUBY_BIN, "-e", "sleep #{seconds}", out: File::NULL, err: File::NULL)
    # Detach so the process is reaped as soon as it is signalled: a zombie child
    # still answers kill(0), which would hide real liveness behaviour.
    Process.detach(pid)
    track_pid(pid)
  end

  def reap_pid(pid)
    return unless pid

    Process.kill("KILL", pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def wait_until(timeout: 5.0, interval: 0.02)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      value = yield
      return value if value
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep interval
    end
    nil
  end

  def process_alive?(pid)
    Process.kill(0, Integer(pid))
    true
  rescue Errno::ESRCH, TypeError, ArgumentError
    false
  rescue Errno::EPERM
    true
  end

  # --- scripted stubs --------------------------------------------------------

  def write_executable(dir, name, source)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    FileUtils.chmod(0o755, path)
    path
  end

  # Scripted Pi RPC stub. Reads newline delimited JSON commands on stdin and
  # writes newline delimited JSON responses/events on stdout, exactly like
  # `pi --mode rpc`, but with fully deterministic, test controlled behaviour.
  PI_STUB_SOURCE = <<~'RUBY'
    # frozen_string_literal: true
    require "json"

    config = ENV["PI_STUB_CONFIG"] ? JSON.parse(File.read(ENV["PI_STUB_CONFIG"])) : {}
    $stdout.sync = true

    if config["argv_log"] && !(ARGV.include?("auth") && ARGV.include?("check"))
      File.write(config["argv_log"], JSON.generate(ARGV))
    end
    if config["env_log"]
      keys = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL]
      File.write(config["env_log"], JSON.generate(keys.to_h { |key| [key, ENV[key]] }))
    end

    def log_command(config, command)
      return unless config["commands_log"]

      File.open(config["commands_log"], "a") { |file| file.puts(JSON.generate(command)) }
    end

    def emit_raw(text, split: false)
      if split && text.length > 4
        middle = text.length / 2
        $stdout.write(text[0, middle])
        $stdout.flush
        sleep 0.02
        $stdout.write(text[middle..])
      else
        $stdout.write(text)
      end
      $stdout.flush
    end

    def emit_json(payload, split: false)
      emit_raw("#{JSON.generate(payload)}\n", split: split)
    end

    def argv_option(name)
      index = ARGV.index(name)
      return ARGV[index + 1] if index && index + 1 < ARGV.length

      prefix = "#{name}="
      ARGV.find { |argument| argument.start_with?(prefix) }&.delete_prefix(prefix)
    end

    # Pi auth checks are separate short-lived CLI calls, so answer them before
    # entering the RPC stdin loop. Tests can set auth_statuses by provider.
    if ARGV.include?("auth") && ARGV.include?("check")
      provider = argv_option("--provider")
      auth = config.fetch("auth_statuses", {}).fetch(provider, { "status" => "ready", "source" => "test" })
      auth = { "status" => auth } unless auth.is_a?(Hash)
      $stdout.write(JSON.generate(auth) + "\n")
      exit(config.fetch("auth_exit_code", 0))
    end

    configured_model = config.fetch("model", { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5" })
    if !config["ignore_argv_model"] && (model_reference = argv_option("--model"))
      provider, model_id = model_reference.split("/", 2)
      configured_model = { "provider" => provider, "id" => model_id, "name" => model_id }
    end

    state = {
      "sessionId" => config.fetch("session_id", "stub-session-id"),
      "sessionFile" => config["session_file"],
      "sessionName" => config["session_name"],
      "isStreaming" => config.fetch("is_streaming", false),
      "model" => configured_model,
      "thinkingLevel" => argv_option("--thinking") || config.fetch("thinking_level", "max")
    }

    Array(config["noise"]).each { |line| emit_raw("#{line}\n") }
    Array(config["startup_events"]).each { |event| emit_json(event) }

    while (line = $stdin.gets)
      line = line.strip
      next if line.empty?

      begin
        command = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      log_command(config, command)

      type = command["type"].to_s
      exit(config.fetch("exit_code", 0)) if config["exit_before"] == type
      next if Array(config["ignore_commands"]).include?(type)

      Array(config.dig("events_before_response", type)).each { |event| emit_json(event) }

      response = { "type" => "response", "id" => command["id"], "command" => type }
      failure = config.dig("fail_commands", type)
      if failure
        response["success"] = false
        response["error"] = failure
      else
        response["success"] = true
        response["data"] =
          case type
          when "get_state"
            state.dup
          when "get_session_stats"
            config.fetch("session_stats", {})
          when "set_session_name"
            state["sessionName"] = command["name"]
            nil
          when "get_last_assistant_text"
            { "text" => config.fetch("last_assistant_text", "stub assistant text") }
          when "get_entries"
            { "entries" => Array(config["entries"]), "leafId" => config["leaf_id"] }
          when "get_messages"
            { "messages" => Array(config["messages"]) }
          when "abort"
            state["isStreaming"] = false
            nil
          when "set_model"
            state["model"] = { "provider" => command["provider"], "id" => command["modelId"] }
          when "get_available_thinking_levels"
            { "levels" => config.fetch("available_thinking_levels", %w[off minimal low medium high xhigh max]) }
          when "get_available_models"
            { "models" => config.fetch("available_models", [
              { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5", "reasoning" => true,
                "contextWindow" => 1_000_000, "maxTokens" => 128_000, "thinkingLevelMap" => { "xhigh" => "xhigh", "max" => "max" } },
              { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol", "reasoning" => true,
                "contextWindow" => 400_000 },
              { "provider" => "google", "id" => "gemini-3-flash", "name" => "Gemini 3 Flash", "reasoning" => false,
                "contextWindow" => 1_048_576 }
            ]) }
          when "set_thinking_level"
            state["thinkingLevel"] = command["level"]
            nil
          when "prompt", "steer", "follow_up"
            nil
          else
            nil
          end
      end

      emit_json(response, split: !!config["split_responses"])
      Array(config.dig("events_after_response", type)).each { |event| emit_json(event) }
      state["isStreaming"] = true if config["streaming_after"] == type

      if config["exit_after"] == type
        $stdout.flush
        exit(config.fetch("exit_code", 0))
      end
    end
  RUBY

  # Generic process-backed harness stub: prints a
  # scripted stream of JSONL records to stdout, then exits.
  PROCESS_STUB_SOURCE = <<~'RUBY'
    # frozen_string_literal: true
    require "json"

    config = ENV["PROCESS_STUB_CONFIG"] ? JSON.parse(File.read(ENV["PROCESS_STUB_CONFIG"])) : {}
    $stdout.sync = true

    File.write(config["argv_log"], JSON.generate(ARGV)) if config["argv_log"]
    if config["env_log"]
      keys = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL]
      File.write(config["env_log"], JSON.generate(keys.to_h { |key| [key, ENV[key]] }))
    end

    Array(config["stdout_lines"]).each do |line|
      $stdout.write(line.is_a?(String) ? "#{line}\n" : "#{JSON.generate(line)}\n")
      $stdout.flush
    end
    $stderr.write(config["stderr"].to_s) if config["stderr"]
    sleep config["sleep"].to_f if config["sleep"]
    exit(config.fetch("exit_code", 0))
  RUBY

  def write_pi_stub(dir, config = {})
    config = default_stub_paths(dir, config, prefix: "pi")
    script = write_executable(dir, "pi_rpc_stub.rb", PI_STUB_SOURCE)
    config_path = File.join(dir, "pi_stub_config.json")
    File.write(config_path, JSON.generate(config))
    {
      "command" => [RUBY_BIN, script],
      "env" => { "PI_STUB_CONFIG" => config_path },
      "config" => config
    }
  end

  def write_process_stub(dir, config = {}, name: "process_stub.rb")
    config = default_stub_paths(dir, config, prefix: File.basename(name, ".rb"))
    script = write_executable(dir, name, PROCESS_STUB_SOURCE)
    config_path = File.join(dir, "#{File.basename(name, ".rb")}_config.json")
    File.write(config_path, JSON.generate(config))
    {
      "command" => [RUBY_BIN, script],
      "env" => { "PROCESS_STUB_CONFIG" => config_path },
      "config" => config
    }
  end

  def default_stub_paths(dir, config, prefix:)
    config = config.transform_keys(&:to_s)
    config["argv_log"] ||= File.join(dir, "#{prefix}_argv.json")
    config["commands_log"] ||= File.join(dir, "#{prefix}_commands.jsonl")
    config
  end

  # Stubs write their argv as soon as they start, which can race with a client
  # call that returns before the child has been scheduled.
  def stub_argv(stub, wait: true)
    path = stub.fetch("config").fetch("argv_log")
    read_argv = lambda do
      next nil unless File.file?(path)

      begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end
    end
    argv = wait ? wait_until { read_argv.call } : read_argv.call
    argv || []
  end

  def stub_commands(stub)
    path = stub.fetch("config").fetch("commands_log")
    return [] unless File.file?(path)

    File.readlines(path).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end

  def stub_commands_of_type(stub, type)
    stub_commands(stub).select { |command| command["type"] == type }
  end

  # --- pi clients ------------------------------------------------------------

  def build_pi_client(dir, stub_config: {}, session_dir: nil, **kwargs)
    stub = write_pi_stub(dir, stub_config)
    session_dir ||= File.join(dir, "pi-sessions")
    FileUtils.mkdir_p(session_dir)
    client = Meringue::Harness::PiClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      session_dir: session_dir,
      command_timeout: 10,
      event_timeout: 10,
      shutdown_timeout: 1,
      transport_ownership: build_transport_ownership(dir),
      **kwargs
    )
    [client, stub]
  end

  def build_transport_ownership(dir, **kwargs)
    Meringue::Harness::TransportOwnership.new(
      directory: File.join(dir, "transport-locks"),
      **kwargs
    )
  end

  # --- pi session files ------------------------------------------------------

  def pi_session_file(dir, session_id: "sess-1", name: "Fix login redirect", cwd: nil,
                      completed: true, extra_lines: [], text: "worker finished the task")
    path = File.join(dir, "#{session_id}.jsonl")
    records = [
      { "type" => "session", "id" => session_id, "cwd" => cwd || dir, "timestamp" => "2026-01-01T00:00:00Z" },
      { "type" => "session_info", "id" => "info-1", "parentId" => nil, "name" => name },
      {
        "type" => "message",
        "id" => "m1",
        "parentId" => nil,
        "timestamp" => "2026-01-01T00:00:01Z",
        "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "please fix the redirect" }] }
      },
      {
        "type" => "message",
        "id" => "m2",
        "parentId" => "m1",
        "timestamp" => "2026-01-01T00:00:02Z",
        "message" => {
          "role" => "assistant",
          "content" => [{ "type" => "text", "text" => text }],
          "stopReason" => completed ? "endTurn" : "toolUse"
        }
      }
    ]
    File.open(path, "w") do |file|
      records.each { |record| file.puts(JSON.generate(record)) }
      Array(extra_lines).each { |line| file.puts(line) }
    end
    path
  end

  def pi_session_ref(session_file:, session_id: "sess-1", pid: nil, cwd: nil, name: "Fix login redirect", kind: "worker")
    {
      "harness" => "pi",
      "pid" => pid,
      "cwd" => cwd || File.dirname(session_file),
      "session_id" => session_id,
      "session_file" => session_file,
      "is_streaming" => false,
      "last_event_at" => nil,
      "metadata" => { "kind" => kind, "session_name" => name }
    }
  end

  # --- config ----------------------------------------------------------------

  def build_config(data = {}, dir: nil)
    Meringue::Config.new(data, path: File.join(dir || tmpdir, "config.toml"))
  end
end

# Base class for the harness integration tests: hermetic temp dirs, tracked
# child processes, and restored environment variables.
class HarnessIntegrationTest < Minitest::Test
  include HarnessSupport

  def setup
    harness_setup
  end

  def teardown
    harness_teardown
  end
end
