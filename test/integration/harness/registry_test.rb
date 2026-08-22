# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The registry is how the kernel picks a harness by name. It must resolve
# defaults, aliases, and unknown names without ever constructing a client that
# writes outside the configured session directory.
class HarnessRegistryTest < HarnessIntegrationTest
  Registry = Meringue::Harness::Registry

  def setup
    super
    # Harness selection reads the environment first; pin it for determinism.
    with_env("MERINGUE_HARNESS" => nil, "MERINGUE_HEAD_HARNESS" => nil, "MERINGUE_WORKER_HARNESS" => nil)
    @session_dir = File.join(tmpdir, "pi-sessions")
  end

  def registry(data = {})
    Registry.new(config: build_config(deep_merge_defaults(data)))
  end

  def deep_merge_defaults(data)
    harness = { "pi" => { "session_dir" => @session_dir } }
    Meringue::Config.deep_merge({ "harness" => harness }, data)
  end

  def test_normalize_provider_accepts_documented_aliases
    assert_equal "pi", Registry.normalize_provider("pi")
    # A blank value means "not configured", not "the usual one".
    assert_equal "", Registry.normalize_provider("")
    assert_equal "", Registry.normalize_provider(nil)
    assert_equal "pi", Registry.normalize_provider("  PI ")
    assert_equal "claude", Registry.normalize_provider("Claude Code")
    assert_equal "claude", Registry.normalize_provider("claude-code")
    assert_equal "claude", Registry.normalize_provider("claude_code")
    assert_equal "claude", Registry.normalize_provider("CC")
    assert_equal "antigravity", Registry.normalize_provider("agy")
    assert_equal "antigravity", Registry.normalize_provider("Antigravity CLI")
    assert_equal "codex", Registry.normalize_provider("Codex"), "unknown names normalize but do not resolve"
  end

  def test_normalize_provider_bang_rejects_unknown_harnesses
    Registry::PROVIDERS.each { |provider| assert_equal provider, Registry.normalize_provider!(provider) }

    error = assert_raises(ArgumentError) { Registry.normalize_provider!("codex") }

    assert_match(/Unsupported harness provider "codex"/, error.message)
    assert_match(/pi, claude, antigravity/, error.message)
  end

  def test_split_role_defaults_use_each_active_harness_and_repair_incompatible_effort_values
    subject = registry(
      "experiments" => { "split_defaults" => true },
      "harness" => {
        "head_provider" => "claude",
        "worker_provider" => "pi",
        "model" => "anthropic/shared",
        "thinking_level" => "off",
        "head_thinking_level" => "low",
        "worker_thinking_level" => "xhigh"
      }
    )

    defaults = subject.session_defaults

    assert_equal "mixed", defaults.fetch("harness")
    assert_equal "claude", defaults.dig("role_harnesses", "head")
    assert_equal "pi", defaults.dig("role_harnesses", "worker")
    assert_equal "low", defaults.dig("roles", "head", "thinking_level")
    assert_equal "xhigh", defaults.dig("roles", "worker", "thinking_level")
    # A Claude-only explicit value is repaired to its provider fallback without affecting Pi.
    claude = registry("harness" => { "provider" => "claude", "thinking_level" => "off" }).session_defaults
    assert_equal Registry::DEFAULT_THINKING_LEVEL, claude.fetch("thinking_level")
  end

  def test_provider_metadata_is_public_facing
    assert_equal %w[pi claude antigravity], Registry.supported_provider_names
    assert_equal "Pi", Registry.provider_label("pi")
    assert_equal "Claude Code", Registry.provider_label("cc")
    assert_equal "Antigravity CLI", Registry.provider_label("agy")
    assert_equal "codex", Registry.provider_label("codex")
    assert_equal "claude", Registry.public_provider_name("claude-code")

    choices = Registry.provider_choices
    assert_equal %w[pi claude antigravity], choices.map { |choice| choice.fetch("provider") }
    assert_equal %w[pi claude antigravity], choices.map { |choice| choice.fetch("internal_provider") }
    assert_equal ["Pi", "Claude Code", "Antigravity CLI"], choices.map { |choice| choice.fetch("label") }
    assert(choices.all? { |choice| choice.fetch("description").start_with?("Use ") })
  end

  # The TUI asks the registry for a harness logo instead of knowing about Pi or
  # Claude itself, so provider display glyphs live and degrade here.
  def test_provider_glyphs_are_one_cell_wide_and_resolve_through_aliases
    assert_equal "π", Registry.provider_glyph("pi")
    assert_equal "✳", Registry.provider_glyph("claude")
    assert_equal "✳", Registry.provider_glyph("Claude Code")
    assert_equal "✳", Registry.provider_glyph("CC")
    assert_equal "↑", Registry.provider_glyph("antigravity")
    assert_equal "↑", Registry.provider_glyph("agy")

    glyphs = Registry::PROVIDERS.map { |provider| Registry.provider_glyph(provider) }
    assert_equal glyphs.uniq, glyphs, "each shipped provider needs its own mark"
    assert(glyphs.all? { |glyph| glyph.length == 1 }, "a renderer reserves exactly one cell")
  end

  def test_unknown_and_missing_harnesses_degrade_to_plain_ascii
    # An unrecognized provider keeps a stable ASCII initial instead of
    # masquerading as a shipped backend. "fake" is the test/dev harness.
    assert_equal "f", Registry.provider_glyph("fake")
    assert_equal "c", Registry.provider_glyph("codex")
    assert_equal "?", Registry.provider_glyph("!!")

    # A blank harness means nothing was recorded, and renders as unknown rather than as any
    # particular backend.
    assert_equal "", Registry.normalize_provider("")
    assert_equal "?", Registry.provider_glyph("")
    assert_equal "?", Registry.provider_glyph(nil)
    assert_equal "?", Registry.provider_glyph("   ")
    assert_equal 1, Registry::UNKNOWN_PROVIDER_GLYPH.length
  end

  def test_ascii_glyph_mode_is_opt_in_through_the_environment
    refute Registry.ascii_glyphs?

    with_env("MERINGUE_ASCII_GLYPHS" => "1") do
      assert Registry.ascii_glyphs?
      assert_equal "p", Registry.provider_glyph("pi")
      assert_equal "c", Registry.provider_glyph("claude-code")
      assert_equal "a", Registry.provider_glyph("agy")
      assert_equal "?", Registry.provider_glyph(nil)
    end

    with_env("MERINGUE_ASCII_GLYPHS" => "  ") do
      refute Registry.ascii_glyphs?, "a blank value is not opt-in"
      assert_equal "π", Registry.provider_glyph("pi")
    end

    assert_equal "π", Registry.provider_glyph("pi")
  end

  # Meringue supports several backends and picks none of them on its own: silently defaulting
  # would start a different harness than the user believes they configured.
  def test_no_harness_is_assumed_when_none_is_configured
    subject = registry

    assert_nil Registry::DEFAULT_PROVIDER
    refute subject.provider_configured?

    error = assert_raises(Registry::MissingProviderError) { subject.worker_provider }
    assert_includes error.message, "No agent harness is configured"
    Registry.supported_provider_names.each { |name| assert_includes error.message, name }

    assert_raises(Registry::MissingProviderError) { subject.head_provider }
  end

  def test_configured_providers_resolve_per_kind_with_a_shared_fallback
    subject = registry("harness" => { "provider" => "claude" })
    assert_equal "claude", subject.head_provider
    assert_equal "claude", subject.worker_provider

    split = registry("harness" => { "provider" => "claude", "worker_provider" => "agy", "head_provider" => "pi" })
    assert_equal "pi", split.head_provider
    assert_equal "antigravity", split.worker_provider
  end

  def test_environment_overrides_beat_configuration
    with_env("MERINGUE_HARNESS" => "claude-code") do
      subject = registry("harness" => { "provider" => "pi" })
      assert_equal "claude", subject.head_provider
      assert_equal "claude", subject.worker_provider
    end

    with_env("MERINGUE_HARNESS" => "claude", "MERINGUE_WORKER_HARNESS" => "agy") do
      subject = registry
      assert_equal "claude", subject.head_provider
      assert_equal "antigravity", subject.worker_provider
    end
  end

  def test_unknown_configured_provider_is_rejected
    error = assert_raises(ArgumentError) { registry("harness" => { "provider" => "codex" }).worker_provider }

    assert_match(/Unsupported harness provider/, error.message)
  end

  def test_client_for_builds_and_memoizes_one_client_per_provider_and_kind
    # worker_client resolves the configured harness, so this registry names one.
    subject = registry("harness" => { "provider" => "pi" })

    worker = subject.client_for(provider: "pi", kind: "worker")
    head = subject.client_for(provider: "pi", kind: "head")

    assert_kind_of Meringue::Harness::PiClient, worker
    assert_same worker, subject.client_for(provider: "pi", kind: "worker")
    assert_same worker, subject.worker_client
    refute_same worker, head, "head and worker clients carry different argv"
    assert_equal File.expand_path(@session_dir), worker.session_dir
    assert Dir.exist?(@session_dir), "the configured Pi session directory is created on demand"
  end

  def test_pi_clients_get_kind_specific_default_argv
    subject = registry

    worker = subject.client_for(provider: "pi", kind: "worker")
    head = subject.client_for(provider: "pi", kind: "head")

    assert_equal Registry::DEFAULT_PI_WORKER_EXTRA_ARGS, worker.extra_args.first(Registry::DEFAULT_PI_WORKER_EXTRA_ARGS.length)
    assert_equal Registry::DEFAULT_PI_HEAD_EXTRA_ARGS, head.extra_args.first(Registry::DEFAULT_PI_HEAD_EXTRA_ARGS.length)
    assert_includes worker.extra_args.each_cons(2).to_a, ["--tools", "read,bash,grep,find,ls,edit,write"]
    assert_includes head.extra_args.each_cons(2).to_a, ["--tools", "read,bash,grep,find,ls"]
    assert_includes worker.extra_args.each_cons(2).to_a, ["--model", Registry::DEFAULT_MODEL]
    assert_includes worker.extra_args.each_cons(2).to_a, ["--thinking", Registry::DEFAULT_THINKING_LEVEL]
    assert_equal ["pi"], worker.command
  end

  def test_pi_scalar_session_defaults_override_role_argv_for_future_heads_and_workers
    subject = registry(
      "harness" => {
        "pi" => {
          "model" => "openai/gpt-5.6-sol",
          "thinking_level" => "xhigh",
          "head_extra_args" => ["--model", "old/head", "--thinking", "low", "--tools", "read"],
          "worker_extra_args" => ["--model", "old/worker", "--thinking", "medium", "--tools", "write"]
        }
      }
    )

    defaults = subject.session_defaults(provider: "pi")

    assert_equal "openai/gpt-5.6-sol", defaults.fetch("model")
    assert_equal "xhigh", defaults.fetch("thinking_level")
    assert_equal "consistent", defaults.fetch("consistency")
    %w[head worker].each do |kind|
      args = subject.client_for(provider: "pi", kind: kind).extra_args
      assert_equal ["--model", "openai/gpt-5.6-sol"], args.last(4).first(2)
      assert_equal ["--thinking", "xhigh"], args.last(2)
    end
  end

  def test_role_specific_thinking_defaults_override_the_legacy_shared_value
    subject = registry(
      "harness" => {
        "pi" => {
          "thinking_level" => "medium",
          "head_thinking_level" => "low",
          "worker_thinking_level" => "xhigh"
        }
      }
    )

    defaults = subject.session_defaults(provider: "pi")

    assert_nil defaults.fetch("thinking_level")
    assert_equal "low", defaults.dig("roles", "head", "thinking_level")
    assert_equal "xhigh", defaults.dig("roles", "worker", "thinking_level")
    assert_equal "low", subject.client_for(provider: "pi", kind: "head").extra_args.last
    assert_equal "xhigh", subject.client_for(provider: "pi", kind: "worker").extra_args.last
  end

  def test_updating_one_role_reconfigures_future_sessions_without_changing_the_other_role
    subject = registry
    head = subject.client_for(provider: "pi", kind: "head")
    worker = subject.client_for(provider: "pi", kind: "worker")

    defaults = subject.update_session_defaults!(provider: "pi", thinking_level: "low", thinking_role: "head")

    assert_equal "low", defaults.dig("roles", "head", "thinking_level")
    assert_equal Registry::DEFAULT_THINKING_LEVEL, defaults.dig("roles", "worker", "thinking_level")
    assert_equal "low", head.extra_args.last
    assert_includes worker.extra_args.each_cons(2).to_a, ["--thinking", Registry::DEFAULT_THINKING_LEVEL]
    saved = Meringue::Config.load(path: subject.config.path)
    assert_equal "low", saved.value("harness", "pi", "head_thinking_level")
    assert_nil saved.value("harness", "pi", "worker_thinking_level")
  end

  def test_role_specific_model_defaults_override_the_legacy_shared_value
    subject = registry(
      "harness" => {
        "pi" => {
          "model" => "anthropic/claude-opus-5",
          "head_model" => "openai/gpt-5.6-sol",
          "worker_model" => "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
        }
      }
    )

    defaults = subject.session_defaults(provider: "pi")

    assert_nil defaults.fetch("model")
    assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "head", "model")
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", defaults.dig("roles", "worker", "model")
    head_model = subject.client_for(provider: "pi", kind: "head").extra_args.each_cons(2).select { |flag, _v| flag == "--model" }.last
    worker_model = subject.client_for(provider: "pi", kind: "worker").extra_args.each_cons(2).select { |flag, _v| flag == "--model" }.last
    assert_equal "openai/gpt-5.6-sol", head_model[1]
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", worker_model[1]
  end

  def test_updating_one_model_role_reconfigures_future_sessions_without_changing_the_other_role
    subject = registry
    head = subject.client_for(provider: "pi", kind: "head")
    worker = subject.client_for(provider: "pi", kind: "worker")

    defaults = subject.update_session_defaults!(provider: "pi", model: "openai/gpt-5.6-sol", model_role: "head")

    assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "head", "model")
    assert_equal Registry::DEFAULT_MODEL, defaults.dig("roles", "worker", "model")
    assert_equal "openai/gpt-5.6-sol", head.extra_args.each_cons(2).select { |flag, _v| flag == "--model" }.last[1]
    assert_equal Registry::DEFAULT_MODEL, worker.extra_args.each_cons(2).select { |flag, _v| flag == "--model" }.last[1]
    saved = Meringue::Config.load(path: subject.config.path)
    assert_equal "openai/gpt-5.6-sol", saved.value("harness", "pi", "head_model")
    assert_nil saved.value("harness", "pi", "worker_model")
  end

  def test_updating_pi_session_defaults_persists_and_reconfigures_cached_clients_in_place
    subject = registry
    head = subject.client_for(provider: "pi", kind: "head")
    worker = subject.client_for(provider: "pi", kind: "worker")

    defaults = subject.update_session_defaults!(
      provider: "pi",
      model: "openai/gpt-5.6-sol",
      thinking_level: "xhigh"
    )

    assert_same head, subject.client_for(provider: "pi", kind: "head")
    assert_same worker, subject.client_for(provider: "pi", kind: "worker")
    assert_equal "openai/gpt-5.6-sol", defaults.fetch("model")
    assert_equal "xhigh", defaults.fetch("thinking_level")
    assert_equal ["--model", "openai/gpt-5.6-sol", "--thinking", "xhigh"], worker.extra_args.last(4)
    saved = Meringue::Config.load(path: subject.config.path)
    assert_equal "openai/gpt-5.6-sol", saved.value("harness", "pi", "model")
    assert_equal "xhigh", saved.value("harness", "pi", "thinking_level")
  end

  def test_role_specific_pi_argv_is_reported_as_mixed_until_scalar_defaults_are_set
    subject = registry(
      "harness" => {
        "pi" => {
          "head_extra_args" => ["--model", "anthropic/head", "--thinking", "high"],
          "worker_extra_args" => ["--model", "openai/worker", "--thinking", "xhigh"]
        }
      }
    )

    defaults = subject.session_defaults(provider: "pi")

    # Both roles resolve to the shipped scalar default, which is what each role's argv ends with,
    # so the pair agrees again even though the role arrays differ.
    assert_equal Registry::DEFAULT_MODEL, defaults.fetch("model")
    assert_equal Registry::DEFAULT_THINKING_LEVEL, defaults.fetch("thinking_level")
    assert_equal "consistent", defaults.fetch("consistency")

    split = registry(
      "harness" => {
        "pi" => { "head_model" => "anthropic/head", "worker_model" => "openai/worker" }
      }
    ).session_defaults(provider: "pi")

    assert_nil split.fetch("model")
    assert_equal "mixed", split.fetch("consistency")
    assert_equal "anthropic/head", split.dig("roles", "head", "model")
    assert_equal "openai/worker", split.dig("roles", "worker", "model")
  end

  def test_worker_command_blacklist_adds_the_enforcement_extension_and_owned_environment
    patterns = ["*gh pr comment *", "*gh api *pulls/*/comments/*/replies*"]
    subject = registry(
      "commands" => { "worker_blacklist" => patterns },
      "harness" => { "pi" => { "env" => { "KEEP_ME" => "yes", Registry::COMMAND_BLACKLIST_ENV => "untrusted" } } }
    )

    worker = subject.client_for(provider: "pi", kind: "worker")
    head = subject.client_for(provider: "pi", kind: "head")

    assert_includes worker.extra_args.each_cons(2).to_a,
                    ["--extension", Registry::COMMAND_BLACKLIST_EXTENSION]
    assert_equal patterns, JSON.parse(worker.env.fetch(Registry::COMMAND_BLACKLIST_ENV))
    assert_equal "yes", worker.env.fetch("KEEP_ME")
    refute_includes head.extra_args, Registry::COMMAND_BLACKLIST_EXTENSION
    refute head.env.key?(Registry::COMMAND_BLACKLIST_ENV)
  end

  def test_configured_blacklist_fails_closed_for_worker_providers_without_enforcement
    subject = registry(
      "commands" => { "worker_blacklist" => ["*gh pr comment *"] },
      "harness" => { "worker_provider" => "claude" }
    )

    error = assert_raises(ArgumentError) { subject.worker_client }

    assert_includes error.message, "cannot be enforced by Claude Code"
    assert_includes error.message, "use Pi or remove the blacklist"
  end

  def test_invalid_blacklist_configuration_is_rejected_when_the_registry_loads
    error = assert_raises(Meringue::CommandBlacklist::ConfigurationError) do
      registry("commands" => { "worker_blacklist" => "*gh pr comment *" })
    end

    assert_includes error.message, "must be an array of glob strings"
  end

  def test_client_for_builds_claude_and_antigravity_clients
    subject = registry(
      "harness" => {
        "claude" => { "command" => "claude --beta", "env" => { "CLAUDE_TOKEN" => "x" } },
        "antigravity" => { "command" => ["agy", "--flag"], "extra_args" => ["--shared"] }
      }
    )

    claude = subject.client_for(provider: "claude-code", kind: "head")
    antigravity = subject.client_for(provider: "agy", kind: "worker")

    assert_kind_of Meringue::Harness::ClaudeInteractiveClient, claude
    assert_equal ["claude", "--beta"], claude.command
    assert_equal({ "CLAUDE_TOKEN" => "x" }, claude.env)
    assert claude.live_terminal_supported?, "Claude Code is driven through its own interactive session"
    assert_kind_of Meringue::Harness::AntigravityClient, antigravity
    assert_equal ["agy", "--flag"], antigravity.command
    assert_equal ["--shared"], antigravity.extra_args
  end

  def test_client_for_rejects_unknown_providers
    assert_raises(ArgumentError) { registry.client_for(provider: "codex", kind: "worker") }
  end

  def test_client_for_agent_follows_the_agent_record
    subject = registry("harness" => { "provider" => "pi" })

    claude_worker = subject.client_for_agent("harness" => "claude", "type" => "worker")
    pi_head = subject.client_for_agent("harness" => "pi", "type" => "head")
    defaulted = subject.client_for_agent("id" => "P1-I1-W1")

    assert_kind_of Meringue::Harness::ClaudeInteractiveClient, claude_worker
    assert_kind_of Meringue::Harness::PiClient, pi_head
    assert_same subject.worker_client, defaulted
  end

  def test_head_runner_is_the_same_runner_for_every_backend
    subject = registry("harness" => { "provider" => "pi" })

    runners = {
      "pi" => subject.head_runner_for(provider: "pi", cwd: tmpdir),
      "claude" => subject.head_runner_for(provider: "claude", cwd: tmpdir),
      "antigravity" => subject.head_runner_for(provider: "antigravity", cwd: tmpdir)
    }

    runners.each_value { |runner| assert_kind_of Meringue::Heads::AgentRunner, runner }
    assert_kind_of Meringue::Harness::PiClient, runners.fetch("pi").harness_client
    assert_kind_of Meringue::Harness::ClaudeInteractiveClient, runners.fetch("claude").harness_client
    assert_kind_of Meringue::Heads::AgentRunner, subject.head_runner(cwd: tmpdir)
    assert_raises(ArgumentError) { subject.head_runner_for(provider: "codex", cwd: tmpdir) }
  end

  # An interactive backend boots a whole agent CLI before it can answer, so it is allowed longer
  # than a backend that starts answering immediately.
  def test_head_timeout_follows_how_the_backend_runs
    subject = registry

    interactive = subject.head_runner_for(provider: "claude", cwd: tmpdir)
    managed = subject.head_runner_for(provider: "pi", cwd: tmpdir)

    assert_operator interactive.timeout, :>, managed.timeout
  end

  def test_head_runner_honours_configured_session_name_prefix_and_timeout
    subject = registry(
      "harness" => { "claude" => { "head_session_name_prefix" => "Meringue Planner", "head_timeout" => "45" } }
    )

    runner = subject.head_runner_for(provider: "claude", cwd: tmpdir)

    assert_equal "Meringue Planner", runner.session_name_prefix
    assert_equal 45, runner.timeout
  end

  def test_provider_command_is_exposed_for_terminal_launching
    subject = registry("harness" => { "antigravity" => { "command" => %w[agy --flag] } })

    assert_equal "pi", subject.provider_command("pi")
    assert_equal "claude", subject.provider_command("claude")
    assert_equal "agy --flag", subject.provider_command("antigravity")
  end

  def test_terminal_session_opener_is_built_from_configuration
    subject = registry(
      "harness" => { "pi" => { "command" => "pi-dev" } },
      "terminal" => { "alacritty_command" => File.join(tmpdir, "alacritty") }
    )

    opener = subject.terminal_session_opener

    assert_kind_of Meringue::Harness::TerminalSessionOpener, opener
    assert_equal "pi-dev", opener.send(:command_parts, "pi").first
    assert_equal File.expand_path(@session_dir), File.expand_path(opener.send(:session_dir))
  end

  def test_public_provider_names_are_used_for_configuration_sections
    subject = registry("harness" => { "claude" => { "command" => "legacy" }, "pi" => { "command" => "public-pi" } })

    assert_equal ["public-pi"], subject.client_for(provider: "pi", kind: "worker").command
    assert_equal ["legacy"], subject.client_for(provider: "claude", kind: "worker").command
  end
end
