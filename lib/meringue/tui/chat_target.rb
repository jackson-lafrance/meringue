# frozen_string_literal: true

module Meringue
  module TUI
    # Presentation of "where will my next chat message go?".
    #
    # LogScope owns the selection itself (see log_scope.rb): `selected_target`
    # always returns a Hash for renderers and `chat_target` returns Hash-or-nil
    # for routing. This module turns that one fact into the composer's chrome:
    # its pane title, border/title styles, prompt marker, placeholder, and the
    # routing hint on the bottom line.
    #
    # The destination is named in exactly one place: the composer pane title,
    # which sits on the border row directly above the chat bar. The bottom hint
    # line deliberately repeats none of it and carries only the gestures a title
    # cannot express (a fresh head still routes the message, a slash command
    # ignores the selection, Esc clears it).
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
    #                or reconciliation already dropped). Quiet, untinted, and it
    #                adds nothing to the bottom line because there is no selection
    #                to explain or clear.
    #
    # Colors are never the only cue: every state also spells the target out in
    # the composer title, so `NO_COLOR`, a 16-color terminal, or a screenshot
    # still says where the prompt is going.
    module ChatTarget
      AGENT = "agent"
      ISSUE = "issue"
      LOG_ONLY = "log_only"
      NONE = "none"
      SLASH = "slash"

      # What the bottom hint line still owes the user once the title above the
      # chat bar names the destination: that a fresh head (not the selected row)
      # receives the message, and how to drop the selection.
      ROUTING_HINT = "head routes · Esc clears"
      # A slash command bypasses the selection, so its hint has to warn rather
      # than promise head routing for the selected node.
      SLASH_HINT = "slash ignores target · Esc clears"
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
        when AGENT then agent_title(target)
        when ISSUE then "chat → #{target.fetch("issue_id")}#{title_suffix(target)}"
        when LOG_ONLY then "chat · head routes · #{target.fetch("label")} logs only"
        else "chat"
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

      # Bottom hint line contribution: gestures only, never the target's
      # identity. The composer title one row above already names the destination,
      # so repeating the id here only spent width the interaction hints and the
      # delivery-PR indicator need on a narrow terminal.
      #
      # - agent/issue/log-only: a fresh head routes the message, Esc clears the
      #   selection.
      # - slash with a selection: that selection is ignored, Esc clears it.
      # - nothing selected (or a slash command with nothing selected): no
      #   segments at all. There is no selection to explain or clear.
      def hint_segments(state)
        target = presentation(state)
        case target.fetch("kind")
        when SLASH then slash_hint_segments(target)
        when AGENT, ISSUE, LOG_ONLY then [[ROUTING_HINT, Style::MUTED]]
        else []
        end
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

      # The clicked agent row is the id the user is looking for, and chat resolves
      # it to that agent's owning issue. A worker id already contains its issue id
      # (`P1-I9-W3` → `P1-I9`), so naming both would only stutter; an agent whose
      # id does not encode its issue (a head bound to one) names the resolved
      # issue too, because the bottom line no longer spells it out.
      def agent_title(target)
        agent_id = target.fetch("agent_id")
        issue_id = target.fetch("issue_id")
        destination = agent_id.start_with?("#{issue_id}-") ? agent_id : "#{agent_id} → #{issue_id}"
        "chat → #{destination}#{title_suffix(target)}"
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
      # silently dropping the target and leaving the user to guess.
      def slash_title(target)
        label = primary_label(target)
        return "chat · slash command" if label.empty?

        "chat · slash command · #{label} not targeted"
      end

      # The title already names the ignored selection (`… P1-I9-W3 not
      # targeted`), so the hint only has to warn that routing drops it. With no
      # selection there is nothing to ignore and nothing to clear.
      def slash_hint_segments(target)
        return [] if primary_label(target).empty?

        [[SLASH_HINT, Style::MUTED]]
      end

      def truncate(text)
        value = text.to_s.gsub(/\s+/, " ").strip
        return value if value.length <= MAX_TITLE_LENGTH

        "#{value[0, MAX_TITLE_LENGTH - 1].rstrip}…"
      end
    end
  end
end
