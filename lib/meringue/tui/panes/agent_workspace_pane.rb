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
        TOOL_ROLES = %w[tool_call tool_result].freeze
        BASH_TOOL_NAMES = %w[bash sh shell zsh run exec command].freeze
        COMMAND_ARGUMENT_KEYS = %w[command cmd script shell_command].freeze
        PATH_ARGUMENT_KEYS = %w[path file file_path filename target].freeze

        def initialize
          @line_cache = {}
        end

        def title(state)
          workspace = workspace_state(state)
          agent = workspace_agent(state)
          view = workspace.fetch("view", "agent") == "terminal" ? "worktree terminal" : "focused worker"
          id = agent&.fetch("id", nil) || workspace.fetch("agent_id", "worker")
          "#{view} · #{id}"
        end

        # Scrolling must not re-wrap and re-sort the whole transcript on every
        # step. Composed lines are cached per view until the content signature
        # changes, so a scroll only changes which cached rows are drawn.
        def content_lines(state, width: nil)
          workspace = workspace_state(state)
          view = workspace.fetch("view", "agent")
          signature = content_signature(state, workspace, view, width)
          cached = @line_cache[view]
          return cached.fetch("lines") if signature && cached && cached.fetch("signature") == signature

          lines = if view == "terminal"
                    terminal_lines(workspace, width: width)
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

        def content_signature(state, workspace, view, width)
          revision = workspace.fetch("content_revision", nil)
          return nil if revision.nil?

          agent = workspace_agent(state)
          [
            view,
            width.to_i,
            workspace.fetch("agent_id", nil).to_s,
            workspace.fetch("filter", "all").to_s,
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

        def transcript_lines(state, workspace, agent, metadata, width:)
          local_entries = Array(workspace.fetch("messages", []))
          live = workspace.fetch("agent_session", {}) || {}
          # The same message is often visible in more than one place: assembled
          # history ("items"), the live event stream ("events"), and any
          # harness-provided message list. Tagging the origin lets identical
          # content observed twice collapse while a genuinely repeated message
          # from one origin is preserved.
          session_entries = []
          session_entries.concat(tag_entry_source(Array(live.fetch("messages", [])), "messages"))
          session_entries.concat(tag_entry_source(Array(live.fetch("items", [])).flat_map { |item| live_item_entries(item) }, "items"))
          session_entries.concat(tag_entry_source(Array(live.fetch("events", [])).flat_map { |event| live_event_entries(event) }, "events"))
          live_lines = Array(live.fetch("lines", []))
          session_entries << { "role" => "agent", "text" => live_lines.join("\n"), "source" => "lines" } unless live_lines.empty?
          local_entries = local_entries.reject { |entry| session_contains_entry?(session_entries, entry) }

          entries = tag_entry_source(local_entries, "local") + session_entries
          # Durable worker logs contain the compact completion summary, not the
          # Pi transcript. They are only a fallback when no session output can
          # be recovered, otherwise they can push the real transcript offscreen.
          entries.concat(tag_entry_source(durable_agent_entries(state, agent.fetch("id")), "durable")) if session_entries.empty?
          entries = deduplicate_entries(entries)
          entries = drop_cross_source_duplicates(entries)
          entries = drop_duplicate_tool_sources(entries)
          entries = chronological_entries(drop_superseded_partials(entries))

          if entries.empty?
            last_text = metadata.fetch("last_assistant_text", "").to_s.strip
            entries << { "role" => "agent", "text" => last_text } unless last_text.empty?
          end
          return [[[EMPTY_TRANSCRIPT, Style::MUTED]]] if entries.empty?

          filter = workspace.fetch("filter", "all").to_s
          entries = entries.select { |entry| transcript_filter_match?(entry, filter) }
          return [[["No #{filter} transcript entries are available. Press the workspace leader then f to change the filter.", Style::MUTED]]] if entries.empty?

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

        def live_item_entries(item)
          return [] unless item.is_a?(Hash)

          role = item.fetch("role", item.fetch("kind", "agent")).to_s
          role = "you" if role == "user"
          role = "agent" if role == "assistant"
          role = "tool_result" if %w[tool toolResult bashExecution].include?(role)
          timestamp = item.fetch("timestamp", nil)
          entries = []

          # Streaming deltas are fragments of the message that is being built.
          # They must never be attributed to another category: a reasoning delta
          # rendered as assistant output is what produced stray tail fragments
          # such as a lone "…showing up at all." entry under the real reasoning.
          delta_type = item.fetch("delta_type", nil).to_s
          streaming_delta = delta_type.end_with?("_delta")
          reasoning_delta = streaming_delta && (delta_type.include?("thinking") || delta_type.include?("reasoning"))
          delta_text = item.fetch("delta", "").to_s

          thinking = item.fetch("thinking", "").to_s.strip
          thinking_partial = false
          if thinking.empty? && reasoning_delta
            thinking = delta_text.strip
            thinking_partial = true
          end
          unless thinking.empty?
            entries << transcript_entry("thinking", thinking, item, timestamp: timestamp, part: "thinking", partial: thinking_partial)
          end

          # Tool results arrive as preformatted output, sometimes with escapes
          # still encoded, so they are normalized and labelled like tool traffic
          # rather than treated as prose.
          if role == "tool_result"
            output = normalize_tool_text(item.fetch("content", item.fetch("text", "")))
            unless output.strip.empty?
              tool_name = item.fetch("tool_name", item.fetch("name", "")).to_s
              entries << transcript_entry("tool_result", output, item, timestamp: timestamp, part: "content").merge(
                {
                  "tool_name" => tool_name.empty? ? nil : tool_name,
                  "tool_language" => tool_language(tool_name, nil, output, role: "tool_result")
                }.compact
              )
            end
            return entries
          end

          text = item.fetch("content", item.fetch("text", "")).to_s.strip
          text_partial = false
          if text.empty? && streaming_delta && !reasoning_delta
            text = delta_text.strip
            text_partial = true
          end
          unless text.empty?
            text_role = if item.fetch("is_error", false)
                          "error"
                        elsif role == "agent" && final_agent_item?(item)
                          "final"
                        else
                          role
                        end
            entries << transcript_entry(text_role, text, item, timestamp: timestamp, part: "content", partial: text_partial)
          end

          Array(item.fetch("tool_calls", [])).each do |call|
            next unless call.is_a?(Hash)

            entries << tool_call_entry(call, timestamp: timestamp)
          end

          if item.fetch("is_error", false)
            reason = item.fetch("error_message", item.fetch("stop_reason", "worker operation failed")).to_s.strip
            if text.empty? || (!reason.empty? && !text.include?(reason))
              entries << transcript_entry("error", reason.empty? ? "worker operation failed" : reason, item, timestamp: timestamp, part: "error")
            end
          end
          entries
        end

        def live_event_entries(event)
          return [] unless event.is_a?(Hash)

          case event.fetch("kind", nil)
          when "message"
            live_item_entries(event)
          when "tool"
            name = event.fetch("tool_name", "tool").to_s
            phase = event.fetch("phase", "update").to_s
            arguments = event.fetch("arguments", nil)
            content = normalize_tool_text(event.fetch("content", ""))
            starting = phase == "start"
            body, extra, primary_key = starting && content.empty? ? split_tool_arguments(name, arguments) : [content, nil, nil]
            role = event.fetch("is_error", false) ? "error" : (starting ? "tool_call" : "tool_result")
            entry = transcript_entry(role, body, event, part: "tool-#{phase}")
            if TOOL_ROLES.include?(role)
              entry = entry.merge(
                {
                  "tool_name" => name,
                  "tool_extra" => extra,
                  "tool_status" => phase == "end" ? "done" : nil,
                  "tool_language" => tool_language(name, arguments, body, primary: !primary_key.nil?, role: role)
                }.compact
              )
            end
            [entry]
          when "lifecycle"
            phase = event.fetch("phase", "update").to_s
            message = {
              "streaming" => "Worker started processing.",
              "turn_start" => "Assistant turn started.",
              "turn_complete" => event.fetch("will_retry", false) ? "Worker turn ended; retry pending." : "Worker turn ended.",
              "turn_end" => "Assistant turn completed.",
              "settled" => "Worker session settled."
            }.fetch(phase, "Worker lifecycle: #{phase.tr("_", " ")}.")
            [transcript_entry("lifecycle", message, event, part: "lifecycle-#{phase}")]
          when "notice"
            phase = event.fetch("phase", event.fetch("notice_type", "notice")).to_s
            message = event.fetch("message", event.fetch("error", event.fetch("reason", phase))).to_s
            [transcript_entry(event.fetch("error", nil) ? "error" : "system", "#{phase.tr("_", " ")}: #{message}", event, part: "notice-#{phase}")]
          when "transport"
            message = event.fetch("message", event.fetch("phase", "transport error")).to_s
            [transcript_entry("error", message, event, part: "transport")]
          when "queue"
            steering = Array(event.fetch("steering", [])).map(&:to_s)
            follow_up = Array(event.fetch("follow_up", [])).map(&:to_s)
            details = []
            details << "steering: #{steering.join(" | ")}" unless steering.empty?
            details << "follow-up: #{follow_up.join(" | ")}" unless follow_up.empty?
            [transcript_entry("system", details.empty? ? "Worker prompt queue updated." : details.join("\n"), event, part: "queue")]
          when "interaction_request"
            [transcript_entry("system", event.fetch("message", "Pi requested unsupported interactive input.").to_s, event, part: "interaction")]
          else
            []
          end
        end

        def tool_call_entry(call, timestamp: nil)
          name = call.fetch("name", "tool").to_s
          arguments = call.fetch("arguments", nil)
          body, extra, primary_key = split_tool_arguments(name, arguments)
          transcript_entry("tool_call", body, call, timestamp: timestamp, part: "call").merge(
            {
              "tool_name" => name,
              "tool_extra" => extra,
              "tool_language" => tool_language(name, arguments, body, primary: !primary_key.nil?)
            }.compact
          )
        end

        # Returns [primary payload, secondary argument summary, primary key].
        # The primary key tells the renderer whether the block holds real file or
        # command content, which is what makes a syntax label meaningful.
        def split_tool_arguments(name, arguments)
          return [format_tool_arguments(name, arguments), nil, nil] unless arguments.is_a?(Hash)

          key = primary_argument_key(name, arguments)
          return [format_tool_arguments(name, arguments), nil, nil] unless key

          extra = arguments.reject { |argument_key, _value| argument_key.to_s == key.to_s }
          summary = extra.map { |argument_key, value| format_tool_pair(argument_key, value) }.join("\n")
          [normalize_tool_text(arguments.fetch(key)), summary.empty? ? nil : summary, key]
        end

        def primary_argument_key(name, arguments)
          keys = BASH_TOOL_NAMES.include?(name.to_s.downcase) ? COMMAND_ARGUMENT_KEYS : COMMAND_ARGUMENT_KEYS + %w[content text patch diff]
          key = keys.find { |candidate| arguments.key?(candidate) }
          return nil unless key
          return nil unless arguments.fetch(key).is_a?(String)

          key
        end

        # Arguments arrive as decoded JSON, so a shell command carries real
        # newlines. Rendering them with Hash#inspect re-escaped those newlines
        # and printed literal "\n" in the transcript.
        def format_tool_arguments(name, arguments)
          case arguments
          when nil then ""
          when String then normalize_tool_text(arguments)
          when Array then arguments.map { |value| format_tool_value(value) }.join("\n")
          when Hash then arguments.map { |key, value| format_tool_pair(key, value) }.join("\n")
          else normalize_tool_text(arguments.to_s)
          end
        end

        def format_tool_pair(key, value)
          text = format_tool_value(value)
          return "#{key}: #{text}" unless text.include?("\n")

          "#{key}:\n#{text}"
        end

        def format_tool_value(value)
          case value
          when String then normalize_tool_text(value)
          when nil then ""
          when Hash then value.map { |key, nested| format_tool_pair(key, nested) }.join("\n")
          when Array then value.map { |nested| format_tool_value(nested) }.join("\n")
          else value.to_s
          end
        end

        # Some harness payloads deliver tool text with escapes still encoded.
        # This only runs on tool traffic, never on assistant prose, so genuine
        # backslash sequences inside authored code are left alone.
        def normalize_tool_text(value)
          text = value.to_s
          return text if text.empty?

          text = text.gsub("\\r\\n", "\n").gsub("\\n", "\n").gsub("\\t", "\t").gsub("\\\"", "\"")
          text.delete("\r")
        end

        # Output is labelled from what it actually contains. A tool's name only
        # implies a language for its call payload: an edit tool's *result* is
        # usually a status line, not a diff.
        def tool_language(name, arguments, body, primary: false, role: "tool_call")
          normalized = name.to_s.downcase
          if role == "tool_result"
            return "diff" if diff_like?(body)
            return "json" if body.to_s.strip.start_with?("{", "[")

            return BASH_TOOL_NAMES.include?(normalized) ? "sh" : ""
          end

          return "sh" if BASH_TOOL_NAMES.include?(normalized)
          return "diff" if normalized.include?("edit") || normalized.include?("patch")

          # An argument summary is not source code, so it must not be labelled
          # with the language of a path that happens to appear in it.
          if primary && arguments.is_a?(Hash)
            path = PATH_ARGUMENT_KEYS.filter_map { |key| arguments[key] }.first
            extension = File.extname(path.to_s).delete_prefix(".").downcase
            return extension unless extension.empty?
          end
          return "json" if body.to_s.strip.start_with?("{", "[")

          ""
        end

        def diff_like?(body)
          lines = body.to_s.lines.first(6).map(&:chomp)
          return false if lines.empty?

          lines.any? { |line| line.start_with?("@@", "--- ", "+++ ", "diff --git") }
        end

        def final_agent_item?(item)
          phase = item.fetch("phase", "complete").to_s
          reason = item.fetch("stop_reason", "").to_s
          %w[complete end].include?(phase) && !reason.empty? && reason != "toolUse"
        end

        def transcript_filter_match?(entry, filter)
          category = entry.fetch("category", "output").to_s
          filter == "all" || filter == category
        end

        def transcript_entry(role, text, source, timestamp: nil, part: nil, partial: false)
          timestamp ||= source["timestamp"]
          identity = timestamp || source["id"] || source["tool_call_id"] || source["sequence"]
          source_kind = source["kind"].to_s
          source_role = source["role"].to_s
          category = case role
                     when "thinking" then "reasoning"
                     when "tool_call", "tool_result" then "tools"
                     when "final" then "final"
                     when "error"
                       (source_kind == "tool" || %w[tool toolResult bashExecution].include?(source_role)) ? "tools" : "output"
                     else "output"
                     end
          {
            "role" => role,
            "category" => category,
            "text" => text.to_s,
            "timestamp" => timestamp,
            "partial" => partial || nil,
            "dedup_key" => identity && [role, identity.to_s, part.to_s]
          }.compact
        end

        def tag_entry_source(entries, source)
          Array(entries).map do |entry|
            entry.is_a?(Hash) ? entry.merge("source" => entry.fetch("source", source)) : entry
          end
        end

        # Drops a repeat only when the identical content also arrived from a
        # different origin, which is the duplication users see when history and
        # the live event stream describe the same message.
        def drop_cross_source_duplicates(entries)
          seen = {}
          entries.reject do |entry|
            next false unless entry.is_a?(Hash)

            key = [
              entry.fetch("role", "agent").to_s,
              entry.fetch("tool_name", nil).to_s,
              entry.fetch("text", entry.fetch("message", "")).to_s.strip
            ]
            next false if key.last.empty?

            source = entry.fetch("source", nil).to_s
            if seen.key?(key)
              seen.fetch(key) != source
            else
              seen[key] = source
              false
            end
          end
        end

        # Assembled history and the live event stream both describe tool traffic:
        # history carries the final call and result, while events carry the
        # phases of the same call. When history already describes a tool, its
        # event copies are dropped; a tool that only exists in the event stream
        # (still streaming) is still shown.
        def drop_duplicate_tool_sources(entries)
          history_tools = entries.each_with_object({}) do |entry, names|
            next unless entry.is_a?(Hash) && TOOL_ROLES.include?(entry.fetch("role", nil).to_s)
            next unless entry.fetch("source", nil).to_s == "items"

            names[entry.fetch("tool_name", "").to_s] = true
          end
          return entries if history_tools.empty?

          entries.reject do |entry|
            next false unless entry.is_a?(Hash)
            next false unless TOOL_ROLES.include?(entry.fetch("role", nil).to_s)
            next false unless entry.fetch("source", nil).to_s == "events"

            history_tools.key?(entry.fetch("tool_name", "").to_s)
          end
        end

        # A streaming fragment is only worth showing until the assembled text
        # arrives. Once any entry contains it, the fragment is redundant noise.
        def drop_superseded_partials(entries)
          partials, complete = entries.partition { |entry| entry.fetch("partial", false) }
          return entries if partials.empty?

          complete_texts = complete.map { |entry| entry.fetch("text", "").to_s }
          entries.reject do |entry|
            next false unless entry.fetch("partial", false)

            text = entry.fetch("text", "").to_s.strip
            text.empty? || complete_texts.any? { |candidate| candidate.include?(text) }
          end
        end

        def durable_agent_entries(state, agent_id)
          Array(state.fetch("logs", [])).filter_map do |entry|
            next unless entry.is_a?(Hash)
            next unless entry.fetch("source_id", nil).to_s == agent_id.to_s

            source_type = entry.fetch("source_type", "worker").to_s
            role = source_type == "user" ? "you" : "agent"
            { "role" => role, "text" => entry.fetch("message", "").to_s, "timestamp" => entry.fetch("timestamp", nil) }.compact
          end
        end

        def session_contains_entry?(session_entries, local_entry)
          local_role = local_entry.fetch("role", "agent").to_s
          local_role = "you" if local_role == "user"
          local_role = "agent" if local_role == "assistant"
          local_text = local_entry.fetch("text", local_entry.fetch("message", "")).to_s.strip
          session_entries.any? do |entry|
            entry.fetch("role", "agent").to_s == local_role &&
              entry.fetch("text", entry.fetch("message", "")).to_s.strip == local_text
          end
        end

        def chronological_entries(entries)
          entries.each_with_index.sort_by do |(entry, index)|
            value = entry.fetch("timestamp", nil)
            time = if value.is_a?(Numeric)
                     value.to_f / 1000
                   elsif value
                     Time.parse(value.to_s).to_f
                   end
            [time ? 0 : 1, time || 0, index]
          rescue ArgumentError, TypeError
            [1, 0, index]
          end.map(&:first)
        end

        def deduplicate_entries(entries)
          seen = {}
          entries.filter_map do |entry|
            next unless entry.is_a?(Hash)

            text = entry.fetch("text", entry.fetch("message", "")).to_s.strip
            next if text.empty?

            key = entry.fetch("dedup_key", nil)
            next if key && seen[key]

            seen[key] = true if key
            entry.merge("text" => text)
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

          time = if value.is_a?(Numeric)
                   seconds = value.to_f
                   seconds /= 1000 if seconds > 10_000_000_000
                   Time.at(seconds).utc
                 else
                   Time.parse(value.to_s)
                 end
          time.strftime("%H:%M:%S")
        rescue ArgumentError, RangeError, TypeError
          value.to_s
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
          segments = [[workspace.fetch("leader_label", "Ctrl-Space").to_s, pending ? Style::WORKING : Style::ACCENT_BOLD]]
          return segments if style == :leader

          segments << [pending ? " waiting… " : "  ", Style::DIM]
          commands.each_with_index do |command, index|
            filter_command = command.fetch("action", nil).to_s == "workspace_cycle_filter"
            label = case style
                    when :full
                      filter_command && !filter.empty? ? "#{command.fetch("label", "")}: #{filter}" : command.fetch("label", "").to_s
                    when :compact
                      filter_command && !filter.empty? ? ": #{filter}" : ""
                    else
                      ""
                    end
            segments << [style == :keys ? " " : " · ", Style::DIM] if index.positive?
            segments << [command.fetch("key", "?").to_s, Style::ACCENT]
            segments << [label.start_with?(":") ? label : " #{label}", Style::MUTED] unless label.empty?
          end
          segments
        end

        def segment_width(segments)
          Array(segments).sum { |text, _style| text.to_s.length }
        end

        # Retained for embedders that still feed only the flattened hint string.
        def legacy_hint_line(workspace)
          leader = workspace.fetch("leader_hint", "Ctrl-Space: T terminal/agent, F filter, A agent session, B editor, P PR, Q quit")
          filter = workspace.fetch("filter", "all")
          return hint_segments("command pending", leader) if workspace.fetch("leader_pending", false)

          hint_segments(leader, "filter: #{filter}")
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
