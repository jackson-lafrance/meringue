# frozen_string_literal: true

require "base64"

module Meringue
  module TUI
    # System clipboard access for native dashboard selection.
    #
    # Copy prefers a local clipboard command (pbcopy on macOS, wl-copy/xclip/xsel
    # on Linux) and falls back to the OSC 52 terminal escape so remote/ssh
    # sessions can still reach the user's clipboard.
    module Clipboard
      COPY_COMMANDS = [
        ["pbcopy"],
        ["wl-copy"],
        ["xclip", "-selection", "clipboard"],
        ["xsel", "--clipboard", "--input"]
      ].freeze

      PASTE_COMMANDS = [
        ["pbpaste"],
        ["wl-paste", "--no-newline"],
        ["xclip", "-selection", "clipboard", "-o"],
        ["xsel", "--clipboard", "--output"]
      ].freeze

      OSC52_LIMIT = 100_000

      module_function

      # Returns the transport used ("command", "osc52") or nil when the text
      # could not be placed on the clipboard.
      def copy(text, output: nil)
        payload = text.to_s
        return nil if payload.empty?
        return "command" if copy_with_command(payload)
        return "osc52" if copy_with_osc52(payload, output)

        nil
      end

      def paste
        PASTE_COMMANDS.each do |command|
          next unless available?(command.first)

          text = read_command(command)
          return text unless text.nil?
        end
        nil
      end

      def copy_with_command(payload)
        COPY_COMMANDS.each do |command|
          next unless available?(command.first)
          return true if write_command(command, payload)
        end
        false
      end

      def copy_with_osc52(payload, output)
        return false unless output.respond_to?(:write)
        return false if payload.bytesize > OSC52_LIMIT

        output.write(osc52_sequence(payload))
        output.flush if output.respond_to?(:flush)
        true
      rescue StandardError
        false
      end

      def osc52_sequence(payload)
        "\e]52;c;#{Base64.strict_encode64(payload)}\a"
      end

      def write_command(command, payload)
        IO.popen(command, "w") { |io| io.write(payload) }
        status = $?
        status.nil? || status.success?
      rescue StandardError
        false
      end

      def read_command(command)
        text = IO.popen(command, "r", &:read)
        status = $?
        return nil unless status.nil? || status.success?

        text
      rescue StandardError
        nil
      end

      # Resolve executables from PATH directly so copying never pays the cost of
      # spawning a shell helper such as `which`.
      def available?(name)
        @available ||= {}
        return @available[name] if @available.key?(name)

        @available[name] = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
          next false if directory.to_s.empty?

          path = File.join(directory, name)
          File.file?(path) && File.executable?(path)
        end
      end

      def reset_command_cache!
        @available = {}
      end
    end
  end
end
