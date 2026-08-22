# frozen_string_literal: true

module Meringue
  module TUI
    # Normalizes harness-owned assistant text for the compact logs presentation.
    # The original text remains available in durable log details and agent
    # metadata; this module only changes what the TUI displays.
    module AgentOutput
      ANSI_OSC_PATTERN = /\e\].*?(?:\a|\e\\)/m
      ANSI_CSI_PATTERN = /\e\[[0-?]*[ -\/]*[@-~]/
      ANSI_ESCAPE_PATTERN = /\e[@-_]/
      BOX_HORIZONTAL_CHARS = "─━═"
      BOX_VERTICAL_CHARS = "│┃║"
      BOX_TOP_LEFT = "╭┌┏╔"
      BOX_TOP_RIGHT = "╮┐┓╗"
      BOX_BOTTOM_LEFT = "╰└┗╚"
      BOX_BOTTOM_RIGHT = "╯┘┛╝"

      module_function

      def normalize(text, source_id: nil, pr_urls: [])
        output = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        output = strip_terminal_sequences(output)
        output = output.gsub("\r\n", "\n").tr("\r", "\n").tr("\u00a0", " ")
        output = output.gsub("\t", "  ").gsub(/[^\P{C}\n]/u, "")

        Array(pr_urls).compact.each do |url|
          value = url.to_s
          output = output.gsub(value, "") unless value.empty?
        end

        lines = output.lines(chomp: true).map(&:rstrip)
        lines = remove_transcript_labels(lines, source_id)
        boxed_layout = lines.count { |line| box_border_line?(line) } >= 2
        lines = unwrap_outer_box(lines)
        lines.reject! { |line| box_border_line?(line) }
        lines = dedent(lines)
        lines = reflow_box_text(lines) if boxed_layout
        lines = remove_transcript_labels(lines, source_id)
        lines.reject! { |line| line.strip.match?(/\APR:\s*\z/i) }
        collapse_blank_lines(trim_blank_lines(lines)).join("\n").rstrip
      rescue ArgumentError
        text.to_s.rstrip
      end

      def strip_terminal_sequences(text)
        text.gsub(ANSI_OSC_PATTERN, "")
            .gsub(ANSI_CSI_PATTERN, "")
            .gsub(ANSI_ESCAPE_PATTERN, "")
      end

      def unwrap_outer_box(lines)
        result = trim_blank_lines(lines)
        2.times do
          result = trim_blank_lines(result.drop_while { |line| box_border_line?(line) })
          result = trim_blank_lines(result.reverse.drop_while { |line| box_border_line?(line) }.reverse)

          content = result.reject { |line| line.strip.empty? }
          break if content.empty?

          leading_border = content.count { |line| line.lstrip.start_with?(*BOX_VERTICAL_CHARS.chars) }
          trailing_border = content.count { |line| line.rstrip.end_with?(*BOX_VERTICAL_CHARS.chars) }
          threshold = [(content.length * 0.75).ceil, 1].max
          break if leading_border < threshold && trailing_border < threshold

          result = result.map do |line|
            unwrapped = line.dup
            unwrapped = unwrapped.sub(/\A\s*[#{Regexp.escape(BOX_VERTICAL_CHARS)}]\s?/, "") if leading_border >= threshold
            unwrapped = unwrapped.sub(/\s?[#{Regexp.escape(BOX_VERTICAL_CHARS)}]\s*\z/, "") if trailing_border >= threshold
            unwrapped.rstrip
          end
        end
        trim_blank_lines(result)
      end

      def box_border_line?(line)
        value = line.to_s.strip
        return false if value.empty?
        return true if value.match?(/\A[#{Regexp.escape(BOX_HORIZONTAL_CHARS + BOX_VERTICAL_CHARS)}\s]+\z/)

        top = BOX_TOP_LEFT.include?(value[0].to_s) && BOX_TOP_RIGHT.include?(value[-1].to_s)
        bottom = BOX_BOTTOM_LEFT.include?(value[0].to_s) && BOX_BOTTOM_RIGHT.include?(value[-1].to_s)
        return false unless top || bottom

        interior = value[1...-1].to_s
        decoration_count = interior.count(BOX_HORIZONTAL_CHARS + " ")
        decoration_count >= (interior.length * 0.4)
      end

      def remove_transcript_labels(lines, source_id)
        result = trim_blank_lines(lines)
        id = source_id.to_s.strip
        escaped_id = Regexp.escape(id)
        id_label = id.empty? ? nil : /\A(?:agent|worker)?\s*#{escaped_id}\s*(?:output|result|update)?\s*:\s*\z/i
        rendered_header = id.empty? ? nil : /\A\[?\d{1,2}:\d{2}(?::\d{2})?\]?\s*[✦◆✓!]\s*(?:agent|worker|head)?\s*#{escaped_id}(?:\s*[—·-].*)?\z/i

        result = result.drop_while do |line|
          stripped = line.strip
          stripped.empty? || (id_label && stripped.match?(id_label)) || (rendered_header && stripped.match?(rendered_header))
        end
        trim_blank_lines(result)
      end

      def dedent(lines)
        content = lines.reject { |line| line.strip.empty? }
        indentation = content.map { |line| line[/\A */].to_s.length }.min.to_i
        return lines unless indentation.positive?

        lines.map { |line| line.sub(/\A {0,#{indentation}}/, "") }
      end

      def reflow_box_text(lines)
        in_fence = false
        lines.each_with_object([]) do |line, result|
          fence = line.to_s.lstrip.match?(/\A(?:```|~~~)/)
          previous = result.last
          if !in_fence && !fence && previous && prose_continuation?(previous, line)
            result[-1] = "#{previous.rstrip} #{line.strip}"
          else
            result << line
          end
          in_fence = !in_fence if fence
        end
      end

      def prose_continuation?(previous, current)
        return false if previous.strip.empty? || current.strip.empty?
        return false if previous.rstrip.match?(/[.!?:;]\z/)
        return false if markdown_structure?(previous) || markdown_structure?(current)
        return false if current.match?(/\A\s{2,}/)

        true
      end

      def markdown_structure?(line)
        line.to_s.lstrip.match?(/\A(?:```|~~~|\#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s|\|)/)
      end

      def collapse_blank_lines(lines)
        in_fence = false
        blank_count = 0
        Array(lines).each_with_object([]) do |line, result|
          fence = line.to_s.lstrip.match?(/\A(?:```|~~~)/)
          if in_fence
            result << line
          elsif line.to_s.strip.empty?
            result << line if blank_count.zero?
            blank_count += 1
          else
            result << line
            blank_count = 0
          end
          in_fence = !in_fence if fence
        end
      end

      def trim_blank_lines(lines)
        Array(lines).drop_while { |line| line.to_s.strip.empty? }
                    .reverse
                    .drop_while { |line| line.to_s.strip.empty? }
                    .reverse
      end
    end
  end
end
