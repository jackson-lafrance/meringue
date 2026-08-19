# frozen_string_literal: true

module Meringue
  module TUI
    # A small, dependency-free Markdown renderer for conversational agent text.
    # It emits Canvas segments rather than ANSI-bearing strings, so untrusted
    # assistant output cannot inject terminal control sequences.
    module Markdown
      ANSI_OSC_PATTERN = /\e\].*?(?:\a|\e\\)/m
      ANSI_CSI_PATTERN = /\e\[[0-?]*[ -\/]*[@-~]/
      ANSI_ESCAPE_PATTERN = /\e[@-_]/
      FENCE_PATTERN = /\A\s{0,3}(`{3,}|~{3,})(.*)\z/
      HEADING_PATTERN = /\A\s{0,3}(\#{1,6})\s+(.+?)\s*\z/
      LIST_PATTERN = /\A(\s*)([-+*]|\d+[.)])\s+(.+)\z/
      QUOTE_PATTERN = /\A\s*(>+)\s?(.*)\z/
      RULE_PATTERN = /\A\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})\z/
      INLINE_PATTERN = /(`+)(.+?)\1|!\[([^\]]*)\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)|\[([^\]]+)\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)|<((?:https?:\/\/|mailto:)[^>]+)>|\*\*(.+?)\*\*|__(.+?)__|(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!\w)_([^_\n]+)_(?!\w)/

      module_function

      def render(text, width:, gutter:, base_style:, accent_style:)
        # The gutter consumes terminal columns for identity/indentation, but it
        # is pane chrome rather than authored Markdown. Keep it in every
        # rendered row while making that distinction available to selection.
        gutter = Selection.display_only_segment(gutter)
        lines = sanitized_lines(text)
        rendered = []
        paragraph = []
        index = 0

        flush_paragraph = lambda do
          unless paragraph.empty?
            content = paragraph.join(" ").gsub(/[[:space:]]+/, " ").strip
            rendered.concat(render_inline_block(content, width: width, gutter: gutter, base_style: base_style)) unless content.empty?
            paragraph.clear
          end
        end

        while index < lines.length
          line = lines[index]

          if (fence = line.match(FENCE_PATTERN))
            flush_paragraph.call
            block, index = fenced_block(lines, index, fence[1])
            rendered.concat(render_code_block(block, language: fence[2].to_s.strip, width: width, gutter: gutter, base_style: base_style, accent_style: accent_style))
            next
          end

          if line.strip.empty?
            flush_paragraph.call
            append_blank_line(rendered, gutter)
            index += 1
            next
          end

          if (heading = line.match(HEADING_PATTERN))
            flush_paragraph.call
            prefix = "#{heading[1]} "
            rendered.concat(
              render_inline_block(
                heading[2].sub(/\s+\#{1,6}\s*\z/, ""),
                width: width,
                gutter: gutter,
                base_style: Style.with_codes(accent_style, 1),
                first_prefix: [[prefix, accent_style]],
                continuation_prefix: [[" " * prefix.length, accent_style]]
              )
            )
            index += 1
            next
          end

          if line.match?(RULE_PATTERN)
            flush_paragraph.call
            available = available_width(width, gutter, [])
            rendered << [gutter, ["─" * available, accent_style]]
            index += 1
            next
          end

          if (quote = line.match(QUOTE_PATTERN))
            flush_paragraph.call
            depth = [quote[1].length, 3].min
            quote_lines = [quote[2]]
            index += 1
            while index < lines.length && (continued = lines[index].match(QUOTE_PATTERN)) && [continued[1].length, 3].min == depth
              quote_lines << continued[2]
              index += 1
            end
            quote_text = quote_lines.join(" ").gsub(/[[:space:]]+/, " ").strip
            quote_prefix = Array.new(depth) { ["│ ", accent_style] }
            rendered.concat(
              render_inline_block(
                quote_text,
                width: width,
                gutter: gutter,
                base_style: Style.with_codes(base_style, 3),
                first_prefix: quote_prefix,
                continuation_prefix: quote_prefix
              )
            )
            next
          end

          if (list = line.match(LIST_PATTERN))
            flush_paragraph.call
            indent = [list[1].length / 2, 4].min
            marker = list[2].match?(/\A\d/) ? list[2] : "•"
            content = list[3]
            if (task = content.match(/\A\[([ xX])\]\s+(.*)\z/))
              marker = task[1].downcase == "x" ? "☒" : "☐"
              content = task[2]
            end
            index += 1
            while index < lines.length && list_continuation?(lines[index], list[1].length)
              content = "#{content.rstrip} #{lines[index].strip}"
              index += 1
            end
            prefix_text = ("  " * indent) + marker + " "
            rendered.concat(
              render_inline_block(
                content,
                width: width,
                gutter: gutter,
                base_style: base_style,
                first_prefix: [[prefix_text, accent_style]],
                continuation_prefix: [[" " * prefix_text.length, accent_style]]
              )
            )
            next
          end

          if line.start_with?("    ")
            flush_paragraph.call
            code_lines = []
            while index < lines.length && (lines[index].start_with?("    ") || lines[index].strip.empty?)
              code_lines << (lines[index].strip.empty? ? "" : lines[index][4..].to_s)
              index += 1
            end
            rendered.concat(render_code_block(code_lines, language: "", width: width, gutter: gutter, base_style: base_style, accent_style: accent_style))
            next
          end

          hard_break = line.end_with?("  ") || line.end_with?("\\")
          paragraph << line.strip.sub(/(?: {2}|\\)\z/, "")
          if hard_break
            flush_paragraph.call
          end
          index += 1
        end

        flush_paragraph.call
        rendered.pop while rendered.length > 1 && blank_rendered_line?(rendered.last)
        rendered
      end

      def list_continuation?(line, list_indent)
        return false if line.to_s.strip.empty?
        return false if line.match?(FENCE_PATTERN) || line.match?(LIST_PATTERN) || line.match?(HEADING_PATTERN) || line.match?(QUOTE_PATTERN)

        line[/\A */].to_s.length > list_indent
      end

      def sanitized_lines(text)
        value = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        value = value.gsub(ANSI_OSC_PATTERN, "")
                     .gsub(ANSI_CSI_PATTERN, "")
                     .gsub(ANSI_ESCAPE_PATTERN, "")
                     .gsub("\r\n", "\n").tr("\r", "\n").tr("\u00a0", " ")
                     .gsub("\t", "  ")
                     .gsub(/[^\P{C}\n]/u, "")
        value.split("\n", -1).map(&:rstrip)
      rescue EncodingError, ArgumentError
        [""]
      end

      def fenced_block(lines, opening_index, fence)
        block = []
        index = opening_index + 1
        closing_pattern = /\A\s{0,3}#{Regexp.escape(fence[0])}{#{fence.length},}\s*\z/
        while index < lines.length
          if lines[index].match?(closing_pattern)
            return [block, index + 1]
          end

          block << lines[index]
          index += 1
        end
        [block, index]
      end

      def render_code_block(lines, language:, width:, gutter:, base_style:, accent_style:)
        code_style = Style.with_codes(base_style, 2)
        label = language.empty? ? "code" : "code · #{language}"
        output = []
        output << clipped_prefixed_line(gutter, [["┌─ #{label}", accent_style]], width)
        code_prefix = [["│ ", accent_style]]
        continuation_prefix = [["│ ", accent_style]]
        Array(lines).each do |line|
          output.concat(
            wrap_segments(
              line.empty? ? [["", code_style]] : [[line, code_style]],
              width: width,
              gutter: gutter,
              first_prefix: code_prefix,
              continuation_prefix: continuation_prefix,
              preserve_space: true
            )
          )
        end
        output << clipped_prefixed_line(gutter, [["└─", accent_style]], width)
        output
      end

      def render_inline_block(text, width:, gutter:, base_style:, first_prefix: [], continuation_prefix: [])
        wrap_segments(
          inline_segments(text, base_style),
          width: width,
          gutter: gutter,
          first_prefix: first_prefix,
          continuation_prefix: continuation_prefix
        )
      end

      def inline_segments(text, base_style)
        segments = []
        cursor = 0
        text.to_s.to_enum(:scan, INLINE_PATTERN).each do
          match = Regexp.last_match
          append_segment(segments, text[cursor...match.begin(0)], base_style)

          if match[1]
            append_segment(segments, "`#{match[2]}`", Style.with_codes(base_style, 2))
          elsif match[3]
            append_segment(segments, "[image: #{match[3]}]", Style.with_codes(base_style, 3))
            append_link_target(segments, match[4], base_style)
          elsif match[5]
            append_segment(segments, match[5], Style.with_codes(base_style, 4))
            append_link_target(segments, match[6], base_style)
          elsif match[7]
            append_segment(segments, match[7], Style.with_codes(base_style, 4))
          elsif match[8] || match[9]
            append_segment(segments, match[8] || match[9], Style.with_codes(base_style, 1))
          else
            append_segment(segments, match[10] || match[11], Style.with_codes(base_style, 3))
          end
          cursor = match.end(0)
        end
        append_segment(segments, text[cursor..], base_style)
        segments
      end

      def append_link_target(segments, target, base_style)
        value = target.to_s
        append_segment(segments, " (#{value})", Style.with_codes(base_style, 2, 4))
      end

      def append_segment(segments, text, style)
        value = text.to_s
        return if value.empty?

        if segments.last && segments.last[1] == style
          segments.last[0] << value
        else
          segments << [value.dup, style]
        end
      end

      def wrap_segments(segments, width:, gutter:, first_prefix:, continuation_prefix:, preserve_space: false)
        styled_chars = segments.flat_map { |text, style| text.to_s.chars.map { |char| [char, style] } }
        return [[gutter, *first_prefix]] if styled_chars.empty?

        output = []
        first = true
        until styled_chars.empty?
          prefix = first ? first_prefix : continuation_prefix
          capacity = available_width(width, gutter, prefix)
          take = [capacity, styled_chars.length].min
          if !preserve_space && take < styled_chars.length
            break_index = styled_chars.first(take + 1).rindex { |char, _style| char.match?(/\s/) }
            take = break_index if break_index&.positive?
          end
          take = [take, 1].max
          chunk = styled_chars.shift(take)
          styled_chars.shift while !preserve_space && styled_chars.first&.first&.match?(/\s/)
          chunk.pop while !preserve_space && chunk.last&.first&.match?(/\s/)
          output << [gutter, *prefix, *segments_from_chars(chunk)]
          first = false
        end
        output
      end

      def segments_from_chars(chars)
        chars.each_with_object([]) do |(char, style), segments|
          if segments.last && segments.last[1] == style
            segments.last[0] << char
          else
            segments << [char.dup, style]
          end
        end
      end

      def available_width(width, gutter, prefix)
        return 1_000_000 unless width

        used = segment_width(gutter) + Array(prefix).sum { |segment| segment_width(segment) }
        [width.to_i - used, 1].max
      end

      def segment_width(segment)
        segment.is_a?(Array) ? segment.fetch(0, "").to_s.length : segment.to_s.length
      end

      def clipped_prefixed_line(gutter, segments, width)
        remaining = width ? [width.to_i - segment_width(gutter), 0].max : nil
        clipped = Array(segments).filter_map do |text, style|
          break if remaining == 0

          value = remaining ? text.to_s.chars.take(remaining).join : text.to_s
          remaining -= value.length if remaining
          [value, style] unless value.empty?
        end
        [gutter, *clipped]
      end

      def append_blank_line(rendered, gutter)
        return if rendered.empty? || blank_rendered_line?(rendered.last)

        rendered << [gutter]
      end

      def blank_rendered_line?(line)
        Array(line).drop(1).all? { |segment| segment_width(segment).zero? }
      end
    end
  end
end
