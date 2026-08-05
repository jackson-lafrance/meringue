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

  # Heads are prompted from this document, so a capability the kernel has but the contract does
  # not describe is a capability no head will ever use.
  def test_head_contract_describes_both_goal_judges
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, '`"reviewer"`'
    assert_includes contract, '"judge": { "mode": "reviewer" }'
    assert_includes contract, "Do not invent a fake metric"
    assert_includes contract, "the kernel rejects a reviewer-judged goal that has one"
    assert_includes contract, "Running out of iterations without approval is a normal, reported outcome"
    refute_includes contract, '`judge.mode` only supports `"metric_only"` today'
  end

  # A prune landing mid-flight used to be reported to the head as an invented issue id. The head
  # contract and the routing rules must describe what the kernel actually does now, in lockstep.
  def test_head_contract_explains_a_target_removed_while_routing
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "### When your target is pruned or killed while you are routing"
    assert_includes contract, "issue_removed_before_head_result_applied"
    assert_includes contract, "Visibility is decided from the head's recorded spawn snapshot, never from \"does this issue exist right now\""
    assert_includes contract, "skipped rather than rejected"
    assert_includes contract, "Dropped issue update (status → completed, description)."
  end

  def test_head_contract_forbids_polling_handoff_prompts
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "The kernel owns the wait."
    assert_includes contract, "Never write a prompt that makes a worker wait by polling"
    assert_includes contract, "~/.meringue/state.json"
    assert_includes contract, "no multi-hour wait budgets"
  end

  # A successor continuing a predecessor's work shares its worktree. A head that still believes
  # every worker gets its own checkout writes prompts that copy work between directories.
  def test_head_contract_explains_worktree_sharing_between_related_workers
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "### Sharing one worktree between related workers"
    assert_includes contract, "**keeps working in that predecessor's worktree and branch**"
    assert_includes contract, "#### When the kernel refuses to share"
    assert_includes contract, "Two live harness sessions must never write one worktree."
    assert_includes contract, "A dirty worktree is *not* a refusal reason"
    assert_includes contract, "reuse_workspace_of_agent_id"
    assert_includes contract, "reuse_workspace_from_command"
    assert_includes contract, '`share_workspace: false` opts a continuation worker out'
    assert_includes contract, "update that pull request rather than open a second one"
    refute_includes contract, "Both workers stay in their own kernel-assigned workspace."
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

  # Heads read this file to decide between a one-shot worker and a goal loop, and the two
  # CreateGoal forms have to be documented where the head actually looks.
  def test_head_contract_explains_when_a_critical_request_is_a_goal_loop
    contract = File.read(FoundationSupport.repo_path("docs", "head_agent_kernel_commands.md"))

    assert_includes contract, "#### Recognising a goal-loop request"
    assert_includes contract, "#### Two forms: an existing issue, or a prompt"
    assert_includes contract, "Urgency on its own is not a goal loop."
    assert_includes contract, "the kernel mints the issue and attaches the goal to it in one command"
    assert_includes contract, "`project_ambiguous`"
    assert_includes contract, "drive it to done"
  end

  def test_goal_loop_doc_documents_both_creation_forms
    guide = File.read(FoundationSupport.repo_path("docs", "goal_loops.md"))

    assert_includes guide, "## Creating a goal"
    assert_includes guide, "/goal create \""
    assert_includes guide, "--project"
    assert_includes guide, "never leaves an orphan issue behind"
  end

  def test_testing_guide_documents_how_to_run_the_suite
    guide = File.read(FoundationSupport.repo_path("docs", "testing.md"))

    assert_includes guide, "rake test"
    assert_includes guide, "ruby -Ilib -Itest test/"
    assert_includes guide, "--name"
    assert_includes guide, "Not covered"
  end

  def test_commit_authorship_policy_is_documented_and_audited
    guide = File.read(FoundationSupport.repo_path("docs", "commit-authorship.md"))

    assert_includes guide, "Meringue must never be the author"
    assert_includes guide, "user.name"
    assert_includes guide, "Author identity unknown"
    assert_includes guide, "PR #175"
    assert_includes guide, "No other safe unmerged Meringue-authored commit"
  end
end
