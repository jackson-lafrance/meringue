# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class HarnessPiWorkspaceTrustTest < Minitest::Test
  Trust = Meringue::Harness::PiWorkspaceTrust

  def test_trust_records_only_the_allocated_workspace
    Dir.mktmpdir do |root|
      workspace = File.join(root, "worker")
      parent = root
      FileUtils.mkdir_p(workspace)
      file = File.join(root, "agent", "trust.json")

      assert Trust.trust!(workspace, file: file)
      assert Trust.trusted?(workspace, file: file)
      refute Trust.trusted?(parent, file: file)
      assert_equal [File.realpath(workspace)], JSON.parse(File.read(file)).keys
    end
  end

  def test_existing_pi_decisions_survive_worker_trust_setup
    Dir.mktmpdir do |root|
      workspace = File.join(root, "worker")
      FileUtils.mkdir_p(workspace)
      file = File.join(root, "agent", "trust.json")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, JSON.generate("/already-trusted" => true))

      Trust.trust!(workspace, file: file)

      decisions = JSON.parse(File.read(file))
      assert_equal true, decisions.fetch("/already-trusted")
      assert_equal true, decisions.fetch(File.realpath(workspace))
    end
  end
end
