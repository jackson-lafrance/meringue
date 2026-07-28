# frozen_string_literal: true

module Meringue
  module TUI
    # Shared styling for the bottom hint lines.
    #
    # Both the dashboard and the focused workspace describe their keys the same
    # way: an optional leader, then key/label pairs separated by a dim divider.
    # Keeping it in one place is what makes the two bars read as one product
    # instead of two independently styled lines.
    module HintLine
      SEPARATOR = " · "

      module_function

      # entries: [[key, label], ...]. A nil or empty label renders the key alone.
      def segments(entries, leader: nil, leader_style: Style::ACCENT_BOLD, leader_suffix: "  ", separator: SEPARATOR)
        output = []
        unless leader.to_s.empty?
          output << [leader.to_s, leader_style]
          output << [leader_suffix, Style::DIM] unless leader_suffix.to_s.empty?
        end

        Array(entries).each_with_index do |entry, index|
          key, label = entry
          next if key.to_s.empty? && label.to_s.empty?

          output << [separator, Style::DIM] if index.positive?
          output << [key.to_s, Style::ACCENT] unless key.to_s.empty?
          output << [label.to_s.start_with?(":") ? label.to_s : " #{label}", Style::MUTED] unless label.to_s.empty?
        end
        output
      end

      def width(segments)
        Array(segments).sum { |text, _style| text.to_s.length }
      end
    end
  end
end
