# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The kernel only ever talks to a harness through Harness::Client. Every backend
# must therefore expose the same methods, the same call signatures, and the same
# session-ref shape, so nothing Pi-specific leaks into the kernel or the TUI.
class HarnessClientContractTest < HarnessIntegrationTest
  Harness = Meringue::Harness

  CLIENT_CLASSES = [
    Harness::FakeClient,
    Harness::PiClient,
    Harness::ClaudeClient,
    Harness::ClaudeCodeClient,
    Harness::AntigravityClient
  ].freeze

  def test_base_client_requires_every_contract_method
    client = Harness::Client.new

    error = assert_raises(NotImplementedError) do
      client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "p", system_prompt: nil, session_name: "n")
    end
    assert_match(/must implement #spawn_session/, error.message)

    assert_raises(NotImplementedError) { client.prompt_session({}, "p") }
    assert_raises(NotImplementedError) { client.abort_session({}) }
    assert_raises(NotImplementedError) { client.kill_session({}) }
    assert_raises(NotImplementedError) { client.get_state({}) }
    assert_raises(NotImplementedError) { client.read_events({}) }
    assert_raises(NotImplementedError) { client.attach_session({}) }
  end

  def test_every_client_implements_the_contract_with_identical_signatures
    CLIENT_CLASSES.each do |klass|
      assert_operator klass, :<, Harness::Client

      HarnessSupport::HARNESS_CLIENT_METHODS.each do |method|
        assert klass.public_method_defined?(method), "#{klass} does not implement ##{method}"
        assert_equal normalized_parameters(Harness::Client, method),
                     normalized_parameters(klass, method),
                     "#{klass}##{method} signature drifted from the harness contract"
        refute_equal Harness::Client.instance_method(method),
                     klass.instance_method(method),
                     "#{klass}##{method} must override the abstract contract method"
      end

      assert klass.public_method_defined?(:open_session_view)
      assert klass.public_method_defined?(:harness_name)
    end
  end

  # `session_progress` is a defaulted contract method rather than an abstract one: a backend that
  # cannot describe its own mid-work activity answers "no progress" and everything else keeps
  # working. Every client must still accept the same one-argument shape, because the kernel calls
  # it with the event array it already drained.
  def test_every_client_answers_the_session_progress_contract
    CLIENT_CLASSES.each do |klass|
      assert klass.public_method_defined?(:session_progress), "#{klass} does not answer #session_progress"
      assert_equal normalized_parameters(Harness::Client, :session_progress),
                   normalized_parameters(klass, :session_progress),
                   "#{klass}#session_progress signature drifted from the harness contract"
    end

    assert_empty Harness::Client.new.session_progress([{ "type" => "message_end" }])
    assert_empty Harness::FakeClient.new.session_progress([{ "type" => "message_end" }])
  end

  def test_prompt_session_accepts_the_shared_mode_keyword
    CLIENT_CLASSES.each do |klass|
      modes = klass.instance_method(:prompt_session).parameters
      assert_includes modes, [:key, :mode], "#{klass}#prompt_session must accept mode:"
    end
  end

  def test_harness_names_are_stable_public_identifiers
    assert_equal "fake", Harness::FakeClient.new.harness_name
    assert_equal "pi", Harness::PiClient.new.harness_name
    assert_equal "claude", Harness::ClaudeClient.new(claude_home: tmpdir).harness_name
    assert_equal "claude", Harness::ClaudeCodeClient.new(claude_home: tmpdir).harness_name
    assert_equal "antigravity", Harness::AntigravityClient.new.harness_name
  end

  def test_fake_pi_and_process_clients_agree_on_the_session_ref_shape
    refs = { "fake" => fake_ref, "pi" => pi_ref, "claude" => claude_ref, "antigravity" => antigravity_ref }

    refs.each do |harness, ref|
      assert_kind_of Hash, ref
      HarnessSupport::REQUIRED_SESSION_REF_KEYS.each do |key|
        assert ref.key?(key), "#{harness} session ref is missing #{key}"
      end
      assert_equal harness, ref.fetch("harness")
      assert_equal tmpdir, ref.fetch("cwd")
      assert_includes [true, false], ref.fetch("is_streaming")
      assert_kind_of Hash, ref.fetch("metadata")
      assert_equal "Task", ref.fetch("metadata").fetch("session_name")
    end

    # Documented difference: only the process-backed clients record the agent
    # kind in metadata (see test/findings/harness.md).
    assert_equal "worker", refs.fetch("pi").fetch("metadata").fetch("kind")
    assert_equal "worker", refs.fetch("claude").fetch("metadata").fetch("kind")
    assert_equal "worker", refs.fetch("antigravity").fetch("metadata").fetch("kind")
    refute refs.fetch("fake").fetch("metadata").key?("kind")

    shapes = refs.values.map { |ref| (ref.keys & HarnessSupport::REQUIRED_SESSION_REF_KEYS).sort }
    assert_equal 1, shapes.uniq.length, "every harness must expose the same session ref keys: #{shapes.inspect}"
  end

  def test_read_events_and_get_state_return_harness_neutral_types
    [fake_client_and_ref, pi_client_and_ref, claude_client_and_ref].each do |client, ref|
      assert_kind_of Array, client.read_events(ref)
      state = client.get_state(ref)
      assert_kind_of Hash, state
      assert_equal client.harness_name, state.fetch("harness")
      assert_includes [true, false], state.fetch("is_streaming")
    end
  end

  def test_open_session_view_returns_a_read_only_handle_for_every_harness
    [fake_client_and_ref, pi_client_and_ref, claude_client_and_ref].each do |client, ref|
      handle = client.open_session_view(ref)

      assert_kind_of Harness::SessionView::Handle, handle
      snapshot = handle.snapshot
      assert_includes Harness::SessionView::AVAILABILITIES, snapshot.fetch("availability")
      assert_includes Harness::SessionView::SESSION_STATES, snapshot.fetch("session_state")
      assert_kind_of Array, snapshot.fetch("items")
      assert_kind_of Hash, snapshot.fetch("capabilities")
      %w[live_events prompt steer follow_up abort].each { |key| assert snapshot.fetch("capabilities").key?(key) }
      assert_kind_of Hash, handle.poll_events
      refute_respond_to handle, :kill_session
      refute_respond_to handle, :attach_session
    end
  end

  def test_fake_client_round_trips_the_contract_without_any_process
    client = Harness::FakeClient.new

    ref = client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it", system_prompt: "sys",
                               session_name: "Fix login redirect")
    assert_equal "fake-worker-session", ref.fetch("session_id")
    assert_nil ref.fetch("pid")
    assert_nil ref.fetch("session_file")
    assert_equal "do it", ref.fetch("metadata").fetch("prompt")
    assert_equal "sys", ref.fetch("metadata").fetch("system_prompt")
    assert_equal "Fix login redirect", ref.fetch("metadata").fetch("session_name")

    prompted = client.prompt_session(ref, "next", mode: "steer")
    assert_equal "next", prompted.fetch("last_prompt")
    assert_equal "steer", prompted.fetch("last_prompt_mode")
    assert_equal false, prompted.fetch("is_streaming")

    assert_equal false, client.abort_session(prompted).fetch("is_streaming")
    assert_equal true, client.kill_session(prompted).fetch("killed")
    assert_equal prompted, client.get_state(prompted)
    assert_equal prompted, client.attach_session(prompted)
    assert_empty client.read_events(prompted)
  end

  def test_transient_session_errors_are_identified_through_the_shared_module
    assert Harness.transient_session_error?(Harness::PiClient::SessionBusyError.new("busy"))
    refute Harness.transient_session_error?(StandardError.new("boom"))
    refute Harness.transient_session_error?(Harness::ProcessClient::InvalidModeError.new("nope"))

    custom = Class.new(StandardError) { include Harness::TransientSessionError }
    assert custom.new("later").transient?
    assert Harness.transient_session_error?(custom.new("later"))
  end

  private

  # Unused parameters are conventionally underscore-prefixed, which is not part
  # of the contract.
  def normalized_parameters(klass, method)
    klass.instance_method(method).parameters.map do |(type, name)|
      [type, name.to_s.delete_prefix("_")]
    end
  end

  def fake_client_and_ref
    client = Harness::FakeClient.new
    [client, fake_ref(client)]
  end

  def fake_ref(client = Harness::FakeClient.new)
    client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "", system_prompt: nil, session_name: "Task")
  end

  def pi_client_and_ref
    @pi_client_and_ref ||= begin
      client, = build_pi_client(tmpdir, stub_config: { "session_id" => "sess-contract" })
      ref = track_session(client, client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "",
                                                       system_prompt: nil, session_name: "Task"))
      [client, ref]
    end
  end

  def pi_ref
    pi_client_and_ref.last
  end

  def claude_client_and_ref
    @claude_client_and_ref ||= begin
      stub = write_process_stub(
        tmpdir,
        { "stdout_lines" => [{ "type" => "result", "result" => "done" }], "sleep" => 0.3 },
        name: "claude_contract_stub.rb"
      )
      client = Harness::ClaudeCodeClient.new(command: stub.fetch("command"), env: stub.fetch("env"),
                                             claude_home: File.join(tmpdir, "claude-home"), shutdown_timeout: 1)
      ref = track_session(client, client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it",
                                                       system_prompt: nil, session_name: "Task"))
      [client, ref]
    end
  end

  def claude_ref
    claude_client_and_ref.last
  end

  def antigravity_ref
    stub = write_process_stub(
      tmpdir,
      { "stdout_lines" => [{ "type" => "result", "result" => "done" }], "sleep" => 0.3 },
      name: "agy_contract_stub.rb"
    )
    client = Harness::AntigravityClient.new(command: stub.fetch("command"), env: stub.fetch("env"),
                                            shutdown_timeout: 1)
    track_session(client, client.spawn_session(kind: "worker", cwd: tmpdir, prompt: "do it",
                                               system_prompt: nil, session_name: "Task"))
  end
end
