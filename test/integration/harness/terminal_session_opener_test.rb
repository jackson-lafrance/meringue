# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The terminal opener is the only place Meringue hands a harness session to a
# real terminal. It must validate the saved session before launching anything,
# and it must never invent or destroy harness state.
class HarnessTerminalSessionOpenerTest < HarnessIntegrationTest
  Opener = Meringue::Harness::TerminalSessionOpener

  def setup
    super
    @session_dir = File.join(tmpdir, "pi-sessions")
    FileUtils.mkdir_p(@session_dir)
    @launch_log = File.join(tmpdir, "alacritty_launches.jsonl")
    @alacritty = write_alacritty_stub
  end

  def write_alacritty_stub(exit_code: 0, name: "alacritty_stub.rb")
    write_executable(tmpdir, name, <<~RUBY)
      #!#{HarnessSupport::RUBY_BIN}
      require "json"
      File.open(#{@launch_log.inspect}, "a") { |file| file.puts(JSON.generate(ARGV)) }
      exit(#{exit_code})
    RUBY
  end

  def launches
    return [] unless File.file?(@launch_log)

    File.readlines(@launch_log).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end

  def opener(alacritty: @alacritty, commands: {})
    Opener.new(pi_session_dir: @session_dir, alacritty_command: alacritty, commands: commands)
  end

  def agent(overrides = {})
    { "id" => "P1-I1-W1", "harness" => "pi", "workspace_path" => tmpdir }.merge(overrides)
  end

  def test_missing_agent_is_rejected
    result = opener.open(nil)

    assert_equal "rejected", result.fetch("status")
    assert_equal "Agent was not found.", result.fetch("message")
    assert_empty launches
  end

  def test_agent_without_a_harness_is_rejected
    result = opener.open(agent("harness" => ""))

    assert_equal "rejected", result.fetch("status")
    assert_match(/has no agent session to open/, result.fetch("message"))
    assert_empty launches
  end

  def test_unsupported_harness_is_rejected
    result = opener.open(agent("harness" => "codex"))

    assert_equal "rejected", result.fetch("status")
    assert_equal "Opening this agent session in a terminal is not supported yet.", result.fetch("message")
    assert_empty launches
  end

  def test_opening_a_pi_session_launches_the_configured_command_in_the_workspace
    session_file = pi_session_file(@session_dir, session_id: "sess-1")

    result = opener(commands: { "pi" => "pi-dev --quiet" }).open(
      agent("harness_session_file" => session_file, "harness_session_id" => "sess-1")
    )

    assert_equal "opened", result.fetch("status")
    assert_nil result["message"], "successful opens are transient UI feedback with no log message"
    argv = launches.fetch(0)
    assert_equal ["--working-directory", tmpdir, "-e", "pi-dev", "--quiet"], argv.first(5)
    assert_includes argv.each_cons(2).to_a, ["--session-dir", @session_dir]
    assert_includes argv.each_cons(2).to_a, ["--session", session_file]
  end

  def test_opening_a_persisted_head_pi_session_uses_the_heads_recorded_cwd
    session_file = pi_session_file(@session_dir, session_id: "head-sess-1")
    head = {
      "id" => "H1",
      "type" => "head",
      "harness" => "pi",
      "harness_session_file" => session_file,
      "harness_session_id" => "head-sess-1",
      "harness_metadata" => { "cwd" => tmpdir, "head_session_state" => "released" }
    }

    result = opener(commands: { "pi" => "pi-dev" }).open(head)

    assert_equal "opened", result.fetch("status")
    argv = launches.fetch(0)
    assert_equal ["--working-directory", tmpdir, "-e", "pi-dev"], argv.first(4)
    assert_includes argv.each_cons(2).to_a, ["--session", session_file]
  end

  def test_pi_session_file_is_discovered_from_the_session_directory
    discovered = pi_session_file(@session_dir, session_id: "sess-discovered")

    result = opener.open(agent("harness_session_id" => "sess-discovered"))

    assert_equal "opened", result.fetch("status")
    assert_includes launches.fetch(0).each_cons(2).to_a, ["--session", discovered]
  end

  def test_pi_agent_without_a_session_file_or_id_is_rejected
    result = opener.open(agent)

    assert_equal "rejected", result.fetch("status")
    assert_match(/has no saved agent session file or session id to open/, result.fetch("message"))
    assert_match(/remain unchanged/, result.fetch("message"))
    assert_empty launches
  end

  def test_missing_pi_session_file_is_rejected_with_the_preserved_record_note
    result = opener.open(
      agent("harness_session_file" => File.join(@session_dir, "gone.jsonl"), "harness_session_id" => "sess-1")
    )

    assert_equal "rejected", result.fetch("status")
    assert_match(/saved session file is missing/, result.fetch("message"))
    assert_match(/The saved Meringue agent record, logs, and any captured agent output remain unchanged/,
                 result.fetch("message"))
    assert_empty launches
  end

  def test_malformed_pi_session_file_is_rejected_without_launching
    path = File.join(@session_dir, "broken.jsonl")
    File.write(path, "{not json\n")

    result = opener.open(agent("harness_session_file" => path))

    assert_equal "rejected", result.fetch("status")
    assert_match(/malformed/, result.fetch("message"))
    assert_match(/line 1 is invalid JSON/, result.fetch("message"))
    assert_empty launches
  end

  def test_empty_and_headerless_pi_session_files_are_rejected
    empty = File.join(@session_dir, "empty.jsonl")
    File.write(empty, "")
    headerless = File.join(@session_dir, "headerless.jsonl")
    File.write(headerless, "#{JSON.generate("type" => "message", "id" => "m1")}\n")

    assert_match(/the file is empty/, opener.open(agent("harness_session_file" => empty)).fetch("message"))
    assert_match(/first record is not an agent session header/,
                 opener.open(agent("harness_session_file" => headerless)).fetch("message"))
    assert_empty launches
  end

  def test_pi_session_file_with_a_mismatched_session_id_is_rejected
    path = pi_session_file(@session_dir, session_id: "sess-other")

    result = opener.open(agent("harness_session_file" => path, "harness_session_id" => "sess-1"))

    assert_equal "rejected", result.fetch("status")
    assert_match(/does not match "sess-1"/, result.fetch("message"))
    assert_empty launches
  end

  def test_claude_and_antigravity_launch_commands
    claude = opener(commands: { "claude" => "claude" }).open(
      { "id" => "P1-I1-W2", "harness" => "claude", "workspace_path" => tmpdir, "harness_session_id" => "claude-1" }
    )
    assert_equal "opened", claude.fetch("status")
    assert_equal ["--working-directory", tmpdir, "-e", "claude", "--resume", "claude-1"], launches.fetch(0)

    antigravity = opener(commands: { "antigravity" => "agy" }).open(
      { "id" => "P1-I1-W3", "harness" => "antigravity", "workspace_path" => tmpdir }
    )
    assert_equal "opened", antigravity.fetch("status")
    assert_equal ["--working-directory", tmpdir, "-e", "agy", "--continue"], launches.fetch(1)
  end

  def test_claude_agent_without_a_session_id_is_rejected
    result = opener.open({ "id" => "P1-I1-W2", "harness" => "claude", "workspace_path" => tmpdir })

    assert_equal "rejected", result.fetch("status")
    assert_match(/has no saved Claude session to open/, result.fetch("message"))
    assert_empty launches
  end

  def test_missing_workspace_is_rejected_before_launching
    result = opener.open(
      agent("workspace_path" => File.join(tmpdir, "deleted-workspace"),
            "harness_session_file" => pi_session_file(@session_dir, session_id: "sess-1"))
    )

    assert_equal "rejected", result.fetch("status")
    assert_match(/workspace is missing/, result.fetch("message"))
    assert_empty launches
  end

  def test_missing_alacritty_executable_is_reported_as_a_failure
    result = opener(alacritty: File.join(tmpdir, "no-such-alacritty")).open(
      agent("harness_session_file" => pi_session_file(@session_dir, session_id: "sess-1"))
    )

    assert_equal "failed", result.fetch("status")
    assert_match(/alacritty executable was not found or is not executable/, result.fetch("message"))
    assert_match(/MERINGUE_ALACRITTY_COMMAND/, result.fetch("message"))
    assert_empty launches
  end

  def test_alacritty_failure_exit_is_reported_as_a_failure
    failing = write_alacritty_stub(exit_code: 1, name: "alacritty_failing.rb")

    result = opener(alacritty: failing).open(
      agent("harness_session_file" => pi_session_file(@session_dir, session_id: "sess-1"))
    )

    assert_equal "failed", result.fetch("status")
    assert_match(/process exited with status 1/, result.fetch("message"))
    assert_equal 1, launches.length
  end
end
