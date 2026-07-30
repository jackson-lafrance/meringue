# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Delivery-PR presentation on the dashboard.
#
# Two different questions share one slot on the bottom hint line:
#
# - Looking at one node (a selected worker/issue, or the jump-mode cursor): show
#   that node's own PR. It must be the PR that belongs to the selection, not
#   whichever PR was attached to the owning issue first.
# - Unscoped "all chat": there is no single PR to show, so report how many are
#   open across the tree and let Ctrl-B open a picker over them.
class TuiOpenPullRequestsPickerTest < Minitest::Test
  include TUISupport

  Delivery = Meringue::TUI::DeliveryPullRequest
  OpenPullRequests = Meringue::TUI::OpenPullRequests
  Pane = Meringue::TUI::Panes::ChatPane
  WIDTH = 100
  HEIGHT = 32

  # Records the URLs Ctrl-B/Enter actually asked to open, without launching a browser.
  class RecordingOpener
    attr_reader :opened

    def initialize(result = { "status" => "opened" })
      @opened = []
      @result = result
    end

    def open(url)
      @opened << url
      @result
    end
  end

  def setup
    @opener = RecordingOpener.new
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      pull_request_opener: @opener
    )
    @pane = Pane.new
    @state = state_with_pull_requests
  end

  # Regression for the stale-number confusion: `delivery_pull_request` is just
  # `delivery_pull_requests.first`, so the oldest PR ever attached to the issue
  # used to win for every worker under it, forever.
  def test_each_worker_gets_the_pull_request_for_its_own_branch
    assert_equal "130", Delivery.for_id(@state, "P1-I1-W1").fetch("number")
    assert_equal "145", Delivery.for_id(@state, "P1-I1-W2").fetch("number")
    # An issue has no branch of its own, so the newest PR that is still live wins.
    assert_equal "145", Delivery.for_id(@state, "P1-I1").fetch("number")
  end

  def test_a_settled_issue_still_shows_what_it_delivered
    issue = issue_record(
      "P1-I9",
      "delivery_pull_requests" => [
        pull_request("70", "state" => "merged"),
        pull_request("71", "state" => "closed")
      ]
    )
    state = empty_state.merge("issues" => [issue])

    assert_equal "71", Delivery.for_id(state, "P1-I9").fetch("number")
    assert_empty OpenPullRequests.entries(state)
    assert OpenPullRequests.tracked?(state)
  end

  def test_selected_worker_hint_names_its_own_pull_request_without_advertising_ctrl_b
    hint = plain_line(@pane.bottom_hint_line(select("P1-I1-W2")))

    assert_includes hint, "PR #145 open"
    refute_includes hint, "Ctrl-B"
    refute_includes hint, "open PRs"
  end

  def test_a_selection_without_a_pull_request_says_so_plainly
    state = empty_state.merge(
      "issues" => [issue_record("P1-I1")],
      "agents" => [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    )
    app = build_app
    assert app.send(:select_agent_tree_item, state, "P1-I1-W1")
    app.send(:exit_agent_tree_navigation)
    hint = plain_line(@pane.bottom_hint_line(compose_app_state(app, state)))

    assert_includes hint, "no PR yet"
    refute_includes hint, "PR unavailable"
  end

  def test_unscoped_chat_counts_open_pull_requests_instead_of_pinning_one
    hint = plain_line(@pane.bottom_hint_line(compose_app_state(@app, @state)))

    assert_includes hint, "2 open PRs"
    refute_includes hint, "PR #"
    assert_equal "2 open PRs", OpenPullRequests.summary_label(@state)
  end

  # The old chip kept showing a specific PR in unscoped chat because the focused
  # workspace agent id outlives the workspace view.
  def test_a_previously_focused_worker_does_not_pin_its_pull_request_to_unscoped_chat
    state = composed_state(@state, workspace: { "agent_id" => "P1-I1-W1" })
    hint = plain_line(@pane.bottom_hint_line(state))

    assert_includes hint, "2 open PRs"
    refute_includes hint, "PR #130"
  end

  def test_tracked_but_settled_pull_requests_read_as_none_open
    state = empty_state.merge("issues" => [issue_record("P1-I1", "delivery_pull_request" => pull_request("70", "state" => "merged"))])

    assert_equal "no open PRs", OpenPullRequests.summary_label(state)
    assert_includes plain_line(@pane.bottom_hint_line(composed_state(state))), "no open PRs"
  end

  def test_a_tree_without_any_pull_request_says_nothing_about_them
    hint = plain_line(@pane.bottom_hint_line(composed_state(empty_state)))

    refute_includes hint, "PR"
    refute OpenPullRequests.tracked?(empty_state)
  end

  def test_unverified_pull_requests_are_listed_as_open_work_and_labelled
    entries = OpenPullRequests.entries(@state)

    assert_equal %w[151 145], entries.map { |entry| entry.fetch("number") }
    assert_equal %w[unverified open], entries.map { |entry| entry.fetch("status") }
    # Delivery records carry no PR title, so the row is named by its issue.
    assert_equal ["Add the open PR picker", "Fix signup validation"], entries.map { |entry| entry.fetch("title") }
    assert_equal %w[P1-I2 P1-I1], entries.map { |entry| entry.fetch("issue_id") }
  end

  def test_ctrl_b_opens_a_picker_listing_every_open_pull_request
    picker = press_ctrl_b

    assert @pane.delivery_pr_picker?(picker)
    assert_equal "open pull requests", @pane.popup_pane_title(picker)
    rows = plain_lines(@pane.popup_lines(picker))
    assert_equal "› #151  Add the open PR picker  P1-I2 · unverified", rows.fetch(0)
    assert_equal "  #145  Fix signup validation  P1-I1 · open", rows.fetch(1)
    assert_includes rows.last, "Enter opens · Esc closes"
    assert_empty @opener.opened

    frame = render_frame(picker, width: WIDTH, height: HEIGHT)
    assert_includes frame, "open pull requests"
    assert_includes frame, "#151"
  end

  def test_arrows_move_the_highlight_and_enter_opens_that_pull_request
    press_ctrl_b
    send_key("\e[B")
    moved = compose_app_state(@app, @state)

    assert_equal 1, @pane.delivery_pr_picker_index(moved)
    assert_equal "› #145  Fix signup validation  P1-I1 · open", plain_lines(@pane.popup_lines(moved)).fetch(1)

    send_key("\r")
    assert_equal ["https://github.com/o/r/pull/145"], @opener.opened
    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))
  end

  def test_the_highlight_wraps_so_the_last_entry_is_one_key_away
    press_ctrl_b
    send_key("\e[A")

    assert_equal 1, @pane.delivery_pr_picker_index(compose_app_state(@app, @state))
  end

  def test_escape_and_ctrl_b_both_close_the_picker_without_opening_anything
    press_ctrl_b
    send_key("\e")

    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))

    press_ctrl_b
    send_key("\u0002")

    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))
    assert_empty @opener.opened
  end

  def test_clicking_a_row_opens_it_and_clicking_away_dismisses_the_picker
    picker = press_ctrl_b
    row = screen_position_for_row(picker, 1)
    send_key(press_event(row))

    assert_equal ["https://github.com/o/r/pull/145"], @opener.opened
    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))

    press_ctrl_b
    send_key(press_event({ "x" => 3, "y" => 3 }))

    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))
    assert_equal 1, @opener.opened.length
  end

  # A modal that swallows typing would strand the user, so any other key closes
  # the picker and is then handled normally.
  def test_typing_closes_the_picker_and_still_reaches_the_composer
    press_ctrl_b
    buffer, cursor, = @app.send(:handle_key, "h", "", 0, -1, nil, compose_app_state(@app, @state))

    assert_equal ["h", 1], [buffer, cursor]
    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))
  end

  def test_ctrl_b_with_nothing_open_reports_it_instead_of_an_empty_picker
    state = empty_state.merge("issues" => [issue_record("P1-I1", "delivery_pull_request" => pull_request("70", "state" => "merged"))])
    @app.send(:handle_key, "\u0002", "", 0, -1, nil, composed_state(state))

    refute @pane.delivery_pr_picker?(compose_app_state(@app, state))
    assert_empty @opener.opened
    assert_includes @app.instance_variable_get(:@messages).map { |message| message.fetch("text") }.join("\n"), "No delivery pull requests are open"
  end

  def test_a_selected_worker_keeps_ctrl_b_pointed_at_its_own_pull_request
    select("P1-I1-W1")
    @app.send(:handle_key, "\u0002", "", 0, -1, nil, compose_app_state(@app, @state))

    assert_equal ["https://github.com/o/r/pull/130"], @opener.opened
    refute @pane.delivery_pr_picker?(compose_app_state(@app, @state))
  end

  def test_the_working_counts_drop_the_redundant_active_label
    state = composed_state(
      empty_state.merge(
        "agents" => [
          agent_record("P1-I1-W1", "status" => "working"),
          agent_record("H1", "status" => "working")
        ]
      )
    )
    hint = plain_line(@pane.bottom_hint_line(state))

    assert_includes hint, "● 1W 1H"
    refute_includes hint, "active"
  end

  private

  def state_with_pull_requests
    empty_state.merge(
      "projects" => [project_record("P1")],
      "issues" => [
        issue_record(
          "P1-I1",
          "title" => "Fix signup validation",
          "agent_ids" => %w[P1-I1-W1 P1-I1-W2],
          # Oldest first, exactly how the state layer stores them.
          "delivery_pull_requests" => [
            pull_request("130", "state" => "merged", "head_branch" => "meringue/first-pass-a1"),
            pull_request("145", "state" => "open", "head_branch" => "meringue/second-pass-b2")
          ]
        ),
        # Never refreshed by the kernel yet, so its own status is still unverified.
        issue_record("P1-I2", "title" => "Add the open PR picker", "delivery_pull_request" => pull_request("151"))
      ],
      "agents" => [
        agent_record("P1-I1-W1", "issue_id" => "P1-I1", "workspace_branch" => "meringue/first-pass-a1"),
        agent_record("P1-I1-W2", "issue_id" => "P1-I1", "workspace_branch" => "meringue/second-pass-b2"),
        agent_record("P1-I2-W1", "issue_id" => "P1-I2")
      ]
    )
  end

  def pull_request(number, overrides = {})
    {
      "url" => "https://github.com/o/r/pull/#{number}",
      "last_checked_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    }.merge(overrides)
  end

  def select(item_id)
    assert @app.send(:select_agent_tree_item, @state, item_id)
    @app.send(:exit_agent_tree_navigation)
    compose_app_state(@app, @state)
  end

  def press_ctrl_b
    send_key("\u0002")
    compose_app_state(@app, @state)
  end

  def send_key(key)
    @app.send(:handle_key, key, "", 0, -1, nil, compose_app_state(@app, @state))
  end

  def press_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(position)
  end

  def screen_position_for_row(state, index)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        hit = @layout.delivery_pr_picker_hit(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        return { "x" => x + 1, "y" => y + 1 } if hit == index
      end
    end
    flunk "no screen position maps to picker row #{index}"
  end
end
