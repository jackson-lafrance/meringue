# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"

# Helpers for exercising the interactive PTY transport for real, without a vendor CLI.
#
# These tests drive an actual pseudo-terminal running test/fixtures/fake_interactive_agent.rb, so
# they cover the parts that only fail in a real terminal: bracketed paste, the interrupt key, screen
# rendering, and a transcript that appears while the process runs. Nothing here reaches the network
# or writes outside a temporary directory.
module InteractiveAgentSupport
  FAKE_AGENT = File.expand_path("../fixtures/fake_interactive_agent.rb", __dir__)

  # A backend built on the shared interactive transport, standing in for a real provider. It is
  # deliberately thin: everything it does not override is the behaviour every interactive backend
  # inherits, which is what these tests are checking.
  class FakeInteractiveClient < Meringue::Harness::InteractiveClient
    attr_reader :transcript_dir, :agent_flags

    def initialize(transcript_dir:, agent_flags: [], **kwargs)
      @transcript_dir = transcript_dir
      @agent_flags = agent_flags
      super(
        harness_name: "fake-interactive",
        command: [RbConfig.ruby, FAKE_AGENT],
        transcript_schema: Meringue::Harness::ClaudeTranscript,
        **kwargs
      )
    end

    def prepared_workspaces
      @prepared_workspaces ||= []
    end

    protected

    def spawn_argv(kind:, cwd:, session_id:, system_prompt:, session_name:, session_settings:)
      _ = [kind, cwd, system_prompt, session_name, session_settings]
      command_argv + ["--session-id", session_id.to_s, "--transcript-dir", transcript_dir] + agent_flags + extra_args
    end

    def resume_argv(session_ref)
      command_argv + [
        "--resume", (session_ref["session_id"] || session_ref[:session_id]).to_s,
        "--transcript-dir", transcript_dir
      ] + agent_flags + extra_args
    end

    def transcript_path(cwd:, session_id:)
      _ = cwd
      return nil unless session_id && !session_id.to_s.empty?

      File.join(transcript_dir, "#{session_id}.jsonl")
    end

    def prepare_workspace!(cwd)
      prepared_workspaces << cwd
    end

    # The fake agent draws "❯" once its prompt box is usable, the same signal a real CLI gives.
    def wait_until_ready(process)
      !process.wait_for_screen(timeout: ready_timeout) { |text| text.include?("❯") }.nil?
    end
  end

  def interactive_root
    @interactive_root ||= Dir.mktmpdir("meringue-interactive")
  end

  def interactive_workspace(name = "workspace")
    path = File.join(interactive_root, name)
    FileUtils.mkdir_p(path)
    path
  end

  def interactive_transcript_dir
    path = File.join(interactive_root, "transcripts")
    FileUtils.mkdir_p(path)
    path
  end

  def build_interactive_client(agent_flags: [], **kwargs)
    client = FakeInteractiveClient.new(
      transcript_dir: interactive_transcript_dir,
      agent_flags: agent_flags,
      ready_timeout: 20,
      **kwargs
    )
    interactive_clients << client
    client
  end

  def interactive_clients
    @interactive_clients ||= []
  end

  # Polls the way the kernel does: drain events, then ask for state.
  def wait_until_settled(client, session_ref, timeout: 20)
    deadline = Time.now + timeout
    state = session_ref
    loop do
      client.read_events(state)
      state = client.get_state(state)
      return state unless state.fetch("is_streaming", false)
      flunk("session did not settle within #{timeout}s") if Time.now > deadline

      sleep 0.1
    end
  end

  def wait_until(timeout: 10, message: "condition was never met")
    deadline = Time.now + timeout
    loop do
      value = yield
      return value if value
      flunk(message) if Time.now > deadline

      sleep 0.05
    end
  end

  def teardown_interactive
    interactive_clients.each do |client|
      client.shutdown
    rescue StandardError
      nil
    end
    FileUtils.remove_entry(@interactive_root) if @interactive_root && Dir.exist?(@interactive_root)
    @interactive_root = nil
  end
end

class InteractiveAgentTest < Minitest::Test
  include InteractiveAgentSupport

  def teardown
    teardown_interactive
    super
  end
end
