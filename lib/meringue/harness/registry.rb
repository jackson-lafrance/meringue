# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module Meringue
  module Harness
    class Registry
      # Raised when nothing says which agent harness to run. Meringue supports several and does not
      # guess: silently defaulting would start a different backend than the user believes they
      # configured, which is worse than saying so.
      class MissingProviderError < ArgumentError; end

      # Deliberately absent. Meringue is harness-agnostic, so there is no backend it falls back to.
      DEFAULT_PROVIDER = nil
      PROVIDERS = %w[pi claude antigravity].freeze
      # How each backend spells a model and a reasoning level on its own command line, and whether
      # it wants a bare model id or a qualified `provider/model` reference. This is the whole of
      # what the registry needs to know about a provider's session defaults; there is no branch on
      # provider name anywhere below.
      # Config keys under a provider's section that carry its model and reasoning defaults.
      SESSION_DEFAULT_KEYS = %w[
        model head_model worker_model
        thinking_level head_thinking_level worker_thinking_level
      ].freeze
      PROVIDER_SESSION_FLAGS = {
        "pi" => { "model" => "--model", "thinking_level" => "--thinking", "qualified_model" => true },
        # Claude Code is single-vendor, so it rejects a provider-qualified reference, and it calls
        # the reasoning level "effort".
        "claude" => { "model" => "--model", "thinking_level" => "--effort", "qualified_model" => false },
        "antigravity" => {}
      }.freeze
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
      # Where a harness that stores its own session files keeps them. The directory name is Pi's
      # because the files in it are Pi's; the environment variable is neutral because any backend
      # with the same need reads it.
      DEFAULT_AGENT_SESSION_DIR = File.expand_path(
        ENV.fetch("MERINGUE_AGENT_SESSION_DIR", ENV.fetch("MERINGUE_PI_SESSION_DIR", "~/.meringue/pi-sessions"))
      )
      COMMAND_BLACKLIST_ENV = "MERINGUE_WORKER_COMMAND_BLACKLIST"
      COMMAND_BLACKLIST_EXTENSION = Meringue.root_path("lib", "meringue", "harness", "extensions", "command_blacklist.js")
      # Stored as a qualified "provider/model" reference because a multi-vendor harness has to
      # disambiguate a bare id across providers that all expose the same model. A single-vendor
      # harness is handed the bare id instead (see PROVIDER_SESSION_FLAGS).
      DEFAULT_MODEL = "anthropic/claude-opus-5"
      # The highest reasoning level; Claude Opus 5 supports only xhigh and max.
      DEFAULT_THINKING_LEVEL = "max"
      DEFAULT_PI_HEAD_EXTRA_ARGS = [
        "--tools", "read,bash,grep,find,ls",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-approve"
      ].freeze
      DEFAULT_PI_WORKER_EXTRA_ARGS = [
        "--tools", "read,bash,grep,find,ls,edit,write",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-approve"
      ].freeze
      # Model and reasoning defaults are config values rather than argv, so the registry renders them
      # in each backend's own spelling instead of every backend hard-coding one harness's flags.
      DEFAULT_PROVIDER_CONFIG = {
        "pi" => {
          "command" => "pi",
          "session_dir" => DEFAULT_AGENT_SESSION_DIR,
          "model" => DEFAULT_MODEL,
          "thinking_level" => DEFAULT_THINKING_LEVEL,
          "head_extra_args" => DEFAULT_PI_HEAD_EXTRA_ARGS,
          "worker_extra_args" => DEFAULT_PI_WORKER_EXTRA_ARGS
        },
        "claude" => {
          "command" => "claude",
          "model" => DEFAULT_MODEL,
          "thinking_level" => DEFAULT_THINKING_LEVEL,
          # A head only reads: it inspects the project to decide what to route, and it must not be
          # able to change it. The tool allowlist is what enforces that, so no write tool is
          # reachable regardless of permission mode. Slash commands are disabled so a project's own
          # commands cannot redirect an orchestration decision.
          #
          # Permission prompts are bypassed rather than using plan mode. A head runs unattended, and
          # plan mode ends by asking a human to approve leaving it — a question nobody is there to
          # answer, which would hang the head until its timeout instead of returning a routing
          # decision.
          "head_extra_args" => [
            "--tools", "Read,Glob,Grep",
            "--permission-mode", "bypassPermissions",
            "--disable-slash-commands"
          ],
          # A worker runs unattended in its own worktree, so a permission prompt has nobody to
          # answer it and would stall the worker indefinitely. Bypassing prompts is what makes
          # autonomous work possible; the isolation that makes it safe is the worktree.
          "worker_extra_args" => [
            "--permission-mode", "bypassPermissions"
          ]
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
        return "" if normalized.empty?

        PROVIDER_ALIASES.fetch(normalized, normalized)
      end

      def self.normalize_provider!(provider)
        normalized = normalize_provider(provider)
        return normalized if PROVIDERS.include?(normalized)
        if normalized.empty?
          raise MissingProviderError,
                "No agent harness is configured. Set one with /config (Agent defaults), the [harness] provider setting, " \
                "or MERINGUE_HARNESS. Available harnesses: #{supported_provider_names.join(", ")}."
        end

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

      # Whether a backend accepts a model and a reasoning level at all, so callers can offer those
      # controls only where they do something.
      def self.session_defaults_supported_for?(provider)
        !PROVIDER_SESSION_FLAGS.fetch(normalize_provider(provider), {}).empty?
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
            config.value("harness", "provider")
        )
      end

      # Whether a harness has been chosen at all, for callers that want to offer the choice rather
      # than surface an error.
      def provider_configured?(kind = "worker")
        provider_for(kind)
        true
      rescue MissingProviderError
        false
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

        Heads::AgentRunner.new(
          harness_client: client,
          cwd: cwd,
          session_name_prefix: session_name_prefix,
          timeout: numeric_provider_option(provider, "head_timeout") || default_head_timeout(provider)
        )
      end

      # A head's turn budget depends on how its backend runs, not on which vendor it is: an
      # interactive session boots a full agent CLI before it can answer, where a one-shot print
      # invocation starts answering immediately.
      def default_head_timeout(provider)
        client = client_for(provider: provider, kind: "head")
        return InteractiveClient::DEFAULT_READY_TIMEOUT * 3 if client.is_a?(InteractiveClient)

        ProcessClient::DEFAULT_EVENT_TIMEOUT
      rescue StandardError
        ProcessClient::DEFAULT_EVENT_TIMEOUT
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
          session_dir: provider_config("pi").fetch("session_dir", DEFAULT_AGENT_SESSION_DIR),
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

      # Effective model and reasoning defaults the registry will use the next time it starts a head
      # or a worker on this backend. Role details stay visible when dedicated per-role defaults or
      # older explicit argv values differ.
      def session_defaults(provider: nil)
        provider = resolved_session_defaults_provider(provider)
        # Model and reasoning defaults are harness-neutral, so they can be read and set before a
        # harness has been chosen. Only the rendering into argv needs to know which backend it is
        # for, and that happens when a session actually starts.
        return harness_neutral_session_defaults unless provider
        raise ArgumentError, "#{self.class.provider_label(provider)} does not expose model or reasoning defaults." unless session_defaults_supported?(provider)

        flags = PROVIDER_SESSION_FLAGS.fetch(provider, {})
        provider_settings = provider_config(provider)
        roles = %w[head worker].to_h do |kind|
          args = extra_args_for(provider, provider_settings, kind)
          [kind, {
            "model" => command_option(args, flags["model"]),
            "thinking_level" => command_option(args, flags["thinking_level"])
          }.compact]
        end
        shared_model = roles.values.map { |role| role["model"] }.uniq
        shared_thinking = roles.values.map { |role| role["thinking_level"] }.uniq
        model_agrees = shared_model.length == 1
        thinking_agrees = shared_thinking.length == 1
        {
          "harness" => self.class.public_provider_name(provider),
          "model" => model_agrees ? shared_model.first : nil,
          "thinking_level" => thinking_agrees ? shared_thinking.first : nil,
          "consistency" => model_agrees && thinking_agrees ? "consistent" : "mixed",
          "roles" => roles,
          "scope" => "future_#{self.class.public_provider_name(provider)}_sessions"
        }
      end

      def session_defaults_supported?(provider)
        self.class.session_defaults_supported_for?(normalize_provider!(provider))
      end

      def resolved_session_defaults_provider(provider)
        normalize_provider!(provider || worker_provider)
      rescue MissingProviderError
        nil
      end

      def harness_neutral_session_defaults
        configured = neutral_session_defaults
        roles = %w[head worker].to_h do |kind|
          [kind, {
            "model" => configured["#{kind}_model"] || configured["model"] || DEFAULT_MODEL,
            "thinking_level" => configured["#{kind}_thinking_level"] || configured["thinking_level"] || DEFAULT_THINKING_LEVEL
          }]
        end
        shared_model = roles.values.map { |role| role.fetch("model") }.uniq
        shared_thinking = roles.values.map { |role| role.fetch("thinking_level") }.uniq
        {
          "harness" => nil,
          "model" => shared_model.length == 1 ? shared_model.first : nil,
          "thinking_level" => shared_thinking.length == 1 ? shared_thinking.first : nil,
          "consistency" => shared_model.length == 1 && shared_thinking.length == 1 ? "consistent" : "mixed",
          "roles" => roles,
          "scope" => "future_sessions"
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
        PROVIDERS.each do |provider|
          data.fetch("harness")[provider] = {} unless data.fetch("harness")[provider].is_a?(Hash)
          updated_provider = updated_config.section("harness", provider)
          SESSION_DEFAULT_KEYS.each do |key|
            if updated_provider.key?(key)
              data.fetch("harness").fetch(provider)[key] = Config.deep_copy(updated_provider[key])
            else
              data.fetch("harness").fetch(provider).delete(key)
            end
          end
        end
        @config = Config.new(data, path: updated_config.path, loaded: updated_config.loaded?, file_data: updated_config.to_file_h)
        PROVIDERS.each { |provider| reconfigure_cached_clients!(provider) }
        self
      end

      # Saves the selected values and reconfigures cached Pi clients in place.
      # Existing RPC processes keep their current effective settings; only a
      # later new-session spawn applies the replacement model/thinking argv.
      def update_session_defaults!(provider: nil, model: nil, model_role: nil, thinking_level: nil, thinking_role: nil)
        provider = resolved_session_defaults_provider(provider)
        if provider && !session_defaults_supported?(provider)
          raise ArgumentError, "#{self.class.provider_label(provider)} does not expose model or reasoning defaults."
        end

        saved = Config.save_agent_session_defaults!(
          provider: provider,
          model: model,
          model_role: model_role,
          thinking_level: thinking_level,
          thinking_role: thinking_role,
          path: config.path
        )
        @config = saved
        reconfigure_cached_clients!(provider) if provider
        session_defaults(provider: provider)
      end

      # Cached clients keep serving their existing sessions; only their next spawn picks up the
      # replacement arguments, which is why this reconfigures rather than rebuilds.
      def reconfigure_cached_clients!(provider)
        provider_settings = provider_config(provider)
        @clients.each do |(cached_provider, kind), client|
          next unless cached_provider == provider && client.respond_to?(:configure_spawn_arguments)

          client.configure_spawn_arguments(extra_args_for(provider, provider_settings, kind))
        end
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
          session_dir = File.expand_path(provider_config.fetch("session_dir", DEFAULT_AGENT_SESSION_DIR).to_s)
          FileUtils.mkdir_p(session_dir)
          PiClient.new(command: command, session_dir: session_dir, env: env, extra_args: extra_args)
        when "claude"
          ClaudeInteractiveClient.new(command: command, env: env, extra_args: extra_args)
        when "antigravity"
          AntigravityClient.new(command: command, env: env, extra_args: extra_args)
        else
          raise ArgumentError, "Unsupported harness provider: #{provider.inspect}"
        end
      end

      # Layered most-general to most-specific:
      #
      #   1. the backend's shipped defaults;
      #   2. Meringue's harness-neutral model and reasoning defaults, which follow whichever
      #      backend is selected rather than being tied to one of them;
      #   3. anything set for this backend specifically, which is the only place a value that only
      #      makes sense for one harness belongs.
      def provider_config(provider)
        provider = normalize_provider!(provider)
        defaults = DEFAULT_PROVIDER_CONFIG.fetch(provider, {})
        merged = Config.deep_merge(defaults, neutral_session_defaults)
        legacy_configured = config.section("harness", provider)
        public_configured = config.section("harness", self.class.public_provider_name(provider))
        Config.deep_merge(Config.deep_merge(merged, legacy_configured), public_configured)
      end

      def neutral_session_defaults
        harness = config.section("harness")
        return {} unless harness.is_a?(Hash)

        SESSION_DEFAULT_KEYS.each_with_object({}) do |key, result|
          value = harness[key]
          result[key] = value unless value.nil? || value.to_s.strip.empty?
        end
      end

      # Role arguments plus the configured model and reasoning level, rendered in whatever spelling
      # this backend uses. A backend that exposes neither simply gets its role arguments.
      def extra_args_for(provider, provider_config, kind)
        args = (Array(provider_config["extra_args"]) + Array(provider_config["#{kind}_extra_args"])).dup
        flags = PROVIDER_SESSION_FLAGS.fetch(provider, {})

        model = role_setting(provider_config, kind, "model")
        unless model.empty? || flags["model"].nil?
          args.concat([flags.fetch("model"), flags.fetch("qualified_model", true) ? model : ModelReference.bare_id(model)])
        end

        thinking_level = role_setting(provider_config, kind, "thinking_level")
        args.concat([flags.fetch("thinking_level"), thinking_level]) unless thinking_level.empty? || flags["thinking_level"].nil?

        if kind == "worker" && !@command_blacklist.empty? && provider == "pi"
          args.concat(["--extension", COMMAND_BLACKLIST_EXTENSION])
        end
        args
      end

      # A role-specific value wins over the shared one, so "workers use a bigger model than heads"
      # is expressible without repeating everything else.
      def role_setting(provider_config, kind, key)
        role_key = key == "model" ? "#{kind}_model" : "#{kind}_#{key}"
        value = provider_config[role_key].to_s.strip
        value = provider_config[key].to_s.strip if value.empty?
        value
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
