# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# Covers the kernel side of harness model catalogs: asking the harness for its
# models, persisting the snapshot other layers complete against, background
# refresh throttling, and explicit degradation when no catalog exists. The Pi RPC
# probe itself is exercised in harness/model_catalog_test.rb, so this slice uses
# an in-process catalog source and stays hermetic.
class KernelCoreModelCatalogTest < Minitest::Test
  include KernelCoreSupport

  # Records every catalog request so throttling and forced refreshes are visible.
  class RecordingCatalogSource
    attr_reader :calls
    attr_accessor :result

    def initialize(result)
      @result = result
      @calls = []
    end

    def call(provider)
      @calls << provider
      @result.respond_to?(:call) ? @result.call(provider) : @result
    end
  end

  def setup
    super
    @catalog_source = RecordingCatalogSource.new(
      ->(provider) { pi_catalog(harness: Meringue::Harness::Registry.public_provider_name(provider)) }
    )
    @engine = build_engine(
      default_harness_provider: "pi",
      model_catalog_provider: ->(provider) { @catalog_source.call(provider) }
    )
  end

  def test_get_model_catalog_asks_the_harness_and_persists_the_snapshot
    result = apply_command("GetModelCatalog")

    assert_accepted(result)
    assert_equal ["pi"], @catalog_source.calls
    assert_equal "pi", result.fetch("target_id")
    assert_equal "available", result.dig("result", "availability")
    assert_equal 3, result.dig("result", "model_count")
    assert_equal(
      %w[anthropic/claude-opus-5 openai/gpt-5.6-sol google/gemini-3-flash],
      result.dig("result", "models").map { |model| model.fetch("reference") }
    )
    assert_includes result.fetch("message"), "3 available models"
    assert_iso8601(result.dig("result", "fetched_at"), "catalog fetched_at")

    persisted = persisted_state.dig("metadata", "harness_model_catalogs", "pi")
    assert_equal result.fetch("result"), persisted
    # The completion layer reads exactly this snapshot.
    assert_equal %w[xhigh max], persisted.fetch("models").first.fetch("thinking_levels")
  end

  def test_cached_snapshots_are_reused_until_a_refresh_is_requested
    apply_command("GetModelCatalog")
    apply_command("GetModelCatalog")

    assert_equal ["pi"], @catalog_source.calls, "a fresh snapshot must not re-probe the harness"

    @catalog_source.result = pi_catalog(
      models: [{ "provider" => "openai", "id" => "gpt-6", "thinking_levels" => %w[high max] }]
    )
    refreshed = apply_command("GetModelCatalog", "refresh" => true)

    assert_accepted(refreshed)
    assert_equal %w[pi pi], @catalog_source.calls
    assert_equal ["openai/gpt-6"], refreshed.dig("result", "models").map { |model| model.fetch("reference") }
    assert_equal(
      ["openai/gpt-6"],
      persisted_state.dig("metadata", "harness_model_catalogs", "pi", "models").map { |model| model.fetch("reference") }
    )
  end

  def test_an_explicit_harness_is_honoured_and_unknown_harnesses_are_rejected
    result = apply_command("GetModelCatalog", "harness" => "claude")

    assert_accepted(result)
    assert_equal ["claude"], @catalog_source.calls
    assert_equal "claude", result.dig("result", "harness")
    refute_nil persisted_state.dig("metadata", "harness_model_catalogs", "claude")
    assert_nil persisted_state.dig("metadata", "harness_model_catalogs", "pi")

    rejection = apply_command("GetModelCatalog", "harness" => "codex")
    assert_rejected(rejection, "Unsupported harness provider")
    assert_equal ["claude"], @catalog_source.calls
  end

  def test_unavailable_and_unsupported_catalogs_are_reported_without_failing
    @catalog_source.result = Meringue::Harness::ModelCatalog.unavailable(
      harness: "pi",
      note: "Could not read Pi's model catalog: pi is not installed",
      reason: "fetch_failed"
    )
    unavailable = apply_command("GetModelCatalog")

    assert_accepted(unavailable)
    assert_equal "unavailable", unavailable.dig("result", "availability")
    assert_includes unavailable.fetch("message"), "pi is not installed"
    assert_empty Array(unavailable.dig("result", "models"))

    @catalog_source.result = ->(_provider) { raise "rpc exploded" }
    raised = apply_command("GetModelCatalog", "refresh" => true)

    assert_accepted(raised)
    assert_equal "unavailable", raised.dig("result", "availability")
    assert_equal "fetch_failed", raised.dig("result", "reason")
    assert_includes raised.fetch("message"), "rpc exploded"

    # An engine with no catalog source at all says so instead of guessing.
    sourceless = build_engine(store: Meringue::State::Store.new(path: File.join(tmp_root, "sourceless.json")))
    sourceless_result = sourceless.apply("type" => "GetModelCatalog", "payload" => {})
    assert_equal "accepted", sourceless_result.fetch("status")
    assert_equal "unsupported", sourceless_result.dig("result", "availability")
    assert_includes sourceless_result.fetch("message"), "no harness model catalog source"
  end

  # Regression: a single failed probe used to replace a full catalog with an empty
  # "unavailable" snapshot, so the selector silently collapsed to the couple of
  # model references Meringue remembered from config and existing sessions.
  def test_a_failed_or_empty_refresh_keeps_the_last_confirmed_model_list
    healthy = apply_command("GetModelCatalog")
    assert_equal 3, healthy.dig("result", "model_count")

    failures = [
      Meringue::Harness::ModelCatalog.unavailable(harness: "pi", note: "connection reset", reason: "fetch_failed", error: "RpcError"),
      Meringue::Harness::ModelCatalog.available(harness: "pi", models: [], source: "probe"),
      ->(_provider) { raise "pi exited while listing models" }
    ]

    failures.each_with_index do |failure, index|
      @catalog_source.result = failure
      result = apply_command("GetModelCatalog", "refresh" => true)

      assert_accepted(result)
      assert_equal "stale", result.dig("result", "availability"), "failure #{index} should retain the list"
      assert_equal 3, result.dig("result", "model_count"), "failure #{index} dropped models"
      assert_equal(
        %w[anthropic/claude-opus-5 openai/gpt-5.6-sol google/gemini-3-flash],
        result.dig("result", "models").map { |model| model.fetch("reference") }
      )
      assert_includes result.fetch("message"), "Showing the last 3 models"
      refute_nil result.dig("result", "last_attempt_at"), "the failed attempt must be recorded"
      persisted = persisted_state.dig("metadata", "harness_model_catalogs", "pi")
      assert_equal 3, persisted.fetch("model_count"), "persisted snapshot must keep the models"
    end

    # Recovery clears the stale marker.
    @catalog_source.result = ->(provider) { pi_catalog(harness: Meringue::Harness::Registry.public_provider_name(provider)) }
    recovered = apply_command("GetModelCatalog", "refresh" => true)
    assert_equal "available", recovered.dig("result", "availability")
    assert_nil recovered.dig("result", "last_attempt_at")
  end

  # A retained list must not make the background pass re-probe the harness every
  # two seconds just because its confirmed timestamp is old.
  def test_a_retained_catalog_is_retried_on_the_failure_cadence_not_every_pass
    apply_command("GetModelCatalog")
    @catalog_source.result = Meringue::Harness::ModelCatalog.unavailable(harness: "pi", note: "blip", reason: "fetch_failed")
    apply_command("GetModelCatalog", "refresh" => true)
    calls_after_failure = @catalog_source.calls.length

    3.times { engine.reconcile_sessions }
    assert_equal calls_after_failure, @catalog_source.calls.length, "a just-attempted stale catalog must not be re-probed"

    rewrite_persisted_state do |state|
      state.dig("metadata", "harness_model_catalogs", "pi")["last_attempt_at"] =
        (Time.now.utc - (Meringue::Kernel::Engine::MODEL_CATALOG_RETRY_INTERVAL_SECONDS + 5)).iso8601
    end
    engine.reconcile_sessions

    assert_equal calls_after_failure + 1, @catalog_source.calls.length
    assert_equal 3, persisted_state.dig("metadata", "harness_model_catalogs", "pi").fetch("model_count")
  end

  def test_reconciliation_refreshes_a_stale_catalog_in_the_background_without_log_noise
    logs_before = persisted_logs.length
    first = engine.reconcile_sessions

    assert_equal "accepted", first.fetch("status")
    assert_equal ["pi"], @catalog_source.calls
    assert_equal true, first.dig("result", "model_catalog_refresh", "changed")
    assert_equal "available", first.dig("result", "model_catalog_refresh", "availability")
    refute_nil persisted_state.dig("metadata", "harness_model_catalogs", "pi")

    second = engine.reconcile_sessions
    assert_equal ["pi"], @catalog_source.calls, "a fresh catalog must not be re-fetched every pass"
    assert_equal false, second.dig("result", "model_catalog_refresh", "changed")

    # Catalog refresh is silent: expected staleness is not a user-visible event.
    assert_equal logs_before, persisted_logs.length

    # An aged snapshot is refreshed again.
    rewrite_persisted_state do |state|
      state.dig("metadata", "harness_model_catalogs", "pi")["fetched_at"] =
        (Time.now.utc - (Meringue::Kernel::Engine::MODEL_CATALOG_REFRESH_INTERVAL_SECONDS + 60)).iso8601
    end
    engine.reconcile_sessions
    assert_equal %w[pi pi], @catalog_source.calls
  end

  def test_reconciliation_skips_catalog_refresh_when_no_source_is_configured
    engine_without_source = build_engine(
      store: Meringue::State::Store.new(path: File.join(tmp_root, "no-source.json")),
      default_harness_provider: "pi"
    )

    result = engine_without_source.reconcile_sessions

    assert_equal "accepted", result.fetch("status")
    assert_equal "no_catalog_source", result.dig("result", "model_catalog_refresh", "skipped")
  end

  def test_models_command_output_is_bounded_and_points_at_completion
    many = (1..40).map { |index| { "provider" => "openai", "id" => "model-#{index}" } }
    @catalog_source.result = pi_catalog(models: many)
    result = apply_command("GetModelCatalog")

    lines = engine.send(:kernel_command_output_lines, [result])

    assert_includes lines, "  harness: pi"
    assert_includes lines, "  availability: available"
    assert_equal Meringue::Kernel::Engine::MODEL_CATALOG_OUTPUT_LIMIT, lines.count { |line| line.include?("openai/model-") }
    assert lines.any? { |line| line.include?("and 10 more") }, lines.inspect
  end

  private

  def pi_catalog(models: nil, harness: "pi")
    Meringue::Harness::ModelCatalog.available(
      harness: harness,
      models: models || [
        { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5",
          "thinking_levels" => %w[xhigh max], "reasoning" => true, "context_window" => 1_000_000 },
        { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol",
          "thinking_levels" => %w[off low medium high], "reasoning" => true },
        { "provider" => "google", "id" => "gemini-3-flash", "name" => "Gemini 3 Flash",
          "thinking_levels" => ["off"], "reasoning" => false }
      ],
      source: "test_catalog_source"
    )
  end
end
