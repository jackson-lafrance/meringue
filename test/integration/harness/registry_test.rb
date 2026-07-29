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
    assert_equal "pi", Registry.normalize_provider("")
    assert_equal "pi", Registry.normalize_provider(nil)
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

  def test_default_provider_is_pi
    subject = registry

    assert_equal "pi", Registry::DEFAULT_PROVIDER
    assert_equal "pi", subject.head_provider
    assert_equal "pi", subject.worker_provider
    assert_equal "pi", subject.provider_for("anything-else")
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
    subject = registry

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

    assert_equal Registry::DEFAULT_PI_WORKER_EXTRA_ARGS, worker.extra_args
    assert_equal Registry::DEFAULT_PI_HEAD_EXTRA_ARGS, head.extra_args
    assert_includes worker.extra_args.each_cons(2).to_a, ["--tools", "read,bash,grep,find,ls,edit,write"]
    assert_includes head.extra_args.each_cons(2).to_a, ["--tools", "read,bash,grep,find,ls"]
    assert_includes worker.extra_args.each_cons(2).to_a, ["--model", Registry::DEFAULT_PI_MODEL]
    assert_includes worker.extra_args.each_cons(2).to_a, ["--thinking", Registry::DEFAULT_PI_THINKING_LEVEL]
    assert_equal ["pi"], worker.command
  end

  def test_client_for_builds_claude_and_antigravity_clients
    subject = registry(
      "harness" => {
        "claude" => { "command" => "claude --beta", "env" => { "CLAUDE_TOKEN" => "x" }, "use_json_schema" => "false" },
        "antigravity" => { "command" => ["agy", "--flag"], "extra_args" => ["--shared"] }
      }
    )

    claude = subject.client_for(provider: "claude-code", kind: "head")
    antigravity = subject.client_for(provider: "agy", kind: "worker")

    assert_kind_of Meringue::Harness::ClaudeCodeClient, claude
    assert_equal ["claude", "--beta"], claude.command
    assert_equal({ "CLAUDE_TOKEN" => "x" }, claude.env)
    assert_equal false, claude.use_json_schema
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

    assert_kind_of Meringue::Harness::ClaudeCodeClient, claude_worker
    assert_kind_of Meringue::Harness::PiClient, pi_head
    assert_same subject.worker_client, defaulted
  end

  def test_head_runner_selection_per_provider
    subject = registry

    pi_runner = subject.head_runner_for(provider: "pi", cwd: tmpdir)
    claude_runner = subject.head_runner_for(provider: "claude", cwd: tmpdir)
    agy_runner = subject.head_runner_for(provider: "antigravity", cwd: tmpdir)

    assert_kind_of Meringue::Heads::PiRunner, pi_runner
    assert_kind_of Meringue::Heads::HarnessRunner, claude_runner
    refute_kind_of Meringue::Heads::PiRunner, claude_runner
    assert_kind_of Meringue::Heads::HarnessRunner, agy_runner
    assert_kind_of Meringue::Heads::PiRunner, subject.head_runner(cwd: tmpdir)
    assert_raises(ArgumentError) { subject.head_runner_for(provider: "codex", cwd: tmpdir) }
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
    assert_equal File.expand_path(@session_dir), File.expand_path(opener.send(:pi_session_dir))
  end

  def test_public_provider_names_are_used_for_configuration_sections
    subject = registry("harness" => { "claude" => { "command" => "legacy" }, "pi" => { "command" => "public-pi" } })

    assert_equal ["public-pi"], subject.client_for(provider: "pi", kind: "worker").command
    assert_equal ["legacy"], subject.client_for(provider: "claude", kind: "worker").command
  end
end
