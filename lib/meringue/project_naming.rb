# frozen_string_literal: true

module Meringue
  # Chooses a concise display name for a project without treating a repository
  # path as the product's canonical name. README headings are the best source
  # of truth because they retain the capitalization chosen by the project.
  module ProjectNaming
    README_FILENAMES = %w[README.md README.markdown README.rdoc README].freeze
    MAX_NAME_LENGTH = 80
    # Lifecycle statuses (see AGENTS.md "Statuses") describe what Meringue is
    # doing to a project. They are never part of what the project is called, so
    # "Meringue working" is always the name "Meringue" plus a rendered status
    # that leaked into the name.
    STATUS_SUFFIXES = %w[queued working idle blocked paused completed errored killed supervision_lost].freeze
    # These words describe a task, lifecycle state, or repository facet rather
    # than the product itself. They must not become part of a derived project
    # label.
    NON_PRODUCT_SUFFIXES = (%w[
      add change clean cleanup complete done fix fixed improve implement
      integration storefront update updated work
    ] + STATUS_SUFFIXES).uniq.freeze
    # Punctuation that only ever joined a name to something else. Once the
    # trailing fragment is gone the separator has nothing left to join.
    SEPARATOR_PATTERN = /\A[-–—·•|:;,\/\\]+\z/.freeze

    module_function

    def name_for(path)
      root = File.expand_path(path.to_s)
      canonical_name(readme_name(root) || humanize_basename(File.basename(root)))
    end

    # The nearest enclosing checkout, or nil outside one. Heads use this to decide
    # what "this repo" means, and first-run setup uses it to offer the repository
    # Meringue was started in; they must agree on the answer.
    def git_root_for(path)
      current = File.expand_path(path.to_s)

      loop do
        return current if File.exist?(File.join(current, ".git"))

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    # Full cleanup for a name Meringue derived itself (README heading, path
    # basename). Safe to be aggressive here because nobody typed this name.
    def canonical_name(value)
      trim_trailing_words(value, NON_PRODUCT_SUFFIXES)
    end

    # Minimal cleanup for a name that a human or a head supplied and that the
    # kernel is about to store. Only a lifecycle status is removed, because a
    # status is never a product name, while "Payments Integration" is.
    def without_status_suffix(value)
      trim_trailing_words(value, STATUS_SUFFIXES)
    end

    # True when a stored/proposed name carries a rendered lifecycle status,
    # which is the shape of the "Meringue working" regression.
    def status_suffix?(value)
      normalized = normalize_whitespace(value)
      return false if normalized.empty?

      without_status_suffix(normalized) != normalized
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

    # Pops trailing throwaway words (and the punctuation that attached them)
    # while always keeping at least one word, so a project genuinely called
    # "Working" survives.
    def trim_trailing_words(value, words_to_drop)
      text = normalize_whitespace(value)
      return nil if text.empty?

      words = text.split(" ")
      words.pop while words.length > 1 && droppable_word?(words.last, words_to_drop)
      words.join(" ")
    end
    private_class_method :trim_trailing_words

    def droppable_word?(word, words_to_drop)
      text = word.to_s
      return true if text.match?(SEPARATOR_PATTERN)

      bare = text.gsub(/\A[\(\[\{"'“‘]+/, "").gsub(/[\)\]\}"'”’.,;:!?]+\z/, "").downcase
      return false if bare.empty?

      words_to_drop.include?(bare)
    end
    private_class_method :droppable_word?

    def normalize_whitespace(value)
      value.to_s.gsub(/[[:space:]]+/, " ").strip
    end
    private_class_method :normalize_whitespace

    def clean_heading(value)
      text = value.to_s.gsub(/\[([^\]]+)\]\([^)]*\)/, '\\1').strip
      text = text.sub(/\s+(?:[-–—|:]|\.{2,})\s+.*\z/, "").strip
      return nil if text.empty? || text.length > MAX_NAME_LENGTH

      text
    end
    private_class_method :clean_heading
  end
end
