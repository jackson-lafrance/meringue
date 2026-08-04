# frozen_string_literal: true

module Meringue
  # Chooses a concise display name for a project without treating a repository
  # path as the product's canonical name. README headings are the best source
  # of truth because they retain the capitalization chosen by the project.
  module ProjectNaming
    README_FILENAMES = %w[README.md README.markdown README.rdoc README].freeze
    MAX_NAME_LENGTH = 80

    module_function

    def name_for(path)
      root = File.expand_path(path.to_s)
      readme_name(root) || humanize_basename(File.basename(root))
    end

    def readme_name(root)
      readme_path = README_FILENAMES.map { |filename| File.join(root, filename) }.find { |path| File.file?(path) }
      return nil unless readme_path

      heading = File.foreach(readme_path).lazy.filter_map do |line|
        match = line.match(/\A\s*#\s+(.+?)\s*#*\s*\z/)
        match && clean_heading(match[1])
      end.first
      heading unless heading.to_s.empty?
    rescue SystemCallError, ArgumentError
      nil
    end

    def humanize_basename(basename)
      text = basename.to_s.strip
      return nil if text.empty? || text == "." || text == ".."

      words = text.tr("-_", " ").split
      return nil if words.empty?

      words.map do |word|
        # Mixed-case names and all-caps initialisms are intentional. Only
        # lowercase path words receive a friendly initial capital.
        word.match?(/\A[a-z][a-z0-9]*\z/) ? word.sub(/\A[a-z]/) { |letter| letter.upcase } : word
      end.join(" ")
    end

    def clean_heading(value)
      text = value.to_s.gsub(/\[([^\]]+)\]\([^)]*\)/, '\\1').strip
      text = text.sub(/\s+(?:[-–—|:]|\.{2,})\s+.*\z/, "").strip
      return nil if text.empty? || text.length > MAX_NAME_LENGTH

      text
    end
    private_class_method :clean_heading
  end
end
