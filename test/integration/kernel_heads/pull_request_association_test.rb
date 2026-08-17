# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# A PR URL in a user's request is issue routing metadata. It should be visible on the target issue
# as soon as the head routes the request, independently of worker completion and delivery discovery.
class KernelHeadsPullRequestAssociationTest < KernelHeadsTestCase
  PULL_REQUEST_URL = "https://github.com/acme/demo/pull/42"

  def test_a_linked_pull_request_is_attached_to_a_new_issue_before_worker_completion
    project_id = add_project!
    head_id = spawn_head!("Review #{PULL_REQUEST_URL}/files and fix the failing checks")

    result = apply_head_result(
      head_id,
      head_result(commands: [
        create_issue_command(project_id: project_id, title: "Review linked pull request", command_id: "issue"),
        spawn_worker_command(
          issue_id: nil,
          title: "Review linked pull request",
          prompt: "Review the linked pull request and fix the failing checks.",
          extra: { "issue_from_command" => "issue" }
        )
      ])
    )

    assert_equal [["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result)
    worker = agents(type: "worker").fetch(0)
    assert_equal "working", worker.fetch("status"), "association must not wait for worker completion"
    issue = issues.fetch(0)
    assert_pull_request_association(issue)

    presentation = Meringue::TUI::DeliveryPullRequest.for_id(state, issue.fetch("id"))
    assert Meringue::TUI::DeliveryPullRequest.openable?(presentation)
    assert_equal PULL_REQUEST_URL, presentation.fetch("url")
    # A user-reported link is stored on the issue but is not a kernel-verified
    # delivery PR, so the `/prs` picker does not list it until branch
    # verification promotes it (`matched_by` becomes `workspace_branch`).
    assert_empty Meringue::TUI::OpenPullRequests.entries(state)
  end

  def test_a_linked_pull_request_is_attached_when_continuing_an_existing_issue
    project_id = add_project!
    issue_id = apply_command(
      "CreateIssue",
      { "project_id" => project_id, "title" => "Existing review", "description" => "Review the proposed change." }
    ).fetch("target_id")
    setup_head = spawn_head!("Start the existing review")
    apply_head_result(setup_head, head_result(commands: [spawn_worker_command(issue_id: issue_id)]))
    worker_id = agents(type: "worker").fetch(0).fetch("id")

    head_id = spawn_head!("Please rebase and review #{PULL_REQUEST_URL}?diff=split")
    result = apply_head_result(
      head_id,
      head_result(commands: [{
        "type" => "PromptAgent",
        "payload" => {
          "agent_id" => worker_id,
          "prompt" => "Rebase and review the linked pull request.",
          "mode" => "normal"
        }
      }])
    )

    assert_equal [["PromptAgent", "accepted"]], command_statuses(result)
    assert_equal "working", find_agent_record(worker_id).fetch("status")
    assert_pull_request_association(issues.find { |issue| issue.fetch("id") == issue_id })
  end

  def test_a_new_issue_is_associated_before_a_later_worker_spawn_finishes
    entered = Queue.new
    release = Queue.new
    slow_engine = build_engine(
      harness_client: KernelHeadsSupport::GatedHarnessClient.new(entered: entered, release: release)
    )
    project_id = add_project!(target_engine: slow_engine)
    head_id = spawn_head!("Fix #{PULL_REQUEST_URL}", target_engine: slow_engine)
    batch = head_result(commands: [
      create_issue_command(project_id: project_id, title: "Fix linked pull request", command_id: "issue"),
      spawn_worker_command(issue_id: nil, extra: { "issue_from_command" => "issue" })
    ])

    applier = Thread.new do
      Thread.current.report_on_exception = false
      apply_head_result(head_id, batch, cleanup_head: false, target_engine: slow_engine)
    end
    entered.pop

    in_progress = issues(current_state: slow_engine.list_all).fetch(0)
    assert_pull_request_association(in_progress)
    assert_empty agents(type: "worker", current_state: slow_engine.list_all).select { |agent| agent["harness_session_id"] },
                 "the PR should be attached while worker startup is still blocked"
  ensure
    release << true if defined?(release) && release
    applier&.value
  end

  def test_repeated_links_and_later_delivery_discovery_merge_into_one_record
    project_id = add_project!
    issue_id = apply_command(
      "CreateIssue",
      { "project_id" => project_id, "title" => "Existing review", "description" => "Review the proposed change." }
    ).fetch("target_id")

    first_head = spawn_head!("Fix #{PULL_REQUEST_URL} and compare it with #{PULL_REQUEST_URL}/files")
    apply_head_result(first_head, head_result(commands: [spawn_worker_command(issue_id: issue_id)]))
    worker_id = agents(type: "worker").fetch(0).fetch("id")

    second_head = spawn_head!("Now rebase #{PULL_REQUEST_URL}#discussion_r1")
    apply_head_result(
      second_head,
      head_result(commands: [{
        "type" => "PromptAgent",
        "payload" => { "agent_id" => worker_id, "prompt" => "Rebase it.", "mode" => "normal" }
      }])
    )

    linked = issues.find { |issue| issue.fetch("id") == issue_id }
    assert_equal [PULL_REQUEST_URL], linked.fetch("delivery_pull_requests").map { |record| record.fetch("url") }

    # This is the same merge seam completion-time branch verification uses. Enriching the linked
    # record must preserve one issue association rather than adding a second delivery record.
    Meringue::State::Models.attach_pull_requests_to_issue!(
      linked,
      delivery_pull_requests: [{
        "url" => PULL_REQUEST_URL,
        "state" => "open",
        "matched_by" => "workspace_branch",
        "matched_branch" => "review-pr-42"
      }]
    )

    records = linked.fetch("delivery_pull_requests")
    assert_equal 1, records.length
    assert_equal "open", records.fetch(0).fetch("state")
    assert_equal "workspace_branch", records.fetch(0).fetch("matched_by")
    assert_equal [PULL_REQUEST_URL], linked.fetch("reported_pr_urls")
  end

  private

  def assert_pull_request_association(issue)
    records = issue.fetch("delivery_pull_requests")
    assert_equal 1, records.length
    assert_equal PULL_REQUEST_URL, records.fetch(0).fetch("url")
    assert_equal "user_request", records.fetch(0).fetch("matched_by")
    refute_nil Time.iso8601(records.fetch(0).fetch("associated_at"))
    assert_equal records.fetch(0), issue.fetch("delivery_pull_request")
    assert_equal [PULL_REQUEST_URL], issue.fetch("reported_pr_urls")
  end
end
