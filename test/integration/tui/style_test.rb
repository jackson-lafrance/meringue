# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiStyleTest < Minitest::Test
  include TUISupport

  Style = Meringue::TUI::Style

  def test_every_scheme_defines_every_semantic_style_and_a_full_agent_palette
    Style::SCHEMES.each do |name, scheme|
      Style::STYLE_NAMES.each do |style_name|
        assert scheme.key?(style_name), "#{name} is missing #{style_name}"
        assert_kind_of Array, scheme.fetch(style_name)
        refute_empty scheme.fetch(style_name)
      end
      palette = scheme.fetch(Style::AGENT_PALETTE_KEY)
      assert_equal Style::AGENT_PALETTE_SIZE, palette.length, "#{name} palette size"
      assert palette.all? { |code| code.is_a?(Integer) && code.between?(0, 255) }, "#{name} palette codes"
    end
  end

  def test_colorschemes_are_sorted_and_default_is_meringue
    assert_equal Style::SCHEMES.keys.sort, Style.colorschemes
    assert_equal "meringue", Style::DEFAULT_COLORSCHEME
  end

  def test_configure_replaces_style_values_in_place_and_can_be_restored
    before = Style::TEXT.dup

    with_colorscheme("gruvbox") do
      assert_equal "gruvbox", Style.current_colorscheme
      refute_equal before, Style::TEXT
      assert_equal Style.ansi(*Style::GRUVBOX.fetch(:TEXT)), Style::TEXT
    end

    assert_equal before, Style::TEXT
    assert_equal "meringue", Style.current_colorscheme
  end

  def test_configure_rejects_unknown_colorschemes_without_changing_state
    before = Style::TEXT.dup

    error = assert_raises(ArgumentError) { Style.configure!("no-such-theme") }

    assert_includes error.message, "Unknown TUI colorscheme"
    assert_includes error.message, "tokyonight"
    assert_equal before, Style::TEXT
  end

  def test_colorscheme_names_are_normalized_through_aliases
    assert_equal "tokyonight", Style.normalize_colorscheme_name("Tokyo_Night")
    assert_equal "catppuccin", Style.normalize_colorscheme_name("catppuccin-mocha")
    assert_equal "rose-pine", Style.normalize_colorscheme_name("  RosePine ")
    assert_equal Style::DEFAULT_COLORSCHEME, Style.normalize_colorscheme_name("")
  end

  def test_ansi_and_with_codes_only_emit_sgr_sequences
    assert_equal "\e[1;38;5;220m", Style.ansi(1, 38, 5, 220)
    assert_equal "#{Style::TEXT}\e[1m", Style.with_codes(Style::TEXT, 1)
    assert_match(/\A(?:\e\[[0-9;]*m)+\z/, Style.with_codes(Style::TEXT, 2, 4))
  end

  def test_agent_palette_index_is_deterministic_and_bounded
    index = Style.agent_palette_index("P1-I1-W1")

    assert_equal index, Style.agent_palette_index("P1-I1-W1")
    assert index.between?(0, Style::AGENT_PALETTE_SIZE - 1)

    indexes = (1..40).map { |number| Style.agent_palette_index("P1-I#{number}-W1") }
    assert indexes.all? { |value| value.between?(0, Style::AGENT_PALETTE_SIZE - 1) }
    assert indexes.uniq.length > 1, "hashing should spread agents across the palette"
    # An empty id still hashes deterministically (the FNV-1a offset basis).
    assert_equal 2166136261 % Style::AGENT_PALETTE_SIZE, Style.agent_palette_index("")
  end

  def test_head_styles_are_bold_variants_of_the_same_hue
    worker = Style.agent_style("P1-I1-W1", kind: Style::WORKER_AGENT_KIND)
    head = Style.agent_style("P1-I1-W1", kind: Style::HEAD_AGENT_KIND)

    assert_equal worker, Style.agent_body_style("P1-I1-W1")
    refute_equal worker, head
    assert_match(/\A\e\[1;/, head)
    assert_equal worker.sub("\e[", "\e[1;"), head
  end

  def test_unknown_agent_kind_falls_back_to_worker_styling
    assert_equal Style.agent_style("H9", kind: Style::WORKER_AGENT_KIND), Style.agent_style("H9", kind: "mystery")
    assert Style.head_kind?("head")
    refute Style.head_kind?("worker")
  end

  def test_agent_styles_follow_the_active_colorscheme
    default_style = Style.agent_style("P1-I1-W1")

    with_colorscheme("kanagawa") do
      refute_equal default_style, Style.agent_style("P1-I1-W1")
      assert_equal Style.agent_palette_index("P1-I1-W1"), Style.agent_palette_index("P1-I1-W1")
    end

    assert_equal default_style, Style.agent_style("P1-I1-W1")
  end

  def test_every_colorscheme_renders_the_demo_dashboard_without_raising
    state = composed_state(tui_state)

    Style.colorschemes.each do |name|
      with_colorscheme(name) do
        frame = render_frame(state, width: 100, height: 32, color: true)
        assert_includes strip_ansi(frame), "agent tree"
        assert_match TUISupport::ANSI_PATTERN, frame
      end
    end
  end
end
