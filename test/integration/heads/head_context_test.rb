# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

# Covers the snapshot handed to a head agent: what it must contain for routing,
# what it must never contain (harness transcripts and secrets), and how question
# context is surfaced when a head is answering a question.
class HeadContextTest < Minitest::Test
  include HeadsSupport

  SECRET_PATTERN = /SECRET_[A-Z_]+|sk-SECRET/

  def test_prompt_payload_exposes_routing_sections_and_user_message
    context = build_head_context(user_message: "keep the existing branch please")
    payload = context.to_prompt_h

    assert_equal(
      %w[head_id user_message question_id cwd state_access project_discovery
         current_state_summary routing_context kernel_command_reference],
      payload.keys
    )
    assert_equal "H8", payload.fetch("head_id")
    assert_equal "keep the existing branch please", payload.fetch("user_message")
    assert_equal(
      %w[purpose explicit_references question_being_answered issue_candidates
         worker_candidates recent_activity decision_rules],
      payload.fetch("routing_context").keys
    )
    refute_empty payload.fetch("routing_context").fetch("decision_rules")
  end

  def test_state_summary_counts_projects_issues_agents_and_open_questions
    summary = build_head_context.to_prompt_h.fetch("current_state_summary")

    assert_equal 1, summary.fetch("project_count")
    assert_equal 2, summary.fetch("issue_count")
    assert_equal 2, summary.fetch("agent_count")
    assert_equal 2, summary.fetch("open_question_count")
    assert_equal 1, summary.fetch("active_head_count")
    assert_equal 1, summary.fetch("active_worker_count")
    assert_equal({ "idle" => 1, "working" => 1 }, summary.fetch("status_counts"))
    assert_equal ["P1"], summary.fetch("registered_projects").map { |project| project.fetch("id") }
  end

  def test_answered_questions_are_not_counted_as_open
    summary = build_head_context(snapshot: head_snapshot(question_status: "answered"))
                .to_prompt_h.fetch("current_state_summary")

    assert_equal 0, summary.fetch("open_question_count")
  end

  # Current behaviour: heads receive only a count of open questions. Recorded in
  # test/findings/heads.md because implicit-answer inference needs the records.
  def test_open_questions_are_only_surfaced_as_a_count
    payload = build_head_context.to_prompt_h

    assert_equal 2, payload.dig("current_state_summary", "open_question_count")
    refute_includes payload.fetch("routing_context").keys, "open_questions"
    refute_includes payload.fetch("current_state_summary").keys, "open_questions"
    refute_includes JSON.generate(payload.fetch("current_state_summary")),
                    "Should the worker keep the existing branch"
  end

  def test_issue_candidates_carry_routing_metadata
    candidates = build_head_context.to_prompt_h.dig("routing_context", "issue_candidates")
    issue = candidates.find { |candidate| candidate.fetch("id") == "P1-I1" }

    assert_equal %w[P1-I1 P1-I2], candidates.map { |candidate| candidate.fetch("id") }.sort
    assert_equal "P1", issue.fetch("project_id")
    assert_equal "Add question answering", issue.fetch("title")
    assert_equal ["P1-I1-W1"], issue.fetch("agent_ids")
    assert_equal "P1-I1-W1", issue.fetch("latest_agent_id")
    assert issue.fetch("has_delivery_pull_request")
    refute build_head_context.to_prompt_h.dig("routing_context", "issue_candidates")
             .find { |candidate| candidate.fetch("id") == "P1-I2" }
             .fetch("has_delivery_pull_request")
  end

  def test_worker_candidates_carry_session_metadata_and_prompt_modes
    workers = build_head_context.to_prompt_h.dig("routing_context", "worker_candidates")

    assert_equal 1, workers.length
    worker = workers.first
    assert_equal "P1-I1-W1", worker.fetch("id")
    assert_equal "pi", worker.fetch("harness")
    assert_equal "pi-session-1", worker.fetch("harness_session_id")
    assert worker.fetch("session_available")
    assert worker.fetch("resumable")
    refute worker.fetch("is_streaming")
    assert_equal ["normal"], worker.fetch("supported_prompt_modes_now")
    assert_equal "normal", worker.fetch("recommended_prompt_mode")
    assert_equal 2, worker.fetch("prompt_count")
    assert_in_delta 0.25, worker.fetch("context_utilization")
    assert_equal "I updated the engine and added logging.", worker.fetch("last_result")
    assert worker.fetch("has_delivery_pull_request")
  end

  def test_streaming_pi_worker_supports_steer_and_follow_up
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker.fetch("harness_metadata")["is_streaming"] = true

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first

    assert candidate.fetch("is_streaming")
    assert_equal %w[steer follow_up], candidate.fetch("supported_prompt_modes_now")
    assert_equal "follow_up", candidate.fetch("recommended_prompt_mode")
  end

  def test_killed_worker_is_not_resumable_and_has_no_prompt_modes
    snapshot = head_snapshot
    snapshot.fetch("agents").first["status"] = "killed"

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first

    refute candidate.fetch("resumable")
    assert_empty candidate.fetch("supported_prompt_modes_now")
    refute candidate.key?("recommended_prompt_mode")
  end

  def test_head_agents_are_not_offered_as_worker_candidates
    workers = build_head_context.to_prompt_h.dig("routing_context", "worker_candidates")

    refute_includes workers.map { |worker| worker.fetch("id") }, "H7"
  end

  def test_recent_activity_includes_bounded_logs_with_routing_details
    activity = build_head_context.to_prompt_h.dig("routing_context", "recent_activity")

    assert_equal %w[L1 L2], activity.map { |entry| entry.fetch("id") }
    assert_equal({ "project_id" => "P1", "issue_id" => "P1-I1" }, activity.first.fetch("routing"))
    assert_equal({ "head_id" => "H7", "question_id" => "Q4" }, activity.last.fetch("routing"))
    refute_includes JSON.generate(activity), "SECRET_LOG_DETAIL"
  end

  def test_recent_activity_is_limited_to_the_most_recent_entries
    snapshot = head_snapshot
    snapshot["logs"] = (1..40).map do |index|
      {
        "id" => "L#{index}",
        "timestamp" => "2024-01-03T00:00:00Z",
        "source_type" => "kernel",
        "source_id" => nil,
        "level" => "info",
        "message" => "log #{index}",
        "details" => {}
      }
    end

    activity = build_head_context(snapshot: snapshot).to_prompt_h.dig("routing_context", "recent_activity")

    assert_equal Meringue::Heads::Context::ROUTING_ACTIVITY_LIMIT, activity.length
    assert_equal "L40", activity.last.fetch("id")
  end

  def test_long_text_is_truncated_before_reaching_the_head
    snapshot = head_snapshot
    snapshot.fetch("issues").first["description"] = "x" * 5_000

    description = build_head_context(snapshot: snapshot)
                    .to_prompt_h.dig("routing_context", "issue_candidates")
                    .find { |candidate| candidate.fetch("id") == "P1-I1" }
                    .fetch("description")

    assert_equal Meringue::Heads::Context::ROUTING_TEXT_LIMIT + 1, description.length
    assert description.end_with?("…")
  end

  def test_explicit_references_resolve_known_and_unknown_ids
    references = build_head_context(user_message: "follow up on P1-I1 from H7, not Q9 or P4-I2-W3")
                   .to_prompt_h.dig("routing_context", "explicit_references")

    assert_equal %w[P1-I1 H7 Q9 P4-I2-W3], references.fetch("mentioned_ids")
    assert_includes references.fetch("known_ids"), "P1-I1"
    assert_includes references.fetch("known_ids"), "P1"
    assert_includes references.fetch("known_ids"), "H7"
    assert_equal %w[Q9 P4-I2-W3], references.fetch("unknown_ids")
  end

  def test_question_context_is_included_when_answering_a_question
    answering = build_head_context(question_id: "Q4").to_prompt_h

    assert_equal "Q4", answering.fetch("question_id")
    question = answering.dig("routing_context", "question_being_answered")
    assert_equal "Q4", question.fetch("id")
    assert_equal "H7", question.fetch("head_id")
    assert_equal "P1", question.fetch("project_id")
    assert_equal "P1-I1", question.fetch("issue_id")
    assert_equal "Should the worker keep the existing branch or start a new one?", question.fetch("question")
    assert_equal "Two branches already exist for this issue.", question.fetch("context")
    assert_equal "open", question.fetch("status")
    assert question.key?("answer")
    assert question.key?("created_at")
  end

  # Current behaviour: prose like "ANSWERING Q4 ..." leaves question_being_answered
  # null because only an explicit question_id populates it.
  def test_question_being_answered_is_null_without_an_explicit_question_id
    payload = build_head_context(user_message: "ANSWERING Q4 keep the existing branch").to_prompt_h

    assert_nil payload.fetch("question_id")
    assert_nil payload.dig("routing_context", "question_being_answered")
    assert_includes payload.dig("routing_context", "explicit_references").fetch("mentioned_ids"), "Q4"
    assert_includes payload.dig("routing_context", "explicit_references").fetch("known_ids"), "Q4"
  end

  def test_unknown_question_id_yields_no_question_context
    assert_nil build_head_context(question_id: "Q404")
                 .to_prompt_h.dig("routing_context", "question_being_answered")
  end

  def test_context_never_embeds_harness_transcripts_or_secrets
    context = build_head_context(question_id: "Q4")

    refute_match SECRET_PATTERN, JSON.generate(context.to_h)
    refute_match SECRET_PATTERN, JSON.generate(context.to_prompt_h)
    refute_match SECRET_PATTERN, context.system_prompt

    worker = context.to_prompt_h.dig("routing_context", "worker_candidates").first
    %w[harness_events prompt system_prompt api_key pi_state harness_metadata].each do |forbidden_key|
      refute_includes worker.keys, forbidden_key
    end
  end

  def test_state_access_points_at_the_state_file_read_only
    root = head_temp_root
    state_path = File.join(root, "state.json")
    access = build_head_context(cwd: root, state_path: state_path).to_prompt_h.fetch("state_access")

    assert_equal state_path, access.fetch("state_path")
    assert access.fetch("read_only")
    assert_equal 2, access.fetch("suggested_commands").length
    assert_includes access.fetch("suggested_commands").map { |command| command.fetch("tool") }, "read"
    assert_includes access.fetch("suggested_commands").last.fetch("command"), state_path.inspect
  end

  def test_project_discovery_prefers_cwd_and_flags_unregistered_directories
    root = head_temp_root
    discovery = build_head_context(cwd: root).to_prompt_h.fetch("project_discovery")

    assert_equal root, discovery.dig("current_directory", "cwd")
    assert_equal root, discovery.dig("current_directory", "default_project_root")
    assert_equal File.basename(root), discovery.dig("current_directory", "default_project_name")
    assert_nil discovery.dig("current_directory", "registered_project_id")
    assert discovery.dig("current_directory", "should_propose_add_project_for_current_directory")
    assert_includes discovery.fetch("candidate_search_roots"), root
    assert_equal Meringue::Heads::Context::DISCOVERY_ALLOWED_COMMANDS,
                 discovery.fetch("allowed_read_only_discovery")
    assert_equal Meringue::Heads::Context::DISCOVERY_FORBIDDEN_COMMANDS,
                 discovery.fetch("forbidden_discovery")
  end

  def test_project_discovery_detects_the_registered_git_root
    root = head_temp_root
    project_path = File.join(root, "registered-project")
    nested_path = File.join(project_path, "lib", "deep")
    FileUtils.mkdir_p(nested_path)
    FileUtils.mkdir_p(File.join(project_path, ".git"))

    snapshot = head_snapshot
    snapshot.fetch("projects").first["root_path"] = project_path

    discovery = build_head_context(snapshot: snapshot, cwd: nested_path)
                  .to_prompt_h.fetch("project_discovery")

    assert_equal project_path, discovery.dig("current_directory", "git_root")
    assert_equal project_path, discovery.dig("current_directory", "default_project_root")
    assert_equal "P1", discovery.dig("current_directory", "registered_project_id")
    refute discovery.dig("current_directory", "should_propose_add_project_for_current_directory")
  end

  def test_to_h_embeds_the_kernel_command_reference_document
    context = build_head_context
    reference_path = Meringue.root_path("docs", "head_agent_kernel_commands.md")
    document = File.read(reference_path)

    assert_equal document, context.to_h.fetch("kernel_command_reference")
    assert_equal reference_path, context.reference_metadata.fetch("path")
    assert_equal document.bytesize, context.reference_metadata.fetch("bytes")
    assert_equal document.lines.count, context.reference_metadata.fetch("lines")
    assert_equal(
      { "path" => reference_path,
        "bytes" => document.bytesize,
        "lines" => document.lines.count,
        "appended_to_system_prompt" => true },
      context.to_prompt_h.fetch("kernel_command_reference")
    )
  end

  def test_system_prompt_forbids_direct_mutation_and_appends_the_reference
    prompt = build_head_context.system_prompt

    assert_includes prompt, "stateless Meringue head agent"
    assert_includes prompt, "Do not mutate files, git state, dependencies, databases, remote services, or Meringue state directly."
    assert_includes prompt, "HeadResult JSON object only"
    assert_includes prompt, File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md")).lines.first.strip
  end

  def test_system_prompt_keeps_a_multi_step_goal_on_one_issue
    prompt = build_head_context.system_prompt

    assert_includes prompt, "one issue with two workers on it"
    assert_includes prompt, "after_from_command and follow_up_of_command on the implementer"
    assert_includes prompt, "Never write a worker prompt that polls Meringue state or sleeps waiting for another worker"
  end

  def test_routing_rules_pair_research_and_implementation_on_one_issue
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")

    assert(rules.any? { |rule| rule.include?("One goal that needs several steps is one issue with several workers") })
    assert(rules.any? { |rule| rule.include?("follow_up_of_command") })
    assert(rules.any? { |rule| rule.include?("polling Meringue state") })
  end

  # A head that asked to both follow up and replace one worker had its SpawnWorker rejected, so the
  # user's retry did nothing. The kernel contract has to be stated in the routing rules.
  def test_routing_rules_forbid_combining_replace_with_follow_up_or_after
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")

    assert(rules.any? { |rule| rule.include?("cannot be combined with follow_up_of_agent_id or after_agent_id") })
    assert(rules.any? { |rule| rule.include?("follow_up_of_agent_id together with after_agent_id is still allowed") })
  end

  def test_routing_rules_explain_how_to_retry_an_errored_worker
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")
    retry_rule = rules.find { |rule| rule.start_with?("To retry a worker that errored") }

    refute_nil retry_rule, "expected a rule for retrying an errored worker"
    assert_includes retry_rule, "no replace_agent_id"
    assert_includes retry_rule, "harness_session_id is null"
  end

  def test_kernel_command_reference_documents_the_exclusive_relationship_fields
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    assert_includes reference, "Set at most one takeover relationship per `SpawnWorker`"
    assert_includes reference, "`follow_up_of_agent_id` and `replace_agent_id` are mutually exclusive"
    assert_includes build_head_context.system_prompt, "Set at most one takeover relationship per `SpawnWorker`"
  end

  def test_missing_kernel_command_reference_raises
    context = Meringue::Heads::Context.new(
      head_id: "H1",
      user_message: "hello",
      snapshot: head_snapshot,
      kernel_commands_path: File.join(head_temp_root, "missing.md"),
      cwd: head_temp_root,
      state_path: File.join(head_temp_root, "state.json")
    )

    error = assert_raises(ArgumentError) { context.to_h }
    assert_includes error.message, "Head kernel command reference not found"
  end

  def test_context_tolerates_an_empty_state_snapshot
    payload = build_head_context(snapshot: Meringue::State::Models.empty_state).to_prompt_h

    assert_equal 0, payload.dig("current_state_summary", "project_count")
    assert_equal 0, payload.dig("current_state_summary", "open_question_count")
    assert_empty payload.dig("routing_context", "issue_candidates")
    assert_empty payload.dig("routing_context", "worker_candidates")
    assert_empty payload.dig("routing_context", "recent_activity")
  end
end
