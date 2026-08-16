# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# `/models` used to print the whole harness catalog into the visible log: 100+
# lines the user could not act on, truncated with a hint that pointed at a
# different command. It now opens a searchable picker over the same
# kernel-cached snapshot, and selecting a row is applied as
# `/model <provider/model>` so the kernel stays the only writer of session
# defaults.
class TuiModelPickerTest < Minitest::Test
  include TUISupport

  ModelPicker = Meringue::TUI::ModelPicker
  Pane = Meringue::TUI::Panes::ChatPane
  # Matches TUI::App's default render size, which is what its mouse hit testing
  # uses before the first real frame.
  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT
  CTRL_R = "\u0012"

  def setup
    @submitted = []
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    )
    @pane = Pane.new
    @state = state_with_catalog
  end

  def teardown
    wait_for_submissions(@submitted.length)
  end

  def test_slash_models_opens_the_picker_instead_of_listing_the_catalog
    picker = open_picker

    assert @pane.model_picker?(picker)
    assert_equal "models (pi)", @pane.popup_pane_title(picker)
    # Nothing was sent to the kernel: opening the picker only reads state.
    assert_empty @submitted

    rows = plain_lines(@pane.popup_lines(picker))
    assert_equal 4, rows.length
    # The saved default comes first and says so, then providers in order.
    assert_equal "› openai/gpt-5.6-sol  current default · GPT-5.6 Sol · thinking: off, low, high", rows.fetch(0)
    assert_equal "  anthropic/claude-opus-5  Claude Opus 5 · thinking: xhigh, max", rows.fetch(1)
    assert_equal %w[openai/gpt-5.6-sol anthropic/claude-opus-5 openai/gpt-5.6-mini xai/grok-5],
                 rows.map { |row| row.split(/\s+/).fetch(1) }

    frame = render_frame(picker, width: WIDTH, height: HEIGHT)
    assert_includes frame, "models (pi)"
    assert_includes frame, "anthropic/claude-opus-5"
  end

  def test_the_picker_captions_its_keys_and_count_below_the_list
    caption = plain_line(@pane.popup_footer_line(open_picker))

    assert_equal "4 models", caption.split("  ·  ").first
    assert_includes caption, "type to filter"
    assert_includes caption, "Enter sets the default"
    assert_includes caption, "Ctrl-R refreshes"
    assert_includes caption, "Esc closes"
  end

  def test_typing_filters_the_list_and_backspace_widens_it_again
    open_picker
    "opus".each_char { |character| send_key(character) }
    filtered = compose

    assert_equal ["  anthropic/claude-opus-5  Claude Opus 5 · thinking: xhigh, max"].map(&:strip),
                 plain_lines(@pane.popup_lines(filtered)).map(&:strip).map { |row| row.delete_prefix("› ") }
    assert_includes plain_line(@pane.popup_footer_line(filtered)), "filter: opus"

    # Multiple tokens narrow further: provider plus a thinking level.
    reopen_picker
    "openai high".each_char { |character| send_key(character) }
    assert_equal ["openai/gpt-5.6-sol"], picker_references

    # Backspace walks the query back one character at a time; Ctrl-W clears it.
    5.times { send_key("\u007f") }
    assert_equal %w[openai/gpt-5.6-sol openai/gpt-5.6-mini], picker_references

    send_key("\u0017")
    assert_equal 4, picker_references.length
  end

  def test_a_query_that_matches_nothing_says_so_instead_of_showing_an_empty_box
    open_picker
    "zzz".each_char { |character| send_key(character) }
    state = compose

    assert_equal ["No pi model matches “zzz”."], plain_lines(@pane.popup_lines(state))
  end

  def test_enter_applies_the_highlighted_model_as_a_slash_model_command
    open_picker
    send_key("\e[B")
    moved = compose

    assert_equal 1, @pane.model_picker_index(moved)

    send_key("\r")
    assert_equal ["/model anthropic/claude-opus-5"], wait_for_submissions(1)
    refute @pane.model_picker?(compose)
  end

  # Reported bug: a Fireworks router model whose id contains slashes and a colon
  # (`fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`) is in the
  # catalog Pi reports, so it must be listed, searchable, and applicable from the
  # picker. It used to list fine and then be rejected by the kernel's one-slash
  # rule the moment Enter turned it into `/model <reference>`.
  def test_a_multi_segment_model_id_is_listed_searchable_and_applied
    reference = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
    @state = state_with_catalog(
      catalogs: {
        "pi" => catalog_snapshot(
          "pi",
          models: [
            { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol" },
            { "provider" => "fireworks", "id" => "fireworks:accounts/fireworks/routers/glm-5p2-fast",
              "name" => "GLM 5.2 Fast (Fireworks)" }
          ]
        )
      }
    )

    open_picker
    assert_includes picker_references, reference

    "glm-5p2".each_char { |character| send_key(character) }
    assert_equal [reference], picker_references

    send_key("\r")
    assert_equal ["/model #{reference}"], wait_for_submissions(1)
  end

  def test_the_highlight_wraps_so_the_last_model_is_one_key_away
    open_picker
    send_key("\e[A")

    assert_equal 3, @pane.model_picker_index(compose)
  end

  def test_escape_closes_the_picker_without_changing_anything
    open_picker
    send_key("\e")

    refute @pane.model_picker?(compose)
    assert_empty @submitted
  end

  # Refreshing is the kernel's job. The picker submits the kernel spelling of the
  # command so the re-fetch is validated, journaled, and logged like any other
  # kernel command instead of being a hidden side effect of a UI key.
  def test_ctrl_r_asks_the_kernel_to_refresh_and_keeps_the_picker_open
    open_picker
    send_key(CTRL_R)

    assert_equal ["/models refresh"], wait_for_submissions(1)
    assert @pane.model_picker?(compose)
  end

  def test_a_harness_argument_scopes_the_picker_and_its_refresh
    @state = state_with_catalog(
      catalogs: {
        "pi" => catalog_snapshot("pi"),
        "claude" => catalog_snapshot("claude", models: [{ "provider" => "anthropic", "id" => "claude-sonnet-9" }])
      }
    )
    picker = open_picker("/models claude")

    assert_equal "models (claude)", @pane.popup_pane_title(picker)
    assert_equal ["anthropic/claude-sonnet-9"], picker_references

    send_key(CTRL_R)
    assert_equal ["/models claude refresh"], wait_for_submissions(1)
  end

  # The degraded states the kernel records explicitly must read as an
  # explanation, never as "this harness has no models".
  def test_an_unavailable_catalog_explains_itself_instead_of_showing_an_empty_list
    @state = state_with_catalog(
      catalogs: {
        "pi" => Meringue::Harness::ModelCatalog.unavailable(
          harness: "pi",
          note: "pi rpc get_available_models timed out"
        ).to_h
      }
    )
    state = open_picker
    row = plain_lines(@pane.popup_lines(state)).fetch(0)

    assert_includes row, "pi model catalog unavailable"
    assert_includes row, "timed out"
    assert_includes row, "/model"
    assert_empty picker_references

    # Enter cannot silently do nothing: there is no row to apply.
    send_key("\r")
    assert_empty @submitted
    assert_includes messages_text, "pi model catalog unavailable"
  end

  def test_an_unsupported_harness_says_it_has_no_catalog_at_all
    @state = state_with_catalog(
      active_harness: "antigravity",
      catalogs: { "antigravity" => Meringue::Harness::ModelCatalog.unsupported(harness: "antigravity").to_h }
    )
    state = open_picker
    row = plain_lines(@pane.popup_lines(state)).fetch(0)

    assert_includes row, "does not expose a model catalog"
    assert_equal "models (antigravity)", @pane.popup_pane_title(state)
  end

  # A stale list is still the harness's own answer, so it stays listed in full and
  # is labelled rather than hidden behind the failed refresh.
  def test_a_stale_catalog_is_listed_and_labelled
    stale = Meringue::Harness::ModelCatalog.retained(
      previous: Meringue::Harness::ModelCatalog.from_h(catalog_snapshot("pi")),
      failure: Meringue::Harness::ModelCatalog.unavailable(harness: "pi", note: "refresh failed")
    )
    @state = state_with_catalog(catalogs: { "pi" => stale.to_h })
    picker = open_picker

    assert_equal 4, picker_references.length
    assert_includes plain_line(@pane.popup_footer_line(picker)), "last confirmed"
  end

  def test_stale_catalog_state_label_uses_the_shared_recency_timestamp
    previous = Meringue::Harness::ModelCatalog.available(
      harness: "pi",
      models: [{ "provider" => "openai", "id" => "gpt-5" }],
      fetched_at: "2026-08-12T18:28:00Z"
    )
    stale = Meringue::Harness::ModelCatalog.retained(
      previous: previous,
      failure: Meringue::Harness::ModelCatalog.unavailable(harness: "pi", note: "refresh failed")
    )
    state = state_with_catalog(catalogs: { "pi" => stale.to_h })
    now = Time.new(2026, 8, 16, 14, 30, 0, "-04:00")

    assert_equal "last confirmed [wed 14:28]", ModelPicker.state_label(state, now: now)
  end

  def test_clicking_a_row_applies_it_and_clicking_away_dismisses_the_picker
    picker = open_picker
    send_key(press_event(screen_position_for_row(picker, 2)))

    assert_equal ["/model openai/gpt-5.6-mini"], wait_for_submissions(1)
    refute @pane.model_picker?(compose)

    open_picker
    send_key(press_event({ "x" => 3, "y" => 3 }))

    refute @pane.model_picker?(compose)
  end

  # The picker is a search box while it is up, so an unrelated control key closes
  # it rather than being swallowed.
  def test_an_unhandled_control_key_closes_the_picker
    open_picker
    @app.send(:handle_key, "\t", "", 0, -1, nil, compose)

    refute @pane.model_picker?(compose)
  end

  def test_the_picker_shows_more_rows_than_the_slash_command_popup
    models = (1..30).map { |index| { "provider" => "openai", "id" => "model-#{format("%02d", index)}" } }
    @state = state_with_catalog(catalogs: { "pi" => catalog_snapshot("pi", models: models) })
    picker = open_picker

    assert_equal Pane::MODEL_PICKER_VISIBLE_LIMIT, @pane.popup_lines(picker).length
    assert_operator Pane::MODEL_PICKER_VISIBLE_LIMIT, :>, Pane::VISIBLE_SUGGESTION_LIMIT
    assert_equal "1–#{Pane::MODEL_PICKER_VISIBLE_LIMIT} of 30 models",
                 plain_line(@pane.popup_footer_line(picker)).split("  ·  ").first

    lines = render_frame(picker, width: WIDTH, height: HEIGHT).split("\n", -1)
    assert_equal HEIGHT, lines.length
    assert_includes render_frame(picker, width: WIDTH, height: HEIGHT), "openai/model-01"
  end

  # View-model level checks, independent of rendering.
  def test_entries_and_messages_come_from_the_kernel_cached_snapshot_only
    assert_equal "pi", ModelPicker.harness_for(@state)
    assert_equal "claude", ModelPicker.harness_for(@state, "claude_code")
    assert_equal 4, ModelPicker.count(@state)
    assert_equal "openai/gpt-5.6-sol", ModelPicker.entry_at(@state, 0).fetch("reference")
    assert_nil ModelPicker.state_label(@state)
    assert_includes ModelPicker.empty_message(empty_state), "has not fetched"
  end

  private

  def state_with_catalog(catalogs: nil, active_harness: "pi", default_model: "openai/gpt-5.6-sol")
    empty_state.merge(
      "metadata" => {
        "active_harness" => active_harness,
        "pi_session_defaults" => { "model" => default_model, "thinking_level" => "high" },
        "harness_model_catalogs" => catalogs || { "pi" => catalog_snapshot("pi") }
      }
    )
  end

  def catalog_snapshot(harness, models: nil)
    Meringue::Harness::ModelCatalog.available(
      harness: harness,
      models: models || [
        { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol", "thinking_levels" => %w[off low high] },
        { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5", "thinking_levels" => %w[xhigh max] },
        { "provider" => "openai", "id" => "gpt-5.6-mini" },
        { "provider" => "xai", "id" => "grok-5" }
      ],
      source: "test_catalog"
    ).to_h
  end

  def open_picker(text = "/models")
    send_key("\r", input_buffer: text)
    compose
  end

  # Enter belongs to the picker while it is up, so it has to be closed before the
  # composer can submit `/models` again.
  def reopen_picker(text = "/models")
    send_key("\e")
    open_picker(text)
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

  def picker_references
    ModelPicker.entries(
      @state,
      harness: @app.instance_variable_get(:@model_picker_harness),
      query: @app.instance_variable_get(:@model_picker_query)
    ).map { |entry| entry.fetch("reference") }
  end

  def messages_text
    @app.instance_variable_get(:@messages).map { |message| message.fetch("text", "") }.join("\n")
  end

  # Slash submissions run on a background thread, exactly as typed ones do.
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
        hit = @layout.model_picker_hit(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        return { "x" => x + 1, "y" => y + 1 } if hit == index
      end
    end
    flunk "no screen position maps to picker row #{index}"
  end
end
