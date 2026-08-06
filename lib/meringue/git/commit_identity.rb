# frozen_string_literal: true

require "open3"

module Meringue
  module Git
    # Supplies a harness process with the repository owner's identity without ever
    # falling back to a Meringue identity. Workers still have normal git commit
    # access; this only controls the identity inherited by the worker's child
    # processes.
    class CommitIdentity
      IDENTITY_ENV_KEYS = %w[
        GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
      ].freeze
      IDENTITY_SCOPES = %w[local global system].freeze
      MERINGUE_IDENTITY_PATTERN = /meringue/i.freeze

      def self.environment(cwd:, base_environment: ENV.to_h)
        new(cwd: cwd, base_environment: base_environment).environment
      end

      def initialize(cwd:, base_environment: ENV.to_h, git_command: "git")
        @cwd = File.expand_path(cwd.to_s)
        @base_environment = base_environment.transform_keys(&:to_s).transform_values { |value| value&.to_s }
        @git_command = git_command
      end

      # Returns only environment changes. The harness merges these with the
      # provider's configured environment immediately before spawning a process.
      # An absent non-Meringue identity is deliberately a safe failure: git will
      # refuse to create a commit rather than silently attributing it to Meringue.
      def environment
        identity = configured_identity || inherited_identity
        return identity_environment(identity) if identity && !meringue_identity?(identity)

        safe_missing_identity_environment
      end

      private

      attr_reader :cwd, :base_environment, :git_command

      def configured_identity
        IDENTITY_SCOPES.each do |scope|
          identity = identity_from_scope(scope)
          return identity if identity && !meringue_identity?(identity)
        end
        nil
      end

      def identity_from_scope(scope)
        name = git_config(scope, "user.name")
        email = git_config(scope, "user.email")
        return nil if name.to_s.strip.empty? || email.to_s.strip.empty?

        { "name" => name.strip, "email" => email.strip, "source" => scope }
      end

      def inherited_identity
        name = base_environment["GIT_AUTHOR_NAME"].to_s.strip
        email = base_environment["GIT_AUTHOR_EMAIL"].to_s.strip
        return nil if name.empty? || email.empty?

        { "name" => name, "email" => email, "source" => "environment" }
      end

      def git_config(scope, key)
        stdout, _stderr, status = Open3.capture3(
          query_environment,
          git_command,
          "-C",
          cwd,
          "config",
          "--#{scope}",
          "--get",
          key
        )
        return nil unless status.success?

        stdout.to_s.strip
      rescue Errno::ENOENT, IOError, SystemCallError
        nil
      end

      # Command-scope config from the parent process must not change which
      # repository identity is discovered. Global/system config remains in play
      # because it is part of the user's normal git identity setup.
      def query_environment
        base_environment.reject do |key, _value|
          key == "GIT_CONFIG_PARAMETERS" || key.start_with?("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")
        end.merge("GIT_CONFIG_COUNT" => nil)
      end

      def identity_environment(identity)
        {
          "GIT_AUTHOR_NAME" => identity.fetch("name"),
          "GIT_AUTHOR_EMAIL" => identity.fetch("email"),
          "GIT_COMMITTER_NAME" => identity.fetch("name"),
          "GIT_COMMITTER_EMAIL" => identity.fetch("email"),
          "EMAIL" => identity.fetch("email")
        }
      end

      def safe_missing_identity_environment
        result = IDENTITY_ENV_KEYS.to_h { |key| [key, nil] }
        result["GIT_CONFIG_PARAMETERS"] = nil
        result.merge!(empty_identity_config)
        result
      end

      # A repository may already contain a stale Meringue user.* setting. Add a
      # higher-precedence empty command-scope value so git reports an unknown
      # author instead of using that setting. Preserve any command-scope values
      # the provider supplied by appending our two entries.
      def empty_identity_config
        count = Integer(base_environment.fetch("GIT_CONFIG_COUNT", "0"))
        {
          "GIT_CONFIG_COUNT" => (count + 2).to_s,
          "GIT_CONFIG_KEY_#{count}" => "user.name",
          "GIT_CONFIG_VALUE_#{count}" => "",
          "GIT_CONFIG_KEY_#{count + 1}" => "user.email",
          "GIT_CONFIG_VALUE_#{count + 1}" => ""
        }
      rescue ArgumentError, TypeError
        {
          "GIT_CONFIG_COUNT" => "2",
          "GIT_CONFIG_KEY_0" => "user.name",
          "GIT_CONFIG_VALUE_0" => "",
          "GIT_CONFIG_KEY_1" => "user.email",
          "GIT_CONFIG_VALUE_1" => ""
        }
      end

      def meringue_identity?(identity)
        [identity.fetch("name"), identity.fetch("email")].any? do |value|
          value.to_s.match?(MERINGUE_IDENTITY_PATTERN)
        end
      end
    end
  end
end
