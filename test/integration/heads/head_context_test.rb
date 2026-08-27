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
      %w[purpose explicit_references question_being_answered open_questions answer_inference
         issue_candidates worker_candidates recent_activity decision_rules],
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

  def test_open_question_records_are_surfaced_for_answer_inference
    payload = build_head_context.to_prompt_h
    open_questions = payload.dig("routing_context", "open_questions")

    assert_equal 2, payload.dig("current_state_summary", "open_question_count")
    assert_equal %w[Q4 Q5], open_questions.map { |question| question.fetch("id") }
    assert_equal "Should the worker keep the existing branch or start a new one?", open_questions.first.fetch("question")
    assert_equal "Two branches already exist for this issue.", open_questions.first.fetch("context")
    assert_equal "P1-I1", open_questions.first.fetch("issue_id")
    refute_includes payload.fetch("current_state_summary").keys, "open_questions"
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

  def test_context_percentage_from_harness_telemetry_is_normalized_to_a_fraction
    snapshot = head_snapshot
    snapshot.fetch("agents").first["session_stats"] = { "context_usage" => { "percent" => 25.0 } }

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first

    assert_in_delta 0.25, candidate.fetch("context_utilization")
  end

  def test_streaming_worker_supports_harness_neutral_steer_and_follow_up_modes
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker["harness"] = "claude"
    worker.fetch("harness_metadata")["is_streaming"] = true

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first

    assert_equal "claude", candidate.fetch("harness")
    assert candidate.fetch("is_streaming")
    assert_equal %w[steer follow_up], candidate.fetch("supported_prompt_modes_now")
    assert_equal "follow_up", candidate.fetch("recommended_prompt_mode")
  end

  def test_streaming_worker_without_live_prompt_capabilities_is_not_offered_unsafe_modes
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker.fetch("harness_metadata")["prompt_modes"] = ["normal"]
    worker.fetch("harness_metadata")["is_streaming"] = true

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first

    assert_empty candidate.fetch("supported_prompt_modes_now")
    refute candidate.key?("recommended_prompt_mode")
  end

  # A head must be able to see that a queued worker is held by a script condition, not just by
  # another agent, or it will re-route work that is already scheduled.
  def test_worker_candidates_expose_a_command_gated_queued_worker
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker["status"] = "queued"
    worker.fetch("harness_metadata")["deferred_spawn"] = {
      "state" => "waiting",
      "after_agent_id" => "P1-I1-W1",
      "if_predecessor_fails" => "cancel",
      "command_gate" => {
        "command" => "gh pr view --json reviewDecision",
        "label" => "pair review",
        "expect" => "exit_zero",
        "state" => "pending",
        "checks" => 3,
        "if_gate_expires" => "cancel",
        "last_check" => { "stdout_tail" => "SECRET_TRANSCRIPT_LINE" }
      }
    }

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first
    gate = candidate.fetch("deferred_spawn").fetch("command_gate")

    assert_equal "gh pr view --json reviewDecision", gate.fetch("command")
    assert_equal "pair review", gate.fetch("label")
    assert_equal "pending", gate.fetch("state")
    assert_equal 3, gate.fetch("checks")
    # The condition's captured output is not routing context; it stays out of the head prompt.
    refute gate.key?("last_check")
  end

  def test_worker_candidates_expose_a_command_gated_completion_continuation
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker["status"] = "completed"
    worker.fetch("harness_metadata")["completion_continuation"] = {
      "state" => "waiting",
      "prompt" => "Route the review response after it lands.",
      "include_worker_result" => true,
      "command_gate" => {
        "command" => "gh pr view --json reviewDecision",
        "label" => "pair review",
        "expect" => "output_matches",
        "state" => "pending",
        "checks" => 2,
        "if_gate_expires" => "cancel",
        "last_check" => { "stdout_tail" => "SECRET_TRANSCRIPT_LINE" }
      }
    }

    candidate = build_head_context(snapshot: snapshot)
                  .to_prompt_h.dig("routing_context", "worker_candidates").first
    continuation = candidate.fetch("completion_continuation")
    gate = continuation.fetch("command_gate")

    assert_equal "waiting", continuation.fetch("state")
    assert_equal "Route the review response after it lands.", continuation.fetch("prompt")
    assert_equal "pair review", gate.fetch("label")
    assert_equal 2, gate.fetch("checks")
    refute gate.key?("last_check")
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

  def test_routing_context_bounds_records_without_slicing_their_messages
    snapshot = head_snapshot
    worker_message = "WORKER START\n#{"w" * 5_000}\nWORKER END"
    original_user_message = "USER START\n#{"u" * 5_000}\nUSER END"
    snapshot.fetch("agents").first.fetch("harness_metadata")["last_assistant_text"] = worker_message
    snapshot.fetch("questions").first["original_user_message"] = original_user_message
    complete_log_messages = (1..(Meringue::Heads::Context::ROUTING_ACTIVITY_LIMIT + 1)).to_h do |index|
      [index, "LOG #{index} START\n#{index.to_s * 2_500}\nLOG #{index} END"]
    end
    snapshot["logs"] = complete_log_messages.map do |index, message|
      {
        "id" => "L#{index}",
        "timestamp" => "2024-01-03T00:00:00Z",
        "source_type" => "worker",
        "source_id" => "P1-I1-W1",
        "level" => "info",
        "message" => message,
        "details" => {}
      }
    end

    routing = build_head_context(snapshot: snapshot).to_prompt_h.fetch("routing_context")

    assert_equal worker_message, routing.fetch("worker_candidates").first.fetch("last_result")
    assert_equal original_user_message, routing.fetch("open_questions").first.fetch("original_user_message")
    activity = routing.fetch("recent_activity")
    assert_equal Meringue::Heads::Context::ROUTING_ACTIVITY_LIMIT, activity.length
    refute_includes activity.map { |entry| entry.fetch("id") }, "L1"
    activity.each do |entry|
      index = entry.fetch("id").delete_prefix("L").to_i
      assert_equal complete_log_messages.fetch(index), entry.fetch("message")
    end
    refute_includes JSON.generate(routing), "[truncated"
  end

  def test_long_non_message_context_is_summarized_before_reaching_the_head
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
    refute question.key?("answer")
    assert question.key?("created_at")
  end

  def test_question_being_answered_is_inferred_from_a_clear_prose_reference
    payload = build_head_context(user_message: "ANSWERING Q4 keep the existing branch").to_prompt_h

    assert_nil payload.fetch("question_id")
    question = payload.dig("routing_context", "question_being_answered")
    assert_equal "Q4", question.fetch("id")
    assert_equal "user_message_reference", question.fetch("inference_source")
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
    assert_equal Meringue::ProjectNaming.name_for(root), discovery.dig("current_directory", "default_project_name")
    assert_equal Meringue::ProjectNaming.name_for(root), discovery.dig("current_directory", "suggested_project_name")
    assert_nil discovery.dig("current_directory", "registered_project_id")
    assert discovery.dig("current_directory", "should_propose_add_project_for_current_directory")
    assert_includes discovery.fetch("candidate_search_roots"), root
    assert_equal Meringue::Heads::Context::DISCOVERY_ALLOWED_COMMANDS,
                 discovery.fetch("allowed_read_only_discovery")
    assert_equal Meringue::Heads::Context::DISCOVERY_FORBIDDEN_COMMANDS,
                 discovery.fetch("forbidden_discovery")
  end

  def test_project_discovery_uses_the_readme_heading_as_the_suggested_name
    root = head_temp_root
    File.write(File.join(root, "README.md"), "# Meringue — terminal-first control plane\n\nA concise product description.\n")

    discovery = build_head_context(cwd: root).to_prompt_h.fetch("project_discovery")

    assert_equal "Meringue", discovery.dig("current_directory", "suggested_project_name")
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
    assert_includes prompt, "Preserve intentional capitalization exactly"
    assert_includes prompt, File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md")).lines.first.strip
  end

  # Recorded invalid-HeadResult failures showed heads emitting `"response": null`,
  # prose without a JSON wrapper, and unescaped literal newlines or embedded code
  # fences inside string values. The system prompt must give the model concrete
  # formatting rules so it stops producing those malformed shapes.
  def test_system_prompt_pins_headresult_json_formatting_rules
    prompt = build_head_context.system_prompt

    assert_includes prompt, "never use JSON null"
    assert_includes prompt, "Escape newlines inside every JSON string value"
    assert_includes prompt, "never embed a ``` code fence inside a string value"
    assert_includes prompt, "never write prose without the JSON wrapper"
  end

  def test_project_routing_guidance_prioritizes_request_identity_and_safe_discovery
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")

    assert_includes prompt, "Resolve project identity from the current user request before considering recent activity"
    assert(rules.any? { |rule| rule.include?("named project, repository path, or clearly identified local repository wins") })
    assert(rules.any? { |rule| rule.include?("propose AddProject for that repository before CreateIssue") })
    assert(rules.any? { |rule| rule.include?("multiple plausible repositories") })
  end

  # H177 asked for a causal explanation across several dependency records. The old contract's
  # broad "status -> GetInfo" example caused the head to dump raw fields instead of answering.
  def test_informational_routing_distinguishes_direct_lookup_response_and_investigation
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    lookup_rule = rules.find { |rule| rule.include?("First distinguish direct record retrieval") }
    response_rule = rules.find { |rule| rule.include?("HeadResult response field") }
    incident_rule = rules.find { |rule| rule.include?("Why are several workers waiting on P6-I22-W1?") }

    refute_nil lookup_rule
    assert_includes lookup_rule, "Use GetInfo only"
    assert_includes lookup_rule, "why/how/what-caused"
    refute_nil response_rule
    assert_includes response_rule, "with no NoOp required"
    assert_includes response_rule, "informational worker"
    refute_nil incident_rule
    assert_includes incident_rule, "Spawn or prompt an informational worker"
    assert_includes incident_rule, "do not propose GetInfo alone"
    assert_includes incident_rule, "What is P6-I22-W1?"

    assert_includes prompt, "HeadResult \"response\" field"
    assert_includes prompt, "A nonblank response is a handled result and needs no NoOp"
    assert_includes reference, "Direct answers versus informational work"
    assert_includes reference, "Why are several workers waiting on P6-I22-W1?"
    assert_includes reference, "Never treat raw status/dependency lines as the answer"
  end

  def test_head_can_explicitly_route_safe_investigations_to_shared_read_only_mode
    context = build_head_context
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    rule = rules.find { |candidate| candidate.include?("SpawnWorker.workspace_mode") }
    refute_nil rule
    assert_includes rule, "shared_read_only"
    assert_includes rule, "only read/grep/find/ls tools"
    assert_includes rule, "Never choose this mode for implementation"
    assert_includes rule, "spawn an isolated worker"
    assert_includes reference, '`workspace_mode: "shared_read_only"`'
    assert_includes reference, "effective_workspace_mode"
    assert_includes reference, "bare common repository root"
  end

  # Number-based labels hide which GitHub work an issue represents. The exact-title rule belongs
  # in the durable reference that every harness-backed head receives, for both issue and PR routes.
  def test_github_backed_issue_naming_uses_the_exact_relevant_github_title
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))
    architecture = File.read(Meringue.root_path("AGENTS.md"))

    assert_includes prompt, "relevant GitHub issue or pull request's exact current title"
    assert_includes prompt, "use that title unchanged as the Meringue issue title"
    assert_includes prompt, "Fix PR #123"
    assert_includes prompt, "Rebase PR #123"
    assert_includes prompt, "GitHub issue #123"

    naming_rule = rules.find { |rule| rule.include?("Before CreateIssue, or an issue-creating CreateGoal, for GitHub-backed work") }
    refute_nil naming_rule, "expected exact GitHub title guidance in routing rules"
    assert_includes naming_rule, "GitHub issue or pull request's exact current title"
    assert_includes naming_rule, "including capitalization and punctuation"
    assert_includes naming_rule, "ask a clarifying question"
    refute_includes naming_rule, "filename"

    assert_includes reference, "## GitHub issue and pull-request titles"
    assert_includes reference, "use the exact GitHub title in `CreateIssue.title`"
    assert_includes reference, "`CreateGoal.issue_title`"
    refute_includes reference, "monotonic-skill"
    assert_includes architecture, "Every new GitHub-backed Meringue issue"
    assert_includes architecture, "exact current title of the relevant GitHub issue or pull request unchanged"
  end

  def test_github_title_discovery_stays_read_only
    context = build_head_context
    discovery = context.to_prompt_h.fetch("project_discovery")
    allowed = discovery.fetch("allowed_read_only_discovery").join("\n")
    forbidden = discovery.fetch("forbidden_discovery").join("\n")

    assert_includes allowed, "gh issue view"
    assert_includes allowed, "gh pr view"
    assert_includes allowed, "--json title"
    refute_includes allowed, "--json files"
    assert_includes forbidden, "GitHub mutations"
    assert_includes forbidden, "gh issue edit/comment/close/reopen"
    assert_includes forbidden, "gh pr edit/comment/review/merge/close/reopen"
    assert_includes context.system_prompt,
                    "Do not mutate files, git state, dependencies, databases, remote services, or Meringue state directly."
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

  # "This is critical, don't stop until it's done" used to route as one ordinary worker, because
  # nothing a head reads connected that phrasing to the goal loop.
  def test_a_head_is_told_that_a_drive_it_to_done_request_is_a_goal_loop
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")

    assert_includes prompt, "driven to completion rather than attempted once"
    assert_includes prompt, "propose CreateGoal instead of a single one-shot worker"
    assert_includes prompt, "CreateGoal mints its own issue from a prompt"
    assert_includes prompt, "Urgency alone is not a goal loop"

    goal_rule = rules.find { |rule| rule.include?("is a goal loop, not a one-shot worker") }
    refute_nil goal_rule, "expected a routing rule for goal-loop requests"
    assert_includes goal_rule, "prompt form"
    assert_includes goal_rule, "project_from_command"
    assert(rules.any? { |rule| rule.include?("Insistence without a measurable finish line is still ordinary work") })
  end

  # A head that only hears "the finish line must be a command" will invent a fake metric for a
  # subjective goal, or downgrade it to one worker. The reviewer judge has to be in its context.
  def test_a_head_is_told_that_a_subjective_finish_line_is_the_reviewer_judge
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")

    assert_includes prompt, "judge.mode \"reviewer\""
    assert_includes prompt, "could be judged by reading the result"

    reviewer_rule = rules.find { |rule| rule.include?("A finish line does not have to be a number") }
    refute_nil reviewer_rule, "expected a routing rule for reviewer-judged goals"
    assert_includes reviewer_rule, "Never invent a fake metric"
  end

  def test_ordinary_delivery_stops_at_the_open_pull_request_without_an_automatic_continuation
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    delivery_rule = rules.find { |rule| rule.include?("ordinary request to implement and deliver a change") }

    refute_nil delivery_rule, "expected an explicit delivery stopping rule"
    assert_includes delivery_rule, "verified it as reasonably possible, pushed it, and opened or updated the pull request"
    assert_includes delivery_rule, "do not automatically add a completion_head, CI/review continuation, checker worker, or after_command gate"
    assert_includes delivery_rule, "The user will explicitly retrigger or request follow-up work"
    assert_includes prompt, "do not create a completion head, CI/review continuation, checker worker, or external-condition gate"
    assert_includes prompt, "Only when the user specifically requests CI remediation"
    assert_includes prompt, "does not watch CI, review bots, pull-request checks, or reviews"
  end

  # A head that asked to both follow up and replace one worker had its SpawnWorker rejected, so the
  # user's retry did nothing. The kernel contract has to be stated in the routing rules.
  # Heads are prompted from docs/head_agent_kernel_commands.md plus these rules; if neither
  # mentions after_command, no head will ever use it.
  def test_routing_rules_and_command_reference_describe_script_gated_waits
    context = build_head_context
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = context.system_prompt

    assert(rules.any? { |rule| rule.include?("Use after_command only when the user explicitly requests a post-delivery action") })
    assert(rules.any? { |rule| rule.include?("after_command composes with after_agent_id as AND") })
    assert(rules.any? { |rule| rule.include?("Use completion_head.after_command") })
    assert(rules.any? { |rule| rule.include?("instead of launching a short-lived worker just to check the state") })
    assert_includes reference, "### Chaining a worker after a script or command"
    assert_includes reference, "completion_head.after_command"
    assert_includes reference, "\"after_command\":"
    assert_includes reference, "if_gate_expires"
  end

  def test_routing_rules_forbid_combining_replace_with_follow_up_or_after
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")

    assert(rules.any? { |rule| rule.include?("cannot be combined with follow_up_of_agent_id or after_agent_id") })
    assert(rules.any? { |rule| rule.include?("follow_up_of_agent_id together with after_agent_id is still allowed") })
  end

  # Heads were being told they had predicted an id when a /prune removed their target mid-flight, so
  # the routing rules now state what the kernel does and that hedging is not the answer.
  def test_routing_rules_explain_a_target_removed_while_routing
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")
    rule = rules.find { |entry| entry.include?("issue_removed_before_head_result_applied") }

    refute_nil rule, "expected a routing rule for a target removed while the head is routing"
    assert_includes rule, "skips that one command as a no-op"
    assert_includes rule, "Never re-check state at the last moment"
  end

  # Meringue keeps harness sessions short: a follow-up is a new worker that inherits the
  # predecessor's worktree, branch, and final report, not another prompt onto a growing session.
  # If the head's contract does not say so, every head defaults back to prompting.
  def test_a_head_is_told_to_continue_an_issue_in_a_fresh_worker_session
    context = build_head_context
    prompt = context.system_prompt
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    assert_includes prompt, "Prefer a fresh worker session for a follow-up on an existing issue"
    assert_includes prompt, "hands it the predecessor's complete final report"

    continuation_rule = rules.find { |rule| rule.include?("Continue an existing issue with a fresh worker session by default") }
    refute_nil continuation_rule, "expected a fresh-session continuation rule"
    assert_includes continuation_rule, "after_agent_id"
    assert_includes continuation_rule, "follow_up_of_agent_id"
    assert_includes continuation_rule, "handover block"

    assert_includes reference, "continue the work in a **fresh worker session** by default"
    assert_includes reference, "Never spawn a bare worker with no relationship field"
  end

  # The exceptions have to be enumerated, or "prefer a fresh session" reads as "never prompt" and
  # heads stop steering mid-turn work or recovering an interrupted one.
  def test_a_head_is_told_the_cases_that_still_call_for_prompting_an_existing_worker
    context = build_head_context
    rules = context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    prompt_rule = rules.find { |rule| rule.start_with?("Prompt an existing worker only when") }
    refute_nil prompt_rule, "expected an explicit rule for when prompting is still right"
    assert_includes prompt_rule, "steer"
    assert_includes prompt_rule, "stopped_without_finishing"
    assert_includes prompt_rule, "explicitly asks to continue that same session"

    mode_rule = rules.find { |rule| rule.include?("Prefer a fresh worker queued with after_agent_id over follow_up mode") }
    refute_nil mode_rule, "a queued fresh worker should replace follow_up mode as the advice"

    assert_includes reference, "This is the narrow path, not the default one"
  end

  # A fresh session only works if the report it inherits is worth inheriting, so the head has to
  # write prompts with that in mind and the worker has to be told what its report is for.
  def test_the_contract_makes_the_final_report_the_carrier_of_context
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    report_rule = rules.find { |rule| rule.include?("usable by a successor that never sees the transcript") }
    refute_nil report_rule, "expected the head to be told its prompts shape the successor's context"

    assert_includes reference, "the durable carrier of context between steps, not its transcript"
    assert_includes Meringue::Kernel::Engine::WORKER_SYSTEM_PROMPT, "Your final message is a handover"
    assert_includes Meringue::Kernel::Engine::WORKER_SYSTEM_PROMPT, "what you tried that did not work and why"
    assert_includes Meringue::Kernel::Engine::READ_ONLY_WORKER_SYSTEM_PROMPT, "Your final message is a handover"
  end

  def test_routing_rules_explain_how_to_retry_an_errored_worker
    rules = build_head_context.to_prompt_h.dig("routing_context", "decision_rules")
    retry_rule = rules.find { |rule| rule.start_with?("To retry a worker that errored") }

    refute_nil retry_rule, "expected a rule for retrying an errored worker"
    assert_includes retry_rule, "no replace_agent_id"
    assert_includes retry_rule, "harness_session_id is null"
  end

  def test_head_can_translate_per_worker_model_and_thinking_requests
    context = build_head_context(user_message: "Spawn openai/gpt-5.6-sol at medium thinking")
    reference = File.read(Meringue.root_path("docs", "head_agent_kernel_commands.md"))

    assert_includes context.to_prompt_h.dig("routing_context", "decision_rules").join("\n"), "SpawnWorker.model"
    assert_includes context.to_prompt_h.dig("routing_context", "decision_rules").join("\n"), "SpawnWorker.thinking_level"
    assert_includes reference, '"model": "openai/gpt-5.6-sol", "thinking_level": "medium"'
    assert_includes reference, "Omit either field to use the configured future-session default"
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
