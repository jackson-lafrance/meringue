# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# The test policy and testing guide are part of the contract agents follow, so
# they are checked like code.
class FoundationDocsPolicyTest < Minitest::Test
  def test_agents_md_allows_and_expects_tests
    agents = File.read(FoundationSupport.repo_path("AGENTS.md"))

    assert_includes agents, "### Test file policy"
    refute_includes agents, "Agents must never write test files"
    assert_includes agents, "rake test"
    assert_includes agents, "test/integration/"
    assert_includes agents, 'require "test_helper"'
    assert_includes agents, "docs/testing.md"
  end

  def test_agents_md_keeps_the_branch_worktree_and_pr_workflow
    agents = File.read(FoundationSupport.repo_path("AGENTS.md"))

    assert_includes agents, "### Branch, worktree, and PR workflow"
    assert_includes agents, "#### Standing approval for agent git workflow"
    assert_includes agents, "git worktree add -b <branch>"
  end

  def test_testing_guide_documents_how_to_run_the_suite
    guide = File.read(FoundationSupport.repo_path("docs", "testing.md"))

    assert_includes guide, "rake test"
    assert_includes guide, "ruby -Ilib -Itest test/"
    assert_includes guide, "--name"
    assert_includes guide, "Not covered"
  end
end
