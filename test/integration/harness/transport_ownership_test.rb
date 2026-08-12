# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# TransportOwnership is the cross-instance single-writer record: only one
# Meringue instance may hold a harness session's RPC pipes at a time, and a
# takeover is only legitimate when the recorded owner is gone.
class HarnessTransportOwnershipTest < HarnessIntegrationTest
  Ownership = Meringue::Harness::TransportOwnership

  def setup
    super
    @directory = File.join(tmpdir, "transport-locks")
  end

  def ownership(owner_pid: Process.pid, lock_timeout: 1.0)
    Ownership.new(directory: @directory, lock_timeout: lock_timeout, owner_pid: owner_pid)
  end

  def test_claim_writes_a_durable_record_under_the_configured_directory
    owner = ownership

    assert owner.claim("pi-sess-1", pid: 4242, session_id: "sess-1", note: "spawned")

    record = owner.record_for("pi-sess-1")
    assert_equal 4242, record.fetch("pid")
    assert_equal Process.pid, record.fetch("owner_pid")
    assert record.fetch("owner_started_at").to_s.start_with?("20"), "PID reuse protection must be durable"
    assert_equal "sess-1", record.fetch("session_id")
    assert_equal "spawned", record.fetch("note")
    assert record.fetch("updated_at").to_s.start_with?("20")

    assert_equal File.join(@directory, "pi-sess-1.lock"), owner.path_for("pi-sess-1")
    assert File.file?(owner.path_for("pi-sess-1"))
    assert_equal JSON.parse(File.read(owner.path_for("pi-sess-1"))), record
  end

  def test_record_for_unknown_key_is_empty_and_never_raises
    assert_empty ownership.record_for("pi-missing")
  end

  def test_record_for_ignores_corrupt_lock_files
    owner = ownership
    FileUtils.mkdir_p(@directory)
    File.write(owner.path_for("pi-corrupt"), "not json at all")

    assert_empty owner.record_for("pi-corrupt")
  end

  def test_path_for_sanitizes_keys
    owner = ownership

    assert_equal File.join(@directory, "pi-a-b-c.lock"), owner.path_for("pi/a b:c")
    assert_equal File.join(@directory, "unknown.lock"), owner.path_for("   ")
  end

  def test_release_clears_the_owner_and_records_who_released_it
    owner = ownership
    owner.claim("pi-sess-1", pid: 4242, session_id: "sess-1")

    assert owner.release("pi-sess-1", pid: 4242)

    record = owner.record_for("pi-sess-1")
    assert_nil record["owner_pid"]
    assert_nil record["pid"]
    assert_equal Process.pid, record.fetch("released_by")
    assert_equal "sess-1", record.fetch("session_id")
  end

  def test_release_refuses_when_the_recorded_harness_pid_differs
    owner = ownership
    owner.claim("pi-sess-1", pid: 4242, session_id: "sess-1")

    refute owner.release("pi-sess-1", pid: 5555)

    record = owner.record_for("pi-sess-1")
    assert_equal 4242, record.fetch("pid")
    assert_equal Process.pid, record.fetch("owner_pid")
  end

  def test_lease_exposes_recorded_owner_and_harness_pids
    ownership(owner_pid: 111).claim("pi-sess-1", pid: 4242, session_id: "sess-1")

    ownership(owner_pid: 111).with_lease("pi-sess-1") do |lease|
      assert_equal 4242, lease.harness_pid
      assert_equal 111, lease.recorded_owner_pid
      assert lease.owned_by_this_instance?
      assert_equal "pi-sess-1", lease.key
    end

    ownership(owner_pid: 222).with_lease("pi-sess-1") do |lease|
      refute lease.owned_by_this_instance?, "another instance must not think it owns the transport"
      assert_equal 111, lease.recorded_owner_pid
    end
  end

  def test_lease_handles_missing_and_unparseable_pids
    owner = ownership
    FileUtils.mkdir_p(@directory)
    File.write(owner.path_for("pi-weird"), JSON.generate("pid" => "abc", "owner_pid" => "xyz"))

    owner.with_lease("pi-weird") do |lease|
      assert_nil lease.harness_pid
      assert_nil lease.recorded_owner_pid
    end

    owner.with_lease("pi-empty") do |lease|
      assert_nil lease.harness_pid
      assert_nil lease.recorded_owner_pid
      refute lease.owned_by_this_instance?
    end
  end

  def test_a_second_instance_cannot_hold_the_same_lease_concurrently
    first = ownership(lock_timeout: 0.05)
    second = ownership(owner_pid: 999, lock_timeout: 0.05)

    first.with_lease("pi-sess-1") do
      assert_raises(Ownership::LockTimeout) { second.with_lease("pi-sess-1") { flunk "should not acquire" } }
      # A different session key is independent.
      second.with_lease("pi-sess-2") { |lease| assert_nil lease.harness_pid }
    end

    # Once released, the other instance can take the lock over.
    second.with_lease("pi-sess-1") { |lease| lease.claim!(pid: 77, session_id: "sess-1") }
    assert_equal 999, second.record_for("pi-sess-1").fetch("owner_pid")
  end

  def test_claim_and_release_return_false_instead_of_raising_on_lock_timeout
    first = ownership(lock_timeout: 0.05)
    second = ownership(owner_pid: 999, lock_timeout: 0.05)

    first.with_lease("pi-sess-1") do
      refute second.claim("pi-sess-1", pid: 1)
      refute second.release("pi-sess-1", pid: 1)
    end
  end

  def test_lease_changes_are_flushed_only_when_dirty
    owner = ownership
    owner.with_lease("pi-sess-1") { |lease| refute lease.flush! }
    assert_empty owner.record_for("pi-sess-1")

    owner.with_lease("pi-sess-1") { |lease| lease.claim!(pid: 5, session_id: "sess-1", note: "resumed") }
    assert_equal 5, owner.record_for("pi-sess-1").fetch("pid")
    assert_equal "resumed", owner.record_for("pi-sess-1").fetch("note")
  end

  def test_default_directory_is_not_touched_by_these_tests
    assert_equal File.expand_path(@directory), ownership.directory
    refute_equal Ownership::DEFAULT_DIRECTORY, ownership.directory
  end
end
