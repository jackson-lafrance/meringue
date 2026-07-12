# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "timeout"
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

  def test_slash_suggestions_show_top_three_and_filter_after_slash
    all_suggestions = Meringue::Input::SlashCommandParser.command_suggestion_records("/", limit: 3)
    filtered_suggestions = Meringue::Input::SlashCommandParser.command_suggestion_records("/p", limit: 3)

    assert_equal 3, all_suggestions.length
    assert_equal "/help", all_suggestions.first.fetch("usage")
    assert_equal ["/project add <path> [name]", "/prompt <agent_id> \"<message>\""], filtered_suggestions.map { |record| record.fetch("usage") }
  end

  def test_chat_pane_renders_cursor_style_suggestions_separately_from_input
    pane = Meringue::TUI::Panes::ChatPane.new
    base_state = Meringue::State::Models.empty_state
    state = base_state.merge("_chat" => { "input_buffer" => "/p", "slash_suggestion_index" => 1 })

    suggestion_text = pane.slash_suggestion_lines(state).map { |line| plain_line(line) }.join("\n")
    composer_text = pane.composer_lines(state).map { |line| plain_line(line) }.join("\n")

    assert_includes suggestion_text, "/project add"
    assert_includes suggestion_text, "› /prompt"
    refute_includes suggestion_text, "/help"
    refute_includes composer_text, "/project add"
  end

  def test_layout_places_suggestions_above_chat_input
    layout = Meringue::TUI::Layout.new
    state = Meringue::State::Models.empty_state.merge("_chat" => { "input_buffer" => "/p", "slash_suggestion_index" => 0 })

    frame_lines = layout.render(state, width: 100, height: 32, color: false).split("\n")
    suggestions_y = frame_lines.index { |line| line.include?("slash commands") }
    chat_y = frame_lines.rindex { |line| line.include?(" chat ") }
    input_y = frame_lines.index { |line| line.include?("› /p_") }

    refute_nil suggestions_y
    refute_nil chat_y
    refute_nil input_y
    assert_operator suggestions_y, :<, chat_y
    assert_operator suggestions_y, :<, input_y
  end

  def test_tui_tab_and_enter_complete_slash_suggestions_without_executing_partial_commands
    app = Meringue::TUI::App.new
    submitted_prompts = Queue.new
    submitter = lambda do |text|
      submitted_prompts << text
      { "summary" => "ok" }
    end

    buffer, index = app.send(:handle_key, "\t", "/p", 0, submitter)
    assert_equal "/project add ", buffer
    assert_equal 0, index
    assert submitted_prompts.empty?

    buffer, = app.send(:handle_key, "\r", "/h", 0, submitter)
    assert_equal "/help", buffer
    assert submitted_prompts.empty?

    buffer, = app.send(:handle_key, "\r", "/help", 0, submitter)
    assert_equal "", buffer
    assert_equal "/help", Timeout.timeout(1) { submitted_prompts.pop }
  end

  private

  def assert_command(input, type, payload)
    command = @parser.parse(input).to_h
    assert_equal type, command.fetch("type")
    assert_equal payload, command.fetch("payload")
  end

  def plain_line(line)
    line.map { |segment| segment.first }.join
  end
end
