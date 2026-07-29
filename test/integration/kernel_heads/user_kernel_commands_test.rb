# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Head-proposed user commands use the normal kernel dispatch path, including validation,
# exactly-once journaling, command logs/output, and destructive-command guards.
class KernelHeadsUserKernelCommandsTest < KernelHeadsTestCase
  def setup
    @original_colorscheme = Meringue::TUI::Style.current_colorscheme
    super
  end

  def teardown
    Meringue::TUI::Style.configure!(@original_colorscheme) if @original_colorscheme
    super
  end

  def command(type, payload = {})
    { "type" => type, "payload" => payload }
  end

  def test_session_model_and_thinking_commands_are_head_proposable
    %w[
      GetSessionDefaults SetDefaultSessionModel SetDefaultSessionThinkingLevel
      GetSessionSettings SetSessionModel SetSessionThinkingLevel
    ].each do |command_type|
      assert_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, command_type
    end
  end

  def test_one_head_batch_can_apply_every_ordinary_user_kernel_command
    project_id = add_project!
    issue_id = apply_command(
      "CreateIssue",
      {
        "project_id" => project_id,
        "title" => "Maintain the tree",
        "description" => "Fixture issue"
      }
    ).fetch("target_id")
    worker_id = apply_command(
      "SpawnWorker",
      {
        "issue_id" => issue_id,
        "title" => "Tree worker",
        "prompt" => "Wait for maintenance."
      }
    ).fetch("target_id")
    head_id = spawn_head!("prompt the worker, update the issue, answer and dismiss the questions, then clean up and renumber")
    q1 = apply_command("AskQuestion", { "head_id" => head_id, "question" => "Continue?" }).fetch("target_id")
    q2 = apply_command("AskQuestion", { "head_id" => head_id, "question" => "Keep this question?" }).fetch("target_id")

    commands = [
      command("PromptAgent", "agent_id" => worker_id, "prompt" => "Report status.", "mode" => "steer"),
      command("ModifyIssue", "issue_id" => issue_id, "title" => "Maintained tree"),
      command("AnswerQuestion", "question_id" => q1, "answer" => "Yes"),
      command("DismissQuestion", "question_id" => q2),
      command("GetInfo", "target_id" => project_id),
      command("ListAll"),
      command("GetState"),
      command("ListQuestions"),
      command("Help"),
      command("SetTheme", "theme" => "gruvbox"),
      command("Prune"),
      command("Kill", "target_id" => worker_id),
      command("SetHarness", "provider" => "pi"),
      # Recount is last because commands above refer to the pre-recount ids.
      command("Recount")
    ]

    applied = apply_head_result(head_id, head_result(commands: commands), cleanup_head: false)
    results = command_results(applied)

    assert_equal commands.map { |entry| entry.fetch("type") }, results.map { |entry| entry.fetch("command_type") }
    assert results.all? { |entry| entry.fetch("status") == "accepted" }, results.inspect
    assert_equal results.length, find_agent_record(head_id).dig("harness_metadata", "head_result_command_journal").length
    assert_includes log_messages, results.find { |entry| entry.fetch("command_type") == "Prune" }.fetch("message")
    assert log_messages.any? { |message| message.start_with?("Command output: GetInfo: accepted") }
  end

  def test_clear_state_requires_explicit_recorded_user_intent_and_confirmation
    add_project!
    vague_head = spawn_head!("clean things up")
    vague = apply_head_result(
      vague_head,
      head_result(commands: [command("ClearState", "confirmed_by_user" => true)]),
      cleanup_head: false
    )

    refute_empty command_results(vague), vague.inspect
    refusal = command_results(vague).first
    assert_equal "rejected", refusal.fetch("status")
    assert_includes refusal.fetch("errors"), "clear_state_requires_explicit_user_instruction"
    refute_empty state.fetch("projects"), "a vague prompt must never wipe state"

    explicit_head = spawn_head!("clear the meringue state")
    explicit = apply_head_result(
      explicit_head,
      head_result(commands: [command("ClearState", "confirmed_by_user" => true)])
    )

    assert_equal "accepted", command_results(explicit).first.fetch("status")
    assert_equal true, explicit.dig("result", "state_cleared")
    assert_empty state.fetch("projects")
    assert log_messages.any? { |message| message.start_with?("Command output: ClearState: accepted") }
  end

  def test_full_project_kill_requires_the_user_to_name_and_confirm_the_project
    project_id = add_project!(name: "demo-project")
    vague_head = spawn_head!("stop whatever is in the way")
    vague = apply_head_result(
      vague_head,
      head_result(commands: [command("Kill", "target_id" => project_id, "confirmed_by_user" => true)]),
      cleanup_head: false
    )

    refute_empty command_results(vague), vague.inspect
    refusal = command_results(vague).first
    assert_equal "rejected", refusal.fetch("status")
    assert_includes refusal.fetch("errors"), "project_kill_requires_explicit_user_instruction"
    refute_empty state.fetch("projects")

    explicit_head = spawn_head!("kill project P1")
    explicit = apply_head_result(
      explicit_head,
      head_result(commands: [command("Kill", "target_id" => project_id, "confirmed_by_user" => true)])
    )

    assert_equal "accepted", command_results(explicit).first.fetch("status")
    assert_empty state.fetch("projects")
  end
end
