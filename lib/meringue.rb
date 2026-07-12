# frozen_string_literal: true

module Meringue
  ROOT = File.expand_path("..", __dir__)

  def self.root_path(*parts)
    File.join(ROOT, *parts)
  end
end

require_relative "meringue/version"
require_relative "meringue/state/models"
require_relative "meringue/state/store"
require_relative "meringue/kernel/commands"
require_relative "meringue/kernel/results"
require_relative "meringue/kernel/engine"
require_relative "meringue/input/slash_command_parser"
require_relative "meringue/input/router"
require_relative "meringue/workspace/manager"
require_relative "meringue/tui/style"
require_relative "meringue/tui/canvas"
require_relative "meringue/tui/terminal"
require_relative "meringue/tui/agent_tree_navigation"
require_relative "meringue/tui/pull_request_opener"
require_relative "meringue/tui/panes/chat_pane"
require_relative "meringue/tui/panes/agent_tree_pane"
require_relative "meringue/tui/panes/log_pane"
require_relative "meringue/tui/layout"
require_relative "meringue/tui/app"
require_relative "meringue/harness/client"
require_relative "meringue/harness/fake_client"
require_relative "meringue/harness/pi_client"
require_relative "meringue/harness/terminal_session_opener"
require_relative "meringue/heads/context"
require_relative "meringue/heads/runner"
require_relative "meringue/heads/fake_runner"
require_relative "meringue/heads/pi_runner"
require_relative "meringue/heads/prompt_loop"
require_relative "meringue/heads/simple_loop"
require_relative "meringue/app"
require_relative "meringue/cli"
