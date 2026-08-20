# frozen_string_literal: true

require "json"
require "shellwords"

module Meringue
  module Workspace
    # Command contract for isolated worktree lifecycle providers. Native Git is
    # the default provider. A user may configure a private executable that
    # adapts another local worktree manager to the generic protocol below.
    # Meringue still treats Git registration as authoritative for ownership,
    # validation, reuse, and cleanup safety.
    class WorktreeProvider
      NATIVE_GIT = "native_git"
      COMMAND = "command"
      KINDS = [NATIVE_GIT, COMMAND].freeze
      DEFAULT_KIND = NATIVE_GIT
      DEFAULT_FALLBACK = NATIVE_GIT
      FALLBACKS = [NATIVE_GIT, "none"].freeze
      MAX_COMMAND_TOKENS = 32
      MAX_IDENTIFIER_BYTES = 4096

      KIND_ALIASES = {
        "git" => NATIVE_GIT,
        "native" => NATIVE_GIT,
        "native_git" => NATIVE_GIT,
        "command" => COMMAND,
        "custom" => COMMAND,
        "external" => COMMAND
      }.freeze

      class InvalidResponse < StandardError; end

      attr_reader :kind, :command

      def self.build(kind:, command: nil)
        new(kind: normalize_kind(kind), command: command_argv(command))
      end

      def self.normalize_kind(value)
        KIND_ALIASES.fetch(value.to_s.strip.downcase.tr("-", "_"), DEFAULT_KIND)
      end

      def self.normalize_fallback(value)
        value.to_s.strip.downcase == "none" ? "none" : DEFAULT_FALLBACK
      end

      # Strings are accepted for configuration compatibility but only split
      # into argv. They are never passed to a shell.
      def self.command_argv(value)
        tokens = case value
                 when Array then value.map(&:to_s)
                 when String then Shellwords.shellsplit(value)
                 else []
                 end
        tokens = tokens.map(&:strip).reject(&:empty?)
        return [] if tokens.length > MAX_COMMAND_TOKENS

        tokens
      rescue ArgumentError
        []
      end

      def initialize(kind:, command: nil)
        @kind = self.class.normalize_kind(kind)
        @command = native? ? [] : self.class.command_argv(command).freeze
      end

      def native?
        kind == NATIVE_GIT
      end

      def command?
        kind == COMMAND
      end

      def external?
        command?
      end

      def configured?
        native? || !command.empty?
      end

      def provision_argv(name:, branch:, base_ref:, git_root:, project_root:)
        raise ArgumentError, "native Git has no provider command" if native?
        raise ArgumentError, "workspace.worktree_provider_command is empty" unless configured?

        [
          *command,
          "provision",
          "--name", name.to_s,
          "--branch", branch.to_s,
          "--base-ref", base_ref.to_s,
          "--git-root", File.expand_path(git_root.to_s),
          "--project-root", File.expand_path(project_root.to_s)
        ]
      end

      def release_argv(identifier:, worktree_path:, branch:, git_root:, project_root:)
        raise ArgumentError, "native Git has no provider command" if native?
        raise ArgumentError, "workspace.worktree_provider_command is empty" unless configured?

        [
          *command,
          "release",
          "--identifier", identifier.to_s,
          "--worktree-path", File.expand_path(worktree_path.to_s),
          "--branch", branch.to_s,
          "--git-root", File.expand_path(git_root.to_s),
          "--project-root", File.expand_path(project_root.to_s)
        ]
      end

      # Provider stdout is one JSON object; human diagnostics belong on stderr.
      # Provision may omit identifier, in which case the requested name is the
      # stable release identifier. Release must declare whether it retained the
      # registered worktree so Meringue can verify the correct postcondition.
      def parse_response(output, action:)
        parsed = JSON.parse(output.to_s)
        raise InvalidResponse, "provider response must be a JSON object" unless parsed.is_a?(Hash)

        response = parsed.transform_keys(&:to_s)
        case action.to_s
        when "provision"
          identifier = response["identifier"]
          if identifier
            identifier = identifier.to_s
            if identifier.strip.empty? || identifier.bytesize > MAX_IDENTIFIER_BYTES || identifier.include?("\0")
              raise InvalidResponse, "provider identifier must be non-blank, NUL-free, and at most #{MAX_IDENTIFIER_BYTES} bytes"
            end
            response["identifier"] = identifier
          end
        when "release"
          unless response["released"] == true && [true, false].include?(response["worktree_retained"])
            raise InvalidResponse, "release response must set released=true and a boolean worktree_retained"
          end
          if response.key?("branch_retained") && ![true, false].include?(response["branch_retained"])
            raise InvalidResponse, "branch_retained must be boolean when present"
          end
        else
          raise InvalidResponse, "unknown provider action #{action.inspect}"
        end
        response
      rescue JSON::ParserError => e
        raise InvalidResponse, "provider response is not valid JSON: #{e.message}"
      end

      def display_name
        native? ? "native Git" : "configured worktree provider"
      end

      def configuration_hint
        "configure workspace.worktree_provider_command with an executable argv prefix"
      end
    end
  end
end
