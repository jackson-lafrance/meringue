# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class ChatPane
    private
        def selected_worker_status_fragments(agent)
          status, model, thinking, context, turns = selected_worker_status_values(agent)
          fragments = [
            status,
            "model #{model}",
            "thinking #{thinking}",
            context
          ]
          fragments << "turns #{turns}" unless turns.nil?
          fragments
        end

        def selected_worker_status_values(agent)
          settings = agent.fetch("session_settings", {})
          settings = {} unless settings.is_a?(Hash)
          model = effective_model_reference(settings.fetch("model", nil)) || "unavailable"
          thinking = (settings["thinking_level"] || settings["thinkingLevel"]).to_s.strip
          thinking = "unavailable" if thinking.empty?
          stats = agent.fetch("session_stats", nil)
          stats = agent.fetch("context_usage", nil) unless stats.is_a?(Hash)
          stats = agent.dig("harness_metadata", "session_stats") unless stats.is_a?(Hash)
          stats = agent.dig("harness_metadata", "context_usage") unless stats.is_a?(Hash)
          stats = {} unless stats.is_a?(Hash)
          context = context_usage_fragment(stats, settings: settings)
          turns = session_turn_count(stats)
          status = agent.fetch("status", nil).to_s.strip
          status = "unavailable" if status.empty?
          [status, model, thinking, context, turns]
        end

        def effective_model_reference(model)
          return nil if model.nil?
          if model.is_a?(Hash)
            reference = model.fetch("reference", nil).to_s.strip
            return reference unless reference.empty?

            provider = model.fetch("provider", nil).to_s.strip
            id = model.fetch("id", model.fetch("modelId", nil)).to_s.strip
            return [provider, id].reject(&:empty?).join("/") unless provider.empty? || id.empty?
            return nil
          end

          value = model.to_s.strip
          value.empty? ? nil : value
        end

        def context_usage_fragment(stats, settings:)
          usage = stats["context_usage"] || stats["contextUsage"]
          usage = stats if usage.nil? && (stats.key?("tokens") || stats.key?("used") || stats.key?("capacity"))
          usage = usage.is_a?(Hash) ? usage : {}
          model = settings.fetch("model", nil)
          model = {} unless model.is_a?(Hash)
          capacity = numeric_telemetry_value(
            usage["capacity"] || usage["contextWindow"] || usage["context_window"] ||
              model["context_window"] || model["contextWindow"]
          )
          capacity = nil unless capacity&.positive?
          used = numeric_telemetry_value(usage.key?("tokens") ? usage["tokens"] : usage["used"])
          approximate = usage["approximate"] == true || usage["estimated"] == true
          prefix = approximate && used ? "~" : ""
          used_text = used.nil? ? "?" : token_count(used)
          capacity_text = capacity.nil? ? "?" : token_count(capacity)
          if used && capacity && capacity.positive?
            percent = (used.to_f / capacity.to_f) * 100.0
            "context #{prefix}#{used_text}/#{capacity_text} (#{percentage(percent)})"
          elsif used || capacity
            "context #{prefix}#{used_text}/#{capacity_text} (unavailable)"
          else
            "context unavailable"
          end
        end

        def numeric_telemetry_value(value)
          return nil if value.nil? || value.to_s.strip.empty?

          number = Float(value)
          number.finite? && number >= 0 ? number : nil
        rescue ArgumentError, TypeError
          nil
        end

        def token_count(value)
          number = value.to_f
          return number.round.to_s if number < 1_000

          scaled = if number >= 1_000_000
                     [number / 1_000_000.0, "M"]
                   else
                     [number / 1_000.0, "K"]
                   end
          rounded = scaled.fetch(0).round(1)
          formatted = rounded.to_i == rounded ? rounded.to_i.to_s : rounded.to_s
          "#{formatted}#{scaled.fetch(1)}"
        end

        def percentage(value)
          rounded = value.round(1)
          rounded.to_i == rounded ? "#{rounded.to_i}%" : "#{rounded}%"
        end

        def session_turn_count(stats)
          value = stats["turn_count"]
          value = stats["user_messages"] if value.nil?
          value = stats["userMessages"] if value.nil?
          number = numeric_telemetry_value(value)
          number&.to_i
        end

        def fit_worker_log_title(base, fragments, width)
          limit = [width.to_i, 1].max
          full = [base, *fragments].join(" · ")
          return full if full.length <= limit

          status, model, thinking, context, turns = selected_worker_status_values_from_fragments(fragments)
          compact = [
            base,
            status,
            "m #{clip_title_value(model, 18)}",
            "t #{clip_title_value(thinking, 8)}",
            context.sub(/\Acontext/, "ctx")
          ]
          compact << "n #{turns}" unless turns.nil?
          compact_text = compact.join(" · ")
          return compact_text if compact_text.length <= limit

          compact.delete_if { |part| part.start_with?("n ") }
          compact_text = compact.join(" · ")
          return compact_text if compact_text.length <= limit

          # At ordinary dashboard widths, dropping the `logs —` caption and
          # shortening labels preserves all four requested signals. The model is
          # visibly elided rather than silently replaced with an id-only guess.
          tight_base = base.sub(/\Alogs — /, "")
          tight_context = context.sub(/\Acontext /, "ctx ").sub(/\s+\(([^)]*)\)\z/, " \\1")
          tight = [
            tight_base,
            status,
            "m #{clip_title_value(model, 12)}",
            "t #{clip_title_value(thinking, 6)}",
            tight_context
          ].join(" · ")
          return tight if tight.length <= limit

          tight = [
            tight_base,
            status,
            "m #{clip_title_value(model, 4)}",
            "t #{clip_title_value(thinking, 6)}",
            tight_context
          ].join(" · ")
          return tight if tight.length <= limit

          # Keep the worker id, lifecycle state, thinking level, and context
          # signal ahead of the optional model spelling when a genuinely narrow
          # pane cannot fit all fields. An ellipsis means the value was clipped,
          # never a guessed value.
          core = [
            tight_base,
            status,
            "t #{clip_title_value(thinking, 6)}",
            tight_context
          ].join(" · ")
          clip_title_value(core, limit)
        end

        def selected_worker_status_values_from_fragments(fragments)
          status = fragments.fetch(0, "unavailable")
          model = fragments.fetch(1, "model unavailable").sub(/\Amodel /, "")
          thinking = fragments.fetch(2, "thinking unavailable").sub(/\Athinking /, "")
          context = fragments.fetch(3, "context unavailable")
          turns = fragments.find { |fragment| fragment.start_with?("turns ") }&.sub(/\Aturns /, "")
          [status, model, thinking, context, turns]
        end

        def clip_title_value(value, limit)
          text = value.to_s
          return text if text.length <= limit
          return text[0, limit] if limit <= 1

          "#{text[0, limit - 1]}…"
        end

        def log_scope_hint_segments(state)
          ChatTarget.hint_segments(state)
        end

        def empty_logs_lines(state, width: nil)
          FirstRun.empty_logs_lines(state, wrap: ->(text) { wrap_text_line(text, width && [width.to_i, 1].max) })
        end

        def delivery_pr_hint_segments(state)
          return [] unless Settings.github_enabled?(state)

          scoped_id = DeliveryPullRequest.scoped_id(state)
          return open_pull_requests_hint_segments(state) if scoped_id.empty?

          presentation = DeliveryPullRequest.for_id(state, scoped_id)
          return scoped_delivery_pr_segments(presentation) if DeliveryPullRequest.openable?(presentation)
          return [["PR link unusable", Style::WARNING]] if presentation.fetch("state", nil) == "invalid"

          [["no PR yet", Style::MUTED]]
        end

        def scoped_delivery_pr_segments(presentation)
          verified = presentation.fetch("metadata_available", true) && !presentation["stale"]
          [
            ["PR ##{presentation.fetch("number", "?")}", Style::ACCENT_BOLD],
            [" #{DeliveryPullRequest.status_label(presentation)}", verified ? Style::SUCCESS : Style::WARNING]
          ]
        end

        def open_pull_requests_hint_segments(state)
          return [] unless OpenPullRequests.tracked?(state)

          total = OpenPullRequests.count(state)
          [[OpenPullRequests.summary_label(state), total.positive? ? Style::ACCENT_BOLD : Style::MUTED]]
        end

        def log_lines_cache_key(state, width)
          chat = chat_state(state)
          [
            width,
            log_records_cache_key(state.fetch("logs", [])),
            log_agents_cache_key(state.fetch("agents", [])),
            message_records_cache_key(chat.fetch("messages", [])),
            AgentTreeNavigation.selected_agent_id(state),
            log_scope_cache_key(state),
            state.dig("metadata", "last_recount", "recounted_at"),
            Style.current_colorscheme,
            Timestamps.context_key
          ]
        end

        def log_records_cache_key(logs)
          records = Array(logs)
          [records.length, log_record_id(records.first), log_record_id(records.last)]
        end

        def log_record_id(record)
          record.is_a?(Hash) ? record.fetch("id", nil) : record
        end

        def message_records_cache_key(messages)
          Array(messages).map do |message|
            next message unless message.is_a?(Hash)

            message.values_at("id", "role", "text", "status", "visible", "timestamp", "source_id")
          end
        end

        def log_agents_cache_key(agents)
          Array(agents).map do |agent|
            next agent unless agent.is_a?(Hash)

            [
              agent.fetch("id", nil),
              agent.fetch("type", nil),
              agent_title(agent),
              !AgentTreeNavigation.active_agent_pr_url(agent).nil?
            ]
          end
        end

        def log_scope_cache_key(state)
          scope = LogScope.scope(state)
          [
            scope.fetch("id", nil),
            scope.fetch("label", nil),
            Array(scope.fetch("member_ids", [])).map(&:to_s)
          ]
        end

        def log_entries(state)
          message_entries = visible_messages(chat_state(state).fetch("messages", []) || []).map.with_index { |message, index| message_entry(message, index, state) }
          durable_log_entries = Array(state.fetch("logs", [])).map.with_index { |entry, index| log_entry(entry, index, state) }.compact
          message_topics = topic_index(message_entries)
          durable_log_entries = durable_log_entries.reject { |entry| redundant_lifecycle_log?(entry, message_topics) }
          duplicate_log_texts = duplicate_text_index(durable_log_entries)
          entries = message_entries.filter_map { |entry| deduplicate_message_entry(entry, duplicate_log_texts) } + durable_log_entries
          # A selected AgentTree node scopes the pane to that node's subtree.
          entries = LogScope.filter(LogScope.scope(state), entries)
          entries.each_with_index { |entry, sequence| entry["sequence"] = sequence }
          entries.sort_by { |entry| entry_sort_key(entry) }
        end

        def visible_messages(messages)
          messages.select { |message| visible_message?(message) }
        end

        def visible_message?(message)
          return false if message.fetch("visible", true) == false

          !message.fetch("text", "").to_s.strip.empty?
        end

        def topic_index(entries)
          entries.each_with_object({}) do |entry, topics|
            key = event_topic_key(entry)
            topics[key] = true if key
          end
        end

        def event_topic_key(entry)
          return nil unless entry.fetch("kind", nil) == "message"
          return nil unless entry.fetch("role", nil) == "agent"

          source_id = entry.fetch("source_id", nil).to_s
          return nil if source_id.empty?

          "worker_completed:#{source_id}"
        end

        def redundant_lifecycle_log?(entry, message_topics)
          source_id = entry.fetch("source_id", nil).to_s
          return false unless message_topics["worker_completed:#{source_id}"]

          message = entry.fetch("message", entry.fetch("text", "")).to_s
          entry.fetch("source_type", nil) == "worker" && message == "Worker #{source_id} completed."
        end

        def duplicate_text_index(entries)
          entries.each_with_object({}) do |entry, index|
            text = normalized_duplicate_text(entry.fetch("text", ""))
            index[text] = true unless text.empty?
          end
        end

        def deduplicate_message_entry(entry, duplicate_texts)
          text = entry.fetch("text", "").to_s
          return nil if duplicate_texts[normalized_duplicate_text(text)]

          lines = text.lines.map(&:chomp)
          return entry unless lines.length > 1 && duplicate_texts[normalized_duplicate_text(lines.first)]

          trimmed_text = lines.drop(1).join("\n").strip
          return nil if trimmed_text.empty?

          entry.merge("text" => trimmed_text)
        end

        def normalized_duplicate_text(text)
          text.to_s.gsub(/[[:space:]]+/, " ").strip
        end

        def message_entry(message, index, state = {})
          role = normalized_message_role(message.fetch("role", "meringue"))
          source_id = message.fetch("source_id", nil)
          {
            "kind" => "message",
            "timestamp" => message.fetch("timestamp", nil),
            "role" => role,
            "source_id" => source_id,
            "text" => message.fetch("text", "").to_s,
            "status" => message.fetch("status", nil),
            "agent" => agent_by_id(state, source_id),
            "ordinal" => index
          }
        end

        def log_entry(entry, index, state)
          return nil unless entry.is_a?(Hash)

          source_type = entry.fetch("source_type", "system").to_s
          source_id = entry.fetch("source_id", nil)
          role = log_role(source_type, source_id)
          {
            "kind" => "log",
            "record_id" => entry.fetch("id", nil),
            "timestamp" => entry.fetch("timestamp", nil),
            "role" => role,
            "source_type" => source_type,
            "source_id" => source_id,
            "text" => log_display_text(entry),
            "message" => entry.fetch("message", "").to_s,
            "details" => entry.fetch("details", {}) || {},
            "status" => log_status(entry),
            "level" => entry.fetch("level", "info"),
            "presentation" => log_presentation(entry),
            "agent" => agent_by_id(state, source_id),
            "ordinal" => index
          }
        end

        def log_display_text(entry)
          worker_completion_text(entry) || entry.fetch("message", "").to_s
        end

        def worker_completion_text(entry)
          return nil unless worker_completion_entry?(entry)

          source_id = entry.fetch("source_id").to_s
          details = entry.fetch("details", {}) || {}
          details = {} unless details.is_a?(Hash)
          pr_urls = worker_completion_pr_urls(details)
          output = AgentOutput.normalize(details["last_assistant_text"], source_id: source_id, pr_urls: pr_urls)
          lines = pr_urls.map { |url| "PR  #{url}" }
          lines << output unless output.empty?
          lines.empty? ? "Completed." : lines.join("\n")
        end

        def worker_completion_entry?(entry)
          source_id = entry.fetch("source_id", nil).to_s
          !source_id.empty? &&
            entry.fetch("source_type", nil).to_s == "worker" &&
            entry.fetch("message", "").to_s == "Worker #{source_id} completed."
        end

        def worker_completion_pr_urls(details)
          delivery_pull_requests = [
            details["delivery_pull_request"],
            *Array(details["delivery_pull_requests"])
          ].compact
          delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }.compact.map(&:to_s).reject(&:empty?).uniq
        end

        def log_presentation(entry)
          return "result" if worker_completion_entry?(entry)
          return "error" if entry.fetch("level", nil).to_s == "error"
          return "warning" if entry.fetch("level", nil).to_s == "warning"

          "progress"
        end

        def entry_sort_key(entry)
          [sortable_timestamp(entry.fetch("timestamp", nil)), entry.fetch("sequence", entry.fetch("ordinal", 0)).to_i]
        end

        def sortable_timestamp(timestamp)
          Timestamps.sort_key(timestamp)
        end

        def normalized_message_role(role)
          case role.to_s
          when "you" then "you"
          when "agent" then "agent"
          else "meringue"
          end
        end

        def log_role(source_type, source_id)
          return "you" if source_type == "user"
          return "agent" if %w[head worker].include?(source_type)
          return "agent" if source_type == "harness" && !source_id.to_s.empty?

          "meringue"
        end

        def log_status(entry)
          return "done" if worker_completion_entry?(entry)

          label = log_level(entry)
          return nil if label == "info"

          label
        end

        def log_level(entry)
          details = entry.fetch("details", {}) || {}
          details = {} unless details.is_a?(Hash)
          return "cmd" if details["presentation"] == "cmd" || details["kind"].to_s.start_with?("kernel_command")

          {
            "info" => "info",
            "warning" => "warn",
            "error" => "err"
          }.fetch(entry.fetch("level", nil), "log")
        end

        def agent_by_id(state, source_id)
          return nil if source_id.to_s.empty?

          Array(state.fetch("agents", [])).find { |agent| agent["id"].to_s == source_id.to_s }
        end

        def role_line(entry, selected_agent_id: nil)
          style = entry_style(entry)
          segments = [
            ["#{timestamp(entry)} ", Style::DIM],
            [entry_icon(entry), style]
          ]
          segments.concat(participant_segments(entry, style))
          segments.concat(agent_title_segments(entry, selected_agent_id: selected_agent_id))
          segments.concat(log_level_segments(entry))
          segments
        end

        def role_lines(entry, selected_agent_id:, width:)
          segments = role_line(entry, selected_agent_id: selected_agent_id)
          return [segments] if width.nil?

          wrap_segments(segments, width)
        end

        def wrap_segments(segments, width)
          limit = [width.to_i, 1].max
          rows = [[]]
          remaining = limit

          Array(segments).each do |segment|
            text = segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s
            style = segment.is_a?(Array) ? segment.fetch(1, nil) : nil
            chars = text.chars
            offset = 0
            while offset < chars.length
              if remaining.zero?
                rows << []
                remaining = limit
              end
              chunk = chars.slice(offset, remaining)
              rows.last << [chunk.join, style] unless chunk.empty?
              offset += chunk.length
              remaining -= chunk.length
            end
          end

          rows.pop if rows.length > 1 && rows.last.empty?
          rows
        end

        def entry_style(entry)
          case entry.fetch("role", "meringue")
          when "you" then Style::USER
          when "agent" then agent_role_style(entry)
          else Style::ACCENT_BOLD
          end
        end

        def agent_role_style(entry)
          agent_id = entry.fetch("source_id", nil).to_s
          return Style::ASSISTANT if agent_id.empty?

          Style.agent_style(agent_id, kind: agent_kind(entry))
        end

        def agent_body_style(entry)
          agent_id = entry.fetch("source_id", nil).to_s
          return Style::ASSISTANT if agent_id.empty?

          Style.agent_body_style(agent_id)
        end

        def agent_kind(entry)
          agent = entry.fetch("agent", nil)
          kind = agent.is_a?(Hash) ? agent.fetch("type", nil).to_s : ""
          return kind if %w[head worker].include?(kind)

          source_type = entry.fetch("source_type", nil).to_s
          return source_type if %w[head worker].include?(source_type)
          return "head" if entry.fetch("source_id", nil).to_s.match?(/\AH\d+\z/)

          ""
        end

        def entry_icon(entry)
          return ERROR_ICON if %w[error warning].include?(entry.fetch("presentation", nil))
          return RESULT_ICON if entry.fetch("presentation", nil) == "result"

          case entry.fetch("role", "meringue")
          when "you" then USER_ICON
          when "agent" then agent_kind(entry) == "head" ? HEAD_ICON : WORKER_ICON
          else KERNEL_ICON
          end
        end

        def gutter_segment(entry)
          gutter = if entry.fetch("role", nil) == "agent"
                     [AGENT_GUTTER, agent_body_style(entry)]
                   else
                     [PLAIN_GUTTER, Style::DIM]
                   end
          Selection.display_only_segment(gutter)
        end

        def participant_segments(entry, style)
          segments = [[" #{participant_label(entry)}", style]]
          author_id = head_command_author_id(entry)
          return segments unless author_id

          # Keep the kernel as the speaking/applying participant, then show the proposing head as
          # secondary provenance in that head's identity color. The wording matters: H127 did not
          # apply state itself; the command reached the user through Meringue.
          segments + [
            [" · via ", Style::DIM],
            [author_id, Style.agent_style(author_id, kind: "head")]
          ]
        end

        def participant_label(entry)
          return "you" if entry.fetch("role", nil) == "you"
          return "meringue" unless entry.fetch("role", nil) == "agent"

          agent_id = entry.fetch("source_id", nil).to_s
          return "agent" if agent_id.empty?

          agent_id
        end

        def head_command_author_id(entry)
          return nil unless entry.fetch("role", nil) == "meringue"

          details = entry.fetch("details", nil)
          return nil unless details.is_a?(Hash)

          author_type = details.fetch("command_author_type", nil).to_s
          author_id = details.fetch("command_author_id", nil).to_s
          # Compatibility for command-output rows persisted before explicit author metadata was
          # added: those rows already carried the proposing head in `details.head_id`.
          if author_id.empty? && details.fetch("kind", nil).to_s == "kernel_command_output"
            author_type = "head"
            author_id = details.fetch("head_id", nil).to_s
          end
          return nil unless author_type == "head" && author_id.match?(/\AH\d+\z/)

          author_id
        end

        def agent_title_segments(entry, selected_agent_id: nil)
          return [] unless entry.fetch("role", nil) == "agent"

          agent = entry.fetch("agent", nil)
          title = agent_title(agent)
          marker = agent && AgentTreeNavigation.active_agent_pr_url(agent) ? " ↗" : ""
          text = [title, marker].join
          return [] if text.strip.empty?

          selected = !selected_agent_id.to_s.empty? && entry.fetch("source_id", nil).to_s == selected_agent_id.to_s
          [[" · ", Style::DIM], [text, selected ? Style::AGENT_TREE_SELECTED : Style::TITLE]]
        end

        def agent_title(agent)
          return "" unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          metadata.fetch("title", "#{agent.fetch("type", "agent")} session").to_s
        end

        def log_level_segments(entry)
          return [] unless entry.fetch("kind", nil) == "log"

          status = entry.fetch("status", nil).to_s
          return [] if status.empty?

          [[" · ", Style::DIM], [status, log_level_style(entry)]]
        end

        def log_level_style(entry)
          return Style::SUCCESS if entry.fetch("presentation", nil) == "result"

          case entry.fetch("level", nil)
          when "warning" then Style::LOG_WARNING
          when "error" then Style::LOG_ERROR
          else entry.fetch("status", nil) == "cmd" ? Style::LOG_COMMAND : Style::LOG_INFO
          end
        end

        def body_lines(entry, width:, gutter:)
          if conversational_markdown?(entry)
            Markdown.render(
              entry.fetch("text", ""),
              width: width,
              gutter: gutter,
              base_style: Style::TEXT,
              accent_style: agent_body_style(entry)
            )
          else
            wrapped_text_lines(
              entry.fetch("text", ""),
              width: width,
              gutter: gutter,
              style: body_text_style(entry)
            )
          end
        end

        def conversational_markdown?(entry)
          return false unless entry.fetch("role", nil) == "agent"
          return false if entry.fetch("status", nil).to_s.match?(/err|fail|warn/i)
          return true if entry.fetch("kind", nil) == "message"
          return true if entry.fetch("presentation", nil) == "result"

          details = entry.fetch("details", {}) || {}
          details.is_a?(Hash) && %w[head_summary head_response].include?(details.fetch("kind", nil).to_s)
        end

        def body_text_style(entry)
          case entry.fetch("level", nil)
          when "warning" then Style::WARNING
          when "error" then Style::ERROR
          else Style::TEXT
          end
        end

        def timestamp(entry)
          Timestamps.display(entry.fetch("timestamp", nil)) || "[--:--]"
        end

        def status_line(status, gutter = [PLAIN_GUTTER, Style::DIM])
          [
            gutter,
            [status.to_s, Style::MUTED]
          ]
        end

        def wrapped_input_lines(input_buffer, input_cursor:, width: nil, selection: nil,
                                prompt_style: Style::ACCENT_BOLD, placeholder: "enter a prompt")
          MultilineInput.lines(
            input_buffer,
            input_cursor: input_cursor,
            width: width,
            selection: selection,
            prompt_style: prompt_style,
            placeholder: placeholder
          )
        end

        def composer_available_width(input_buffer, width)
          MultilineInput.available_width(input_buffer, width)
        end

        def input_row_spans(input_buffer, available_width)
          MultilineInput.row_spans(input_buffer, available_width)
        end

        def composer_cursor_location(spans, cursor)
          MultilineInput.cursor_location(spans, cursor)
        end

        def paste_marker_index?(paste_ranges, index)
          return false if paste_ranges.empty?

          paste_ranges.any? { |range| range.cover?(index) }
        end

        def composer_selection_range(selection, buffer_length)
          return nil unless selection.is_a?(Hash)

          start_index = selection.fetch("start", 0).to_i.clamp(0, buffer_length)
          finish_index = selection.fetch("end", 0).to_i.clamp(0, buffer_length)
          return nil if finish_index <= start_index

          (start_index...finish_index)
        end

        def input_line_segments(chars, span, first_line:, cursor_column:, selection_range:, prompt_style: Style::ACCENT_BOLD,
                                paste_ranges: [])
          prefix = first_line ? "› " : "  "
          segments = [[prefix, first_line ? prompt_style : Style::DIM]]
          run = +""
          run_style = nil

          span.fetch(:length).times do |offset|
            index = span.fetch(:start) + offset
            if cursor_column == offset
              segments << [run.dup, run_style] unless run.empty?
              run.clear
              segments << ["_", Style::ACCENT_BOLD]
            end

            # A collapsed paste is one chunk, so it is tinted as one token rather
            # than reading as literal text the user typed.
            style = if selection_range&.include?(index)
                      Style::SELECTION
                    elsif paste_marker_index?(paste_ranges, index)
                      Style::ACCENT
                    else
                      Style::TEXT
                    end
            if style != run_style
              segments << [run.dup, run_style] unless run.empty?
              run.clear
              run_style = style
            end
            run << chars[index].to_s
          end

          segments << [run.dup, run_style] unless run.empty?
          segments << ["_", Style::ACCENT_BOLD] if cursor_column && cursor_column >= span.fetch(:length)
          segments
        end

        def wrapped_text_lines(text, width: nil, gutter: [PLAIN_GUTTER, Style::DIM], style: Style::TEXT)
          gutter = Selection.display_only_segment(gutter)
          content_width = width ? [width.to_i - 2, 1].max : nil
          text.to_s.split("\n", -1).flat_map do |line|
            wrap_text_line(line, content_width)
          end.map do |line|
            line.empty? ? [["", style]] : [gutter, [line, style]]
          end
        end

        def wrap_text_line(line, width)
          return [line] unless width && line.length > width

          chunks = []
          remaining = line.dup
          until remaining.empty?
            if remaining.length <= width
              chunks << remaining
              break
            end

            break_at = remaining.rindex(/\s/, width)
            if break_at&.positive?
              chunks << remaining[0...break_at]
              remaining = remaining[(break_at + 1)..].to_s.lstrip
            else
              chunks << remaining[0...width]
              remaining = remaining[width..].to_s.lstrip
            end
          end
          chunks
        end

        def selection_hint_segments(state)
          selection = state.fetch("_selection", {}) || {}
          status = selection.fetch("status", "").to_s.strip
          return [["⧉ #{status}", Style::SUCCESS]] unless status.empty?
          if selection.fetch("mode", nil).to_s == "logs_cursor"
            return [["⧉ logs select", Style::ACCENT], ["  arrows move · Shift+arrows extend · Ctrl-C copies · Esc exits", Style::MUTED]]
          end
          return [["⧉ selection", Style::ACCENT], ["  Ctrl-C copies", Style::MUTED]] if selection.fetch("active", false)
          return [["use the mouse or shift+arrows to select text.", Style::MUTED]] if logs_pane_focused?(state)

          []
        end

        def logs_pane_focused?(state)
          (state.fetch("_scroll", {}) || {}).fetch("active_pane", nil).to_s == "logs"
        end

        def interaction_hint_segments
          HintLine.segments(
            [
              ["Ctrl-C", "clear/quit"],
              ["Tab", "focus"],
              ["/", "commands"]
            ]
          )
        end

        def active_harness_label(state)
          metadata = state.fetch("metadata", {}) || {}
          explicit_label = metadata.fetch("active_harness_label", "").to_s.strip
          return explicit_label unless explicit_label.empty?

          provider = metadata.fetch("active_harness", "").to_s.strip
          return "" if provider.empty?

          Meringue::Harness::Registry.provider_label(provider)
        end

        def compact_harness_status_segments(state)
          metadata = state.fetch("metadata", {}) || {}
          head = metadata.fetch("active_head_harness_label", "").to_s.strip
          worker = metadata.fetch("active_worker_harness_label", "").to_s.strip
          head = Meringue::Harness::Registry.provider_label(metadata["active_head_harness"]) if head.empty? && metadata["active_head_harness"]
          worker = Meringue::Harness::Registry.provider_label(metadata["active_worker_harness"]) if worker.empty? && metadata["active_worker_harness"]
          shared = active_harness_label(state)
          head = shared if head.empty?
          worker = shared if worker.empty?
          return [] if head.empty? && worker.empty?
          return [["harness: ", Style::DIM], [head, Style::ACCENT_BOLD]] if head == worker

          [
            ["head: ", Style::DIM], [head, Style::ACCENT_BOLD],
            [" · worker: ", Style::DIM], [worker, Style::ACCENT_BOLD]
          ]
        end

        def compact_status_segments(state, pending_count)
          working_workers = active_agent_count(state, "worker")
          working_heads = active_agent_count(state, "head")
          return active_status_segments(working_workers, working_heads) if working_workers.positive? || working_heads.positive?
          return [[prompt_count_label(pending_count), Style::ACCENT]] if pending_count.positive?

          []
        end

        def active_status_segments(working_workers, working_heads)
          segments = [["● ", Style::ACCENT_BOLD]]
          metrics = []
          metrics << ["#{working_workers}W", Style::WORKING] if working_workers.positive?
          metrics << ["#{working_heads}H", Style::ACCENT_BOLD] if working_heads.positive?
          metrics.each_with_index do |metric, index|
            segments << [" ", Style::DIM] unless index.zero?
            segments << metric
          end
          segments
        end

        def active_agent_count(state, type)
          state.fetch("agents", []).count do |agent|
            agent["type"] == type && agent["status"] == "working"
          end
        end

        def prompt_count_label(pending_count)
          "#{pending_count} prompt#{pending_count == 1 ? "" : "s"} running"
        end

        def chat_state(state)
          state.fetch("_chat", {}) || {}
        end

        def selected_slash_suggestion_index(state, count)
          index = chat_state(state).fetch("slash_suggestion_index", NO_SLASH_SELECTION).to_i
          # Negative means the user has not navigated the list yet, so nothing is highlighted.
          return NO_SLASH_SELECTION unless count.positive? && index >= 0

          index.clamp(0, count - 1)
        end

        def slash_suggestion_window_start(count, selected_index, limit: VISIBLE_SUGGESTION_LIMIT)
          return 0 if count <= limit || selected_index.negative?

          max_start = count - limit
          [selected_index - limit + 1, 0].max.clamp(0, max_start)
        end

        def plain_text(line)
          return line.to_s unless line.is_a?(Array)

          line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join
        end

      end
    end
  end
end
