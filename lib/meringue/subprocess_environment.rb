# frozen_string_literal: true

module Meringue
  # Environment for independent executables launched by Meringue. A process
  # started under `bundle exec` carries Ruby/Bundler hooks intended only for the
  # current interpreter. Passing those hooks to a different Ruby (or to a script
  # with its own Ruby shebang) can load incompatible gems before its first line.
  module SubprocessEnvironment
    RUBY_INJECTION_KEYS = %w[
      RUBYOPT RUBYLIB BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLE_LOCKFILE
      BUNDLER_VERSION BUNDLER_SETUP
    ].freeze
    # Session identity inherited from an enclosing coding harness can make an
    # independent shell or agent process attach to the parent session, disable
    # persistence, or send commands through the wrong transport. The harness
    # registry supplies provider-specific patterns; this utility stays generic.

    module_function

    def clean(base_environment = ENV.to_h)
      # Start from the environment at the call site so deliberate PATH overlays
      # (including hermetic test/provider shims) survive. Bundler's saved original
      # environment predates those overlays and can accidentally launch a real tool.
      environment = base_environment.to_h.dup
      # Assign nil rather than merely deleting: Process.spawn/Open3 apply this
      # environment over the parent and nil explicitly unsets inherited values.
      RUBY_INJECTION_KEYS.each { |key| environment[key] = nil }
      environment
    end

    def clean_agent_session(base_environment = ENV.to_h, session_environment_patterns: [])
      environment = base_environment.to_h.dup
      patterns = Array(session_environment_patterns)
      environment.each_key do |key|
        environment[key] = nil if patterns.any? { |pattern| pattern.match?(key.to_s) }
      end
      environment
    end
  end
end
