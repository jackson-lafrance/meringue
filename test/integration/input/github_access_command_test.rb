# frozen_string_literal: true

require "test_helper"

class InputGithubAccessCommandTest < Minitest::Test
  def setup
    @parser = Meringue::Input::SlashCommandParser.new
  end

  def test_github_test_maps_to_the_read_only_kernel_command
    command = @parser.parse("/github test")

    assert_equal "TestGitHubAccess", command.type
    assert_empty command.payload
  end

  def test_github_test_rejects_extra_arguments
    command = @parser.parse("/github test now")

    assert_equal "InvalidSlashCommand", command.type
    assert_match(/Usage: \/github test/, command.payload.fetch("message"))
  end
end
