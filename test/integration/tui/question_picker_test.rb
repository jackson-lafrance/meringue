# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# `/questions` is a local TUI picker. It lists only open questions with a compact
# local ordinal, while Enter inserts the durable question id into `/answer`.
class TuiQuestionPickerTest < Minitest::Test
  include TUISupport

  QuestionPicker = Meringue::TUI::QuestionPicker
  Pane = Meringue::TUI::Panes::ChatPane
  WIDTH = 100
  HEIGHT = 32

  def setup
    @submitted = []
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    )
    @pane = Pane.new
    @state = state_with_questions
  end

  def teardown
    wait_for_submissions(@submitted.length)
  end

  def test_questions_command_opens_a_picker_with_only_open_questions
    picker = open_picker

    assert @pane.question_picker?(picker)
    assert_equal "open questions", @pane.popup_pane_title(picker)
    assert_empty @submitted
    assert_equal(
      [
        "› 1. Q20  Which environment should I target?",
        "  2. Q24  Which region should receive the build?"
      ],
      plain_lines(@pane.popup_lines(picker))
    )
    refute plain_lines(@pane.popup_lines(picker)).any? { |line| line.include?("Q21") }
  end

  def test_local_display_numbers_start_at_one_and_ignore_canonical_question_ids
    entries = QuestionPicker.entries(@state)

    assert_equal [1, 2], entries.map { |entry| entry.fetch("display_number") }
    assert_equal %w[Q20 Q24], entries.map { |entry| entry.fetch("id") }
    assert_equal 2, QuestionPicker.count(@state)
    assert_equal "Q24", QuestionPicker.entry_at(@state, 1).fetch("id")
  end

  def test_arrow_navigation_and_enter_insert_the_canonical_answer_command
    open_picker
    send_key("\e[B")

    moved = compose
    assert_equal 1, @pane.question_picker_index(moved)
    assert_includes plain_lines(@pane.popup_lines(moved)).fetch(1), "› 2. Q24"

    result = send_key("\r")

    assert_equal "/answer Q24 ", result.fetch(0)
    assert_equal result.fetch(0).length, result.fetch(1)
    assert_equal(-1, result.fetch(2))
    refute @pane.question_picker?(compose)
    assert_empty @submitted
  end

  def test_the_inserted_command_can_be_completed_and_submitted_as_an_answer
    open_picker
    command = send_key("\r").fetch(0)
    answer = "#{command}Use the staging environment"

    send_key("\r", input_buffer: answer)

    assert_equal [answer], wait_for_submissions(1)
  end

  def test_escape_closes_the_picker_without_submitting
    open_picker
    send_key("\e")

    refute @pane.question_picker?(compose)
    assert_empty @submitted
  end

  def test_clicking_a_question_inserts_it_and_clicking_away_closes_the_picker
    picker = open_picker
    result = send_key(press_event(screen_position_for_row(picker, 1)))

    assert_equal "/answer Q24 ", result.fetch(0)
    refute @pane.question_picker?(compose)

    open_picker
    send_key(press_event({ "x" => 3, "y" => 3 }))
    refute @pane.question_picker?(compose)
  end

  def test_an_empty_question_list_explains_itself_instead_of_listing_answered_questions
    @state = empty_state.merge("questions" => [question("Q20", status: "answered", text: "Already answered")])
    picker = open_picker

    assert @pane.question_picker?(picker)
    assert_equal ["No open questions."], plain_lines(@pane.popup_lines(picker))
    assert_equal "Esc closes", plain_line(@pane.popup_footer_line(picker))
    refute plain_lines(@pane.popup_lines(picker)).any? { |line| line.include?("Already answered") }
  end

  private

  def state_with_questions
    empty_state.merge(
      "questions" => [
        question("Q20", text: "Which environment should I target?"),
        question("Q21", status: "answered", text: "Should this old question still be used?"),
        question("Q24", text: "Which region should receive the build?")
      ]
    )
  end

  def question(id, status: "open", text: "Question #{id}")
    {
      "id" => id,
      "status" => status,
      "question" => text,
      "context" => "picker test"
    }
  end

  def open_picker
    send_key("\r", input_buffer: "/questions")
    compose
  end

  def compose
    compose_app_state(@app, @state)
  end

  def send_key(key, input_buffer: "")
    @app.send(:handle_key, key, input_buffer, input_buffer.length, -1, prompt_handler, compose)
  end

  def prompt_handler
    @prompt_handler ||= lambda do |text, **_options|
      @submitted << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end
  end

  def wait_for_submissions(count)
    deadline = Time.now + 5
    sleep 0.01 while @submitted.length < count && Time.now < deadline
    assert_equal count, @submitted.length, "expected #{count} submitted command(s), got #{@submitted.inspect}"
    @submitted
  end

  def press_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(position)
  end

  def screen_position_for_row(state, index)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        hit = @layout.question_picker_hit(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        return { "x" => x + 1, "y" => y + 1 } if hit == index
      end
    end
    flunk "no screen position maps to question picker row #{index}"
  end
end
