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
      AUTHENTICATED = "authenticated"
      UNAUTHENTICATED = "unauthenticated"
      AUTHENTICATION_UNKNOWN = "unknown"
      AUTHENTICATION_UNAVAILABLE = "unavailable"
      AUTHENTICATION_PARTIAL = "partial"
      AUTHENTICATION_STATUSES = [
        AUTHENTICATED,
        UNAUTHENTICATED,
        AUTHENTICATION_UNKNOWN,
        AUTHENTICATION_UNAVAILABLE,
        AUTHENTICATION_PARTIAL
      ].freeze
      # A previously confirmed list whose latest refresh failed. The models are
      # still the harness's own answer, just older than we would like, so they
      # stay listed instead of collapsing back to whatever Meringue remembers.
      STALE = "stale"
      UNAVAILABLE = "unavailable"
      UNSUPPORTED = "unsupported"
      EMPTY_CATALOG_REASON = "empty_catalog"
      # A provider can accidentally print an unbounded registry (or a proxy can return a very large
      # payload). State metadata is long-lived, so catalog snapshots have an explicit memory and
      # persistence bound rather than trusting provider output size.
      MAX_MODELS = 2_000
      MAX_REFERENCE_BYTES = 4_096
      MAX_AUTH_PROVIDERS = 256
      MAX_NAME_BYTES = 512
      MAX_THINKING_LEVELS = 32
      MAX_THINKING_LEVEL_BYTES = 32

      ENTRY_KEYS = %w[
        reference provider id name thinking_levels reasoning context_window max_tokens authentication
      ].freeze
      HEAD_ENTRY_KEYS = ENTRY_KEYS.freeze

      attr_reader :harness, :availability, :models, :note, :reason, :source, :fetched_at, :error,
                  :last_attempt_at, :last_error, :authentication

      class << self
        def available(harness:, models:, source: nil, fetched_at: nil, authentication: nil, auth: nil)
          entries = normalize_entries(models)
          if entries.empty?
            return unavailable(
              harness: harness,
              note: "#{harness} reported no available models. Check provider auth and model configuration.",
              source: source,
              reason: EMPTY_CATALOG_REASON,
              fetched_at: fetched_at,
              authentication: authentication.nil? ? auth : authentication
            )
          end

          new(
            harness: harness,
            availability: AVAILABLE,
            models: entries,
            source: source,
            fetched_at: fetched_at,
            authentication: authentication.nil? ? auth : authentication
          )
        end

        def unavailable(harness:, note:, source: nil, reason: nil, error: nil, fetched_at: nil,
                        authentication: nil, auth: nil)
          new(
            harness: harness,
            availability: UNAVAILABLE,
            models: [],
            note: note,
            reason: reason || "unavailable",
            source: source,
            error: error,
            fetched_at: fetched_at,
            authentication: authentication.nil? ? (auth.nil? ? { "status" => AUTHENTICATION_UNAVAILABLE } : auth) : authentication
          )
        end

        def unsupported(harness:, note: nil, source: nil, fetched_at: nil, authentication: nil, auth: nil)
          new(
            harness: harness,
            availability: UNSUPPORTED,
            models: [],
            note: note || "#{harness} does not expose a model catalog yet.",
            reason: "unsupported_harness",
            source: source,
            fetched_at: fetched_at,
            authentication: authentication.nil? ? (auth.nil? ? { "status" => AUTHENTICATION_UNAVAILABLE } : auth) : authentication
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
            last_error: failure.error || failure.reason,
            authentication: previous.authentication
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
            last_error: hash["last_error"],
            authentication: hash.key?("authentication") ? hash["authentication"] : hash["auth"]
          )
        end

        def entry(provider:, id:, name: nil, thinking_levels: nil, reasoning: nil,
                  context_window: nil, max_tokens: nil, authentication: nil, auth: nil,
                  authenticated: nil)
          normalize_entry(
            "provider" => provider,
            "id" => id,
            "name" => name,
            "thinking_levels" => thinking_levels,
            "reasoning" => reasoning,
            "context_window" => context_window,
            "max_tokens" => max_tokens,
            "authentication" => if !authentication.nil?
                                  authentication
                                elsif !auth.nil?
                                  auth
                                else
                                  authenticated
                                end
          )
        end

        def normalize_entries(models)
          Array(models).filter_map { |model| normalize_entry(model) }
            .uniq { |entry| entry.fetch("reference") }
            .first(MAX_MODELS)
        end

        def normalize_entry(model)
          return nil unless model.is_a?(Hash)

          model = stringify(model)
          provider, id = provider_and_id(model)
          return nil if provider.empty? || id.empty?
          return nil if "#{provider}/#{id}".bytesize > MAX_REFERENCE_BYTES

          {
            "reference" => "#{provider}/#{id}",
            "provider" => provider,
            "id" => id,
            "name" => bounded_string(model["name"], MAX_NAME_BYTES),
            "thinking_levels" => normalize_thinking_levels(model["thinking_levels"] || model["thinkingLevels"]),
            "reasoning" => boolean_or_nil(model["reasoning"]),
            "context_window" => integer_or_nil(model["context_window"] || model["contextWindow"]),
            "max_tokens" => integer_or_nil(model["max_tokens"] || model["maxTokens"]),
            "authentication" => normalize_authentication_status(
              model.key?("authentication") ? model["authentication"] :
                (model.key?("auth") ? model["auth"] :
                  (model.key?("auth_status") ? model["auth_status"] : model["authenticated"]))
            )
          }.compact
        end

        # Authentication is a small, optional contract. A harness may provide a
        # single status or one status per provider, but never credentials.
        def normalize_authentication_metadata(value)
          return nil if value.nil?

          if value.is_a?(Hash)
            hash = stringify(value)
            providers = hash["providers"]
            if providers.nil?
              provider_values = hash.reject { |key, _value| %w[status source reason].include?(key) }
              providers = provider_values unless provider_values.empty?
            end
            normalized_providers = if providers.is_a?(Hash)
                                     providers.to_a.first(MAX_AUTH_PROVIDERS).each_with_object({}) do |(provider, detail), result|
                                       provider_name = normalize_authentication_token(provider)
                                       normalized = normalize_authentication_detail(detail)
                                       result[provider_name] = normalized if provider_name && normalized
                                     end
                                   else
                                     {}
                                   end
            status = normalize_authentication_status(hash.key?("status") ? hash["status"] : hash["authenticated"])
            status = aggregate_authentication_status(normalized_providers.values) if status.nil? && !normalized_providers.empty?
            status ||= AUTHENTICATION_UNKNOWN
            {
              "status" => status,
              "source" => normalize_authentication_token(hash["source"]),
              "reason" => normalize_authentication_token(hash["reason"]),
              "providers" => normalized_providers
            }.compact.tap { |result| result.delete("providers") if result["providers"].empty? }
          else
            { "status" => normalize_authentication_status(value) || AUTHENTICATION_UNKNOWN }
          end
        end

        def normalize_authentication_status(value)
          return AUTHENTICATED if value == true
          return UNAUTHENTICATED if value == false
          return nil if value.nil?

          value = if value.is_a?(Hash)
                    if value.key?("status")
                      value["status"]
                    elsif value.key?(:status)
                      value[:status]
                    else
                      value["authenticated"]
                    end
                  else
                    value
                  end
          case value.to_s.strip.downcase
          when "authenticated", "ready", "ok", "available"
            AUTHENTICATED
          when "unauthenticated", "not_authenticated", "not_ready", "credentials_not_configured"
            UNAUTHENTICATED
          when "unavailable", "unsupported", "error", "failed"
            AUTHENTICATION_UNAVAILABLE
          when "partial", "partially_authenticated", "mixed"
            AUTHENTICATION_PARTIAL
          when "unknown", "", "not_checked"
            AUTHENTICATION_UNKNOWN
          else
            AUTHENTICATION_UNKNOWN
          end
        end

        private

        def normalize_authentication_detail(value)
          detail = value.is_a?(Hash) ? stringify(value) : { "status" => value }
          status = normalize_authentication_status(
            detail.key?("status") ? detail["status"] : detail["authenticated"]
          )
          return nil unless status

          {
            "status" => status,
            "source" => normalize_authentication_token(detail["source"]),
            "reason" => normalize_authentication_token(detail["reason"])
          }.compact
        end

        def normalize_authentication_token(value)
          text = value.to_s.strip
          return nil if text.empty?
          return nil unless text.bytesize <= 128 && text.match?(/\A[a-zA-Z0-9_.:-]+\z/)

          text
        end

        def aggregate_authentication_status(details)
          statuses = details.filter_map { |detail| detail.is_a?(Hash) ? detail["status"] : nil }.uniq
          return AUTHENTICATED if statuses == [AUTHENTICATED]
          return UNAUTHENTICATED if statuses == [UNAUTHENTICATED]
          return AUTHENTICATION_UNAVAILABLE if statuses == [AUTHENTICATION_UNAVAILABLE]
          return AUTHENTICATION_UNKNOWN if statuses.empty? || statuses == [AUTHENTICATION_UNKNOWN]

          AUTHENTICATION_PARTIAL
        end

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
          normalized = Array(levels).filter_map do |level|
            value = bounded_string(level, MAX_THINKING_LEVEL_BYTES)&.strip&.downcase
            value unless value.to_s.empty?
          end.uniq.first(MAX_THINKING_LEVELS)
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

        def bounded_string(value, bytes)
          return nil unless present(value)

          value.to_s.byteslice(0, bytes).to_s.scrub
        end

        def stringify(hash)
          hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        end
      end

      def initialize(harness:, availability:, models: [], note: nil, reason: nil, source: nil,
                     error: nil, fetched_at: nil, last_attempt_at: nil, last_error: nil,
                     authentication: nil, auth: nil)
        @harness = harness.to_s
        @availability = availability.to_s
        @note = note.nil? ? nil : note.to_s
        @reason = reason.nil? ? nil : reason.to_s
        @source = source.nil? ? nil : source.to_s
        @error = error.nil? ? nil : error.to_s
        @fetched_at = fetched_at.nil? ? Time.now.utc.iso8601 : fetched_at.to_s
        @last_attempt_at = last_attempt_at.nil? ? nil : last_attempt_at.to_s
        @last_error = last_error.nil? ? nil : last_error.to_s
        @authentication = self.class.normalize_authentication_metadata(authentication.nil? ? auth : authentication)
        @models = apply_provider_authentication(self.class.normalize_entries(models))
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

      def authentication_for(reference)
        entry = entry_for(reference)
        return nil unless entry

        return entry.fetch("authentication") if entry.key?("authentication")

        providers = authentication.is_a?(Hash) ? authentication.fetch("providers", {}) : {}
        provider_detail = providers.fetch(entry.fetch("provider"), nil)
        return self.class.normalize_authentication_status(provider_detail) if provider_detail

        authentication.is_a?(Hash) ? authentication.fetch("status", nil) : nil
      end

      alias auth_status_for authentication_for

      def authenticated?(reference)
        authentication_for(reference) == AUTHENTICATED
      end

      # Head context can include this bounded, secret-free view. Raw notes,
      # errors, and harness metadata stay in the kernel-facing snapshot only.
      def to_head_h(role: nil)
        head_authentication = authentication || {
          "status" => availability == AVAILABLE ? AUTHENTICATION_UNKNOWN : AUTHENTICATION_UNAVAILABLE
        }
        {
          "role" => role,
          "harness" => harness,
          "availability" => availability,
          "authentication" => head_authentication,
          "model_count" => model_count,
          "models" => models.map do |model|
            model.slice(*HEAD_ENTRY_KEYS).tap do |entry|
              entry["authentication"] ||= authentication_for(model.fetch("reference")) || AUTHENTICATION_UNKNOWN
            end
          end,
          "source" => source,
          "fetched_at" => fetched_at,
          "last_attempt_at" => last_attempt_at,
          "reason" => reason
        }.compact
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
          "authentication" => authentication,
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

      def apply_provider_authentication(entries)
        return entries unless authentication.is_a?(Hash)

        providers = authentication.fetch("providers", {})
        entries.map do |entry|
          status = if entry.key?("authentication")
                     entry.fetch("authentication")
                   elsif providers.is_a?(Hash) && providers.key?(entry.fetch("provider"))
                     self.class.normalize_authentication_status(providers.fetch(entry.fetch("provider")))
                   elsif authentication.fetch("status", nil) != AUTHENTICATION_UNKNOWN
                     authentication.fetch("status", nil)
                   end
          status ? entry.merge("authentication" => status) : entry
        end
      end

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
