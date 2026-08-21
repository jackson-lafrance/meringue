# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Meringue
  class Config
    DEFAULT_PATH = File.expand_path(ENV.fetch("MERINGUE_CONFIG", "~/.meringue/config.toml"))
    DEFAULT_CONFLICT_PREDECESSOR_FAILURE = "cancel"
    CONFLICT_PREDECESSOR_FAILURES = %w[cancel run].freeze
    # First-run setup marker. It lives in the config file rather than in
    # `state.json` because `meringue reset-state` and `/clear` legitimately wipe
    # state, and re-running setup after every state reset would be a nag. The
    # version leaves room to replay setup for a future revision of the flow
    # without inventing a second key.
    ONBOARDING_SECTION = "onboarding"
    ONBOARDING_VERSION = 1
    ONBOARDING_OUTCOMES = %w[completed skipped].freeze
    DEFAULT_WORKER_PROVISIONING_CONCURRENCY = 2
    MAX_WORKER_PROVISIONING_CONCURRENCY = 8

    class ParseError < StandardError; end

    attr_reader :path, :data, :loaded, :file_data, :overrides, :override_sources

    def self.load(path: DEFAULT_PATH)
      expanded_path = File.expand_path(path.to_s)
      return new({}, path: expanded_path, loaded: false, file_data: {}) unless File.file?(expanded_path)

      parsed = parse(File.read(expanded_path), path: expanded_path)
      new(parsed, path: expanded_path, loaded: true, file_data: parsed)
    end

    def self.parse(source, path: nil)
      parser = TomlParser.new(source.to_s, path: path)
      parser.parse
    end

    def self.save_tui_theme!(theme, path: DEFAULT_PATH)
      expanded_path = File.expand_path(path.to_s)
      store = Store.new(path: expanded_path)
      store.save(
        base_fingerprint: store.fingerprint,
        changes: { "appearance.theme" => theme.to_s }
      ).fetch("config")
    end

    # Persists the model and reasoning defaults future sessions spawn with, through the same schema
    # transaction Settings uses. They are harness-neutral: they follow whichever backend is
    # selected instead of being tied to one. Shared commands patch both role rows; role
    # serialization then writes one compatibility fallback plus only differing overrides.
    #
    # `provider` is accepted so a caller can say which backend it was looking at, but it does not
    # change where the values are written. Shared values use the canonical shared model/thinking
    # keys; role-specific values are available only when the split-agent-defaults experiment is enabled.
    def self.save_agent_session_defaults!(model: nil, model_role: nil, thinking_level: nil, thinking_role: nil, provider: nil, path: DEFAULT_PATH, split_agent_defaults: nil)
      _ = provider
      expanded_path = File.expand_path(path.to_s)
      current = load(path: expanded_path)
      split_defaults = split_agent_defaults.nil? ? current.experiment_enabled?("split_agent_defaults") : split_agent_defaults == true
      changes = {}
      if split_agent_defaults == true && !current.path_present?("experiments", "split_agent_defaults")
        changes["experiments.split_agent_defaults"] = true
      end
      unless model.nil?
        role = model_role.to_s.strip.downcase
        raise ArgumentError, "model_role must be head or worker" unless role.empty? || %w[head worker].include?(role)
        if split_defaults
          targets = role.empty? ? %w[head worker] : [role]
          targets.each { |target| changes["agent.#{target}_model"] = model.to_s }
        else
          raise ArgumentError, "model_role is unavailable while split head and worker defaults are disabled" unless role.empty?
          changes["agent.model"] = model.to_s
        end
      end
      unless thinking_level.nil?
        role = thinking_role.to_s.strip.downcase
        raise ArgumentError, "thinking_role must be head or worker" unless role.empty? || %w[head worker].include?(role)
        if split_defaults
          targets = role.empty? ? %w[head worker] : [role]
          targets.each { |target| changes["agent.#{target}_thinking"] = thinking_level.to_s }
        else
          raise ArgumentError, "thinking_role is unavailable while split head and worker defaults are disabled" unless role.empty?
          changes["agent.thinking"] = thinking_level.to_s
        end
      end
      store = Store.new(path: expanded_path)
      store.save(base_fingerprint: store.fingerprint, changes: changes).fetch("config")
    end

    # Records that the user has been through (or dismissed) first-run setup, so
    # the flow opens once instead of on every launch. Written by the kernel's
    # CompleteOnboarding command, never by the TUI.
    def self.save_onboarding!(outcome:, version: ONBOARDING_VERSION, completed_at: nil, path: DEFAULT_PATH)
      expanded_path = File.expand_path(path.to_s)
      store = Store.new(path: expanded_path)
      store.patch_paths(
        patches: {
          "onboarding.completed_version" => version.to_i,
          "onboarding.completed_at" => (completed_at || Time.now.utc.iso8601).to_s,
          "onboarding.outcome" => outcome.to_s
        }
      )
    end

    def self.save_harness_defaults!(head_provider:, worker_provider:, path: DEFAULT_PATH)
      expanded_path = File.expand_path(path.to_s)
      store = Store.new(path: expanded_path)
      store.save(
        base_fingerprint: store.fingerprint,
        changes: {
          "agent.head_harness" => head_provider,
          "agent.worker_harness" => worker_provider
        }
      ).fetch("config")
    end

    # Runs before State::Store can create a new empty state file. An explicit
    # experiment value always wins. Existing installations retain GitHub support;
    # genuinely new installations record the opt-in default (off).
    def self.migrate_settings!(path: DEFAULT_PATH, state_path: nil)
      expanded_path = File.expand_path(path.to_s)
      config = load(path: expanded_path)
      return config if config.value("settings", "schema_version").to_i >= Schema::VERSION

      explicit_github = config.value("experiments", "github_support")
      legacy_install = config.onboarding_version.positive? || preexisting_state?(state_path)
      github_support = explicit_github == true || (explicit_github.nil? && legacy_install)
      store = Store.new(path: expanded_path)
      store.patch_paths(
        base_fingerprint: store.fingerprint,
        patches: {
          "settings.schema_version" => Schema::VERSION,
          "experiments.github_support" => github_support
        }
      )
    end

    def self.preexisting_state?(state_path)
      return false if state_path.nil? || state_path.to_s.strip.empty?
      return false unless File.file?(File.expand_path(state_path.to_s))

      state = JSON.parse(File.read(File.expand_path(state_path.to_s)))
      return true if Array(state["issues"]).any? do |issue|
        issue.is_a?(Hash) && %w[delivery_pull_request delivery_pull_requests reported_pr_urls candidate_pr_urls].any? do |key|
          value = issue[key]
          value.is_a?(Array) ? !value.empty? : !value.nil?
        end
      end

      true
    rescue JSON::ParserError, SystemCallError
      true
    end

    def self.write_toml(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      temp_path = "#{path}.tmp.#{$$}"
      File.write(temp_path, TomlWriter.new(data).to_s)
      File.rename(temp_path, path)
    ensure
      File.delete(temp_path) if temp_path && File.exist?(temp_path)
    end

    def initialize(data, path:, loaded: false, file_data: nil, overrides: nil, override_sources: nil)
      @data = deep_stringify(data || {})
      @file_data = deep_stringify(file_data.nil? ? data || {} : file_data)
      @overrides = deep_stringify(overrides || {})
      @override_sources = deep_stringify(override_sources || {})
      @path = File.expand_path(path.to_s)
      @loaded = loaded
    end

    def loaded?
      !!loaded
    end

    def section(*keys)
      keys.reduce(data) do |current, key|
        return {} unless current.is_a?(Hash)

        current.fetch(key.to_s, {})
      end
    end

    def value(*keys)
      keys.reduce(data) do |current, key|
        return nil unless current.is_a?(Hash)

        current.fetch(key.to_s, nil)
      end
    end

    def path_present?(*keys)
      sentinel = Object.new
      value = keys.reduce(data) do |current, key|
        return false unless current.is_a?(Hash) && current.key?(key.to_s)

        current.fetch(key.to_s, sentinel)
      end
      !value.equal?(sentinel)
    end

    def override_source_for(*keys)
      override_sources[keys.map(&:to_s).join(".")]
    end

    def with_overrides(new_overrides = nil, source: "runtime", **keyword_overrides)
      supplied = new_overrides.nil? ? keyword_overrides : new_overrides
      normalized = deep_stringify(supplied || {})
      sources = override_sources.dup
      each_leaf_path(normalized) { |parts, _value| sources[parts.join(".")] = source.to_s }
      merged_overrides = deep_merge(overrides, normalized)
      self.class.new(
        deep_merge(file_data, merged_overrides),
        path: path,
        loaded: loaded?,
        file_data: file_data,
        overrides: merged_overrides,
        override_sources: sources
      )
    end

    def reload_file
      loaded_config = self.class.load(path: path)
      return loaded_config if overrides.empty?

      self.class.new(
        deep_merge(loaded_config.to_file_h, overrides),
        path: path,
        loaded: loaded_config.loaded?,
        file_data: loaded_config.to_file_h,
        overrides: overrides,
        override_sources: override_sources
      )
    end

    def setting(id, env: ENV)
      Schema.fetch(id).effective_value(self, env: env)
    end

    def setting_source(id, env: ENV)
      Schema.fetch(id).source(self, env: env)
    end

    def experiment_enabled?(id, legacy: nil)
      definition = Meringue::Experiments::Registry.fetch(id)
      explicit = value(*definition.config_path)
      return explicit if explicit == true || explicit == false
      return legacy unless legacy.nil?

      definition.default
    end

    # A dependent worker normally cancels when its predecessor fails. `run` is
    # useful for independent follow-on work and is the only conflict policy
    # currently supported by the config file.
    def conflict_predecessor_failure
      configured = value("conflicts", "predecessor_failure").to_s.strip.downcase.tr("-", "_")
      return DEFAULT_CONFLICT_PREDECESSOR_FAILURE unless CONFLICT_PREDECESSOR_FAILURES.include?(configured)

      configured
    end

    # Workspace allocation is expensive external I/O and independent worker reservations may run
    # concurrently, but an unbounded fan-out can overwhelm Git and disk bandwidth. Invalid values
    # retain the conservative default; very large values are capped at the documented safety bound.
    def worker_provisioning_concurrency
      configured = value("workspace", "worker_provisioning_concurrency")
      parsed = Integer(configured, exception: false)
      return DEFAULT_WORKER_PROVISIONING_CONCURRENCY unless parsed&.positive?

      [parsed, MAX_WORKER_PROVISIONING_CONCURRENCY].min
    end

    # Which revision of the first-run flow this user finished, or 0 when setup
    # has never run. A hand-deleted `[onboarding]` section replays setup.
    def onboarding_version
      value(ONBOARDING_SECTION, "completed_version").to_i
    end

    def onboarding_outcome
      value(ONBOARDING_SECTION, "outcome").to_s
    end

    def to_h
      deep_copy(data)
    end

    def to_file_h
      deep_copy(file_data)
    end

    def fingerprint
      Store.fingerprint(path)
    end

    def each_leaf_path(value = data, prefix = [], &block)
      value.each do |key, child|
        path_parts = prefix + [key.to_s]
        if child.is_a?(Hash)
          each_leaf_path(child, path_parts, &block)
        else
          yield(path_parts, child)
        end
      end
    end

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

    def self.deep_merge(left, right)
      left = deep_stringify(left || {})
      right = deep_stringify(right || {})

      left.merge(right) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    def self.deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def deep_stringify(value)
      self.class.deep_stringify(value)
    end

    def deep_merge(left, right)
      self.class.deep_merge(left, right)
    end

    def deep_copy(value)
      self.class.deep_copy(value)
    end

    class TomlWriter
      def initialize(data)
        @data = Config.deep_stringify(data || {})
      end

      def to_s
        lines = []
        emit_table(data, [], lines)
        lines << "" unless lines.empty? || lines.last == ""
        lines.join("\n")
      end

      private

      attr_reader :data

      def emit_table(table, path, lines)
        scalars, children = table.partition { |_key, value| !value.is_a?(Hash) }
        unless path.empty?
          lines << "" unless lines.empty?
          lines << "[#{path.join(".")}]"
        end
        scalars.each do |key, value|
          next if value.nil?

          lines << "#{key} = #{format_value(value)}"
        end
        children.each do |key, child|
          emit_table(child, path + [key], lines)
        end
      end

      def format_value(value)
        case value
        when String
          JSON.generate(value)
        when TrueClass, FalseClass
          value ? "true" : "false"
        when Integer
          value.to_s
        when Array
          "[#{value.map { |child| format_value(child) }.join(", ")}]"
        else
          JSON.generate(value.to_s)
        end
      end
    end

    class TomlParser
      def initialize(source, path: nil)
        @source = source
        @path = path
        @root = {}
        @section_path = []
      end

      def parse
        source.each_line.with_index(1) do |line, line_number|
          parse_line(line, line_number)
        end
        root
      end

      private

      attr_reader :source, :path, :root

      def parse_line(line, line_number)
        stripped = strip_comment(line).strip
        return if stripped.empty?

        if stripped.start_with?("[")
          parse_section(stripped, line_number)
        else
          parse_assignment(stripped, line_number)
        end
      end

      def parse_section(text, line_number)
        unless text.end_with?("]") && text.count("[") == 1 && text.count("]") == 1
          raise parse_error(line_number, "invalid section header")
        end

        section = text[1...-1].strip
        raise parse_error(line_number, "empty section header") if section.empty?

        @section_path = section.split(".").map(&:strip)
        raise parse_error(line_number, "invalid section header") if @section_path.any?(&:empty?)

        ensure_section(@section_path, line_number)
      end

      def parse_assignment(text, line_number)
        key, raw_value = split_assignment(text)
        raise parse_error(line_number, "expected key = value") unless key && raw_value

        key_path = key.split(".").map(&:strip)
        raise parse_error(line_number, "invalid key") if key_path.any?(&:empty?)

        target_path = @section_path + key_path[0...-1]
        target = ensure_section(target_path, line_number)
        leaf_key = key_path.last
        target[leaf_key] = parse_value(raw_value.strip, line_number)
      end

      def split_assignment(text)
        in_string = false
        quote = nil
        escaped = false

        text.chars.each_with_index do |char, index|
          if in_string
            if escaped
              escaped = false
            elsif char == "\\" && quote == '"'
              escaped = true
            elsif char == quote
              in_string = false
              quote = nil
            end
            next
          end

          case char
          when '"', "'"
            in_string = true
            quote = char
          when "="
            return [text[0...index].strip, text[(index + 1)..].strip]
          end
        end

        nil
      end

      def parse_value(value, line_number)
        case value
        when /\A".*"\z/m
          parse_double_quoted_string(value, line_number)
        when /\A'.*'\z/m
          value[1...-1]
        when /\A\[(.*)\]\z/m
          parse_array(Regexp.last_match(1), line_number)
        when "true"
          true
        when "false"
          false
        when /\A-?\d+\z/
          value.to_i
        else
          raise parse_error(line_number, "unsupported value #{value.inspect}")
        end
      end

      def parse_double_quoted_string(value, line_number)
        JSON.parse(value)
      rescue JSON::ParserError => e
        raise parse_error(line_number, "invalid string: #{e.message}")
      end

      def parse_array(value, line_number)
        items = split_array_items(value)
        items.map { |item| parse_value(item, line_number) }
      end

      def split_array_items(value)
        items = []
        current = +""
        in_string = false
        quote = nil
        escaped = false

        value.chars.each do |char|
          if in_string
            current << char
            if escaped
              escaped = false
            elsif char == "\\" && quote == '"'
              escaped = true
            elsif char == quote
              in_string = false
              quote = nil
            end
            next
          end

          case char
          when '"', "'"
            in_string = true
            quote = char
            current << char
          when ","
            items << current.strip unless current.strip.empty?
            current = +""
          else
            current << char
          end
        end

        items << current.strip unless current.strip.empty?
        items
      end

      def strip_comment(line)
        in_string = false
        quote = nil
        escaped = false

        line.chars.each_with_index do |char, index|
          if in_string
            if escaped
              escaped = false
            elsif char == "\\" && quote == '"'
              escaped = true
            elsif char == quote
              in_string = false
              quote = nil
            end
            next
          end

          case char
          when '"', "'"
            in_string = true
            quote = char
          when "#"
            return line[0...index]
          end
        end

        line
      end

      def ensure_section(path_parts, line_number)
        path_parts.reduce(root) do |current, part|
          existing = current[part]
          if existing && !existing.is_a?(Hash)
            raise parse_error(line_number, "#{part.inspect} is already set to a non-table value")
          end

          current[part] ||= {}
        end
      end

      def parse_error(line_number, message)
        location = path ? "#{path}:#{line_number}" : "line #{line_number}"
        ParseError.new("#{location}: #{message}")
      end
    end
  end
end

require_relative "config/schema"
require_relative "config/store"
