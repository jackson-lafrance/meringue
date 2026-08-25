# frozen_string_literal: true

require "json"
require "shellwords"

module Meringue
  class Config
    class ValidationError < ArgumentError
      attr_reader :field_errors

      def initialize(field_errors)
        @field_errors = Config.deep_stringify(field_errors || {})
        super(@field_errors.map { |id, message| "#{id}: #{message}" }.join("; "))
      end
    end

    class StaleRevisionError < StandardError; end
    class LockError < StandardError; end
    class PersistenceError < StandardError; end

    class SettingDefinition
      ATTRIBUTES = %i[
        id path category type default aliases normalize validate description visibility editor
        apply_mode dependencies sensitive serialize label options advanced override_env minimum maximum
        fallback_paths optional env_overrides env_value
      ].freeze

      ATTRIBUTES.each { |attribute| attr_reader attribute }

      def initialize(**values)
        unknown = values.keys - ATTRIBUTES
        raise ArgumentError, "Unknown setting definition fields: #{unknown.join(", ")}" unless unknown.empty?

        ATTRIBUTES.each { |attribute| instance_variable_set("@#{attribute}", values[attribute]) }
        @id = id.to_s.freeze
        @path = path && Array(path).map(&:to_s).freeze
        @category = category.to_s.freeze
        @type = type.to_s.freeze
        @aliases = Array(aliases).map { |alias_path| Array(alias_path).map(&:to_s).freeze }.freeze
        @fallback_paths = Array(fallback_paths).map { |fallback_path| Array(fallback_path).map(&:to_s).freeze }.freeze
        @dependencies = Array(dependencies).map(&:to_s).freeze
        @visibility = (visibility || "normal").to_s.freeze
        @editor = (editor || type).to_s.freeze
        @apply_mode = (apply_mode || "restart").to_s.freeze
        @label = (label || id.to_s.split(".").last.tr("_", " ").split.map(&:capitalize).join(" ")).freeze
        @description = description.to_s.freeze
        @options = options
        @advanced = !!advanced
        @sensitive = !!sensitive
        @override_env = Array(override_env).map(&:to_s).freeze
        @optional = !!optional
        @env_overrides = !!env_overrides
        freeze
      end

      def default_value(config = nil, env: ENV)
        value = default.respond_to?(:call) ? default.call(config, env) : default
        Config.deep_copy(value)
      end

      def option_values(config = nil)
        values = options.respond_to?(:call) ? options.call(config) : options
        Array(values).map(&:to_s)
      end

      def effective_value(config, env: ENV)
        environment_key = override_env.find { |key| env.key?(key) && !env[key].to_s.empty? }
        environment_value = if environment_key
                              env_value.respond_to?(:call) ? env_value.call(environment_key, env.fetch(environment_key), env) : env.fetch(environment_key)
                            end
        return environment_value if env_overrides && environment_key

        configured_path = ([path] + aliases + fallback_paths).compact.find { |candidate| config.path_present?(*candidate) }
        return Config.deep_copy(config.value(*configured_path)) if configured_path
        return environment_value if environment_key

        default_value(config, env: env)
      end

      def source(config, env: ENV)
        environment_key = override_env.find { |key| env.key?(key) && !env[key].to_s.empty? }
        return "env:#{environment_key}" if env_overrides && environment_key

        configured_path = ([path] + aliases + fallback_paths).compact.find { |candidate| config.path_present?(*candidate) }
        if configured_path
          override_source = config.override_source_for(*configured_path)
          return override_source if override_source

          return "file"
        end
        return "env:#{environment_key}" if environment_key

        "default"
      end

      def normalize_value(value)
        return normalize.call(value) if normalize.respond_to?(:call)

        case type
        when "boolean"
          return value if value == true || value == false
          return true if value.to_s.strip.downcase == "true"
          return false if value.to_s.strip.downcase == "false"
          raise ArgumentError, "must be true or false"
        when "integer", "duration"
          Integer(value)
        when "enum", "thinking_level"
          value.to_s.strip.downcase.tr("_", "-")
        when "model_reference", "path", "string", "read_only", "action"
          value.nil? ? "" : value.to_s
        when "command_argv"
          normalize_command(value)
        when "string_list", "blacklist_glob_list", "keybinding_list"
          normalize_string_list(value)
        when "environment_map"
          normalize_environment(value)
        else
          Config.deep_copy(value)
        end
      rescue JSON::ParserError, Shellwords::ParseError => e
        raise ArgumentError, e.message
      end

      def validate_value(value, config: nil)
        normalized = normalize_value(value)
        built_in_validate(normalized, config: config)
        custom = validate.respond_to?(:call) ? validate.call(normalized, config) : nil
        raise ArgumentError, custom.to_s unless custom.nil? || custom == true

        normalized
      end

      private

      def built_in_validate(value, config:)
        if %w[integer duration].include?(type)
          raise ArgumentError, "must be at least #{minimum}" if !minimum.nil? && value < minimum
          raise ArgumentError, "must be at most #{maximum}" if !maximum.nil? && value > maximum
        end

        if %w[enum thinking_level].include?(type)
          allowed = option_values(config)
          raise ArgumentError, "must be one of: #{allowed.join(", ")}" unless allowed.include?(value)
        end

        case type
        when "model_reference"
          reason = if defined?(Meringue::Harness::ModelReference)
                     Meringue::Harness::ModelReference.rejection_reason(value)
                   elsif !value.to_s.match?(%r{\A[^/\s]+/[^\s/].*\z})
                     "must be a provider/model id"
                   end
          raise ArgumentError, reason if reason
        when "path", "string", "read_only"
          raise ArgumentError, "must not contain a null byte" if value.include?("\0")
        when "command_argv"
          return if optional && value.empty?
          raise ArgumentError, "must contain an executable" if value.empty? || value.first.to_s.empty?
          raise ArgumentError, "must contain only strings" unless value.all? { |entry| entry.is_a?(String) }
          raise ArgumentError, "must not contain a null byte" if value.any? { |entry| entry.include?("\0") }
        when "string_list"
          validate_string_entries(value)
        when "environment_map"
          value.each do |key, child|
            raise ArgumentError, "environment keys must not be empty" if key.empty?
            raise ArgumentError, "environment keys must not contain = or null bytes" if key.include?("=") || key.include?("\0")
            raise ArgumentError, "environment values must not contain null bytes" if child.include?("\0")
          end
        when "blacklist_glob_list"
          if defined?(Meringue::CommandBlacklist)
            Meringue::CommandBlacklist.new(value)
          else
            validate_string_entries(value)
          end
        when "keybinding_list"
          validate_string_entries(value)
          if defined?(Meringue::TUI::Keybindings)
            invalid = value.reject { |name| Meringue::TUI::Keybindings.compile_name(name).any? }
            raise ArgumentError, "invalid key sequence#{invalid.length == 1 ? "" : "s"}: #{invalid.join(", ")}" unless invalid.empty?
          end
        end
      rescue Meringue::CommandBlacklist::ConfigurationError => e
        raise ArgumentError, e.message
      end

      def validate_string_entries(value)
        raise ArgumentError, "must contain only strings" unless value.all? { |entry| entry.is_a?(String) }
        raise ArgumentError, "must not contain null bytes" if value.any? { |entry| entry.include?("\0") }
      end

      def normalize_command(value)
        case value
        when Array
          value.map(&:to_s)
        when String
          stripped = value.strip
          return JSON.parse(stripped).map(&:to_s) if stripped.start_with?("[")

          Shellwords.split(stripped)
        else
          raise ArgumentError, "must be an argv array or shell-quoted command"
        end
      end

      def normalize_string_list(value)
        case value
        when Array
          value.map(&:to_s)
        when String
          stripped = value.strip
          return [] if stripped.empty?
          return JSON.parse(stripped).map(&:to_s) if stripped.start_with?("[")

          stripped.split(/\r?\n|,/).map(&:strip).reject(&:empty?)
        else
          raise ArgumentError, "must be a list of strings"
        end
      end

      def normalize_environment(value)
        source = case value
                 when Hash then value
                 when String
                   stripped = value.strip
                   if stripped.start_with?("{")
                     JSON.parse(stripped)
                   else
                     stripped.lines.each_with_object({}) do |line, result|
                       next if line.strip.empty?
                       key, child = line.chomp.split("=", 2)
                       raise ArgumentError, "environment entries use KEY=VALUE" if child.nil?

                       result[key] = child
                     end
                   end
                 else
                   raise ArgumentError, "must be a key/value map"
                 end
        source.each_with_object({}) { |(key, child), result| result[key.to_s] = child.to_s }
      end
    end

    module Schema
      VERSION = 1
      CATEGORIES = [
        "Agent defaults",
        "Appearance",
        "Experiments",
        "Harnesses",
        "Workspace",
        "Safety",
        "Keybindings",
        "Setup"
      ].freeze
      THINKING_LEVELS = %w[off minimal low medium high xhigh max].freeze
      PROVIDERS = %w[pi claude codex antigravity].freeze

      module_function

      def definitions
        @definitions ||= build_definitions.freeze
      end

      def reload!
        @definitions = nil
        definitions
      end

      def fetch(id)
        by_id.fetch(id.to_s) { raise KeyError, "Unknown setting #{id.inspect}" }
      end

      def by_id
        @by_id ||= definitions.to_h { |definition| [definition.id, definition] }.freeze
      end

      def categories
        CATEGORIES
      end

      def for_category(category, include_internal: false)
        definitions.select do |definition|
          definition.category == category.to_s && (include_internal || definition.visibility != "internal")
        end
      end

      def setting_ids
        definitions.map(&:id)
      end

      def paths
        definitions.flat_map { |definition| [definition.path, *definition.aliases] }.compact
      end

      def validate_registry!
        duplicate_ids = setting_ids.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
        duplicate_paths = paths.map { |path| path.join(".") }.group_by(&:itself).select { |_path, values| values.length > 1 }.keys
        errors = []
        errors << "duplicate setting ids: #{duplicate_ids.join(", ")}" unless duplicate_ids.empty?
        errors << "duplicate setting paths/aliases: #{duplicate_paths.join(", ")}" unless duplicate_paths.empty?
        raise ArgumentError, errors.join("; ") unless errors.empty?

        true
      end

      def effective_values(config, env: ENV)
        definitions.each_with_object({}) do |definition, result|
          next if definition.type == "action"

          result[definition.id] = definition.effective_value(config, env: env)
        end
      end

      def validate_changes(changes, config: nil)
        normalized = {}
        errors = {}
        Config.deep_stringify(changes || {}).each do |id, value|
          definition = by_id[id]
          unless definition
            errors[id] = "is not a supported setting"
            next
          end
          if definition.visibility == "read_only" || definition.type == "read_only" || definition.path.nil?
            errors[id] = "is read-only"
            next
          end
          begin
            normalized[id] = definition.validate_value(value, config: config)
          rescue ArgumentError => e
            errors[id] = e.message
          end
        end
        raise ValidationError, errors unless errors.empty?

        normalized
      end

      def restart_required_ids(ids)
        Array(ids).map(&:to_s).select { |id| by_id[id]&.apply_mode == "restart" }
      end

      def live_ids(ids)
        Array(ids).map(&:to_s).select { |id| by_id[id]&.apply_mode == "live" }
      end

      def build_definitions
        settings = []
        add_role_defaults(settings)
        add_appearance(settings)
        add_experiments(settings)
        add_harnesses(settings)
        add_workspace(settings)
        add_safety(settings)
        add_keybindings(settings)
        add_setup(settings)
        settings
      end

      def add_role_defaults(settings)
        settings.concat([
          definition("agent.head_harness", %w[harness head_provider], "Agent defaults", "enum", nil, fallback_paths: [%w[harness provider]], options: PROVIDERS, editor: "selector", apply_mode: "live", label: "Head harness", description: "Agent harness used for future routing heads.", override_env: %w[MERINGUE_HEAD_HARNESS MERINGUE_HARNESS], env_overrides: true),
          # Model and reasoning defaults follow whichever harness is selected rather than living
          # under one backend's section. The legacy [harness.pi] paths stay readable as fallbacks so
          # an existing configuration keeps working, and a value set under a specific backend still
          # wins for that backend.
          definition("agent.head_model", %w[harness head_model], "Agent defaults", "model_reference", ->(config, env) { default_model_for_role(config, env, "head") }, fallback_paths: [%w[harness model], %w[harness pi head_model], %w[harness pi model]], editor: "model", apply_mode: "live", label: "Head model", description: "Model for future heads; exact provider/model references remain allowed when the catalog is unavailable."),
          definition("agent.head_thinking", %w[harness head_thinking_level], "Agent defaults", "thinking_level", "max", fallback_paths: [%w[harness thinking_level], %w[harness pi head_thinking_level], %w[harness pi thinking_level]], options: THINKING_LEVELS, editor: "selector", apply_mode: "live", label: "Head reasoning", description: "Reasoning level for future heads."),
          definition("agent.worker_harness", %w[harness worker_provider], "Agent defaults", "enum", nil, fallback_paths: [%w[harness provider]], options: PROVIDERS, editor: "selector", apply_mode: "live", label: "Worker harness", description: "Agent harness used for future workers.", override_env: %w[MERINGUE_WORKER_HARNESS MERINGUE_HARNESS], env_overrides: true),
          definition("agent.worker_model", %w[harness worker_model], "Agent defaults", "model_reference", ->(config, env) { default_model_for_role(config, env, "worker") }, fallback_paths: [%w[harness model], %w[harness pi worker_model], %w[harness pi model]], editor: "model", apply_mode: "live", label: "Worker model", description: "Model for future workers; existing sessions are unchanged."),
          definition("agent.worker_thinking", %w[harness worker_thinking_level], "Agent defaults", "thinking_level", "max", fallback_paths: [%w[harness thinking_level], %w[harness pi worker_thinking_level], %w[harness pi thinking_level]], options: THINKING_LEVELS, editor: "selector", apply_mode: "live", label: "Worker reasoning", description: "Reasoning level for future workers."),
          definition("agent.shared_harness_compatibility", %w[harness provider], "Agent defaults", "read_only", nil, visibility: "internal", apply_mode: "none", label: "Shared harness compatibility", description: "Backward-compatible shared harness fallback."),
          definition("agent.shared_model_compatibility", %w[harness model], "Agent defaults", "read_only", "anthropic/claude-opus-5", visibility: "internal", apply_mode: "none", label: "Shared model compatibility", description: "Backward-compatible shared model fallback."),
          definition("agent.shared_thinking_compatibility", %w[harness thinking_level], "Agent defaults", "read_only", "max", visibility: "internal", apply_mode: "none", label: "Shared reasoning compatibility", description: "Backward-compatible shared reasoning fallback.")
        ])
      end

      def default_model_for_role(config, env, role)
        role_provider = env["MERINGUE_#{role.upcase}_HARNESS"] || env["MERINGUE_HARNESS"] ||
                        config&.value("harness", "#{role}_provider") || config&.value("harness", "provider")
        if defined?(Meringue::Harness::Registry) && !role_provider.to_s.strip.empty?
          Meringue::Harness::Registry.default_model_for(role_provider)
        else
          "anthropic/claude-opus-5"
        end
      rescue ArgumentError
        "anthropic/claude-opus-5"
      end

      def add_appearance(settings)
        settings << definition("appearance.theme", %w[tui colorscheme], "Appearance", "enum", "meringue", aliases: [%w[tui color_scheme]], options: ->(_config) { defined?(Meringue::TUI::Style) ? Meringue::TUI::Style.colorschemes : %w[meringue rose-pine tokyonight gruvbox catppuccin kanagawa] }, editor: "selector", apply_mode: "live", label: "Theme", description: "Dashboard colorscheme. Highlighting previews the theme; only Save persists it.")
        settings << definition("appearance.animations", %w[tui animations], "Appearance", "boolean", true, editor: "checkbox", apply_mode: "live", label: "Animations", description: "Use motion where the terminal can render it safely.", override_env: %w[MERINGUE_NO_ANIMATION], env_overrides: true, env_value: ->(_key, _value, _env) { false })
        settings << definition(
          "appearance.status_bar_layout",
          %w[tui status_bar_layout],
          "Appearance",
          "status_bar_layout",
          "",
          aliases: [%w[tui status_bars], %w[tui status_bar]],
          editor: "status_bar",
          apply_mode: "live",
          label: "Status bar layout",
          description: "Optional JSON layout for the bottom, agent-information, and focused-worker status bars. Use /status-bar to edit it.",
          advanced: true,
          normalize: ->(value) { value.nil? ? "" : value.to_s },
          validate: ->(value, _config) {
            value.to_s.empty? || !defined?(Meringue::TUI::StatusBarLayout) || Meringue::TUI::StatusBarLayout.valid_serialized?(value)
          }
        )
      end

      def add_experiments(settings)
        Meringue::Experiments::Registry.all.each do |experiment|
          settings << definition(
            "experiments.#{experiment.id}",
            experiment.config_path,
            "Experiments",
            "boolean",
            experiment.default,
            editor: "checkbox",
            apply_mode: experiment.apply_mode,
            label: experiment.label,
            description: "#{experiment.description} #{experiment.risk}".strip
          )
          if experiment.id == "worker_spawning_guidance"
            settings << definition(
              "experiments.worker_spawning_guidance_prompt",
              %w[experiments worker_spawning_guidance_prompt],
              "Experiments",
              "string",
              Meringue::Experiments::WorkerSpawningGuidance.default_text,
              editor: "text",
              apply_mode: "live",
              label: "Worker model selection prompt",
              description: "Additional system-prompt text supplied to heads when worker model selection guidance is enabled. Use @ for models and # for thinking levels."
            )
          end
          experiment.actions.each do |action|
            settings << definition(
              "experiments.#{action.fetch("id")}",
              nil,
              "Experiments",
              "action",
              nil,
              editor: "action",
              apply_mode: "none",
              label: action.fetch("label"),
              description: action.fetch("description"),
              dependencies: ["experiments.#{experiment.id}"]
            )
          end
        end
      end

      def add_harnesses(settings)
        defaults = {
          "pi" => {
            "command" => ["pi"],
            "head_extra_args" => ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--tools", "read,bash,grep,find,ls", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve"],
            "worker_extra_args" => ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--tools", "read,bash,grep,find,ls,edit,write", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve"]
          },
          "claude" => {
            "command" => ["claude"],
            "head_extra_args" => ["--effort", "high", "--tools", "Read,Glob,Grep,Bash", "--permission-mode", "plan", "--disable-slash-commands"],
            "worker_extra_args" => ["--effort", "high", "--permission-mode", "acceptEdits"]
          },
          "codex" => {
            "command" => ["codex"],
            "head_extra_args" => ["--sandbox", "read-only", "--ask-for-approval", "never"],
            "worker_extra_args" => ["--dangerously-bypass-approvals-and-sandbox"]
          },
          "antigravity" => { "command" => ["agy"], "head_extra_args" => [], "worker_extra_args" => [] }
        }
        PROVIDERS.each do |provider|
          label = { "claude" => "Claude Code", "codex" => "Codex CLI" }.fetch(provider, provider.capitalize)
          settings.concat([
            definition("harnesses.#{provider}.command", ["harness", provider, "command"], "Harnesses", "command_argv", defaults.dig(provider, "command"), editor: "command", label: "#{label} command", description: "Executable and arguments used to launch #{label}.", advanced: true),
            definition("harnesses.#{provider}.env", ["harness", provider, "env"], "Harnesses", "environment_map", {}, editor: "environment", label: "#{label} environment", description: "Additional process environment. Values are redacted outside the editor.", sensitive: true, advanced: true),
            definition("harnesses.#{provider}.extra_args", ["harness", provider, "extra_args"], "Harnesses", "string_list", [], editor: "list", label: "#{label} shared arguments", description: "Arguments added to both role launches.", advanced: true),
            definition("harnesses.#{provider}.head_extra_args", ["harness", provider, "head_extra_args"], "Harnesses", "string_list", defaults.dig(provider, "head_extra_args"), editor: "list", label: "#{label} head arguments", description: "Arguments added to head launches.", advanced: true),
            definition("harnesses.#{provider}.worker_extra_args", ["harness", provider, "worker_extra_args"], "Harnesses", "string_list", defaults.dig(provider, "worker_extra_args"), editor: "list", label: "#{label} worker arguments", description: "Arguments added to worker launches.", advanced: true),
            definition("harnesses.#{provider}.head_session_name_prefix", ["harness", provider, "head_session_name_prefix"], "Harnesses", "string", "Meringue Head", editor: "text", label: "#{label} head session prefix", description: "Prefix for provider-side head session names.", advanced: true),
            definition("harnesses.#{provider}.head_timeout", ["harness", provider, "head_timeout"], "Harnesses", "duration", 120, editor: "integer", label: "#{label} head timeout", description: "Seconds allowed for capturing a head result from this harness.", minimum: 1, maximum: 86_400, advanced: true)
          ])
        end
        settings << definition("harnesses.pi.session_dir", %w[harness pi session_dir], "Harnesses", "path", ->(_config, env) { File.expand_path(env.fetch("MERINGUE_AGENT_SESSION_DIR", env.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))) }, editor: "text", label: "Pi session directory", description: "Directory containing Pi session files.", override_env: %w[MERINGUE_AGENT_SESSION_DIR MERINGUE_PI_SESSION_DIR], advanced: true)
        settings << definition("harnesses.claude.use_json_schema", %w[harness claude use_json_schema], "Harnesses", "boolean", true, editor: "checkbox", label: "Claude JSON schema", description: "Ask Claude Code to constrain head output to the HeadResult schema.", advanced: true)
      end

      def add_workspace(settings)
        settings.concat([
          definition("workspace.worktree_provider", %w[workspace worktree_provider], "Workspace", "enum", "native_git", options: %w[native_git command], editor: "selector", label: "Worktree provider", description: "Create isolated worker worktrees with native Git or a locally configured command provider.", advanced: true),
          definition("workspace.worktree_provider_fallback", %w[workspace worktree_provider_fallback], "Workspace", "enum", "native_git", options: %w[native_git none], editor: "selector", label: "Worktree fallback", description: "Use native Git when the command provider is unavailable before it mutates a worktree.", advanced: true),
          definition("workspace.worktree_provider_command", %w[workspace worktree_provider_command], "Workspace", "command_argv", [], editor: "command", label: "Worktree provider command", description: "Executable argv prefix implementing the generic worktree provider protocol.", advanced: true, optional: true),
          definition("workspace.root", %w[workspace root_path], "Workspace", "path", ->(_config, _env) { File.expand_path("~/.meringue/workspaces") }, editor: "text", label: "Workspace root", description: "Parent directory for native Git worktrees and ownership records for provider-managed worktrees.", advanced: true),
          definition("workspace.provisioning_concurrency", %w[workspace worker_provisioning_concurrency], "Workspace", "integer", 2, editor: "integer", label: "Provisioning concurrency", description: "Independent worktrees provisioned concurrently.", minimum: 1, maximum: 8, advanced: true),
          definition("workspace.git_timeout", %w[workspace git_command_timeout], "Workspace", "duration", 60, editor: "integer", label: "Git command timeout", description: "Seconds allowed for short Git plumbing commands.", minimum: 1, maximum: 86_400, advanced: true),
          definition("workspace.worktree_stall_timeout", %w[workspace worktree_stall_timeout], "Workspace", "duration", 120, editor: "integer", label: "Checkout stall timeout", description: "Seconds a worktree checkout may produce no output.", minimum: 1, maximum: 86_400, advanced: true),
          definition("workspace.worktree_checkout_timeout", %w[workspace worktree_checkout_timeout], "Workspace", "duration", 1800, editor: "integer", label: "Checkout ceiling", description: "Absolute seconds allowed for one worktree checkout.", minimum: 1, maximum: 604_800, advanced: true),
          definition("workspace.shell", %w[workspace shell_command], "Workspace", "command_argv", ->(_config, env) { [env["MERINGUE_SHELL"] || env["SHELL"] || "/bin/sh"] }, editor: "command", label: "Workspace shell", description: "Shell argv for focused workspace terminals.", override_env: %w[MERINGUE_SHELL SHELL], advanced: true),
          definition("workspace.editor", %w[workspace editor_command], "Workspace", "command_argv", ->(_config, env) { [env["MERINGUE_EDITOR"] || env["VISUAL"] || env["EDITOR"] || "code"] }, editor: "command", label: "Workspace editor", description: "Editor argv launched from focused workspaces.", override_env: %w[MERINGUE_EDITOR VISUAL EDITOR], advanced: true),
          definition("workspace.editor_args", %w[workspace editor_args], "Workspace", "string_list", ["."], editor: "list", label: "Editor arguments", description: "Arguments appended when opening a worker worktree.", advanced: true),
          definition("workspace.terminal_buffer_bytes", %w[workspace terminal_buffer_bytes], "Workspace", "integer", 4 * 1024 * 1024, editor: "integer", label: "Terminal buffer", description: "Maximum focused terminal output retained in bytes.", minimum: 4096, maximum: 256 * 1024 * 1024, advanced: true),
          definition("workspace.alacritty_command", %w[terminal alacritty_command], "Workspace", "command_argv", ->(_config, env) { env["MERINGUE_ALACRITTY_COMMAND"].to_s.empty? ? [] : [env["MERINGUE_ALACRITTY_COMMAND"]] }, editor: "command", label: "External terminal command", description: "Optional command used to open provider sessions externally.", override_env: %w[MERINGUE_ALACRITTY_COMMAND], advanced: true, optional: true)
        ])
      end

      def add_safety(settings)
        settings << definition("safety.worker_blacklist", %w[commands worker_blacklist], "Safety", "blacklist_glob_list", [], editor: "list", label: "Worker command blacklist", description: "Full-command glob patterns rejected before an isolated worker bash call.")
        settings << definition("safety.predecessor_failure", %w[conflicts predecessor_failure], "Safety", "enum", "cancel", options: %w[cancel run], editor: "selector", label: "Predecessor failure", description: "Cancel dependent workers when their predecessor fails, or run them anyway.")
      end

      def add_keybindings(settings)
        require_relative "../tui/keybindings" unless defined?(Meringue::TUI::Keybindings)
        defaults = if defined?(Meringue::TUI::Keybindings)
                     Meringue::TUI::Keybindings::DEFAULT_BINDINGS
                   else
                     {}
                   end
        defaults.each do |action, keys|
          settings << definition(
            "keybindings.#{action}",
            ["tui", "keybindings", action],
            "Keybindings",
            "keybinding_list",
            keys,
            editor: "keybinding",
            apply_mode: "live",
            label: (defined?(Meringue::TUI::Keybindings) ? Meringue::TUI::Keybindings.label_for(action) : action.tr("_", " ")),
            description: "Keys for the #{action.tr("_", " ")} action.",
            advanced: true
          )
        end
      end

      def add_setup(settings)
        settings.concat([
          definition("setup.completed_version", %w[onboarding completed_version], "Setup", "read_only", 0, visibility: "read_only", apply_mode: "none", label: "Completed version", description: "Version of setup already completed or skipped."),
          definition("setup.completed_at", %w[onboarding completed_at], "Setup", "read_only", "Not completed", visibility: "read_only", apply_mode: "none", label: "Completed at", description: "When setup was last completed or skipped."),
          definition("setup.outcome", %w[onboarding outcome], "Setup", "read_only", "not_run", visibility: "read_only", apply_mode: "none", label: "Outcome", description: "Whether setup was completed or skipped."),
          definition("setup.run_again", nil, "Setup", "action", nil, visibility: "normal", editor: "action", apply_mode: "none", label: "Run setup again", description: "Close Settings and open the guided setup flow."),
          definition("runtime.config_path", nil, "Setup", "read_only", ->(config, _env) { config&.path.to_s }, visibility: "read_only", apply_mode: "none", label: "Config file", description: "File opened by this Settings draft; --config and MERINGUE_CONFIG choose it before startup.", override_env: %w[MERINGUE_CONFIG], advanced: true),
          definition("runtime.state_path", nil, "Setup", "read_only", "default state path", visibility: "read_only", apply_mode: "none", label: "State file override", description: "MERINGUE_STATE_PATH or --state is process-only and is never saved here.", override_env: %w[MERINGUE_STATE_PATH], advanced: true),
          definition("runtime.claude_config_dir", nil, "Setup", "read_only", "not set", visibility: "read_only", apply_mode: "none", label: "Claude config directory", description: "Process-only Claude Code resource override.", override_env: %w[CLAUDE_CONFIG_DIR], advanced: true),
          definition("runtime.codex_home", nil, "Setup", "read_only", "not set", visibility: "read_only", apply_mode: "none", label: "Codex home", description: "Process-only Codex config and rollout directory override.", override_env: %w[CODEX_HOME], advanced: true),
          definition("runtime.no_color", nil, "Setup", "read_only", "not set", visibility: "read_only", apply_mode: "none", label: "No color", description: "NO_COLOR disables terminal color for this process.", override_env: %w[NO_COLOR], advanced: true),
          definition("runtime.ascii_glyphs", nil, "Setup", "read_only", "not set", visibility: "read_only", apply_mode: "none", label: "ASCII glyphs", description: "MERINGUE_ASCII_GLYPHS replaces Unicode marks for this process.", override_env: %w[MERINGUE_ASCII_GLYPHS], advanced: true),
          definition("runtime.locale", nil, "Setup", "read_only", ->(_config, env) { env["LC_ALL"] || env["LC_CTYPE"] || env["LANG"] || "not set" }, visibility: "read_only", apply_mode: "none", label: "Terminal locale", description: "Locale controls UTF-8 presentation and is process-only.", override_env: %w[LC_ALL LC_CTYPE LANG], advanced: true),
          definition("runtime.pr_open_command", nil, "Setup", "read_only", "platform default", visibility: "read_only", apply_mode: "none", label: "PR opener override", description: "MERINGUE_PR_OPEN_COMMAND changes the browser launcher for this process.", override_env: %w[MERINGUE_PR_OPEN_COMMAND], advanced: true),
          definition("runtime.project_roots", nil, "Setup", "read_only", "not set", visibility: "read_only", apply_mode: "none", label: "Project discovery roots", description: "MERINGUE_PROJECT_ROOTS is a process-only discovery hint.", override_env: %w[MERINGUE_PROJECT_ROOTS], advanced: true),
          definition("runtime.transport_lock_dir", nil, "Setup", "read_only", "default", visibility: "read_only", apply_mode: "none", label: "Transport lock directory", description: "MERINGUE_TRANSPORT_LOCK_DIR is an internal process-only path.", override_env: %w[MERINGUE_TRANSPORT_LOCK_DIR], advanced: true),
          definition("settings.schema_version", %w[settings schema_version], "Setup", "read_only", VERSION, visibility: "internal", apply_mode: "none", label: "Settings schema", description: "Internal configuration migration version.")
        ])
      end

      def definition(id, path, category, type, default, **options)
        SettingDefinition.new(
          id: id,
          path: path,
          category: category,
          type: type,
          default: default,
          description: options.delete(:description),
          **options
        )
      end
    end
  end
end
