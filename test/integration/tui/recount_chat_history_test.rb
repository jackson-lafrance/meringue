# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"
require "fileutils"

# Chat history is TUI-owned: the pane keeps it in memory and rewrites the whole buffer on every
# append. A recount renames records and the kernel rewrites the ids embedded in that persisted
# history, so the TUI has to re-read it. Otherwise the next appended message writes the stale
# buffer back and a pre-recount id starts naming whichever record inherited it.
class TuiRecountChatHistoryTest < Minitest::Test
  include TUISupport

  App = Meringue::TUI::App

  def setup
    @tmp = Dir.mktmpdir("meringue-tui-recount")
    @store = Meringue::State::Store.new(path: File.join(@tmp, "state.json"))
    @app = App.new(layout: Meringue::TUI::Layout.new, out: StringIO.new,
                   terminal: TUISupport::FakeTerminal.new, log_store: @store)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_chat_history_and_workspace_selection_are_reloaded_after_an_accepted_recount
    seed_state(agent_id: "P4-I2-W1", text: "prompt P4-I2-W1 to keep going")
    @app.restore_logs!(@store.load)
    @app.restore_agent_workspace!(@store.load)
    assert_equal ["prompt P4-I2-W1 to keep going"], buffered_texts

    # What the kernel persisted while renumbering: the same worker, spelled with its new id.
    seed_state(agent_id: "P1-I1-W1", text: "prompt P1-I1-W1 to keep going")
    apply_results([{ "command_type" => "Recount", "status" => "accepted" }])

    assert_equal ["prompt P1-I1-W1 to keep going"], buffered_texts
    assert_equal "P1-I1-W1", @app.instance_variable_get(:@agent_workspace_agent_id)
  end

  def test_an_unrelated_command_result_does_not_reload_chat_history
    seed_state(agent_id: "P4-I2-W1", text: "prompt P4-I2-W1 to keep going")
    @app.restore_logs!(@store.load)
    seed_state(agent_id: "P1-I1-W1", text: "prompt P1-I1-W1 to keep going")

    apply_results([{ "command_type" => "Prune", "status" => "accepted" }])

    assert_equal ["prompt P4-I2-W1 to keep going"], buffered_texts
  end

  def test_a_rejected_recount_does_not_reload_chat_history
    seed_state(agent_id: "P4-I2-W1", text: "prompt P4-I2-W1 to keep going")
    @app.restore_logs!(@store.load)
    seed_state(agent_id: "P1-I1-W1", text: "prompt P1-I1-W1 to keep going")

    apply_results([{ "command_type" => "Recount", "status" => "rejected" }])

    assert_equal ["prompt P4-I2-W1 to keep going"], buffered_texts
  end

  private

  def apply_results(command_results)
    @app.send(:apply_slash_command_results, command_results)
  end

  def buffered_texts
    @app.instance_variable_get(:@messages).map { |message| message.fetch("text") }
  end

  def seed_state(agent_id:, text:)
    project_id = agent_id[/\AP\d+/]
    issue_id = agent_id[/\AP\d+-I\d+/]
    state = Meringue::State::Models.empty_state
    state["projects"] = [{ "id" => project_id, "name" => "Demo", "root_path" => @tmp, "status" => "working",
                           "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z" }]
    state["issues"] = [{ "id" => issue_id, "project_id" => project_id, "title" => "Demo issue",
                         "description" => "", "status" => "working", "agent_ids" => [agent_id],
                         "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z" }]
    state["agents"] = [{ "id" => agent_id, "type" => "worker", "status" => "working", "project_id" => project_id,
                         "issue_id" => issue_id, "title" => "Demo worker", "harness" => "fake",
                         "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z" }]
    state["conversation"] = { "messages" => [{ "id" => 1, "role" => "you", "text" => text,
                                               "timestamp" => "2026-01-01T00:00:00Z" }],
                              "next_message_id" => 1 }
    state["ui"] = { "agent_workspace" => { "selected_agent_id" => agent_id, "view" => "agent", "filter" => "all",
                                           "draft" => "" } }
    @store.save(state, preserve_conversation: false)
    state
  end
end
