# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    # Builds the ordered entry list a focused worker transcript renders.
    #
    # This is presentation-neutral on purpose: it normalizes whatever the harness
    # session view provides (assembled history, live events, harness message
    # lists, local echoes, durable logs) into one deduplicated, chronological
    # list of entries. The pane owns how those entries look; nothing here emits
    # styles, and nothing here is specific to one harness backend.
    module WorkspaceTranscript
      TOOL_ROLES = %w[tool_call tool_result].freeze
      BASH_TOOL_NAMES = %w[bash sh shell zsh run exec command].freeze
      COMMAND_ARGUMENT_KEYS = %w[command cmd script shell_command].freeze
      PATH_ARGUMENT_KEYS = %w[path file file_path filename target].freeze

      module_function

      # Ordered entries for one worker, already deduplicated and filtered.
      # +fallback_text+ is used only when nothing else could be recovered.
      def entries(workspace:, agent_id:, logs: [], filter: "all", fallback_text: nil)
        local = tag_entry_source(Array(workspace.fetch("messages", [])), "local")
        live = workspace.fetch("agent_session", {}) || {}
        session = session_entries(live)
        local = local.reject { |entry| session_contains_entry?(session, entry) }

        collected = local + session
        # Durable worker logs hold the compact completion summary, not the
        # harness transcript. They are a fallback only when no session output
        # could be recovered, otherwise they push the real transcript offscreen.
        collected.concat(tag_entry_source(durable_agent_entries(logs, agent_id), "durable")) if session.empty?

        collected = deduplicate_entries(collected)
        collected = drop_cross_source_duplicates(collected)
        collected = drop_duplicate_tool_sources(collected)
        collected = chronological_entries(drop_superseded_partials(collected))

        if collected.empty?
          text = fallback_text.to_s.strip
          collected << { "role" => "agent", "text" => text } unless text.empty?
        end

        collected.select { |entry| transcript_filter_match?(entry, filter) }
      end

      def session_entries(live)
        entries = []
        entries.concat(tag_entry_source(Array(live.fetch("messages", [])), "messages"))
        entries.concat(tag_entry_source(Array(live.fetch("items", [])).flat_map { |item| live_item_entries(item) }, "items"))
        entries.concat(tag_entry_source(Array(live.fetch("events", [])).flat_map { |event| live_event_entries(event) }, "events"))
        lines = Array(live.fetch("lines", []))
        entries << { "role" => "agent", "text" => lines.join("\n"), "source" => "lines" } unless lines.empty?
        entries
      end

    def live_item_entries(item)
      return [] unless item.is_a?(Hash)

      role = item.fetch("role", item.fetch("kind", "agent")).to_s
      role = "you" if role == "user"
      role = "agent" if role == "assistant"
      role = "tool_result" if %w[tool toolResult bashExecution].include?(role)
      timestamp = item.fetch("timestamp", nil)
      entries = []

      # Control records from a Pi session (compaction, branch summaries, model changes, and
      # visible extension messages) are already normalized by the harness adapter. They are
      # session output, not Meringue log entries, so render them in the same stream without
      # trying to infer a fake assistant message.
      if item.fetch("kind", nil).to_s == "notice" && item.fetch("content", item.fetch("text", "")).to_s.strip != ""
        entries << transcript_entry(role, item.fetch("content", item.fetch("text", "")), item, timestamp: timestamp, part: "notice")
        return entries
      end

      if role == "custom"
        text = item.fetch("content", item.fetch("text", "")).to_s.strip
        return text.empty? ? entries : [transcript_entry("system", text, item, timestamp: timestamp, part: "custom")]
      end

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
      tool_call_delta = delta_type.start_with?("toolcall_") || delta_type.start_with?("tool_call_")
      if text.empty? && streaming_delta && !reasoning_delta && !tool_call_delta
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

      if tool_call_delta
        call = {
          "id" => item.fetch("tool_call_id", nil),
          "name" => item.fetch("tool_name", nil),
          "arguments" => item.fetch("tool_arguments", delta_text)
        }.compact
        unless call.empty? || (call.fetch("name", "").to_s.empty? && call.fetch("arguments", "").to_s.empty?)
          entries << tool_call_entry(call, timestamp: timestamp)
        end
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
        [transcript_entry("system", event.fetch("message", "The agent requested unsupported interactive input.").to_s, event, part: "interaction")]
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

    def durable_agent_entries(logs, agent_id)
      Array(logs).filter_map do |entry|
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
    end
  end
end
