# frozen_string_literal: true

require "fileutils"
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
      DEFAULT_PI_HEAD_EXTRA_ARGS = [
        "--thinking", "high",
        "--tools", "read,bash,grep,find,ls",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-approve"
      ].freeze
      DEFAULT_PI_WORKER_EXTRA_ARGS = [
        "--thinking", "high",
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

      private

      def build_client(provider:, kind:)
        provider = normalize_provider!(provider)
        provider_config = provider_config(provider)
        extra_args = extra_args_for(provider_config, kind)
        env = env_for(provider_config)
        command = command_argv(provider_config.fetch("command"))

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

      def extra_args_for(provider_config, kind)
        Array(provider_config["extra_args"]) + Array(provider_config["#{kind}_extra_args"])
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
