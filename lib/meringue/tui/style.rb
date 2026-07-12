# frozen_string_literal: true

module Meringue
  module TUI
    module Style
      RESET = "\e[0m"

      module_function

      def ansi(*codes)
        "\e[#{codes.flatten.join(";")}m"
      end

      TEXT = ansi(38, 5, 252)
      MUTED = ansi(38, 5, 245)
      DIM = ansi(38, 5, 240)
      BORDER = ansi(38, 5, 238)
      BORDER_ACTIVE = ansi(38, 5, 141)
      ACCENT = ansi(38, 5, 177)
      ACCENT_BOLD = ansi(1, 38, 5, 183)
      AGENT_TREE_SELECTED = ansi(1, 38, 5, 231, 48, 5, 61)
      AGENT_TREE_SELECTED_DIM = ansi(38, 5, 189, 48, 5, 61)
      AGENT_TREE_SELECTED_STATUS = ansi(1, 38, 5, 159, 48, 5, 61)
      TITLE = ansi(1, 38, 5, 255)
      PANEL_TITLE = ansi(1, 38, 5, 225)
      HEADER = ansi(1, 38, 5, 255, 48, 5, 235)
      HEADER_MUTED = ansi(38, 5, 250, 48, 5, 235)
      SUCCESS = ansi(38, 5, 114)
      WARNING = ansi(38, 5, 221)
      ERROR = ansi(38, 5, 203)
      WORKING = ansi(1, 38, 5, 141)
      QUEUED = ansi(38, 5, 109)
      IDLE = ansi(38, 5, 246)
      USER = ansi(1, 38, 5, 117)
      ASSISTANT = ansi(1, 38, 5, 183)
      LOG_INFO = ansi(38, 5, 117)
      LOG_WARNING = ansi(38, 5, 221)
      LOG_ERROR = ansi(38, 5, 203)
    end
  end
end
