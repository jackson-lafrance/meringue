# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# `lib/meringue/kernel/engine.rb` reached 20,889 lines and 867 methods in one class before it was
# split by command family. At that size nobody reads the file, which is how it came to define the
# same method twice three separate times - once making a public accessor private and breaking every
# embedder that called it, once turning a whole command handler into dead code.
#
# This test is the ratchet that keeps that from happening again silently. It is deliberately not a
# style rule: the ceiling is generous, and the files that are still over it are listed by name with
# their current size, so growing one of them fails here and has to be a decision rather than an
# accident.
class FoundationSourceLayoutTest < Minitest::Test
  # Roughly "still navigable in one sitting". Well above every file this repository writes on
  # purpose, and far below the size at which duplicate definitions hide.
  MAX_LINES = 1_200

  # Files that predate the ceiling. Each entry is the size it may not exceed, so these can shrink
  # or be split but never grow by accident. Raising one is allowed, but it has to be an edit to
  # this list with a reason - which is the whole mechanism. Splitting one means deleting its entry.
  GRANDFATHERED = {
    "lib/meringue/workspace/manager.rb" => 3_183,
    "lib/meringue/harness/pi_client.rb" => 2_599,
    # Lowered when the empty-pane copy moved to tui/first_run.rb. These may
    # shrink but never grow, so the reclaimed room is locked in rather than left
    # as headroom for the next accidental addition.
    "lib/meringue/tui/panes/chat_pane.rb" => 2_020,
    "lib/meringue/tui/layout.rb" => 1_522,
    "lib/meringue/input/slash_command_parser.rb" => 1_302
  }.freeze

  def test_no_source_file_grows_past_the_ceiling
    offenders = source_files.filter_map do |path, length|
      limit = GRANDFATHERED.fetch(path, MAX_LINES)
      next if length <= limit

      "#{path} is #{length} lines (limit #{limit})"
    end

    assert_empty offenders,
                 "split the file by responsibility, or raise its entry deliberately:\n  #{offenders.join("\n  ")}"
  end

  def test_the_grandfathered_list_names_only_files_that_still_need_it
    lengths = source_files.to_h
    stale = GRANDFATHERED.filter_map do |path, limit|
      length = lengths[path]
      next "#{path} is no longer a source file" unless length
      next "#{path} is #{length} lines, under the #{MAX_LINES} ceiling" if length <= MAX_LINES

      nil
    end

    assert_empty stale, "remove these from GRANDFATHERED:\n  #{stale.join("\n  ")}"
  end

  private

  def source_files
    Dir[FoundationSupport.repo_path("lib", "**", "*.rb")].sort.map do |path|
      [path.delete_prefix("#{FoundationSupport::REPO_ROOT}/"), File.readlines(path).length]
    end
  end
end
