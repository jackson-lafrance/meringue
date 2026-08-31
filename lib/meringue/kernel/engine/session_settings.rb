# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Model and reasoning defaults: reading state, discovering a harness's catalog, and persisting
      # per-session or default model/thinking selections.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def get_state(command_id, command_type)
        accepted_result(command_id, command_type, nil, "Loaded Meringue state.", store.load, [])
      end

      # Reports the model/thinking pair future heads and workers will use.
      # There is no slash command for it any more: the dashboard status line
      # already shows the compact model/thinking summary and `/config` prints
      # the same values, so the typed `/defaults` was redundant surface. The
      # command stays because a head still proposes it for "show the defaults"
      # or "which model will future agents use", where the answer has to reach
      # the log with the clamp caveat attached.
      def get_session_defaults(command_id, command_type)
        state = normalized_state
        defaults = configured_session_defaults
        message = session_defaults_message(defaults)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: message,
          details: defaults.merge("config_path" => config_path)
        )
        touch_state!(state)
        store.save(state)
        accepted_result(command_id, command_type, defaults.fetch("harness", nil), message, defaults.merge("config_path" => config_path), log_ids)
      end

      # Lists the models the selected harness itself reports. The catalog is
      # cached in state metadata so completion never has to start a harness
      # process while the user types.
      def get_model_catalog(command_id, command_type, payload)
        requested = value_at(payload, "harness", "provider", "Harness", "Provider")
        requested_role = value_at(payload, "role", "Role")
        role = requested_role.to_s.strip.downcase
        if !role.empty? && !%w[head worker].include?(role)
          return synchronized_state do
            rejected_result(command_id, command_type, "Model catalog was not loaded.", ["role must be one of: head, worker"])
          end
        end
        role = "worker" if role.empty?
        provider =
          if blank?(requested)
            synchronized_state { active_harness_provider(normalized_state, role: role) }
          else
            begin
              Meringue::Harness::Registry.normalize_provider!(requested)
            rescue ArgumentError => e
              return synchronized_state do
                rejected_result(command_id, command_type, "Model catalog was not loaded.", [e.message])
              end
            end
          end

        force = model_catalog_force_flag?(value_at(payload, "refresh", "force", "Refresh", "Force"))
        catalog = refresh_model_catalog!(provider: provider, force: force)
        accepted_result(
          command_id,
          command_type,
          catalog.fetch("harness", nil),
          model_catalog_message(catalog),
          catalog,
          []
        )
      rescue StandardError => e
        synchronized_state do
          error = error_payload(e)
          failed_result(
            command_id,
            command_type,
            "Could not load the model catalog: #{error.fetch("message")}",
            [error.fetch("class"), error.fetch("message")]
          )
        end
      end

      def model_catalog_force_flag?(value)
        return false if value.nil?
        return value if value == true || value == false

        %w[true yes 1 refresh reload force].include?(value.to_s.strip.downcase)
      end

      def model_catalog_message(catalog)
        harness = catalog.fetch("harness", "harness")
        count = catalog.fetch("model_count", Array(catalog["models"]).length)
        case catalog.fetch("availability", nil)
        when Meringue::Harness::ModelCatalog::AVAILABLE
          "#{harness} reports #{count} available model#{count == 1 ? "" : "s"}. " \
            "Use /model <provider>/<model-id> to set the default for future sessions."
        when Meringue::Harness::ModelCatalog::STALE
          "Showing the last #{count} model#{count == 1 ? "" : "s"} #{harness} confirmed at #{catalog.fetch("fetched_at", "an earlier time")}; " \
            "the newest refresh failed: #{catalog.fetch("note", "unknown error")}"
        else
          note = catalog.fetch("note", nil)
          blank?(note) ? "No #{harness} model catalog is available." : note.to_s
        end
      end

      # Fetching a catalog can start a harness process, so the fetch happens
      # outside the state lock and only the resulting snapshot is persisted.
      def refresh_model_catalog!(provider:, force: false)
        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        @model_catalog_mutex.synchronize do
          existing = persisted_model_catalog(public_name)
          return existing if existing && !force && !model_catalog_stale?(existing)

          snapshot = merged_model_catalog(fetch_model_catalog(provider), existing)
          persist_model_catalog!(public_name, snapshot)
          snapshot
        end
      end

      # A failed or empty refresh must never shrink a working model list. A harness
      # hiccup (restart, provider auth blip, sleeping laptop) would otherwise drop
      # the selector back to the couple of references Meringue remembers, which
      # looks exactly like the catalog never worked. Keep the last list the harness
      # confirmed, marked stale with the failure attached.
      def merged_model_catalog(fetched, existing)
        catalog = Meringue::Harness::ModelCatalog.coerce(fetched)
        return catalog.to_h if catalog.usable?

        previous = Meringue::Harness::ModelCatalog.coerce(existing)
        return catalog.to_h unless previous.usable?

        Meringue::Harness::ModelCatalog.retained(previous: previous, failure: catalog).to_h
      end

      # Which harness's model list a default should be checked against. Normally the configured
      # one; before a harness is chosen, the only list Meringue actually holds is still the right
      # thing to check against, and saying so is more useful than silently skipping the check.
      def catalog_harness_for(defaults)
        harness = defaults.is_a?(Hash) ? defaults.fetch("harness", nil) : nil
        harness ||= default_session_harness
        harness || sole_persisted_catalog_harness
      end

      def sole_persisted_catalog_harness
        names = synchronized_state do
          catalogs = normalized_state.dig("metadata", "harness_model_catalogs")
          catalogs.is_a?(Hash) ? catalogs.keys : []
        end
        names.length == 1 ? names.first : nil
      end

      def persisted_model_catalog(public_name)
        synchronized_state do
          catalog = normalized_state.dig("metadata", "harness_model_catalogs", public_name)
          catalog.is_a?(Hash) ? deep_copy(catalog) : nil
        end
      end

      def persist_model_catalog!(public_name, snapshot)
        synchronized_state do
          state = normalized_state
          catalogs = (state.fetch("metadata")["harness_model_catalogs"] ||= {})
          catalogs[public_name] = deep_copy(snapshot)
          touch_state!(state)
          store.save(state)
        end
      end

      def fetch_model_catalog(provider)
        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        unless @model_catalog_provider
          return Meringue::Harness::ModelCatalog.unsupported(
            harness: public_name,
            note: "This Meringue instance has no harness model catalog source configured, " \
                  "so #{public_name} models cannot be listed."
          ).to_h
        end

        Meringue::Harness::ModelCatalog.coerce(
          @model_catalog_provider.call(provider),
          harness: public_name
        ).to_h
      rescue StandardError => e
        Meringue::Harness::ModelCatalog.unavailable(
          harness: public_name,
          note: "Could not read the #{public_name} model catalog: #{sanitized_error_message(e)}",
          reason: "fetch_failed",
          error: e.class.name
        ).to_h
      end

      # Refresh cadence is measured from the last fetch *attempt*, so a retained
      # (stale) list is retried on the failure cadence instead of being re-probed
      # on every pass just because its confirmed timestamp is old.
      def model_catalog_stale?(snapshot)
        return true unless snapshot.is_a?(Hash)

        catalog = Meringue::Harness::ModelCatalog.from_h(snapshot)
        age = catalog.attempt_age_seconds
        return true if age.nil?
        return false if age.negative?

        age >= (catalog.available? ? MODEL_CATALOG_REFRESH_INTERVAL_SECONDS : MODEL_CATALOG_RETRY_INTERVAL_SECONDS)
      end

      # Background refresh for the harness that future sessions will use. Silent
      # by design: an expected "no catalog yet" state is surfaced in `/models`
      # and in completion, not as repeated durable log entries.
      def refresh_active_model_catalog
        return { "changed" => false, "skipped" => "no_catalog_source" } unless @model_catalog_provider

        provider = synchronized_state { active_harness_provider(normalized_state) }
        # No harness is configured yet (fresh state before setup). Skip rather
        # than ask the registry for a catalog it cannot resolve, which would
        # log a warning on every reconciliation tick.
        return { "changed" => false, "skipped" => "no_harness_configured" } if provider.to_s.empty?
        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        existing = persisted_model_catalog(public_name)
        if existing && !model_catalog_stale?(existing)
          return {
            "changed" => false,
            "harness" => public_name,
            "availability" => existing.fetch("availability", nil),
            "model_count" => existing.fetch("model_count", 0)
          }
        end

        snapshot = refresh_model_catalog!(provider: provider)
        {
          "changed" => existing.nil? || existing.fetch("fetched_at", nil) != snapshot.fetch("fetched_at", nil),
          "harness" => public_name,
          "availability" => snapshot.fetch("availability", nil),
          "model_count" => snapshot.fetch("model_count", 0)
        }
      end

      # A worker override can be checked against a fresh harness-owned list before
      # workspace or session provisioning starts. Degraded snapshots stay usable,
      # but the reservation records that the model was not verified.
      def worker_model_validation(state, provider:, reference:)
        return nil if reference.to_s.strip.empty?

        public_name = Meringue::Harness::Registry.public_provider_name(provider)
        snapshot = state.dig("metadata", "harness_model_catalogs", public_name)
        catalog = Meringue::Harness::ModelCatalog.coerce(snapshot, harness: public_name)
        base = {
          "reference" => reference.to_s,
          "harness" => public_name,
          "catalog_availability" => catalog.availability,
          "catalog_fetched_at" => catalog.fetched_at
        }.compact
        unless snapshot.is_a?(Hash)
          return base.merge("status" => "unverified", "reason" => "catalog_not_fetched")
        end

        entry = catalog.entry_for(reference)
        if catalog.available?
          unless entry
            # A snapshot exactly at the bound may be truncated. Do not reject a
            # valid extension model merely because it fell beyond that bound.
            return base.merge("status" => "unverified", "reason" => "not_in_bounded_catalog") if catalog.model_count >= Meringue::Harness::ModelCatalog::MAX_MODELS

            return base.merge(
              "status" => "rejected",
              "reason" => "not_in_catalog",
              "error_code" => "model_not_in_harness_catalog"
            )
          end

          authentication = catalog.authentication_for(reference)
          if authentication == Meringue::Harness::ModelCatalog::UNAUTHENTICATED
            return base.merge(
              "status" => "rejected",
              "reason" => "not_authenticated",
              "error_code" => "model_not_authenticated"
            )
          end

          return base.merge(
            "status" => authentication == Meringue::Harness::ModelCatalog::AUTHENTICATED ? "verified" : "unverified",
            "reason" => authentication ? "authentication_#{authentication}" : "catalog_entry"
          )
        end

        base.merge(
          "status" => "unverified",
          "reason" => catalog.stale? ? "stale_catalog" : "catalog_#{catalog.availability}"
        )
      end

      def worker_model_validation_message(validation)
        reference = validation.fetch("reference")
        harness = validation.fetch("harness")
        case validation.fetch("reason")
        when "not_in_catalog"
          "Worker was not spawned: #{harness} does not report #{reference} in its current model catalog. Run /models refresh and choose a listed model."
        when "not_authenticated"
          "Worker was not spawned: #{harness} reports #{reference}, but its provider authentication is not ready. Choose an authenticated model or run /models refresh."
        else
          "Worker was not spawned because model #{reference} failed harness catalog validation."
        end
      end

      # Shape validation only, and deliberately catalog-independent: a model the
      # cached catalog does not list is still settable (the catalog can be stale,
      # empty, unavailable, or simply behind a provider extension that added the
      # model), it is just labelled unverified in the accepted message.
      def set_default_session_model(command_id, command_type, payload)
        role_value = value_at(payload, "role", "Role")
        role = role_value.to_s.strip.downcase
        if !role.empty? && !%w[head worker].include?(role)
          return rejected_result(
            command_id,
            command_type,
            "Default model was not changed: role must be head or worker.",
            ["role must be one of: head, worker"]
          )
        end
        role = nil if role.empty?
        model_reference = value_at(payload, "model", "model_reference", "Model", "ModelReference")
        reason = Meringue::Harness::ModelReference.rejection_reason(model_reference)
        if reason
          return rejected_result(
            command_id,
            command_type,
            invalid_model_reference_message("Default model", reason),
            ["model must be a provider/model id: #{reason}"]
          )
        end

        update_agent_session_defaults(
          command_id,
          command_type,
          model: Meringue::Harness::ModelReference.normalize(model_reference),
          model_role: role,
          changed_field: "model"
        )
      end

      def set_default_session_thinking_level(command_id, command_type, payload)
        requested = value_at(payload, "level", "thinking_level", "Level", "ThinkingLevel")
        role_value = value_at(payload, "role", "Role")
        role = role_value.to_s.strip.downcase
        if !role.empty? && !%w[head worker].include?(role)
          return rejected_result(
            command_id,
            command_type,
            "Default reasoning level was not changed: role must be head or worker.",
            ["role must be one of: head, worker"]
          )
        end
        role = nil if role.empty?
        level = requested.to_s.strip.downcase
        unless Meringue::Harness::ModelCatalog::THINKING_LEVELS.include?(level)
          return rejected_result(
            command_id,
            command_type,
            invalid_thinking_level_message("Default reasoning level", requested),
            ["thinking level must be one of: #{Meringue::Harness::ModelCatalog::THINKING_LEVELS.join(", ")}"]
          )
        end

        update_agent_session_defaults(
          command_id,
          command_type,
          thinking_level: level,
          thinking_role: role,
          changed_field: "thinking_level"
        )
      end

      def update_agent_session_defaults(command_id, command_type, model: nil, model_role: nil, thinking_level: nil, thinking_role: nil, changed_field:)
        previous = configured_session_defaults
        # Whoever reports the defaults also says which harness they belong to. Re-deriving it from
        # config here would disagree with an injected provider. A role-specific update targets that
        # role's harness when head and worker are split; a shared update retains the worker-side
        # compatibility convention.
        update_role = model_role || thinking_role
        harness = if update_role
                    default_session_harness(role: update_role)
                  else
                    previous.fetch("harness", nil) || default_session_harness
                  end
        defaults = if @session_defaults_updater
                     keywords = { model: model, thinking_level: thinking_level }
                     keywords[:model_role] = model_role unless model_role.nil?
                     keywords[:thinking_role] = thinking_role unless thinking_role.nil?
                     @session_defaults_updater.call(harness, **keywords)
                   else
                     saved = Config.save_agent_session_defaults!(
                       model: model,
                       model_role: model_role,
                       thinking_level: thinking_level,
                       thinking_role: thinking_role,
                       provider: harness,
                       path: config_path
                     )
                     Meringue::Harness::Registry.new(config: saved).session_defaults(provider: harness)
                   end
        defaults = Config.deep_stringify(defaults)
        harness = defaults.fetch("harness", nil) || harness
        state = normalized_state
        state.fetch("metadata")["agent_session_defaults"] = deep_copy(defaults)
        unchanged_ids = existing_agent_session_ids(state, harness)
        active_role = model_role || thinking_role
        value = if changed_field == "model"
                  if model_role
                    defaults.dig("roles", model_role, "model") || model
                  else
                    defaults.fetch("model", model)
                  end
                elsif thinking_role
                  defaults.dig("roles", thinking_role, "thinking_level") || thinking_level
                else
                  defaults.fetch("thinking_level", thinking_level)
                end
        label = changed_field == "model" ? "model" : "thinking level"
        audience = active_role ? "future #{active_role}s" : "all future heads and workers"
        scope_harness = active_role ? (default_session_harness(role: active_role) || harness) : harness
        scope = if scope_harness.to_s.empty? || scope_harness.to_s == "mixed"
                  active_role ? "future_#{active_role}_sessions" : "future_sessions"
                else
                  suffix = active_role ? "#{scope_harness}_#{active_role}_sessions" : "#{scope_harness}_sessions"
                  "future_#{suffix}"
                end
        clamp_note = clamped_default_thinking_note(defaults, changed_field, role: active_role)
        unverified_note = unverified_default_model_note(defaults, changed_field, role: model_role)
        message = "Set the default #{label} to #{value} for #{audience}. " \
                  "Existing sessions were not changed." \
                  "#{unverified_note ? " #{unverified_note}" : ""}" \
                  "#{clamp_note ? " #{clamp_note}" : ""}"
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: "info",
          message: message,
          details: {
            "changed_field" => changed_field,
            "previous_defaults" => previous,
            "agent_session_defaults" => defaults,
            "scope" => scope,
            "existing_session_ids_unchanged" => unchanged_ids,
            "config_path" => config_path
          }
        )
        touch_state!(state)
        store.save(state)
        accepted_result(
          command_id,
          command_type,
          harness,
          message,
          defaults.merge(
            "scope" => scope,
            "config_path" => config_path,
            "existing_session_ids_unchanged" => unchanged_ids
          ),
          log_ids
        )
      rescue Config::ParseError => e
        rejected_result(command_id, command_type, "Default agent session settings were not changed because config could not be read.", [e.message])
      end

      # The model and reasoning defaults future sessions will use, read for the active harness of
      # each role. This prevents `/config` and the status line from showing worker settings for a
      # head that is configured to use a different harness.
      def configured_session_defaults
        if @session_defaults_provider
          head_harness = default_session_harness(role: "head")
          worker_harness = default_session_harness(role: "worker")
          if head_harness.to_s != worker_harness.to_s && !head_harness.to_s.empty? && !worker_harness.to_s.empty?
            head = Config.deep_stringify(@session_defaults_provider.call(head_harness))
            worker = Config.deep_stringify(@session_defaults_provider.call(worker_harness))
            return merge_active_role_defaults(head, worker, head_harness: head_harness, worker_harness: worker_harness)
          end

          return Config.deep_stringify(@session_defaults_provider.call(worker_harness))
        end

        config = Config.load(path: config_path)
        Config.deep_stringify(Meringue::Harness::Registry.new(config: config).session_defaults)
      rescue Config::ParseError, ArgumentError
        fallback_session_defaults
      end

      def merge_active_role_defaults(head, worker, head_harness:, worker_harness:)
        roles = {
          "head" => head.dig("roles", "head") || head,
          "worker" => worker.dig("roles", "worker") || worker
        }
        models = roles.values.map { |role| role["model"] }.uniq
        thinking = roles.values.map { |role| role["thinking_level"] }.uniq
        {
          "harness" => "mixed",
          "model" => models.length == 1 ? models.first : nil,
          "thinking_level" => thinking.length == 1 ? thinking.first : nil,
          "consistency" => models.length == 1 && thinking.length == 1 ? "consistent" : "mixed",
          "roles" => roles,
          "scope" => "future_sessions",
          "role_harnesses" => { "head" => head_harness, "worker" => worker_harness }
        }
      end

      # The harness whose defaults `/model` and `/thinking` are talking about. Workers are what a
      # user is normally changing, so the worker harness is the one reported unless a role is
      # explicitly requested.
      def default_session_harness(role: "worker")
        registry = Meringue::Harness::Registry.new(config: Config.load(path: config_path))
        role.to_s == "head" ? registry.head_provider : registry.worker_provider
      rescue StandardError
        nil
      end

      def fallback_session_defaults
        model = Meringue::Harness::Registry::DEFAULT_MODEL
        thinking = Meringue::Harness::Registry::DEFAULT_THINKING_LEVEL
        harness = default_session_harness
        {
          "harness" => harness,
          "model" => model,
          "thinking_level" => thinking,
          "consistency" => "consistent",
          "roles" => {
            "head" => { "model" => model, "thinking_level" => thinking },
            "worker" => { "model" => model, "thinking_level" => thinking }
          },
          "scope" => harness ? "future_#{harness}_sessions" : "future_sessions"
        }.compact
      end

      def existing_agent_session_ids(state, harness)
        state.fetch("agents", []).select do |agent|
          agent.fetch("harness", nil).to_s == harness.to_s && agent_has_session_reference?(agent)
        end.map { |agent| agent.fetch("id", nil) }.compact
      end

      # A level the model's catalog entry does not advertise is still saved: a
      # provider extension can under-declare what its model really supports. Ask
      # the harness registry for any authoritative adjustment policy so the
      # result stays honest without making the kernel assume one backend's rules.
      def clamped_default_thinking_note(defaults, changed_field, role: nil)
        return nil unless %w[thinking_level model].include?(changed_field)

        reference = if role
                      defaults.dig("roles", role, "model")
                    else
                      defaults.fetch("model", nil)
                    end
        reference = reference.to_s.strip
        level = if role
                  defaults.dig("roles", role, "thinking_level")
                else
                  defaults.fetch("thinking_level", nil)
                end
        level = level.to_s.strip.downcase
        return nil if reference.empty? || level.empty?

        harness = catalog_harness_for(defaults)
        return nil unless harness

        snapshot = persisted_model_catalog(Meringue::Harness::Registry.public_provider_name(harness))
        return nil unless snapshot

        supported = Meringue::Harness::ModelCatalog.coerce(snapshot, harness: harness).thinking_levels_for(reference)
        supported = Array(supported).map { |value| value.to_s.downcase }
        return nil if supported.empty? || supported.include?(level)

        adjusted = Meringue::Harness::Registry.adjusted_thinking_level(harness, level, supported)
        label = Meringue::Harness::Registry.provider_label(harness)
        if adjusted
          "#{label}'s catalog does not list #{level} for #{reference}, so future sessions run #{adjusted} instead."
        else
          "#{label}'s catalog does not list #{level} for #{reference}; verify the effective reasoning level when the next session starts."
        end
      end

      # `/model` used to reject with a bare "Default model was not changed.",
      # so the reason lived only in the `errors` details and the user could not
      # tell a typo from an unknown id from an over-strict rule. This mirrors
      # `invalid_thinking_level_message`: the visible line names the reason and
      # the accepted grammar.
      def invalid_model_reference_message(subject, reason)
        "#{subject} was not changed: #{reason}. #{Meringue::Harness::ModelReference::FORMAT_HINT}"
      end

      # A well-formed id the cached catalog does not confirm is saved, not
      # refused: the catalog can be stale, empty, unavailable, or behind a
      # provider extension that added the model after the last fetch. Say so,
      # reusing the "unverified" wording the picker and completion already use
      # for a degraded catalog.
      def unverified_default_model_note(defaults, changed_field, role: nil)
        return nil unless changed_field == "model"

        reference = if role
                      defaults.dig("roles", role, "model")
                    else
                      defaults.fetch("model", nil)
                    end
        reference = reference.to_s.strip
        return nil if reference.empty?

        harness = catalog_harness_for(defaults)
        return nil unless harness

        snapshot = persisted_model_catalog(Meringue::Harness::Registry.public_provider_name(harness))
        catalog = Meringue::Harness::ModelCatalog.coerce(snapshot, harness: harness)
        label = Meringue::Harness::Registry.provider_label(harness)
        unless catalog.usable?
          return "Meringue has no confirmed #{label} model list right now, so #{reference} is unverified; " \
                 "run /models refresh to check it. #{label} validates it when the next session starts."
        end
        entry = catalog.entry_for(reference)
        if entry
          authentication = catalog.authentication_for(reference)
          return nil if authentication.nil? || authentication == Meringue::Harness::ModelCatalog::AUTHENTICATED

          auth_note = if authentication == Meringue::Harness::ModelCatalog::UNAUTHENTICATED
                        "#{label} reports that its provider authentication is not ready"
                      else
                        "#{label} could not confirm provider authentication"
                      end
          return "#{auth_note} for #{reference}, so the id is unverified; run /models refresh to check it."
        end

        "#{label}'s model list (confirmed #{catalog.fetched_at}) does not include #{reference}, so the id is unverified; " \
          "run /models refresh if it should be there. #{label} validates it when the next session starts."
      end

      # A bare "was not changed" left the user guessing which words are legal, so
      # the visible log line carries the ladder itself plus the obvious near-miss
      # for a truncated level such as "xhi". The valid set is the one the kernel
      # validates against, which is deliberately independent of the model catalog.
      def invalid_thinking_level_message(subject, requested)
        levels = Meringue::Harness::ModelCatalog::THINKING_LEVELS
        typed = requested.to_s.strip
        reason = typed.empty? ? "a level is required" : "#{typed.inspect} is not a supported reasoning level"
        near_miss = closest_thinking_levels(typed)
        did_you_mean = near_miss.empty? ? nil : "Did you mean #{near_miss.join(" or ")}?"
        [
          "#{subject} was not changed: #{reason}.",
          did_you_mean,
          "Valid levels: #{levels.join(", ")}."
        ].compact.join(" ")
      end

      # Only an unambiguous near-miss is worth naming; the full ladder follows in
      # the same message, so "m" does not need "minimal or medium or max".
      def closest_thinking_levels(typed)
        candidate = typed.to_s.strip.downcase
        return [] if candidate.empty?

        matches = Meringue::Harness::ModelCatalog::THINKING_LEVELS.select do |level|
          level.start_with?(candidate) || candidate.start_with?(level) || level.include?(candidate)
        end
        matches.length > 2 ? [] : matches
      end

      def session_defaults_message(defaults)
        head_model = defaults.dig("roles", "head", "model") || Meringue::Harness::Registry::DEFAULT_MODEL
        worker_model = defaults.dig("roles", "worker", "model") || Meringue::Harness::Registry::DEFAULT_MODEL
        head_thinking = defaults.dig("roles", "head", "thinking_level") || Meringue::Harness::Registry::DEFAULT_THINKING_LEVEL
        worker_thinking = defaults.dig("roles", "worker", "thinking_level") || Meringue::Harness::Registry::DEFAULT_THINKING_LEVEL
        clamp_note = clamped_default_thinking_note(defaults, "thinking_level")
        summary = if head_model == worker_model && head_thinking == worker_thinking
                    "Future heads and workers use #{head_model} with thinking #{head_thinking}."
                  else
                    "Future heads use #{head_model} with thinking #{head_thinking}; workers use #{worker_model} with thinking #{worker_thinking}."
                  end
        [
          summary,
          clamp_note,
          "Existing sessions keep their own effective settings."
        ].compact.join(" ")
      end

      def set_session_model(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "target_id", "AgentID", "TargetID")
        model_reference = value_at(payload, "model", "model_reference", "Model", "ModelReference")
        reason = Meringue::Harness::ModelReference.rejection_reason(model_reference)
        if reason
          return rejected_result(
            command_id,
            command_type,
            invalid_model_reference_message("Session model", reason),
            ["model must be a provider/model id: #{reason}"]
          )
        end

        model_reference = Meringue::Harness::ModelReference.normalize(model_reference)
        state = normalized_state
        agent, rejection = session_settings_target(state, command_id, command_type, agent_id)
        return rejection if rejection

        previous = deep_copy(agent.fetch("session_settings", {}) || {})
        client = harness_client_for_agent(agent)
        outcome = client.set_session_model(agent_session_ref(agent), model_reference)
        persist_session_settings_result!(agent, outcome)
        settings = outcome.fetch("settings")
        message = "Updated #{agent.fetch("id")} session model to #{settings.dig("model", "reference") || "unknown"}; " \
                  "effective thinking is #{settings.fetch("thinking_level", nil) || "unknown"}. This session only; defaults were not changed."
        log_ids = log_session_settings_update(state, agent, message, previous, settings, "model")
        accepted_result(command_id, command_type, agent.fetch("id"), message, session_settings_result(agent, settings), log_ids)
      rescue StandardError => e
        failed_result(
          command_id,
          command_type,
          "Could not update session model for #{agent_id}: #{sanitized_error_message(e)}",
          [e.class.name, sanitized_error_message(e)]
        )
      end

      def set_session_thinking_level(command_id, command_type, payload)
        agent_id = value_at(payload, "agent_id", "target_id", "AgentID", "TargetID")
        level = value_at(payload, "level", "thinking_level", "Level", "ThinkingLevel")
        if blank?(level)
          return rejected_result(
            command_id,
            command_type,
            invalid_thinking_level_message("Session thinking level", level),
            ["thinking level must be one of: #{Meringue::Harness::ModelCatalog::THINKING_LEVELS.join(", ")}"]
          )
        end

        state = normalized_state
        agent, rejection = session_settings_target(state, command_id, command_type, agent_id)
        return rejection if rejection

        previous = deep_copy(agent.fetch("session_settings", {}) || {})
        client = harness_client_for_agent(agent)
        outcome = client.set_session_thinking_level(agent_session_ref(agent), level.to_s)
        persist_session_settings_result!(agent, outcome)
        settings = outcome.fetch("settings")
        message = "Updated #{agent.fetch("id")} session thinking level to #{settings.fetch("thinking_level", nil) || "unknown"}; " \
                  "effective model is #{settings.dig("model", "reference") || "unknown"}. This session only; defaults were not changed."
        log_ids = log_session_settings_update(state, agent, message, previous, settings, "thinking_level")
        accepted_result(command_id, command_type, agent.fetch("id"), message, session_settings_result(agent, settings), log_ids)
      rescue StandardError => e
        failed_result(
          command_id,
          command_type,
          "Could not update session thinking level for #{agent_id}: #{sanitized_error_message(e)}",
          [e.class.name, sanitized_error_message(e)]
        )
      end

      def session_settings_target(state, command_id, command_type, agent_id)
        return [nil, rejected_result(command_id, command_type, "A target agent id is required.", ["agent_id is required"])] if blank?(agent_id)

        agent = find_agent(state, agent_id.to_s)
        return [nil, rejected_result(command_id, command_type, "Agent #{agent_id} does not exist.", ["agent_not_found"])] unless agent
        return [nil, rejected_result(command_id, command_type, "Agent #{agent_id} has been killed and is not resumable.", ["session_unavailable"])] if agent.fetch("status", nil) == "killed"
        unless agent_has_session_reference?(agent)
          return [nil, rejected_result(command_id, command_type, "Agent #{agent_id} has no harness session.", ["missing_harness_session"])]
        end

        client = harness_client_for_agent(agent)
        unless client.respond_to?(:session_settings_supported?) && client.session_settings_supported?
          harness = agent.fetch("harness", "unknown")
          return [nil, rejected_result(
            command_id,
            command_type,
            "#{harness} session settings are not supported yet; model and reasoning controls need a harness that exposes them.",
            ["unsupported_harness"]
          )]
        end

        [agent, nil]
      end

      def persist_session_settings_result!(agent, outcome)
        session_ref = outcome.fetch("session_ref")
        merge_session_ref_into_agent!(agent, session_ref)
        agent["session_settings"] = deep_copy(outcome.fetch("settings"))
        agent["updated_at"] = timestamp
      end

      def log_session_settings_update(state, agent, message, previous, settings, field)
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: agent.fetch("id"),
          level: "info",
          message: message,
          details: {
            "agent_id" => agent.fetch("id"),
            "changed_field" => field,
            "previous_session_settings" => previous,
            "session_settings" => settings,
            "scope" => "current_session"
          }
        )
        touch_state!(state)
        store.save(state)
        log_ids
      end

      def session_settings_result(agent, settings)
        {
          "agent_id" => agent.fetch("id"),
          "harness" => agent.fetch("harness", nil),
          "scope" => "current_session",
          "session_settings" => settings
        }
      end

      def list_questions(command_id, command_type)
        state = normalized_state
        questions = state.fetch("questions", [])
        accepted_result(
          command_id,
          command_type,
          nil,
          "Loaded #{questions.length} question#{questions.length == 1 ? "" : "s"}.",
          questions,
          []
        )
      end

      def help(command_id, command_type)
        accepted_result(
          command_id,
          command_type,
          nil,
          "Loaded slash command help.",
          HELP_COMMANDS.map do |usage, description|
            { "usage" => usage, "description" => description, "group" => self.class.help_group_for(usage) }
          end,
          []
        )
      end

      def invalid_slash_command(command_id, command_type, payload)
        message = value_at(payload, "message") || "Invalid slash command."
        usage = value_at(payload, "usage")
        errors = [message.to_s]
        errors << "Try #{usage}" if present_string(usage)
        rejected_result(command_id, command_type, message.to_s, errors)
      end
    end
  end
end
