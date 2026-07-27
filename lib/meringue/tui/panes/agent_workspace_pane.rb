# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      # Renders one selected agent as a focused workspace. The agent and terminal
      # views deliberately share the whole dashboard area instead of competing
      # for space; switching views never changes the worker lifecycle.
      class AgentWorkspacePane
        EMPTY_TRANSCRIPT = "No agent output yet. Send a message below to continue this session."

        def title(state)
          workspace = workspace_state(state)
          agent = workspace_agent(state)
          view = workspace.fetch("view", "agent")
          id = agent&.fetch("id", nil) || workspace.fetch("agent_id", "agent")
          "#{view} · #{id}"
        end

        def content_lines(state, width: nil)
          workspace = workspace_state(state)
          return terminal_lines(workspace, width: width) if workspace.fetch("view", "agent") == "terminal"

          agent_lines(state, workspace, width: width)
        end

        def composer_lines(state, width: nil)
          workspace = workspace_state(state)
          input = workspace.fetch("input_buffer", "").to_s
          cursor = workspace.fetch("input_cursor", input.chars.length).to_i.clamp(0, input.chars.length)
          input = input.dup
          input.insert(cursor, "\u0000")
          available_width = width ? [width.to_i - 2, 1].max : [input.length, 1].max

          rows = input.split("\n", -1).flat_map do |line|
            line.empty? ? [""] : line.chars.each_slice(available_width).map(&:join)
          end
          rows.map.with_index do |row, index|
            marker_index = row.index("\u0000")
            prefix = index.zero? ? "› " : "  "
            prefix_style = index.zero? ? Style::ACCENT_BOLD : Style::DIM
            segments = [[prefix, prefix_style]]
            if marker_index
              before = row[0...marker_index]
              after = row[(marker_index + 1)..].to_s
              segments << [before, Style::TEXT] unless before.empty?
              segments << ["_", Style::ACCENT_BOLD]
              segments << [after, Style::TEXT] unless after.empty?
            else
              segments << [row, Style::TEXT]
            end
            segments
          end
        end

        def hint_line(state)
          workspace = workspace_state(state)
          if workspace.fetch("view", "agent") == "terminal"
            hint_segments("Esc tree", "Ctrl-T agent", "Ctrl-E editor", "Ctrl-B PR")
          else
            hint_segments("Esc tree", "Ctrl-T terminal", "Enter send", "Ctrl-E editor", "Ctrl-B PR", "Shift-Enter newline")
          end
        end

        def status_line(state)
          workspace = workspace_state(state)
          agent = workspace_agent(state)
          live = if workspace.fetch("view", "agent") == "terminal"
                   workspace.fetch("terminal", {}) || {}
                 else
                   workspace.fetch("agent_session", {}) || {}
                 end
          status = live.fetch("session_state", live.fetch("status", agent&.fetch("status", nil))).to_s
          pending = workspace.fetch("pending_count", 0).to_i
          label = pending.positive? ? "sending" : status
          return [] if label.empty?

          style = status_style(label)
          [["● ", style], [label, style]]
        end

        private

        def workspace_state(state)
          state.fetch("_agent_workspace", {}) || {}
        end

        def workspace_agent(state)
          id = workspace_state(state).fetch("agent_id", nil).to_s
          Array(state.fetch("agents", [])).find { |agent| agent.fetch("id", nil).to_s == id }
        end

        def workspace_issue(state, agent)
          return nil unless agent

          Array(state.fetch("issues", [])).find { |issue| issue.fetch("id", nil).to_s == agent.fetch("issue_id", nil).to_s }
        end

        def agent_lines(state, workspace, width:)
          agent = workspace_agent(state)
          return wrapped_notice(workspace.fetch("notice", "Selected agent is no longer available."), Style::WARNING, width) unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          issue = workspace_issue(state, agent)
          lines = [
            [[agent_title(agent), Style::TITLE]],
            compact_identity_line(agent),
            issue_line(issue),
            workspace_path_line(agent),
            pull_request_line(agent, issue),
            [["", Style::DIM]]
          ].compact
          lines.concat(workspace_notices(workspace, width: width))
          lines.concat(transcript_lines(state, workspace, agent, metadata, width: width))
          lines
        end

        def agent_title(agent)
          metadata = agent.fetch("harness_metadata", {}) || {}
          metadata.fetch("title", "#{agent.fetch("type", "agent")} session").to_s
        end

        def compact_identity_line(agent)
          provider = agent.fetch("harness", "").to_s
          values = [agent.fetch("id", "agent"), agent.fetch("status", "unknown"), provider].reject(&:empty?)
          values.each_with_index.flat_map do |value, index|
            segments = []
            segments << [" · ", Style::DIM] if index.positive?
            segments << [value, index == 1 ? status_style(value) : Style::MUTED]
            segments
          end
        end

        def issue_line(issue)
          return nil unless issue

          [["issue  ", Style::DIM], [issue.fetch("title", issue.fetch("id", "issue")), Style::TEXT]]
        end

        def workspace_path_line(agent)
          path = agent.fetch("workspace_path", nil).to_s
          return nil if path.empty?

          [["cwd    ", Style::DIM], [path, Style::MUTED]]
        end

        def pull_request_line(agent, issue)
          url = AgentTreeNavigation.agent_pr_url(issue || {}) || AgentTreeNavigation.agent_pr_url(agent)
          return nil unless url

          [["PR     ", Style::DIM], [url, Style::PR_MARKER]]
        end

        def workspace_notices(workspace, width:)
          live = workspace.fetch("agent_session", {}) || {}
          notice = [workspace.fetch("notice", nil), live.fetch("notice", nil), live.fetch("warning", nil)].compact.map(&:to_s).find { |value| !value.strip.empty? }.to_s.strip
          error = [workspace.fetch("error", nil), live.fetch("error", nil)].compact.map(&:to_s).find { |value| !value.strip.empty? }.to_s.strip
          lines = []
          lines.concat(wrapped_notice(notice, Style::MUTED, width)) unless notice.empty?
          lines.concat(wrapped_notice(error, Style::ERROR, width)) unless error.empty?
          lines << [["", Style::DIM]] unless lines.empty?
          lines
        end

        def transcript_lines(state, workspace, agent, metadata, width:)
          entries = []
          entries.concat(Array(workspace.fetch("messages", [])))
          live = workspace.fetch("agent_session", {}) || {}
          entries.concat(Array(live.fetch("messages", [])))
          entries.concat(Array(live.fetch("items", [])).filter_map { |item| live_item_entry(item) })
          live_lines = Array(live.fetch("lines", []))
          entries << { "role" => "agent", "text" => live_lines.join("\n") } unless live_lines.empty?
          entries.concat(durable_agent_entries(state, agent.fetch("id")))
          entries = deduplicate_entries(entries)

          if entries.empty?
            last_text = metadata.fetch("last_assistant_text", "").to_s.strip
            entries << { "role" => "agent", "text" => last_text } unless last_text.empty?
          end
          return [[[EMPTY_TRANSCRIPT, Style::MUTED]]] if entries.empty?

          entries.flat_map.with_index do |entry, index|
            role = entry.fetch("role", "agent").to_s
            label, label_style = transcript_label(role, agent.fetch("id"))
            text = entry.fetch("text", entry.fetch("message", "")).to_s
            rows = wrap_text(text, width)
            rendered = [[[label, label_style]]]
            rendered.concat(rows.map { |row| [["  #{row}", Style::TEXT]] })
            rendered << [["", Style::DIM]] unless index == entries.length - 1
            rendered
          end
        end

        def live_item_entry(item)
          return nil unless item.is_a?(Hash)

          text = item.fetch("content", item.fetch("text", "")).to_s
          return nil if text.strip.empty?

          role = item.fetch("role", item.fetch("kind", "agent")).to_s
          role = "you" if role == "user"
          role = "agent" if role == "assistant"
          role = "system" if role == "tool"
          { "role" => role, "text" => text }
        end

        def durable_agent_entries(state, agent_id)
          Array(state.fetch("logs", [])).filter_map do |entry|
            next unless entry.is_a?(Hash)
            next unless entry.fetch("source_id", nil).to_s == agent_id.to_s

            source_type = entry.fetch("source_type", "worker").to_s
            role = source_type == "user" ? "you" : "agent"
            { "role" => role, "text" => entry.fetch("message", "").to_s }
          end
        end

        def deduplicate_entries(entries)
          seen = {}
          entries.filter_map do |entry|
            next unless entry.is_a?(Hash)

            text = entry.fetch("text", entry.fetch("message", "")).to_s.strip
            next if text.empty?

            role = entry.fetch("role", "agent").to_s
            key = [role, text.gsub(/\s+/, " ")]
            next if seen[key]

            seen[key] = true
            entry.merge("text" => text)
          end
        end

        def transcript_label(role, agent_id)
          case role
          when "you", "user"
            ["● you", Style::USER]
          when "system"
            ["▪ meringue", Style::ACCENT_BOLD]
          else
            ["✦ #{agent_id}", Style.agent_style(agent_id, kind: "worker")]
          end
        end

        def terminal_lines(workspace, width:)
          terminal = workspace.fetch("terminal", {}) || {}
          lines = Array(terminal.fetch("lines", []))
          error = terminal.fetch("error", workspace.fetch("error", nil)).to_s.strip
          notice = terminal.fetch("notice", workspace.fetch("notice", nil)).to_s.strip
          output = []
          output.concat(wrapped_notice(notice, Style::MUTED, width)) unless notice.empty?
          output.concat(wrapped_notice(error, Style::ERROR, width)) unless error.empty?
          output << [["", Style::DIM]] unless output.empty? || lines.empty?
          output.concat(lines.map { |line| [[line.to_s, Style::TEXT]] })
          output.empty? ? [[["Terminal is starting…", Style::MUTED]]] : output
        end

        def wrap_text(text, width)
          available = width ? [width.to_i, 1].max : nil
          text.to_s.split("\n", -1).flat_map do |line|
            if available && line.length > available
              line.chars.each_slice(available).map(&:join)
            else
              [line]
            end
          end
        end

        def wrapped_notice(text, style, width)
          wrap_text(text.to_s, width).map { |line| [[line, style]] }
        end

        def hint_segments(*hints)
          hints.each_with_index.flat_map do |hint, index|
            segments = []
            segments << [" • ", Style::DIM] if index.positive?
            segments << [hint, Style::MUTED]
            segments
          end
        end

        def status_style(status)
          {
            "working" => Style::WORKING,
            "streaming" => Style::WORKING,
            "completed" => Style::SUCCESS,
            "blocked" => Style::WARNING,
            "errored" => Style::ERROR,
            "sending" => Style::ACCENT
          }.fetch(status.to_s, Style::MUTED)
        end
      end
    end
  end
end
