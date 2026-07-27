# frozen_string_literal: true

require "shellwords"

module Meringue
  module Workspace
    # Parses user-configured commands into argv without ever invoking a shell.
    # Arrays are preferred, while strings use ordinary shell-style quoting only
    # to split arguments (pipes, redirects, substitutions, and globs are not
    # evaluated).
    class LaunchCommand
      attr_reader :argv, :source

      def self.parse(value, default:, label: "command")
        source = value.nil? ? default : value
        argv = case source
               when Array
                 unless source.all? { |part| part.is_a?(String) }
                   raise ArgumentError, "#{label} must be a string or an array of strings"
                 end

                 source.dup
               when String
                 Shellwords.split(source)
               else
                 raise ArgumentError, "#{label} must be a string or an array of strings"
               end

        argv = argv.map(&:to_s)
        raise ArgumentError, "#{label} cannot be empty" if argv.empty? || argv.first.to_s.empty?
        raise ArgumentError, "#{label} cannot contain empty arguments" if argv.any?(&:empty?)
        raise ArgumentError, "#{label} cannot contain null bytes" if argv.any? { |part| part.include?("\0") }

        new(argv, source: source)
      rescue ArgumentError => e
        raise e if e.message.start_with?(label)

        raise ArgumentError, "invalid #{label}: #{e.message}"
      end

      def initialize(argv, source: nil)
        @argv = Array(argv).map(&:to_s).freeze
        @source = source
      end

      def executable
        argv.first
      end

      def with_arguments(arguments)
        values = Array(arguments)
        unless values.all? { |argument| argument.is_a?(String) }
          raise ArgumentError, "command arguments must be strings"
        end
        raise ArgumentError, "command arguments cannot contain null bytes" if values.any? { |argument| argument.include?("\0") }

        self.class.new(argv + values, source: source)
      end

      def executable_path(cwd: Dir.pwd, path: ENV.fetch("PATH", ""))
        name = executable.to_s
        return nil if name.empty?

        if name.include?(File::SEPARATOR)
          candidate = File.expand_path(name, cwd.to_s)
          return candidate if File.file?(candidate) && File.executable?(candidate)

          return nil
        end

        path.to_s.split(File::PATH_SEPARATOR).each do |directory|
          directory = "." if directory.empty?
          candidate = File.expand_path(File.join(directory, name), cwd.to_s)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def display
        Shellwords.join(argv)
      end
    end
  end
end
