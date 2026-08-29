# frozen_string_literal: true

require "test_helper"
require "support/supervisor_support"
require "support/harness_support"

# Every transport adapter the supervisor can use must implement the
# harness-agnostic `TransportAdapter` contract, so adding a backend (Claude
# Code, Codex, ...) never reaches into the supervisor or kernel. This is the
# regression that keeps the abstraction honest as new backends are registered.
class SupervisorTransportAdapterContractTest < HarnessIntegrationTest
  Contract = Meringue::Supervisor::TransportAdapter

  REQUIRED_METHODS = %i[
    capabilities transport_key claim release record_for evidence attach prompt abort kill
    get_state streaming? wait_for_settled harness_name
  ].freeze

  def test_fake_adapter_satisfies_the_contract
    assert_adapter_satisfies_contract(Meringue::Supervisor::FakeTransportAdapter.new)
  end

  def test_pi_adapter_satisfies_the_contract
    dir = tmpdir
    stub = write_pi_stub(dir)
    session_dir = File.join(dir, "pi-sessions")
    FileUtils.mkdir_p(session_dir)
    ownership = build_transport_ownership(dir)
    client = Meringue::Harness::PiClient.new(
      command: stub.fetch("command"),
      env: stub.fetch("env"),
      session_dir: session_dir,
      command_timeout: 5,
      event_timeout: 5,
      shutdown_timeout: 1,
      transport_ownership: ownership
    )
    adapter = Meringue::Supervisor::PiAdapter.new(client: client, transport_ownership: ownership)

    assert_adapter_satisfies_contract(adapter)
  ensure
    client&.kill_session("harness" => "pi", "pid" => nil, "cwd" => dir,
                         "session_id" => "cleanup", "session_file" => nil,
                         "is_streaming" => false, "last_event_at" => nil) rescue nil
  end

  def test_all_advertised_harnesses_have_concrete_adapters
    assert_equal Meringue::Supervisor::PiAdapter, Meringue::Supervisor::ADAPTERS.fetch("pi")
    assert_equal Meringue::Supervisor::ClaudeAdapter, Meringue::Supervisor::ADAPTERS.fetch("claude")
    assert_equal Meringue::Supervisor::CodexAdapter, Meringue::Supervisor::ADAPTERS.fetch("codex")

    Meringue::Supervisor::ADAPTERS.each_value do |adapter_class|
      adapter = adapter_class.allocate
      capabilities = adapter_class.instance_method(:capabilities).bind(adapter).call
      assert capabilities.fetch("session_start")
      assert capabilities.fetch("session_lookup")
      assert capabilities.fetch("health_status")
      assert capabilities.fetch("stop")
      assert capabilities.fetch("concurrent_sessions")
    end
  end

  def test_registering_a_new_backend_does_not_require_reworking_the_supervisor
    custom = Class.new do
      include Contract

      def initialize(client: nil, transport_ownership: nil)
        @client = client
        @transport_ownership = transport_ownership
      end

      def harness_name; "demo"; end
      def transport_key(_); "demo-1"; end
      def claim(_, harness_pid:, note: nil); { "pid" => harness_pid, "note" => note }; end
      def release(_, harness_pid: nil); true; end
      def record_for(_); {}; end
      def evidence(_); nil; end
      def attach(ref); ref; end
      def prompt(ref, _, mode:); ref; end
      def abort(ref); ref; end
      def kill(ref); ref; end
      def get_state(ref); ref; end
      def streaming?(_); false; end
      def wait_for_settled(ref, timeout:); [ref]; end
    end

    Meringue::Supervisor.register_adapter("demo", custom)

    assert_equal custom, Meringue::Supervisor::ADAPTERS.fetch("demo")
    adapter = Meringue::Supervisor.adapter_for("demo", client: nil)
    refute_nil adapter
    assert_equal "demo", adapter.harness_name
  ensure
    Meringue::Supervisor::ADAPTERS.delete("demo")
  end

  private

  def assert_adapter_satisfies_contract(adapter)
    assert_kind_of Contract, adapter
    REQUIRED_METHODS.each do |method_name|
      assert_respond_to adapter, method_name,
                        "#{adapter.class} must implement TransportAdapter##{method_name}"
      refute_nil adapter.method(method_name), "#{adapter.class} must expose ##{method_name}"
    end
    # The adapter must not leak backend-specific control flow into the
    # supervisor: harness_name is a string for diagnostics only.
    assert_kind_of String, adapter.harness_name
  end
end
