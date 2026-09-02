# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"
require "support/workspace_support"

# The kernel introspects the workspace manager's `allocate_worker_workspace` signature so
# it can withhold keywords an older manager does not accept. A manager that wraps the real
# one with `**options` declares no named keywords at all; that must read as "accepts
# everything", not as "accepts nothing", or every worker fails at provisioning with
# missing required keywords.
class KernelWorkersWorkspaceManagerKwargsTest < Minitest::Test
  include WorkspaceSupport
  include KernelWorkersSupport

  class WrappingWorkspaceManager < Meringue::Workspace::FakeManager
    attr_reader :allocations

    def initialize(**options)
      super
      @allocations = []
    end

    def allocate_worker_workspace(**options)
      @allocations << options
      super
    end
  end

  def test_spawn_worker_keeps_required_keywords_for_a_kwargs_only_manager
    manager = WrappingWorkspaceManager.new(root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))

    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    assert_equal 1, manager.allocations.length
    options = manager.allocations.first
    assert_equal File.expand_path(context.fetch("root")), File.expand_path(options.fetch(:project_root))
    assert_equal context.fetch("project_id"), options.fetch(:project_id)
    assert_equal context.fetch("issue_id"), options.fetch(:issue_id)
    assert_equal "P1-I1-W1", options.fetch(:agent_id)
    assert options.key?(:unavailable_paths), "expected unavailable_paths to be passed to a **options manager"

    worker = agent(engine, "P1-I1-W1")
    refute_nil worker
    assert_equal options.fetch(:agent_id), worker.fetch("id")
  end
end
