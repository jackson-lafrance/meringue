# frozen_string_literal: true

require "test_helper"

class FoundationCommandBlacklistTest < Minitest::Test
  Blacklist = Meringue::CommandBlacklist

  def test_empty_configuration_allows_every_command
    blacklist = Blacklist.new(nil)

    assert blacklist.empty?
    assert_nil blacklist.match("gh pr comment 12 --body nope")
  end

  def test_globs_match_the_complete_raw_command_with_only_star_and_question_special
    pattern = "*gh api *pulls/*/comments/?/replies*"

    assert Blacklist.glob_match?(pattern, "cd repo && gh api repos/acme/app/pulls/7/comments/3/replies -f body=done")
    assert Blacklist.glob_match?("*", "line one\nline two"), "star includes newlines"
    assert Blacklist.glob_match?("gh pr comment ?", "gh pr comment 7")
    refute Blacklist.glob_match?("gh pr comment ?", "gh pr comment 77")
    refute Blacklist.glob_match?("*gh pr comment*", "GH PR COMMENT 7"), "matching is case-sensitive"
    assert Blacklist.glob_match?("*[body]*", "echo '[body]'"), "regular-expression punctuation is literal"
  end

  def test_first_matching_pattern_identifies_direct_comments_and_api_replies
    patterns = [
      "*gh pr comment *",
      "*gh api *pulls/*/comments/*/replies*"
    ]
    blacklist = Blacklist.new(patterns)

    assert_equal patterns[0], blacklist.match("gh pr comment 135 --body-file /tmp/reply.md")
    assert_equal patterns[1], blacklist.match(
      "gh api --method POST repos/shop/world/pulls/988109/comments/3754624124/replies -f body='done'"
    )
    assert_equal patterns[1], blacklist.match(
      "cd src && gh api repos/shop/world/pulls/959763/comments/3722703743/replies -f body=\"$(cat reply.md)\""
    )
    assert_nil blacklist.match("gh pr view 135 --json comments")
    assert_nil blacklist.match("gh api repos/shop/world/pulls/135/comments")
  end

  def test_configuration_rejects_unsafe_or_ambiguous_shapes
    cases = [
      ["not an array", /must be an array/],
      [[""], /must not be empty/],
      [[7], /must be a string/],
      [["bad\u0000pattern"], /control character/],
      [["x" * (Blacklist::MAX_PATTERN_LENGTH + 1)], /at most 512/],
      [Array.new(Blacklist::MAX_PATTERNS + 1, "safe"), /at most 100/]
    ]

    cases.each do |value, message|
      error = assert_raises(Blacklist::ConfigurationError) { Blacklist.new(value) }
      assert_match message, error.message
    end
  end

  def test_config_factory_reads_the_documented_key
    config = Meringue::Config.new(
      { "commands" => { "worker_blacklist" => ["*gh pr comment *"] } },
      path: "/tmp/config.toml"
    )

    assert_equal ["*gh pr comment *"], Blacklist.from_config(config).patterns
  end

  def test_pi_extension_blocks_bash_before_execution_with_the_matching_pattern_in_the_reason
    source = File.read(Meringue::Harness::Registry::COMMAND_BLACKLIST_EXTENSION)

    assert_includes source, 'pi.on("tool_call"'
    assert_includes source, 'event.toolName !== "bash"'
    assert_includes source, "block: true"
    assert_includes source, "Command blocked by Meringue worker blacklist pattern"
    assert_includes source, "globMatches(pattern, command)"
  end
end
