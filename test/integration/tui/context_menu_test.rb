# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Right-click opens a menu whose entries depend on what was clicked. The registry
# is pure data; the app owns where the box sits, how it is driven, and what an
# entry does when chosen.
class TuiContextMenuTest < Minitest::Test
  include TUISupport

  WIDTH = 100
  HEIGHT = 32
  ContextMenu = Meringue::TUI::ContextMenu

  def setup
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    )
    @state = tree_state(
      projects: [project_record("P1", "root_path" => "/tmp/shared-root", "name" => "Migration")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "working")]
    )
  end

  # --- registry ---------------------------------------------------------------------

  def test_kind_is_derived_from_the_record_and_empty_space_is_background
    assert_equal "project", ContextMenu.kind_for(@state, "P1")
    assert_equal "issue", ContextMenu.kind_for(@state, "P1-I1")
    assert_equal "worker", ContextMenu.kind_for(@state, "P1-I1-W1")
    assert_equal "background", ContextMenu.kind_for(@state, nil)
    assert_equal "background", ContextMenu.kind_for(@state, "P9-I9-W9")
  end

  def test_each_kind_offers_its_own_verbs
    labels = ->(id) { ContextMenu.entries(@state, id).map(&:label) }

    assert_includes labels.call("P1"), "New project here…"
    assert_includes labels.call("P1-I1"), "Spawn worker…"
    assert_includes labels.call("P1-I1-W1"), "Open workspace"
    assert_includes labels.call(nil), "Add project…"
    refute_includes labels.call("P1"), "Open workspace"
  end

  # An unavailable option stays visible and says why, so the menu for a row kind
  # keeps a stable shape.
  def test_unavailable_entries_are_disabled_with_a_reason_rather_than_hidden
    entry = ContextMenu.entries(@state, "P1-I1").find { |candidate| candidate.id == "promote" }

    refute_predicate entry, :enabled?
    assert_equal "already top level", entry.note

    pr = ContextMenu.entries(@state, "P1-I1", github_enabled: false).find { |candidate| candidate.id == "open_pr" }
    refute_predicate pr, :enabled?
    assert_equal "GitHub support is off", pr.note
    assert_predicate ContextMenu.entries(@state, "P1-I1", github_enabled: true).find { |c| c.id == "open_pr" }, :enabled?
  end

  # Moving an issue between boards is only offered when another board actually
  # shares the checkout.
  def test_move_to_project_is_offered_only_when_a_project_shares_the_checkout
    alone = ContextMenu.entries(@state, "P1-I1").find { |entry| entry.id == "move_project" }
    refute_predicate alone, :enabled?

    shared = @state.merge(
      "projects" => @state.fetch("projects") + [project_record("P2", "root_path" => "/tmp/shared-root", "name" => "Resiliency")]
    )
    paired = ContextMenu.entries(shared, "P1-I1").find { |entry| entry.id == "move_project" }
    assert_predicate paired, :enabled?

    elsewhere = @state.merge(
      "projects" => @state.fetch("projects") + [project_record("P2", "root_path" => "/tmp/other-root", "name" => "Other")]
    )
    unrelated = ContextMenu.entries(elsewhere, "P1-I1").find { |entry| entry.id == "move_project" }
    refute_predicate unrelated, :enabled?
  end

  # --- driving the menu -------------------------------------------------------------

  def test_shift_f10_opens_the_menu_for_the_selected_row_without_a_mouse
    @app.send(:select_agent_tree_item, @state, "P1-I1")
    @app.send(:handle_key, "\e[21;2~", "", 0, -1, nil, @state)

    assert @app.send(:context_menu_active?)
    assert_equal "P1-I1", @app.instance_variable_get(:@context_menu).fetch("target_id")
    assert_includes render, "Spawn worker…"
  end

  def test_arrows_skip_disabled_entries_and_enter_drafts_the_command
    open_menu_for("P1-I1")
    # Opening lands on the first entry the user can actually pick.
    assert_predicate selected_entry.fetch("enabled"), :itself

    buffer, cursor, = activate("Rename…")

    assert_equal "/issue rename P1-I1 ", buffer
    assert_equal buffer.length, cursor
    refute @app.send(:context_menu_active?)
  end

  def test_moving_through_the_menu_never_selects_a_disabled_entry
    open_menu_for("P1-I1")
    entries = @app.instance_variable_get(:@context_menu).fetch("entries")

    entries.length.times do
      @app.send(:handle_key, "\e[B", "", 0, -1, nil, @state)
      assert selected_entry.fetch("enabled"), "stopped on #{selected_entry.fetch("label")}"
    end
  end

  def test_an_unrecognised_key_dismisses_the_menu_instead_of_typing_into_the_composer
    open_menu_for("P1-I1")

    buffer, = @app.send(:handle_key, "x", "", 0, -1, nil, @state)

    refute @app.send(:context_menu_active?)
    assert_equal "", buffer
  end

  def test_the_menu_renders_inside_the_viewport_even_when_opened_at_the_edge
    @app.send(:open_context_menu, @state, "P1-I1", x: WIDTH + 40, y: HEIGHT + 40)
    geometry = @layout.context_menu_geometry(compose, width: WIDTH, height: HEIGHT)

    assert_operator geometry.fetch(:x) + geometry.fetch(:width), :<=, WIDTH
    assert_operator geometry.fetch(:y) + geometry.fetch(:height), :<=, HEIGHT
    frame = render
    assert_equal HEIGHT, frame.lines.length
    assert_equal [WIDTH], frame.split("\n", -1).map(&:length).uniq
  end

  def test_background_menu_offers_tree_wide_actions
    @app.send(:open_context_menu, @state, nil, x: 5, y: 5)

    labels = @app.instance_variable_get(:@context_menu).fetch("entries").map { |entry| entry.fetch("label") }
    assert_equal ["Add project…", "Open pull requests", "Prune resolved", "Recount ids"], labels

    buffer, = activate("Add project…")
    assert_equal "/project add ", buffer
  end

  # A second board over one directory is created from the project's own menu, so
  # the path is filled in rather than retyped.
  def test_project_menu_drafts_a_sibling_project_at_the_same_path
    open_menu_for("P1")

    buffer, = activate("New project here…")

    assert_equal "/project add /tmp/shared-root ", buffer
  end

  private

  def compose
    compose_app_state(@app, @state)
  end

  def render
    @app.render(compose, width: WIDTH, height: HEIGHT, color: false)
  end

  def open_menu_for(id)
    @app.send(:open_context_menu, @state, id, x: 6, y: 4)
  end

  def selected_entry
    @app.send(:selected_context_menu_entry)
  end

  def activate(label)
    entries = @app.instance_variable_get(:@context_menu).fetch("entries")
    index = entries.index { |entry| entry.fetch("label") == label }
    flunk "no entry labelled #{label.inspect}" unless index

    @app.instance_variable_get(:@context_menu)["index"] = index
    @app.send(:handle_key, "\r", "", 0, -1, nil, @state)
  end
end
