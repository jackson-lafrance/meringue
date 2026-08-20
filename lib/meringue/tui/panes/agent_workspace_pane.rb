# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    module Panes
      # Renders one selected worker as an optional issue-focused workspace. The
      # live worker and worktree terminal share the area instead of competing;
      # the normal dashboard remains the primary head-agent workflow.
      class AgentWorkspacePane
        EMPTY_TRANSCRIPT = "No agent output yet. Send a message below to continue this session."
        BODY_INDENT = "  "
        # Conversational text is rendered as Markdown so fenced code, lists, and
        # inline code look the same here as in the dashboard log.
        # Reasoning entries carry the role "thinking"; "reasoning" is accepted too
        # so an embedder using the display name still gets Markdown rendering.
        MARKDOWN_ROLES = %w[you user agent final thinking reasoning system].freeze
        TOOL_ROLES = WorkspaceTranscript::TOOL_ROLES

        def initialize
          @line_cache = {}
        end

        def title(state)
          workspace = workspace_state(state)
          agent = workspace_agent(state)
          view = if workspace.fetch("view", "agent") == "terminal"
                   "worktree terminal"
                 elsif workspace.fetch("opening", false)
                   "Agent session preparing"
                 elsif workspace.fetch("interactive", false)
                   "Agent session"
                 else
                   "focused worker"
                 end
          id = agent&.fetch("id", nil) || workspace.fetch("agent_id", "worker")
          "#{view} · #{id}"
        end

        # The focused pane title takes the worker's identity color, the same one
        # its AgentTree row, its log rows, and the dashboard composer use, so a
        # full-screen workspace still says which agent you are looking at.
        def title_style(state)
          agent = workspace_agent(state)
          id = (agent&.fetch("id", nil) || workspace_state(state).fetch("agent_id", nil)).to_s
          return nil if id.empty?

          Style.agent_chrome_style(id, bold: true)
        end

        # Scrolling must not re-wrap and re-sort the whole transcript on every
        # step. Composed lines are cached per view until the content signature
        # changes, so a scroll only changes which cached rows are drawn.
        # The embedded workspace shares the dashboard's top border with its
        # controls. Returning hit regions alongside the segments keeps drawing
        # and mouse handling on exactly the same geometry.
        def top_status_layout(state, width:)
          workspace = workspace_state(state)
          available = [width.to_i, 0].max
          command_records = %w[workspace_switch_view workspace_open_editor workspace_close].filter_map do |action|
            command = Array(workspace.fetch("leader_commands", [])).find do |candidate|
              candidate.is_a?(Hash) && candidate.fetch("action", nil).to_s == action
            end
            next unless command

            label = { "workspace_switch_view" => "Terminal", "workspace_open_editor" => "Editor", "workspace_close" => "Dashboard" }.fetch(action)
            { "action" => action, "key" => command.fetch("key", "").to_s, "label" => label }
          end
          leader = workspace.fetch("leader_label", "Ctrl-Space").to_s
          pending_style = workspace.fetch("leader_pending", false) ? Style::SELECTION : Style::ACCENT_BOLD

          full_title = title(state)
          compact_title = full_title.split(" · ", 2).first
          candidates = [
            [full_title, false],
            [full_title, true],
            [compact_title, true],
            ["", true]
          ]
          chosen_title, compact = candidates.find do |candidate_title, candidate_compact|
            button_texts = command_records.map do |record|
              key = record.fetch("key")
              candidate_compact ? "[#{key}]" : "[#{key} #{record.fetch("label")}]"
            end
            text = [candidate_title, leader, *button_texts].reject(&:empty?).join("  ")
            text.length <= available
          end || candidates.last

          prefix = chosen_title.empty? ? "" : "#{chosen_title}  "
          segments = []
          segments << [chosen_title, title_style(state)] unless chosen_title.empty?
          segments << ["  ", Style::DIM] unless chosen_title.empty?
          controls = []
          cursor = prefix.length
          segments << [leader, pending_style]
          cursor += leader.length
          command_records.each do |record|
            key = record.fetch("key")
            text = compact ? "[#{key}]" : "[#{key} #{record.fetch("label")}]"
            separator = "  "
            segments << [separator, Style::DIM]
            cursor += separator.length
            start = cursor
            segments << [text, Style::ACCENT_BOLD]
            cursor += text.length
            controls << { action: record.fetch("action"), start: start, finish: cursor }
          end

          { segments: segments, controls: controls.select { |record| record.fetch(:finish) <= available } }
        end

        def content_lines(state, width: nil)
          workspace = workspace_state(state)
          view = workspace.fetch("view", "agent")
          signature = content_signature(state, workspace, view, width)
          cached = @line_cache[view]
          return cached.fetch("lines") if signature && cached && cached.fetch("signature") == signature

          lines = if view == "terminal"
                    terminal_lines(workspace, width: width)
                  elsif workspace.fetch("interactive", false) || workspace.fetch("opening", false)
                    interactive_lines(workspace, width: width)
                  else
                    agent_lines(state, workspace, width: width)
                  end
          @line_cache[view] = { "signature" => signature, "lines" => lines } if signature
          lines
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

        # One leader-key line for both views: the leader, then every command key
        # with a harness-agnostic label, plus the active transcript filter.
        #
        # When the line cannot fit, whole labels are dropped before whole
        # commands are, so every command stays discoverable at any width instead
        # of the list being cut mid-item.
        # Workspace slash commands mirror the dashboard's completion popup, so the
        # focused view stays discoverable without adding another hint line.
        def slash_suggestions?(state)
          workspace = workspace_state(state)
          return false if workspace.fetch("embedded", false)
          return false unless workspace.fetch("view", "agent") == "agent"

          WorkspaceCommands.slash_prompt?(workspace.fetch("input_buffer", ""))
        end

        def slash_suggestion_lines(state)
          workspace = workspace_state(state)
          records = Array(workspace.fetch("slash_suggestions", []))
          return [[["No matching workspace commands.", Style::MUTED]]] if records.empty?

          selected_index = workspace.fetch("slash_suggestion_index", -1).to_i
          records.each_with_index.map do |record, index|
            selected = index == selected_index
            [
              [selected ? "› " : "  ", selected ? Style::ACCENT_BOLD : Style::DIM],
              [record.fetch("usage", "").to_s, selected ? Style::ACCENT_BOLD : Style::TEXT],
              [" — #{record.fetch("description", "")}", Style::MUTED]
            ]
          end
        end

        def hint_line(state, width: nil)
          workspace = workspace_state(state)
          commands = Array(workspace.fetch("leader_commands", nil)).select { |command| command.is_a?(Hash) }
          return legacy_hint_line(workspace) if commands.empty?

          filter = workspace.fetch("filter", "all").to_s
          available = width.nil? ? nil : [width.to_i, 0].max
          %i[full compact keys leader].each do |style|
            segments = leader_segments(workspace, commands, filter, style)
            return segments if available.nil? || segment_width(segments) <= available
          end
          leader_segments(workspace, commands, filter, :leader)
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

        def leader_command_key(workspace, action)
          command = Array(workspace.fetch("leader_commands", [])).find do |candidate|
            candidate.is_a?(Hash) && candidate.fetch("action", nil).to_s == action
          end
          command ? command.fetch("key", "F").to_s : "F"
        end

        def content_signature(state, workspace, view, width)
          revision = workspace.fetch("content_revision", nil)
          return nil if revision.nil?

          agent = workspace_agent(state)
          [
            view,
            width.to_i,
            workspace.fetch("agent_id", nil).to_s,
            workspace.fetch("interactive", false),
            workspace.fetch("embedded", false),
            workspace.fetch("opening", false),
            workspace.fetch("filter", "all").to_s,
            Settings.github_enabled?(state),
            revision,
            agent&.fetch("updated_at", nil).to_s,
            agent&.fetch("status", nil).to_s
          ]
        end

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
            status_reason_line(agent, metadata),
            session_settings_line(agent),
            issue_line(issue),
            workspace_path_line(agent),
            pull_request_line(state, agent, issue),
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

        # Why an agent is in its current status, when the kernel recorded one. This is what lets a
        # worker whose turn died from a dropped connection read as "this died" instead of
        # "this finished".
        def status_reason_line(agent, metadata)
          reason = metadata.fetch("status_reason", nil).to_s.strip
          return nil if reason.empty?

          style = agent.fetch("status", nil).to_s == "errored" ? Style::ERROR : Style::WARNING
          [["status ", Style::DIM], [reason, style]]
        end

        def session_settings_line(agent)
          settings = agent.fetch("session_settings", {}) || {}
          model = settings.dig("model", "reference")
          thinking = settings.fetch("thinking_level", nil)
          availability = settings.fetch("availability", nil)
          # "unknown" means the harness can report these and Meringue has not read them yet;
          # "unavailable" means this backend does not expose them at all. Saying which is which
          # keeps a missing value from reading like a bug.
          reportable = availability.to_s != "unsupported" && !availability.to_s.empty?
          model = reportable ? "unknown" : "unavailable" if model.to_s.empty?
          thinking = reportable ? "unknown" : "unavailable" if thinking.to_s.empty?

          [
            ["session settings · ", Style::DIM],
            ["model #{model}", Style::MUTED],
            [" · ", Style::DIM],
            ["thinking #{thinking}", Style::MUTED]
          ]
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

        def pull_request_line(state, agent, issue)
          return nil unless Settings.github_enabled?(state)

          presentation = DeliveryPullRequest.for_id(
            { "agents" => [agent], "issues" => [issue].compact },
            agent.fetch("id", nil)
          )
          return nil unless DeliveryPullRequest.openable?(presentation)

          [["PR     ", Style::DIM], [presentation.fetch("url"), Style::PR_MARKER]]
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

        # Entry collection, normalization, and deduplication live in
        # WorkspaceTranscript; this method only turns entries into styled rows.
        def transcript_lines(state, workspace, agent, metadata, width:)
          filter = workspace.fetch("filter", "all").to_s
          entries = WorkspaceTranscript.entries(
            workspace: workspace,
            agent_id: agent.fetch("id"),
            logs: state.fetch("logs", []),
            filter: filter,
            fallback_text: metadata.fetch("last_assistant_text", nil)
          )
          return [[[EMPTY_TRANSCRIPT, Style::MUTED]]] if entries.empty? && filter == "all"
          if entries.empty?
            key = leader_command_key(workspace, "workspace_cycle_filter")
            leader = workspace.fetch("leader_label", "Ctrl-Space")
            return [[["No #{filter} transcript entries yet. Press #{leader} then #{key} to change the filter, or run /filter all.", Style::MUTED]]]
          end

          entries.flat_map.with_index do |entry, index|
            role = entry.fetch("role", "agent").to_s
            label, label_style = transcript_label(role, agent.fetch("id"), entry.fetch("timestamp", nil))
            rendered = [[[label, label_style]]]
            rendered.concat(entry_body_lines(entry, role, label_style, width))
            rendered << [["", Style::DIM]] unless index == entries.length - 1
            rendered
          end
        end

        def entry_body_lines(entry, role, label_style, width)
          text = entry.fetch("text", entry.fetch("message", "")).to_s
          gutter = [BODY_INDENT, Style::DIM]

          if TOOL_ROLES.include?(role)
            return Markdown.render(
              tool_markdown(entry, role),
              width: width,
              gutter: gutter,
              base_style: body_style_for(role),
              accent_style: label_style
            )
          end

          if MARKDOWN_ROLES.include?(role)
            return Markdown.render(
              text,
              width: width,
              gutter: gutter,
              base_style: body_style_for(role),
              accent_style: label_style
            )
          end

          # Errors and lifecycle notes stay verbatim: they are short and must not
          # be reflowed or reinterpreted as Markdown.
          #
          # Bodies are indented, so wrap to the indented width. Wrapping at the
          # full width and then indenting pushed the last characters of every
          # wrapped row past the pane edge, which dropped them from the text.
          wrap_text(text, width ? width.to_i - BODY_INDENT.length : nil)
            .map { |row| [["#{BODY_INDENT}#{row}", body_style_for(role)]] }
        end

        # Tool traffic is rendered as a labelled, fenced block so multi-line
        # commands, diffs, and command output keep their real line breaks and
        # alignment instead of being flattened into one escaped string.
        def tool_markdown(entry, role)
          name = entry.fetch("tool_name", nil).to_s.strip
          body = entry.fetch("text", "").to_s
          parts = []
          heading = [name.empty? ? nil : "**#{name}**", entry.fetch("tool_status", nil)].compact.join(" · ")
          parts << heading unless heading.empty?
          if body.strip.empty?
            parts << (role == "tool_call" ? "_no arguments_" : "_no output_")
          else
            parts << fenced_block(body, entry.fetch("tool_language", nil).to_s)
          end
          # Secondary arguments read better beside the block than inside it.
          extra = entry.fetch("tool_extra", nil).to_s
          parts << extra unless extra.strip.empty?
          parts.join("\n\n")
        end

        # Chooses a fence longer than any run inside the payload so tool output
        # that itself contains backticks cannot break out of the block.
        def fenced_block(body, language)
          longest = body.scan(/`+/).map(&:length).max.to_i
          fence = "`" * [longest + 1, 3].max
          "#{fence}#{language}\n#{body.rstrip}\n#{fence}"
        end

        # Tool traffic is supporting detail, so its body is dimmer than assistant
        # and reasoning text while headers keep their semantic colors.
        def body_style_for(role)
          case role
          when "tool_call", "tool_result" then Style::MUTED
          when "lifecycle" then Style::DIM
          else Style::TEXT
          end
        end


        def transcript_label(role, agent_id, timestamp = nil)
          label, style = case role
                         when "you", "user"
                           ["● you", Style::USER]
                         when "system"
                           ["▪ meringue", Style::ACCENT_BOLD]
                         when "lifecycle"
                           ["▪ lifecycle", Style::MUTED]
                         when "thinking"
                           ["◌ reasoning", Style::WORKSPACE_REASONING]
                         when "error"
                           ["! error", Style::ERROR]
                         when "tool_call"
                           ["◇ tool call", Style::WORKSPACE_TOOL_CALL]
                         when "tool_result"
                           ["◆ tool result", Style::WORKSPACE_TOOL_RESULT]
                         when "final"
                           ["✓ final #{agent_id}", Style::WORKSPACE_FINAL]
                         else
                           ["✦ #{agent_id}", Style::WORKSPACE_OUTPUT]
                         end
          retained_timestamp = transcript_timestamp(timestamp)
          label = "#{label} · #{retained_timestamp}" if retained_timestamp
          [label, style]
        end

        def transcript_timestamp(value)
          return nil if value.nil? || value.to_s.empty?

          timestamp = if value.is_a?(Numeric)
                        seconds = value.to_f
                        seconds /= 1000 if seconds > 10_000_000_000
                        Time.at(seconds)
                      else
                        value
                      end
          # Pi emits UTC ISO8601 or epoch timestamps. Use the same recency-aware
          # local-clock formatting as the dashboard instead of the source zone.
          Timestamps.display(timestamp) || value.to_s
        rescue ArgumentError, RangeError, TypeError
          value.to_s
        end

        def interactive_lines(workspace, width:)
          terminal_lines({ "terminal" => workspace.fetch("agent_session", {}) || {}, "error" => workspace.fetch("error", nil), "notice" => workspace.fetch("notice", nil) }, width: width)
        end

        def terminal_lines(workspace, width:)
          terminal = workspace.fetch("terminal", {}) || {}
          lines = Array(terminal.fetch("lines", []))
          styled_lines = Array(terminal.fetch("styled_lines", []))
          error = terminal.fetch("error", workspace.fetch("error", nil)).to_s.strip
          notice = terminal.fetch("notice", workspace.fetch("notice", nil)).to_s.strip
          output = []
          output.concat(wrapped_notice(notice, Style::MUTED, width)) unless notice.empty?
          output.concat(wrapped_notice(error, Style::ERROR, width)) unless error.empty?
          output << [["", Style::DIM]] unless output.empty? || lines.empty?
          rendered_lines = if styled_lines.empty?
                             lines.map { |line| [[line.to_s, Style::TEXT]] }
                           else
                             styled_lines.map do |segments|
                               Array(segments).map { |text, style| [text.to_s, style || Style::TEXT] }
                             end
                           end
          cursor = Array(terminal.fetch("cursor", []))
          if cursor.length >= 2
            row = cursor[0].to_i
            rendered_lines << [] while rendered_lines.length <= row
            rendered_lines[row] = insert_terminal_cursor(rendered_lines[row], cursor[1].to_i)
          end
          output.concat(rendered_lines)
          output.empty? ? [[["Terminal is starting…", Style::MUTED]]] : output
        end

        def insert_terminal_cursor(segments, column)
          remaining = [column, 0].max
          output = []
          inserted = false
          Array(segments).each do |text, style|
            value = text.to_s
            if !inserted && remaining <= value.length
              output << [value[0...remaining], style] if remaining.positive?
              output << ["▏", Style::ACCENT_BOLD]
              output << [value[remaining..].to_s, style] if remaining < value.length
              inserted = true
            else
              output << [value, style]
              remaining -= value.length unless inserted
            end
          end
          unless inserted
            output << [" " * remaining, Style::TEXT] if remaining.positive?
            output << ["▏", Style::ACCENT_BOLD]
          end
          output
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

        def leader_segments(workspace, commands, filter, style)
          pending = workspace.fetch("leader_pending", false)
          leader = workspace.fetch("leader_label", "Ctrl-Space").to_s
          leader_style = pending ? Style::WORKING : Style::ACCENT_BOLD
          return [[leader, leader_style]] if style == :leader

          entries = commands.map do |command|
            filter_command = command.fetch("action", nil).to_s == "workspace_cycle_filter"
            label = case style
                    when :full
                      filter_command && !filter.empty? ? "#{command.fetch("label", "")}: #{filter}" : command.fetch("label", "").to_s
                    when :compact
                      filter_command && !filter.empty? ? ": #{filter}" : ""
                    else
                      ""
                    end
            [command.fetch("key", "?").to_s, label]
          end
          HintLine.segments(
            entries,
            leader: leader,
            leader_style: leader_style,
            leader_suffix: pending ? " waiting… " : "  ",
            separator: style == :keys ? " " : HintLine::SEPARATOR
          )
        end

        def segment_width(segments)
          HintLine.width(segments)
        end

        # Retained for embedders that still feed only the flattened hint string.
        def legacy_hint_line(workspace)
          leader = workspace.fetch("leader_hint", "Ctrl-Space: T terminal/agent, F filter, A agent session, B editor, P PR, Q quit")
          filter = workspace.fetch("filter", "all")
          entries = workspace.fetch("leader_pending", false) ? [[nil, "command pending"], [nil, leader]] : [[nil, leader], [nil, "filter: #{filter}"]]
          HintLine.segments(entries)
        end

        def status_style(status)
          {
            "working" => Style::WORKING,
            "streaming" => Style::WORKING,
            "completed" => Style::SUCCESS,
            "paused" => Style::WARNING,
            "blocked" => Style::WARNING,
            "errored" => Style::ERROR,
            "sending" => Style::ACCENT
          }.fetch(status.to_s, Style::MUTED)
        end
      end
    end
  end
end
