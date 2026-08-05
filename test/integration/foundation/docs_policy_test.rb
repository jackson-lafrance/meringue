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

  def test_agents_md_keeps_one_durable_goal_on_one_issue
    agents = File.read(FoundationSupport.repo_path("AGENTS.md"))

    assert_includes agents, "One durable goal is one issue, even when it needs several sequential steps."
    assert_includes agents, "belong on the same issue as two workers"
    assert_includes agents, "Deliverables do not define issues"
    assert_includes agents, "Needing to run second does not make a step its own goal"
    assert_includes agents, "Never instruct a worker to poll"
  end

  # docs/head_agent_kernel_commands.md is appended to every head system prompt, so the guidance a
  # head reads is part of the contract too.
  def test_head_contract_pairs_research_and_implementation_on_one_issue
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "## One goal, two steps: research then implementation"
    assert_includes contract, "**one issue with two workers**"
    assert_includes contract, "### When two issues really are correct"
    assert_includes contract, "follow_up_of_command"
    assert_includes contract, '"issue_from_command": "goal"'
    assert_includes contract, "Deliverables do not define issues."
    assert_includes contract, '"At least one" is a floor, not a cap'
  end

  # The worked example must use the shipped sequencing field, and the queueing section must not
  # re-open the door to splitting one goal across two issues.
  def test_head_contract_orders_the_pair_with_the_deferred_spawn_field
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, '"after_from_command": "research"'
    assert_includes contract, "### Chaining a worker after another agent"
    assert_includes contract, "Sequencing is not scoping"
    assert_includes contract, "needing to run second never turns a step into its own durable goal"
    refute_includes contract, 'That is the normal shape for "research issue, then implementation issue"'
  end

  def test_head_contract_forbids_polling_handoff_prompts
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "The kernel owns the wait."
    assert_includes contract, "Never write a prompt that makes a worker wait by polling"
    assert_includes contract, "~/.meringue/state.json"
    assert_includes contract, "no multi-hour wait budgets"
  end

  # Project labels regressed to "Meringue working" because a lifecycle status leaked into
  # the name. The contract heads read must state that a status is never part of a name.
  def test_head_contract_keeps_lifecycle_statuses_out_of_project_names
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "#### Project naming contract"
    assert_includes contract, "A project name never contains a lifecycle status."
    assert_includes contract, '"Meringue working"'
    assert_includes contract, "it strips a trailing lifecycle status from any project name it stores"
  end

  def test_testing_guide_documents_how_to_run_the_suite
    guide = File.read(FoundationSupport.repo_path("docs", "testing.md"))

    assert_includes guide, "rake test"
    assert_includes guide, "ruby -Ilib -Itest test/"
    assert_includes guide, "--name"
    assert_includes guide, "Not covered"
  end
end
