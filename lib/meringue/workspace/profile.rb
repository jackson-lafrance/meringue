# frozen_string_literal: true

require "fileutils"

module Meringue
  module Workspace
    # A project-declared workspace provisioning profile.
    #
    # Meringue's default provisioning materializes the full tree per worker. For
    # large monorepos that is minutes of avoidable checkout time plus slower
    # downstream git operations. A project may instead declare a sparse
    # provisioning profile so Meringue checks out only the working set the
    # project's own tooling expects, using repository-approved patterns rather
    # than model-inferred path narrowing.
    #
    # The profile is generic and project-configured: Meringue never hard-codes a
    # specific project's sparse set, path layout, or validation command. A
    # project without a declared profile gets the current full-checkout behavior
    # unchanged.
    #
    # The profile file lives at the project root as
    # `.meringue/workspace-profile.toml` and is parsed with Meringue's existing
    # TOML parser (no new dependencies). Schema:
    #
    #   default_profile = "core"
    #
    #   [profiles.core]
    #   sparse_cone = true
    #   sparse_patterns = ["/src/", "/docs/"]
    #   path_template = "{{root}}/{{project}}/{{task}}"
    #   validation_command = ["bin/validate-checkout"]
    #
    # A single-profile file may use the flat `[profile]` table instead of the
    # `[profiles.<name>]` map. `path_template` and `validation_command` are
    # optional; `sparse_patterns` enables sparse provisioning when non-empty.
    class Profile
      PROFILE_FILE_RELATIVE_PATH = ".meringue/workspace-profile.toml"
      DEFAULT_PATH_TEMPLATE = "{{root}}/{{project}}/{{task}}"
      ALLOWED_PLACEHOLDERS = %w[root project task].freeze
      PLACEHOLDER_PATTERN = /\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/.freeze
      # A path template must only carry literal path characters and the allowed
      # placeholders, so a project can never redirect worktrees outside the
      # managed root or smuggle shell metacharacters into a filesystem path.
      PATH_TEMPLATE_LITERAL_PATTERN = %r{\A[-_./a-zA-Z0-9]+\z}.freeze
      MAX_PATTERN_LENGTH = 4096
      MAX_PATTERNS = 4096
      MAX_COMMAND_TOKENS = 64

      attr_reader :name, :path_template, :sparse_cone, :sparse_patterns,
                  :validation_command, :raw

      # `name` identifies the selected profile so it can be persisted on the
      # workspace record and reused on retry. `raw` keeps the declared section
      # for diagnostics without re-reading the file.
      def initialize(name:, path_template: nil, sparse_cone: nil, sparse_patterns: nil,
                     validation_command: nil, raw: {})
        @name = name.to_s
        @path_template = path_template.to_s unless path_template.nil? || path_template.to_s.empty?
        @sparse_cone = sparse_cone.nil? ? nil : !!sparse_cone
        @sparse_patterns = Array(sparse_patterns).map(&:to_s).reject(&:empty?)
        @validation_command = normalize_command(validation_command)
        @raw = raw.is_a?(Hash) ? raw : {}
      end

      def sparse?
        !sparse_patterns.empty?
      end

      def cone?
        sparse? && sparse_cone
      end

      def validation?
        !validation_command.empty?
      end

      def custom_path_template?
        !path_template.nil? && path_template != DEFAULT_PATH_TEMPLATE
      end

      # Whether the declared path template is structurally safe: it must only
      # contain literal path characters and the allowed placeholders, and no
      # `..` segment, so a project cannot redirect a worktree outside the
      # managed root or smuggle shell metacharacters into a filesystem path.
      def path_template_valid?
        return true if path_template.nil? || path_template == DEFAULT_PATH_TEMPLATE
        return false if path_template.length > MAX_PATTERN_LENGTH

        placeholders = path_template.scan(PLACEHOLDER_PATTERN).flatten
        return false unless placeholders.all? { |placeholder| ALLOWED_PLACEHOLDERS.include?(placeholder) }

        stripped = path_template.gsub(PLACEHOLDER_PATTERN, "")
        return false unless stripped.empty? || PATH_TEMPLATE_LITERAL_PATTERN.match?(stripped)

        expand_template(path_template, root: "r", project: "p", task: "t")
          .split(File::SEPARATOR).none? { |segment| segment == ".." }
      end

      # Expands the path template into an absolute workspace path. Returns nil
      # when the template is invalid or the expanded path escapes `root`, so the
      # caller falls back to the default layout and ownership/collision
      # machinery still applies.
      def expand_path(root:, project_slug:, task_slug:)
        template = path_template || DEFAULT_PATH_TEMPLATE
        return nil unless path_template_valid?

        root_path = File.expand_path(root.to_s)
        expanded_template = expand_template(
          template, root: root_path, project: project_slug.to_s, task: task_slug.to_s
        )
        expanded = File.expand_path(expanded_template)
        return nil unless expanded == root_path || expanded.start_with?("#{root_path}#{File::SEPARATOR}")

        expanded
      end

      def to_h
        {
          "name" => name,
          "path_template" => path_template,
          "sparse_cone" => sparse_cone,
          "sparse_patterns" => sparse_patterns,
          "validation_command" => validation_command.empty? ? nil : validation_command
        }.compact
      end

      # Returns a brief, log-safe summary of the profile for workspace records.
      def summary
        return "#{name} (sparse, #{cone? ? "cone" : "non-cone"}, #{sparse_patterns.length} patterns)" if sparse?

        "#{name} (full checkout)"
      end

      # Load and select a profile from a project root. Returns nil when the
      # project declares no profile file, so the caller preserves the default
      # full-checkout behavior. `profile_name` optionally selects among
      # multiple declared profiles; without it the file's `default_profile` (or
      # the first declared profile) is used.
      def self.load(project_root, profile_name: nil)
        path = profile_file_path(project_root)
        return nil unless path && File.file?(path)

        begin
          parsed = Meringue::Config.parse(File.read(path))
        rescue Meringue::Config::ParseError
          # A malformed profile file is treated as no profile: provisioning
          # must never fail because a project's optional profile file is broken.
          return nil
        end
        build_from_config(parsed.to_h, profile_name: profile_name)
      rescue StandardError
        nil
      end

      def self.profile_file_path(project_root)
        return nil if project_root.to_s.strip.empty?

        File.join(File.expand_path(project_root.to_s), PROFILE_FILE_RELATIVE_PATH)
      end

      # Build a Profile from a parsed config hash. Supports both the flat
      # `[profile]` table and the `[profiles.<name>]` map with a
      # `default_profile` selector.
      def self.build_from_config(config, profile_name: nil)
        config = deep_stringify(config)
        requested = profile_name.to_s unless profile_name.nil? || profile_name.to_s.empty?

        profiles = config.fetch("profiles", nil)
        if profiles.is_a?(Hash) && !profiles.empty?
          selected_name = requested || config.fetch("default_profile", nil).to_s
          selected_name = profiles.keys.first if selected_name.empty?
          section = profiles.fetch(selected_name, nil)
          return nil unless section.is_a?(Hash)

          return from_section(section, name: selected_name)
        end

        section = config.fetch("profile", nil)
        return nil unless section.is_a?(Hash)

        from_section(section, name: requested || present_config_string(config.fetch("default_profile", nil)) || "profile")
      end

      def self.from_section(section, name:)
        section = deep_stringify(section)
        new(
          name: name.to_s,
          path_template: section.fetch("path_template", nil),
          sparse_cone: section.fetch("sparse_cone", nil),
          sparse_patterns: section.fetch("sparse_patterns", nil),
          validation_command: section.fetch("validation_command", nil),
          raw: section
        )
      end

      # ---- private class helpers -------------------------------------------

      def self.deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[key.to_s] = deep_stringify(child) }
        when Array
          value.map { |child| deep_stringify(child) }
        else
          value
        end
      end
      private_class_method :deep_stringify

      def self.present_config_string(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
      private_class_method :present_config_string

      # ---- private instance helpers ----------------------------------------

      def expand_template(template, root:, project:, task:)
        values = { "root" => root.to_s, "project" => project.to_s, "task" => task.to_s }
        template.gsub(PLACEHOLDER_PATTERN) do |match|
          key = Regexp.last_match(1)
          if ALLOWED_PLACEHOLDERS.include?(key)
            values.fetch(key)
          else
            match
          end
        end
      end

      def normalize_command(command)
        tokens = Array(command).map(&:to_s).map(&:strip).reject(&:empty?)
        return [] if tokens.empty?
        return [] if tokens.length > MAX_COMMAND_TOKENS

        tokens
      end

      def present_string(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
