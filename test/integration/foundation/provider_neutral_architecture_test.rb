# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# Keeps provider implementations behind the harness/supervisor integration boundary.
# Generic orchestration and presentation code may carry a harness name as data, but it
# must not read Pi's classes, RPC state shape, or retired provider-specific defaults.
class FoundationProviderNeutralArchitectureTest < Minitest::Test
  GENERIC_RUNTIME_GLOBS = %w[
    lib/meringue/kernel/**/*.rb
    lib/meringue/heads/**/*.rb
    lib/meringue/input/**/*.rb
    lib/meringue/tui/**/*.rb
    lib/meringue/workspace/**/*.rb
    lib/meringue/subprocess_environment.rb
    lib/meringue/supervisor/service.rb
    lib/meringue/supervisor/transport_adapter.rb
  ].freeze

  FORBIDDEN_PROVIDER_INTERNALS = {
    /\bPiClient\b/ => "Pi client class",
    /\bPiSessionView\b/ => "Pi session-view class",
    /\bPiAdapter\b/ => "Pi supervisor adapter",
    /["']pi_state["']/ => "Pi RPC state field",
    /["']pi_session_defaults["']/ => "retired Pi defaults field",
    /["']contextUtilization["']/ => "Pi context-usage field"
  }.freeze

  def test_generic_runtime_does_not_depend_on_pi_implementation_shapes
    offenders = generic_runtime_files.flat_map do |path|
      source = File.read(path)
      FORBIDDEN_PROVIDER_INTERNALS.filter_map do |pattern, description|
        next unless source.match?(pattern)

        "#{relative_path(path)} references #{description}"
      end
    end

    assert_empty offenders, "provider-specific internals crossed the harness boundary:\n#{offenders.join("\n")}"
  end

  private

  def generic_runtime_files
    GENERIC_RUNTIME_GLOBS.flat_map do |glob|
      Dir[FoundationSupport.repo_path(*glob.split("/"))]
    end.uniq.sort
  end

  def relative_path(path)
    path.delete_prefix("#{FoundationSupport::REPO_ROOT}/")
  end
end
