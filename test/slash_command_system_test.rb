# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/meringue"

class SlashCommandSystemTest < Minitest::Test
  class ExplodingRunner < Meringue::Heads::Runner
    def run(**)
      raise "head runner should not be called for slash commands"
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("meringue-slash-test")
    @store = Meringue::State::Store.new(path: File.join(@tmpdir, "state.json"))
    @store.save(Meringue::State::Models.empty_state)
    @engine = Meringue::Kernel::Engine.new(
      store: @store,
      harness_client: Meringue::Harness::FakeClient.new,
      head_runner: ExplodingRunner.new,
      cwd: @tmpdir
    )
    @parser = Meringue::Input::SlashCommandParser.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  def test_parser_maps_mvp_slash_commands_to_kernel_commands
    assert_command "/help", "Help", {}
    assert_command "/project add #{@tmpdir} Demo", "AddProject", "path" => @tmpdir, "name" => "Demo"
    assert_command "/issue create P1 \"Title here\" \"Long desc\"", "CreateIssue", "project_id" => "P1", "title" => "Title here", "description" => "Long desc"
    assert_command "/worker spawn P1-I1 \"Do the work\"", "SpawnWorker", "issue_id" => "P1-I1", "prompt" => "Do the work"
    assert_command "/prompt P1-I1-W1 \"Follow up\"", "PromptAgent", "agent_id" => "P1-I1-W1", "prompt" => "Follow up"
    assert_command "/kill P1-I1", "Kill", "target_id" => "P1-I1"
    assert_command "/tree", "ListAll", "view" => "tree"
    assert_command "/state", "GetState", {}
    assert_command "/questions", "ListQuestions", {}
    assert_command "/answer Q1 \"Yes\"", "AnswerQuestion", "question_id" => "Q1", "answer" => "Yes"
  end

  def test_slash_commands_bypass_head_runner_and_apply_in_kernel
    loop = Meringue::Heads::PromptLoop.new(engine: @engine)

    result = loop.call("/project add #{@tmpdir} Demo")

    assert_equal "slash_command_applied", result.fetch("event")
    assert_equal "accepted", result.fetch("command_results").first.fetch("status")
    assert_empty @store.load.fetch("agents")
    assert_equal "P1", @store.load.fetch("projects").first.fetch("id")
  end

  def test_prompt_and_kill_slash_commands_share_kernel_state_path
    project = @engine.apply("type" => "AddProject", "payload" => { "path" => @tmpdir, "name" => "Demo" }).fetch("result")
    issue = @engine.apply("type" => "CreateIssue", "payload" => { "project_id" => project.fetch("id"), "title" => "Test" }).fetch("result")
    worker = @engine.apply("type" => "SpawnWorker", "payload" => { "issue_id" => issue.fetch("id"), "prompt" => "Start" }).fetch("result")

    prompt_result = @engine.apply(@parser.parse("/prompt #{worker.fetch("id")} \"Continue\""))
    kill_result = @engine.apply(@parser.parse("/kill #{issue.fetch("id")}"))

    assert_equal "accepted", prompt_result.fetch("status")
    assert_equal "accepted", kill_result.fetch("status")
    state = @store.load
    assert_equal "killed", state.fetch("issues").first.fetch("status")
    assert_equal "killed", state.fetch("agents").first.fetch("status")
  end

  def test_chat_pane_shows_helper_only_for_empty_slash_prompt
    pane = Meringue::TUI::Panes::ChatPane.new
    base_state = Meringue::State::Models.empty_state

    helper_text = pane.composer_lines(base_state.merge("_chat" => { "input_buffer" => "/" })).map do |line|
      line.map { |segment| segment.first }.join
    end.join("\n")
    normal_text = pane.composer_lines(base_state.merge("_chat" => { "input_buffer" => "/help" })).map do |line|
      line.map { |segment| segment.first }.join
    end.join("\n")

    assert_includes helper_text, "slash commands"
    refute_includes normal_text, "slash commands"
  end

  private

  def assert_command(input, type, payload)
    command = @parser.parse(input).to_h
    assert_equal type, command.fetch("type")
    assert_equal payload, command.fetch("payload")
  end
end
