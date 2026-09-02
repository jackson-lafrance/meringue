# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(__dir__)

require "minitest/autorun"
require "fileutils"
require "json"
require "set"
require "tmpdir"
require "meringue"

# Meringue::TUI::Style is process-global: configure! rewrites the ANSI constants in
# place. A kernel SaveConfiguration that carries a theme (onboarding tests pass
# "appearance.theme" => "gruvbox") leaves the whole process on that theme, and any
# later test in the same shard that assumes the default scheme then fails depending on
# file order. Snapshot the scheme around every test so no test can leak colour state.
module RestoreTuiColorscheme
  def before_setup
    @meringue_colorscheme_before_test = Meringue::TUI::Style.current_colorscheme
    super
  end

  def after_teardown
    super
  ensure
    before = @meringue_colorscheme_before_test
    Meringue::TUI::Style.configure!(before) if before && Meringue::TUI::Style.current_colorscheme != before
  end
end

Minitest::Test.include(RestoreTuiColorscheme)
