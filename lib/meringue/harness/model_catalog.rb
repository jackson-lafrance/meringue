# frozen_string_literal: true

require "time"

require_relative "model_reference"

module Meringue
  module Harness
    # Harness-neutral snapshot of the models a harness reports it can actually
    # use, plus explicit metadata for the cases where no catalog exists.
    #
    # Meringue never hand-maintains a model list: a provider client asks its
    # harness and normalizes the answer
    # into these entries. Providers that cannot answer yet return an
    # `unsupported` catalog, and a failed fetch returns an `unavailable`
    # catalog, so the UI can say why the list is missing instead of silently
    # offering a couple of remembered values.
    class ModelCatalog
      # The reasoning-effort ladder Meringue speaks, ordered weakest to strongest. It lives here
      # rather than inside one backend because it is the vocabulary every harness is translated
      # into: each client renders it in whatever flag its own CLI uses.
      THINKING_LEVELS = %w[off minimal low medium high xhigh max].freeze
      AVAILABLE = "available"
      # A previously confirmed list whose latest refresh failed. The models are
      # still the harness's own answer, just older than we would like, so they
      # stay listed instead of collapsing back to whatever Meringue remembers.
      STALE = "stale"
      UNAVAILABLE = "unavailable"
      UNSUPPORTED = "unsupported"
      EMPTY_CATALOG_REASON = "empty_catalog"

      ENTRY_KEYS = %w[reference provider id name thinking_levels reasoning context_window max_tokens].freeze

      attr_reader :harness, :availability, :models, :note, :reason, :source, :fetched_at, :error,
                  :last_attempt_at, :last_error

      class << self
        def available(harness:, models:, source: nil, fetched_at: nil)
          entries = normalize_entries(models)
          if entries.empty?
            return unavailable(
              harness: harness,
              note: "#{harness} reported no available models. Check provider auth and model configuration.",
              source: source,
              reason: EMPTY_CATALOG_REASON,
              fetched_at: fetched_at
            )
          end

          new(
            harness: harness,
            availability: AVAILABLE,
            models: entries,
            source: source,
            fetched_at: fetched_at
          )
        end

        def unavailable(harness:, note:, source: nil, reason: nil, error: nil, fetched_at: nil)
          new(
            harness: harness,
            availability: UNAVAILABLE,
            models: [],
            note: note,
            reason: reason || "unavailable",
            source: source,
            error: error,
            fetched_at: fetched_at
          )
        end

        def unsupported(harness:, note: nil, source: nil, fetched_at: nil)
          new(
            harness: harness,
            availability: UNSUPPORTED,
            models: [],
            note: note || "#{harness} does not expose a model catalog yet.",
            reason: "unsupported_harness",
            source: source,
            fetched_at: fetched_at
          )
        end

        # A failed refresh must never shrink a working model list. This keeps the
        # last list the harness actually confirmed, records why the newest
        # attempt failed, and lets callers label the list as last-known.
        def retained(previous:, failure:, last_attempt_at: nil)
          previous = coerce(previous)
          failure = coerce(failure, harness: previous.harness)
          return failure if previous.models.empty?

          new(
            harness: previous.harness,
            availability: STALE,
            models: previous.models,
            note: failure.note,
            reason: failure.reason || "refresh_failed",
            source: previous.source,
            error: previous.error,
            fetched_at: previous.fetched_at,
            last_attempt_at: last_attempt_at || Time.now.utc.iso8601,
            last_error: failure.error || failure.reason
          )
        end

        # Accepts a catalog, a persisted snapshot hash, or nil so callers can
        # treat live and stored catalogs the same way.
        def coerce(value, harness: nil)
          return value if value.is_a?(ModelCatalog)
          return from_h(value) if value.is_a?(Hash)

          unsupported(harness: harness || "unknown", note: "No model catalog has been fetched yet.")
        end

        def from_h(hash)
          hash = stringify(hash)
          new(
            harness: hash["harness"],
            availability: hash["availability"],
            models: hash["models"],
            note: hash["note"],
            reason: hash["reason"],
            source: hash["source"],
            error: hash["error"],
            fetched_at: hash["fetched_at"],
            last_attempt_at: hash["last_attempt_at"],
            last_error: hash["last_error"]
          )
        end

        def entry(provider:, id:, name: nil, thinking_levels: nil, reasoning: nil,
                  context_window: nil, max_tokens: nil)
          normalize_entry(
            "provider" => provider,
            "id" => id,
            "name" => name,
            "thinking_levels" => thinking_levels,
            "reasoning" => reasoning,
            "context_window" => context_window,
            "max_tokens" => max_tokens
          )
        end

        def normalize_entries(models)
          Array(models).filter_map { |model| normalize_entry(model) }.uniq { |entry| entry.fetch("reference") }
        end

        def normalize_entry(model)
          return nil unless model.is_a?(Hash)

          model = stringify(model)
          provider, id = provider_and_id(model)
          return nil if provider.empty? || id.empty?

          {
            "reference" => "#{provider}/#{id}",
            "provider" => provider,
            "id" => id,
            "name" => present(model["name"]) ? model["name"].to_s : nil,
            "thinking_levels" => normalize_thinking_levels(model["thinking_levels"] || model["thinkingLevels"]),
            "reasoning" => boolean_or_nil(model["reasoning"]),
            "context_window" => integer_or_nil(model["context_window"] || model["contextWindow"]),
            "max_tokens" => integer_or_nil(model["max_tokens"] || model["maxTokens"])
          }.compact
        end

        private

        # A model id may itself contain slashes, so a reference is split on the
        # first slash only, exactly as the harness does. See `ModelReference`.
        def provider_and_id(model)
          provider = model["provider"].to_s.strip
          id = (model["id"] || model["model_id"] || model["modelId"]).to_s.strip
          reference = model["reference"].to_s.strip
          if (provider.empty? || id.empty?) && reference.include?("/")
            reference_provider, reference_id = ModelReference.split(reference)
            provider = reference_provider.to_s.strip if provider.empty?
            id = reference_id.to_s.strip if id.empty?
          end
          [provider, id]
        end

        def normalize_thinking_levels(levels)
          normalized = Array(levels).map { |level| level.to_s.strip.downcase }.reject(&:empty?).uniq
          normalized.empty? ? nil : normalized
        end

        def boolean_or_nil(value)
          return nil if value.nil?

          !!value && value.to_s != "false"
        end

        def integer_or_nil(value)
          return nil if value.nil? || value.to_s.strip.empty?

          Integer(value)
        rescue ArgumentError, TypeError
          nil
        end

        def present(value)
          !value.nil? && !value.to_s.strip.empty?
        end

        def stringify(hash)
          hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        end
      end

      def initialize(harness:, availability:, models: [], note: nil, reason: nil, source: nil,
                     error: nil, fetched_at: nil, last_attempt_at: nil, last_error: nil)
        @harness = harness.to_s
        @availability = availability.to_s
        @models = self.class.normalize_entries(models)
        @note = note.nil? ? nil : note.to_s
        @reason = reason.nil? ? nil : reason.to_s
        @source = source.nil? ? nil : source.to_s
        @error = error.nil? ? nil : error.to_s
        @fetched_at = fetched_at.nil? ? Time.now.utc.iso8601 : fetched_at.to_s
        @last_attempt_at = last_attempt_at.nil? ? nil : last_attempt_at.to_s
        @last_error = last_error.nil? ? nil : last_error.to_s
      end

      def available?
        availability == AVAILABLE && !models.empty?
      end

      # True whenever the harness's own model list can still be offered, which
      # includes a last-known list whose newest refresh failed.
      def usable?
        !models.empty? && [AVAILABLE, STALE].include?(availability)
      end

      def stale?
        availability == STALE
      end

      def unsupported?
        availability == UNSUPPORTED
      end

      def model_count
        models.length
      end

      def references
        models.map { |model| model.fetch("reference") }
      end

      def entry_for(reference)
        wanted = reference.to_s.strip.downcase
        return nil if wanted.empty?

        models.find { |model| model.fetch("reference").downcase == wanted }
      end

      def thinking_levels_for(reference)
        entry_for(reference)&.fetch("thinking_levels", nil)
      end

      # Seconds since this snapshot was taken, or nil when the timestamp is
      # unusable. Refresh policy lives in the kernel, not in the snapshot.
      def age_seconds(now: Time.now.utc)
        seconds_since(fetched_at, now)
      end

      # Seconds since the last fetch *attempt*, successful or not. Retry policy
      # uses this so a retained list is retried on the failure cadence instead of
      # being re-probed on every pass because its confirmed timestamp is old.
      def attempt_age_seconds(now: Time.now.utc)
        seconds_since(last_attempt_at || fetched_at, now)
      end

      def to_h
        {
          "harness" => harness,
          "availability" => availability,
          "model_count" => model_count,
          "models" => models,
          "note" => note,
          "reason" => reason,
          "source" => source,
          "error" => error,
          "fetched_at" => fetched_at,
          "last_attempt_at" => last_attempt_at,
          "last_error" => last_error
        }.compact
      end

      alias to_hash to_h

      private

      def seconds_since(timestamp, now)
        reference = Time.iso8601(timestamp.to_s)
        now_time = now.is_a?(Time) ? now : Time.iso8601(now.to_s)
        (now_time - reference).to_f
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
