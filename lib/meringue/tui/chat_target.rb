# frozen_string_literal: true

module Meringue
  module TUI
    # Presentation of "where will my next chat message go?".
    #
    # LogScope owns the selection itself (see log_scope.rb): `selected_target`
    # always returns a Hash for renderers and `chat_target` returns Hash-or-nil
    # for routing. This module turns that one fact into the composer's chrome:
    # its pane title, border/title styles, prompt marker, placeholder, and the
    # chip on the bottom hint line.
    #
    # The tint is deliberately *not* a new palette. It is the same per-id color
    # the logs pane already uses for that agent's rows (Style::AGENT_PALETTE via
    # Style.agent_palette_index), so a tinted composer reads as "this box talks
    # to the node whose log lines are this color".
    #
    # States, in the order they are resolved:
    #
    # - `slash`      the buffer starts with `/`, so the selection is ignored by
    #                routing. The composer is deliberately untinted; a tinted box
    #                would promise scoping that slash commands never carry.
    # - `agent`      a head/worker row with an owning issue is selected. Tinted
    #                with the selected agent's own log color.
    # - `issue`      an issue row is selected. Tinted with that issue id's color.
    # - `log_only`   a project, or a head with no owning issue, is selected. It
    #                filters logs but does not scope chat, so it stays untinted
    #                and says the head still routes.
    # - `none`       nothing is selected (including a stale selection the kernel
    #                or reconciliation already dropped). Quiet, dim, explicitly
    #                "head routes".
    #
    # Colors are never the only cue: every state also spells the target out in
    # the composer title and chip, so `NO_COLOR`, a 16-color terminal, or a
    # screenshot still says where the prompt is going.
    module ChatTarget
      AGENT = "agent"
      ISSUE = "issue"
      LOG_ONLY = "log_only"
      NONE = "none"
      SLASH = "slash"

      TARGET_MARKER = "⌖"
      # Issue titles are user-written and can be long; the composer title is one
      # border row, so keep it scannable.
      MAX_TITLE_LENGTH = 34

      module_function

      # One frame's worth of composer-target facts. Panes and the layout read
      # this instead of re-deriving the state from LogScope.
      def presentation(state)
        target = LogScope.selected_target(state)
        issue_id = target.fetch("issue_id", "").to_s
        label = LogScope.label(state)
        kind = kind_for(state, issue_id, label)
        agent_id = target.fetch("selected_agent_id", "").to_s
        tint_id = tint_id_for(kind, agent_id, issue_id)

        {
          "kind" => kind,
          "targeted" => %w[agent issue].include?(kind),
          "label" => label,
          "issue_id" => issue_id,
          "issue_title" => target.fetch("issue_title", "").to_s,
          "agent_id" => agent_id,
          "tint_id" => tint_id
        }
      end

      # Composer pane title. Always names the concrete destination so the user
      # can read it without decoding a color.
      def composer_title(state)
        target = presentation(state)
        case target.fetch("kind")
        when SLASH then slash_title(target)
        when AGENT then "chat → #{target.fetch("agent_id")}#{title_suffix(target)}"
        when ISSUE then "chat → #{target.fetch("issue_id")}#{title_suffix(target)}"
        when LOG_ONLY then "chat · head routes · #{target.fetch("label")} logs only"
        else "chat · head routes"
        end
      end

      # Border color for the composer box. nil means "keep the pane default",
      # which is what makes the untargeted states visually distinct.
      #
      # The focused/unfocused distinction survives tinting: a focused composer
      # uses the bold weight of the same hue instead of a different color.
      def border_style(state, active: false)
        tint = tint_id(state)
        return nil if tint.empty?

        Style.agent_chrome_style(tint, bold: active)
      end

      def title_style(state)
        tint = tint_id(state)
        return nil if tint.empty?

        Style.agent_chrome_style(tint, bold: true)
      end

      # Prompt marker (`›`) style, so the tint reaches inside the box as well as
      # around it and survives a composer whose border is clipped by a very
      # narrow terminal.
      def prompt_style(state)
        title_style(state) || Style::ACCENT_BOLD
      end

      # Placeholder for an empty composer. A targeted composer says who it will
      # message; everything else keeps the familiar generic prompt.
      def placeholder(state)
        target = presentation(state)
        return "enter a prompt" unless target.fetch("targeted")

        "message #{primary_label(target)}"
      end

      # Bottom-hint chip. Carries the resolved routing destination, that a head
      # still routes the message, and the clear gesture.
      def chip_segments(state)
        target = presentation(state)
        case target.fetch("kind")
        when SLASH then slash_chip_segments(target)
        when AGENT
          [
            ["#{TARGET_MARKER} target: #{target.fetch("agent_id")} → #{target.fetch("issue_id")}", chip_style(target)],
            ["  head routes · Esc clears", Style::MUTED]
          ]
        when ISSUE
          [
            ["#{TARGET_MARKER} target: #{target.fetch("issue_id")}", chip_style(target)],
            ["  head routes · Esc clears", Style::MUTED]
          ]
        when LOG_ONLY
          [
            ["#{TARGET_MARKER} logs: #{target.fetch("label")}", Style::ACCENT],
            ["  chat → head routes · Esc clears", Style::MUTED]
          ]
        else no_target_chip_segments
        end
      end

      # Deliberately the shortest chip on the bar: nothing is selected, the
      # composer title already says a head routes the message, and the
      # interaction hints after it matter more at the minimum terminal width.
      def no_target_chip_segments
        [["#{TARGET_MARKER} no target", Style::DIM]]
      end

      # Palette id the composer is tinted from, or "" when it is untinted.
      def tint_id(state)
        presentation(state).fetch("tint_id")
      end

      def targeted?(state)
        presentation(state).fetch("targeted")
      end

      def kind_for(state, issue_id, label)
        return SLASH if slash_prompt?(state)
        return LOG_ONLY if issue_id.empty? && !label.empty?
        return NONE if issue_id.empty?

        agent_selection?(state) ? AGENT : ISSUE
      end

      def agent_selection?(state)
        !LogScope.selected_target(state).fetch("selected_agent_id", "").to_s.empty?
      end

      # Slash commands never inherit the dashboard selection, so the composer
      # must stop advertising one the moment the buffer becomes a slash command.
      def slash_prompt?(state)
        buffer = ((state || {}).fetch("_chat", nil) || {}).fetch("input_buffer", "").to_s
        buffer.lstrip.start_with?("/")
      end

      def tint_id_for(kind, agent_id, issue_id)
        case kind
        when AGENT then agent_id
        when ISSUE then issue_id
        else ""
        end
      end

      def chip_style(target)
        Style.agent_chrome_style(target.fetch("tint_id"), bold: true)
      end

      def title_suffix(target)
        title = truncate(target.fetch("issue_title"))
        title.empty? ? "" : " · #{title}"
      end

      # The row the user clicked, which is the id they are looking for: the
      # selected agent when one is selected, otherwise the issue, otherwise the
      # log-only node.
      def primary_label(target)
        [target.fetch("agent_id"), target.fetch("issue_id"), target.fetch("label")].find { |value| !value.to_s.empty? }.to_s
      end

      # A slash command bypasses the selection. Say so with the id, instead of
      # silently dropping the chip and leaving the user to guess.
      def slash_title(target)
        label = primary_label(target)
        return "chat · slash command" if label.empty?

        "chat · slash command · #{label} not targeted"
      end

      def slash_chip_segments(target)
        label = primary_label(target)
        return no_target_chip_segments if label.empty?

        [
          ["#{TARGET_MARKER} #{label}", Style::DIM],
          ["  slash ignores target · Esc clears", Style::MUTED]
        ]
      end

      def truncate(text)
        value = text.to_s.gsub(/\s+/, " ").strip
        return value if value.length <= MAX_TITLE_LENGTH

        "#{value[0, MAX_TITLE_LENGTH - 1].rstrip}…"
      end
    end
  end
end
