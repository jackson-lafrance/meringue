# frozen_string_literal: true

module Meringue
  # Validates and matches user-configured worker command blacklist globs.
  #
  # Matching is deliberately smaller than regular expressions: `*` matches any
  # sequence (including newlines), `?` matches one character, and every other
  # character is literal. The whole raw bash command must match. This keeps the
  # config portable to the Pi extension and avoids executable regex syntax.
  class CommandBlacklist
    MAX_PATTERNS = 100
    MAX_PATTERN_LENGTH = 512

    class ConfigurationError < ArgumentError; end

    attr_reader :patterns

    def self.from_config(config)
      new(config.value("commands", "worker_blacklist"))
    end

    def initialize(patterns)
      @patterns = validate(patterns).freeze
    end

    def empty?
      patterns.empty?
    end

    def match(command)
      patterns.find { |pattern| self.class.glob_match?(pattern, command.to_s) }
    end

    def self.glob_match?(pattern, command)
      pattern_chars = pattern.to_s.each_char.to_a
      command_chars = command.to_s.each_char.to_a
      pattern_index = 0
      command_index = 0
      star_index = nil
      star_command_index = nil

      while command_index < command_chars.length
        if pattern_index < pattern_chars.length &&
           (pattern_chars[pattern_index] == "?" || pattern_chars[pattern_index] == command_chars[command_index])
          pattern_index += 1
          command_index += 1
        elsif pattern_index < pattern_chars.length && pattern_chars[pattern_index] == "*"
          star_index = pattern_index
          star_command_index = command_index
          pattern_index += 1
        elsif star_index
          pattern_index = star_index + 1
          star_command_index += 1
          command_index = star_command_index
        else
          return false
        end
      end

      pattern_index += 1 while pattern_chars[pattern_index] == "*"
      pattern_index == pattern_chars.length
    end

    private

    def validate(value)
      return [] if value.nil?
      unless value.is_a?(Array)
        raise ConfigurationError, "commands.worker_blacklist must be an array of glob strings"
      end
      if value.length > MAX_PATTERNS
        raise ConfigurationError, "commands.worker_blacklist supports at most #{MAX_PATTERNS} patterns"
      end

      value.each_with_index.map do |pattern, index|
        unless pattern.is_a?(String)
          raise ConfigurationError, "commands.worker_blacklist[#{index}] must be a string"
        end
        if pattern.empty?
          raise ConfigurationError, "commands.worker_blacklist[#{index}] must not be empty"
        end
        if pattern.length > MAX_PATTERN_LENGTH
          raise ConfigurationError,
                "commands.worker_blacklist[#{index}] must be at most #{MAX_PATTERN_LENGTH} characters"
        end
        if pattern.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
          raise ConfigurationError, "commands.worker_blacklist[#{index}] contains a control character"
        end

        pattern.dup.freeze
      end
    end
  end
end
