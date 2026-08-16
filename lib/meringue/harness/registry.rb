# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module Meringue
  module Harness
    class Registry
      DEFAULT_PROVIDER = "pi"
      PROVIDERS = %w[pi claude antigravity].freeze
      PROVIDER_LABELS = {
        "pi" => "Pi",
        "claude" => "Claude Code",
        "antigravity" => "Antigravity CLI"
      }.freeze
      PUBLIC_PROVIDER_NAMES = {
        "pi" => "pi",
        "claude" => "claude",
        "antigravity" => "antigravity"
      }.freeze
      # Single-cell display glyphs, so a session's backend is identifiable at a
      # glance next to its Meringue id. Provider presentation already lives in
      # this registry (see PROVIDER_LABELS), which keeps panes harness-agnostic:
      # they ask the registry for a glyph instead of knowing about Pi or Claude.
      PROVIDER_GLYPHS = {
        "pi" => "π",
        "claude" => "✳",
        "antigravity" => "↑"
      }.freeze
      # Same marks in plain ASCII for fonts/terminals that cannot draw the
      # glyphs above, selected with MERINGUE_ASCII_GLYPHS.
      PROVIDER_ASCII_GLYPHS = {
        "pi" => "p",
        "claude" => "c",
        "antigravity" => "a"
      }.freeze
      # Matches the AgentTree's unknown-status convention.
      UNKNOWN_PROVIDER_GLYPH = "?"
      PROVIDER_ALIASES = {
        "pi" => "pi",
        "claude" => "claude",
        "claude-code" => "claude",
        "claude_code" => "claude",
        "claude code" => "claude",
        "cc" => "claude",
        "antigravity" => "antigravity",
        "antigravity-cli" => "antigravity",
        "antigravity_cli" => "antigravity",
        "antigravity cli" => "antigravity",
        "agy" => "antigravity"
      }.freeze
      DEFAULT_PI_SESSION_DIR = File.expand_path(ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
      COMMAND_BLACKLIST_ENV = "MERINGUE_WORKER_COMMAND_BLACKLIST"
      COMMAND_BLACKLIST_EXTENSION = Meringue.root_path("lib", "meringue", "harness", "extensions", "command_blacklist.js")
      # Canonical "provider/model" reference so Pi never has to disambiguate the
      # bare model id across providers that all expose Claude Opus 5.
      DEFAULT_PI_MODEL = "anthropic/claude-opus-5"
      # Highest thinking level Pi exposes; Claude Opus 5 only supports xhigh/max.
      DEFAULT_PI_THINKING_LEVEL = "max"
      DEFAULT_PI_HEAD_EXTRA_ARGS = [
        "--model", DEFAULT_PI_MODEL,
        "--thinking", DEFAULT_PI_THINKING_LEVEL,
        "--tools", "read,bash,grep,find,ls",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-approve"
      ].freeze
      DEFAULT_PI_WORKER_EXTRA_ARGS = [
        "--model", DEFAULT_PI_MODEL,
        "--thinking", DEFAULT_PI_THINKING_LEVEL,
        "--tools", "read,bash,grep,find,ls,edit,write",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-approve"
      ].freeze
      DEFAULT_PROVIDER_CONFIG = {
        "pi" => {
          "command" => "pi",
          "session_dir" => DEFAULT_PI_SESSION_DIR,
          "head_extra_args" => DEFAULT_PI_HEAD_EXTRA_ARGS,
          "worker_extra_args" => DEFAULT_PI_WORKER_EXTRA_ARGS
        },
        "claude" => {
          "command" => "claude",
          "head_extra_args" => [
            "--effort", "high",
            "--tools", "Read,Glob,Grep,Bash",
            "--permission-mode", "plan",
            "--disable-slash-commands"
          ],
          "worker_extra_args" => [
            "--effort", "high",
            "--permission-mode", "acceptEdits"
          ],
          "use_json_schema" => true
        },
        "antigravity" => {
          "command" => "agy",
          "head_extra_args" => [],
          "worker_extra_args" => []
        }
      }.freeze

      attr_reader :config

      def initialize(config: Config.load)
        @config = config
        @command_blacklist = CommandBlacklist.from_config(config)
        @clients = {}
      end

      def self.normalize_provider(provider)
        normalized = provider.to_s.strip.downcase.gsub(/\s+/, " ")
        normalized = DEFAULT_PROVIDER if normalized.empty?
        PROVIDER_ALIASES.fetch(normalized, normalized)
      end

      def self.normalize_provider!(provider)
        normalized = normalize_provider(provider)
        return normalized if PROVIDERS.include?(normalized)

        raise ArgumentError, "Unsupported harness provider #{provider.inspect}. Supported providers: #{supported_provider_names.join(", ")}"
      end

      def self.provider_label(provider)
        PROVIDER_LABELS.fetch(normalize_provider(provider), provider.to_s)
      end

      # Degrades in three steps, and every branch is exactly one column wide so
      # a renderer can reserve one cell and never misalign:
      #
      # 1. a shipped provider's mark (or its ASCII twin under
      #    MERINGUE_ASCII_GLYPHS);
      # 2. a plain ASCII initial for a provider Meringue does not ship, such as
      #    the `fake` harness used by the demo fixture and the test suite, so an
      #    unknown backend never masquerades as a shipped one;
      # 3. "?" when the record carries no harness at all.
      #
      # This deliberately does not reuse normalize_provider, which resolves a
      # blank value to the default provider: "no harness recorded" must not
      # render as Pi.
      def self.provider_glyph(provider, ascii: ascii_glyphs?)
        name = provider.to_s.strip.downcase.gsub(/\s+/, " ")
        return UNKNOWN_PROVIDER_GLYPH if name.empty?

        normalized = PROVIDER_ALIASES.fetch(name, name)
        glyphs = ascii ? PROVIDER_ASCII_GLYPHS : PROVIDER_GLYPHS
        return glyphs.fetch(normalized) if glyphs.key?(normalized)

        initial = normalized[0].to_s
        initial.match?(/[a-z0-9]/) ? initial : UNKNOWN_PROVIDER_GLYPH
      end

      def self.ascii_glyphs?
        !ENV.fetch("MERINGUE_ASCII_GLYPHS", "").to_s.strip.empty?
      end

      def self.public_provider_name(provider)
        PUBLIC_PROVIDER_NAMES.fetch(normalize_provider(provider), normalize_provider(provider))
      end

      def self.supported_provider_names
        PROVIDERS.map { |provider| public_provider_name(provider) }
      end

      def self.provider_choices
        PROVIDERS.map do |provider|
          {
            "provider" => public_provider_name(provider),
            "internal_provider" => provider,
            "label" => provider_label(provider),
            "description" => "Use #{provider_label(provider)} for future heads and workers."
          }
        end
      end

      def provider_for(kind)
        self.class.normalize_provider!(
          env_provider_for(kind) ||
            config.value("harness", "#{kind}_provider") ||
            config.value("harness", "provider") ||
            DEFAULT_PROVIDER
        )
      end

      def head_provider
        provider_for("head")
      end

      def worker_provider
        provider_for("worker")
      end

      def head_runner(cwd: Dir.pwd)
        head_runner_for(provider: head_provider, cwd: cwd)
      end

      def head_runner_for(provider:, cwd: Dir.pwd)
        provider = self.class.normalize_provider!(provider)
        client = client_for(provider: provider, kind: "head")
        session_name_prefix = provider_option(provider, "head_session_name_prefix") || "Meringue Head"

        case provider
        when "pi"
          Heads::PiRunner.new(harness_client: client, cwd: cwd, session_name_prefix: session_name_prefix)
        when "claude", "antigravity"
          Heads::HarnessRunner.new(
            harness_client: client,
            cwd: cwd,
            session_name_prefix: session_name_prefix,
            timeout: numeric_provider_option(provider, "head_timeout") || ProcessClient::DEFAULT_EVENT_TIMEOUT
          )
        else
          raise ArgumentError, "Unsupported head harness provider: #{provider.inspect}"
        end
      end

      def worker_client
        worker_client_for(provider: worker_provider)
      end

      def worker_client_for(provider:)
        client_for(provider: provider, kind: "worker")
      end

      def client_for(provider:, kind:)
        provider = normalize_provider!(provider)
        kind = kind.to_s == "head" ? "head" : "worker"
        @clients[[provider, kind]] ||= build_client(provider: provider, kind: kind)
      end

      def client_for_agent(agent)
        client_for(provider: agent.fetch("harness", worker_provider), kind: agent.fetch("type", "worker"))
      end

      def terminal_session_opener
        TerminalSessionOpener.new(
          commands: PROVIDERS.each_with_object({}) { |provider, result| result[provider] = provider_command(provider) },
          pi_session_dir: provider_config("pi").fetch("session_dir", DEFAULT_PI_SESSION_DIR),
          alacritty_command: config.value("terminal", "alacritty_command") || ENV["MERINGUE_ALACRITTY_COMMAND"]
        )
      end

      def provider_command(provider)
        command = provider_config(provider).fetch("command")
        command.is_a?(Array) ? command.join(" ") : command.to_s
      end

      # Authoritative model catalog for one harness provider, asked of that
      # provider's client. Providers without catalog support answer with an
      # explicit unsupported catalog, so callers never need provider branches.
      def model_catalog(provider: nil, kind: "worker", cwd: nil)
        # An unsupported provider name is a caller error, not a degraded catalog,
        # so it still raises before any client is built.
        provider = normalize_provider!(provider || worker_provider)
        public_name = self.class.public_provider_name(provider)
        begin
          client = client_for(provider: provider, kind: kind)
          return ModelCatalog.unsupported(harness: public_name) unless catalog_capable?(client)

          client.available_models(cwd: cwd)
        rescue StandardError => e
          ModelCatalog.unavailable(
            harness: public_name,
            note: "Could not ask #{self.class.provider_label(provider)} for its models: #{e.message}",
            reason: "fetch_failed",
            error: e.class.name
          )
        end
      end

      # Effective defaults used when the registry next starts a Pi head or
      # worker. Role details stay visible when dedicated model/thinking defaults
      # or older explicit argv values differ.
      def session_defaults(provider: "pi")
        provider = normalize_provider!(provider)
        raise ArgumentError, "Session defaults are currently Pi-only." unless provider == "pi"

        provider_settings = provider_config(provider)
        roles = %w[head worker].to_h do |kind|
          args = extra_args_for(provider, provider_settings, kind)
          [kind, {
            "model" => command_option(args, "--model") || DEFAULT_PI_MODEL,
            "thinking_level" => command_option(args, "--thinking") || DEFAULT_PI_THINKING_LEVEL
          }]
        end
        shared_model = roles.values.map { |role| role.fetch("model") }.uniq
        shared_thinking = roles.values.map { |role| role.fetch("thinking_level") }.uniq
        {
          "harness" => "pi",
          "model" => shared_model.one? ? shared_model.first : nil,
          "thinking_level" => shared_thinking.one? ? shared_thinking.first : nil,
          "consistency" => shared_model.one? && shared_thinking.one? ? "consistent" : "mixed",
          "roles" => roles,
          "scope" => "future_pi_sessions"
        }
      end

      # Applies only runtime-safe provider defaults after an atomic Settings
      # transaction. Provider commands/environment/arguments and blacklist policy
      # remain restart-required, and cached clients stay attached to existing
      # sessions. Pi clients receive only replacement spawn defaults.
      def reload_config!(updated_config, changed_ids: [])
        live_role_ids = %w[
          agent.head_harness agent.worker_harness
          agent.head_model agent.worker_model
          agent.head_thinking agent.worker_thinking
        ]
        ids = Array(changed_ids).map(&:to_s)
        return self if (ids & live_role_ids).empty?

        data = config.to_h
        data["harness"] = {} unless data["harness"].is_a?(Hash)
        updated_harness = updated_config.section("harness")
        %w[provider head_provider worker_provider].each do |key|
          if updated_harness.key?(key)
            data.fetch("harness")[key] = Config.deep_copy(updated_harness[key])
          else
            data.fetch("harness").delete(key)
          end
        end
        data.fetch("harness")["pi"] = {} unless data.fetch("harness")["pi"].is_a?(Hash)
        updated_pi = updated_config.section("harness", "pi")
        %w[model head_model worker_model thinking_level head_thinking_level worker_thinking_level].each do |key|
          if updated_pi.key?(key)
            data.fetch("harness").fetch("pi")[key] = Config.deep_copy(updated_pi[key])
          else
            data.fetch("harness").fetch("pi").delete(key)
          end
        end
        @config = Config.new(data, path: updated_config.path, loaded: updated_config.loaded?, file_data: updated_config.to_file_h)
        provider_settings = provider_config("pi")
        @clients.each do |(provider, kind), client|
          next unless provider == "pi" && client.respond_to?(:configure_spawn_arguments)

          client.configure_spawn_arguments(extra_args_for("pi", provider_settings, kind))
        end
        self
      end

      # Saves the selected values and reconfigures cached Pi clients in place.
      # Existing RPC processes keep their current effective settings; only a
      # later new-session spawn applies the replacement model/thinking argv.
      def update_session_defaults!(provider: "pi", model: nil, model_role: nil, thinking_level: nil, thinking_role: nil)
        provider = normalize_provider!(provider)
        raise ArgumentError, "Session defaults are currently Pi-only." unless provider == "pi"

        saved = Config.save_pi_session_defaults!(
          model: model,
          model_role: model_role,
          thinking_level: thinking_level,
          thinking_role: thinking_role,
          path: config.path
        )
        @config = saved
        provider_settings = provider_config("pi")
        @clients.each do |(cached_provider, kind), client|
          next unless cached_provider == "pi" && client.respond_to?(:configure_spawn_arguments)

          client.configure_spawn_arguments(extra_args_for("pi", provider_settings, kind))
        end
        session_defaults(provider: "pi")
      end

      private

      def catalog_capable?(client)
        client.respond_to?(:model_catalog_supported?) && client.model_catalog_supported?
      end

      def build_client(provider:, kind:)
        provider = normalize_provider!(provider)
        provider_config = provider_config(provider)
        extra_args = extra_args_for(provider, provider_config, kind)
        # This variable is owned by Meringue. Do not let provider env settings
        # inject a policy into heads or replace the validated worker patterns.
        env = env_for(provider_config).reject { |key, _value| key.to_s == COMMAND_BLACKLIST_ENV }
        command = command_argv(provider_config.fetch("command"))

        if kind == "worker" && !@command_blacklist.empty?
          unless provider == "pi"
            raise ArgumentError,
                  "commands.worker_blacklist cannot be enforced by #{self.class.provider_label(provider)}; use Pi or remove the blacklist"
          end
          env = env.merge(COMMAND_BLACKLIST_ENV => JSON.generate(@command_blacklist.patterns))
        end

        case provider
        when "pi"
          session_dir = File.expand_path(provider_config.fetch("session_dir", DEFAULT_PI_SESSION_DIR).to_s)
          FileUtils.mkdir_p(session_dir)
          PiClient.new(command: command, session_dir: session_dir, env: env, extra_args: extra_args)
        when "claude"
          ClaudeCodeClient.new(
            command: command,
            env: env,
            extra_args: extra_args,
            use_json_schema: boolean_option(provider_config, "use_json_schema", true)
          )
        when "antigravity"
          AntigravityClient.new(command: command, env: env, extra_args: extra_args)
        else
          raise ArgumentError, "Unsupported harness provider: #{provider.inspect}"
        end
      end

      def provider_config(provider)
        provider = normalize_provider!(provider)
        defaults = DEFAULT_PROVIDER_CONFIG.fetch(provider, {})
        legacy_configured = config.section("harness", provider)
        public_configured = config.section("harness", self.class.public_provider_name(provider))
        Config.deep_merge(Config.deep_merge(defaults, legacy_configured), public_configured)
      end

      def extra_args_for(provider, provider_config, kind)
        args = Array(provider_config["extra_args"]) + Array(provider_config["#{kind}_extra_args"])
        return args unless provider == "pi"

        args = args.dup
        model = provider_config["#{kind}_model"].to_s.strip
        model = provider_config["model"].to_s.strip if model.empty?
        thinking_level = provider_config["#{kind}_thinking_level"].to_s.strip
        thinking_level = provider_config["thinking_level"].to_s.strip if thinking_level.empty?
        args.concat(["--model", model]) unless model.empty?
        args.concat(["--thinking", thinking_level]) unless thinking_level.empty?
        if kind == "worker" && !@command_blacklist.empty?
          args.concat(["--extension", COMMAND_BLACKLIST_EXTENSION])
        end
        args
      end

      def command_option(args, option)
        values = []
        Array(args).each_with_index do |argument, index|
          text = argument.to_s
          values << args[index + 1].to_s if text == option && args[index + 1]
          values << text.delete_prefix("#{option}=") if text.start_with?("#{option}=")
        end
        values.reject(&:empty?).last
      end

      def env_for(provider_config)
        env = provider_config.fetch("env", {})
        return {} unless env.is_a?(Hash)

        env
      end

      def command_argv(command)
        case command
        when Array
          command.map(&:to_s)
        else
          Shellwords.split(command.to_s)
        end
      rescue ArgumentError
        [command.to_s]
      end

      def provider_option(provider, key)
        provider_config(provider)[key.to_s]
      end

      def numeric_provider_option(provider, key)
        value = provider_option(provider, key)
        return nil if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def boolean_option(hash, key, default)
        return default unless hash.key?(key.to_s)

        value = hash.fetch(key.to_s)
        return value if value == true || value == false

        %w[true yes 1].include?(value.to_s.downcase)
      end

      def env_provider_for(kind)
        case kind.to_s
        when "head"
          ENV["MERINGUE_HEAD_HARNESS"] || ENV["MERINGUE_HARNESS"]
        when "worker"
          ENV["MERINGUE_WORKER_HARNESS"] || ENV["MERINGUE_HARNESS"]
        else
          ENV["MERINGUE_HARNESS"]
        end
      end

      def normalize_provider!(provider)
        self.class.normalize_provider!(provider)
      end
    end
  end
end
