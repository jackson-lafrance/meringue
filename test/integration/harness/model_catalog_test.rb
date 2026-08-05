# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# Covers harness-neutral model catalog discovery: the value object, Pi's
# authoritative `get_available_models` probe, and the registry seam other
# harnesses will plug into. Everything runs against the scripted Pi RPC stub, so
# no real harness process, network call, or user config is involved.
class HarnessModelCatalogTest < HarnessIntegrationTest
  Catalog = Meringue::Harness::ModelCatalog

  def test_catalog_normalizes_entries_and_exposes_lookups
    catalog = Catalog.available(
      harness: "pi",
      models: [
        { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5",
          "thinking_levels" => %w[XHIGH max], "reasoning" => true, "contextWindow" => 1_000_000 },
        { provider: "openai", id: "gpt-5.6-sol", thinking_levels: ["high"] },
        { "provider" => "anthropic", "id" => "claude-opus-5" },
        { "id" => "no-provider" },
        "not-a-model"
      ],
      source: "test"
    )

    assert catalog.available?
    assert_equal %w[anthropic/claude-opus-5 openai/gpt-5.6-sol], catalog.references
    assert_equal 2, catalog.model_count
    assert_equal %w[xhigh max], catalog.thinking_levels_for("anthropic/claude-opus-5")
    assert_equal %w[xhigh max], catalog.thinking_levels_for("ANTHROPIC/claude-opus-5")
    assert_nil catalog.thinking_levels_for("anthropic/missing")
    assert_equal 1_000_000, catalog.entry_for("anthropic/claude-opus-5").fetch("context_window")
    assert_equal "available", catalog.to_h.fetch("availability")
  end

  def test_empty_and_failed_catalogs_stay_explicit_instead_of_pretending_to_be_available
    empty = Catalog.available(harness: "pi", models: [], source: "test")
    refute empty.available?
    assert_equal Catalog::UNAVAILABLE, empty.availability
    assert_equal Catalog::EMPTY_CATALOG_REASON, empty.reason
    assert_includes empty.note, "no available models"

    failed = Catalog.unavailable(harness: "pi", note: "pi exited", reason: "fetch_failed", error: "Errno::ENOENT")
    refute failed.available?
    assert_equal "fetch_failed", failed.reason
    assert_equal "Errno::ENOENT", failed.to_h.fetch("error")

    unsupported = Catalog.unsupported(harness: "claude")
    assert unsupported.unsupported?
    assert_includes unsupported.note, "does not expose a model catalog"
    assert_empty unsupported.models
  end

  # A harness hiccup must never shrink a working list: that is what makes the
  # selector look like it only ever knew a couple of models.
  def test_a_failed_refresh_retains_the_last_confirmed_models_as_stale
    previous = Catalog.available(
      harness: "pi",
      models: [
        { "provider" => "anthropic", "id" => "claude-opus-5", "thinking_levels" => %w[xhigh max] },
        { "provider" => "openai", "id" => "gpt-5.6-sol", "thinking_levels" => %w[low high] },
        { "provider" => "google", "id" => "gemini-3-flash", "thinking_levels" => ["off"] }
      ],
      source: "pi_rpc_get_available_models",
      fetched_at: "2026-01-01T00:00:00Z"
    )
    failure = Catalog.unavailable(harness: "pi", note: "connection reset", reason: "fetch_failed", error: "RpcError")

    retained = Catalog.retained(previous: previous, failure: failure, last_attempt_at: "2026-01-01T00:10:00Z")

    assert_equal Catalog::STALE, retained.availability
    assert retained.stale?
    assert retained.usable?, "a retained list must still be offerable"
    refute retained.available?, "a retained list must not claim to be freshly confirmed"
    assert_equal previous.references, retained.references
    assert_equal 3, retained.model_count
    assert_equal %w[xhigh max], retained.thinking_levels_for("anthropic/claude-opus-5")
    # The confirmed timestamp survives; the failed attempt is recorded separately.
    assert_equal "2026-01-01T00:00:00Z", retained.fetched_at
    assert_equal "2026-01-01T00:10:00Z", retained.last_attempt_at
    assert_equal "connection reset", retained.note
    assert_equal "fetch_failed", retained.reason
    assert_equal "RpcError", retained.last_error
    assert_equal 600.0, retained.age_seconds(now: Time.iso8601("2026-01-01T00:10:00Z"))
    assert_equal 0.0, retained.attempt_age_seconds(now: Time.iso8601("2026-01-01T00:10:00Z"))

    # Nothing to retain: the failure is reported as-is instead of inventing models.
    empty_previous = Catalog.unavailable(harness: "pi", note: "never fetched", reason: "fetch_failed")
    assert_equal failure.to_h, Catalog.retained(previous: empty_previous, failure: failure).to_h
    refute Catalog.retained(previous: nil, failure: failure).usable?
  end

  def test_catalog_round_trips_through_persisted_snapshots
    original = Catalog.available(
      harness: "pi",
      models: [{ "provider" => "openai", "id" => "gpt-5.6-sol", "thinking_levels" => %w[low high] }],
      source: "test"
    )
    restored = Catalog.coerce(JSON.parse(JSON.generate(original.to_h)))

    assert_equal original.to_h, restored.to_h
    assert_equal %w[low high], restored.thinking_levels_for("openai/gpt-5.6-sol")

    missing = Catalog.coerce(nil, harness: "pi")
    assert missing.unsupported?
    assert_includes missing.note, "has been fetched yet"

    stale = Catalog.retained(
      previous: original,
      failure: Catalog.unavailable(harness: "pi", note: "blip", reason: "fetch_failed"),
      last_attempt_at: "2026-02-02T00:00:00Z"
    )
    restored_stale = Catalog.coerce(JSON.parse(JSON.generate(stale.to_h)))
    assert restored_stale.stale?
    assert restored_stale.usable?
    assert_equal stale.references, restored_stale.references
    assert_equal "2026-02-02T00:00:00Z", restored_stale.last_attempt_at
  end

  def test_catalog_age_is_measured_from_its_fetch_timestamp
    catalog = Catalog.available(
      harness: "pi",
      models: [{ "provider" => "openai", "id" => "gpt-5.6-sol" }],
      source: "test",
      fetched_at: "2026-01-01T00:00:00Z"
    )

    assert_in_delta 60.0, catalog.age_seconds(now: Time.iso8601("2026-01-01T00:01:00Z")), 0.001
    assert_nil Catalog.from_h("harness" => "pi", "availability" => "unavailable", "fetched_at" => "not-a-time").age_seconds
  end

  def test_pi_client_reads_the_catalog_from_pi_and_derives_supported_thinking_levels
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {
        "available_models" => [
          { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5", "reasoning" => true,
            "contextWindow" => 1_000_000, "maxTokens" => 128_000,
            "thinkingLevelMap" => { "xhigh" => "xhigh", "max" => "max" } },
          { "provider" => "anthropic", "id" => "claude-fable-5", "name" => "Claude Fable 5", "reasoning" => true,
            "thinkingLevelMap" => { "off" => nil, "xhigh" => "xhigh", "max" => "max" } },
          { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol", "reasoning" => true },
          { "provider" => "google", "id" => "gemini-3-flash", "name" => "Gemini 3 Flash", "reasoning" => false }
        ]
      }
    )

    assert client.model_catalog_supported?
    catalog = client.available_models(cwd: tmpdir)

    assert catalog.available?, catalog.to_h.inspect
    assert_equal "pi", catalog.harness
    assert_equal Meringue::Harness::PiClient::MODEL_CATALOG_SOURCE, catalog.source
    assert_equal(
      %w[anthropic/claude-opus-5 anthropic/claude-fable-5 openai/gpt-5.6-sol google/gemini-3-flash],
      catalog.references
    )
    # Pi only offers xhigh/max when a model maps them, hides levels mapped to
    # null, and reports ["off"] for a model without reasoning.
    assert_equal %w[off minimal low medium high xhigh max], catalog.thinking_levels_for("anthropic/claude-opus-5")
    assert_equal %w[minimal low medium high xhigh max], catalog.thinking_levels_for("anthropic/claude-fable-5")
    assert_equal %w[off minimal low medium high], catalog.thinking_levels_for("openai/gpt-5.6-sol")
    assert_equal ["off"], catalog.thinking_levels_for("google/gemini-3-flash")
    assert_equal 128_000, catalog.entry_for("anthropic/claude-opus-5").fetch("max_tokens")
    assert_equal ["get_available_models"], stub_commands(stub).map { |command| command.fetch("type") }
  end

  # A model's advertised levels explain what Pi will run, they are not permission
  # to choose: Pi clamps an unlisted level (up the ladder first, then down)
  # instead of failing, and a provider extension can under-declare what its model
  # really supports. Meringue mirrors that rule so its surfaces can say "max
  # clamps to xhigh" instead of hiding max.
  def test_pi_clamping_mirrors_pis_own_rule_for_levels_a_model_does_not_advertise
    proxy_levels = %w[off minimal low medium high xhigh]

    assert_equal "xhigh", Meringue::Harness::PiClient.clamp_thinking_level("max", proxy_levels)
    assert_equal "xhigh", Meringue::Harness::PiClient.clamp_thinking_level("XHIGH", proxy_levels)
    # Nothing above the request is available, so the search falls back downward.
    assert_equal "low", Meringue::Harness::PiClient.clamp_thinking_level("high", %w[off minimal low])
    # A non-reasoning model reports only "off".
    assert_equal "off", Meringue::Harness::PiClient.clamp_thinking_level("max", ["off"])
    # Degrades instead of raising when the catalog knows nothing.
    assert_equal "off", Meringue::Harness::PiClient.clamp_thinking_level("max", [])
    assert_equal "minimal", Meringue::Harness::PiClient.clamp_thinking_level("ultra", %w[minimal high])
  end

  def test_catalog_probe_is_ephemeral_and_drops_spawn_only_model_defaults
    client, stub = build_pi_client(
      tmpdir,
      stub_config: {},
      extra_args: ["--model", "anthropic/claude-opus-5", "--thinking", "max", "--extension", "/tmp/provider-ext", "--tools", "read"]
    )

    catalog = client.available_models(cwd: tmpdir)
    argv = stub_argv(stub)

    assert catalog.available?
    assert_includes argv.each_cons(2).to_a, %w[--mode rpc]
    assert_includes argv, "--no-session"
    refute_includes argv, "--session-dir"
    # Resource flags stay so the listed models match what a real spawn can use.
    assert_includes argv.each_cons(2).to_a, ["--extension", "/tmp/provider-ext"]
    assert_includes argv.each_cons(2).to_a, %w[--tools read]
    # Spawn-only defaults are dropped: an unavailable saved default must not stop
    # Pi from answering which models exist.
    refute_includes argv, "--model"
    refute_includes argv, "--thinking"
    assert_empty Dir[File.join(tmpdir, "pi-sessions", "*.jsonl")]
  end

  def test_catalog_failures_degrade_without_raising
    failing_client, = build_pi_client(tmpdir, stub_config: { "fail_commands" => { "get_available_models" => "no provider configured" } })
    failed = failing_client.available_models(cwd: tmpdir)

    refute failed.available?
    assert_equal Meringue::Harness::ModelCatalog::UNAVAILABLE, failed.availability
    assert_equal "fetch_failed", failed.reason
    assert_includes failed.note, "no provider configured"

    missing_binary = Meringue::Harness::PiClient.new(
      command: [File.join(tmpdir, "definitely-not-installed-pi")],
      session_dir: File.join(tmpdir, "pi-sessions"),
      command_timeout: 5,
      shutdown_timeout: 1,
      transport_ownership: build_transport_ownership(tmpdir)
    )
    unavailable = missing_binary.available_models(cwd: tmpdir)

    refute unavailable.available?
    assert_includes unavailable.note, "Could not read Pi's model catalog"

    empty_catalog = build_pi_client(tmpdir, stub_config: { "available_models" => [] }).first.available_models(cwd: tmpdir)
    refute empty_catalog.available?
    assert_equal Meringue::Harness::ModelCatalog::EMPTY_CATALOG_REASON, empty_catalog.reason
  end

  def test_registry_serves_pi_catalogs_and_reports_other_harnesses_as_unsupported
    stub = write_pi_stub(tmpdir, default_stub_paths(tmpdir, {}, prefix: "registry-pi"))
    config = build_config(
      {
        "harness" => {
          "provider" => "pi",
          "pi" => {
            "command" => stub.fetch("command"),
            "session_dir" => File.join(tmpdir, "pi-sessions"),
            "env" => stub.fetch("env"),
            "worker_extra_args" => []
          },
          "claude" => { "command" => [File.join(tmpdir, "claude-not-real")] }
        }
      }
    )
    registry = Meringue::Harness::Registry.new(config: config)

    pi_catalog = registry.model_catalog(provider: "pi", cwd: tmpdir)
    assert pi_catalog.available?, pi_catalog.to_h.inspect
    assert_equal "pi", pi_catalog.harness
    assert_includes pi_catalog.references, "anthropic/claude-opus-5"

    claude_catalog = registry.model_catalog(provider: "claude", cwd: tmpdir)
    assert claude_catalog.unsupported?
    assert_equal "claude", claude_catalog.harness

    assert_raises(ArgumentError) { registry.model_catalog(provider: "codex") }
  end

  def test_unsupported_clients_answer_with_an_explicit_catalog_instead_of_raising
    client = Class.new(Meringue::Harness::Client) do
      def harness_name
        "codex"
      end
    end.new

    refute client.model_catalog_supported?
    catalog = client.available_models

    assert catalog.unsupported?
    assert_equal "codex", catalog.harness
    assert_includes catalog.note, "codex"
  end
end
