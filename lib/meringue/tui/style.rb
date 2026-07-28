# frozen_string_literal: true

module Meringue
  module TUI
    module Style
      RESET = "\e[0m"
      DEFAULT_COLORSCHEME = "meringue"

      STYLE_NAMES = %i[
        TEXT
        MUTED
        DIM
        BORDER
        BORDER_ACTIVE
        ACCENT
        ACCENT_BOLD
        AGENT_TREE_SELECTED
        AGENT_TREE_SELECTED_DIM
        AGENT_TREE_SELECTED_STATUS
        PR_MARKER
        PR_MARKER_SELECTED
        TITLE
        PANEL_TITLE
        HEADER
        HEADER_MUTED
        SUCCESS
        WARNING
        ERROR
        WORKING
        QUEUED
        IDLE
        USER
        ASSISTANT
        WORKSPACE_OUTPUT
        WORKSPACE_FINAL
        WORKSPACE_REASONING
        WORKSPACE_TOOL_CALL
        WORKSPACE_TOOL_RESULT
        LOG_INFO
        LOG_COMMAND
        LOG_WARNING
        LOG_ERROR
      ].freeze

      # Per-agent log colors. Each colorscheme supplies the same number of
      # 256-color foreground codes, ordered red, orange, yellow, green, cyan,
      # blue, purple, magenta, so every theme keeps the same hue spread.
      AGENT_PALETTE_KEY = :AGENT_PALETTE
      AGENT_PALETTE_SIZE = 8
      HEAD_AGENT_KIND = "head"
      WORKER_AGENT_KIND = "worker"

      class StyleValue < String; end

      module_function

      def ansi(*codes)
        "\e[#{codes.flatten.join(";")}m"
      end

      # Compose semantic terminal attributes with a colorscheme or per-agent
      # foreground. Canvas owns emission, so these values never enter content.
      def with_codes(style, *codes)
        "#{style}#{ansi(*codes)}"
      end

      # Deterministic FNV-1a hash so an unchanged agent id keeps the same color
      # across renders and restarts without storing palette assignments.
      def agent_palette_index(agent_id)
        hash = 2166136261
        agent_id.to_s.each_byte do |byte|
          hash = ((hash ^ byte) * 16777619) & 0xffffffff
        end
        hash % AGENT_PALETTE_SIZE
      end

      # Header style for an agent's log lines. Heads are bold so they stay
      # distinguishable from workers that hash to the same palette slot.
      def agent_style(agent_id, kind: WORKER_AGENT_KIND)
        agent_styles.fetch(head_kind?(kind) ? HEAD_AGENT_KIND : WORKER_AGENT_KIND).fetch(agent_palette_index(agent_id))
      end

      # Body/gutter style for an agent's log lines: same hue, never bold.
      def agent_body_style(agent_id)
        agent_styles.fetch(WORKER_AGENT_KIND).fetch(agent_palette_index(agent_id))
      end

      def head_kind?(kind)
        kind.to_s == HEAD_AGENT_KIND
      end

      def agent_styles
        @agent_styles ||= build_agent_styles(SCHEMES.fetch(current_colorscheme).fetch(AGENT_PALETTE_KEY))
      end

      def build_agent_styles(palette)
        {
          HEAD_AGENT_KIND => palette.map { |code| ansi(1, 38, 5, code).freeze }.freeze,
          WORKER_AGENT_KIND => palette.map { |code| ansi(38, 5, code).freeze }.freeze
        }.freeze
      end

      def colorschemes
        SCHEMES.keys.sort
      end

      def current_colorscheme
        @current_colorscheme || DEFAULT_COLORSCHEME
      end

      def configure!(colorscheme = DEFAULT_COLORSCHEME)
        name = normalize_colorscheme_name(colorscheme)
        scheme = SCHEMES[name]
        unless scheme
          raise ArgumentError, "Unknown TUI colorscheme #{colorscheme.inspect}. Available colorschemes: #{colorschemes.join(", ")}"
        end

        STYLE_NAMES.each do |style_name|
          const_get(style_name).replace(ansi(*scheme.fetch(style_name)))
        end
        @agent_styles = build_agent_styles(scheme.fetch(AGENT_PALETTE_KEY))
        @current_colorscheme = name
      end

      def normalize_colorscheme_name(colorscheme)
        name = colorscheme.to_s.strip.downcase.tr("_", "-")
        name.empty? ? DEFAULT_COLORSCHEME : ALIASES.fetch(name, name)
      end

      STYLE_NAMES.each do |style_name|
        const_set(style_name, StyleValue.new)
      end

      # The rose-pine scheme intentionally preserves the palette that shipped
      # before colorschemes were configurable.
      ROSE_PINE = {
        TEXT: [38, 5, 252],
        MUTED: [38, 5, 245],
        DIM: [38, 5, 240],
        BORDER: [38, 5, 238],
        BORDER_ACTIVE: [38, 5, 141],
        ACCENT: [38, 5, 177],
        ACCENT_BOLD: [1, 38, 5, 183],
        AGENT_TREE_SELECTED: [1, 38, 5, 231, 48, 5, 61],
        AGENT_TREE_SELECTED_DIM: [38, 5, 189, 48, 5, 61],
        AGENT_TREE_SELECTED_STATUS: [1, 38, 5, 159, 48, 5, 61],
        PR_MARKER: [1, 38, 5, 51],
        PR_MARKER_SELECTED: [1, 38, 5, 51, 48, 5, 61],
        TITLE: [1, 38, 5, 255],
        PANEL_TITLE: [1, 38, 5, 225],
        HEADER: [1, 38, 5, 255, 48, 5, 235],
        HEADER_MUTED: [38, 5, 250, 48, 5, 235],
        SUCCESS: [38, 5, 114],
        WARNING: [38, 5, 221],
        ERROR: [38, 5, 203],
        WORKING: [1, 38, 5, 141],
        QUEUED: [38, 5, 109],
        IDLE: [38, 5, 246],
        USER: [1, 38, 5, 117],
        ASSISTANT: [1, 38, 5, 183],
        WORKSPACE_OUTPUT: [38, 5, 252],
        WORKSPACE_FINAL: [1, 38, 5, 183],
        WORKSPACE_REASONING: [38, 5, 141],
        WORKSPACE_TOOL_CALL: [38, 5, 117],
        WORKSPACE_TOOL_RESULT: [38, 5, 114],
        LOG_INFO: [38, 5, 117],
        LOG_COMMAND: [38, 5, 203],
        LOG_WARNING: [38, 5, 221],
        LOG_ERROR: [38, 5, 203],
        AGENT_PALETTE: [174, 216, 222, 151, 116, 110, 141, 176]
      }.freeze

      MERINGUE = {
        TEXT: [38, 5, 231],
        MUTED: [38, 5, 250],
        DIM: [38, 5, 242],
        BORDER: [38, 5, 238],
        BORDER_ACTIVE: [38, 5, 220],
        ACCENT: [38, 5, 222],
        ACCENT_BOLD: [1, 38, 5, 226],
        AGENT_TREE_SELECTED: [1, 38, 5, 231, 48, 5, 94],
        AGENT_TREE_SELECTED_DIM: [38, 5, 229, 48, 5, 94],
        AGENT_TREE_SELECTED_STATUS: [1, 38, 5, 226, 48, 5, 94],
        PR_MARKER: [1, 38, 5, 51],
        PR_MARKER_SELECTED: [1, 38, 5, 51, 48, 5, 94],
        TITLE: [1, 38, 5, 231],
        PANEL_TITLE: [1, 38, 5, 229],
        HEADER: [1, 38, 5, 230, 48, 5, 94],
        HEADER_MUTED: [38, 5, 223, 48, 5, 94],
        SUCCESS: [38, 5, 114],
        WARNING: [38, 5, 220],
        ERROR: [38, 5, 203],
        WORKING: [1, 38, 5, 220],
        QUEUED: [38, 5, 179],
        IDLE: [38, 5, 246],
        USER: [1, 38, 5, 231],
        ASSISTANT: [1, 38, 5, 226],
        WORKSPACE_OUTPUT: [38, 5, 231],
        WORKSPACE_FINAL: [1, 38, 5, 226],
        WORKSPACE_REASONING: [38, 5, 183],
        WORKSPACE_TOOL_CALL: [38, 5, 81],
        WORKSPACE_TOOL_RESULT: [38, 5, 114],
        LOG_INFO: [38, 5, 220],
        LOG_COMMAND: [38, 5, 203],
        LOG_WARNING: [38, 5, 214],
        LOG_ERROR: [38, 5, 203],
        # The default theme is yellow, so agent colors skip yellow to stay
        # separable from the kernel/meringue accent styles.
        AGENT_PALETTE: [210, 215, 156, 122, 80, 111, 183, 218]
      }.freeze

      TOKYONIGHT = {
        TEXT: [38, 5, 252],
        MUTED: [38, 5, 110],
        DIM: [38, 5, 60],
        BORDER: [38, 5, 238],
        BORDER_ACTIVE: [38, 5, 111],
        ACCENT: [38, 5, 117],
        ACCENT_BOLD: [1, 38, 5, 159],
        AGENT_TREE_SELECTED: [1, 38, 5, 231, 48, 5, 24],
        AGENT_TREE_SELECTED_DIM: [38, 5, 153, 48, 5, 24],
        AGENT_TREE_SELECTED_STATUS: [1, 38, 5, 120, 48, 5, 24],
        PR_MARKER: [1, 38, 5, 51],
        PR_MARKER_SELECTED: [1, 38, 5, 51, 48, 5, 24],
        TITLE: [1, 38, 5, 255],
        PANEL_TITLE: [1, 38, 5, 147],
        HEADER: [1, 38, 5, 255, 48, 5, 235],
        HEADER_MUTED: [38, 5, 153, 48, 5, 235],
        SUCCESS: [38, 5, 120],
        WARNING: [38, 5, 221],
        ERROR: [38, 5, 203],
        WORKING: [1, 38, 5, 111],
        QUEUED: [38, 5, 109],
        IDLE: [38, 5, 67],
        USER: [1, 38, 5, 117],
        ASSISTANT: [1, 38, 5, 147],
        WORKSPACE_OUTPUT: [38, 5, 252],
        WORKSPACE_FINAL: [1, 38, 5, 147],
        WORKSPACE_REASONING: [38, 5, 141],
        WORKSPACE_TOOL_CALL: [38, 5, 117],
        WORKSPACE_TOOL_RESULT: [38, 5, 120],
        LOG_INFO: [38, 5, 117],
        LOG_COMMAND: [38, 5, 203],
        LOG_WARNING: [38, 5, 221],
        LOG_ERROR: [38, 5, 203],
        AGENT_PALETTE: [210, 216, 222, 150, 117, 111, 141, 176]
      }.freeze

      GRUVBOX = {
        TEXT: [38, 5, 223],
        MUTED: [38, 5, 245],
        DIM: [38, 5, 239],
        BORDER: [38, 5, 237],
        BORDER_ACTIVE: [38, 5, 214],
        ACCENT: [38, 5, 214],
        ACCENT_BOLD: [1, 38, 5, 220],
        AGENT_TREE_SELECTED: [1, 38, 5, 223, 48, 5, 94],
        AGENT_TREE_SELECTED_DIM: [38, 5, 248, 48, 5, 94],
        AGENT_TREE_SELECTED_STATUS: [1, 38, 5, 142, 48, 5, 94],
        PR_MARKER: [1, 38, 5, 51],
        PR_MARKER_SELECTED: [1, 38, 5, 51, 48, 5, 94],
        TITLE: [1, 38, 5, 230],
        PANEL_TITLE: [1, 38, 5, 222],
        HEADER: [1, 38, 5, 223, 48, 5, 236],
        HEADER_MUTED: [38, 5, 248, 48, 5, 236],
        SUCCESS: [38, 5, 142],
        WARNING: [38, 5, 214],
        ERROR: [38, 5, 167],
        WORKING: [1, 38, 5, 214],
        QUEUED: [38, 5, 109],
        IDLE: [38, 5, 243],
        USER: [1, 38, 5, 109],
        ASSISTANT: [1, 38, 5, 220],
        WORKSPACE_OUTPUT: [38, 5, 223],
        WORKSPACE_FINAL: [1, 38, 5, 220],
        WORKSPACE_REASONING: [38, 5, 175],
        WORKSPACE_TOOL_CALL: [38, 5, 109],
        WORKSPACE_TOOL_RESULT: [38, 5, 142],
        LOG_INFO: [38, 5, 109],
        LOG_COMMAND: [38, 5, 167],
        LOG_WARNING: [38, 5, 214],
        LOG_ERROR: [38, 5, 167],
        AGENT_PALETTE: [167, 208, 214, 142, 108, 109, 139, 175]
      }.freeze

      CATPPUCCIN = {
        TEXT: [38, 5, 255],
        MUTED: [38, 5, 146],
        DIM: [38, 5, 60],
        BORDER: [38, 5, 238],
        BORDER_ACTIVE: [38, 5, 183],
        ACCENT: [38, 5, 183],
        ACCENT_BOLD: [1, 38, 5, 219],
        AGENT_TREE_SELECTED: [1, 38, 5, 231, 48, 5, 60],
        AGENT_TREE_SELECTED_DIM: [38, 5, 189, 48, 5, 60],
        AGENT_TREE_SELECTED_STATUS: [1, 38, 5, 158, 48, 5, 60],
        PR_MARKER: [1, 38, 5, 51],
        PR_MARKER_SELECTED: [1, 38, 5, 51, 48, 5, 60],
        TITLE: [1, 38, 5, 255],
        PANEL_TITLE: [1, 38, 5, 219],
        HEADER: [1, 38, 5, 255, 48, 5, 235],
        HEADER_MUTED: [38, 5, 189, 48, 5, 235],
        SUCCESS: [38, 5, 158],
        WARNING: [38, 5, 222],
        ERROR: [38, 5, 210],
        WORKING: [1, 38, 5, 183],
        QUEUED: [38, 5, 110],
        IDLE: [38, 5, 146],
        USER: [1, 38, 5, 117],
        ASSISTANT: [1, 38, 5, 219],
        WORKSPACE_OUTPUT: [38, 5, 255],
        WORKSPACE_FINAL: [1, 38, 5, 219],
        WORKSPACE_REASONING: [38, 5, 183],
        WORKSPACE_TOOL_CALL: [38, 5, 117],
        WORKSPACE_TOOL_RESULT: [38, 5, 158],
        LOG_INFO: [38, 5, 117],
        LOG_COMMAND: [38, 5, 210],
        LOG_WARNING: [38, 5, 222],
        LOG_ERROR: [38, 5, 210],
        AGENT_PALETTE: [210, 216, 223, 151, 116, 111, 183, 218]
      }.freeze

      KANAGAWA = {
        TEXT: [38, 5, 252],
        MUTED: [38, 5, 109],
        DIM: [38, 5, 66],
        BORDER: [38, 5, 238],
        BORDER_ACTIVE: [38, 5, 110],
        ACCENT: [38, 5, 110],
        ACCENT_BOLD: [1, 38, 5, 153],
        AGENT_TREE_SELECTED: [1, 38, 5, 231, 48, 5, 24],
        AGENT_TREE_SELECTED_DIM: [38, 5, 152, 48, 5, 24],
        AGENT_TREE_SELECTED_STATUS: [1, 38, 5, 179, 48, 5, 24],
        PR_MARKER: [1, 38, 5, 51],
        PR_MARKER_SELECTED: [1, 38, 5, 51, 48, 5, 24],
        TITLE: [1, 38, 5, 255],
        PANEL_TITLE: [1, 38, 5, 176],
        HEADER: [1, 38, 5, 252, 48, 5, 235],
        HEADER_MUTED: [38, 5, 152, 48, 5, 235],
        SUCCESS: [38, 5, 108],
        WARNING: [38, 5, 179],
        ERROR: [38, 5, 203],
        WORKING: [1, 38, 5, 110],
        QUEUED: [38, 5, 109],
        IDLE: [38, 5, 66],
        USER: [1, 38, 5, 110],
        ASSISTANT: [1, 38, 5, 176],
        WORKSPACE_OUTPUT: [38, 5, 252],
        WORKSPACE_FINAL: [1, 38, 5, 179],
        WORKSPACE_REASONING: [38, 5, 176],
        WORKSPACE_TOOL_CALL: [38, 5, 110],
        WORKSPACE_TOOL_RESULT: [38, 5, 108],
        LOG_INFO: [38, 5, 110],
        LOG_COMMAND: [38, 5, 203],
        LOG_WARNING: [38, 5, 179],
        LOG_ERROR: [38, 5, 203],
        AGENT_PALETTE: [174, 216, 222, 108, 115, 110, 140, 175]
      }.freeze

      SCHEMES = {
        "catppuccin" => CATPPUCCIN,
        "gruvbox" => GRUVBOX,
        "kanagawa" => KANAGAWA,
        "meringue" => MERINGUE,
        "rose-pine" => ROSE_PINE,
        "tokyonight" => TOKYONIGHT
      }.freeze

      ALIASES = {
        "catppuccin-mocha" => "catppuccin",
        "rosepine" => "rose-pine",
        "tokyo-night" => "tokyonight",
        "tokyo-night-moon" => "tokyonight",
        "tokyonight-moon" => "tokyonight"
      }.freeze

      configure!(DEFAULT_COLORSCHEME)
    end
  end
end
