# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# Isolation evidence became part of the project record, but nothing wrote it onto the
# projects that were registered before it existed. Those records read as "isolation
# unavailable" and every worker they owned was refused a workspace, on installs that
# had been working. Reconciliation re-probes them.
class KernelCoreProjectVersionControlBackfillTest < Minitest::Test
  include KernelCoreSupport

  # Records what it was asked, so a test can prove the probe is not repeated on every
  # 2-second reconciliation pass.
  class RecordingBackend < Meringue::VersionControl::Backend
    attr_reader :probes

    def initialize(isolated: true)
      @isolated = isolated
      @probes = []
    end

    def id = "github_git"

    def inspect_project(root_path:)
      @probes << root_path
      {
        "available" => @isolated,
        "backend" => id,
        "repository_identity" => "git@github.com:example/app.git",
        "capabilities" => { "isolated_workspaces" => @isolated, "mutable_workspace" => @isolated },
        "diagnostics" => @isolated ? [] : ["github_origin_missing"],
        "diagnostic_at" => Time.now.utc.iso8601
      }
    end
  end

  def test_a_project_recorded_before_the_isolation_contract_regains_its_evidence
    backend = RecordingBackend.new
    engine = build_engine(version_control_backend: backend)
    path = record_legacy_project!

    assert_accepted(reconcile(engine))

    project = persisted_projects.fetch(0)
    assert_equal [path], backend.probes
    assert_equal "github_git", project.fetch("version_control_backend")
    assert_equal "git@github.com:example/app.git", project.fetch("version_control_repository_identity")
    assert_equal true, project.fetch("version_control_capabilities").fetch("isolated_workspaces")
    assert_iso8601(project.fetch("version_control_diagnostic_at"), "version_control_diagnostic_at")
    assert_includes log_messages, "Recorded isolated-workspace evidence for project P1."
  end

  def test_a_project_that_already_proves_isolation_is_never_reprobed
    backend = RecordingBackend.new
    engine = build_engine(version_control_backend: backend)
    record_legacy_project!

    assert_accepted(reconcile(engine))
    assert_accepted(reconcile(engine))

    assert_equal 1, backend.probes.length
    assert_equal 1, log_messages.count("Recorded isolated-workspace evidence for project P1.")
  end

  # A project the backend still cannot back keeps its recorded verdict and is retried
  # on the reprobe cadence rather than on every pass, because the probe shells out to git.
  def test_a_project_the_backend_cannot_back_is_recorded_quietly_and_throttled
    backend = RecordingBackend.new(isolated: false)
    engine = build_engine(version_control_backend: backend)
    record_legacy_project!

    assert_accepted(reconcile(engine))
    assert_accepted(reconcile(engine))

    assert_equal 1, backend.probes.length
    project = persisted_projects.fetch(0)
    assert_equal false, project.fetch("version_control_capabilities").fetch("isolated_workspaces")
    refute_includes log_messages, "Recorded isolated-workspace evidence for project P1."
  end

  private

  def reconcile(engine)
    engine.apply({ "type" => "ReconcileSessions", "payload" => {} })
  end

  # A project exactly as an older Meringue wrote it: no version-control keys at all.
  def record_legacy_project!(name: "legacy")
    path = make_project_dir(name)
    now = Time.now.utc.iso8601
    state = store.load
    state.fetch("projects") << {
      "id" => "P1",
      "name" => "Legacy",
      "root_path" => path,
      "status" => "working",
      "created_at" => now,
      "updated_at" => now
    }
    state.fetch("counters")["projects"] = 1
    store.save(state)
    path
  end
end
